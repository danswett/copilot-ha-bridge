#Requires -Version 7.0
<#
.SYNOPSIS
    Tests that a daemon restart restores each card instead of blanking it.

.DESCRIPTION
    A restart - including the one a self-update now triggers - used to re-prime every
    live session with a generic "Working"/"Idle" summary and empty attributes, which
    wiped the chain-of-thought and the activity history off the dashboard. The daemon
    already carries the last summary, reasoning, response and history on each persisted
    session entry, so the fix is to restore the card from them rather than blank it.

    Resolve-DaemonPrimedCard is the pure function that builds what the prime
    re-publishes; these assert it restores everything when present, gates reasoning on
    the verbose toggle, and falls back cleanly when a session has no remembered
    activity.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:COPILOT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\copilot-bridge-daemon.ps1')

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

# A persisted entry as Read-DaemonState would hand back: a plain object with the
# remembered display fields.
function New-Entry {
    param([hashtable]$Extra = @{})
    $o = [pscustomobject]@{ Name = 'my task'; Machine = 'DSWETT-HOME'; Status = 'working' }
    foreach ($k in $Extra.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] -Force }
    $o
}

Write-Host '--- a working session with full history is restored, not blanked ---'
$entry = New-Entry @{
    LastSummary   = 'Running: grep'
    LastReasoning = 'I should search the config first'
    LastResponse  = 'Here is the result.'
    LastHistory   = @('Reading your message', 'Running: grep')
}
$card = Resolve-DaemonPrimedCard -Entry $entry -Status 'working' -VerboseOn $true
Test-That 'the real summary is kept' { $card.Summary -eq 'Running: grep' }
Test-That 'the reasoning is restored when verbose is on' { $card.Detail['reasoning'] -eq 'I should search the config first' }
Test-That 'the last response is restored' { $card.Detail['response'] -eq 'Here is the result.' }
Test-That 'the history is restored' { @($card.Detail['history']).Count -eq 2 }
Test-That 'session and machine are carried' { $card.Detail['session'] -eq 'my task' -and $card.Detail['machine'] -eq 'DSWETT-HOME' }

Write-Host '--- reasoning is withheld when verbose is off ---'
$card = Resolve-DaemonPrimedCard -Entry $entry -Status 'working' -VerboseOn $false
Test-That 'no reasoning key when verbose is off' { -not $card.Detail.ContainsKey('reasoning') }
Test-That 'the summary is still restored' { $card.Summary -eq 'Running: grep' }
Test-That 'verbose flag reflects off' { $card.Detail['verbose'] -eq $false }

Write-Host '--- a session with no remembered activity falls back cleanly ---'
$bare = New-Entry
$card = Resolve-DaemonPrimedCard -Entry $bare -Status 'idle' -VerboseOn $true
Test-That 'idle falls back to the Idle label' { $card.Summary -eq 'Idle' }
Test-That 'working falls back to the Working label' { (Resolve-DaemonPrimedCard -Entry $bare -Status 'working' -VerboseOn $true).Summary -eq 'Working' }
Test-That 'no reasoning/response/history keys when nothing is remembered' {
    -not $card.Detail.ContainsKey('reasoning') -and -not $card.Detail.ContainsKey('response') -and -not $card.Detail.ContainsKey('history')
}

Write-Host '--- empty remembered fields do not produce empty attributes ---'
$blank = New-Entry @{ LastSummary = '  '; LastReasoning = ''; LastResponse = $null }
$card = Resolve-DaemonPrimedCard -Entry $blank -Status 'working' -VerboseOn $true
Test-That 'blank summary falls back to a label' { $card.Summary -eq 'Working' }
Test-That 'blank reasoning is not published' { -not $card.Detail.ContainsKey('reasoning') }
Test-That 'blank response is not published' { -not $card.Detail.ContainsKey('response') }

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
