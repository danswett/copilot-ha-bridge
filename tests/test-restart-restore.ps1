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

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')

# Keep this run's log lines out of the live daemon log; dot-sourcing the daemon
# otherwise points Write-DaemonLog straight at it.
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-restart-restore-$([guid]::NewGuid().ToString('N').Substring(0,8)).log"
$testLogFile = $script:DaemonConfig.LogFile

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

Write-Host '--- state persistence is atomic, backed up, and recovers from corruption ---'
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-state-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$stateFile = Join-Path $tmpDir 'state.json'
$origStateFile = $script:DaemonConfig.StateFile
$script:DaemonConfig.StateFile = $stateFile
$script:DaemonStateLastWritten = $null
try {
    Write-DaemonState -State @{ sess1 = @{ Offset = 5 } }
    Test-That 'the state file is written' { Test-Path -LiteralPath $stateFile }
    Test-That 'no temp file is left behind' { -not (Test-Path -LiteralPath "$stateFile.tmp") }
    Test-That 'the state round-trips' { [int](Read-DaemonState)['sess1'].Offset -eq 5 }

    # A second, different write creates a last-good backup of the prior content.
    Write-DaemonState -State @{ sess1 = @{ Offset = 9 } }
    Test-That 'a backup is created on change' { Test-Path -LiteralPath "$stateFile.bak" }
    Test-That 'the backup holds the previous content' { (Get-Content -LiteralPath "$stateFile.bak" -Raw) -match '"Offset":5' }
    Test-That 'the primary holds the new content' { [int](Read-DaemonState)['sess1'].Offset -eq 9 }

    # Corruption of the primary recovers from the backup instead of blanking cards.
    Set-Content -LiteralPath $stateFile -Value '{ this is not valid json' -Encoding UTF8
    Test-That 'a corrupt primary recovers the backup' { [int](Read-DaemonState)['sess1'].Offset -eq 5 }

    # Corrupt with no usable backup, and a missing file, are both empty (not a throw).
    Remove-Item -LiteralPath "$stateFile.bak" -Force
    Set-Content -LiteralPath $stateFile -Value 'still not json' -Encoding UTF8
    Test-That 'a corrupt primary with no backup is empty' { (Read-DaemonState).Count -eq 0 }
    Remove-Item -LiteralPath $stateFile -Force
    Test-That 'a missing state file is empty' { (Read-DaemonState).Count -eq 0 }

    # The dirty flag skips an unchanged write and honours a changed one.
    $script:DaemonStateLastWritten = $null
    Write-DaemonState -State @{ sess1 = @{ Offset = 7 } }
    Set-Content -LiteralPath $stateFile -Value 'SENTINEL' -Encoding UTF8
    Write-DaemonState -State @{ sess1 = @{ Offset = 7 } }
    Test-That 'an unchanged write is skipped' { (Get-Content -LiteralPath $stateFile -Raw).Trim() -eq 'SENTINEL' }
    Write-DaemonState -State @{ sess1 = @{ Offset = 8 } }
    Test-That 'a changed write is not skipped' { [int](Read-DaemonState)['sess1'].Offset -eq 8 }
}
finally {
    $script:DaemonConfig.StateFile = $origStateFile
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- the MCP discovery scan is cached within its TTL ---'
$script:McpScanCalls = 0
function Invoke-DecisionHttpRequest { param($Parameters) $script:McpScanCalls++; @() }
$script:DaemonMcpCache = $null
$script:DaemonMcpCacheAt = [DateTimeOffset]::MinValue
$mcpHeaders = @{ Authorization = 'Bearer test' }
$null = Get-LiveMcpSessions -Headers $mcpHeaders
$null = Get-LiveMcpSessions -Headers $mcpHeaders
$null = Get-LiveMcpSessions -Headers $mcpHeaders
Test-That 'the /api/states scan runs once within the TTL' { $script:McpScanCalls -eq 1 }
$script:DaemonMcpCacheAt = [DateTimeOffset]::Now.AddSeconds(-9999)
$null = Get-LiveMcpSessions -Headers $mcpHeaders
Test-That 'an expired cache triggers a fresh scan' { $script:McpScanCalls -eq 2 }

Write-Host '--- state persistence survives console detachment ---'
# Regression. Reply injection does FreeConsole -> AttachConsole -> FreeConsole, and
# once a daemon has done that, any cmdlet emitting a progress record throws from the
# host: 'The handle is invalid. 0x6 ... while getting console output buffer
# information'. That is a host exception rather than an error record, so the
# -ErrorAction SilentlyContinue on the old Copy-Item backup did not suppress it and
# every subsequent save failed. Observed live: 331 consecutive failures and a state
# file that silently stopped advancing from the first injection onward.
#
# Run in a child process, because the console juggling would break the rest of this
# suite's own output.
$detachDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-detach-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $detachDir -Force | Out-Null
$detachScript = Join-Path $detachDir 'detach.ps1'
$detachResult = Join-Path $detachDir 'result.txt'
$daemonPath = (Resolve-Path (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')).Path

@"
`$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. '$daemonPath'

Add-Type -Namespace Detach -Name Con -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool AttachConsole(uint dwProcessId);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool FreeConsole();
'@

`$script:DaemonConfig.StateFile = '$($detachDir -replace "'", "''")\state.json'
`$script:DaemonConfig.LogFile = '$($detachDir -replace "'", "''")\daemon.log'
`$script:DaemonStateLastWritten = `$null

# Seed a file so the backup branch is exercised - that is where the old code failed.
Write-DaemonState -State @{ s = @{ Offset = 1 } }

`$victim = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'timeout /t 30 /nobreak' -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 800
[void][Detach.Con]::FreeConsole()
[void][Detach.Con]::AttachConsole([uint32]`$victim.Id)
[void][Detach.Con]::FreeConsole()

Write-DaemonState -State @{ s = @{ Offset = 2 } }
`$state = Read-DaemonState
`$ok = (`$state.Count -gt 0) -and ([int]`$state['s'].Offset -eq 2)
try { Stop-Process -Id `$victim.Id -Force -ErrorAction SilentlyContinue } catch { }
[System.IO.File]::WriteAllText('$($detachResult -replace "'", "''")', `$(if (`$ok) { 'OK' } else { 'FAIL' }))
"@ | Set-Content -LiteralPath $detachScript -Encoding UTF8

try {
    $child = Start-Process -FilePath 'pwsh' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $detachScript
    )
    $child.WaitForExit(90000) | Out-Null
    $detachOutcome = if (Test-Path -LiteralPath $detachResult) { (Get-Content -LiteralPath $detachResult -Raw).Trim() } else { 'NO RESULT' }
    Test-That 'a state write succeeds after injection-style console detachment' { $detachOutcome -eq 'OK' } $detachOutcome
}
finally {
    Remove-Item -LiteralPath $detachDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- the legacy cleanup runs once and re-publishes live sessions ---'
# The sweep deletes a live session's old entities. Sync-DaemonSessions only
# publishes sessions it has never seen, so unless the sweep also drops them from
# state they end up with no card at all - old entities gone, new ones never made.
$script:SweptTopics = @()
function Clear-CopilotLegacyMqttEntities {
    param([hashtable]$Headers, [string[]]$SessionIds = @())
    $script:SweptTopics += @($SessionIds)
    27
}

$cleanupMarker = Join-Path ([IO.Path]::GetTempPath()) "test-legacy-cleanup-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
$origMarker = $script:DaemonConfig.LegacyCleanupMarker
$script:DaemonConfig.LegacyCleanupMarker = $cleanupMarker
try {
    $liveSet = @{ 'sess-a' = [pscustomobject]@{ SessionId = 'sess-a' }; 'sess-b' = [pscustomobject]@{ SessionId = 'sess-b' } }
    $stateSet = @{ 'sess-a' = [pscustomobject]@{ Offset = 10 }; 'sess-b' = [pscustomobject]@{ Offset = 20 }; 'sess-dead' = [pscustomobject]@{ Offset = 5 } }

    $script:SweptTopics = @()
    $n = Invoke-DaemonLegacyCleanup -Headers @{ Authorization = 'x' } -Live $liveSet -State $stateSet
    Test-That 'it reports how many topics were cleared' { $n -eq 27 }
    Test-That 'the live sessions are passed to the sweep' {
        ($script:SweptTopics -contains 'sess-a') -and ($script:SweptTopics -contains 'sess-b')
    }
    Test-That 'live sessions are dropped from state so they republish' {
        -not $stateSet.ContainsKey('sess-a') -and -not $stateSet.ContainsKey('sess-b')
    }
    Test-That 'a session that is not live is left in state' { $stateSet.ContainsKey('sess-dead') }
    Test-That 'a marker is written' { Test-Path -LiteralPath $cleanupMarker }

    # Second run must be a complete no-op, or every daemon start would blow away the
    # cards of whatever is running.
    $stateSet2 = @{ 'sess-a' = [pscustomobject]@{ Offset = 10 } }
    $script:SweptTopics = @()
    $n2 = Invoke-DaemonLegacyCleanup -Headers @{ Authorization = 'x' } -Live $liveSet -State $stateSet2
    Test-That 'a second run does nothing' { $n2 -eq -1 -and $script:SweptTopics.Count -eq 0 }
    Test-That 'and leaves state untouched' { $stateSet2.ContainsKey('sess-a') }
}
finally {
    $script:DaemonConfig.LegacyCleanupMarker = $origMarker
    Remove-Item -LiteralPath $cleanupMarker -Force -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath $testLogFile -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green