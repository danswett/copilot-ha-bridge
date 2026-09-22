#Requires -Version 7.0
<#
.SYNOPSIS
    Integration test for the Claude Code adapter against a real Home Assistant.

.DESCRIPTION
    Drives the PreToolUse router with the recorded hook fixtures and checks that the
    Home Assistant card really arms, that the pending-decision marker is written where
    the daemon will look for it, and that the session is registered with its transcript.

    This covers everything except Claude itself invoking the hook: the payloads are
    fixtures taken from the shipping tool's own contract, fed in exactly as Claude
    feeds them - on stdin.

    Requires the main bridge to be installed (the shared Home Assistant layer lives in
    ~/.copilot/hooks). Creates entities and removes them again.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$core = Join-Path $HOME '.copilot\hooks'
if (-not (Test-Path -LiteralPath (Join-Path $core 'decision-mqtt.ps1'))) {
    Write-Host 'The main bridge is not installed; run install.ps1 first.' -ForegroundColor Yellow
    exit 2
}

. (Join-Path $core 'decision-bridge-common.ps1')
. (Join-Path $core 'decision-mqtt.ps1')
. (Join-Path $core 'decision-ha-websocket.ps1')
. (Join-Path $PSScriptRoot '..\hooks\claude-session.ps1')

$router = Join-Path $PSScriptRoot '..\hooks\route-askuserquestion.ps1'
$fixtures = Join-Path $PSScriptRoot '..\fixtures'
$headers = Get-HomeAssistantHeaders

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name$(if ($Detail) { " - $Detail" })" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

function Invoke-Router {
    param([string]$FixtureName)
    $raw = Get-Content (Join-Path $fixtures $FixtureName) -Raw
    $output = $raw | & pwsh -NoProfile -File $router 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String).Trim()
        Event    = $raw | ConvertFrom-Json
    }
}

function Get-DecisionState {
    param([string]$SessionId)
    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    try { Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $headers }
    catch { $null }
}

function Remove-TestSession {
    param([string]$SessionId)
    try { Remove-CopilotMqttSession -SessionId $SessionId -Headers $headers } catch { }
    try { Remove-CopilotDecisionMarker -SessionId $SessionId } catch { }
    try { Remove-ClaudeSessionRegistration -SessionId $SessionId } catch { }
}

$touched = [System.Collections.Generic.List[string]]::new()

try {
    Write-Host '--- a single question ---'
    $run = Invoke-Router -FixtureName 'pretooluse-single.json'
    $sessionId = [string]$run.Event.session_id
    $touched.Add($sessionId)

    Test-That 'the hook exits 0' { $run.ExitCode -eq 0 } "exit $($run.ExitCode)"
    Test-That 'it writes nothing to stdout, leaving Claude''s prompt untouched' { $run.Output -eq '' } "[$($run.Output)]"

    Start-Sleep -Seconds 3
    $decision = Get-DecisionState -SessionId $sessionId
    Test-That 'the decision entity exists' { $null -ne $decision } (($decision.entity_id) ?? 'missing')
    Test-That 'it is armed with both options' {
        $options = @($decision.attributes.options)
        ($options -join '|') -match 'PostgreSQL' -and ($options -join '|') -match 'SQLite'
    } (@($decision.attributes.options) -join ' | ')

    Test-That 'a pending-decision marker is written where the daemon looks' {
        $null -ne (Get-CopilotDecisionMarker -SessionId $sessionId)
    }
    Test-That 'the marker records the choices' {
        @((Get-CopilotDecisionMarker -SessionId $sessionId).Choices).Count -eq 2
    }
    Test-That 'the session is registered with its transcript path' {
        $reg = Get-ClaudeSessionRegistrations -IncludeStale | Where-Object SessionId -eq $sessionId
        $null -ne $reg
    }

    Write-Host '--- several questions become per-field dropdowns ---'
    $runMulti = Invoke-Router -FixtureName 'pretooluse-multi.json'
    $multiSession = [string]$runMulti.Event.session_id
    $touched.Add($multiSession)
    Test-That 'the hook exits 0' { $runMulti.ExitCode -eq 0 }

    Start-Sleep -Seconds 3
    $node = Get-CopilotMqttNodeId -SessionId $multiSession
    $f1 = try { Get-HomeAssistantState -EntityId "select.${node}_f1" -Headers $headers } catch { $null }
    $f2 = try { Get-HomeAssistantState -EntityId "select.${node}_f2" -Headers $headers } catch { $null }
    Test-That 'field 1 is armed with the database options' {
        (@($f1.attributes.options) -join '|') -match 'PostgreSQL'
    } (@($f1.attributes.options) -join ' | ')
    Test-That 'field 2 is armed with the feature options' {
        (@($f2.attributes.options) -join '|') -match 'Billing'
    } (@($f2.attributes.options) -join ' | ')

    Write-Host '--- too many questions fall back to freeform ---'
    $runMany = Invoke-Router -FixtureName 'pretooluse-too-many.json'
    $manySession = [string]$runMany.Event.session_id
    $touched.Add($manySession)
    Start-Sleep -Seconds 3
    Test-That 'the marker is freeform' {
        (Get-CopilotDecisionMarker -SessionId $manySession).Mode -eq 'freeform'
    }
    Test-That 'the question still lists every option' {
        (Get-CopilotDecisionMarker -SessionId $manySession).Question -match 'Redis'
    }

    Write-Host '--- a non-matching tool is ignored ---'
    $ignored = '{"session_id":"ignore-me","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
    $out = $ignored | & pwsh -NoProfile -File $router 2>&1
    Test-That 'the hook exits 0 and does nothing' { $LASTEXITCODE -eq 0 -and (($out | Out-String).Trim() -eq '') }
    Test-That 'no entity was created for it' { $null -eq (Get-DecisionState -SessionId 'ignore-me') }

    Write-Host '--- malformed input fails open ---'
    $bad = '{not json'
    $out = $bad | & pwsh -NoProfile -File $router 2>&1
    Test-That 'the hook still exits 0' { $LASTEXITCODE -eq 0 } "exit $LASTEXITCODE"

    Write-Host '--- a Notification surfaces the session as waiting ---'
    $notifier = Join-Path $PSScriptRoot '..\hooks\route-notification.ps1'
    $notifyRaw = Get-Content (Join-Path $fixtures 'notification.json') -Raw
    $notifyOut = $notifyRaw | & pwsh -NoProfile -File $notifier 2>&1
    $notifySession = ($notifyRaw | ConvertFrom-Json).session_id
    $touched.Add($notifySession)
    Test-That 'the hook exits 0 silently' {
        $LASTEXITCODE -eq 0 -and (($notifyOut | Out-String).Trim() -eq '')
    } "exit $LASTEXITCODE"

    Start-Sleep -Seconds 4
    $notifyNode = Get-CopilotMqttNodeId -SessionId $notifySession
    $status = try { Get-HomeAssistantState -EntityId "sensor.${notifyNode}_status" -Headers $headers } catch { $null }
    $activity = try { Get-HomeAssistantState -EntityId "sensor.${notifyNode}_activity" -Headers $headers } catch { $null }
    Test-That 'the status reads waiting' { $status.state -eq 'waiting' } (($status.state) ?? 'missing')
    Test-That 'the activity carries what Claude is asking for' {
        $activity.state -match 'git push'
    } (($activity.state) ?? 'missing')

    Write-Host '--- Stop marks the turn idle and uses last_assistant_message ---'
    $stopHook = Join-Path $PSScriptRoot '..\hooks\notify-claude-stop.ps1'
    # Reuse the notified session, which already has entities, so the idle transition
    # is observable.
    $stopEvent = Get-Content (Join-Path $fixtures 'stop-event.json') -Raw | ConvertFrom-Json
    $stopEvent.session_id = $notifySession
    $stopOut = ($stopEvent | ConvertTo-Json -Depth 6) | & pwsh -NoProfile -File $stopHook 2>&1
    Test-That 'the Stop hook exits 0 silently' {
        $LASTEXITCODE -eq 0 -and (($stopOut | Out-String).Trim() -eq '')
    } "exit $LASTEXITCODE"

    Start-Sleep -Seconds 4
    $statusAfter = try { Get-HomeAssistantState -EntityId "sensor.${notifyNode}_status" -Headers $headers } catch { $null }
    $activityAfter = try { Get-HomeAssistantState -EntityId "sensor.${notifyNode}_activity" -Headers $headers } catch { $null }
    Test-That 'the session goes idle' { $statusAfter.state -eq 'idle' } (($statusAfter.state) ?? 'missing')
    Test-That 'the response comes from last_assistant_message' {
        $activityAfter.state -match 'hello from the scratch file'
    } (($activityAfter.state) ?? 'missing')
}
finally {
    Write-Host '--- cleanup ---'
    foreach ($sessionId in $touched | Select-Object -Unique) {
        if ($sessionId) { Remove-TestSession -SessionId $sessionId }
    }
    Remove-TestSession -SessionId 'ignore-me'
    Write-Host "  removed $($touched.Count) test session(s)"
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
