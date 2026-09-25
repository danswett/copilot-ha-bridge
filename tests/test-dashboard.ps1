#Requires -Version 7.0
<#
.SYNOPSIS
    Tests the generated Home Assistant dashboard config.

.DESCRIPTION
    Save-CopilotSessionDashboard builds the whole Lovelace config from the live session
    list. These assert the parts that are easy to get wrong and that users see: the
    dashboard title, the view tab, the control card's live/version summary, and that a
    live session produces a card. The Home Assistant save is mocked, so nothing here
    touches a real instance.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
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

# Capture the config that would be saved instead of sending it to Home Assistant.
$script:SavedUrlPath = $null
$script:SavedConfig = $null
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    $script:SavedUrlPath = $Commands[0].url_path
    $script:SavedConfig = $Commands[0].config
    @()
}

Write-Host '--- the dashboard is titled and routed correctly ---'
$sessions = @(
    [pscustomobject]@{ Node = 'copilot_abc123def456'; Name = 'Copilot: my task'; Machine = 'BOX'; Kind = 'copilot' }
)
Save-CopilotSessionDashboard -Sessions $sessions
$cfg = $script:SavedConfig

Test-That 'the dashboard title is Agent Sessions' { $cfg.title -eq 'Agent Sessions' }
Test-That 'the view tab is titled Sessions' { $cfg.views[0].title -eq 'Sessions' }
Test-That 'the view path stays decision (URL slug unchanged)' { $cfg.views[0].path -eq 'decision' }
Test-That 'it is saved to the copilot-decisions slug' { $script:SavedUrlPath -eq $script:DecisionBridgeConfig.DashboardUrlPath }

Write-Host '--- the control card summarises sessions and the installed version ---'
# The summary and its toggle are one stacked card now, so the markdown lives a level
# down rather than directly among the view's cards.
$agentCard = @($cfg.views[0].cards | Where-Object {
    $_.type -eq 'vertical-stack' -and @($_.cards | Where-Object { $_.type -eq 'markdown' -and $_.content -match 'Agent sessions' }).Count -gt 0
})[0]
Test-That 'the agent sessions card exists' { $null -ne $agentCard }
$control = @($agentCard.cards | Where-Object { $_.type -eq 'markdown' })[0]
Test-That 'the control markdown card exists' { $null -ne $control }
Test-That 'it shows the live session count' { $control.content.Contains("states('sensor.agent_bridge_sessions')") }
Test-That 'it shows the installed bridge version from the update entity' {
    $control.content.Contains("state_attr('update.agent_bridge_update', 'installed_version')") -and
    $control.content.Contains('**Bridge**')
}

Write-Host '--- the detailed-activity toggle lives in that card ---'
$toggleRows = @($agentCard.cards | Where-Object { $_.type -eq 'entities' } | ForEach-Object { $_.entities })
Test-That 'the toggle is inside the agent sessions card' {
    @($toggleRows | Where-Object { $_.entity -eq 'input_boolean.agent_bridge_detailed_activity' }).Count -eq 1
}
Test-That 'it is labelled Detailed activity, not Live Verbose' {
    ($toggleRows | Where-Object { $_.entity -eq 'input_boolean.agent_bridge_detailed_activity' }).name -eq 'Detailed activity'
}
Test-That 'the markdown refers to the toggle by its new name' {
    $control.content -match 'Detailed activity' -and $control.content -notmatch 'Live Verbose'
}
Test-That 'the toggle keeps its original entity id for compatibility' {
    @($toggleRows | Where-Object { $_.entity -eq 'input_boolean.agent_bridge_detailed_activity' }).Count -eq 1
}

Write-Host '--- the duplicate session counter is gone ---'
# The count is printed in the markdown above, so a sensor row repeating it was noise.
$allRows = @($cfg.views[0].cards | ForEach-Object {
    if ($_.type -eq 'vertical-stack') { $_.cards | Where-Object { $_.type -eq 'entities' } | ForEach-Object { $_.entities } }
    elseif ($_.type -eq 'entities') { $_.entities }
})
Test-That 'no card repeats the live-session sensor as a row' {
    @($allRows | Where-Object { $_.entity -eq 'sensor.agent_bridge_sessions' }).Count -eq 0
}
Test-That 'there is no longer a standalone toggle card beside the summary' {
    @($cfg.views[0].cards | Where-Object {
        $_.type -eq 'entities' -and @($_.entities | Where-Object { $_.entity -eq 'input_boolean.agent_bridge_detailed_activity' }).Count -gt 0
    }).Count -eq 0
}

Write-Host '--- a live session produces a card ---'
Test-That 'the control cards plus a session card are present' { @($cfg.views[0].cards).Count -ge 3 }

Write-Host '--- the session renders as one card, not a stack of loose ones ---'
$sessionCard = @($cfg.views[0].cards | Where-Object {
    $_.type -eq 'vertical-stack' -and @($_.cards | Where-Object { $_.type -eq 'markdown' -and $_.content -match 'my task' }).Count -gt 0
})[0]
Test-That 'the session card exists' { $null -ne $sessionCard }
Test-That 'the stack itself carries the border and background' {
    $sessionCard.card_mod.style -match ':host' -and
    $sessionCard.card_mod.style -match 'background' -and
    $sessionCard.card_mod.style -match 'border'
}
Test-That 'the state glow moved onto the stack' {
    $sessionCard.card_mod.style -match 'cpwait' -and $sessionCard.card_mod.style -match 'cpwork'
}
Test-That 'the gaps between sections are collapsed' {
    $sessionCard.card_mod.style -match 'margin-top:\s*0'
}
$sessionHeader = @($sessionCard.cards | Where-Object { $_.type -eq 'markdown' })[0]
Test-That 'the header no longer draws its own border' {
    $sessionHeader.card_mod.style -match 'border:\s*none'
}
Test-That 'the header no longer owns the glow' {
    $sessionHeader.card_mod.style -notmatch 'cpwait'
}
Test-That 'every inner card is transparent so one surface shows through' {
    $inner = @($sessionCard.cards | Where-Object { $_.type -in @('markdown', 'conditional') })
    $styled = foreach ($c in $inner) {
        if ($c.type -eq 'conditional') { $c.card.card_mod.style } else { $c.card_mod.style }
    }
    @($styled | Where-Object { $_ -notmatch 'background:\s*none' }).Count -eq 0
}

Write-Host '--- the decision row says what it actually does ---'
# On a multi-field question the per-field dropdowns carry the answer and this selector
# offers only "Cancel request" - but it was still labelled "Answer", so it read as one
# more question to fill in, sitting exactly where the last field should have been.
$decisionRows = @($sessionCard.cards | Where-Object {
    $_.type -eq 'conditional' -and $_.card.type -eq 'entities' -and
    "$($_.card.entities[0].entity)" -match '_decision$'
})
Test-That 'there are two variants of the decision row' { $decisionRows.Count -eq 2 }

$answerRow = @($decisionRows | Where-Object { $_.card.entities[0].name -eq 'Answer' })[0]
$cancelRow = @($decisionRows | Where-Object { $_.card.entities[0].name -eq 'Cancel this request' })[0]
Test-That 'one is Answer and the other is Cancel this request' {
    $null -ne $answerRow -and $null -ne $cancelRow
}
Test-That 'Answer shows only when no field dropdown is in play' {
    @($answerRow.conditions | Where-Object {
        "$($_.entity)" -match '_f1$' -and "$($_.state)" -eq 'Idle'
    }).Count -eq 1
}
Test-That 'Cancel shows only when a field dropdown is in play' {
    @($cancelRow.conditions | Where-Object {
        "$($_.entity)" -match '_f1$' -and "$($_.state_not)" -eq 'Idle'
    }).Count -eq 1
}
Test-That 'so the two can never appear together' {
    # Both variants key off the same signal, one on it and one against it, which is
    # what makes them mutually exclusive.
    $a = @($answerRow.conditions | Where-Object { "$($_.entity)" -match '_f1$' })[0]
    $c = @($cancelRow.conditions | Where-Object { "$($_.entity)" -match '_f1$' })[0]
    "$($a.entity)" -eq "$($c.entity)" -and "$($a.state)" -eq 'Idle' -and "$($c.state_not)" -eq 'Idle'
}

Write-Host '--- End session is a footer, well away from Send ---'
$stop = $sessionCard.cards[-1]
Test-That 'End session is the last thing on the card' { $stop.entity -match '_stop$' }
Test-That 'send feedback sits next to Send, not in the header' {
    # The header is the first thing to scroll away on a long card, which is exactly
    # when "Sending..." or "NOT sent" needs to be visible.
    $idx = 0
    $statusIdx = -1
    $replyIdx = -1
    foreach ($c in $sessionCard.cards) {
        if ($c.type -eq 'custom:layout-card') { $replyIdx = $idx }
        if ($c.type -eq 'conditional' -and $c.card.type -eq 'markdown' -and
            "$($c.conditions[0].entity)" -match '_activity$') { $statusIdx = $idx }
        $idx++
    }
    $statusIdx -gt $replyIdx -and $replyIdx -ge 0
}
Test-That 'it only shows while reporting on something you just did' {
    $status = @($sessionCard.cards | Where-Object { $_.type -eq 'conditional' -and $_.card.type -eq 'markdown' })[0]
    @($status.conditions[0].state) -contains 'Sending...' -and @($status.conditions[0].state) -contains 'Reply NOT sent'
}
Test-That 'it is separated by a hairline rather than butting up to Send' {
    @($stop.styles.card | Where-Object { $_.ContainsKey('border-top') }).Count -gt 0
}
Test-That 'it is left-aligned, unlike the right-aligned Send button' {
    @($stop.styles.grid | Where-Object { $_.ContainsKey('justify-items') -and $_['justify-items'] -eq 'start' }).Count -gt 0
}
Test-That 'it is rendered muted rather than as a primary action' {
    @($stop.styles.name | Where-Object { $_.ContainsKey('color') -and $_['color'] -match 'secondary-text-color' }).Count -gt 0
}
Test-That 'Send and End are not in the same row' {
    $replyRow = @($sessionCard.cards | Where-Object { $_.type -eq 'custom:layout-card' })[0]
    $inRow = @($replyRow.cards | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
    ($inRow -join ' ') -notmatch '_stop'
}
Test-That 'Send is still in the reply row' {
    $replyRow = @($sessionCard.cards | Where-Object { $_.type -eq 'custom:layout-card' })[0]
    $inRow = @($replyRow.cards | ForEach-Object { if ($_.ContainsKey('entity')) { [string]$_['entity'] } else { '' } })
    ($inRow -join ' ') -match '_submit'
}

Write-Host ''
Write-Host '--- a free-text field leaves no empty dropdown behind ---'
# A text field is answered through the reply box, not a dropdown, so its slot is
# published with only the 'Idle' option. It was still *started* on 'Choose...', a value
# not in its own option list, so the dashboard's "hide while Idle" condition failed and
# a blank dropdown appeared between the real ones.
$script:FieldStarts = @{}
$script:FieldOptions = @{}
function Publish-CopilotMqttMessage {
    param([string]$Topic, [string]$Payload, [hashtable]$Headers, [switch]$Retain)
    if ($Topic -match '/select/[^/]+/(f\d)/config$') {
        $script:FieldOptions[$Matches[1]] = ($Payload | ConvertFrom-Json).options
    }
}
function Invoke-HomeAssistantService {
    param([string]$Domain, [string]$Service, [hashtable]$Headers, [hashtable]$Data)
    if ("$($Data.entity_id)" -match '_(f\d)$') { $script:FieldStarts[$Matches[1]] = [string]$Data.option }
}
function Set-CopilotMqttEntityIds { param([string]$SessionId) }

$mixedFields = @(
    [pscustomobject]@{ Label = 'Glow';  Options = @('Amber', 'Blue'); IsText = $false }
    [pscustomobject]@{ Label = 'Notes'; Options = @();                IsText = $true }
    [pscustomobject]@{ Label = 'Pick';  Options = @('One', 'Two');    IsText = $false }
)
Publish-CopilotMqttDecisionFields -SessionId 'abc123de-f456-7890-abcd-ef1234567890' `
    -SessionName 'S' -Machine 'BOX' -Fields $mixedFields -Headers @{ Authorization = '******' }

Test-That 'the two choice fields start on Choose...' {
    $script:FieldStarts['f1'] -eq 'Choose...' -and $script:FieldStarts['f3'] -eq 'Choose...'
}
Test-That 'the free-text slot is parked on Idle, like an unused one' {
    $script:FieldStarts['f2'] -eq 'Idle' -and $script:FieldStarts['f4'] -eq 'Idle'
}
Test-That 'and its starting value is one of its own options' {
    @($script:FieldOptions['f2']) -contains $script:FieldStarts['f2']
}
Test-That 'the choice slots still carry their real options' {
    @($script:FieldOptions['f1']) -contains 'Amber' -and @($script:FieldOptions['f3']) -contains 'Two'
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green

