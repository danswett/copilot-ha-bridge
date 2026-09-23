#Requires -Version 7.0
<#
.SYNOPSIS
    Sets up the bridge's MCP server and hands you a ready-to-paste client config.

.DESCRIPTION
    Copies the Node MCP server into ~/.copilot/mcp so it survives deleting the clone,
    installs its dependencies, and writes a paste-ready stdio config using the Home
    Assistant URL and token already in the bridge config. If Claude Desktop is present,
    the server is written straight into its config; other MCP clients (Cursor, ChatGPT)
    use the generated snippet.

    Unlike the hook adapters, an MCP server is not a hook: MCP clients each point at it
    their own way, so for anything but Claude Desktop you paste the generated snippet.
    The base bridge must already be installed - the MCP setup reuses its Home Assistant
    URL and token.

.PARAMETER TargetHome
    Install into this directory's .copilot instead of $HOME's. For testing without
    touching a real setup.

.PARAMETER Uninstall
    Remove the MCP server and its Claude Desktop registration.
#>
[CmdletBinding()]
param(
    [string]$TargetHome,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$installHome = if ($TargetHome) { $TargetHome } else { $HOME }
$copilotHome = Join-Path $installHome '.copilot'
$mcpDir      = Join-Path $copilotHome 'mcp'
$configPath  = Join-Path $copilotHome 'copilot-ha-bridge.config.json'
$snippetPath = Join-Path $mcpDir 'mcp-client-config.json'
$serverName  = 'home-assistant-bridge'
# Overridable so a sandbox test never touches the real Claude Desktop config.
$claudeDesktopConfig = if ($env:BRIDGE_CLAUDE_DESKTOP_CONFIG) {
    $env:BRIDGE_CLAUDE_DESKTOP_CONFIG
}
else {
    Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
}

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ is required (found $($PSVersionTable.PSVersion))."
}

function Get-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    # -AsHashtable so the map is mutable and exposes ContainsKey for merging.
    $raw | ConvertFrom-Json -AsHashtable
}

function Remove-BridgeMcpServer {
    <# Strips only this bridge's server, leaving any others the client has. #>
    param([hashtable]$Config)
    if ($Config.ContainsKey('mcpServers') -and $Config['mcpServers'] -is [hashtable]) {
        $Config['mcpServers'].Remove($serverName)
        if ($Config['mcpServers'].Count -eq 0) { $Config.Remove('mcpServers') }
    }
    $Config
}

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
    Write-Step 'Removing the MCP server'
    if (Test-Path -LiteralPath $claudeDesktopConfig) {
        Copy-Item $claudeDesktopConfig "$claudeDesktopConfig.bak" -Force
        (Remove-BridgeMcpServer -Config (Get-JsonFile $claudeDesktopConfig)) |
            ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $claudeDesktopConfig -Encoding UTF8
        Write-Host '    removed from Claude Desktop'
    }
    if (Test-Path -LiteralPath $mcpDir) {
        Remove-Item -LiteralPath $mcpDir -Recurse -Force
        Write-Host "    removed $mcpDir"
    }
    Write-Step 'Done'
    return
}

# -------------------------------------------------------------------- install
if (-not (Test-Path -LiteralPath $configPath)) {
    throw ("The bridge config was not found at $configPath. Run install.ps1 first - the " +
           'MCP setup reuses its Home Assistant URL and token.')
}
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$baseUrl = [string]$config.homeAssistant.baseUrl
$token = [string]$config.homeAssistant.token
if (-not $token -and $config.homeAssistant.tokenEnvVar) {
    $token = [Environment]::GetEnvironmentVariable([string]$config.homeAssistant.tokenEnvVar)
}

Write-Step "Installing the MCP server into $mcpDir"
if (-not (Test-Path -LiteralPath $mcpDir)) { New-Item -ItemType Directory -Path $mcpDir -Force | Out-Null }
# A clean copy of src each time, so a removed file cannot linger.
$destSrc = Join-Path $mcpDir 'src'
if (Test-Path -LiteralPath $destSrc) { Remove-Item -LiteralPath $destSrc -Recurse -Force }
Copy-Item (Join-Path $PSScriptRoot 'src') $mcpDir -Recurse -Force
Copy-Item (Join-Path $PSScriptRoot 'package.json') $mcpDir -Force
# Copy the release marker next to the server so it reports the bridge version it is
# actually running (server.js reads VERSION, falling back to package.json).
$mcpVersionFile = Join-Path $PSScriptRoot '..\VERSION'
if (Test-Path -LiteralPath $mcpVersionFile) { Copy-Item $mcpVersionFile $mcpDir -Force }
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'package-lock.json')) {
    Copy-Item (Join-Path $PSScriptRoot 'package-lock.json') $mcpDir -Force
}

if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-Step 'Installing dependencies (npm)'
    Push-Location $mcpDir
    try {
        & npm install --omit=dev --no-audit --no-fund 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "npm install exited $LASTEXITCODE; run 'npm install' in $mcpDir yourself."
        }
        else { Write-Host '    dependencies installed' }
    }
    finally { Pop-Location }
}
else {
    Write-Warning "Node/npm not found. Install Node.js, then run 'npm install' in $mcpDir."
}

# ------------------------------------------------------- paste-ready snippet
# The token is written to files (the snippet and, below, Claude Desktop) but never
# printed, so it does not land in console history.
$serverJs = Join-Path $mcpDir 'src\server.js'
$serverEnv = [ordered]@{ HA_BASE_URL = $baseUrl }
$serverEnv['HA_TOKEN'] = if ($token) { $token } else { '<your Home Assistant long-lived token>' }
$serverBlock = [ordered]@{ command = 'node'; args = @($serverJs); env = $serverEnv }

([ordered]@{ mcpServers = [ordered]@{ $serverName = $serverBlock } }) |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $snippetPath -Encoding UTF8
Write-Step "Wrote a paste-ready client config to $snippetPath"
if (-not $token) {
    Write-Warning 'No token was in the bridge config, so the snippet has a placeholder - fill in HA_TOKEN.'
}

# ----------------------------------------------------------- Claude Desktop
$claudeDone = $false
if (Test-Path -LiteralPath (Split-Path -Parent $claudeDesktopConfig)) {
    $cd = Get-JsonFile $claudeDesktopConfig
    if (-not $cd.ContainsKey('mcpServers') -or $cd['mcpServers'] -isnot [hashtable]) { $cd['mcpServers'] = @{} }
    $cd['mcpServers'][$serverName] = $serverBlock
    if (Test-Path -LiteralPath $claudeDesktopConfig) { Copy-Item $claudeDesktopConfig "$claudeDesktopConfig.bak" -Force }
    $cd | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $claudeDesktopConfig -Encoding UTF8
    Write-Step 'Registered with Claude Desktop'
    Write-Host "    added '$serverName' to $claudeDesktopConfig"
    $claudeDone = $true
}

Write-Step 'Done'
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Yellow
if ($claudeDone) {
    Write-Host '  - Claude Desktop: restart it; the Home Assistant bridge tool is now available.'
}
Write-Host "  - Other MCP clients (Cursor, ...): paste $snippetPath into their MCP config."
Write-Host '  - ChatGPT / remote clients: use the HTTP transport - see mcp/README.md.'
