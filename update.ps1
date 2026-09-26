<#
.SYNOPSIS
    Checks for a newer release of the bridge and installs it.

.DESCRIPTION
    Installs are a clone plus install.ps1, so this is how you move to a new version
    without doing that by hand. It asks GitHub for the newest release, compares it
    with the version recorded at install time, and - with your agreement - downloads
    and installs it.

    Your configuration is preserved: the installer reads the existing config, backs it
    up, and writes it back with only what you pass on the command line changed.

    The daemon performs the same check a few times a day and surfaces the result as a
    Home Assistant `update` entity, so you normally learn about a new version there
    rather than by running this.

.PARAMETER Check
    Report what is available and exit without installing anything.

.PARAMETER Force
    Install the newest release even if it is not newer than what is installed. Use to
    repair a damaged install.

.PARAMETER Yes
    Skip the confirmation prompt.

.EXAMPLE
    .\update.ps1 -Check

.EXAMPLE
    .\update.ps1 -Yes
#>

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Force,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$hooksDir = Join-Path $HOME '.agent-ha-bridge\hooks'
if (-not (Test-Path -LiteralPath (Join-Path $hooksDir 'bridge-update.ps1'))) {
    # Fall back to the copy in this clone, so -Check works before a first install.
    $hooksDir = Join-Path $PSScriptRoot 'hooks'
}

. (Join-Path $hooksDir 'decision-bridge-common.ps1')
. (Join-Path $hooksDir 'bridge-update.ps1')

Write-Host '==> Checking for updates' -ForegroundColor Cyan
$status = Get-BridgeUpdateStatus -Force

Write-Host "    repository : $(Get-BridgeUpdateRepository)"
Write-Host "    installed  : $($status.Installed)"
Write-Host "    latest     : $($status.Latest)"

if (-not $status.Available -and -not $Force) {
    if ($status.Installed -eq $status.Latest) {
        Write-Host '    already up to date' -ForegroundColor Green
    }
    else {
        # Also covers a repository with no releases yet, where latest falls back to
        # the installed version.
        Write-Host '    nothing newer published' -ForegroundColor Green
    }
    return
}

if ($status.Notes) {
    Write-Host ''
    Write-Host 'Release notes:' -ForegroundColor Cyan
    ($status.Notes -split "`n") | Select-Object -First 20 | ForEach-Object { "    $_" }
}
Write-Host ''
Write-Host "    $($status.Url)"
Write-Host ''

if (-not $Yes) {
    $answer = Read-Host "Install $($status.Latest) now? [y/N]"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host 'Nothing changed.'
        return
    }
}

if ($Check) {
    Write-Host 'Check only; nothing installed.'
    return
}

Write-Host '==> Installing' -ForegroundColor Cyan
# Not detached: run in the foreground so the outcome is visible. The daemon uses the
# detached path instead, because the installer restarts the task it runs under.
$result = Invoke-BridgeSelfUpdate
Write-Host "    $($result.Detail)"
Write-Host ''
Write-Host "Log: $env:TEMP\agent-bridge-update.log"
Write-Host 'Restart any running Copilot or Claude sessions to pick up the new hooks.' -ForegroundColor Yellow
