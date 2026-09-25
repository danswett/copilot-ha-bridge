<#
    Regression tests for Repair-DecisionToolArguments.

    Covers the current Copilot CLI ask_user shape (message + requestedSchema) as well
    as the legacy shape (question + choices) and the malformed-markup recovery path.
#>

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks\decision-bridge-common.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks\decision-inject.ps1')

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

Write-Host "`n--- an injected answer is checked against what the CLI recorded ---"
# The failure this catches: the injector drives an arrow-key list by index, so one
# dropped keystroke selects the neighbouring option and the prompt reports it as the
# user's choice. Seen live - a field picked as index 1 in Home Assistant came back
# from the CLI as index 0 - and nothing downstream could tell.
$checkFields = @(
    [pscustomobject]@{ Label = 'Alignment'; Options = @('Aligned', 'Closer', 'No change'); IsText = $false }
    [pscustomobject]@{ Label = 'Notes';     Options = @();                                  IsText = $true }
)

Test-Case 'a matching answer passes' {
    Test-CopilotAnswerMatchesSelections `
        -ResultContent 'User responded: alignment=Closer, notes=whatever they typed' `
        -Fields $checkFields -Selections @('Closer', 'whatever they typed')
}
Test-Case 'the neighbouring option is caught' {
    -not (Test-CopilotAnswerMatchesSelections `
        -ResultContent 'User responded: alignment=Aligned, notes=whatever they typed' `
        -Fields $checkFields -Selections @('Closer', 'whatever they typed'))
}
Test-Case 'a reworded free-text field is not treated as a mismatch' {
    Test-CopilotAnswerMatchesSelections `
        -ResultContent 'User responded: alignment=Closer, notes=trimmed differently' `
        -Fields $checkFields -Selections @('Closer', '  trimmed differently  ')
}
Test-Case 'no recorded result yet is not a mismatch' {
    Test-CopilotAnswerMatchesSelections -ResultContent '' -Fields $checkFields -Selections @('Closer', 'x')
}
Test-Case 'nothing injected is not a mismatch' {
    Test-CopilotAnswerMatchesSelections -ResultContent 'anything' -Fields @() -Selections @()
}

Write-Host "`n--- a failed tool call must not kill the reconcile loop ---"
# The failure this catches: a tool call that FAILED records `error` instead of
# `result`, and reaching through `.result.content` makes StrictMode throw. That
# terminating error propagated out of the daemon's reconcile loop, so one unrelated
# failed tool anywhere in the transcript tail left every armed card unanswerable -
# Send from Home Assistant silently did nothing. Seen live: the loop threw
# "The property 'result' cannot be found on this object" every cycle for 3 minutes.
$askTranscript = Join-Path ([IO.Path]::GetTempPath()) "bridge-askstate-$([guid]::NewGuid()).jsonl"
@(
    '{"type":"tool.execution_complete","timestamp":"2026-09-24T21:00:00Z","data":{"toolCallId":"failed-1","success":false,"error":{"message":"boom"}}}'
    '{"type":"tool.execution_start","timestamp":"2026-09-24T21:01:00Z","data":{"toolName":"ask_user","toolCallId":"ask-1"}}'
) | Set-Content -Path $askTranscript -Encoding UTF8

Test-Case 'a failed tool call in the tail does not throw' {
    # StrictMode is what turns the missing property into a terminating error, and the
    # daemon runs under it (it leaks in from a dot-sourced library), so the test has
    # to opt in or it cannot see the bug at all.
    $state = & {
        Set-StrictMode -Version Latest
        Get-CopilotAskUserState -TranscriptPath $askTranscript
    }
    $state.Started -and $state.Pending -and $state.ToolCallId -eq 'ask-1'
}

Add-Content -Path $askTranscript -Encoding UTF8 -Value `
    '{"type":"tool.execution_complete","timestamp":"2026-09-24T21:02:00Z","data":{"toolCallId":"ask-1","result":{"content":"User responded: a=B"}}}'

Test-Case 'and the recorded answer is still captured once it completes' {
    $state = & {
        Set-StrictMode -Version Latest
        Get-CopilotAskUserState -TranscriptPath $askTranscript
    }
    (-not $state.Pending) -and $state.ResultContent -eq 'User responded: a=B'
}

Remove-Item $askTranscript -Force -ErrorAction SilentlyContinue

Write-Host "`n--- every choice field actually gets its keystrokes ---"
# The failure this catches is silent and severe: the per-field payloads were built by
# putting $null in a List[string] to mean "this field is not typed", but PowerShell
# stores that as an EMPTY STRING. Every choice field then looked like a typed field
# with nothing to type, so no arrow was ever sent and each one committed at its FIRST
# option - recorded by the CLI as the user's own choice, with nothing to show it was
# wrong. Seen live three times: an answer of index 1 came back as index 0 each time.
$esc = [string][char]27
$formFields = @(
    [pscustomobject]@{ Label = 'Glow';   Options = @('Amber', 'Blue', 'No glow'); IsText = $false }
    [pscustomobject]@{ Label = 'Notes';  Options = @();                           IsText = $true }
    [pscustomobject]@{ Label = 'Rigged'; Options = @('First', 'Second', 'Third'); IsText = $false }
)
$steps = @(Get-BridgeFormPayloads -Fields $formFields -Selections @('No glow', 'a note', 'Third'))

Test-Case 'one payload per field' { $steps.Count -eq 3 }
Test-Case 'a third option sends two Down sequences, not nothing' {
    $steps[0].Payload -eq ($esc + '[B' + $esc + '[B') -and $steps[0].Payload.Length -eq 6
}
Test-Case 'the text field carries its text' {
    $steps[1].IsText -and $steps[1].Payload -eq 'a note'
}
Test-Case 'and the last field gets its own presses' {
    $steps[2].Payload -eq ($esc + '[B' + $esc + '[B') -and -not $steps[2].IsText
}
Test-Case 'a first option needs no presses' {
    @(Get-BridgeFormPayloads -Fields @($formFields[0]) -Selections @('Amber'))[0].Payload -eq ''
}
Test-Case 'an empty text field stays empty without becoming a choice' {
    $s = @(Get-BridgeFormPayloads -Fields @($formFields[1]) -Selections @(''))[0]
    $s.IsText -and $s.Payload -eq ''
}
Test-Case 'an option that is not in the list is refused' {
    $threw = $false
    try { [void](Get-BridgeFormPayloads -Fields @($formFields[0]) -Selections @('Nope')) }
    catch { $threw = $true }
    $threw
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
