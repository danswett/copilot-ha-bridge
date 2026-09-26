<#
    Turn-end handling for Claude Code.

    Registered as a Stop hook. Claude has no turn-end entry in its transcript, so this
    is the authoritative end-of-turn signal: it marks the session idle, refreshes the
    session registration so the daemon still considers it live, and sends the optional
    out-of-band push with a preview of the response.

    The dashboard card already carries the full response - the daemon streams it from
    the transcript - so only a preview is pushed.

    It writes nothing to stdout. A Stop hook may return a block decision to force the
    model to continue; staying silent guarantees the turn ends exactly as Claude
    intended.
#>

$ErrorActionPreference = 'Stop'

function Exit-Silently { exit 0 }

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

    . (Join-Path $PSScriptRoot 'claude-ask-parser.ps1')
    . (Join-Path $PSScriptRoot 'claude-session.ps1')
    . (Join-Path $PSScriptRoot 'claude-transcript.ps1')

    $core = Join-Path $HOME '.agent-ha-bridge\hooks'
    . (Join-Path $core 'decision-bridge-common.ps1')
    . (Join-Path $core 'decision-mqtt.ps1')
    . (Join-Path $core 'bridge-adapter.ps1')

    $event = Get-ClaudeHookEvent
    if ($null -eq $event) { Exit-Silently }

    $sessionId = [string]$event.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { Exit-Silently }

    $transcriptPath = Resolve-ClaudeTranscriptPath -SessionId $sessionId `
        -KnownPath ([string]$event.transcript_path)

    # Keeps the registration fresh, and recovers the owning pid if an earlier event
    # could not resolve it.
    Write-ClaudeSessionRegistration -SessionId $sessionId -TranscriptPath $transcriptPath `
        -WorkingDirectory ([string]$event.cwd) -ProcessId (Get-ClaudeOwningProcessId) | Out-Null

    # The turn has already ended, so a miss here costs nothing - the daemon reconciles
    # it. Enter-BridgeAdapterSession returns headers when reachable, or $null when not.
    $headers = Enter-BridgeAdapterSession
    if (-not $headers) { Exit-Silently }
    $display = Get-ClaudeSessionDisplay -SessionId $sessionId -WorkingDirectory ([string]$event.cwd)

    # Only touch entities that already exist. A turn can end in a session that never
    # asked anything, and publishing a card for it here would create clutter the
    # daemon is responsible for.
    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $exists = Test-BridgeSessionEntityPresent -EntityId "sensor.${node}_status" -Headers $headers

    $response = $null
    # Claude hands the finished reply to the Stop hook directly as
    # last_assistant_message - confirmed on a real session - which is both cheaper and
    # more accurate than re-reading the transcript. The transcript stays as a fallback
    # for older builds that do not send it.
    if ($event.PSObject.Properties.Name -contains 'last_assistant_message' -and
        -not [string]::IsNullOrWhiteSpace([string]$event.last_assistant_message)) {
        $response = ([string]$event.last_assistant_message).Trim()
    }
    elseif ($transcriptPath) {
        $tail = Read-ClaudeTranscriptAppend -Path $transcriptPath -Offset 0
        $activity = Get-ClaudeActivityFromTranscript -Lines $tail.Lines
        $response = $activity.Response
    }

    if ($exists) {
        Publish-BridgeSessionStatus -SessionId $sessionId -SessionName $display.Name `
            -Machine $display.Machine -Headers $headers -Status 'idle' -Activity ([string]$response)
    }

    Send-BridgeResponseNotification -SessionName $display.Name -Response ([string]$response) -Headers $headers

    Write-DecisionBridgeLog -Message (
        "claude Stop: session=$($sessionId.Substring(0,[Math]::Min(8,$sessionId.Length))) " +
        "entities=$exists responseChars=$(($response ?? '').Length)"
    )

    Exit-Silently
}
catch {
    try { Write-DecisionBridgeLog -Message "claude stop hook failed: $($_.Exception.Message)" } catch { }
    Exit-Silently
}
