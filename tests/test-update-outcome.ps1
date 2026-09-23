#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the update-install feedback: the in-progress spinner and the
    completion / failure notification.

.DESCRIPTION
    Pressing the Home Assistant install button used to give no visible feedback - the
    update entity flipped silently. Now the daemon shows a spinner on the press, the
    detached updater drops an outcome marker, and whichever daemon runs next turns
    that marker into an authoritative "up to date" state plus a persistent
    notification.

    These tests cover the two new pieces without touching Home Assistant:

      * Publish-CopilotMqttUpdate emits in_progress true / false in the state payload;
      * Invoke-DaemonUpdateOutcome announces success, announces failure, ignores a
        stale or malformed marker, and always consumes the marker.

    The daemon file is dot-sourced with COPILOT_BRIDGE_DAEMON_NORUN set so its
    functions load without the daemon starting.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:COPILOT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\copilot-bridge-daemon.ps1')

# Isolate the marker from the real daemon's file so a test run can never make the
# live bridge announce a phantom update.
$script:DaemonConfig.UpdateOutcomeFile = Join-Path ([IO.Path]::GetTempPath()) "test-update-outcome-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
$outcomeFile = $script:DaemonConfig.UpdateOutcomeFile
$headers = @{ Authorization = 'Bearer test' }

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

# --- in_progress in the state payload (real Publish-CopilotMqttUpdate) ------------
# Mock only the transport, so the real function's JSON is what gets asserted.
$script:MqttMsgs = @()
function Publish-CopilotMqttMessage {
    param([string]$Topic, [AllowEmptyString()][string]$Payload, [hashtable]$Headers, [switch]$Retain)
    $script:MqttMsgs += [pscustomobject]@{ Topic = $Topic; Payload = $Payload }
}
function Get-StatePayload { ($script:MqttMsgs | Where-Object { $_.Topic -match '/update/state$' } | Select-Object -First 1).Payload }

Write-Host '--- the update entity carries an in_progress flag ---'
$script:MqttMsgs = @()
Publish-CopilotMqttUpdate -InstalledVersion '1.1.0' -LatestVersion '1.2.0' -InProgress -Headers $headers
Test-That 'a press publishes in_progress=true' { (Get-StatePayload) -match '"in_progress":true' } (Get-StatePayload)
$script:MqttMsgs = @()
Publish-CopilotMqttUpdate -InstalledVersion '1.2.0' -LatestVersion '1.2.0' -Headers $headers
Test-That 'a normal publish is in_progress=false' { (Get-StatePayload) -match '"in_progress":false' } (Get-StatePayload)

# --- Invoke-DaemonUpdateOutcome --------------------------------------------------
# Now shadow the higher-level calls so the announcer can be observed in isolation.
$script:Published = @()
$script:Notified = @()
function Publish-CopilotMqttUpdate {
    param([string]$InstalledVersion, [string]$LatestVersion, [string]$ReleaseUrl = '', [string]$ReleaseNotes = '', [switch]$InProgress, [hashtable]$Headers)
    $script:Published += [pscustomobject]@{ Installed = $InstalledVersion; Latest = $LatestVersion; InProgress = [bool]$InProgress }
}
function Set-CopilotMqttUpdateEntityIds { }
function Invoke-HomeAssistantService {
    param([string]$Domain, [string]$Service, [hashtable]$Data, [hashtable]$Headers, [int]$TimeoutSec = 15)
    $script:Notified += [pscustomobject]@{ Domain = $Domain; Service = $Service; Title = [string]$Data.title; Message = [string]$Data.message; Id = [string]$Data.notification_id }
}
function Get-BridgeUpdateStatus { param([switch]$Force) [pscustomobject]@{ Installed = '1.1.0'; Latest = '1.2.0'; Available = $true; Url = ''; Notes = '' } }
function Write-DaemonLog { param($Message) }

function Reset-Capture {
    $script:Published = @()
    $script:Notified = @()
    Remove-Item -LiteralPath $outcomeFile -Force -ErrorAction SilentlyContinue
}
function Write-Marker { param([hashtable]$Data) ($Data | ConvertTo-Json -Compress) | Set-Content -LiteralPath $outcomeFile -Encoding UTF8 }
$now = { [DateTimeOffset]::Now.ToString('o') }

Write-Host '--- no marker is a no-op ---'
Reset-Capture
Invoke-DaemonUpdateOutcome -Headers $headers
Test-That 'nothing is published or notified' { $script:Published.Count -eq 0 -and $script:Notified.Count -eq 0 }

Write-Host '--- a success marker announces the new version ---'
Reset-Capture
Write-Marker @{ success = $true; version = '1.2.0'; releaseUrl = 'https://example.test/rel'; at = (& $now) }
Invoke-DaemonUpdateOutcome -Headers $headers
Test-That 'it publishes up to date with the spinner off' {
    $script:Published.Count -ge 1 -and $script:Published[-1].Installed -eq '1.2.0' -and
    $script:Published[-1].Latest -eq '1.2.0' -and -not $script:Published[-1].InProgress
}
Test-That 'it fires one notification naming the version' {
    $script:Notified.Count -eq 1 -and $script:Notified[0].Title -eq 'Bridge updated' -and $script:Notified[0].Message -match '1\.2\.0'
}
Test-That 'the notification is a stable single id' { $script:Notified[0].Id -eq 'copilot_bridge_update' }
Test-That 'the marker is consumed' { -not (Test-Path -LiteralPath $outcomeFile) }

Write-Host '--- a failure marker clears the spinner and reports the error ---'
Reset-Capture
Write-Marker @{ success = $false; error = 'disk full'; at = (& $now) }
Invoke-DaemonUpdateOutcome -Headers $headers
Test-That 'it clears the spinner' { $script:Published.Count -ge 1 -and -not $script:Published[-1].InProgress }
Test-That 'it leaves the update available for retry' { $script:Published[-1].Installed -eq '1.1.0' }
Test-That 'it notifies with the error text' {
    $script:Notified.Count -eq 1 -and $script:Notified[0].Title -eq 'Bridge update failed' -and $script:Notified[0].Message -match 'disk full'
}
Test-That 'the marker is consumed' { -not (Test-Path -LiteralPath $outcomeFile) }

Write-Host '--- a stale marker is ignored ---'
Reset-Capture
Write-Marker @{ success = $true; version = '1.2.0'; at = ([DateTimeOffset]::Now.AddHours(-24)).ToString('o') }
Invoke-DaemonUpdateOutcome -Headers $headers
Test-That 'no notification fires for an old marker' { $script:Notified.Count -eq 0 }
Test-That 'the stale marker is still consumed' { -not (Test-Path -LiteralPath $outcomeFile) }

Write-Host '--- a malformed marker is dropped safely ---'
Reset-Capture
Set-Content -LiteralPath $outcomeFile -Value '{ not valid json' -Encoding UTF8
Invoke-DaemonUpdateOutcome -Headers $headers
Test-That 'it does not throw and notifies nothing' { $script:Notified.Count -eq 0 }
Test-That 'the bad marker is removed' { -not (Test-Path -LiteralPath $outcomeFile) }

Remove-Item -LiteralPath $outcomeFile -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
