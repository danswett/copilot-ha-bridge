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

    $core = Join-Path $HOME '.copilot\hooks'
    . (Join-Path $core 'decision-bridge-common.ps1')
    . (Join-Path $core 'decision-mqtt.ps1')
    . (Join-Path $core 'decision-ha-websocket.ps1')

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

    # Probe before committing to network work: a host that is gone is detected in
    # about a second, and the daemon reconciles whatever this misses.
    if ($eventName -eq 'SessionEnd') {
        # Nothing below applies to SessionEnd, and its three second budget is better
        # spent returning promptly than probing.
        Exit-Silently
    }
    if (-not (Test-HomeAssistantReachable -TimeoutSec 2)) {
        Write-DecisionBridgeLog -Message 'Home Assistant unreachable; skipping (the daemon will catch up)'
        Exit-Silently
    }
    Set-DecisionBridgeDeadline -Seconds 45

    $headers = Get-HomeAssistantHeaders
    $display = Get-CodexSessionDisplay -SessionId $sessionId -WorkingDirectory $workingDirectory
    $node = Get-CopilotMqttNodeId -SessionId $sessionId

    if ($eventName -eq 'SessionEnd') {
        # Deliberately no Home Assistant work here. Codex clamps SessionEnd hooks to
        # three seconds, which is not enough to retire a session's entities - several
        # publishes plus a dashboard rebuild - and a cleanup cut off halfway leaves a
        # card behind, which is exactly what happened before this was moved.
        #
        # The registration above is already marked ended, and the daemon retires the
        # entities on its next reconcile, where there is time to do it properly.
        Exit-Silently
    }

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

    Set-CopilotMqttStatus -SessionId $sessionId -Status $status -Headers $headers -Attributes @{
        session    = $display.Name
        machine    = $display.Machine
        model      = (Get-EventField 'model')
        process_id = (Get-CodexOwningProcessId)
        updated    = [DateTimeOffset]::Now.ToString('o')
    }
    if ($activity) {
        Set-CopilotMqttActivity -SessionId $sessionId -Summary $activity `
            -Detail @{ session = $display.Name; machine = $display.Machine } -Headers $headers
    }

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

        $title = "Approval needed: $($display.Name)"
        if ($title.Length -gt 190) { $title = $title.Substring(0, 187) + '...' }
        Send-BridgeNotification -Title $title -Message $question -Headers $headers
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

    if ($eventName -eq 'Stop' -and $response) {
        $preview = $response
        if ($preview.Length -gt 880) {
            $preview = $preview.Substring(0, 880).TrimEnd() + "...`n`nFull response is on the dashboard."
        }
        $title = "Response: $($display.Name)"
        if ($title.Length -gt 190) { $title = $title.Substring(0, 187) + '...' }
        Send-BridgeNotification -Title $title -Message $preview -Headers $headers
    }

    Exit-Silently
}
catch {
    try { Write-DecisionBridgeLog -Message "codex hook failed: $($_.Exception.Message)" } catch { }
    Exit-Silently
}
