<#
    ask_user routing over the per-session Home Assistant bridge — dual-input, non-blocking.

    When the model calls ask_user, this preToolUse hook:
      1. Ensures this session's Home Assistant entities exist.
      2. Arms this session's MQTT decision card with the question and choices.
      3. Sends an optional push notification.
      4. Writes a pending-decision marker for the daemon.
      5. Returns `allow` IMMEDIATELY, so the native terminal prompt appears at once.

    Why non-blocking:
      The previous router blocked until Home Assistant returned an answer, then denied
      the tool with that answer. Blocking froze the terminal: anything typed there was
      queued by the CLI behind the blocked hook, so you could only answer from Home
      Assistant, never the terminal. Worse, the daemon also injects Home Assistant
      replies, so the two raced and an answer could be both denied by the hook and
      injected into the console.

      This hook does not wait. The native terminal prompt is the single source of
      truth. Home Assistant becomes a second input device: the daemon watches the card
      and, while the ask_user is still pending, injects the answer into the same native
      prompt (proven AttachConsole + WriteConsoleInput path). Whichever you use first
      wins; the transcript's matching tool.execution_complete is the authoritative
      "answered" signal, and the daemon clears the card on it. Neither path blocks the
      other, so there is no deadlock and the terminal always works — even if Home
      Assistant or the daemon is down.

    Fail-open: any error still returns `allow`, so the native ask_user prompt is never
    suppressed.
#>

$ErrorActionPreference = 'Stop'

function Write-AllowDecision {
    @{ permissionDecision = 'allow' } | ConvertTo-Json -Compress
    exit 0
}

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    . (Join-Path $PSScriptRoot 'decision-bridge-common.ps1')
    . (Join-Path $PSScriptRoot 'decision-mqtt.ps1')
    . (Join-Path $PSScriptRoot 'decision-ha-websocket.ps1')
    . (Join-Path $PSScriptRoot 'bridge-adapter.ps1')

    $rawEvent = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawEvent)) {
        Write-AllowDecision
    }

    $event = $rawEvent | ConvertFrom-Json
    $toolArgs = $event.toolArgs
    if ($null -eq $toolArgs) { $toolArgs = $event.tool_input }
    if ($toolArgs -is [string]) { $toolArgs = $toolArgs | ConvertFrom-Json }
    if ($null -ne $toolArgs.arguments) {
        $toolArgs = $toolArgs.arguments
        if ($toolArgs -is [string]) { $toolArgs = $toolArgs | ConvertFrom-Json }
    }

    $parsed = Repair-DecisionToolArguments -ToolArgs $toolArgs
    $question = $parsed.Question
    $choices = @($parsed.Choices)
    $combos = @($parsed.Combos)
    $fields = @($parsed.Fields)
    $mode = if ($choices.Count -gt 0 -or $fields.Count -gt 0) { 'multiple_choice' } else { 'freeform' }

    $argKeys = if ($null -ne $toolArgs) {
        (@($toolArgs.PSObject.Properties.Name) -join ',')
    }
    else { '<none>' }
    Write-DecisionBridgeLog -Message (
        "ask_user parsed (v3): argKeys=[$argKeys] choices=$($choices.Count) mode=$mode questionChars=$($question.Length)"
    )

    $sessionId = [string]$event.sessionId
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = "unknown-$PID" }
    $workingDirectory = [string]$event.cwd
    if ([string]::IsNullOrWhiteSpace($workingDirectory)) { $workingDirectory = 'Unknown folder' }

    # This hook runs before the native prompt appears; it must never wait on the
    # network. Enter-BridgeAdapterSession probes, sets the deadline and returns headers
    # when Home Assistant is reachable, or $null when it is not.
    $headers = Enter-BridgeAdapterSession
    if (-not $headers) { Write-AllowDecision }
    $display = Get-CopilotSessionDisplay -SessionId $sessionId -WorkingDirectory $workingDirectory
    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $decisionId = "$($node)-$($event.timestamp)"

    # Ensure this session's entities exist. The daemon publishes them within a
    # reconcile interval of session start, but an ask_user in the first seconds of a
    # brand-new session may beat it, so publish on demand and force deterministic ids.
    [void](Confirm-BridgeSessionEntities -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Headers $headers -ProbeEntity "select.${node}_decision")

    Set-CopilotMqttDecision -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Question $question -Choices $choices `
        -Fields $fields -DecisionId $decisionId -Headers $headers | Out-Null

    # The marker is the daemon's gate: while it exists and the transcript shows the
    # ask_user still pending, the daemon injects a Home Assistant answer and clears the
    # card on completion. It also carries the combo mapping so a multi-field choice can
    # be reported field by field.
    Write-CopilotDecisionMarker -SessionId $sessionId -DecisionId $decisionId `
        -Question $question -Choices $choices -Combos $combos -Fields $fields -Mode $mode

    # Notify. Both paths (terminal and Home Assistant) are now open.
    if ($choices.Count -gt 0) {
        $numbered = for ($i = 0; $i -lt $choices.Count; $i++) { "$($i + 1). $($choices[$i])" }
        $body = @(
            "Session: $($display.Name)"
            "Machine: $($display.Machine)"
            ''
            $question
            ''
            ($numbered -join "`n")
            ''
            'Answer in the terminal or on the Copilot Decisions dashboard.'
        ) -join "`n"
    }
    else {
        $body = @(
            "Session: $($display.Name)"
            "Machine: $($display.Machine)"
            ''
            $question
            ''
            'Answer in the terminal or in the Reply box on the Copilot Decisions dashboard.'
        ) -join "`n"
    }
    if ($body.Length -gt 950) { $body = $body.Substring(0, 947) + '...' }
    $title = Format-BridgeNotificationTitle "Copilot: $($display.Name)"
    Send-BridgeNotification -Title $title -Message $body -Headers $headers

    # Return immediately. The native prompt is shown and answerable; Home Assistant is
    # a parallel input the daemon feeds in.
    Write-AllowDecision
}
catch {
    try {
        Write-DecisionBridgeLog -Message "route v3 failed: $($_.Exception.Message)"
    }
    catch {
        # The native ask_user dialog remains the fail-open response path.
    }
    Write-AllowDecision
}
