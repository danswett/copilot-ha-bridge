<#
.SYNOPSIS
    Reduces a Codex rollout transcript to the reasoning the hooks cannot provide.

.DESCRIPTION
    The Codex hooks carry everything the card normally needs - the prompt, each tool
    call, the final reply - so this exists for one thing only: chain-of-thought.

    A rollout lives at the `transcript_path` every hook reports:

        ~/.codex/sessions/<yyyy>/<MM>/<dd>/rollout-<timestamp>-<session_id>.jsonl

    Each line is `{timestamp, ordinal, type, payload}`. Reasoning arrives as an
    `event_msg` whose payload is an `item_completed` carrying a thread item, and
    `ThreadItemDetails` in codex-rs declares a `Reasoning` variant holding `{ text }`
    alongside `AgentMessage`, `CommandExecution` and the rest.

    IMPORTANT, and the reason this is gated rather than assumed: no model has been
    observed emitting one. Across 26 rollouts captured on 0.155.0-alpha.6, including
    sessions run with `model_reasoning_effort=high` and
    `model_reasoning_summary=detailed`, only AgentMessage, UserMessage and
    CommandExecution ever appeared. The handling below is written to the protocol's
    own contract and will work the moment a model emits reasoning, but it has never
    run against a real one. Everything else the Codex adapter does is verified live;
    this is the exception, and it is deliberately additive - if no reasoning is
    present the card is exactly as it was.
#>

Set-StrictMode -Version Latest

function Get-CodexReasoningFromTranscript {
    <#
        Returns the most recent reasoning text in a batch of rollout lines, or $null.

        Only reasoning is extracted. Status, activity and the final response all come
        from hooks, which report them sooner and more reliably than a transcript tail.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
    )

    $reasoning = $null
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Cheap pre-filter: most lines are messages or token counts.
        if ($line -notmatch 'Reasoning') { continue }

        $entry = try { $line | ConvertFrom-Json } catch { $null }
        if ($null -eq $entry) { continue }
        if ([string]$entry.type -ne 'event_msg') { continue }

        $payload = $entry.payload
        if ($null -eq $payload) { continue }
        if ($payload.PSObject.Properties.Name -notcontains 'item') { continue }

        $item = $payload.item
        if ($null -eq $item -or $item.PSObject.Properties.Name -notcontains 'type') { continue }
        if ([string]$item.type -ne 'Reasoning') { continue }

        # ReasoningItem is { text }, but tolerate a content array in case the rollout
        # serialisation differs from the exec event stream, as it already does for
        # casing.
        $text = ''
        if ($item.PSObject.Properties.Name -contains 'text') {
            $text = [string]$item.text
        }
        elseif ($item.PSObject.Properties.Name -contains 'content') {
            $text = (@($item.content) | ForEach-Object {
                if ($_ -is [string]) { $_ } elseif ($_.PSObject.Properties.Name -contains 'text') { [string]$_.text }
            }) -join "`n"
        }

        if (-not [string]::IsNullOrWhiteSpace($text)) { $reasoning = $text.Trim() }
    }

    $reasoning
}

function Read-CodexTranscriptAppend {
    <#
        Reads the bytes appended since the last offset.

        Mirrors the other adapters' readers: a capped tail so a burst cannot stall the
        loop, a reset when the file shrinks, and a partial trailing line withheld until
        it is complete so a half-written line is never parsed.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [long]$Offset = 0,
        [int]$MaxTailBytes = 512000
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Lines = @(); Offset = 0 }
    }

    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -lt $Offset) { $Offset = 0 }
    if ($length -eq $Offset) { return [pscustomobject]@{ Lines = @(); Offset = $Offset } }

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

    $lines = $text -split "`n"
    $trailing = 0
    if (-not $text.EndsWith("`n") -and $lines.Count -gt 0) {
        $trailing = [Text.Encoding]::UTF8.GetByteCount($lines[-1])
        $lines = if ($lines.Count -ge 2) { $lines[0..($lines.Count - 2)] } else { @() }
    }

    [pscustomobject]@{
        Lines  = @($lines | Where-Object { $_.Trim() })
        Offset = $length - $trailing
    }
}
