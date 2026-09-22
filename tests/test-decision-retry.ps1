<#
    Regression tests for the Home Assistant HTTP resilience layer.

    These cover the failure that made the CLI re-prompt a question that was already
    live on the dashboard: one transient error inside the eight hour ask_user wait
    propagated out of the hook, which then failed open.
#>

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks\decision-bridge-common.ps1')

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

function New-ErrorRecord {
    param([Parameter(Mandatory)][string]$Message)

    try { throw [System.Net.WebException]::new($Message) }
    catch { return $_ }
}

Write-Host "`n--- transient classification ---"

foreach ($message in @(
    'No connection could be made because the target machine actively refused it. (192.0.2.10:8123)',
    'The request was canceled due to the configured HttpClient.Timeout of 15 seconds elapsing.',
    'Unable to connect to the remote server',
    'The operation has timed out',
    'No such host is known'
)) {
    $record = New-ErrorRecord -Message $message
    Assert-True -Name "transient: $($message.Substring(0, [Math]::Min(46, $message.Length)))" `
        -Condition (Test-DecisionTransientHttpError -ErrorRecord $record)
}

foreach ($message in @(
    'Entity not found',
    'Unauthorized access token'
)) {
    $record = New-ErrorRecord -Message $message
    Assert-True -Name "not transient: $message" `
        -Condition (-not (Test-DecisionTransientHttpError -ErrorRecord $record))
}

Write-Host "`n--- retry behaviour ---"

# Shadow Invoke-RestMethod inside this scope so the retry wrapper drives a fake.
$script:Attempts = 0
function Invoke-RestMethod {
    param()
    $script:Attempts++
    if ($script:Attempts -lt 3) {
        throw [System.Net.WebException]::new(
            'No connection could be made because the target machine actively refused it.'
        )
    }
    return [pscustomobject]@{ state = 'recovered' }
}

$script:Attempts = 0
$result = Invoke-DecisionHttpRequest -Parameters @{ Uri = 'http://example' }
Assert-True -Name 'retries a transient failure and succeeds' `
    -Condition ($result.state -eq 'recovered' -and $script:Attempts -eq 3) `
    -Detail "attempts=$($script:Attempts) state=$($result.state)"

$script:Attempts = 0
function Invoke-RestMethod {
    param()
    $script:Attempts++
    throw [System.Net.WebException]::new('Unauthorized access token')
}
$threw = $false
try { Invoke-DecisionHttpRequest -Parameters @{ Uri = 'http://example' } }
catch { $threw = $true }
Assert-True -Name 'does not retry a non-transient failure' `
    -Condition ($threw -and $script:Attempts -eq 1) `
    -Detail "attempts=$($script:Attempts) threw=$threw"

$script:Attempts = 0
function Invoke-RestMethod {
    param()
    $script:Attempts++
    throw [System.Net.WebException]::new('The operation has timed out')
}
$threw = $false
try { Invoke-DecisionHttpRequest -Parameters @{ Uri = 'http://example' } -RetryCount 2 }
catch { $threw = $true }
Assert-True -Name 'gives up after the retry budget' `
    -Condition ($threw -and $script:Attempts -eq 3) `
    -Detail "attempts=$($script:Attempts) threw=$threw"

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) test(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
exit 0
