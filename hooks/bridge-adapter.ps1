<#
.SYNOPSIS
    Client-neutral adapter orchestration for the Home Assistant bridge.

.DESCRIPTION
    The Copilot, Claude and Codex hooks all translate a front-end event into the same
    handful of Home Assistant operations: gate on reachability, make sure the session's
    entities exist, publish a status and activity, and push a notification. That
    orchestration used to be copy-pasted into every hook, so a fix to the timeout, the
    entity-adoption dance, or the notification shape had to be made in several places.

    These functions are that shared orchestration. An adapter is now responsible only
    for the client-specific parts - parsing its event schema, discovering its
    transcript and owning process, and mapping an event to a status/activity - and
    calls into here for everything that is the same across front ends.

    Depends on decision-bridge-common.ps1 (reachability, headers, deadline,
    notifications) and decision-mqtt.ps1 (entity publish/status/activity). Callers that
    use Confirm-BridgeSessionEntities must also have decision-ha-websocket.ps1 loaded,
    because publishing a new session resolves its entity ids over the WebSocket.
#>

# Deliberately no top-level Set-StrictMode: this library is dot-sourced into hook
# scripts, and Set-StrictMode leaks into the dot-sourcing scope. The Copilot hooks
# (route-ask-user-v3, notify-agent-response) are not written under StrictMode, so
# forcing it on them changes their behaviour. The functions below are strict-safe
# regardless, and the test suite dot-sources them under StrictMode to keep them so.

function Enter-BridgeAdapterSession {
    <#
        The reachability gate every adapter runs before touching Home Assistant.

        Returns the request headers when Home Assistant is reachable, having set the
        per-hook deadline; returns $null when it is not, so the caller can exit
        silently and let the daemon catch up. A hook must never wait on the network,
        which is why the probe is short and a miss is not an error.
    #>
    param(
        [int]$ProbeTimeoutSec = 2,
        [int]$DeadlineSeconds = 45
    )

    if (-not (Test-HomeAssistantReachable -TimeoutSec $ProbeTimeoutSec)) {
        Write-DecisionBridgeLog -Message 'Home Assistant unreachable; skipping (the daemon will catch up)'
        return $null
    }
    Set-DecisionBridgeDeadline -Seconds $DeadlineSeconds
    Get-HomeAssistantHeaders
}

function Test-BridgeSessionEntityPresent {
    <#
        True when a session entity already exists in Home Assistant. Used to decide
        whether to publish a session on demand, and to touch only existing entities
        from a turn-end hook. An unreadable state is treated as absent.
    #>
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    try {
        $probe = Get-HomeAssistantState -EntityId $EntityId -Headers $Headers
        return ($null -ne $probe -and [string]$probe.state -notin @('unavailable', ''))
    }
    catch {
        return $false
    }
}

function Confirm-BridgeSessionEntities {
    <#
        Ensures a session's entities exist, publishing them on demand when they do not.

        A hook can be the first thing a session ever does - a notification, an
        ask_user - so waiting for the daemon's reconcile would delay exactly the alert
        that matters. Publishing here fills that gap; the short sleep lets Home
        Assistant register the discovery config before the ids are pinned.

        Returns $true when the entities already existed (nothing was published).
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][hashtable]$Headers,
        # Which entity to probe for existence. Defaults to the status sensor; the
        # ask_user router probes the decision selector instead.
        [string]$ProbeEntity
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    if ([string]::IsNullOrWhiteSpace($ProbeEntity)) { $ProbeEntity = "sensor.${node}_status" }

    $exists = Test-BridgeSessionEntityPresent -EntityId $ProbeEntity -Headers $Headers
    if (-not $exists) {
        Publish-CopilotMqttSession -SessionId $SessionId -SessionName $SessionName `
            -Machine $Machine -Headers $Headers | Out-Null
        Start-Sleep -Milliseconds 1500
        [void](Set-CopilotMqttEntityIds -SessionId $SessionId)
    }
    $exists
}

function Publish-BridgeSessionStatus {
    <#
        Publishes a session's status and, when given, its activity, with the standard
        session/machine/updated attributes every adapter uses. Extra status attributes
        (a Codex model and pid, a Claude notification message) are merged in.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$Status,
        [string]$Activity,
        [hashtable]$ExtraAttributes
    )

    $attributes = @{
        session = $SessionName
        machine = $Machine
        updated = [DateTimeOffset]::Now.ToString('o')
    }
    if ($ExtraAttributes) {
        foreach ($key in $ExtraAttributes.Keys) { $attributes[$key] = $ExtraAttributes[$key] }
    }

    Set-CopilotMqttStatus -SessionId $SessionId -Status $Status -Headers $Headers -Attributes $attributes
    if (-not [string]::IsNullOrWhiteSpace($Activity)) {
        Set-CopilotMqttActivity -SessionId $SessionId -Summary $Activity `
            -Detail @{ session = $SessionName; machine = $Machine } -Headers $Headers
    }
}

function Format-BridgeNotificationTitle {
    <# Caps a notification title to the length the notifier accepts. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title)

    if ($Title.Length -gt 190) { return $Title.Substring(0, 187) + '...' }
    $Title
}

function Send-BridgeResponseNotification {
    <#
        Pushes the out-of-band preview of a finished response. The dashboard card
        carries the full text - the daemon streams it - so only a capped preview is
        sent, and nothing is sent for an empty response. The title prefix and dashboard
        label default to the wording the Claude and Codex adapters use; the Copilot
        hook overrides them for its own phrasing.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Response,
        [Parameter(Mandatory)][hashtable]$Headers,
        [string]$TitlePrefix = 'Response',
        [string]$DashboardLabel = 'the dashboard'
    )

    if ([string]::IsNullOrWhiteSpace($Response)) { return }

    $preview = $Response
    if ($preview.Length -gt 880) {
        $preview = $preview.Substring(0, 880).TrimEnd() + "...`n`nFull response is on $DashboardLabel."
    }
    Send-BridgeNotification -Title (Format-BridgeNotificationTitle "${TitlePrefix}: $SessionName") `
        -Message $preview -Headers $Headers
}
