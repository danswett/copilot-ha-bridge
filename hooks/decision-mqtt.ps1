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

function Get-CopilotMqttNodeId {
    <#
        A stable, MQTT-safe node id for a session. Discovery topics and object ids
        allow only [a-zA-Z0-9_-], so anything else is stripped.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $clean = ($SessionId -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($clean)) {
        $clean = 'unknown'
    }
    if ($clean.Length -gt 16) {
        $clean = $clean.Substring(0, 16)
    }
    "copilot_$($clean.ToLowerInvariant())"
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
        manufacturer = 'GitHub Copilot CLI'
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

    foreach ($topic in @(
        $topics.DecisionState, $topics.DecisionAttributes, $topics.ReplyState,
        $topics.StatusState, $topics.StatusAttributes,
        $topics.ActivityState, $topics.ActivityAttributes, $topics.Availability
    )) {
        Publish-CopilotMqttMessage -Topic $topic -Payload '' -Headers $Headers -Retain
    }
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

    $node = 'copilot_cli_global'
    $stateTopic = "$($script:CopilotMqttConfig.TopicRoot)/global/state"
    $attrTopic = "$($script:CopilotMqttConfig.TopicRoot)/global/attr"

    $config = @{
        name = 'Copilot Sessions'
        unique_id = 'copilot_cli_sessions'
        object_id = 'copilot_cli_sessions'
        state_topic = $stateTopic
        json_attributes_topic = $attrTopic
        icon = 'mdi:robot-happy'
        device = @{
            identifiers = @('copilot_cli_bridge')
            name = 'Copilot CLI Bridge'
            manufacturer = 'GitHub Copilot CLI'
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
    'sensor.copilot_cli_sessions'
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
    Start-Sleep -Milliseconds 600
    try {
        Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers -Data @{
            entity_id = "select.${node}_decision"
            option = 'Awaiting answer...'
        }
    }
    catch {
        # Non-fatal: the card still carries the question in its attributes.
    }

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
    Start-Sleep -Milliseconds 600
    try {
        Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers -Data @{
            entity_id = "select.${node}_decision"
            option = 'Idle'
        }
    }
    catch {
        # Non-fatal: the cleared attributes already hide the question.
    }

    # Collapse any per-field dropdowns from a multi-field question.
    try {
        Clear-CopilotMqttDecisionFields -SessionId $SessionId -SessionName $SessionName `
            -Machine $Machine -Headers $Headers
    }
    catch {
        # Non-fatal.
    }
}
