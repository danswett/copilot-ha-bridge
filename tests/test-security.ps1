#Requires -Version 7.0
<#
.SYNOPSIS
    Security regression tests for the bridge.

.DESCRIPTION
    Covers the untrusted inputs that reach Home Assistant or the filesystem:

      * session display names, which reach a Lovelace template. A Copilot session is
        named after its task and a Claude session after its working directory, so a
        repository or folder called "{{ ... }}" is attacker-controlled input. Confirmed
        against a live instance: an injected expression evaluated and read real entity
        state before this was fixed.
      * session ids, which are used to build file paths and MQTT topics.
      * the access token, which must never reach a log.

    Needs no Home Assistant.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-inject.ps1')
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

Write-Host '--- template injection ---'
$payloads = @(
    '{{ 1+1 }}',
    "{% for s in states %}{{ s }}{% endfor %}",
    '{# comment #}',
    "{{ states('device_tracker.phone') }}"
)
foreach ($payload in $payloads) {
    $safe = Remove-CopilotTemplateMarkup -Text $payload
    Test-That "neutralised: $payload" {
        $safe -notmatch '\{\{' -and $safe -notmatch '\{%' -and $safe -notmatch '\{#'
    } $safe
}
Test-That 'ordinary text is untouched' {
    (Remove-CopilotTemplateMarkup -Text 'Fix the decision notifier') -eq 'Fix the decision notifier'
}
Test-That 'a lone brace is left alone' {
    (Remove-CopilotTemplateMarkup -Text 'json { "a": 1 }') -eq 'json { "a": 1 }'
}
Test-That 'empty input is safe' { (Remove-CopilotTemplateMarkup -Text '') -eq '' }

Write-Host '--- session names reaching a card ---'
Test-That 'a hostile Claude folder name is neutralised' {
    $display = Get-ClaudeSessionDisplay -SessionId 'abc' -WorkingDirectory "C:\repos\{{ states('sun.sun') }}"
    $display.Name -notmatch '\{\{'
} (Get-ClaudeSessionDisplay -SessionId 'abc' -WorkingDirectory "C:\repos\{{ states('sun.sun') }}").Name

Write-Host '--- session ids used as paths ---'
$traversals = @('../../../../evil', '..\..\evil', 'a/b/c', 'C:\Windows\System32', '....//evil', '')
foreach ($candidate in $traversals) {
    $key = Get-CopilotSafeSessionKey -SessionId $candidate
    Test-That "path-safe: '$candidate' -> '$key'" {
        $key -notmatch '[\\/]' -and $key -notmatch '^\.' -and $key -ne ''
    } $key
}
Test-That 'a real session id is unchanged' {
    (Get-CopilotSafeSessionKey -SessionId '0f5c1a2e-9b44-4d31-8c77-2a1f6b3e0d55') -eq '0f5c1a2e-9b44-4d31-8c77-2a1f6b3e0d55'
}
Test-That 'the marker path stays inside its root' {
    $path = Get-CopilotDecisionMarkerPath -SessionId '../../../../evil'
    $path -notmatch '\.\.'
} (Get-CopilotDecisionMarkerPath -SessionId '../../../../evil')
Test-That 'the Claude key is path-safe too' {
    (Get-ClaudeSafeSessionKey -SessionId '../../evil') -notmatch '[\\/]'
}

Write-Host '--- session ids used as MQTT topics ---'
foreach ($candidate in @('a/b/#', 'x+y', '../evil', 'node id')) {
    $node = Get-CopilotMqttNodeId -SessionId $candidate
    Test-That "mqtt-safe: '$candidate' -> '$node'" {
        $node -match '^[a-zA-Z0-9_]+$'
    } $node
}

Write-Host '--- session-derived filesystem paths cannot escape the session-state root ---'
$sroot = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-sec-" + [Guid]::NewGuid().ToString('N'))
$rootDir = Join-Path $sroot 'root'
$evilDir = Join-Path $sroot 'evil'
New-Item -ItemType Directory -Path $rootDir, $evilDir -Force | Out-Null
# A transcript OUTSIDE the root that, if reachable by traversal, would read as working.
Set-Content -LiteralPath (Join-Path $evilDir 'events.jsonl') -Value '{"type":"assistant.turn_start"}' -Encoding UTF8
$origRoot = $script:DecisionBridgeConfig.SessionStateRoot
$script:DecisionBridgeConfig.SessionStateRoot = $rootDir
try {
    Test-That 'a traversal id cannot read an events.jsonl outside the root' {
        -not (Test-CopilotSessionWorking -SessionId '..\evil')
    }
    Test-That 'a traversal id resolves no owning process' {
        $null -eq (Get-CopilotSessionProcessId -SessionId '..\evil')
    }
    $liveDir = Join-Path $rootDir 'sess-live'
    New-Item -ItemType Directory -Path $liveDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $liveDir 'events.jsonl') -Value '{"type":"assistant.turn_start"}' -Encoding UTF8
    Test-That 'a normal in-root session is still detected as working' {
        Test-CopilotSessionWorking -SessionId 'sess-live'
    }
}
finally {
    $script:DecisionBridgeConfig.SessionStateRoot = $origRoot
    Remove-Item -LiteralPath $sroot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- an injected reply is reduced to printable characters ---'
Test-That 'newlines cannot submit an extra line' {
    (Get-CopilotInjectableText -Text "line1`nline2") -eq 'line1 line2'
}
Test-That 'escape, backspace and tab controls are stripped' {
    (Get-CopilotInjectableText -Text "a$([char]27)b$([char]8)c$([char]9)d") -eq 'a b c d'
}
Test-That 'no control character survives' {
    (Get-CopilotInjectableText -Text "x$([char]0)$([char]13)$([char]7)y") -notmatch '\p{Cc}'
}
Test-That 'printable text is preserved unchanged' {
    (Get-CopilotInjectableText -Text 'yes, option 2 (do it)') -eq 'yes, option 2 (do it)'
}

Write-Host '--- MQTT node ids stay distinct for degenerate ids and stable for real ones ---'
Test-That 'a real UUID node id is unchanged by the hardening' {
    (Get-CopilotMqttNodeId -SessionId '0f5c1a2e-9b44-4d31-8c77-2a1f6b3e0d55') -eq 'agent_bridge_0f5c1a2e9b444d31'
}
Test-That 'two distinct all-symbol ids do not collide on one node' {
    (Get-CopilotMqttNodeId -SessionId '###') -ne (Get-CopilotMqttNodeId -SessionId '@@@')
}
Test-That 'a degenerate id still yields a valid node id' {
    (Get-CopilotMqttNodeId -SessionId '///') -match '^agent_bridge_[a-z0-9]+$'
}

Write-Host '--- token handling ---'
$token = Get-BridgeSetting 'homeAssistant.token' ''
if ([string]::IsNullOrWhiteSpace($token)) {
    $tokenEnvVar = Get-BridgeSetting 'homeAssistant.tokenEnvVar' 'COPILOT_HA_TOKEN'
    if ($tokenEnvVar) { $token = [Environment]::GetEnvironmentVariable($tokenEnvVar) }
}
if ([string]::IsNullOrWhiteSpace($token)) {
    # No token on this machine (a fresh clone or CI). The log-leakage scan needs a
    # real token to be meaningful, so there is nothing to verify here.
    Write-Host '  SKIP  no Home Assistant token configured; log-leakage scan not applicable'
}
else {
    foreach ($log in @('copilot-decision-bridge.log', 'copilot-bridge-daemon.log', 'copilot-bridge-supervisor.log')) {
        $path = Join-Path $env:TEMP $log
        Test-That "the token is absent from $log" {
            -not (Test-Path -LiteralPath $path) -or
            -not (Select-String -LiteralPath $path -SimpleMatch -Pattern $token -Quiet)
        }
    }
}

Write-Host '--- the legacy entity sweep clears the old retained topics ---'
# Renaming a unique_id does not replace an MQTT entity; the retained discovery
# config has to be cleared or Home Assistant keeps the old one forever, sitting
# unavailable next to its replacement.
$script:SweepMsgs = @()
function Publish-CopilotMqttMessage {
    param([string]$Topic, [AllowEmptyString()][string]$Payload, [hashtable]$Headers, [switch]$Retain)
    $script:SweepMsgs += [pscustomobject]@{ Topic = $Topic; Payload = $Payload; Retain = $Retain.IsPresent }
}

$script:SweepMsgs = @()
$sweepHeaders = @{ Authorization = '******' }
$cleared = Clear-CopilotLegacyMqttEntities -Headers $sweepHeaders -SessionIds @('0f5c1a2e-9b44-4d31-8c77-2a1f6b3e0d55')

Test-That 'it reports what it cleared' { $cleared -eq $script:SweepMsgs.Count }
Test-That 'every payload is empty, which is what removes a retained config' {
    @($script:SweepMsgs | Where-Object { $_.Payload -ne '' }).Count -eq 0
}
Test-That 'every clear is retained, or the removal would not stick' {
    @($script:SweepMsgs | Where-Object { -not $_.Retain }).Count -eq 0
}
Test-That 'the old bridge-wide topics are cleared' {
    $t = @($script:SweepMsgs | ForEach-Object { $_.Topic })
    ($t -contains 'homeassistant/update/copilot_cli_bridge/update/config') -and
    ($t -contains 'homeassistant/button/copilot_cli_bridge/install_update/config') -and
    ($t -contains 'homeassistant/sensor/copilot_cli_global/sessions/config') -and
    ($t -contains 'homeassistant/select/copilot_cli_bridge/new_workspace/config')
}
Test-That 'the old per-session topics are cleared for a live session' {
    $t = @($script:SweepMsgs | ForEach-Object { $_.Topic })
    ($t -contains 'homeassistant/select/copilot_0f5c1a2e9b444d31/decision/config') -and
    ($t -contains 'homeassistant/text/copilot_0f5c1a2e9b444d31/reply/config') -and
    ($t -contains 'homeassistant/sensor/copilot_0f5c1a2e9b444d31/status/config') -and
    ($t -contains 'homeassistant/button/copilot_0f5c1a2e9b444d31/submit/config')
}
Test-That 'the per-field dropdown topics are cleared too' {
    $t = @($script:SweepMsgs | ForEach-Object { $_.Topic })
    @(1..4 | Where-Object { $t -contains "homeassistant/select/copilot_0f5c1a2e9b444d31/f$_/config" }).Count -eq 4
}
Test-That 'it never touches a new-style agent_bridge topic' {
    @($script:SweepMsgs | Where-Object { $_.Topic -match '/agent_bridge' }).Count -eq 0
}
Test-That 'the legacy node id is derived independently of the current one' {
    (Get-CopilotLegacyMqttNodeId -SessionId '0f5c1a2e-9b44-4d31-8c77-2a1f6b3e0d55') -eq 'copilot_0f5c1a2e9b444d31' -and
    (Get-CopilotMqttNodeId -SessionId '0f5c1a2e-9b44-4d31-8c77-2a1f6b3e0d55') -eq 'agent_bridge_0f5c1a2e9b444d31'
}

$script:SweepMsgs = @()
[void](Clear-CopilotLegacyMqttEntities -Headers $sweepHeaders -SessionIds @())
Test-That 'with no live sessions only the bridge-wide topics are cleared' {
    @($script:SweepMsgs | Where-Object { $_.Topic -match '/copilot_[0-9a-f]{8}' }).Count -eq 0 -and
    $script:SweepMsgs.Count -gt 0
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
