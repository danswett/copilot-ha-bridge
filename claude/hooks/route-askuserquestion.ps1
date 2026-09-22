<#
    AskUserQuestion routing for Claude Code — dual-input, non-blocking.

    Registered as a PreToolUse hook matching AskUserQuestion. When Claude asks a
    question this hook:
      1. Records the session, its transcript and its owning pid.
      2. Ensures the session's Home Assistant entities exist.
      3. Arms the decision card with the question and its options.
      4. Sends an optional push notification.
      5. Writes a pending-decision marker for the daemon.
      6. Exits silently so Claude's own prompt appears untouched.

    It deliberately produces no stdout. A PreToolUse hook can return
    hookSpecificOutput.permissionDecision to allow or deny, but AskUserQuestion is not
    permission-gated and its whole purpose is to prompt; staying silent is the only
    response that guarantees the native prompt is unaffected.

    Answering works the same way as the Copilot bridge: the terminal prompt remains the
    source of truth, and the daemon injects a Home Assistant answer into that same
    prompt. Whichever is used first wins.

    Fail-open throughout: any error exits 0 silently, so a bridge problem can never
    stop Claude from asking.
#>

$ErrorActionPreference = 'Stop'

function Exit-Silently { exit 0 }

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

    . (Join-Path $PSScriptRoot 'claude-ask-parser.ps1')
    . (Join-Path $PSScriptRoot 'claude-session.ps1')

    # The shared Home Assistant layer is installed with the main bridge.
    $core = Join-Path $HOME '.copilot\hooks'
    . (Join-Path $core 'decision-bridge-common.ps1')
    . (Join-Path $core 'decision-mqtt.ps1')
    . (Join-Path $core 'decision-ha-websocket.ps1')

    $event = Get-ClaudeHookEvent
    if ($null -eq $event) { Exit-Silently }
    if ([string]$event.tool_name -ne 'AskUserQuestion') { Exit-Silently }

    $sessionId = [string]$event.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = "claude-$PID" }
    $workingDirectory = [string]$event.cwd

    $parsed = ConvertFrom-ClaudeAskUserQuestion -ToolInput $event.tool_input
    $question = $parsed.Question
    $choices = @($parsed.Choices)
    $fields = @($parsed.Fields)
    $mode = if ($choices.Count -gt 0 -or $fields.Count -gt 0) { 'multiple_choice' } else { 'freeform' }

    $owningPid = Get-ClaudeOwningProcessId
    Write-ClaudeSessionRegistration -SessionId $sessionId `
        -TranscriptPath (Resolve-ClaudeTranscriptPath -SessionId $sessionId -KnownPath ([string]$event.transcript_path)) `
        -WorkingDirectory $workingDirectory -ProcessId $owningPid | Out-Null

    $decisionId = "$(Get-CopilotMqttNodeId -SessionId $sessionId)-$([DateTimeOffset]::Now.ToUnixTimeMilliseconds())"

    # Local state first, before anything that can block. If Home Assistant is slow or
    # down, the hook still returns promptly and the daemon arms the card from this
    # marker once it can reach Home Assistant again.
    Write-CopilotDecisionMarker -SessionId $sessionId -DecisionId $decisionId `
        -Question $question -Choices $choices -Combos @() -Fields $fields -Mode $mode

    Write-DecisionBridgeLog -Message (
        "claude AskUserQuestion: session=$($sessionId.Substring(0,[Math]::Min(8,$sessionId.Length))) " +
        "pid=$owningPid choices=$($choices.Count) fields=$($fields.Count) mode=$mode"
    )

    # Probe before committing to any Home Assistant work: Claude's own prompt must not wait on the network.
    # A host that is gone is detected in about a second; one that answers gets a
    # budget generous enough for discovery, the registry rename and arming.
    if (-not (Test-HomeAssistantReachable -TimeoutSec 2)) {
        Write-DecisionBridgeLog -Message 'Home Assistant unreachable; skipping (the daemon will catch up)'
        Exit-Silently
    }
    Set-DecisionBridgeDeadline -Seconds 45
    $headers = Get-HomeAssistantHeaders
    $display = Get-ClaudeSessionDisplay -SessionId $sessionId -WorkingDirectory $workingDirectory
    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $decisionEntity = "select.${node}_decision"

    $exists = $false
    try {
        $probe = Get-HomeAssistantState -EntityId $decisionEntity -Headers $headers
        $exists = ($null -ne $probe -and [string]$probe.state -notin @('unavailable', ''))
    }
    catch { $exists = $false }

    if (-not $exists) {
        Publish-CopilotMqttSession -SessionId $sessionId -SessionName $display.Name `
            -Machine $display.Machine -Headers $headers | Out-Null
        Start-Sleep -Milliseconds 1500
        [void](Set-CopilotMqttEntityIds -SessionId $sessionId)
    }

    Set-CopilotMqttDecision -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Question $question -Choices $choices `
        -Fields $fields -DecisionId $decisionId -Headers $headers | Out-Null


    $numbered = ''
    if ($choices.Count -gt 0) {
        $lines = for ($i = 0; $i -lt $choices.Count; $i++) { "$($i + 1). $($choices[$i])" }
        $numbered = ($lines -join "`n") + "`n"
    }

    $body = @(
        "Session: $($display.Name)"
        "Machine: $($display.Machine)"
        ''
        $question
        ''
        $numbered
        'Answer in the terminal or on the dashboard.'
    ) -join "`n"
    if ($body.Length -gt 950) { $body = $body.Substring(0, 947) + '...' }

    $title = $display.Name
    if ($title.Length -gt 190) { $title = $title.Substring(0, 187) + '...' }
    Send-BridgeNotification -Title $title -Message $body -Headers $headers

    Exit-Silently
}
catch {
    try { Write-DecisionBridgeLog -Message "claude ask router failed: $($_.Exception.Message)" } catch { }
    Exit-Silently
}
