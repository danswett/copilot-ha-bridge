#Requires -Version 7.0
<#
.SYNOPSIS
    Reliability regression tests for the bridge.

.DESCRIPTION
    Covers the behaviours that keep a bridge fault from becoming a CLI fault:

      * the request budget, which stops a hook waiting on an unreachable Home
        Assistant. Before it existed the routers took 19-34 seconds with the host
        down, and a PreToolUse hook that slow delays the very prompt the bridge
        promises never to block.
      * StrictMode safety of that budget. The deadline must be initialised, because
        reading an unset variable throws and would take the retry layer - and the
        daemon with it - down.
      * the stale-registration prune, without which the daemon's per-reconcile cost
        grows for every Claude session ever started.

    Needs no Home Assistant.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\claude\hooks\claude-session.ps1')

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

Write-Host '--- the request budget under StrictMode ---'
Test-That 'no deadline set means no limit' {
    (Get-DecisionBridgeRemainingSeconds) -eq [double]::PositiveInfinity
}
Test-That 'a deadline is honoured' {
    Set-DecisionBridgeDeadline -Seconds 5
    $remaining = Get-DecisionBridgeRemainingSeconds
    $remaining -gt 4 -and $remaining -le 5
}
Test-That 'a deadline can be cleared' {
    Set-DecisionBridgeDeadline -Seconds 0
    (Get-DecisionBridgeRemainingSeconds) -eq [double]::PositiveInfinity
}

Write-Host '--- a spent budget stops the retry loop ---'
Set-DecisionBridgeDeadline -Seconds 1
Start-Sleep -Milliseconds 1200
$elapsed = Measure-Command {
    try {
        # An address that black-holes traffic: without the budget this would retry
        # for tens of seconds.
        Invoke-DecisionHttpRequest -Parameters @{
            Method = 'Get'; Uri = 'http://192.0.2.99:8123/api/'; TimeoutSec = 30
        }
    }
    catch { }
}
Test-That 'a spent budget fails immediately' { $elapsed.TotalSeconds -lt 2 } "$([math]::Round($elapsed.TotalSeconds,2))s"

Write-Host '--- a live budget is not exceeded ---'
Set-DecisionBridgeDeadline -Seconds 3
$elapsed = Measure-Command {
    try {
        Invoke-DecisionHttpRequest -Parameters @{
            Method = 'Get'; Uri = 'http://192.0.2.99:8123/api/'; TimeoutSec = 30
        }
    }
    catch { }
}
Test-That 'a 3s budget is respected despite a 30s request timeout' {
    $elapsed.TotalSeconds -lt 6
} "$([math]::Round($elapsed.TotalSeconds,2))s"
Set-DecisionBridgeDeadline -Seconds 0

Write-Host '--- reachability probe ---'
Test-That 'an unreachable host is detected quickly' {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $result = Test-HomeAssistantReachable -TimeoutSec 2
    $sw.Stop()
    (-not $result) -or $sw.Elapsed.TotalSeconds -lt 4
}

Write-Host '--- stale Claude registrations are pruned ---'
$root = Get-ClaudeStateRoot
$seeded = @()
try {
    foreach ($i in 1..25) {
        $id = [guid]::NewGuid().ToString()
        $seeded += $id
        [pscustomobject]@{
            SessionId = $id; ProcessId = (900000 + $i); TranscriptPath = 'C:\nope.jsonl'
            WorkingDirectory = 'C:\x'; Updated = [DateTimeOffset]::Now.AddDays(-3).ToString('o')
        } | ConvertTo-Json | Set-Content (Join-Path $root "$id.json") -Encoding UTF8
    }
    $before = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File).Count
    $live = @(Get-ClaudeSessionRegistrations)
    $after = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File).Count

    Test-That 'dead registrations are not reported as live' { $live.Count -eq 0 } "$($live.Count)"
    Test-That 'dead registrations are deleted' { $after -lt $before } "$before -> $after"

    # A fresh registration with no resolvable process must survive: the hook may have
    # written it moments ago while the parent walk failed.
    $fresh = [guid]::NewGuid().ToString()
    $seeded += $fresh
    [pscustomobject]@{
        SessionId = $fresh; ProcessId = 0; TranscriptPath = 'C:\nope.jsonl'
        WorkingDirectory = 'C:\x'; Updated = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json | Set-Content (Join-Path $root "$fresh.json") -Encoding UTF8
    [void](Get-ClaudeSessionRegistrations)
    Test-That 'a fresh registration is not pruned' {
        Test-Path -LiteralPath (Join-Path $root "$fresh.json")
    }
}
finally {
    foreach ($id in $seeded) { Remove-Item (Join-Path $root "$id.json") -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
