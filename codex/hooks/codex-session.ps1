<#
.SYNOPSIS
    Codex CLI session tracking for the Home Assistant bridge.

.DESCRIPTION
    Codex is the easiest of the three front ends to track, because its hooks carry
    almost everything the bridge needs:

      SessionStart       session_id, transcript_path, cwd, model, permission_mode, source
      UserPromptSubmit   + turn_id, prompt
      PreToolUse         + tool_name, tool_input, tool_use_id
      Stop               + stop_hook_active, last_assistant_message
      SessionEnd         + reason

    Those field names were captured from real sessions on Codex 0.155.0-alpha.6, not
    taken from documentation.

    Two consequences for this file. Activity does not need the transcript at all - the
    hooks report each prompt, tool call and reply directly - so the daemon only reads
    the rollout for reasoning. And liveness is authoritative rather than inferred:
    Codex fires an explicit SessionEnd, which neither Copilot nor Claude does, so a
    session is retired the moment it exits instead of when its process disappears.

    Two things Codex demands that the others do not, both learned the hard way:

    * Hooks must be **trusted** before they run. An untrusted hook is skipped in
      complete silence - no error, no log line - which looks exactly like a hook that
      was never registered. The installer explains this; the first run prompts.
    * The `command` string must not be shell-quoted. A quoted executable path fails
      with `hook exited with code 1`, while the same command unquoted runs fine.
#>

Set-StrictMode -Version Latest

$script:CodexStateRoot = Join-Path $env:TEMP 'copilot-bridge-codex'
# Codex writes rollouts under CODEX_HOME/sessions/<yyyy>/<MM>/<dd>/.
$script:CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$script:CodexSessionStaleMinutes = 240

function Get-CodexStateRoot {
    if (-not (Test-Path -LiteralPath $script:CodexStateRoot)) {
        New-Item -ItemType Directory -Path $script:CodexStateRoot -Force | Out-Null
    }
    $script:CodexStateRoot
}

function Get-CodexSafeSessionKey {
    <# Filesystem-safe key, so a hostile session id cannot escape the state directory. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SessionId)

    $clean = ($SessionId -replace '[^a-zA-Z0-9._-]', '').TrimStart('.')
    if ([string]::IsNullOrWhiteSpace($clean)) { return 'unknown' }
    if ($clean.Length -gt 96) { $clean = $clean.Substring(0, 96) }
    $clean
}

function Get-CodexSessionDisplay {
    <#
        Names a session after its working directory, prefixed so its cards are
        distinguishable from Copilot's and Claude's on a shared dashboard.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SessionId,
        [string]$WorkingDirectory
    )

    $folder = if ($WorkingDirectory) { Split-Path -Leaf $WorkingDirectory } else { '' }
    if ([string]::IsNullOrWhiteSpace($folder)) {
        $folder = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))
    }

    $name = "Codex: $folder"
    if ($name.Length -gt 120) { $name = $name.Substring(0, 117) + '...' }

    # The working directory is attacker-controllable - a folder called "{{ ... }}" is
    # enough - so template syntax is neutralised before this can reach a card.
    if (Get-Command Remove-CopilotTemplateMarkup -ErrorAction SilentlyContinue) {
        $name = Remove-CopilotTemplateMarkup -Text $name
    }

    [pscustomobject]@{
        Name    = $name
        Machine = [Environment]::MachineName
    }
}

function Get-CodexOwningProcessId {
    <#
        Finds the codex process that owns this hook by walking the parent chain, the
        same approach the Claude adapter uses: a hook runs as a descendant of its
        session, so this identifies the right one even with several open.
    #>
    param([int]$StartPid = $PID, [int]$MaxDepth = 12)

    $current = $StartPid
    for ($depth = 0; $depth -lt $MaxDepth; $depth++) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
        if (-not $process) { return 0 }
        # Exact match: codex-windows-sandbox-setup and codex-command-runner also exist.
        if ($process.Name -match '^codex(\.exe)?$') { return [int]$process.ProcessId }
        if (-not $process.ParentProcessId -or $process.ParentProcessId -eq $current) { return 0 }
        $current = [int]$process.ParentProcessId
    }
    return 0
}

function Write-CodexSessionRegistration {
    <#
        Records a session, its transcript and its owning process.

        Status is carried here as well, because Codex reports it directly: a turn
        starts at UserPromptSubmit and ends at Stop, so the daemon never has to guess
        from transcript freshness.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$TranscriptPath,
        [string]$WorkingDirectory,
        [string]$Model,
        [string]$Status,
        [string]$Activity,
        [int]$ProcessId = 0,
        [switch]$Ended
    )

    $path = Join-Path (Get-CodexStateRoot) ((Get-CodexSafeSessionKey -SessionId $SessionId) + '.json')
    $existing = if (Test-Path -LiteralPath $path) {
        try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $null }
    }

    # Later events carry less than SessionStart did, so anything already known is kept
    # rather than blanked.
    function Resolve-Field {
        param([string]$New, [string]$Field)
        if (-not [string]::IsNullOrWhiteSpace($New)) { return $New }
        if ($existing -and $existing.PSObject.Properties.Name -contains $Field) { return [string]$existing.$Field }
        ''
    }

    if ($ProcessId -le 0 -and $existing -and $existing.PSObject.Properties.Name -contains 'ProcessId') {
        $ProcessId = [int]$existing.ProcessId
    }

    [pscustomobject]@{
        SessionId        = $SessionId
        ProcessId        = $ProcessId
        TranscriptPath   = Resolve-Field -New $TranscriptPath -Field 'TranscriptPath'
        WorkingDirectory = Resolve-Field -New $WorkingDirectory -Field 'WorkingDirectory'
        Model            = Resolve-Field -New $Model -Field 'Model'
        Status           = if ($Ended) { 'ended' } else { Resolve-Field -New $Status -Field 'Status' }
        Activity         = Resolve-Field -New $Activity -Field 'Activity'
        Ended            = [bool]$Ended
        Updated          = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8

    $path
}

function Get-CodexSessionRegistrations {
    <#
        Live sessions, pruning dead ones as it goes.

        A session is live until SessionEnd fires, so an ended one is dropped
        immediately. The process check is a safety net for a session killed outright,
        where no SessionEnd is delivered. Pruning matters because nothing else would
        ever remove these files.
    #>
    param([switch]$IncludeEnded)

    $root = Get-CodexStateRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $cutoff = [DateTimeOffset]::Now.AddMinutes(-$script:CodexSessionStaleMinutes)

    $livePids = @{}
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue |
                           Where-Object { $_.ProcessName -eq 'codex' })) {
        $livePids[$process.Id] = $true
    }

    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $entry = try { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { $null }
        if (-not $entry) { continue }

        $ended = ($entry.PSObject.Properties.Name -contains 'Ended' -and $entry.Ended)
        $knownPid = ($entry.PSObject.Properties.Name -contains 'ProcessId' -and [int]$entry.ProcessId -gt 0)
        $alive = $false
        if (-not $ended -and $knownPid) {
            $alive = $livePids.ContainsKey([int]$entry.ProcessId)
        }
        $fresh = $true
        if ($entry.Updated) { $fresh = ([DateTimeOffset]::Parse($entry.Updated) -gt $cutoff) }

        # Prune when the session is definitively over: it said goodbye, its process is
        # gone, or it went quiet for long enough to be abandoned. The middle case
        # matters because a session killed outright never fires SessionEnd, and
        # without it the registration would linger for hours. It is only applied when
        # a pid was actually recorded, so a session still resolving its owner is not
        # discarded.
        $finished = $ended -or ($knownPid -and -not $alive) -or -not $fresh
        if (-not $IncludeEnded -and $finished) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            continue
        }

        if ($IncludeEnded -or ($alive -and $fresh)) {
            [pscustomobject]@{
                SessionId        = [string]$entry.SessionId
                ProcessId        = [int]($entry.ProcessId ?? 0)
                TranscriptPath   = [string]$entry.TranscriptPath
                WorkingDirectory = [string]$entry.WorkingDirectory
                Model            = [string]$entry.Model
                Status           = [string]$entry.Status
                Activity         = [string]$entry.Activity
                IsLive           = $alive -and $fresh -and -not $ended
                StatePath        = $file.FullName
            }
        }
    }
}

function Remove-CodexSessionRegistration {
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Join-Path (Get-CodexStateRoot) ((Get-CodexSafeSessionKey -SessionId $SessionId) + '.json')
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Get-CodexApprovalMarkerPath {
    param([Parameter(Mandatory)][string]$SessionId)
    Join-Path (Get-CodexStateRoot) ((Get-CodexSafeSessionKey -SessionId $SessionId) + '.approval.json')
}

function Write-CodexApprovalMarker {
    <#
        Records that a command is waiting for approval.

        This is the daemon's gate, the same role the pending-decision marker plays for
        Copilot's ask_user: while it exists, an answer on the dashboard is delivered
        into the session's own approval prompt. It is removed as soon as any later
        event proves the prompt was answered, whichever way it was answered.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$DecisionId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Question
    )

    [pscustomobject]@{
        SessionId  = $SessionId
        DecisionId = $DecisionId
        Question   = $Question
        Created    = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Get-CodexApprovalMarkerPath -SessionId $SessionId) -Encoding UTF8
}

function Get-CodexApprovalMarker {
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Get-CodexApprovalMarkerPath -SessionId $SessionId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $null }
}

function Remove-CodexApprovalMarker {
    <# Returns $true when a marker was actually removed, so callers can tell whether
       there was anything pending. #>
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Get-CodexApprovalMarkerPath -SessionId $SessionId
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return $true
}

function Get-CodexHookEvent {
    <# Reads the hook event from stdin, returning $null when nothing usable arrives. #>
    param([string]$Raw)

    if (-not $Raw) { $Raw = [Console]::In.ReadToEnd() }
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return $Raw | ConvertFrom-Json } catch { return $null }
}
