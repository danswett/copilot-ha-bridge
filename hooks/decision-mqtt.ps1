<#
    Dynamic per-session Home Assistant entities for the Copilot CLI bridge.

    Replaces the eight fixed decision/response slots with entities created on demand,
    one set per live CLI session, published through MQTT discovery.

    Why MQTT discovery rather than input_* helpers:
      - No .storage churn. Helper create/delete rewrites the helper store and the
        entity registry on every session; discovery messages do not.
      - No orphans. A retained discovery topic is cleared by publishing an empty
        payload, and an availability topic marks a session offline the moment the
        daemon stops, so a crashed daemon degrades to "unavailable" rather than
        leaving dead helpers behind forever.
      - Entities group into a per-session device, so Home Assistant shows one card
        per Copilot session instead of eight anonymous slots.

    No MQTT broker credentials are required and no MQTT client library is used.
    Everything is published through Home Assistant's own `mqtt.publish` service
    using the existing long-lived token. Verified end to end 2026-09-21: publishing
    a retained discovery config registered the entity in about four seconds,
    omitting `state_topic` gave optimistic mode so `select.select_option` updated
    the state instantly, and an empty retained payload removed the entity with the
    state API returning 404 and no orphan left behind.
#>

$script:CopilotMqttConfig = @{
    DiscoveryPrefix = 'homeassistant'
    TopicRoot = 'copilot/cli'
    # Home Assistant caps an entity state at 255 characters. Long text therefore
    # rides in attributes via json_attributes_topic, and the state carries a short
    # summary only.
    StateMaxChars = 255
    # The MQTT text platform allows at most 255 characters for a value.
    ReplyMaxChars = 255
}

# The resume selector's "start fresh" option. Shared because the daemon compares the
# selector's state against it and the dashboard shows it as the default.
$script:CopilotMqttNewSessionOption = 'New session'

function Get-CopilotMqttNodeId {
    <#
        A stable, MQTT-safe node id for a session. Discovery topics and object ids
        allow only [a-zA-Z0-9_-], so anything else is stripped.

        Namespaced `agent_bridge_` rather than `copilot_`: the bridge serves Copilot
        CLI, Claude Code, Codex and MCP clients alike, and calling a Claude session's
        entities sensor.copilot_... was actively misleading.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $clean = ($SessionId -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($clean)) {
        # An id with no alphanumerics would otherwise collapse to a single shared
        # 'unknown' node, colliding every such session onto one card and topic set.
        # Derive a short stable hash of the raw id so distinct ids stay distinct. Real
        # ids are UUIDs and never reach this branch, so their node ids are unchanged
        # and existing entities are undisturbed.
        $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes([string]$SessionId))
        $clean = ([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 12)
    }
    if ($clean.Length -gt 16) {
        $clean = $clean.Substring(0, 16)
    }
    "agent_bridge_$($clean.ToLowerInvariant())"
}

function Get-CopilotMqttTopics {
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    $root = "$($script:CopilotMqttConfig.TopicRoot)/$node"

    @{
        Node = $node
        Root = $root
        Availability = "$root/available"
        DecisionCommand = "$root/decision/set"
        DecisionState = "$root/decision/state"
        DecisionAttributes = "$root/decision/attr"
        ReplyCommand = "$root/reply/set"
        ReplyState = "$root/reply/state"
        StatusState = "$root/status/state"
        StatusAttributes = "$root/status/attr"
        ActivityState = "$root/activity/state"
        ActivityAttributes = "$root/activity/attr"
        FieldCommandPrefix = "$root/field"
        SubmitCommand = "$root/submit/set"
        StopCommand = "$root/stop/set"
    }
}

# A multi-field question gets one dropdown per field, mirroring the native prompt's
# tabbed form. Capped so the card stays readable; a form with more fields falls back
# to the free-text outline.
$script:CopilotMqttMaxFields = 4

function Get-CopilotMqttFieldEntityId {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][int]$Index
    )
    "select.${Node}_f$Index"
}

function Get-CopilotMqttEntityIds {
    <#
        Entity ids Home Assistant derives from the discovery payloads below. The
        device name prefixes each entity, so these must track the `name` fields in
        Publish-CopilotMqttSession.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId

    @{
        Decision = "select.${node}_decision"
        Reply = "text.${node}_reply"
        Status = "sensor.${node}_status"
        Activity = "sensor.${node}_activity"
    }
}

function Publish-CopilotMqttMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Topic,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Payload,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [switch]$Retain
    )

    Invoke-HomeAssistantService -Domain 'mqtt' -Service 'publish' -Headers $Headers -Data @{
        topic = $Topic
        payload = $Payload
        retain = [bool]$Retain
        qos = 1
    }
}

function New-CopilotMqttDeviceBlock {
    param(
        [Parameter(Mandatory)]
        [string]$Node,

        [Parameter(Mandatory)]
        [string]$SessionName,

        [Parameter(Mandatory)]
        [string]$Machine
    )

    @{
        identifiers = @($Node)
        name = "Copilot: $SessionName"
        manufacturer = 'AI CLI bridge'
        model = $Machine
    }
}

function Publish-CopilotMqttSession {
    <#
        Registers the four entities for one live session. Idempotent: republishing
        the same retained configs simply updates them, so a daemon restart re-arms
        every session without creating duplicates.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$SessionName,

        [Parameter(Mandatory)]
        [string]$Machine,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })
    $prefix = $script:CopilotMqttConfig.DiscoveryPrefix

    # Availability must be retained and published before the entities appear, so a
    # session never shows up already stale.
    Publish-CopilotMqttMessage -Topic $topics.Availability -Payload 'online' -Headers $Headers -Retain

    # Decision selector. Deliberately has no state_topic: that puts the MQTT select
    # into optimistic mode, so tapping a choice updates the Home Assistant state
    # immediately instead of waiting for a device to echo the value back on a state
    # topic. Nothing is subscribed to the command topic - the bridge never connects
    # to the broker - so with a state_topic the selection would never stick.
    # The daemon observes the resulting state change over the Home Assistant
    # WebSocket, which keeps the whole path push-based and credential-free.
    $decision = @{
        name = 'Decision'
        unique_id = "${node}_decision"
        command_topic = $topics.DecisionCommand
        json_attributes_topic = $topics.DecisionAttributes
        options = @('Idle')
        icon = 'mdi:comment-question-outline'
        device = $device
        availability = $availability
        enabled_by_default = $true
    }

    # Reply box for continuing a session whose turn has already ended. Optimistic for
    # the same reason as the selector above.
    $reply = @{
        name = 'Reply'
        unique_id = "${node}_reply"
        command_topic = $topics.ReplyCommand
        max = $script:CopilotMqttConfig.ReplyMaxChars
        mode = 'text'
        icon = 'mdi:reply'
        device = $device
        availability = $availability
    }

    # Sensors are published by the daemon, so these keep a state topic.
    $status = @{
        name = 'Status'
        unique_id = "${node}_status"
        state_topic = $topics.StatusState
        json_attributes_topic = $topics.StatusAttributes
        icon = 'mdi:robot'
        device = $device
        availability = $availability
    }

    # Live activity. The state is a short label; the full text, including reasoning
    # when the verbose toggle is on, rides in the attributes.
    $activity = @{
        name = 'Activity'
        unique_id = "${node}_activity"
        state_topic = $topics.ActivityState
        json_attributes_topic = $topics.ActivityAttributes
        icon = 'mdi:pulse'
        device = $device
        availability = $availability
    }

    $map = @(
        @{ Component = 'select'; Object = 'decision'; Config = $decision }
        @{ Component = 'text'; Object = 'reply'; Config = $reply }
        @{ Component = 'sensor'; Object = 'status'; Config = $status }
        @{ Component = 'sensor'; Object = 'activity'; Config = $activity }
    )

    foreach ($entry in $map) {
        $topic = "$prefix/$($entry.Component)/$node/$($entry.Object)/config"
        $payload = $entry.Config | ConvertTo-Json -Depth 8 -Compress
        Publish-CopilotMqttMessage -Topic $topic -Payload $payload -Headers $Headers -Retain
    }

    # Every session also gets its four per-field dropdown slots, parked on a single
    # 'Idle' option. They exist from the start so the dashboard's per-field cards
    # always reference a real entity - a conditional card pointing at a missing entity
    # renders an "Entity not found" box on every session that has never been asked a
    # multi-field question.
    for ($i = 1; $i -le $script:CopilotMqttMaxFields; $i++) {
        $fieldConfig = @{
            name = "Field $i"
            unique_id = "${node}_f$i"
            command_topic = "$($topics.FieldCommandPrefix)$i/set"
            options = @('Idle')
            icon = 'mdi:form-select'
            device = $device
            availability = $availability
        }
        Publish-CopilotMqttMessage -Topic "$prefix/select/$node/f$i/config" `
            -Payload ($fieldConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
    }

    # A Submit button for multi-field questions. Without it the bridge would inject
    # the moment the last dropdown got a value, so there was no chance to review or
    # change a selection. An MQTT button's state is the timestamp of its last press,
    # which is exactly what the daemon needs to tell "submitted now" from "pressed for
    # a previous question".
    $submitConfig = @{
        name = 'Submit answer'
        unique_id = "${node}_submit"
        command_topic = $topics.SubmitCommand
        icon = 'mdi:send-check'
        device = $device
        availability = $availability
    }
    Publish-CopilotMqttMessage -Topic "$prefix/button/$node/submit/config" `
        -Payload ($submitConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # Ending a session from the dashboard. The bridge can already start one, and
    # being able to start work remotely but not stop it means a session that has gone
    # wrong can only be dealt with at the keyboard.
    #
    # Safe to press: the stop is graceful, and the transcript survives, so the
    # session stays in the resume list and can be reopened. A mistaken press costs a
    # window, not the work.
    $stopConfig = @{
        name          = 'End session'
        unique_id     = "${node}_stop"
        command_topic = $topics.StopCommand
        icon          = 'mdi:stop-circle-outline'
        device        = $device
        availability  = $availability
    }
    Publish-CopilotMqttMessage -Topic "$prefix/button/$node/stop/config" `
        -Payload ($stopConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    $topics
}

function Remove-CopilotMqttSession {
    <#
        Clears the retained discovery configs so Home Assistant drops the entities
        and leaves no orphan behind. Also clears the retained state topics, so a
        node id reused by a later session cannot inherit stale values.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $prefix = $script:CopilotMqttConfig.DiscoveryPrefix

    Publish-CopilotMqttMessage -Topic $topics.Availability -Payload 'offline' -Headers $Headers -Retain

    foreach ($entry in @(
        @{ Component = 'select'; Object = 'decision' }
        @{ Component = 'text'; Object = 'reply' }
        @{ Component = 'sensor'; Object = 'status' }
        @{ Component = 'sensor'; Object = 'activity' }
    )) {
        $topic = "$prefix/$($entry.Component)/$node/$($entry.Object)/config"
        Publish-CopilotMqttMessage -Topic $topic -Payload '' -Headers $Headers -Retain
    }

    # The per-field dropdown slots are part of the session too.
    for ($i = 1; $i -le $script:CopilotMqttMaxFields; $i++) {
        Publish-CopilotMqttMessage -Topic "$prefix/select/$node/f$i/config" `
            -Payload '' -Headers $Headers -Retain
    }
    Publish-CopilotMqttMessage -Topic "$prefix/button/$node/submit/config" `
        -Payload '' -Headers $Headers -Retain
    Publish-CopilotMqttMessage -Topic "$prefix/button/$node/stop/config" `
        -Payload '' -Headers $Headers -Retain

    foreach ($topic in @(
        $topics.DecisionState, $topics.DecisionAttributes, $topics.ReplyState,
        $topics.StatusState, $topics.StatusAttributes,
        $topics.ActivityState, $topics.ActivityAttributes, $topics.Availability
    )) {
        Publish-CopilotMqttMessage -Topic $topic -Payload '' -Headers $Headers -Retain
    }
}

function Publish-CopilotMqttUpdate {
    <#
        Publishes the bridge's own update status as a Home Assistant `update` entity,
        plus a button to install it.

        The update entity deliberately has no command_topic. Home Assistant's install
        action for an MQTT update entity publishes to that topic and reports no state
        change of its own - confirmed against a live instance - and nothing here
        subscribes to MQTT, so the button it would render could never work. Rather
        than ship a control that silently does nothing, the action is a separate
        button whose press timestamp the daemon can actually see, which is the same
        mechanism the per-session Submit button uses.
    #>
    param(
        [Parameter(Mandatory)][string]$InstalledVersion,
        [Parameter(Mandatory)][string]$LatestVersion,
        [string]$ReleaseUrl = '',
        [string]$ReleaseNotes = '',
        [switch]$InProgress,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $device = @{
        identifiers  = @('agent_bridge')
        name         = 'AI Agent Bridge'
        manufacturer = 'AI CLI bridge'
    }
    $stateTopic = "$($script:CopilotMqttConfig.TopicRoot)/update/state"

    $config = @{
        name        = 'Update'
        unique_id   = 'agent_bridge_update'
        object_id   = 'agent_bridge_update'
        state_topic = $stateTopic
        device_class = 'firmware'
        icon        = 'mdi:package-up'
        device      = $device
    }
    Publish-CopilotMqttMessage `
        -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/update/agent_bridge/update/config" `
        -Payload ($config | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # Release notes render in the entity's own dialog. They are capped because the
    # whole payload travels through an MQTT message.
    $notes = [string]$ReleaseNotes
    if ($notes.Length -gt 2000) { $notes = $notes.Substring(0, 1997) + '...' }

    $state = @{
        installed_version = $InstalledVersion
        latest_version    = $LatestVersion
        title             = 'Copilot CLI Home Assistant bridge'
        # Always present, so Home Assistant shows a spinner while an install runs and
        # clears it the moment a later publish reports false, rather than inferring
        # the flag from an absent key.
        in_progress       = [bool]$InProgress
    }
    if ($ReleaseUrl) { $state['release_url'] = $ReleaseUrl }
    if ($notes) { $state['release_summary'] = $notes }

    Publish-CopilotMqttMessage -Topic $stateTopic `
        -Payload ($state | ConvertTo-Json -Depth 6 -Compress) -Headers $Headers -Retain

    $button = @{
        name          = 'Install Bridge Update'
        unique_id     = 'agent_bridge_install_update'
        object_id     = 'agent_bridge_install_update'
        command_topic = "$($script:CopilotMqttConfig.TopicRoot)/update/install"
        icon          = 'mdi:download'
        device        = $device
    }
    Publish-CopilotMqttMessage `
        -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/button/agent_bridge/install_update/config" `
        -Payload ($button | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
}

function Publish-CopilotMqttNewSession {
    <#
        Publishes the controls that start a brand new CLI session, on the same
        bridge-level device as the update entity and the session counter.

        Four entities, deliberately split rather than combined:

          * a `text` box for the opening prompt,
          * a `select` listing the approved working directories,
          * a `button` that actually launches,
          * a `sensor` reporting what the last press did.

        The text and select are optimistic - no state topic - for the same reason
        the per-session reply box is: nothing here subscribes to the broker, so a
        typed value would never be echoed back and would never stick.

        Launching is a separate button rather than an action on the text box because
        Home Assistant commits a text entity as soon as it loses focus. Acting on
        the value alone would spawn a session the moment you clicked away, which is
        easy to do by accident and impossible to undo. The button's state is the
        timestamp of its last press, which is exactly the signal the daemon needs.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Workspaces,

        [AllowEmptyCollection()]
        [string[]]$Profiles = @(),

        [AllowEmptyCollection()]
        [object[]]$Resumable = @(),

        [string]$LastResult = '',

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $device = @{
        identifiers  = @('agent_bridge')
        name         = 'AI Agent Bridge'
        manufacturer = 'AI CLI bridge'
    }
    $prefix = $script:CopilotMqttConfig.DiscoveryPrefix
    $root = $script:CopilotMqttConfig.TopicRoot

    # An MQTT select must offer at least one option, so a bridge with nothing
    # configured still publishes a single explanatory entry rather than an invalid
    # discovery payload that Home Assistant would reject outright.
    $options = @(@($Workspaces) | ForEach-Object { [string]$_.Label } | Where-Object { $_ })
    if ($options.Count -eq 0) { $options = @('(no workspaces configured)') }

    $promptConfig = @{
        name          = 'New session prompt'
        unique_id     = 'agent_bridge_new_prompt'
        object_id     = 'agent_bridge_new_prompt'
        command_topic = "$root/newsession/prompt/set"
        max           = $script:CopilotMqttConfig.ReplyMaxChars
        mode          = 'text'
        icon          = 'mdi:message-plus-outline'
        device        = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/text/agent_bridge/new_prompt/config" `
        -Payload ($promptConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    $workspaceConfig = @{
        name          = 'New session workspace'
        unique_id     = 'agent_bridge_new_workspace'
        object_id     = 'agent_bridge_new_workspace'
        command_topic = "$root/newsession/workspace/set"
        options       = $options
        icon          = 'mdi:folder-open-outline'
        device        = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/select/agent_bridge/new_workspace/config" `
        -Payload ($workspaceConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # The Agency profile decides which MCP servers and plugins a session gets, and it
    # is an axis of its own rather than a property of the directory - the same folder
    # is routinely opened under different profiles. It therefore gets its own
    # selector instead of being folded into the workspace list.
    #
    # Published even when Agency is not the launcher, so the entity the generated
    # dashboard references always exists; the daemon simply ignores its value.
    $profileOptions = @(@($Profiles) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($profileOptions.Count -eq 0) { $profileOptions = @('(default)') }

    $profileConfig = @{
        name          = 'New session profile'
        unique_id     = 'agent_bridge_new_profile'
        object_id     = 'agent_bridge_new_profile'
        command_topic = "$root/newsession/profile/set"
        options       = $profileOptions
        icon          = 'mdi:account-cog-outline'
        device        = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/select/agent_bridge/new_profile/config" `
        -Payload ($profileConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # Resume selector. "New session" is always the first option and the default, so
    # the common case needs no interaction and nothing can be resumed by accident.
    $resumeOptions = @($script:CopilotMqttNewSessionOption)
    foreach ($entry in @($Resumable)) {
        $label = [string]$entry.Label
        if (-not [string]::IsNullOrWhiteSpace($label)) { $resumeOptions += $label }
    }

    $resumeConfig = @{
        name          = 'New session resume'
        unique_id     = 'agent_bridge_new_resume'
        object_id     = 'agent_bridge_new_resume'
        command_topic = "$root/newsession/resume/set"
        options       = $resumeOptions
        icon          = 'mdi:history'
        device        = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/select/agent_bridge/new_resume/config" `
        -Payload ($resumeConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    $buttonConfig = @{
        name          = 'Start new session'
        unique_id     = 'agent_bridge_new_session'
        object_id     = 'agent_bridge_new_session'
        command_topic = "$root/newsession/start"
        icon          = 'mdi:rocket-launch-outline'
        device        = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/button/agent_bridge/new_session/config" `
        -Payload ($buttonConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    $resultTopic = "$root/newsession/result"
    $resultConfig = @{
        name        = 'New session result'
        unique_id   = 'agent_bridge_new_session_result'
        object_id   = 'agent_bridge_new_session_result'
        state_topic = $resultTopic
        icon        = 'mdi:information-outline'
        device      = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/sensor/agent_bridge/new_session_result/config" `
        -Payload ($resultConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    if ($PSBoundParameters.ContainsKey('LastResult')) {
        Set-CopilotMqttNewSessionResult -Text $LastResult -Headers $Headers
    }
}

function Set-CopilotMqttNewSessionResult {
    <#
        Reports the outcome of the last launch. Truncated to the Home Assistant state
        limit, since a failure detail can easily run past it.
    #>
    param(
        [string]$Text = '',
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $value = [string]$Text
    $limit = $script:CopilotMqttConfig.StateMaxChars
    if ($value.Length -gt $limit) { $value = $value.Substring(0, $limit - 3) + '...' }

    Publish-CopilotMqttMessage -Topic "$($script:CopilotMqttConfig.TopicRoot)/newsession/result" `
        -Payload $value -Headers $Headers -Retain
}

function Clear-CopilotLegacyMqttEntities {
    <#
        Removes the entities published under the pre-rename `copilot_cli_*` and
        `copilot_<hex>` ids.

        An MQTT discovery config is retained on the broker, so renaming a unique_id
        does not replace the old entity - it adds a second one and leaves the first
        sitting there forever, unavailable and confusing. The retained payload has to
        be explicitly cleared, which is done by publishing an empty one.

        Only two sets can still exist by the time this runs. The bridge-wide entities,
        which are a fixed list; and the per-session entities of whatever was live at
        the moment of the switch, because a session's topics are already cleared when
        it exits. Historical sessions therefore need no sweep.

        Returns the number of topics cleared.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,

        # Session ids whose legacy per-session topics should also be cleared.
        [AllowEmptyCollection()]
        [string[]]$SessionIds = @()
    )

    $prefix = $script:CopilotMqttConfig.DiscoveryPrefix
    $topics = @(
        "$prefix/update/copilot_cli_bridge/update/config"
        "$prefix/button/copilot_cli_bridge/install_update/config"
        "$prefix/text/copilot_cli_bridge/new_prompt/config"
        "$prefix/select/copilot_cli_bridge/new_workspace/config"
        "$prefix/select/copilot_cli_bridge/new_profile/config"
        "$prefix/select/copilot_cli_bridge/new_resume/config"
        "$prefix/button/copilot_cli_bridge/new_session/config"
        "$prefix/sensor/copilot_cli_bridge/new_session_result/config"
        "$prefix/sensor/copilot_cli_global/sessions/config"
    )

    foreach ($sessionId in @($SessionIds)) {
        $node = Get-CopilotLegacyMqttNodeId -SessionId $sessionId
        if ([string]::IsNullOrWhiteSpace($node)) { continue }
        $topics += @(
            "$prefix/select/$node/decision/config"
            "$prefix/text/$node/reply/config"
            "$prefix/sensor/$node/status/config"
            "$prefix/sensor/$node/activity/config"
            "$prefix/button/$node/submit/config"
        )
        for ($i = 1; $i -le $script:CopilotMqttMaxFields; $i++) {
            $topics += "$prefix/select/$node/f$i/config"
        }
    }

    $cleared = 0
    foreach ($topic in $topics) {
        try {
            Publish-CopilotMqttMessage -Topic $topic -Payload '' -Headers $Headers -Retain
            $cleared++
        }
        catch {
            # A topic that cannot be cleared is not worth failing a daemon start over.
        }
    }

    $cleared
}

function Get-CopilotLegacyMqttNodeId {
    <#
        The node id a session had before the `agent_bridge_` rename. Kept verbatim
        rather than derived from the current function, so a later change to node
        naming cannot silently break the cleanup of the old one.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    $clean = ($SessionId -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($clean)) { return '' }
    if ($clean.Length -gt 16) { $clean = $clean.Substring(0, 16) }
    "copilot_$($clean.ToLowerInvariant())"
}

function Publish-CopilotMqttGlobalStatus {
    <#
        Publishes a single global sensor summarising all live sessions, so the
        dashboard can show an accurate live-session count without a fragile template.

        The old dashboard counter (input_number.copilot_cli_active_sessions) only
        counted sessions in the 'working' state, so a set of sessions all idle and
        waiting for input read as 0 - which looked broken. This sensor counts every
        live session the daemon is tracking, whatever their turn state, and lists them
        in an attribute.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Sessions,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $node = 'agent_bridge_global'
    $stateTopic = "$($script:CopilotMqttConfig.TopicRoot)/global/state"
    $attrTopic = "$($script:CopilotMqttConfig.TopicRoot)/global/attr"

    $config = @{
        name = 'Sessions'
        unique_id = 'agent_bridge_sessions'
        object_id = 'agent_bridge_sessions'
        state_topic = $stateTopic
        json_attributes_topic = $attrTopic
        icon = 'mdi:robot-happy'
        device = @{
            identifiers = @('agent_bridge')
            name = 'AI Agent Bridge'
            manufacturer = 'AI CLI bridge'
        }
    }
    Publish-CopilotMqttMessage `
        -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/sensor/$node/sessions/config" `
        -Payload ($config | ConvertTo-Json -Depth 6 -Compress) -Headers $Headers -Retain

    Publish-CopilotMqttMessage -Topic $stateTopic -Payload ([string]$Sessions.Count) `
        -Headers $Headers -Retain
    Publish-CopilotMqttMessage -Topic $attrTopic -Payload (@{
        sessions = @($Sessions)
        updated = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json -Depth 6 -Compress) -Headers $Headers -Retain
}

function Get-CopilotMqttGlobalEntityId {
    'sensor.agent_bridge_sessions'
}

function Set-CopilotMqttStatus {
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [ValidateSet('working', 'idle', 'waiting', 'offline')]
        [string]$Status,

        [hashtable]$Attributes = @{},

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    Publish-CopilotMqttMessage -Topic $topics.StatusState -Payload $Status -Headers $Headers -Retain
    Publish-CopilotMqttMessage -Topic $topics.StatusAttributes `
        -Payload ($Attributes | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
}

function Set-CopilotMqttActivity {
    <#
        Publishes one live activity update. `Summary` is the short state label and is
        truncated to the Home Assistant state limit; `Detail` carries the full text,
        including model reasoning when the verbose toggle is on.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Summary,

        [AllowNull()]
        [hashtable]$Detail,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $state = $Summary
    $limit = $script:CopilotMqttConfig.StateMaxChars
    if ($state.Length -gt $limit) {
        $state = $state.Substring(0, $limit - 3) + '...'
    }

    Publish-CopilotMqttMessage -Topic $topics.ActivityState -Payload $state -Headers $Headers -Retain
    if ($null -ne $Detail) {
        Publish-CopilotMqttMessage -Topic $topics.ActivityAttributes `
            -Payload ($Detail | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
    }
}

function Publish-CopilotMqttDecisionFields {
    <#
        Publishes one dropdown per field of a multi-field question, mirroring the
        native prompt's tabbed form.

        A multi-field form used to be flattened into the cartesian product of every
        field's options on a single dropdown - two fields of 3 and 2 options became 6
        entries, and a real one reached 9 - which is unreadable and scales terribly.
        One dropdown per field keeps each list short and matches what the terminal
        shows. The daemon injects only once every field has a selection.

        Each dropdown starts on a "Choose..." placeholder so "not yet answered" is
        distinguishable from a real choice.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Fields,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })

    for ($i = 1; $i -le $script:CopilotMqttMaxFields; $i++) {
        $field = if ($i -le $Fields.Count) { $Fields[$i - 1] } else { $null }

        # Unused field slots collapse to a single Idle option so the dashboard's
        # condition hides them; they are not deleted, which keeps the entity ids
        # stable across questions.
        $options = @('Idle')
        $label = "Field $i"
        if ($null -ne $field) {
            $label = [string]$field.Label
            if ([string]::IsNullOrWhiteSpace($label)) { $label = "Field $i" }
            $options = @('Choose...') + @(
                $field.Options | ForEach-Object {
                    $t = [string]$_
                    if ($t.Length -gt 250) { $t = $t.Substring(0, 247) + '...' }
                    $t
                }
            )
        }

        $config = @{
            name = $label
            unique_id = "${node}_f$i"
            command_topic = "$($topics.FieldCommandPrefix)$i/set"
            options = $options
            icon = 'mdi:form-select'
            device = $device
            availability = $availability
        }
        Publish-CopilotMqttMessage `
            -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/select/$node/f$i/config" `
            -Payload ($config | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
    }

    # Home Assistant derives an MQTT entity id from the device name plus the entity
    # name, so these register as select.<device>_field_1 rather than the node-based id
    # the dashboard points at. Force them onto the deterministic ids before driving
    # their values, otherwise the dashboard's per-field cards reference entities that
    # do not exist and simply render nothing.
    Start-Sleep -Milliseconds 900
    if (Get-Command Set-CopilotMqttEntityIds -ErrorAction SilentlyContinue) {
        try { [void](Set-CopilotMqttEntityIds -SessionId $SessionId) }
        catch { }
    }

    # Now set each dropdown's starting value. These are optimistic selects, so their
    # state must be driven explicitly.
    for ($i = 1; $i -le $script:CopilotMqttMaxFields; $i++) {
        $start = if ($i -le $Fields.Count) { 'Choose...' } else { 'Idle' }
        try {
            Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers -Data @{
                entity_id = (Get-CopilotMqttFieldEntityId -Node $node -Index $i)
                option = $start
            }
        }
        catch {
            # Non-fatal; the dashboard condition treats a missing value as unanswered.
        }
    }
}

function Publish-CopilotMqttSubmitButton {
    <#
        Publishes just the Submit button for a session. Used to provision it onto
        sessions that were created before the button existed, without disturbing their
        other entities.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })

    $config = @{
        name = 'Submit answer'
        unique_id = "${node}_submit"
        command_topic = $topics.SubmitCommand
        icon = 'mdi:send-check'
        device = $device
        availability = $availability
    }
    Publish-CopilotMqttMessage `
        -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/button/$node/submit/config" `
        -Payload ($config | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    Start-Sleep -Milliseconds 900
    if (Get-Command Set-CopilotMqttEntityIds -ErrorAction SilentlyContinue) {
        try { [void](Set-CopilotMqttEntityIds -SessionId $SessionId) } catch { }
    }
}

function Clear-CopilotMqttDecisionFields {
    <#
        Collapses every field dropdown back to Idle so the dashboard hides them once
        the question is answered.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    Publish-CopilotMqttDecisionFields -SessionId $SessionId -SessionName $SessionName `
        -Machine $Machine -Fields @() -Headers $Headers
}

function Set-CopilotMqttSelectOption {
    <#
        Drives an optimistic MQTT select to a value, waiting until Home Assistant has
        actually ingested the discovery config that carries that value.

        The MQTT select platform fixes its option list at configuration time, and
        `select.select_option` rejects anything outside that list with a
        ServiceValidationError. Discovery is asynchronous: the retained config goes to
        the broker, Home Assistant consumes it, and only then does the entity carry the
        new options. Publishing and then immediately selecting is therefore a race.

        This used to be a flat `Start-Sleep -Milliseconds 600`. Under load that is not
        enough: the call lands while the entity still holds the *previous* option list,
        and Home Assistant logs

            Option 'Awaiting answer...' is not valid for entity
            select.<node>_decision, valid options are: Idle

        once per attempt (30 in one observed 24h window). The exception was caught and
        ignored, so the card still carried the question in its attributes - but the
        selector's state stayed 'unknown', which the dashboard cannot tell apart from an
        idle card, so the Answer control was hidden exactly when it was needed.

        Polling for the option to appear fixes it in both directions and is usually
        *faster* than the old fixed sleep, because it returns as soon as the entity is
        ready instead of always paying 600 ms. The wait is bounded; on timeout the
        select is still attempted, since that costs nothing beyond the log line the
        caller already tolerated.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EntityId,

        [Parameter(Mandatory)]
        [string]$Option,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [ValidateRange(1, 40)]
        [int]$Attempts = 12,

        [ValidateRange(25, 2000)]
        [int]$DelayMs = 150
    )

    $ready = $false
    foreach ($attempt in 1..$Attempts) {
        try {
            $state = Get-HomeAssistantState -EntityId $EntityId -Headers $Headers
            if ($null -ne $state -and (@($state.attributes.options) -contains $Option)) {
                $ready = $true
                break
            }
        }
        catch {
            # A missing entity is a 404, which the retry layer rethrows immediately
            # rather than treating as transient. Discovery simply has not registered it
            # yet, so keep waiting rather than giving up.
        }
        if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds $DelayMs }
    }

    try {
        Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers -Data @{
            entity_id = $EntityId
            option    = $Option
        }
    }
    catch {
        # Non-fatal by design: the attributes already carry (or have already cleared)
        # the question, so a failed state nudge costs only the dashboard's Answer
        # control, never the answer itself.
    }

    return $ready
}

function Set-CopilotMqttDecision {
    <#
        Arms the decision selector with a question.

        The options list is republished through discovery because the MQTT select
        platform fixes its options at configuration time. Passing no choices leaves
        the selector idle and marks the question freeform, to be answered in the
        reply box instead.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$SessionName,

        [Parameter(Mandatory)]
        [string]$Machine,

        [Parameter(Mandatory)]
        [string]$Question,

        [string[]]$Choices = @(),

        # Per-field option lists. When more than one field is present the question is
        # published as one dropdown per field instead of a single flattened list.
        [AllowNull()][object[]]$Fields = @(),

        [Parameter(Mandatory)]
        [string]$DecisionId,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })

    $fieldList = @($Fields)
    $isMultiField = $fieldList.Count -gt 1 -and $fieldList.Count -le $script:CopilotMqttMaxFields

    # A multi-field question answers through its per-field dropdowns, so the main
    # selector carries only Cancel; a single-field one keeps the full option list.
    $options = @('Awaiting answer...')
    if ($isMultiField) {
        $options = @('Awaiting answer...', 'Cancel request')
    }
    elseif ($Choices.Count -gt 0) {
        $options = @('Awaiting answer...') +
            @($Choices | ForEach-Object {
                $text = [string]$_
                if ($text.Length -gt 250) { $text = $text.Substring(0, 247) + '...' }
                $text
            }) +
            @('Cancel request')
    }

    $decision = @{
        name = 'Decision'
        unique_id = "${node}_decision"
        command_topic = $topics.DecisionCommand
        json_attributes_topic = $topics.DecisionAttributes
        options = $options
        icon = 'mdi:comment-question-outline'
        device = $device
        availability = $availability
    }

    $topic = "$($script:CopilotMqttConfig.DiscoveryPrefix)/select/$node/decision/config"
    Publish-CopilotMqttMessage -Topic $topic `
        -Payload ($decision | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # The selector is optimistic, so its state stays 'unknown' until something sets it.
    # Drive it to the placeholder so the state itself says "a question is waiting" -
    # the dashboard keys the Answer control off that, and 'unknown' would otherwise be
    # indistinguishable from an idle card.
    Set-CopilotMqttSelectOption -EntityId "select.${node}_decision" `
        -Option 'Awaiting answer...' -Headers $Headers | Out-Null

    # Publish the per-field dropdowns for a multi-field question, and collapse them
    # for a single-field one so a previous question's fields never linger.
    if ($isMultiField) {
        Publish-CopilotMqttDecisionFields -SessionId $SessionId -SessionName $SessionName `
            -Machine $Machine -Fields $fieldList -Headers $Headers
    }
    else {
        Clear-CopilotMqttDecisionFields -SessionId $SessionId -SessionName $SessionName `
            -Machine $Machine -Headers $Headers
    }

    # The card shows the question in full, so it is published whole rather than split
    # into a preview plus a "show more" remainder - the expander is reserved for
    # reasoning and extra detail.
    $fullQuestion = $Question
    if ($fullQuestion.Length -gt $script:DecisionBridgeConfig.DecisionQuestionMaxChars) {
        $fullQuestion = $fullQuestion.Substring(0, $script:DecisionBridgeConfig.DecisionQuestionMaxChars).TrimEnd() +
            "`n`n_(truncated - see terminal)_"
    }
    $questionAttrs = @{
        decision_id = $DecisionId
        question = $fullQuestion
        choices = @($Choices)
        mode = if ($Choices.Count -gt 0 -or $fieldList.Count -gt 0) { 'multiple_choice' } else { 'freeform' }
        multi_field = $isMultiField
        field_count = $(if ($isMultiField) { $fieldList.Count } else { 0 })
        session = $SessionName
        machine = $Machine
        asked_at = [DateTimeOffset]::Now.ToString('o')
    }
    # Field labels ride on the decision attributes so the dashboard can name each
    # dropdown after its field without rebuilding the whole Lovelace config.
    if ($isMultiField) {
        for ($fi = 1; $fi -le $fieldList.Count; $fi++) {
            $lbl = [string]$fieldList[$fi - 1].Label
            if ([string]::IsNullOrWhiteSpace($lbl)) { $lbl = "Field $fi" }
            $questionAttrs["field_${fi}_label"] = $lbl
        }
    }
    Publish-CopilotMqttMessage -Topic $topics.DecisionAttributes `
        -Payload ($questionAttrs | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    $topics
}

function Clear-CopilotMqttDecision {
    <#
        Returns the selector to its idle state once an answer has been consumed.

        The selector is optimistic, so its value cannot be reset by publishing to a
        state topic - there is none. Resetting therefore means republishing the
        discovery config with only the idle option, which both clears the stale
        answer and stops the old choices being tappable a second time.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$SessionName,

        [Parameter(Mandatory)]
        [string]$Machine,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })

    $decision = @{
        name = 'Decision'
        unique_id = "${node}_decision"
        command_topic = $topics.DecisionCommand
        json_attributes_topic = $topics.DecisionAttributes
        options = @('Idle')
        icon = 'mdi:comment-question-outline'
        device = $device
        availability = $availability
    }

    Publish-CopilotMqttMessage `
        -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/select/$node/decision/config" `
        -Payload ($decision | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
    Publish-CopilotMqttMessage -Topic $topics.DecisionAttributes -Payload '{}' -Headers $Headers -Retain

    # Drive the optimistic selector to 'Idle' so its state, not just its attributes,
    # reflects that nothing is waiting. The dashboard shows the Answer control only
    # when the state is something other than Idle.
    Set-CopilotMqttSelectOption -EntityId "select.${node}_decision" `
        -Option 'Idle' -Headers $Headers | Out-Null

    # Collapse any per-field dropdowns from a multi-field question.
    try {
        Clear-CopilotMqttDecisionFields -SessionId $SessionId -SessionName $SessionName `
            -Machine $Machine -Headers $Headers
    }
    catch {
        # Non-fatal.
    }
}

