#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the installer's client selection.

.DESCRIPTION
    The base installer now sets up the shared layer and then configures whichever
    clients are chosen, instead of always forcing Copilot. These cover the pure
    decision logic:

      * ConvertTo-BridgeClientList normalises aliases, de-dupes, drops blanks and
        rejects unknown names;
      * Resolve-BridgeClients honours -Clients first, then a persisted selection, then
        an interactive pick, and falls back to Copilot only for an unattended install.

    install.ps1 is dot-sourced with BRIDGE_INSTALL_NORUN set so its functions load
    without running the install.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:BRIDGE_INSTALL_NORUN = '1'
. (Join-Path $PSScriptRoot '..\install.ps1')

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

Write-Host '--- ConvertTo-BridgeClientList ---'
Test-That 'passes known clients through' {
    (ConvertTo-BridgeClientList @('copilot', 'claude', 'codex')) -join ',' -eq 'copilot,claude,codex'
}
Test-That 'normalises aliases' {
    (ConvertTo-BridgeClientList @('GitHub', 'claude-code', 'codex-cli')) -join ',' -eq 'copilot,claude,codex'
}
Test-That 'is case-insensitive' {
    (ConvertTo-BridgeClientList @('Copilot', 'CLAUDE')) -join ',' -eq 'copilot,claude'
}
Test-That 'de-dupes' {
    (ConvertTo-BridgeClientList @('copilot', 'copilot', 'github')) -join ',' -eq 'copilot'
}
Test-That 'drops blanks' {
    (ConvertTo-BridgeClientList @('copilot', '', '  ')) -join ',' -eq 'copilot'
}
Test-That 'splits a comma-joined single string' {
    (ConvertTo-BridgeClientList @('copilot,claude,codex')) -join ',' -eq 'copilot,claude,codex'
}
Test-That 'rejects an unknown client' {
    $threw = $false
    try { ConvertTo-BridgeClientList @('sublime') } catch { $threw = $true }
    $threw
}

Write-Host '--- Resolve-BridgeClients precedence ---'
Test-That '-Clients wins over everything' {
    (Resolve-BridgeClients -Requested @('claude') -Persisted @('copilot') -NonInteractive) -join ',' -eq 'claude'
}
Test-That 'a persisted selection is used when nothing is requested' {
    (Resolve-BridgeClients -Persisted @('copilot', 'codex') -NonInteractive) -join ',' -eq 'copilot,codex'
}
Test-That 'a persisted selection is normalised too' {
    (Resolve-BridgeClients -Persisted @('github', 'claude-code') -NonInteractive) -join ',' -eq 'copilot,claude'
}
Test-That 'non-interactive with nothing set defaults to copilot' {
    (Resolve-BridgeClients -NonInteractive) -join ',' -eq 'copilot'
}
Test-That 'the interactive prompt is used when not non-interactive' {
    (Resolve-BridgeClients -Prompt { @('claude', 'codex') }) -join ',' -eq 'claude,codex'
}
Test-That 'a request beats a prompt' {
    (Resolve-BridgeClients -Requested @('copilot') -Prompt { @('claude') }) -join ',' -eq 'copilot'
}

Write-Host '--- Test-BridgeClientInstalled returns a bool for each client ---'
foreach ($c in @('copilot', 'claude', 'codex')) {
    Test-That "$c detection does not throw" { (Test-BridgeClientInstalled $c) -is [bool] }
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
