#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the Codex adapter: hook event handling and the rollout reducer.

.DESCRIPTION
    The hook fixtures are real payloads captured from Codex 0.155.0-alpha.6.

    The rollout fixture is not. Its envelope - `{timestamp, ordinal, type, payload}`
    with `event_msg` / `item_completed` / `item.type` - matches real captured data,
    but its `Reasoning` item is synthetic, because no model has been observed emitting
    one: across 26 real rollouts, including runs with `model_reasoning_effort=high`
    and `model_reasoning_summary=detailed`, only AgentMessage, UserMessage and
    CommandExecution ever appeared. The item is modelled on the `Reasoning` variant
    declared in codex-rs `ThreadItemDetails`, which holds `{ text }`.

    These tests therefore prove the reducer honours the documented contract. They do
    not prove Codex emits reasoning. That distinction is deliberate and is repeated in
    the adapter README.

    Needs no Home Assistant and no Codex session.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Loaded exactly as the hook loads it: template sanitisation lives in the shared
# module, and codex-session defers to it when present.
$core = Join-Path $HOME '.copilot\hooks\decision-bridge-common.ps1'
if (Test-Path -LiteralPath $core) { . $core }
else { . (Join-Path $PSScriptRoot '..\..\hooks\decision-bridge-common.ps1') }

. (Join-Path $PSScriptRoot '..\hooks\codex-session.ps1')
. (Join-Path $PSScriptRoot '..\hooks\codex-transcript.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

$fixtures = Join-Path $PSScriptRoot '..\fixtures'

Write-Host '--- real hook payloads ---'
foreach ($case in @(
    @{ File = 'sessionstart.json'; Event = 'SessionStart'; Fields = @('session_id', 'transcript_path', 'cwd', 'model', 'permission_mode', 'source') }
    @{ File = 'userpromptsubmit.json'; Event = 'UserPromptSubmit'; Fields = @('session_id', 'turn_id', 'prompt') }
    @{ File = 'pretooluse.json'; Event = 'PreToolUse'; Fields = @('tool_name', 'tool_input', 'tool_use_id') }
    @{ File = 'stop.json'; Event = 'Stop'; Fields = @('stop_hook_active', 'last_assistant_message') }
    @{ File = 'sessionend.json'; Event = 'SessionEnd'; Fields = @('session_id', 'reason') }
)) {
    $event = Get-CodexHookEvent -Raw (Get-Content (Join-Path $fixtures $case.File) -Raw)
    Test-That "$($case.Event) parses" { $event.hook_event_name -eq $case.Event } (($event.hook_event_name) ?? 'null')
    foreach ($field in $case.Fields) {
        Test-That "$($case.Event) carries $field" { $event.PSObject.Properties.Name -contains $field }
    }
}

Write-Host '--- session naming ---'
Test-That 'a session is named after its working directory' {
    (Get-CodexSessionDisplay -SessionId 'abc123' -WorkingDirectory 'C:\repos\my-project').Name -eq 'Codex: my-project'
}
Test-That 'a missing directory falls back to the id' {
    (Get-CodexSessionDisplay -SessionId '01a0cb31aaaa' -WorkingDirectory '').Name -eq 'Codex: 01a0cb31'
}
Test-That 'template syntax in a folder name is neutralised' {
    (Get-CodexSessionDisplay -SessionId 'abc' -WorkingDirectory 'C:\repos\{{ states(''sun.sun'') }}').Name -notmatch '\{\{'
}

Write-Host '--- session ids used as paths ---'
foreach ($candidate in @('../../evil', 'a/b', '', 'C:\Windows')) {
    Test-That "path-safe: '$candidate'" {
        (Get-CodexSafeSessionKey -SessionId $candidate) -notmatch '[\\/]'
    } (Get-CodexSafeSessionKey -SessionId $candidate)
}

Write-Host '--- approval markers ---'
$sessionId = 'test-approval-0001'
try {
    Test-That 'no marker to begin with' { $null -eq (Get-CodexApprovalMarker -SessionId $sessionId) }
    Write-CodexApprovalMarker -SessionId $sessionId -DecisionId 'd1' -Question 'Needs approval: rm -rf /'
    $marker = Get-CodexApprovalMarker -SessionId $sessionId
    Test-That 'a marker round-trips' { $marker.DecisionId -eq 'd1' -and $marker.Question -match 'rm -rf' }
    Test-That 'removing reports that it removed something' { Remove-CodexApprovalMarker -SessionId $sessionId }
    Test-That 'removing again reports nothing to remove' { -not (Remove-CodexApprovalMarker -SessionId $sessionId) }

    # The bug this guards: approval markers live beside registrations and also end in
    # .json, so the registration reader parsed them as registrations. The missing
    # fields threw under StrictMode and took down the daemon's whole reconcile.
    Write-CodexApprovalMarker -SessionId $sessionId -DecisionId 'd2' -Question 'q'
    Test-That 'a marker is not mistaken for a registration' {
        # The assertion is that this completes at all: before the fix it threw on the
        # marker's missing fields, and that exception propagated out of the daemon's
        # reconcile.
        $null = @(Get-CodexSessionRegistrations -IncludeEnded)
        $true
    }
    Test-That 'the marker survives a registration scan' {
        $null -ne (Get-CodexApprovalMarker -SessionId $sessionId)
    }
}
finally {
    Remove-CodexApprovalMarker -SessionId $sessionId | Out-Null
}

Write-Host '--- rollout reducer (contract, not observed behaviour) ---'
$lines = @(Get-Content (Join-Path $fixtures 'rollout-with-reasoning.jsonl') | Where-Object { $_.Trim() })
Test-That 'the latest reasoning wins' {
    (Get-CodexReasoningFromTranscript -Lines $lines) -eq 'Double-checked the arithmetic.'
} (Get-CodexReasoningFromTranscript -Lines $lines)
Test-That 'agent messages are not treated as reasoning' {
    (Get-CodexReasoningFromTranscript -Lines $lines) -notmatch '391\.$'
}
Test-That 'a rollout with no reasoning yields nothing' {
    $none = @($lines | Where-Object { $_ -notmatch 'Reasoning' })
    $null -eq (Get-CodexReasoningFromTranscript -Lines $none)
}
Test-That 'malformed lines are skipped' {
    $null -eq (Get-CodexReasoningFromTranscript -Lines @('{bad', ''))
}
Test-That 'an empty batch is safe' {
    $null -eq (Get-CodexReasoningFromTranscript -Lines @())
}

Write-Host '--- tailing reader ---'
$temp = Join-Path ([IO.Path]::GetTempPath()) "codex-rollout-$([guid]::NewGuid().ToString('N').Substring(0,8)).jsonl"
try {
    Copy-Item (Join-Path $fixtures 'rollout-with-reasoning.jsonl') $temp
    $first = Read-CodexTranscriptAppend -Path $temp -Offset 0
    Test-That 'a first read returns every line' { $first.Lines.Count -eq $lines.Count } "$($first.Lines.Count)"
    $second = Read-CodexTranscriptAppend -Path $temp -Offset $first.Offset
    Test-That 'a second read returns nothing new' { $second.Lines.Count -eq 0 }

    [IO.File]::AppendAllText($temp, '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","id":"r3","text":"later thought"}}}' + "`n")
    $third = Read-CodexTranscriptAppend -Path $temp -Offset $second.Offset
    Test-That 'only the appended line is returned' { $third.Lines.Count -eq 1 } "$($third.Lines.Count)"
    Test-That 'the appended reasoning is read' {
        (Get-CodexReasoningFromTranscript -Lines $third.Lines) -eq 'later thought'
    }

    [IO.File]::AppendAllText($temp, '{"type":"event_msg","payload":{"type":"item_comp')
    $partial = Read-CodexTranscriptAppend -Path $temp -Offset $third.Offset
    Test-That 'a partial trailing line is withheld' { $partial.Lines.Count -eq 0 } "$($partial.Lines.Count)"

    Set-Content -LiteralPath $temp -Value '{"type":"event_msg","payload":{"type":"task_started"}}'
    $shrunk = Read-CodexTranscriptAppend -Path $temp -Offset 999999
    Test-That 'a shrinking file resets the offset' { $shrunk.Lines.Count -eq 1 } "$($shrunk.Lines.Count)"

    Test-That 'a missing file is handled' { (Read-CodexTranscriptAppend -Path 'C:\nope.jsonl').Lines.Count -eq 0 }
    Test-That 'an empty path is handled' { (Read-CodexTranscriptAppend -Path '').Lines.Count -eq 0 }
}
finally {
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
