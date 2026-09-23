#Requires -Version 7.0
<#
.SYNOPSIS
    Regression tests for Live Verbose toggle provisioning.

.DESCRIPTION
    The one guarantee that matters here: Initialize-CopilotVerboseToggle must never
    reset the user's Live Verbose choice. Home Assistant restores a storage-backed
    input_boolean across a restart (verified against a real core restart), so the
    daemon only has to ensure the helper exists - and must never delete+recreate one
    that already does, because that silently flips the toggle back to Off.

    The bug this covers: when the daemon (re)starts while Home Assistant is still
    booting, the helper is already in storage but its state has not materialised yet.
    The old code read that transient no-state as "broken" and recreated the helper,
    resetting it. These tests drive that exact condition with a mocked WebSocket and
    assert that no delete of the real helper is ever issued.

    Needs no Home Assistant: the WebSocket and the state probe are mocked.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-ha-websocket.ps1')

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

# --- mocks -------------------------------------------------------------------
# Every WebSocket command is recorded so the tests can assert on exactly what the
# function tried to do, and the input_boolean/list and input_boolean/create results
# are scripted per scenario. The unary comma keeps [0] returning the intended object
# rather than unrolling it.
$script:WsLog = @()
$script:MockHelpers = @()
$script:MockHasState = $true
$script:MockCreatedId = 'copilot_cli_live_verbose'

function Invoke-CopilotHaWebSocket {
    param([hashtable[]]$Commands, [int]$TimeoutSeconds = 60)
    $type = [string]$Commands[0].type
    $id = ''
    if ($Commands[0].ContainsKey('input_boolean_id')) { $id = [string]$Commands[0]['input_boolean_id'] }
    $script:WsLog += [pscustomobject]@{ Type = $type; InputBooleanId = $id }

    # Assign the payload directly (not through switch, which would unroll an array),
    # then emit a one-element outer array without enumeration - one result per
    # command - so the caller's [0] gets the payload intact even when it is itself an
    # empty array.
    if ($type -eq 'input_boolean/create') { $payload = [pscustomobject]@{ id = $script:MockCreatedId } }
    elseif ($type -eq 'input_boolean/list') { $payload = @($script:MockHelpers) }
    else { $payload = @() }
    Write-Output (, $payload) -NoEnumerate
}

function Test-CopilotHelperHasState {
    param([Parameter(Mandatory)][string]$EntityId)
    return $script:MockHasState
}

function Reset-Mocks {
    param([object[]]$Helpers = @(), [bool]$HasState = $true, [string]$CreatedId = 'copilot_cli_live_verbose')
    $script:WsLog = @()
    $script:MockHelpers = $Helpers
    $script:MockHasState = $HasState
    $script:MockCreatedId = $CreatedId
}

function Get-DeleteTargets {
    @($script:WsLog | Where-Object { $_.Type -eq 'input_boolean/delete' } | ForEach-Object { $_.InputBooleanId })
}
function Test-Created { @($script:WsLog | Where-Object { $_.Type -eq 'input_boolean/create' }).Count -gt 0 }

$helperId = 'copilot_cli_live_verbose'
$present = @([pscustomobject]@{ id = $helperId })

# --- existing helper with a state (steady state) -----------------------------
Write-Host '--- an existing, healthy helper is left completely alone ---'
Reset-Mocks -Helpers $present -HasState $true
$r = Initialize-CopilotVerboseToggle
Test-That 'it returns true' { $r }
Test-That 'nothing is deleted' { @(Get-DeleteTargets).Count -eq 0 }
Test-That 'nothing is created' { -not (Test-Created) }

# --- existing helper, no state yet (Home Assistant still booting) ------------
# This is the exact condition that used to reset the toggle. The helper is in
# storage, but its state has not materialised. It must NOT be recreated.
Write-Host '--- an existing helper with no state yet is never destroyed (the fix) ---'
Reset-Mocks -Helpers $present -HasState $false
$r = Initialize-CopilotVerboseToggle
Test-That 'it returns true' { $r }
Test-That 'the helper is NOT deleted' { @(Get-DeleteTargets) -notcontains $helperId }
Test-That 'nothing is deleted at all' { @(Get-DeleteTargets).Count -eq 0 }
Test-That 'the helper is NOT recreated' { -not (Test-Created) }

# --- helper genuinely absent (fresh install) ---------------------------------
Write-Host '--- a genuinely absent helper is created ---'
Reset-Mocks -Helpers @() -HasState $true -CreatedId $helperId
$r = Initialize-CopilotVerboseToggle
Test-That 'it returns true' { $r }
Test-That 'a create is issued' { Test-Created }
Test-That 'the real helper id is never deleted' { @(Get-DeleteTargets) -notcontains $helperId }

# --- absent list but Home Assistant de-duplicates the id ---------------------
# A transient empty list during boot leads to a create, which Home Assistant slugs
# to a *_2 id because the helper really existed. The stray must be removed and the
# original left intact.
Write-Host '--- a de-duplicated create removes only the stray, not the original ---'
Reset-Mocks -Helpers @() -HasState $true -CreatedId 'copilot_cli_live_verbose_2'
$r = Initialize-CopilotVerboseToggle
Test-That 'it returns true' { $r }
Test-That 'the stray _2 helper is deleted' { @(Get-DeleteTargets) -contains 'copilot_cli_live_verbose_2' }
Test-That 'the real helper is never deleted' { @(Get-DeleteTargets) -notcontains $helperId }

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
