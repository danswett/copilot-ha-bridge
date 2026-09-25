<#
    Regression tests for Repair-DecisionToolArguments.

    Covers the current Copilot CLI ask_user shape (message + requestedSchema) as well
    as the legacy shape (question + choices) and the malformed-markup recovery path.
#>

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks\decision-bridge-common.ps1')

$script:Failures = 0

function Assert-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][string]$ExpectedQuestion,
        [string[]]$ExpectedChoices = @()
    )

    $args = $Json | ConvertFrom-Json
    $result = Repair-DecisionToolArguments -ToolArgs $args

    $gotChoices = @($result.Choices)
    $okQuestion = $result.Question -eq $ExpectedQuestion
    $okChoices = ($gotChoices.Count -eq $ExpectedChoices.Count)
    if ($okChoices) {
        for ($i = 0; $i -lt $ExpectedChoices.Count; $i++) {
            if ($gotChoices[$i] -ne $ExpectedChoices[$i]) { $okChoices = $false; break }
        }
    }

    if ($okQuestion -and $okChoices) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    else {
        $script:Failures++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if (-not $okQuestion) {
            Write-Host "        question expected: '$ExpectedQuestion'"
            Write-Host "        question actual  : '$($result.Question)'"
        }
        if (-not $okChoices) {
            Write-Host "        choices expected : $($ExpectedChoices -join ' | ')"
            Write-Host "        choices actual   : $($gotChoices -join ' | ')"
        }
    }
}

Write-Host "`n--- current CLI shape: message + requestedSchema ---"

Assert-Case -Name 'oneOf with titles' -ExpectedQuestion 'Reboot now?' `
    -ExpectedChoices @('Roll all three now', 'Only proxmox3 + node1', 'Defer all reboots') -Json @'
{
  "message": "Reboot now?",
  "requestedSchema": {
    "properties": {
      "reboot_plan": {
        "type": "string",
        "title": "Reboot plan",
        "oneOf": [
          { "const": "all_rolling",     "title": "Roll all three now" },
          { "const": "low_impact_only", "title": "Only proxmox3 + node1" },
          { "const": "defer_all",       "title": "Defer all reboots" }
        ]
      }
    }
  }
}
'@

Assert-Case -Name 'enum + enumNames labels' -ExpectedQuestion 'Pick a plan' `
    -ExpectedChoices @('Roll all three', 'Low impact only', 'Defer') -Json @'
{
  "message": "Pick a plan",
  "requestedSchema": {
    "properties": {
      "plan": {
        "type": "string",
        "enum": ["all", "low", "defer"],
        "enumNames": ["Roll all three", "Low impact only", "Defer"]
      }
    }
  }
}
'@

Assert-Case -Name 'bare enum without labels' -ExpectedQuestion 'Which node?' `
    -ExpectedChoices @('proxmox', 'proxmox2', 'proxmox3') -Json @'
{
  "message": "Which node?",
  "requestedSchema": {
    "properties": {
      "node": { "type": "string", "enum": ["proxmox", "proxmox2", "proxmox3"] }
    }
  }
}
'@

Assert-Case -Name 'boolean becomes Yes/No' -ExpectedQuestion 'Overwrite production data?' `
    -ExpectedChoices @('Yes', 'No') -Json @'
{
  "message": "Overwrite production data?",
  "requestedSchema": {
    "properties": { "proceed": { "type": "boolean", "title": "Overwrite" } }
  }
}
'@

Assert-Case -Name 'multi-select items.enum' -ExpectedQuestion 'Which services?' `
    -ExpectedChoices @('frigate', 'plex', 'pihole') -Json @'
{
  "message": "Which services?",
  "requestedSchema": {
    "properties": {
      "svc": { "type": "array", "items": { "type": "string", "enum": ["frigate", "plex", "pihole"] } }
    }
  }
}
'@

Assert-Case -Name 'free-text field stays freeform' -ExpectedQuestion 'What name?' `
    -ExpectedChoices @() -Json @'
{
  "message": "What name?",
  "requestedSchema": { "properties": { "name": { "type": "string" } } }
}
'@

Assert-Case -Name 'two-option-field form no longer flattens (per-field dropdowns)' `
    -ExpectedQuestion 'Configure it' `
    -ExpectedChoices @() -Json @'
{
  "message": "Configure it",
  "requestedSchema": {
    "properties": {
      "a": { "type": "string", "enum": ["x", "y"] },
      "b": { "type": "boolean" }
    }
  }
}
'@

Assert-Case -Name 'a mixed choice + free-text form is answerable, not flattened to an outline' `
    -ExpectedQuestion 'Pick' `
    -ExpectedChoices @() -Json @'
{
  "message": "Pick",
  "requestedSchema": {
    "properties": {
      "scope": {
        "type": "string", "title": "Scope", "default": "Patch only",
        "oneOf": [ { "const": "both", "title": "Both" }, { "const": "patch", "title": "Patch only" } ]
      },
      "notes": { "type": "string", "title": "Notes" }
    }
  }
}
'@

Assert-Case -Name 'multi-field form exposes per-field options, not a flattened list' `
    -ExpectedQuestion 'Two things' `
    -ExpectedChoices @() -Json @'
{
  "message": "Two things",
  "requestedSchema": {
    "properties": {
      "visibility": { "type":"string","title":"Visibility","oneOf":[{"const":"public","title":"Public"},{"const":"private","title":"Private"}] },
      "push": { "type":"string","title":"Push","enum":["Yes","No"] }
    }
  }
}
'@

Write-Host "`n--- per-field extraction for the tabbed native form ---"

$twoField = @'
{
  "message": "Two things",
  "requestedSchema": {
    "properties": {
      "visibility": { "type":"string","title":"Visibility","oneOf":[{"const":"public","title":"Public"},{"const":"private","title":"Private"}] },
      "push": { "type":"string","title":"Push","enum":["Yes","No"] }
    }
  }
}
'@ | ConvertFrom-Json
$parsedFields = @((Repair-DecisionToolArguments -ToolArgs $twoField).Fields)
if ($parsedFields.Count -eq 2 -and
    $parsedFields[0].Label -eq 'Visibility' -and
    ($parsedFields[0].Options -join ',') -eq 'Public,Private' -and
    $parsedFields[1].Label -eq 'Push' -and
    ($parsedFields[1].Options -join ',') -eq 'Yes,No') {
    Write-Host '  PASS  fields carry per-field labels and options in order' -ForegroundColor Green
}
else {
    $script:Failures++
    Write-Host '  FAIL  fields carry per-field labels and options in order' -ForegroundColor Red
    $parsedFields | ForEach-Object { Write-Host "        $($_.Label): $($_.Options -join ',')" }
}

$oneField = '{"message":"One","requestedSchema":{"properties":{"c":{"type":"string","enum":["A","B"]}}}}' | ConvertFrom-Json
$oneParsed = Repair-DecisionToolArguments -ToolArgs $oneField
if (@($oneParsed.Choices).Count -eq 2 -and @($oneParsed.Fields).Count -eq 1) {
    Write-Host '  PASS  single-field form still yields a plain choice list' -ForegroundColor Green
}
else {
    $script:Failures++
    Write-Host "  FAIL  single-field form still yields a plain choice list (choices=$(@($oneParsed.Choices).Count) fields=$(@($oneParsed.Fields).Count))" -ForegroundColor Red
}

Write-Host "`n--- mixed forms, and the prompts the dashboard must refuse ---"
# The bug this covers: one free-text field among dropdowns used to discard the whole
# field set, leaving a card with no options while the terminal showed an arrow-key
# form. Typed answers were then injected into that prompt and silently discarded.
$mixed = @'
{
  "message": "Pick",
  "requestedSchema": {
    "properties": {
      "look":   { "type":"string","title":"Look","enum":["Good","Bad","Ugly","Fine"] },
      "button": { "type":"string","title":"Button","enum":["Yes","No","Maybe"] },
      "detail": { "type":"string","title":"Detail" }
    }
  }
}
'@ | ConvertFrom-Json
$mixedParsed = Repair-DecisionToolArguments -ToolArgs $mixed
$mixedFields = @($mixedParsed.Fields)

function Test-Case {
    param([string]$Name, [scriptblock]$Condition)
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { }
    if ($ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Failures++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

Test-Case 'every field survives, including the free-text one' { $mixedFields.Count -eq 3 }
Test-Case 'the dropdown fields keep their options' {
    ($mixedFields[0].Options -join ',') -eq 'Good,Bad,Ugly,Fine' -and
    ($mixedFields[1].Options -join ',') -eq 'Yes,No,Maybe'
}
Test-Case 'the free-text field is flagged rather than dropped' {
    (Test-DecisionFieldIsText -Field $mixedFields[2]) -and
    -not (Test-DecisionFieldIsText -Field $mixedFields[0])
}
Test-Case 'a mixed form is answerable from the dashboard' {
    Test-DecisionFieldsAnswerable -Fields $mixedFields
}
Test-Case 'it is not marked terminal-only' { -not $mixedParsed.TerminalOnly }

# Two free-text fields cannot map: there is only one Reply box.
$twoText = '{"message":"Q","requestedSchema":{"properties":{"a":{"type":"string","title":"A"},"b":{"type":"string","title":"B"}}}}' | ConvertFrom-Json
$twoTextParsed = Repair-DecisionToolArguments -ToolArgs $twoText
Test-Case 'two free-text fields are refused, not silently accepted' {
    -not (Test-DecisionFieldsAnswerable -Fields @($twoTextParsed.Fields)) -and $twoTextParsed.TerminalOnly
}

# More fields than the card publishes dropdowns for.
$fiveField = '{"message":"Q","requestedSchema":{"properties":{"a":{"type":"string","enum":["1","2"]},"b":{"type":"string","enum":["1","2"]},"c":{"type":"string","enum":["1","2"]},"d":{"type":"string","enum":["1","2"]},"e":{"type":"string","enum":["1","2"]}}}}' | ConvertFrom-Json
$fiveParsed = Repair-DecisionToolArguments -ToolArgs $fiveField
Test-Case 'a five-field form is refused rather than half-answered' { $fiveParsed.TerminalOnly }
Test-Case 'and it still spells the fields out in the question' { $fiveParsed.Question -match 'Answer these' }

Test-Case 'a single free-text field stays plain freeform' {
    $one = '{"message":"Q","requestedSchema":{"properties":{"a":{"type":"string","title":"A"}}}}' | ConvertFrom-Json
    $p = Repair-DecisionToolArguments -ToolArgs $one
    -not $p.TerminalOnly -and @($p.Choices).Count -eq 0
}

Write-Host "`n--- legacy shape must still work ---"

Assert-Case -Name 'legacy question + choices array' -ExpectedQuestion 'Legacy question?' `
    -ExpectedChoices @('A', 'B') -Json @'
{ "question": "Legacy question?", "choices": ["A", "B"] }
'@

Assert-Case -Name 'legacy question only' -ExpectedQuestion 'Just asking' -ExpectedChoices @() -Json @'
{ "question": "Just asking" }
'@

Write-Host "`n--- malformed markup recovery must still work ---"

Assert-Case -Name 'leaked choices in question' -ExpectedQuestion 'Real question?' `
    -ExpectedChoices @('A', 'B') -Json @'
{ "question": "Real question?</question>\n<parameter name=\"choices\">[\"A\",\"B\"]" }
'@

Assert-Case -Name 'leaked requestedSchema recovers oneOf buttons' -ExpectedQuestion 'Which plan?' `
    -ExpectedChoices @('Roll now', 'Defer') -Json @'
{ "message": "Which plan?</message>\n<parameter name=\"requestedSchema\">{\"properties\":{\"plan\":{\"type\":\"string\",\"oneOf\":[{\"const\":\"now\",\"title\":\"Roll now\"},{\"const\":\"defer\",\"title\":\"Defer\"}]}}}</parameter>" }
'@

Assert-Case -Name 'leaked requestedSchema without closing message tag' -ExpectedQuestion 'Which node?' `
    -ExpectedChoices @('proxmox2', 'proxmox3') -Json @'
{ "message": "Which node?\n<parameter name=\"requestedSchema\">{\"properties\":{\"node\":{\"type\":\"string\",\"enum\":[\"proxmox2\",\"proxmox3\"]}}}" }
'@

Assert-Case -Name 'truncated leaked requestedSchema still recovers' -ExpectedQuestion 'Pick one' `
    -ExpectedChoices @('Alpha', 'Beta') -Json @'
{ "message": "Pick one</message>\n<parameter name=\"requestedSchema\">{\"properties\":{\"x\":{\"type\":\"string\",\"oneOf\":[{\"const\":\"a\",\"title\":\"Alpha\"},{\"const\":\"b\",\"title\":\"Beta\"}" }
'@

Assert-Case -Name 'requestedSchema passed as a JSON string' -ExpectedQuestion 'String schema?' `
    -ExpectedChoices @('Yes', 'No') -Json @'
{ "message": "String schema?", "requestedSchema": "{\"properties\":{\"ok\":{\"type\":\"boolean\"}}}" }
'@

Assert-Case -Name 'question mentioning a parameter tag is not truncated' `
    -ExpectedQuestion 'Should I add a <parameter name="foo"> block?' -ExpectedChoices @() -Json @'
{ "message": "Should I add a <parameter name=\"foo\"> block?" }
'@

Write-Host "`n--- degenerate input ---"

Assert-Case -Name 'empty args fall back to default' `
    -ExpectedQuestion 'Copilot CLI needs your input.' -ExpectedChoices @() -Json '{}'

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) test(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
exit 0
