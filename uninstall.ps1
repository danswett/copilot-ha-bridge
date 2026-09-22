<#
.SYNOPSIS
    Removes the Copilot <-> Home Assistant bridge.

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
    Uninstall from this directory's .copilot instead of $HOME's. Intended for testing;
    it also skips the machine-wide steps (scheduled task, process termination).
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
$arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CopilotHaBridge' +
          $(if ($TargetHome) { '_Sandbox' } else { '' })
$bridgeHome = Join-Path $copilotHome 'copilot-ha-bridge'
$hooksDir = Join-Path $copilotHome 'hooks'
$skillDir = Join-Path $copilotHome 'skills\decision-notifier'
$configPath = Join-Path $copilotHome 'copilot-ha-bridge.config.json'
$taskName = 'CopilotBridgeDaemon'

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
            if (Remove-CopilotVerboseToggle) { Write-Host '    removed the Live Verbose toggle' }
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
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host '    removed'
    }
    else {
        Write-Host '    not registered'
    }

    Write-Step 'Stopping any running daemon or supervisor'
    foreach ($proc in Get-Process pwsh -ErrorAction SilentlyContinue) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)").CommandLine
            if ($cmd -match 'copilot-bridge-(daemon|supervisor)\.ps1') {
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
    'decision-inject.ps1', 'copilot-bridge-daemon.ps1', 'copilot-bridge-supervisor.ps1',
    'copilot-bridge-launch.vbs', 'route-ask-user-v3.ps1', 'notify-agent-response.ps1',
    'notify-home-assistant.ps1', 'decision-notifier.json'
)
foreach ($name in $files) {
    $path = Join-Path $hooksDir $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; Write-Host "    $name" }
}

if (Test-Path -LiteralPath $skillDir) {
    Write-Step 'Removing the decision-notifier skill'
    Remove-Item -LiteralPath $skillDir -Recurse -Force
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
    Write-Step 'Removing the installed uninstaller'
    Remove-Item -LiteralPath $bridgeHome -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Step 'Done'
Write-Host 'Restart any running Copilot CLI sessions to drop the hooks.' -ForegroundColor Yellow