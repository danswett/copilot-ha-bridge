#Requires -Version 7.0
<#
.SYNOPSIS
    Tests the Claude Code AskUserQuestion parser against the real hook contract.

.DESCRIPTION
    The field names exercised here were read out of the shipping claude.exe (2.1.215),
    not from documentation. These tests need no Home Assistant and no Claude session.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\claude-ask-parser.ps1')

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

function Get-Fixture {
    param([string]$Name)
    Get-Content (Join-Path $PSScriptRoot "..\fixtures\$Name") -Raw | ConvertFrom-Json
}

Write-Host '--- single question ---'
$single = (Get-Fixture 'pretooluse-single.json')
$parsed = ConvertFrom-ClaudeAskUserQuestion -ToolInput $single.tool_input
Test-That 'the question text is carried through' { $parsed.Question -eq 'Which database should we use?' } $parsed.Question
Test-That 'both options become choices' { $parsed.Choices.Count -eq 2 } "$($parsed.Choices.Count)"
Test-That 'a description is folded into its label' { $parsed.Choices[0] -eq 'PostgreSQL (Recommended) - Best fit for relational data' } $parsed.Choices[0]
Test-That 'an option without a description stays bare' { $parsed.Choices[1] -eq 'SQLite' } $parsed.Choices[1]
Test-That 'a single question uses no per-field dropdowns' { $parsed.Fields.Count -eq 0 }

Write-Host '--- several questions ---'
$multi = (Get-Fixture 'pretooluse-multi.json')
$parsedMulti = ConvertFrom-ClaudeAskUserQuestion -ToolInput $multi.tool_input
Test-That 'each question becomes a field' { $parsedMulti.Fields.Count -eq 2 } "$($parsedMulti.Fields.Count)"
Test-That 'the header names the field' { $parsedMulti.Fields[0].Label -eq 'Database' } $parsedMulti.Fields[0].Label
Test-That 'the field carries its options for the dropdown' { $parsedMulti.Fields[0].Options.Count -eq 2 }
Test-That 'multiSelect is preserved' { $parsedMulti.Fields[1].MultiSelect -eq $true }
Test-That 'the prompt mentions both questions' { $parsedMulti.Question -match 'database' -and $parsedMulti.Question -match 'features' }
Test-That 'no flattened choice list is produced' { $parsedMulti.Choices.Count -eq 0 }

Write-Host '--- more questions than dropdowns ---'
$many = (Get-Fixture 'pretooluse-too-many.json')
$parsedMany = ConvertFrom-ClaudeAskUserQuestion -ToolInput $many.tool_input
Test-That 'it falls back to freeform' { $parsedMany.Fields.Count -eq 0 -and $parsedMany.Choices.Count -eq 0 }
Test-That 'every question survives in the outline' {
    (1..5 | ForEach-Object { $parsedMany.Question -match "$_\." }) -notcontains $false
}
Test-That 'options stay visible in the outline' { $parsedMany.Question -match 'Redis' }

Write-Host '--- degenerate input ---'
Test-That 'no questions yields a usable default' {
    (ConvertFrom-ClaudeAskUserQuestion -ToolInput ([pscustomobject]@{ questions = @() })).Question
}
Test-That 'null input does not throw' { (ConvertFrom-ClaudeAskUserQuestion -ToolInput $null).Question }
Test-That 'options given as plain strings still work' {
    $input = [pscustomobject]@{ questions = @([pscustomobject]@{ question = 'Pick'; options = @('A', 'B') }) }
    (ConvertFrom-ClaudeAskUserQuestion -ToolInput $input).Choices -join ',' -eq 'A,B'
}

Write-Host '--- truncation ---'
Test-That 'an overlong option label is truncated' {
    $long = 'x' * 900
    $input = [pscustomobject]@{ questions = @([pscustomobject]@{ question = 'Pick'; options = @([pscustomobject]@{ label = $long }) }) }
    $result = ConvertFrom-ClaudeAskUserQuestion -ToolInput $input
    $result.Choices[0].Length -le 600 -and $result.Choices[0].EndsWith('...')
}

Write-Host '--- hook event reading ---'
Test-That 'a full hook event parses' {
    $raw = Get-Content (Join-Path $PSScriptRoot '..\fixtures\pretooluse-single.json') -Raw
    $event = Get-ClaudeHookEvent -Raw $raw
    $event.tool_name -eq 'AskUserQuestion' -and $event.session_id -and $event.transcript_path
}
Test-That 'malformed JSON returns null rather than throwing' { $null -eq (Get-ClaudeHookEvent -Raw '{not json') }
Test-That 'empty input returns null' { $null -eq (Get-ClaudeHookEvent -Raw '   ') }

Write-Host '--- owning process lookup ---'
Test-That 'no claude ancestor resolves to 0' { (Get-ClaudeOwningProcessId -StartPid $PID) -eq 0 }
Test-That 'an unknown pid resolves to 0' { (Get-ClaudeOwningProcessId -StartPid 999999) -eq 0 }

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
