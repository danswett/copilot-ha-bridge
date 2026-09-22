<#
.SYNOPSIS
    Claude Code session helpers: display names, the session->pid registry, and
    transcript discovery.

.DESCRIPTION
    Claude Code has no equivalent of Copilot's session-state folder or its
    inuse.<pid>.lock, so the pieces the bridge relies on are rebuilt here:

      * a display name, derived from the project folder rather than a workspace file
      * a session -> pid registry, written by the hook, which is the only place the
        owning process can be identified reliably (a hook runs as a descendant of its
        session)
      * transcript discovery under the projects directory reported by `claude auth
        status` as `projectsDirectory`
#>

Set-StrictMode -Version Latest

$script:ClaudeStateRoot = Join-Path $env:TEMP 'copilot-bridge-claude'
$script:ClaudeProjectsRoot = Join-Path $HOME '.claude\projects'
# A session whose registry entry has not been refreshed in this long is treated as
# gone, so a crashed session cannot hold entities open forever.
$script:ClaudeSessionStaleMinutes = 240

function Get-ClaudeStateRoot {
    if (-not (Test-Path -LiteralPath $script:ClaudeStateRoot)) {
        New-Item -ItemType Directory -Path $script:ClaudeStateRoot -Force | Out-Null
    }
    $script:ClaudeStateRoot
}

function Get-ClaudeSessionDisplay {
    <#
        Names a session after its project folder, which is the most recognisable
        handle a Claude session has. The "Claude:" prefix keeps its cards
        distinguishable from Copilot's on a shared dashboard.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$WorkingDirectory
    )

    $folder = if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory)) {
        Split-Path -Leaf $WorkingDirectory
    }
    elseif ($WorkingDirectory) { Split-Path -Leaf $WorkingDirectory }
    else { $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length)) }

    if ([string]::IsNullOrWhiteSpace($folder)) {
        $folder = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))
    }

    $name = "Claude: $folder"
    if ($name.Length -gt 120) { $name = $name.Substring(0, 117) + '...' }

    [pscustomobject]@{
        Name    = $name
        Machine = [Environment]::MachineName
    }
}

function Write-ClaudeSessionRegistration {
    <#
        Records where a session lives and which process owns it.

        This is written from the hook because that is the only moment the owning pid
        can be determined: the hook process is a descendant of the Claude session, so
        walking its parents identifies the right one even with several sessions open.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$TranscriptPath,
        [string]$WorkingDirectory,
        [int]$ProcessId = 0
    )

    $path = Join-Path (Get-ClaudeStateRoot) "$SessionId.json"
    $existing = if (Test-Path -LiteralPath $path) {
        try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $null }
    }

    # A later event without a resolvable pid must not erase one already known.
    if ($ProcessId -le 0 -and $existing -and $existing.ProcessId) {
        $ProcessId = [int]$existing.ProcessId
    }

    [pscustomobject]@{
        SessionId        = $SessionId
        ProcessId        = $ProcessId
        TranscriptPath   = $TranscriptPath
        WorkingDirectory = $WorkingDirectory
        Updated          = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8

    $path
}

function Get-ClaudeSessionRegistrations {
    <#
        Returns live registrations. A session counts as live when its recorded process
        is still running and is still a claude process; the pid check is what retires
        entities promptly when a session exits, since Claude fires no reliable
        "session ended" hook for every exit path.
    #>
    param([switch]$IncludeStale)

    $root = Get-ClaudeStateRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $cutoff = [DateTimeOffset]::Now.AddMinutes(-$script:ClaudeSessionStaleMinutes)

    foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $entry = try { Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { $null }
        if (-not $entry) { continue }

        $alive = $false
        if ($entry.ProcessId -and [int]$entry.ProcessId -gt 0) {
            $process = Get-Process -Id ([int]$entry.ProcessId) -ErrorAction SilentlyContinue
            $alive = ($null -ne $process -and $process.ProcessName -match '^claude')
        }

        $fresh = $true
        if ($entry.Updated) {
            $fresh = ([DateTimeOffset]::Parse($entry.Updated) -gt $cutoff)
        }

        if ($IncludeStale -or ($alive -and $fresh)) {
            [pscustomobject]@{
                SessionId        = [string]$entry.SessionId
                ProcessId        = [int]($entry.ProcessId ?? 0)
                TranscriptPath   = [string]$entry.TranscriptPath
                WorkingDirectory = [string]$entry.WorkingDirectory
                Updated          = [string]$entry.Updated
                IsLive           = $alive -and $fresh
                StatePath        = $file.FullName
            }
        }
    }
}

function Remove-ClaudeSessionRegistration {
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Join-Path (Get-ClaudeStateRoot) "$SessionId.json"
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Resolve-ClaudeTranscriptPath {
    <#
        Falls back to searching the projects directory when a hook event did not carry
        transcript_path, matching on the session id in the file name.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$KnownPath
    )

    if ($KnownPath -and (Test-Path -LiteralPath $KnownPath)) { return $KnownPath }
    if (-not (Test-Path -LiteralPath $script:ClaudeProjectsRoot)) { return $null }

    $match = Get-ChildItem -LiteralPath $script:ClaudeProjectsRoot -Recurse -Filter "$SessionId.jsonl" `
        -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($match) { return $match.FullName }
    $null
}
