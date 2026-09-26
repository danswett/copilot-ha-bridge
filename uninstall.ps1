<#
.SYNOPSIS
    Removes the AI coding agent <-> Home Assistant bridge.

.DESCRIPTION
    Stops and unregisters the scheduled task, removes the hook scripts and hook
    definitions, and optionally deletes the bridge config (which holds your token).

    Home Assistant entities are published through retained MQTT discovery messages, so
    -ClearEntities clears them; without it they linger until manually removed.

.PARAMETER KeepConfig
    Leave the bridge config in place, so a later re-install keeps your settings.

.PARAMETER ClearEntities
    Clear the retained MQTT discovery topics so Home Assistant drops the bridge's
    entities. Requires the config to still be present.

.PARAMETER TargetHome
    Uninstall from this directory's .agent-ha-bridge instead of $HOME's. Intended for
    testing; it also skips the machine-wide steps (scheduled task, process termination).
#>

[CmdletBinding()]
param(
    [switch]$KeepConfig,
    [switch]$ClearEntities,
    [string]$TargetHome
)

$ErrorActionPreference = 'Stop'

$installHome = if ($TargetHome) { $TargetHome } else { $HOME }
$copilotHome = Join-Path $installHome '.copilot'
$arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AgentHaBridge' +
          $(if ($TargetHome) { '_Sandbox' } else { '' })
$bridgeHome = Join-Path $installHome '.agent-ha-bridge'
$hooksDir = Join-Path $bridgeHome 'hooks'
$hookConfigPath = Join-Path $copilotHome 'hooks\decision-notifier.json'
$legacySkillDir = Join-Path $copilotHome 'skills\decision-notifier'
$configPath = Join-Path $bridgeHome 'config.json'
$taskName = 'AgentBridgeDaemon'
# Pre-rename artefacts, removed too so an upgrade-then-uninstall leaves nothing.
$legacyTaskName = 'CopilotBridgeDaemon'
$legacyHooksDir = Join-Path $copilotHome 'hooks'
$legacyConfigPath = Join-Path $copilotHome 'copilot-ha-bridge.config.json'
$legacyBridgeHome = Join-Path $copilotHome 'copilot-ha-bridge'
$legacyArpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CopilotHaBridge' +
                $(if ($TargetHome) { '_Sandbox' } else { '' })

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

# Entities first: this needs the hooks and config that the rest of the script removes.
if ($ClearEntities -and $TargetHome) {
    # Entities, the verbose toggle and the dashboard live in the shared Home Assistant
    # instance, not under the install root. Clearing them from a sandbox uninstall
    # would wipe the real install's dashboard, so it is refused outright.
    Write-Warning ('Ignoring -ClearEntities because -TargetHome is set: Home Assistant ' +
                   'entities are global and would belong to the real install.')
}
elseif ($ClearEntities) {
    Write-Step 'Clearing Home Assistant entities'
    try {
        . (Join-Path $hooksDir 'decision-bridge-common.ps1')
        . (Join-Path $hooksDir 'decision-mqtt.ps1')
        . (Join-Path $hooksDir 'decision-ha-websocket.ps1')
        $headers = Get-HomeAssistantHeaders
        $root = $script:DecisionBridgeConfig.SessionStateRoot
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
                try { Remove-CopilotMqttSession -SessionId $_.Name -Headers $headers } catch { }
            }
        }
        Write-Host '    session entities cleared'

        # The daemon creates these two; without removing them Home Assistant keeps a
        # dead dashboard and an orphaned toggle after everything else is gone.
        try {
            if (Remove-CopilotVerboseToggle) { Write-Host '    removed the Detailed activity toggle' }
        }
        catch { Write-Warning "Could not remove the verbose toggle: $($_.Exception.Message)" }

        try {
            $urlPath = $script:DecisionBridgeConfig.DashboardUrlPath
            if ($urlPath) {
                [void](Invoke-CopilotHaWebSocket -Commands @(@{
                    type = 'lovelace/config/delete'; url_path = $urlPath
                }))
                Write-Host "    removed the '$urlPath' dashboard view"
            }
        }
        catch {
            # Already absent is the desired end state, not a failure.
            if ($_.Exception.Message -match 'config_not_found') {
                Write-Host "    dashboard '$urlPath' already absent"
            }
            else {
                Write-Warning "Could not remove the dashboard: $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-Warning "Could not clear entities: $($_.Exception.Message)"
    }
}

if ($TargetHome) {
    Write-Step 'Skipping the scheduled task and process cleanup (-TargetHome)'
}
else {
    Write-Step "Removing the '$taskName' scheduled task"
    foreach ($name in @($taskName, $legacyTaskName)) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "    removed $name"
        }
        else {
            Write-Host "    $name not registered"
        }
    }

    Write-Step 'Stopping any running daemon or supervisor'
    foreach ($proc in Get-Process pwsh -ErrorAction SilentlyContinue) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)").CommandLine
            if ($cmd -match '(agent|copilot)-bridge-(daemon|supervisor)\.ps1') {
                Stop-Process -Id $proc.Id -Force
                Write-Host "    stopped pid $($proc.Id)"
            }
        }
        catch { }
    }
}

Write-Step 'Removing hook scripts'
$files = @(
    'decision-bridge-common.ps1', 'decision-mqtt.ps1', 'decision-ha-websocket.ps1',
    'decision-inject.ps1', 'agent-bridge-daemon.ps1', 'agent-bridge-supervisor.ps1',
    'agent-bridge-launch.vbs', 'route-ask-user-v3.ps1', 'notify-agent-response.ps1',
    'notify-home-assistant.ps1', 'bridge-adapter.ps1', 'bridge-update.ps1',
    'session-launch.ps1', 'VERSION'
)
foreach ($name in $files) {
    $path = Join-Path $hooksDir $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Host "    $name" }
}

# The Copilot CLI's hook definition is the one bridge file outside the bridge root.
if (Test-Path -LiteralPath $hookConfigPath) {
    Remove-Item -LiteralPath $hookConfigPath -Force
    Write-Host "    $hookConfigPath"
}

if (Test-Path -LiteralPath $legacySkillDir) {
    Write-Step 'Removing the obsolete decision-notifier skill'
    Remove-Item -LiteralPath $legacySkillDir -Recurse -Force
}

# Anything a pre-rename install left in ~/.copilot.
foreach ($name in @(
    'decision-bridge-common.ps1', 'decision-mqtt.ps1', 'decision-ha-websocket.ps1',
    'decision-inject.ps1', 'bridge-adapter.ps1', 'bridge-update.ps1', 'session-launch.ps1',
    'copilot-bridge-daemon.ps1', 'copilot-bridge-supervisor.ps1', 'copilot-bridge-launch.vbs',
    'route-ask-user-v3.ps1', 'notify-agent-response.ps1', 'notify-home-assistant.ps1', 'VERSION')) {
    $path = Join-Path $legacyHooksDir $name
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Host "    $path"
    }
}
foreach ($path in @($legacyConfigPath, "$legacyConfigPath.bak", $legacyBridgeHome)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "    $path"
    }
}
if (Test-Path -LiteralPath $legacyArpKey) {
    Remove-Item -LiteralPath $legacyArpKey -Recurse -Force -ErrorAction SilentlyContinue
}

$mcpDir = Join-Path $bridgeHome 'mcp'
if (Test-Path -LiteralPath $mcpDir) {
    Write-Step 'Removing the MCP server'
    Remove-Item -LiteralPath $mcpDir -Recurse -Force
    # The Claude Desktop registration (and any other MCP client's) is left in place;
    # remove it with `mcp/install-mcp.ps1 -Uninstall`, the same way the Claude and
    # Codex client registrations are their own installers' job.
    Write-Host '    (run mcp/install-mcp.ps1 -Uninstall to also remove it from Claude Desktop)'
}

if (-not $KeepConfig -and (Test-Path -LiteralPath $configPath)) {
    Write-Step 'Removing the bridge config (it holds your token)'
    Remove-Item -LiteralPath $configPath -Force
    # The install-time backup holds the same token.
    if (Test-Path -LiteralPath "$configPath.bak") { Remove-Item -LiteralPath "$configPath.bak" -Force }
}

if (Test-Path -LiteralPath $arpKey) {
    Write-Step 'Removing the Apps & features entry'
    Remove-Item -LiteralPath $arpKey -Recurse -Force
}

# Last, because this script usually runs from here via the uninstall entry. Deleting
# the folder while it executes is fine on Windows: the file stays open until the
# process exits.
if (Test-Path -LiteralPath $bridgeHome) {
    if ($KeepConfig) {
        # The config lives in this folder, so clear it out item by item instead.
        Write-Step 'Removing the bridge root (keeping the config)'
        Get-ChildItem -LiteralPath $bridgeHome -Force |
            Where-Object { $_.FullName -ne $configPath -and $_.FullName -ne "$configPath.bak" } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    else {
        Write-Step 'Removing the bridge root'
        Remove-Item -LiteralPath $bridgeHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Step 'Done'
Write-Host 'Restart any running agent CLI sessions to drop the hooks.' -ForegroundColor Yellow