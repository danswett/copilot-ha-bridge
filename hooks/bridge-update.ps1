<#
.SYNOPSIS
    Update checking and self-update for the bridge.

.DESCRIPTION
    Installs are a clone plus install.ps1, so without this there is no way to learn
    that a newer version exists short of watching the repository. The daemon checks
    GitHub's releases once a day and publishes the result as a Home Assistant `update`
    entity, which is the native surface for exactly this: it shows the installed and
    latest versions, links the release notes, and appears in Home Assistant's own
    Updates list.

    The update entity is published **without** a command topic on purpose. Home
    Assistant sends an MQTT install command that nothing here is subscribed to, and it
    reports no state change when it does - verified against a live instance - so an
    Install button on that entity would silently do nothing. The action lives on a
    separate button entity instead, which the daemon watches with the same press
    timestamp mechanism the Submit button already uses.

    Nothing installs itself. The check is passive and the install is a deliberate
    press, because this software types into terminals and writes scheduled tasks.
#>

Set-StrictMode -Version Latest

$script:BridgeUpdateConfig = @{
    CacheFile     = Join-Path $env:TEMP 'copilot-bridge-update.json'
    # A day is frequent enough to be useful and leaves the unauthenticated GitHub
    # rate limit (60/hour/IP) almost untouched.
    CheckHours    = 24
    UserAgent     = 'copilot-ha-bridge'
    RequestTimeout = 15
}

function Get-BridgeInstalledVersion {
    <#
        The installed version, recorded at install time. Falls back to the VERSION
        file beside the hooks when running from a clone.
    #>
    $recorded = Get-BridgeSetting 'updates.installedVersion' ''
    if (-not [string]::IsNullOrWhiteSpace($recorded)) { return $recorded }

    foreach ($candidate in @(
        (Join-Path $PSScriptRoot 'VERSION'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION')
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return (Get-Content -LiteralPath $candidate -Raw).Trim()
        }
    }
    '0.0.0'
}

function Get-BridgeUpdateRepository {
    $repository = Get-BridgeSetting 'updates.repository' ''
    if ([string]::IsNullOrWhiteSpace($repository)) { $repository = 'danswett/copilot-ha-bridge' }
    $repository
}

function ConvertTo-BridgeVersion {
    <# Tags are published as v1.2.3; anything unparseable sorts as 0.0.0. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $clean = ([string]$Text).Trim().TrimStart('v', 'V')
    # Drop any pre-release or build suffix: [version] cannot parse 1.2.3-beta.1.
    $clean = ($clean -split '[-+]')[0]
    $parsed = [version]'0.0.0'
    if ([version]::TryParse($clean, [ref]$parsed)) { return $parsed }
    [version]'0.0.0'
}

function Get-BridgeLatestRelease {
    <#
        The newest published release, cached so a restart loop cannot hammer GitHub.

        Returns $null when the check is skipped, fails, or the repository has no
        releases yet - an update check must never be able to break the daemon.
    #>
    param(
        [switch]$Force,
        [int]$CheckHours = $script:BridgeUpdateConfig.CheckHours
    )

    $cachePath = $script:BridgeUpdateConfig.CacheFile
    $cache = $null
    if (Test-Path -LiteralPath $cachePath) {
        $cache = try { Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json } catch { $null }
    }

    if (-not $Force -and $null -ne $cache -and $cache.PSObject.Properties.Name -contains 'CheckedAt') {
        $age = ([DateTimeOffset]::Now - [DateTimeOffset]::Parse($cache.CheckedAt)).TotalHours
        if ($age -lt $CheckHours) {
            if ($cache.PSObject.Properties.Name -contains 'Release' -and $cache.Release) { return $cache.Release }
            return $null
        }
    }

    $release = $null
    try {
        $repository = Get-BridgeUpdateRepository
        $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest" `
            -Headers @{ 'User-Agent' = $script:BridgeUpdateConfig.UserAgent; Accept = 'application/vnd.github+json' } `
            -TimeoutSec $script:BridgeUpdateConfig.RequestTimeout

        $release = [pscustomobject]@{
            Tag       = [string]$response.tag_name
            Name      = [string]$response.name
            Url       = [string]$response.html_url
            Zip       = [string]$response.zipball_url
            Notes     = [string]$response.body
            Published = [string]$response.published_at
        }
    }
    catch {
        # A 404 means no releases yet; anything else is a network or rate-limit
        # problem. Both are recorded as "checked" so the failure is not retried on
        # every reconcile.
        $release = $null
    }

    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.ToString('o')
        Release   = $release
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8

    $release
}

function Get-BridgeUpdateStatus {
    <#
        Compares the installed version with the newest release.

        Always returns an object, so a caller can publish a card whether or not an
        update exists.
    #>
    param([switch]$Force)

    $installed = Get-BridgeInstalledVersion
    $release = Get-BridgeLatestRelease -Force:$Force

    $latest = if ($release) { [string]$release.Tag } else { $installed }
    $available = $false
    if ($release) {
        $available = (ConvertTo-BridgeVersion -Text $latest) -gt (ConvertTo-BridgeVersion -Text $installed)
    }

    [pscustomobject]@{
        Installed = $installed
        Latest    = ($latest -replace '^[vV]', '')
        Available = $available
        Url       = if ($release) { [string]$release.Url } else { "https://github.com/$(Get-BridgeUpdateRepository)/releases" }
        Notes     = if ($release) { [string]$release.Notes } else { '' }
        Zip       = if ($release) { [string]$release.Zip } else { '' }
    }
}

function Invoke-BridgeSelfUpdate {
    <#
        Downloads the newest release and runs its installer.

        The installer stops and restarts the scheduled task, which kills the daemon,
        so when this is triggered from the daemon it must run detached - otherwise the
        update dies halfway through with the process that started it. -Detached starts
        an independent pwsh and returns immediately.
    #>
    param(
        [switch]$Detached,
        [string]$TargetHome
    )

    $status = Get-BridgeUpdateStatus -Force
    if (-not $status.Available) {
        return [pscustomobject]@{ Started = $false; Detail = "already on $($status.Installed)" }
    }
    if ([string]::IsNullOrWhiteSpace($status.Zip)) {
        return [pscustomobject]@{ Started = $false; Detail = 'the release has no downloadable archive' }
    }

    $staging = Join-Path $env:TEMP "copilot-ha-bridge-update-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $script = Join-Path $staging 'run-update.ps1'
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    $targetArgument = if ($TargetHome) { " -TargetHome '$TargetHome'" } else { '' }
    @"
`$ErrorActionPreference = 'Stop'
`$staging = '$staging'
`$log = Join-Path `$env:TEMP 'copilot-bridge-update.log'
`$outcomeFile = Join-Path `$env:TEMP 'copilot-bridge-update-outcome.json'
function Write-UpdateLog { param([string]`$Message) Add-Content -LiteralPath `$log -Value ("{0} {1}" -f [DateTimeOffset]::Now.ToString('o'), `$Message) }

try {
    Write-UpdateLog 'downloading $($status.Latest)'
    `$zip = Join-Path `$staging 'release.zip'
    Invoke-WebRequest -Uri '$($status.Zip)' -OutFile `$zip -Headers @{ 'User-Agent' = 'copilot-ha-bridge' } -UseBasicParsing
    Expand-Archive -LiteralPath `$zip -DestinationPath `$staging -Force
    `$root = Get-ChildItem -LiteralPath `$staging -Directory | Select-Object -First 1
    if (-not `$root) { throw 'the archive did not contain the expected folder' }

    Write-UpdateLog "installing from `$(`$root.FullName)"
    # The existing config is preserved and backed up by the installer, so no
    # settings are passed here.
    & (Join-Path `$root.FullName 'install.ps1') -NonInteractive -SkipVerify$targetArgument
    Write-UpdateLog 'update complete'
    @{ success = `$true; version = '$($status.Latest)'; releaseUrl = '$($status.Url)'; at = [DateTimeOffset]::Now.ToString('o') } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath `$outcomeFile -Encoding UTF8
    # Restart the daemon so the new code and config take effect. The installer cannot:
    # the running daemon is detached and survives the scheduled-task restart. Killing it
    # makes the supervisor relaunch a fresh one, which reads the marker above and
    # announces the result.
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { `$_.CommandLine -match 'copilot-bridge-daemon\.ps1' } |
        ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }
}
catch {
    Write-UpdateLog "update FAILED: `$(`$_.Exception.Message)"
    @{ success = `$false; error = `$_.Exception.Message; at = [DateTimeOffset]::Now.ToString('o') } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath `$outcomeFile -Encoding UTF8
}
finally {
    Remove-Item -LiteralPath `$staging -Recurse -Force -ErrorAction SilentlyContinue
}
"@ | Set-Content -LiteralPath $script -Encoding UTF8

    if ($Detached) {
        Start-Process -FilePath (Get-Command pwsh).Source `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"" `
            -WindowStyle Hidden | Out-Null
        return [pscustomobject]@{ Started = $true; Detail = "updating to $($status.Latest) in the background" }
    }

    # The child's own output would otherwise be returned alongside the result object,
    # leaving callers with an array instead of the object they expect. The updater
    # writes its progress to copilot-bridge-update.log, so nothing is lost.
    & (Get-Command pwsh).Source -NoProfile -ExecutionPolicy Bypass -File $script *>&1 | Out-Null
    [pscustomobject]@{ Started = $true; Detail = "updated to $($status.Latest)" }
}
