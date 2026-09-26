<#
.SYNOPSIS
    One-line installer for the Copilot CLI <-> Home Assistant bridge.

.DESCRIPTION
    Downloads the repository and runs install.ps1. Intended for:

        irm https://raw.githubusercontent.com/danswett/agent-ha-bridge/main/bootstrap.ps1 | iex

    install.ps1 is interactive, so this needs no arguments: it discovers Home
    Assistant, confirms the URL, and walks you through creating a token. To pass
    options instead, clone the repository and run install.ps1 directly.
#>

$ErrorActionPreference = 'Stop'

$repo = 'danswett/agent-ha-bridge'
$branch = 'main'
$staging = Join-Path ([IO.Path]::GetTempPath()) "agent-ha-bridge-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$zipPath = "$staging.zip"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ is required (found $($PSVersionTable.PSVersion)). Install it with: winget install Microsoft.PowerShell"
}

Write-Host "==> Downloading $repo ($branch)" -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri "https://github.com/$repo/archive/refs/heads/$branch.zip" `
        -OutFile $zipPath -UseBasicParsing
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $staging -Force

    # The archive contains a single <name>-<branch> directory.
    $root = Get-ChildItem -LiteralPath $staging -Directory | Select-Object -First 1
    if (-not $root) { throw 'The downloaded archive did not contain the expected folder.' }

    Write-Host "==> Running the installer" -ForegroundColor Cyan
    & (Join-Path $root.FullName 'install.ps1')
}
finally {
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
