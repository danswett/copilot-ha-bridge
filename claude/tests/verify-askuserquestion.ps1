#Requires -Version 7.0
<#
.SYNOPSIS
    Verifies the AskUserQuestion path against a real Claude Code session.

.DESCRIPTION
    Every other part of the Claude adapter was verified live. AskUserQuestion could
    not be, because the tool is not exposed to this account or build: asked to use it,
    Claude searched for it three times and reported it unavailable, and it is absent
    from the tool list Claude advertises at startup. The handling is therefore built
    to the contract embedded in the shipping binary and covered by unit tests, but has
    never run against a question Claude actually asked.

    This script closes that gap automatically whenever the tool appears. It:

      1. asks Claude which tools it advertises, and stops with a clear explanation if
         AskUserQuestion is not among them;
      2. otherwise drives a real interactive session, captures the PreToolUse payload
         Claude emits, and checks it against the parser;
      3. reports any difference between the real payload and the assumed contract, so
         a drift in field names is caught rather than guessed at.

    Re-run it after a Claude Code upgrade. It creates a scratch project under TEMP and
    removes it afterwards.

.PARAMETER KeepScratch
    Leave the scratch project in place for inspection.
#>

[CmdletBinding()]
param([switch]$KeepScratch)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\claude-ask-parser.ps1')

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

$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) {
    Write-Host 'Claude Code is not installed; nothing to verify.' -ForegroundColor Yellow
    exit 2
}

$authStatus = & claude auth status 2>&1 | Out-String
if ($authStatus -notmatch '"loggedIn"\s*:\s*true') {
    Write-Host 'Not signed in to Claude Code. Run: claude auth login' -ForegroundColor Yellow
    exit 2
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) "claude-auq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory (Join-Path $scratch '.claude') -Force | Out-Null

try {
    # ------------------------------------------------------------ availability
    Write-Host '--- is AskUserQuestion available? ---'
    Push-Location $scratch
    $raw = & claude -p 'say ok' --output-format stream-json --verbose 2>&1 | Out-String
    Pop-Location

    $init = ($raw -split "`n") | Where-Object { $_ -match '"type"\s*:\s*"system"' } | Select-Object -First 1
    if (-not $init) {
        Write-Host '  Could not read the tool list from Claude.' -ForegroundColor Yellow
        exit 2
    }

    $tools = @(($init | ConvertFrom-Json).tools)
    $available = $tools -contains 'AskUserQuestion'
    Write-Host "  Claude advertises $($tools.Count) tools; AskUserQuestion present: $available"

    if (-not $available) {
        Write-Host ''
        Write-Host 'AskUserQuestion is not exposed to this build or account, so the live' -ForegroundColor Yellow
        Write-Host 'verification cannot run. This is not a bridge fault: the tool is compiled' -ForegroundColor Yellow
        Write-Host 'into claude.exe (CLAUDE_CODE_QUESTION_PREVIEW_FORMAT and the tool''s own' -ForegroundColor Yellow
        Write-Host 'description are present) but is not offered, exactly like EnterPlanMode.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Meanwhile the handling is covered by claude/tests/test-claude-ask-parser.ps1,'
        Write-Host 'built against the contract read out of the shipping binary. Re-run this'
        Write-Host 'script after a Claude Code upgrade to check again.'
        exit 3
    }

    # ------------------------------------------------------------- live capture
    Write-Host '--- capturing a real AskUserQuestion payload ---'
    $captureDir = Join-Path $scratch 'captured'
    $captureScript = Join-Path $scratch 'capture.ps1'
    @"
`$raw = [Console]::In.ReadToEnd()
if (-not (Test-Path '$captureDir')) { New-Item -ItemType Directory '$captureDir' -Force | Out-Null }
`$raw | Set-Content (Join-Path '$captureDir' ("event-" + [DateTimeOffset]::Now.ToUnixTimeMilliseconds() + ".json")) -Encoding UTF8
exit 0
"@ | Set-Content $captureScript -Encoding UTF8

    $pwshPath = (Get-Command pwsh).Source
    @{
        hooks = @{
            PreToolUse = @(@{
                matcher = 'AskUserQuestion'
                hooks   = @(@{ type = 'command'; command = "`"$pwshPath`" -NoProfile -File `"$captureScript`""; timeout = 15 })
            })
        }
    } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $scratch '.claude\settings.json') -Encoding UTF8

    # An interactive session is required: the tool prompts, so it is not offered in
    # print mode. The prompt is typed in with the same console injection the bridge
    # uses to deliver replies.
    $exe = Join-Path (Split-Path $claude.Source) 'claude.exe'
    if (-not (Test-Path $exe)) { $exe = $claude.Source }
    $session = Start-Process -FilePath $exe -WorkingDirectory $scratch -PassThru -WindowStyle Minimized
    try {
        Start-Sleep -Seconds 14
        . (Join-Path $HOME '.agent-ha-bridge\hooks\decision-inject.ps1')
        Initialize-CopilotConsoleInjector
        [void][CopilotCli.ConsoleInjector]::Send(
            [uint32]$session.Id,
            'Use the AskUserQuestion tool to ask me whether to use PostgreSQL or SQLite, with a short description for each option.',
            $true, 500)

        $deadline = [DateTimeOffset]::Now.AddSeconds(90)
        while ([DateTimeOffset]::Now -lt $deadline) {
            Start-Sleep -Seconds 3
            if ((Test-Path $captureDir) -and @(Get-ChildItem $captureDir -File).Count -gt 0) { break }
        }
    }
    finally {
        Stop-Process -Id $session.Id -Force -ErrorAction SilentlyContinue
    }

    $captured = @(Get-ChildItem $captureDir -File -ErrorAction SilentlyContinue)
    Test-That 'Claude emitted an AskUserQuestion PreToolUse event' { $captured.Count -gt 0 } "$($captured.Count) event(s)"
    if ($captured.Count -eq 0) { exit 1 }

    $event = Get-Content $captured[0].FullName -Raw | ConvertFrom-Json

    # ------------------------------------------------------- contract assertions
    Write-Host '--- the real payload versus the assumed contract ---'
    foreach ($field in @('session_id', 'transcript_path', 'cwd', 'hook_event_name', 'tool_name', 'tool_input')) {
        Test-That "carries $field" { $event.PSObject.Properties.Name -contains $field }
    }
    Test-That 'tool_name is AskUserQuestion' { $event.tool_name -eq 'AskUserQuestion' } $event.tool_name
    Test-That 'tool_input has a questions array' {
        $event.tool_input.PSObject.Properties.Name -contains 'questions' -and @($event.tool_input.questions).Count -gt 0
    }

    $question = @($event.tool_input.questions)[0]
    foreach ($field in @('question', 'options')) {
        Test-That "a question carries $field" { $question.PSObject.Properties.Name -contains $field }
    }
    $option = @($question.options)[0]
    Test-That 'an option carries label' {
        $option -is [string] -or $option.PSObject.Properties.Name -contains 'label'
    }

    # ------------------------------------------------------------- parser output
    Write-Host '--- the parser handles it ---'
    $parsed = ConvertFrom-ClaudeAskUserQuestion -ToolInput $event.tool_input
    Test-That 'a question is produced' { -not [string]::IsNullOrWhiteSpace($parsed.Question) } $parsed.Question
    Test-That 'choices or fields are produced' {
        @($parsed.Choices).Count -gt 0 -or @($parsed.Fields).Count -gt 0
    } "choices=$(@($parsed.Choices).Count) fields=$(@($parsed.Fields).Count)"
    Test-That 'every option survives' {
        $expected = @($question.options).Count
        if (@($parsed.Fields).Count -gt 0) { @($parsed.Fields[0].Options).Count -eq $expected }
        else { @($parsed.Choices).Count -eq $expected }
    }

    Write-Host ''
    Write-Host 'Captured payload:' -ForegroundColor Cyan
    ($event.tool_input | ConvertTo-Json -Depth 6) -split "`n" | Select-Object -First 25 | ForEach-Object { "  $_" }
}
finally {
    if (-not $KeepScratch) { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }
    else { Write-Host "Scratch kept at $scratch" }
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'AskUserQuestion verified end to end' -ForegroundColor Green
