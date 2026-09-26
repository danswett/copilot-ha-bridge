<#
.SYNOPSIS
    Installs the Codex CLI adapter for the Copilot <-> Home Assistant bridge.

.DESCRIPTION
    Codex loads third-party hooks from plugins, so the adapter is packaged as one and
    registered through a local marketplace - the mechanism Codex supports for plugins
    that do not come from a catalogue.

    The main bridge must already be installed: this reuses its Home Assistant layer,
    its daemon and its dashboard.

    After installing you must **trust the hooks once**, in Codex itself. This is not
    optional and not something the installer can do for you: an untrusted Codex hook
    is skipped in complete silence, with no error and no log entry, which looks
    exactly like a broken install. Start Codex once and approve the prompt.

.PARAMETER TargetHome
    Install into this directory instead of $HOME. For testing without touching a real
    setup.

.PARAMETER Uninstall
    Remove the plugin, the marketplace registration and the adapter.
#>

[CmdletBinding()]
param(
    [string]$TargetHome,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$installHome = if ($TargetHome) { $TargetHome } else { $HOME }
$bridgeRoot = Join-Path $installHome '.agent-ha-bridge\codex-bridge'
$marketplaceName = 'agent-ha-bridge'
$pluginName = 'agent-ha-bridge'
$pluginRoot = Join-Path $bridgeRoot "plugins\$pluginName"
$coreDir = Join-Path $installHome '.agent-ha-bridge\hooks'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

function Get-CodexExecutable {
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    # npm does not always create a shim on Windows, so fall back to the vendored binary.
    $vendored = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
    if (Test-Path -LiteralPath $vendored) { return $vendored }
    $null
}

$codex = Get-CodexExecutable

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
    Write-Step 'Removing the Codex adapter'
    if ($codex) {
        & $codex plugin remove "$pluginName@$marketplaceName" 2>&1 | Out-Null
        & $codex plugin marketplace remove $marketplaceName 2>&1 | Out-Null
        Write-Host '    plugin and marketplace removed'
    }
    if (Test-Path -LiteralPath $bridgeRoot) {
        Remove-Item -LiteralPath $bridgeRoot -Recurse -Force
        Write-Host '    adapter removed'
    }
    $stateRoot = Join-Path $env:TEMP 'agent-bridge-codex'
    if (Test-Path -LiteralPath $stateRoot) { Remove-Item -LiteralPath $stateRoot -Recurse -Force }
    Write-Step 'Done'
    Write-Host 'Trust entries under [hooks.state] in the Codex config are left alone;' -ForegroundColor Yellow
    Write-Host 'they are harmless and Codex prunes them itself.' -ForegroundColor Yellow
    return
}

# -------------------------------------------------------------------- install
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ is required (found $($PSVersionTable.PSVersion))."
}
if (-not (Test-Path -LiteralPath (Join-Path $coreDir 'decision-mqtt.ps1'))) {
    throw ("The main bridge is not installed at $coreDir. Run install.ps1 first - the " +
           'Codex adapter reuses its Home Assistant layer, daemon and dashboard.')
}
if (-not $codex) {
    throw 'Codex CLI was not found. Install it with: npm install -g @openai/codex'
}

Write-Step "Installing the adapter into $pluginRoot"
New-Item -ItemType Directory -Path (Join-Path $pluginRoot '.codex-plugin') -Force | Out-Null
$hooksTarget = Join-Path $pluginRoot 'hooks'
New-Item -ItemType Directory -Path $hooksTarget -Force | Out-Null
Get-ChildItem (Join-Path $PSScriptRoot 'hooks') -File | ForEach-Object {
    Copy-Item $_.FullName $hooksTarget -Force
    Write-Host "    $($_.Name)"
}

$versionFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION'
$version = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { '1.0.0' }

[ordered]@{
    name        = $pluginName
    version     = $version
    description = 'Answer Codex prompts from Home Assistant.'
    hooks       = './hooks.json'
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $pluginRoot '.codex-plugin\plugin.json') -Encoding UTF8

# The command must NOT be shell-quoted. A quoted executable path fails with
# "hook exited with code 1"; the same command unquoted runs fine. pwsh is resolved
# from PATH for the same reason - its installed path contains a space.
$hookScript = Join-Path $hooksTarget 'codex-bridge-hook.ps1'
if ($hookScript -match '\s') {
    Write-Warning ("The adapter path contains a space ($hookScript). Codex cannot quote " +
                   'hook commands, so hooks may fail. Install under a path without spaces.')
}
$command = "pwsh -NoProfile -ExecutionPolicy Bypass -File $hookScript"

$events = [ordered]@{}
# SessionEnd is clamped to a 3 second timeout by Codex, which the hook accounts for.
# PermissionRequest runs before Codex shows its own approval UI; the hook writes
# nothing to stdout, which Codex reads as "no decision", so the terminal prompt still
# appears and the dashboard becomes a second way to answer rather than a replacement.
foreach ($eventName in @('SessionStart', 'UserPromptSubmit', 'PermissionRequest', 'PreToolUse', 'Stop', 'SessionEnd')) {
    $events[$eventName] = @(
        [ordered]@{ hooks = @([ordered]@{ type = 'command'; command = $command; timeout = 20 }) }
    )
}
[ordered]@{
    description = 'Copilot Home Assistant bridge'
    hooks       = $events
} | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $pluginRoot 'hooks.json') -Encoding UTF8

Write-Step 'Registering the local marketplace'
$marketplaceDir = Join-Path $bridgeRoot '.agents\plugins'
New-Item -ItemType Directory -Path $marketplaceDir -Force | Out-Null
[ordered]@{
    name      = $marketplaceName
    interface = [ordered]@{ displayName = 'Copilot HA bridge' }
    plugins   = @(
        [ordered]@{
            name     = $pluginName
            source   = [ordered]@{ source = 'local'; path = "./plugins/$pluginName" }
            policy   = [ordered]@{ installation = 'AVAILABLE'; authentication = 'ON_USE' }
            category = 'Productivity'
        }
    )
} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $marketplaceDir 'marketplace.json') -Encoding UTF8

& $codex plugin marketplace remove $marketplaceName 2>&1 | Out-Null
$added = & $codex plugin marketplace add $bridgeRoot 2>&1 | Out-String
if ($added -notmatch 'Added marketplace') { throw "Could not register the marketplace: $added" }
Write-Host "    $marketplaceName"

Write-Step 'Installing the plugin'
& $codex plugin remove "$pluginName@$marketplaceName" 2>&1 | Out-Null
$installed = & $codex plugin add "$pluginName@$marketplaceName" 2>&1 | Out-String
if ($installed -notmatch 'Added plugin') { throw "Could not install the plugin: $installed" }
Write-Host "    $pluginName@$marketplaceName"

Write-Step 'Done'
Write-Host ''
Write-Host 'One more step - this one matters:' -ForegroundColor Yellow
Write-Host '  Start Codex once and approve the hook trust prompt.' -ForegroundColor Yellow
Write-Host '  Until you do, Codex skips these hooks silently: no error, no log line,' -ForegroundColor Yellow
Write-Host '  which looks exactly like a broken install.' -ForegroundColor Yellow
Write-Host ''
Write-Host "Logs: `$env:TEMP\agent-decision-bridge.log"
