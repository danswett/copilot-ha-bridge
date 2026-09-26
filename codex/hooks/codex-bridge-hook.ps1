<#
    Codex CLI bridge hook.

    One script handles every event, dispatching on hook_event_name. Codex identifies
    the event in its payload, so a single trusted entry point is simpler to install
    and - because each hook has to be trusted individually - means one approval rather
    than five.

      SessionStart      publish the session's card
      UserPromptSubmit  mark it working, show the prompt
      PreToolUse        show the running tool; surface a command awaiting approval
      Stop              mark it idle, publish the reply, push a notification
      SessionEnd        retire the card

    It writes nothing to stdout. A Codex hook can return JSON to allow, deny or ask,
    and emitting anything unexpected risks altering a decision Codex should own, so
    staying silent guarantees the bridge cannot change what Codex does.

    Fail-open throughout: any error exits 0, because a bridge fault must never stop
    Codex from running.
#>

$ErrorActionPreference = 'Stop'

function Exit-Silently { exit 0 }

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

    . (Join-Path $PSScriptRoot 'codex-session.ps1')

    $core = Join-Path $HOME '.agent-ha-bridge\hooks'
    . (Join-Path $core 'decision-bridge-common.ps1')
    . (Join-Path $core 'decision-mqtt.ps1')
    . (Join-Path $core 'decision-ha-websocket.ps1')
    . (Join-Path $core 'bridge-adapter.ps1')

    $event = Get-CodexHookEvent
    if ($null -eq $event) { Exit-Silently }

    $sessionId = [string]$event.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { Exit-Silently }
    $eventName = [string]$event.hook_event_name
    $workingDirectory = [string]$event.cwd

    function Get-EventField {
        param([string]$Name)
        if ($event.PSObject.Properties.Name -contains $Name) { return [string]$event.$Name }
        ''
    }

    # Work out what this event means for the card before touching the network.
    $status = ''
    $activity = ''
    $response = ''
    $pendingApproval = $false
    switch ($eventName) {
        'SessionStart' { $status = 'idle'; $activity = 'Session started' }
        'UserPromptSubmit' {
            $status = 'working'
            $prompt = Get-EventField 'prompt'
            if ($prompt.Length -gt 160) { $prompt = $prompt.Substring(0, 157) + '...' }
            $activity = if ($prompt) { "Prompt: $prompt" } else { 'Working' }
        }
        'PermissionRequest' {
            # Codex runs this before showing its own approval UI, and an empty stdout
            # means "no decision", so the terminal prompt still appears. The card is
            # therefore a second way to answer rather than a replacement, which is the
            # same dual-input arrangement the Copilot bridge uses for ask_user.
            $status = 'waiting'
            $pendingApproval = $true
            $tool = Get-EventField 'tool_name'
            $activity = "Needs approval: $tool"
            if ($event.PSObject.Properties.Name -contains 'tool_input' -and
                $event.tool_input -and
                $event.tool_input.PSObject.Properties.Name -contains 'command') {
                $command = [string]$event.tool_input.command
                if ($command.Length -gt 300) { $command = $command.Substring(0, 297) + '...' }
                if ($command) { $activity = "Needs approval: $command" }
            }
        }
        'PreToolUse' {
            $status = 'working'
            $tool = Get-EventField 'tool_name'
            $activity = if ($tool) { "Running: $tool" } else { 'Running a tool' }
            # A command is the one tool detail worth showing: it is what you would
            # want to see before approving something from a phone.
            if ($event.PSObject.Properties.Name -contains 'tool_input' -and
                $event.tool_input -and
                $event.tool_input.PSObject.Properties.Name -contains 'command') {
                $command = [string]$event.tool_input.command
                if ($command.Length -gt 200) { $command = $command.Substring(0, 197) + '...' }
                if ($command) { $activity = "$activity - $command" }
            }
        }
        'Stop' {
            $status = 'idle'
            $response = Get-EventField 'last_assistant_message'
            $activity = if ($response) { $response } else { 'Idle' }
        }
        'SessionEnd' { $status = 'ended' }
        default { Exit-Silently }
    }

    # Local state first, so a Home Assistant outage cannot lose the session record.
    Write-CodexSessionRegistration -SessionId $sessionId `
        -TranscriptPath (Get-EventField 'transcript_path') `
        -WorkingDirectory $workingDirectory `
        -Model (Get-EventField 'model') `
        -Status $status -Activity $activity `
        -ProcessId (Get-CodexOwningProcessId) `
        -Ended:($eventName -eq 'SessionEnd') | Out-Null

    Write-DecisionBridgeLog -Message (
        "codex ${eventName}: session=$($sessionId.Substring(0,[Math]::Min(8,$sessionId.Length))) status=$status"
    )

    # A hook must never wait on the network; the daemon reconciles whatever a miss
    # leaves behind. SessionEnd is special: Codex clamps it to three seconds, not
    # enough to retire a session's entities without leaving a card behind, so the
    # registration above is already marked ended and the daemon retires it on the next
    # reconcile.
    if ($eventName -eq 'SessionEnd') { Exit-Silently }

    $headers = Enter-BridgeAdapterSession
    if (-not $headers) { Exit-Silently }
    $display = Get-CodexSessionDisplay -SessionId $sessionId -WorkingDirectory $workingDirectory
    $node = Get-CopilotMqttNodeId -SessionId $sessionId

    [void](Confirm-BridgeSessionEntities -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Headers $headers)

    Publish-BridgeSessionStatus -SessionId $sessionId -SessionName $display.Name `
        -Machine $display.Machine -Headers $headers -Status $status -Activity $activity `
        -ExtraAttributes @{ model = (Get-EventField 'model'); process_id = (Get-CodexOwningProcessId) }

    if ($pendingApproval) {
        # Arm the selector so the command can be approved from the dashboard. The
        # marker is the daemon's gate: while it exists, an answer on the card is
        # delivered into the session's own approval prompt.
        $decisionId = "$node-$([DateTimeOffset]::Now.ToUnixTimeMilliseconds())"
        $question = $activity
        $choices = @('Approve', 'Deny')
        Set-CopilotMqttDecision -SessionId $sessionId -SessionName $display.Name `
            -Machine $display.Machine -Question $question -Choices $choices `
            -Fields @() -DecisionId $decisionId -Headers $headers | Out-Null
        Write-CodexApprovalMarker -SessionId $sessionId -DecisionId $decisionId -Question $question

        Send-BridgeNotification -Title (Format-BridgeNotificationTitle "Approval needed: $($display.Name)") `
            -Message $question -Headers $headers
    }
    elseif ($eventName -in @('PreToolUse', 'Stop')) {
        # Whatever was awaiting approval has been answered - in the terminal or on the
        # dashboard - because the tool is now running or the turn has finished.
        if (Remove-CodexApprovalMarker -SessionId $sessionId) {
            try {
                Clear-CopilotMqttDecision -SessionId $sessionId -SessionName $display.Name `
                    -Machine $display.Machine -Headers $headers
            }
            catch { }
        }
    }

    if ($eventName -eq 'Stop') {
        Send-BridgeResponseNotification -SessionName $display.Name -Response $response -Headers $headers
    }

    Exit-Silently
}
catch {
    try { Write-DecisionBridgeLog -Message "codex hook failed: $($_.Exception.Message)" } catch { }
    Exit-Silently
}
