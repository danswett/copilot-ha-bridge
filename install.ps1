<#
.SYNOPSIS
    Installs the Copilot <-> Home Assistant bridge.

.DESCRIPTION
    Copies the hook scripts into the Copilot CLI hooks folder, writes the bridge
    config, merges the hook definitions into Copilot's hook config, and registers the
    supervisor as a hidden scheduled task.

    Everything is idempotent: re-running it upgrades an existing install in place.

.PARAMETER HomeAssistantUrl
    Base URL of Home Assistant, e.g. http://homeassistant.local:8123

.PARAMETER Token
    A Home Assistant long-lived access token. Stored in the bridge config outside the
    repository. Omit it to keep an existing token, or to supply one via the
    COPILOT_HA_TOKEN environment variable instead.

.PARAMETER NotifyService
    Optional Home Assistant notify-style service for out-of-band alerts, e.g.
    notify.mobile_app_pixel. Omit to disable notifications.

.PARAMETER TargetHome
    Install into this directory's .copilot instead of $HOME's. Intended for testing a
    build without touching a working install; $HOME is read-only in PowerShell, so it
    cannot be redirected any other way.

.PARAMETER SkipVerify
    Skip the Home Assistant connectivity check. Use for an offline install, or when
    the token comes from an environment variable that is not set yet.

.PARAMETER NonInteractive
    Never prompt. Without this, the installer discovers Home Assistant on the network
    and asks for anything it still needs.

.EXAMPLE
    .\install.ps1 -HomeAssistantUrl http://homeassistant.local:8123 -Token 'eyJ...'

.EXAMPLE
    .\install.ps1 -HomeAssistantUrl http://ha.lan:8123 -Token 'eyJ...' -NotifyService notify.mobile_app_pixel
#>

[CmdletBinding()]
param(
    [string]$HomeAssistantUrl,
    [string]$Token,
    [string]$NotifyService,
    [string]$TickerCategory,
    [string]$TargetHome,
    [switch]$SkipVerify,
    [switch]$NonInteractive,
    [switch]$SkipTask
)

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$installHome = if ($TargetHome) { $TargetHome } else { $HOME }

# The VERSION file is the single source of truth, so the Apps & features entry, the
# recorded config and the update check can never disagree about what is installed.
$versionFile = Join-Path $repoRoot 'VERSION'
$version = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { '0.0.0' }
$copilotHome = Join-Path $installHome '.copilot'
$hooksDir = Join-Path $copilotHome 'hooks'
$skillDir = Join-Path $copilotHome 'skills\decision-notifier'
$configPath = Join-Path $copilotHome 'copilot-ha-bridge.config.json'
$hookConfigPath = Join-Path $hooksDir 'decision-notifier.json'
$taskName = 'CopilotBridgeDaemon'
# A sandbox install must not collide with the real Add/Remove Programs entry.
$arpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CopilotHaBridge' +
          $(if ($TargetHome) { '_Sandbox' } else { '' })
$bridgeHome = Join-Path $copilotHome 'copilot-ha-bridge'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

function Test-IsHomeAssistant {
    <#
        True when the URL serves Home Assistant. manifest.json is unauthenticated and
        names the product outright, which makes it a reliable fingerprint; /api/ only
        returns a bare 401 without a token.
    #>
    param([Parameter(Mandatory)][string]$BaseUrl, [int]$TimeoutSec = 4)

    try {
        $response = Invoke-WebRequest -Uri "$($BaseUrl.TrimEnd('/'))/manifest.json" `
            -TimeoutSec $TimeoutSec -SkipHttpErrorCheck -ErrorAction Stop
        if ($response.StatusCode -ne 200) { return $false }
        $body = if ($response.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($response.Content)
        } else { [string]$response.Content }
        return ($body -match '"(short_)?name"\s*:\s*"Home Assistant"')
    }
    catch { return $false }
}

function Find-HomeAssistant {
    <#
        Locates Home Assistant on the local network.

        Home Assistant publishes itself as homeassistant.local over mDNS, which Windows
        resolves natively, so the default hostname plus its resolved address covers
        almost every install. Anything more exotic is a typed URL. No subnet scanning:
        it is slow and looks like hostile traffic.
    #>
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($hostName in @('homeassistant.local', 'homeassistant')) {
        $candidates.Add("http://${hostName}:8123")
    }
    try {
        $resolved = Resolve-DnsName -Name 'homeassistant.local' -Type A -ErrorAction Stop
        foreach ($address in @($resolved | Where-Object IPAddress | Select-Object -Expand IPAddress)) {
            $candidates.Add("http://${address}:8123")
        }
    }
    catch { }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        Write-Host "    probing $candidate" -ForegroundColor DarkGray
        if (Test-IsHomeAssistant -BaseUrl $candidate) { return $candidate }
    }
    return $null
}

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    throw 'This bridge is Windows-only: reply injection uses AttachConsole/WriteConsoleInput.'
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ is required (found $($PSVersionTable.PSVersion))."
}
if (-not (Test-Path -LiteralPath $copilotHome)) {
    throw "Copilot CLI home not found at $copilotHome. Install and run the Copilot CLI first."
}

# ---------------------------------------------------------------- hook scripts
Write-Step "Copying hook scripts to $hooksDir"
if (-not (Test-Path -LiteralPath $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }
Get-ChildItem (Join-Path $repoRoot 'hooks') -File | ForEach-Object {
    Copy-Item $_.FullName $hooksDir -Force
    Write-Host "    $($_.Name)"
}

if (Test-Path -LiteralPath $versionFile) { Copy-Item $versionFile $hooksDir -Force }
# ---------------------------------------------------------------------- skill
Write-Step "Installing the decision-notifier skill"
if (-not (Test-Path -LiteralPath $skillDir)) { New-Item -ItemType Directory -Path $skillDir -Force | Out-Null }
Copy-Item (Join-Path $repoRoot 'skill\SKILL.md') $skillDir -Force

# --------------------------------------------------------------------- config
Write-Step "Writing bridge config to $configPath"
$config = if (Test-Path -LiteralPath $configPath) {
    # Never lose a working config to a mistyped re-run.
    Copy-Item $configPath "$configPath.bak" -Force
    Write-Host "    backed up existing config to $(Split-Path $configPath -Leaf).bak"
    Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
else {
    Get-Content -LiteralPath (Join-Path $repoRoot 'config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

if ($PSBoundParameters.ContainsKey('HomeAssistantUrl') -and $HomeAssistantUrl) {
    $config.homeAssistant.baseUrl = $HomeAssistantUrl.TrimEnd('/')
}
if ($PSBoundParameters.ContainsKey('Token') -and $Token) {
    $config.homeAssistant.token = $Token
}
if ($PSBoundParameters.ContainsKey('NotifyService') -and $NotifyService) {
    $config.notifications.enabled = $true
    $config.notifications.service = $NotifyService
}
if ($PSBoundParameters.ContainsKey('TickerCategory') -and $TickerCategory) {
    $config.notifications.tickerCategory = $TickerCategory
}

# --------------------------------------------------------------- interactive
# Fill in whatever is still missing by discovering Home Assistant and asking, so the
# common case is running install.ps1 with no arguments at all.
if (-not $NonInteractive) {
    $needsUrl = -not ($PSBoundParameters.ContainsKey('HomeAssistantUrl') -and $HomeAssistantUrl)
    $knownToken = $config.homeAssistant.token
    if (-not $knownToken -and $config.homeAssistant.tokenEnvVar) {
        $knownToken = [Environment]::GetEnvironmentVariable($config.homeAssistant.tokenEnvVar)
    }

    if ($needsUrl) {
        Write-Step 'Looking for Home Assistant'
        $found = Find-HomeAssistant
        if ($found) {
            Write-Host "    found $found" -ForegroundColor Green
            $config.homeAssistant.baseUrl = $found
        }
        else {
            Write-Host '    not found automatically' -ForegroundColor Yellow
        }
        $prompt = "    Home Assistant URL [$($config.homeAssistant.baseUrl)]"
        $answer = Read-Host $prompt
        if ($answer) { $config.homeAssistant.baseUrl = $answer.Trim().TrimEnd('/') }
    }

    if (-not $knownToken) {
        $profileUrl = "$($config.homeAssistant.baseUrl.TrimEnd('/'))/profile/security"
        Write-Step 'Home Assistant needs a long-lived access token'
        Write-Host "    1. Open $profileUrl"
        Write-Host '    2. Scroll to "Long-lived access tokens" and choose "Create token"'
        Write-Host '    3. Name it anything (e.g. "Copilot CLI bridge") and copy the value'
        $entered = Read-Host '    Paste the token here'
        if ($entered) { $config.homeAssistant.token = $entered.Trim() }
    }
}

# Record what was installed, so the update check can compare against the newest
# release without guessing.
if (-not $config.PSObject.Properties.Name.Contains('updates')) {
    $config | Add-Member -NotePropertyName 'updates' -NotePropertyValue ([pscustomobject]@{
        repository = 'danswett/copilot-ha-bridge'; installedVersion = ''; checkForUpdates = $true
    })
}
$config.updates.installedVersion = $version

$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
# The token lives here; keep it out of any shared listing.
Write-Host "    baseUrl      : $($config.homeAssistant.baseUrl)"
Write-Host "    token        : $(if ($config.homeAssistant.token) { 'set in config' } else { "from `$env:$($config.homeAssistant.tokenEnvVar)" })"
Write-Host "    notifications: $(if ($config.notifications.enabled) { $config.notifications.service } else { 'disabled' })"

# ------------------------------------------------------------------- preflight
# Without this the installer happily reports success and the bridge only fails much
# later, from a hook or the daemon, where the cause is far less obvious.
if ($SkipVerify) {
    Write-Step 'Skipping the Home Assistant check (-SkipVerify)'
}
else {
    Write-Step 'Verifying Home Assistant'
    $effectiveToken = $config.homeAssistant.token
    if (-not $effectiveToken -and $config.homeAssistant.tokenEnvVar) {
        $effectiveToken = [Environment]::GetEnvironmentVariable($config.homeAssistant.tokenEnvVar)
    }

    if (-not $effectiveToken) {
        throw ("No Home Assistant token. Re-run without -NonInteractive to be prompted, " +
               "or pass -Token '<long-lived token>', or set " +
               "`$env:$($config.homeAssistant.tokenEnvVar), or pass -SkipVerify " +
               'to finish the install and configure it later.')
    }

    $base = $config.homeAssistant.baseUrl.TrimEnd('/')
    $authHeaders = @{ Authorization = "Bearer $effectiveToken"; 'Content-Type' = 'application/json' }

    # A long-lived token is sent on every request, so over plain HTTP it crosses the
    # network in the clear. Local Home Assistant installs are usually http, so this
    # warns rather than blocks.
    if ($base -match '^http://' -and $base -notmatch '^http://(localhost|127\.0\.0\.1|\[::1\])') {
        Write-Warning ("$base is plain HTTP, so the access token is sent unencrypted " +
                       'over your network. Prefer https:// if your Home Assistant has a certificate.')
    }

    try {
        $api = Invoke-RestMethod -Uri "$base/api/" -Headers $authHeaders -TimeoutSec 15
        Write-Host "    $base -> $($api.message)"
    }
    catch {
        throw ("Could not reach Home Assistant at $base : $($_.Exception.Message)`n" +
               '    Check -HomeAssistantUrl and that the token is valid, or pass -SkipVerify.')
    }

    # The MQTT integration is the one prerequisite the bridge cannot provision itself:
    # every per-session entity is published through the mqtt.publish service.
    try {
        $services = Invoke-RestMethod -Uri "$base/api/services" -Headers $authHeaders -TimeoutSec 20
        $mqtt = @($services) | Where-Object { $_.domain -eq 'mqtt' }
        if ($mqtt -and $mqtt.services.PSObject.Properties.Name -contains 'publish') {
            Write-Host '    mqtt.publish available'
        }
        else {
            Write-Warning ('Home Assistant has no mqtt.publish service. Add the MQTT ' +
                           'integration (Settings > Devices & Services > Add Integration > MQTT) ' +
                           'or the bridge cannot create its entities.')
        }
    }
    catch {
        Write-Warning "Could not list Home Assistant services: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- hook config
Write-Step "Merging Copilot hook definitions"
$hookDefs = [ordered]@{
    agentStop = @(
        [ordered]@{
            type = 'command'
            powershell = "& '$(Join-Path $hooksDir 'notify-agent-response.ps1')'"
            timeoutSec = 30
        }
    )
    preToolUse = @(
        [ordered]@{
            type = 'command'
            matcher = 'ask_user'
            powershell = "& '$(Join-Path $hooksDir 'route-ask-user-v3.ps1')'"
            timeoutSec = 120
        }
    )
    notification = @(
        [ordered]@{
            type = 'command'
            matcher = 'permission_prompt'
            powershell = "& '$(Join-Path $hooksDir 'notify-home-assistant.ps1')'"
            timeoutSec = 15
        }
    )
}
@{ version = 1; hooks = $hookDefs } | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $hookConfigPath -Encoding UTF8
Write-Host "    $hookConfigPath"

# ------------------------------------------------------------- scheduled task
if (-not $SkipTask) {
    Write-Step "Registering the '$taskName' scheduled task"
    # wscript + the VBS launcher, not pwsh directly: WScript.Shell.Run(..., 0, False)
    # starts the supervisor with no window at all, while still giving the daemon a real
    # console. conhost --headless would give a pseudoconsole and break reply injection.
    $launcher = Join-Path $hooksDir 'copilot-bridge-launch.vbs'
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$launcher`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Limited

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Set-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal | Out-Null
    }
    else {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal `
            -Description 'Supervises the Copilot CLI Home Assistant bridge daemon.' | Out-Null
    }
    Start-ScheduledTask -TaskName $taskName
    Write-Host "    registered and started"
}

# ------------------------------------------------------- add/remove programs
# No installer executable is needed for this: a per-user uninstall key is the same
# list Settings reads, and it avoids the SmartScreen warning an unsigned exe would
# produce. uninstall.ps1 is copied somewhere stable so the entry keeps working after
# the cloned repo is deleted.
Write-Step 'Registering in Apps & features'
if (-not (Test-Path -LiteralPath $bridgeHome)) { New-Item -ItemType Directory -Path $bridgeHome -Force | Out-Null }
Copy-Item (Join-Path $repoRoot 'uninstall.ps1') $bridgeHome -Force
$uninstallScript = Join-Path $bridgeHome 'uninstall.ps1'

# A sandbox install must uninstall itself, not the real one, so the entry carries its
# own location. A normal install omits it and lets uninstall.ps1 use $HOME, which also
# keeps the machine-wide cleanup (scheduled task, daemon processes) enabled.
$uninstallArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`" -ClearEntities"
if ($TargetHome) { $uninstallArgs += " -TargetHome `"$installHome`"" }

New-Item -Path $arpKey -Force | Out-Null
$arpValues = @{
    DisplayName     = 'Copilot CLI Home Assistant bridge'
    DisplayVersion  = $version
    Publisher       = 'copilot-ha-bridge'
    InstallLocation = $bridgeHome
    URLInfoAbout    = 'https://github.com/danswett/copilot-ha-bridge'
    UninstallString = "pwsh.exe $uninstallArgs"
    QuietUninstallString = "pwsh.exe $uninstallArgs"
}
foreach ($name in $arpValues.Keys) { Set-ItemProperty -Path $arpKey -Name $name -Value $arpValues[$name] }
Set-ItemProperty -Path $arpKey -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $arpKey -Name NoRepair -Value 1 -Type DWord
Write-Host "    'Copilot CLI Home Assistant bridge' is now uninstallable from Settings"

Write-Step 'Done'
Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host '  1. Restart any running Copilot CLI sessions (/restart) so they pick up the hooks.'
Write-Host '  2. Open the Copilot Decisions dashboard in Home Assistant.'
Write-Host "     Logs: `$env:TEMP\copilot-bridge-daemon.log and copilot-decision-bridge.log"
