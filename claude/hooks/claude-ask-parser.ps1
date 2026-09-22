<#
.SYNOPSIS
    Parses a Claude Code AskUserQuestion hook event into the bridge's decision shape.

.DESCRIPTION
    Claude Code delivers hook events as JSON on stdin. A PreToolUse event carries:

        session_id, transcript_path, cwd, hook_event_name, tool_name,
        tool_input, permission_mode

    and for AskUserQuestion the tool_input is:

        { questions: [ { question, header, multiSelect,
                         options: [ { label, description } ] } ] }

    These field names were read out of the shipping claude.exe (2.1.215) rather than
    documentation, so they reflect what the tool actually sends.

    The output matches what Set-CopilotMqttDecision already expects, so the Claude
    adapter reuses the proven Home Assistant layer unchanged:

        @{ Question = <string>; Choices = <string[]>; Fields = <object[]> }

    Claude always offers "Other" for free text, so no synthetic Other option is added.
#>

Set-StrictMode -Version Latest

$script:ClaudeMaxFields = 4
$script:ClaudeMaxQuestionLength = 6000
$script:ClaudeMaxChoiceLength = 600

function ConvertFrom-ClaudeAskUserQuestion {
    <#
        Returns the decision shape for a Claude AskUserQuestion tool_input.

        One question becomes a single dropdown. Several become one dropdown per
        question, which is how the bridge avoids a combinatorial option list. More
        than $ClaudeMaxFields falls back to freeform with a numbered outline, so
        nothing is ever silently dropped.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $ToolInput
    )

    $questions = @()
    if ($null -ne $ToolInput -and $ToolInput.PSObject.Properties.Name -contains 'questions') {
        $questions = @($ToolInput.questions)
    }

    if ($questions.Count -eq 0) {
        return [pscustomobject]@{
            Question = 'Claude needs an answer.'
            Choices  = @()
            Fields   = @()
        }
    }

    $fields = foreach ($question in $questions) {
        $labels = @()
        if ($question.PSObject.Properties.Name -contains 'options') {
            $labels = @(
                foreach ($option in @($question.options)) {
                    $label = if ($option -is [string]) { $option } else { [string]$option.label }
                    # A description carries real decision content, so it is folded into
                    # the label rather than dropped - the dashboard shows labels only.
                    if ($option -isnot [string] -and
                        $option.PSObject.Properties.Name -contains 'description' -and
                        $option.description) {
                        $label = "$label - $($option.description)"
                    }
                    if ($label.Length -gt $script:ClaudeMaxChoiceLength) {
                        $label = $label.Substring(0, $script:ClaudeMaxChoiceLength - 3) + '...'
                    }
                    $label
                }
            )
        }

        [pscustomobject]@{
            # Label and Options are the contract Set-CopilotMqttDecision consumes for
            # per-field dropdowns; Title and MultiSelect are extra context for logging
            # and the freeform outline.
            Label       = if ($question.PSObject.Properties.Name -contains 'header' -and $question.header) {
                              [string]$question.header
                          } else {
                              [string]$question.question
                          }
            Title       = [string]$question.question
            Options     = $labels
            MultiSelect = [bool]($question.PSObject.Properties.Name -contains 'multiSelect' -and $question.multiSelect)
        }
    }

    $fields = @($fields)
    $prompt = ($fields | ForEach-Object { $_.Title }) -join ' / '

    if ($fields.Count -eq 1) {
        return [pscustomobject]@{
            Question = Limit-ClaudeText -Text $fields[0].Title
            Choices  = $fields[0].Options
            Fields   = @()
        }
    }

    if ($fields.Count -le $script:ClaudeMaxFields) {
        return [pscustomobject]@{
            Question = Limit-ClaudeText -Text $prompt
            Choices  = @()
            Fields   = $fields
        }
    }

    # Too many questions for dropdowns: keep every option visible in the text so the
    # user can still answer accurately in the reply box.
    $outline = for ($i = 0; $i -lt $fields.Count; $i++) {
        $options = if ($fields[$i].Options.Count) { ': ' + ($fields[$i].Options -join ' | ') } else { '' }
        "$($i + 1). $($fields[$i].Title)$options"
    }

    [pscustomobject]@{
        Question = Limit-ClaudeText -Text (($prompt, ($outline -join "`n")) -join "`n`n")
        Choices  = @()
        Fields   = @()
    }
}

function Limit-ClaudeText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text.Length -le $script:ClaudeMaxQuestionLength) { return $Text }
    $Text.Substring(0, $script:ClaudeMaxQuestionLength - 20) + "`n[truncated]"
}

function Get-ClaudeHookEvent {
    <#
        Reads and parses the hook event from stdin. Returns $null when nothing usable
        arrives, so a caller can fail open rather than block Claude.
    #>
    param([string]$Raw)

    if (-not $Raw) { $Raw = [Console]::In.ReadToEnd() }
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return $Raw | ConvertFrom-Json } catch { return $null }
}

function Get-ClaudeOwningProcessId {
    <#
        Finds the claude process that owns this hook.

        Claude Code has no equivalent of Copilot's inuse.<pid>.lock, but a hook runs as
        a descendant of the session it belongs to, so walking up the parent chain
        identifies it unambiguously - and correctly picks the right one when several
        sessions are open.
    #>
    param([int]$StartPid = $PID, [int]$MaxDepth = 12)

    $current = $StartPid
    for ($depth = 0; $depth -lt $MaxDepth; $depth++) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
        if (-not $process) { return 0 }
        if ($process.Name -match '^claude(\.exe)?$') { return [int]$process.ProcessId }
        if (-not $process.ParentProcessId -or $process.ParentProcessId -eq $current) { return 0 }
        $current = [int]$process.ParentProcessId
    }
    return 0
}
