<#
    Mirrors a completed Copilot turn to Home Assistant as a notification.

    The session card on the dashboard already carries the full response - the bridge
    daemon streams it there from the transcript - so this hook only sends the optional
    out-of-band push, and is a no-op when notifications are disabled.

    It is deliberately non-blocking. An earlier design held the turn open here to carry
    a dashboard reply back as the next prompt, which deadlocked: while the hook blocks,
    the CLI queues anything typed in the terminal, so the escape signal it was waiting
    for could never arrive. Continuation is now the daemon's job, delivered by writing
    to the session's console.
#>

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'decision-bridge-common.ps1')

    $rawEvent = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawEvent)) {
        Write-Output '{}'
        exit 0
    }

    $event = $rawEvent | ConvertFrom-Json
    $sessionId = [string]$event.sessionId
    $transcriptPath = [string]$event.transcriptPath
    if (
        [string]::IsNullOrWhiteSpace($transcriptPath) -or
        -not (Test-Path -LiteralPath $transcriptPath)
    ) {
        $transcriptPath = Join-Path (
            Join-Path $script:DecisionBridgeConfig.SessionStateRoot $sessionId
        ) 'events.jsonl'
    }
    if (-not (Test-Path -LiteralPath $transcriptPath)) {
        Write-Output '{}'
        exit 0
    }

    # Last assistant message with content is the response that just finished.
    $response = $null
    foreach ($line in @(Get-CopilotTranscriptTailLines -Path $transcriptPath)) {
        if (-not $line.StartsWith('{"type":"assistant.message"')) { continue }
        try {
            $content = [string]($line | ConvertFrom-Json).data.content
            if (-not [string]::IsNullOrWhiteSpace($content)) { $response = $content.Trim() }
        }
        catch { continue }
    }
    if ([string]::IsNullOrWhiteSpace($response)) {
        Write-Output '{}'
        exit 0
    }

    $display = Get-CopilotSessionDisplay -SessionId $sessionId -WorkingDirectory ([string]$event.cwd)

    # Push payloads cap well below a typical CLI response, so send a preview and let
    # the dashboard card carry the full text.
    $preview = $response
    if ($preview.Length -gt 880) {
        $preview = $preview.Substring(0, 880).TrimEnd() + "...`n`nFull response is on the Copilot Decisions dashboard."
    }
    $title = "Copilot response: $($display.Name)"
    if ($title.Length -gt 190) { $title = $title.Substring(0, 187) + '...' }

    Send-BridgeNotification -Title $title -Message $preview -Headers (Get-HomeAssistantHeaders)
}
catch {
    try {
        Write-DecisionBridgeLog -Message "response notification failed: $($_.Exception.Message)"
    }
    catch {
        # Response delivery must not affect the completed CLI turn.
    }
}

Write-Output '{}'