<#
    Attention routing for Claude Code.

    Registered as a Notification hook. Claude fires this when it wants the user -
    most usefully when a tool needs permission, or when a prompt has been sitting
    unanswered - and the event carries a `message` describing what it needs.

    This matters because AskUserQuestion, the multiple-choice tool the PreToolUse
    router handles, is not exposed in every Claude build. Notification is, so this is
    what makes the adapter useful today: the card shows that the session is blocked
    and on what, a push goes out, and the reply box is there to answer with.

    Answering a permission prompt by text is best-effort. Claude's own prompt stays
    the source of truth, exactly as in the Copilot bridge, and the reply box injects
    into it; whether a given prompt accepts typed input depends on that prompt. The
    value this delivers unconditionally is knowing, away from the terminal, that a
    session has stopped and why.

    Writes nothing to stdout and always exits 0, so it can never interfere.
#>

$ErrorActionPreference = 'Stop'

function Exit-Silently { exit 0 }

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

    . (Join-Path $PSScriptRoot 'claude-ask-parser.ps1')
    . (Join-Path $PSScriptRoot 'claude-session.ps1')

    $core = Join-Path $HOME '.copilot\hooks'
    . (Join-Path $core 'decision-bridge-common.ps1')
    . (Join-Path $core 'decision-mqtt.ps1')
    . (Join-Path $core 'decision-ha-websocket.ps1')

    $event = Get-ClaudeHookEvent
    if ($null -eq $event) { Exit-Silently }

    $sessionId = [string]$event.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { Exit-Silently }

    $message = [string]$event.message
    if ([string]::IsNullOrWhiteSpace($message)) { $message = 'Claude is waiting for you.' }
    if ($message.Length -gt 600) { $message = $message.Substring(0, 597) + '...' }

    $owningPid = Get-ClaudeOwningProcessId
    Write-ClaudeSessionRegistration -SessionId $sessionId `
        -TranscriptPath (Resolve-ClaudeTranscriptPath -SessionId $sessionId -KnownPath ([string]$event.transcript_path)) `
        -WorkingDirectory ([string]$event.cwd) -ProcessId $owningPid | Out-Null

    # Probe before committing to any Home Assistant work: a notification must never delay Claude.
    # A host that is gone is detected in about a second; one that answers gets a
    # budget generous enough for discovery, the registry rename and arming.
    if (-not (Test-HomeAssistantReachable -TimeoutSec 2)) {
        Write-DecisionBridgeLog -Message 'Home Assistant unreachable; skipping (the daemon will catch up)'
        Exit-Silently
    }
    Set-DecisionBridgeDeadline -Seconds 45
    $headers = Get-HomeAssistantHeaders
    $display = Get-ClaudeSessionDisplay -SessionId $sessionId -WorkingDirectory ([string]$event.cwd)
    $node = Get-CopilotMqttNodeId -SessionId $sessionId

    # Publish on demand: a notification can be the first thing a session ever does, so
    # waiting for the daemon's reconcile would delay exactly the alert that matters.
    $exists = $false
    try {
        $probe = Get-HomeAssistantState -EntityId "sensor.${node}_status" -Headers $headers
        $exists = ($null -ne $probe -and [string]$probe.state -notin @('unavailable', ''))
    }
    catch { $exists = $false }

    if (-not $exists) {
        Publish-CopilotMqttSession -SessionId $sessionId -SessionName $display.Name `
            -Machine $display.Machine -Headers $headers | Out-Null
        Start-Sleep -Milliseconds 1500
        [void](Set-CopilotMqttEntityIds -SessionId $sessionId)
    }

    Set-CopilotMqttStatus -SessionId $sessionId -Status 'waiting' -Headers $headers -Attributes @{
        session = $display.Name
        machine = $display.Machine
        message = $message
        updated = [DateTimeOffset]::Now.ToString('o')
    }
    Set-CopilotMqttActivity -SessionId $sessionId -Summary $message `
        -Detail @{ session = $display.Name; machine = $display.Machine } -Headers $headers

    $body = @(
        "Session: $($display.Name)"
        "Machine: $($display.Machine)"
        ''
        $message
        ''
        'Answer in the terminal, or try the Reply box on the dashboard.'
    ) -join "`n"
    $title = "Waiting: $($display.Name)"
    if ($title.Length -gt 190) { $title = $title.Substring(0, 187) + '...' }
    Send-BridgeNotification -Title $title -Message $body -Headers $headers

    Write-DecisionBridgeLog -Message (
        "claude Notification: session=$($sessionId.Substring(0,[Math]::Min(8,$sessionId.Length))) " +
        "pid=$owningPid chars=$($message.Length)"
    )

    Exit-Silently
}
catch {
    try { Write-DecisionBridgeLog -Message "claude notification hook failed: $($_.Exception.Message)" } catch { }
    Exit-Silently
}
