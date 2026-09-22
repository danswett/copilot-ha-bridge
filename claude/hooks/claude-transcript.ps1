<#
.SYNOPSIS
    Reduces Claude Code transcript lines to the bridge's activity shape.

.DESCRIPTION
    A Claude Code transcript is JSON Lines under ~/.claude/projects/<slug>/<id>.jsonl.
    Each line carries parentUuid, isSidechain, userType, cwd, sessionId, gitBranch,
    type, message, uuid and timestamp, with toolUseResult on tool-result entries and
    isMeta on housekeeping ones. Those field names were read out of the shipping
    claude.exe 2.1.215.

    An assistant message's content is either a plain string or an array of blocks:
    text, thinking, tool_use and tool_result. `thinking` is what makes chain-of-thought
    streaming possible for Claude, the same as reasoningText does for Copilot.

    Output deliberately matches Get-ActivityFromEvents in the daemon:

        @{ Summary; Reasoning; Response; Status; History }

    Note on idle: Claude has no turn-end transcript entry, so idle is not inferred
    here. The Stop hook is the authoritative end-of-turn signal and sets it directly;
    anything appearing in the transcript means the session is working.
#>

Set-StrictMode -Version Latest

function Get-ClaudeContentBlocks {
    <#
        Normalises message.content, which is a bare string for simple messages and an
        array of typed blocks otherwise.
    #>
    param([AllowNull()]$Message)

    if ($null -eq $Message) { return @() }
    if ($Message.PSObject.Properties.Name -notcontains 'content') { return @() }
    $content = $Message.content
    if ($null -eq $content) { return @() }
    if ($content -is [string]) {
        return @([pscustomobject]@{ type = 'text'; text = $content })
    }
    @($content)
}

function Get-ClaudeActivityFromTranscript {
    <#
        Reduces a batch of transcript lines to the current activity plus a short
        rolling history.

        Reasoning is captured regardless of the verbose toggle, matching the daemon:
        capture and display are decoupled so flipping the toggle can reveal the latest
        thinking immediately instead of waiting for the model to think again.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [bool]$VerboseMode = $false
    )

    $summary = $null
    $reasoning = $null
    $response = $null
    $status = $null
    $history = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $entry = try { $line | ConvertFrom-Json } catch { $null }
        if ($null -eq $entry) { continue }

        # Sidechain entries belong to sub-agents, and meta entries are housekeeping;
        # neither is the session's own visible activity.
        if ($entry.PSObject.Properties.Name -contains 'isSidechain' -and $entry.isSidechain) { continue }
        if ($entry.PSObject.Properties.Name -contains 'isMeta' -and $entry.isMeta) { continue }

        $type = [string]$entry.type

        if ($type -eq 'user') {
            $blocks = Get-ClaudeContentBlocks -Message $entry.message
            $isToolResult = @($blocks | Where-Object { $_.type -eq 'tool_result' }).Count -gt 0
            if (-not $isToolResult) {
                $status = 'working'
                $summary = 'Reading your message'
                $history.Add($summary)
            }
            continue
        }

        if ($type -ne 'assistant') { continue }

        $status = 'working'
        foreach ($block in (Get-ClaudeContentBlocks -Message $entry.message)) {
            switch ([string]$block.type) {
                'tool_use' {
                    $tool = [string]$block.name
                    if (-not [string]::IsNullOrWhiteSpace($tool)) {
                        $summary = "Running: $tool"
                        $history.Add($summary)
                    }
                }
                'thinking' {
                    $text = [string]$block.thinking
                    if (-not [string]::IsNullOrWhiteSpace($text)) { $reasoning = $text.Trim() }
                }
                'text' {
                    $text = [string]$block.text
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        $first = (($text -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
                        if ($first) {
                            $summary = $first.Trim()
                            $history.Add($summary)
                        }
                        $response = $text.Trim()
                    }
                }
            }
        }
    }

    [pscustomobject]@{
        Summary   = $summary
        Reasoning = $reasoning
        Response  = $response
        Status    = $status
        History   = @($history)
    }
}

function Read-ClaudeTranscriptAppend {
    <#
        Reads the bytes appended since the last offset.

        Mirrors the daemon's reader: a capped tail so a session that produced a huge
        burst cannot stall the loop, and a reset when the file shrinks, which means it
        was rotated or rewritten.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$Offset = 0,
        [int]$MaxTailBytes = 512000
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Lines = @(); Offset = 0 }
    }

    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -lt $Offset) { $Offset = 0 }
    if ($length -eq $Offset) {
        return [pscustomobject]@{ Lines = @(); Offset = $Offset }
    }

    $start = $Offset
    if (($length - $start) -gt $MaxTailBytes) { $start = $length - $MaxTailBytes }

    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$stream.Seek($start, 'Begin')
        $buffer = New-Object byte[] ($length - $start)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    }
    finally {
        $stream.Dispose()
    }

    # A trailing partial line is left for the next pass by rewinding the offset, so a
    # line is never parsed half-written.
    $lines = $text -split "`n"
    $trailing = 0
    if (-not $text.EndsWith("`n") -and $lines.Count -gt 0) {
        $trailing = [Text.Encoding]::UTF8.GetByteCount($lines[-1])
        # When the batch is nothing but a partial line there is no complete line to
        # return; slicing would otherwise hand back the fragment itself.
        $lines = if ($lines.Count -ge 2) { $lines[0..($lines.Count - 2)] } else { @() }
    }

    [pscustomobject]@{
        Lines  = @($lines | Where-Object { $_.Trim() })
        Offset = $length - $trailing
    }
}
