<#
    Regression tests for Set-CopilotMqttSelectOption.

    The bug: an MQTT select fixes its option list at discovery time, so publishing a
    new config and immediately calling select.select_option is a race. The old code
    slept a flat 600 ms and hoped. When Home Assistant was slow the call landed against
    the *previous* option list and HA logged

        Option 'Awaiting answer...' is not valid for entity select.<node>_decision,
        valid options are: Idle

    once per attempt (30 in one observed 24h window). It was swallowed, so the question
    still reached the card, but the selector's state stayed 'unknown' and the dashboard
    hides the Answer control unless the state is something other than Idle.

    These tests are Home Assistant free: the two HTTP helpers are replaced with fakes.
#>

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks\decision-mqtt.ps1')

$script:Failures = 0

function Assert-True {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail = ''
    )

    if ($Condition) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    else {
        $script:Failures++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" }
    }
}

# --- fakes -----------------------------------------------------------------
# Redefined after the dot-source above, so these win at call time.

$script:StateCalls = 0
$script:SelectCalls = @()
$script:StateScript = { param($attempt) $null }

function Get-HomeAssistantState {
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][hashtable]$Headers,
        [int]$TimeoutSec = 15
    )

    $script:StateCalls++
    return (& $script:StateScript $script:StateCalls)
}

function Invoke-HomeAssistantService {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][hashtable]$Data,
        [Parameter(Mandatory)][hashtable]$Headers,
        [int]$TimeoutSec = 15
    )

    $script:SelectCalls += [pscustomobject]@{
        Domain   = $Domain
        Service  = $Service
        EntityId = $Data.entity_id
        Option   = $Data.option
    }
}

function New-StateWithOptions {
    param([string[]]$Options)
    return [pscustomobject]@{
        state      = 'Idle'
        attributes = [pscustomobject]@{ options = $Options }
    }
}

function Reset-Fakes {
    param([scriptblock]$StateScript)
    $script:StateCalls = 0
    $script:SelectCalls = @()
    $script:StateScript = $StateScript
}

$headers = @{ Authorization = 'Bearer test' }
$entity = 'select.copilot_test_decision'

# --- the actual race -------------------------------------------------------
Write-Host "`n--- waits for discovery to land before selecting ---"

# Discovery is slow: the first two polls still show the OLD option list.
Reset-Fakes -StateScript {
    param($attempt)
    if ($attempt -lt 3) { return (New-StateWithOptions -Options @('Idle')) }
    return (New-StateWithOptions -Options @('Awaiting answer...', 'Cancel request'))
}

$ready = Set-CopilotMqttSelectOption -EntityId $entity -Option 'Awaiting answer...' `
    -Headers $headers -Attempts 8 -DelayMs 25

Assert-True -Name 'reports the entity became ready' -Condition ([bool]$ready)
Assert-True -Name 'polled until the new options appeared' -Condition ($script:StateCalls -eq 3) `
    "state calls: $($script:StateCalls)"
Assert-True -Name 'selected exactly once' -Condition (@($script:SelectCalls).Count -eq 1) `
    "select calls: $(@($script:SelectCalls).Count)"
Assert-True -Name 'selected the right option on the right entity' -Condition (
    $script:SelectCalls[0].Option -eq 'Awaiting answer...' -and
    $script:SelectCalls[0].EntityId -eq $entity -and
    $script:SelectCalls[0].Service -eq 'select_option'
) "$($script:SelectCalls[0] | ConvertTo-Json -Compress)"

Write-Host "`n--- fast path: already armed, no waiting ---"

Reset-Fakes -StateScript { param($attempt) New-StateWithOptions -Options @('Awaiting answer...') }

$sw = [Diagnostics.Stopwatch]::StartNew()
$ready = Set-CopilotMqttSelectOption -EntityId $entity -Option 'Awaiting answer...' `
    -Headers $headers -Attempts 8 -DelayMs 600
$sw.Stop()

Assert-True -Name 'returns ready on the first poll' -Condition ($script:StateCalls -eq 1) `
    "state calls: $($script:StateCalls)"
Assert-True -Name 'does not pay the old fixed 600ms sleep' -Condition ($sw.ElapsedMilliseconds -lt 400) `
    "elapsed: $($sw.ElapsedMilliseconds)ms"
Assert-True -Name 'still performs the select' -Condition (@($script:SelectCalls).Count -eq 1)

Write-Host "`n--- a 404 from a not-yet-registered entity is not fatal ---"

# Get-HomeAssistantState throws for a missing entity; that means "keep waiting".
Reset-Fakes -StateScript {
    param($attempt)
    if ($attempt -lt 3) { throw [System.Net.WebException]::new('404 Not Found') }
    return (New-StateWithOptions -Options @('Idle'))
}

$ready = Set-CopilotMqttSelectOption -EntityId $entity -Option 'Idle' `
    -Headers $headers -Attempts 6 -DelayMs 25

Assert-True -Name 'survives the 404s and still becomes ready' -Condition ([bool]$ready)
Assert-True -Name 'kept polling past the throws' -Condition ($script:StateCalls -eq 3) `
    "state calls: $($script:StateCalls)"

Write-Host "`n--- timeout still attempts the select, and never throws ---"

Reset-Fakes -StateScript { param($attempt) New-StateWithOptions -Options @('Idle') }

$ready = $null
$threw = $false
try {
    $ready = Set-CopilotMqttSelectOption -EntityId $entity -Option 'Awaiting answer...' `
        -Headers $headers -Attempts 3 -DelayMs 25
}
catch { $threw = $true }

Assert-True -Name 'does not throw when the option never appears' -Condition (-not $threw)
Assert-True -Name 'reports not-ready' -Condition (-not $ready)
Assert-True -Name 'bounded by the attempt count' -Condition ($script:StateCalls -eq 3) `
    "state calls: $($script:StateCalls)"
Assert-True -Name 'still tries the select as a last resort' -Condition (@($script:SelectCalls).Count -eq 1)

Write-Host "`n--- a failing select_option stays non-fatal ---"

Reset-Fakes -StateScript { param($attempt) New-StateWithOptions -Options @('Idle') }
function Invoke-HomeAssistantService {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][hashtable]$Data,
        [Parameter(Mandatory)][hashtable]$Headers,
        [int]$TimeoutSec = 15
    )
    throw 'ServiceValidationError: Option is not valid for entity'
}

$threw = $false
try {
    Set-CopilotMqttSelectOption -EntityId $entity -Option 'Idle' `
        -Headers $headers -Attempts 2 -DelayMs 25 | Out-Null
}
catch { $threw = $true }

Assert-True -Name 'swallows a ServiceValidationError like the old code did' -Condition (-not $threw)

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'All select-race tests passed.' -ForegroundColor Green
exit 0
