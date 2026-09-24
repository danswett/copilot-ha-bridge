#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the shared adapter orchestration (bridge-adapter.ps1).

.DESCRIPTION
    The Claude and Codex hooks were near-identical orchestration around a small
    client-specific core. That orchestration now lives in bridge-adapter.ps1 so a fix
    lands in one place. These cover the behaviour the hooks depend on: the reachability
    gate, the publish-on-demand entity check, status/activity publication with the
    standard attributes, and the capped response notification.

    The Home Assistant and MQTT layer is mocked, so nothing here touches a real Home
    Assistant.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
. (Join-Path $PSScriptRoot '..\hooks\bridge-adapter.ps1')

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

# --- mocks that record what the orchestration did (shadow the real functions) ---
$script:Reachable = $true
$script:ProbeResult = $null
$script:Calls = $null
function Reset-Calls {
    $script:Calls = @{ Publish = @(); EntityIds = @(); Status = @(); Activity = @(); Notify = @(); Deadline = @(); Probed = @() }
}
function Test-HomeAssistantReachable { param([int]$TimeoutSec) $script:Reachable }
function Set-DecisionBridgeDeadline { param([int]$Seconds) $script:Calls.Deadline += $Seconds }
function Get-HomeAssistantHeaders { @{ Authorization = 'Bearer test' } }
function Write-DecisionBridgeLog { param([string]$Message) }
function Get-HomeAssistantState { param($EntityId, $Headers) $script:Calls.Probed += [string]$EntityId; $script:ProbeResult }
function Publish-CopilotMqttSession { param($SessionId, $SessionName, $Machine, $Headers) $script:Calls.Publish += @{ SessionId = $SessionId; Name = $SessionName } }
function Set-CopilotMqttEntityIds { param($SessionId) $script:Calls.EntityIds += $SessionId }
function Set-CopilotMqttStatus { param($SessionId, $Status, $Headers, $Attributes) $script:Calls.Status += @{ Status = $Status; Attributes = $Attributes } }
function Set-CopilotMqttActivity { param($SessionId, $Summary, $Detail, $Headers) $script:Calls.Activity += @{ Summary = $Summary; Detail = $Detail } }
function Send-BridgeNotification { param($Title, $Message, $Headers) $script:Calls.Notify += @{ Title = $Title; Message = $Message } }
function Start-Sleep { param([int]$Milliseconds, [int]$Seconds) }

$headers = @{ Authorization = 'Bearer test' }

Write-Host '--- Enter-BridgeAdapterSession gates on reachability ---'
Reset-Calls
$script:Reachable = $true
$h = Enter-BridgeAdapterSession
Test-That 'reachable returns headers' { $null -ne $h -and $h.Authorization -eq 'Bearer test' }
Test-That 'reachable sets the deadline' { $script:Calls.Deadline.Count -eq 1 -and $script:Calls.Deadline[0] -eq 45 }
Reset-Calls
$script:Reachable = $false
Test-That 'unreachable returns null' { $null -eq (Enter-BridgeAdapterSession) }
Test-That 'unreachable does not set a deadline' { $script:Calls.Deadline.Count -eq 0 }

Write-Host '--- Test-BridgeSessionEntityPresent reads presence ---'
$script:ProbeResult = [pscustomobject]@{ state = 'idle' }
Test-That 'a real state is present' { Test-BridgeSessionEntityPresent -EntityId 'sensor.x_status' -Headers $headers }
$script:ProbeResult = [pscustomobject]@{ state = 'unavailable' }
Test-That 'an unavailable state is absent' { -not (Test-BridgeSessionEntityPresent -EntityId 'sensor.x_status' -Headers $headers) }
$script:ProbeResult = $null
Test-That 'a null state is absent' { -not (Test-BridgeSessionEntityPresent -EntityId 'sensor.x_status' -Headers $headers) }

Write-Host '--- Confirm-BridgeSessionEntities publishes only when missing ---'
Reset-Calls
$script:ProbeResult = [pscustomobject]@{ state = 'idle' }
$existed = Confirm-BridgeSessionEntities -SessionId 'sess-1' -SessionName 'S' -Machine 'M' -Headers $headers
Test-That 'existing entities are not republished' { $existed -and $script:Calls.Publish.Count -eq 0 -and $script:Calls.EntityIds.Count -eq 0 }
Test-That 'the default probe is the status sensor' { $script:Calls.Probed[0] -match '^sensor\.agent_bridge_.*_status$' }
Reset-Calls
$script:ProbeResult = $null
$existed = Confirm-BridgeSessionEntities -SessionId 'sess-2' -SessionName 'S' -Machine 'M' -Headers $headers
Test-That 'missing entities are published once' { (-not $existed) -and $script:Calls.Publish.Count -eq 1 -and $script:Calls.EntityIds.Count -eq 1 }
Reset-Calls
$script:ProbeResult = $null
[void](Confirm-BridgeSessionEntities -SessionId 'sess-3' -SessionName 'S' -Machine 'M' -Headers $headers -ProbeEntity 'select.custom_decision')
Test-That 'a custom probe entity is honoured' { $script:Calls.Probed[0] -eq 'select.custom_decision' }

Write-Host '--- Publish-BridgeSessionStatus builds standard attributes ---'
Reset-Calls
Publish-BridgeSessionStatus -SessionId 's' -SessionName 'MyProj' -Machine 'BOX' -Headers $headers -Status 'working' -Activity 'Running: grep'
Test-That 'status carries session/machine/updated' {
    $a = $script:Calls.Status[0].Attributes
    $a.session -eq 'MyProj' -and $a.machine -eq 'BOX' -and $a.ContainsKey('updated')
}
Test-That 'the status value is set' { $script:Calls.Status[0].Status -eq 'working' }
Test-That 'activity is published with a summary and detail' {
    $script:Calls.Activity.Count -eq 1 -and $script:Calls.Activity[0].Summary -eq 'Running: grep' -and
    $script:Calls.Activity[0].Detail.session -eq 'MyProj'
}
Reset-Calls
Publish-BridgeSessionStatus -SessionId 's' -SessionName 'MyProj' -Machine 'BOX' -Headers $headers -Status 'idle'
Test-That 'no activity is published when none is given' { $script:Calls.Activity.Count -eq 0 }
Reset-Calls
Publish-BridgeSessionStatus -SessionId 's' -SessionName 'MyProj' -Machine 'BOX' -Headers $headers -Status 'working' `
    -ExtraAttributes @{ model = 'gpt'; process_id = 42 }
Test-That 'extra attributes are merged in' {
    $a = $script:Calls.Status[0].Attributes
    $a.model -eq 'gpt' -and $a.process_id -eq 42 -and $a.session -eq 'MyProj'
}

Write-Host '--- Format-BridgeNotificationTitle caps length ---'
Test-That 'a short title is unchanged' { (Format-BridgeNotificationTitle 'hello') -eq 'hello' }
Test-That 'a long title is capped to 190' {
    $t = Format-BridgeNotificationTitle ('x' * 300)
    $t.Length -eq 190 -and $t.EndsWith('...')
}

Write-Host '--- Send-BridgeResponseNotification previews the response ---'
Reset-Calls
Send-BridgeResponseNotification -SessionName 'MyProj' -Response '' -Headers $headers
Test-That 'an empty response sends nothing' { $script:Calls.Notify.Count -eq 0 }
Reset-Calls
Send-BridgeResponseNotification -SessionName 'MyProj' -Response 'All done.' -Headers $headers
Test-That 'a short response is sent whole' {
    $script:Calls.Notify.Count -eq 1 -and $script:Calls.Notify[0].Title -eq 'Response: MyProj' -and
    $script:Calls.Notify[0].Message -eq 'All done.'
}
Reset-Calls
Send-BridgeResponseNotification -SessionName 'MyProj' -Response ('y' * 1000) -Headers $headers
Test-That 'a long response is truncated with a pointer to the dashboard' {
    $m = $script:Calls.Notify[0].Message
    $m.Length -lt 1000 -and $m.EndsWith('Full response is on the dashboard.')
}
Reset-Calls
Send-BridgeResponseNotification -SessionName 'MyProj' -Response ('z' * 1000) -Headers $headers `
    -TitlePrefix 'Copilot response' -DashboardLabel 'the Agent Sessions dashboard'
Test-That 'a custom title prefix and dashboard label are honoured' {
    $script:Calls.Notify[0].Title -eq 'Copilot response: MyProj' -and
    $script:Calls.Notify[0].Message.EndsWith('Full response is on the Agent Sessions dashboard.')
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
