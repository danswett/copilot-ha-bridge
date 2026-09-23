#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for update checking.

.DESCRIPTION
    Covers version comparison, the release cache, and the safety properties that
    matter: a failing or unreachable GitHub must never break the daemon, and a
    repository with no releases must not look like an available update.

    Touches the network only in the tests that say so, and restores any cache it
    moves aside.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\bridge-update.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

# The real GitHub API is rate-limited on shared CI runners, where an unauthenticated
# 403 is indistinguishable from an outage. That made the refetch and failure tests
# non-deterministic. Simulate every fetch as an outage: the cache, version and
# failure-handling logic under test needs no real response, and this keeps the suite
# offline and stable.
function Invoke-RestMethod { throw 'network disabled in test' }

Write-Host '--- version comparison ---'
$cases = @(
    @{ Installed = '1.0.0'; Latest = 'v1.0.1'; Newer = $true }
    @{ Installed = '1.0.0'; Latest = 'v1.0.0'; Newer = $false }
    @{ Installed = '1.0.1'; Latest = 'v1.0.0'; Newer = $false }
    # String ordering would get this one wrong.
    @{ Installed = '1.2.0'; Latest = 'v1.10.0'; Newer = $true }
    @{ Installed = '1.0.0'; Latest = '2.0.0'; Newer = $true }
    @{ Installed = '1.0.0'; Latest = 'v2.0.0-beta.1'; Newer = $true }
    @{ Installed = '1.0.0'; Latest = 'not-a-version'; Newer = $false }
    @{ Installed = '1.0.0'; Latest = ''; Newer = $false }
)
foreach ($case in $cases) {
    $installed = ConvertTo-BridgeVersion -Text $case.Installed
    $latest = ConvertTo-BridgeVersion -Text $case.Latest
    Test-That "$($case.Installed) vs '$($case.Latest)' newer=$($case.Newer)" {
        ($latest -gt $installed) -eq $case.Newer
    } "$installed vs $latest"
}
Test-That 'an unparseable version sorts as 0.0.0' {
    (ConvertTo-BridgeVersion -Text 'garbage') -eq [version]'0.0.0'
}

Write-Host '--- repository resolution ---'
Test-That 'a repository is always resolved' {
    (Get-BridgeUpdateRepository) -match '^[\w.-]+/[\w.-]+$'
} (Get-BridgeUpdateRepository)

Write-Host '--- installed version ---'
Test-That 'an installed version is always reported' {
    (Get-BridgeInstalledVersion) -match '^\d+\.\d+'
} (Get-BridgeInstalledVersion)

Write-Host '--- the cache ---'
$cachePath = $script:BridgeUpdateConfig.CacheFile
$backup = "$cachePath.testbak"
if (Test-Path -LiteralPath $cachePath) { Move-Item $cachePath $backup -Force }
try {
    # A cache that is fresh must be used rather than re-fetching. A bogus tag proves
    # the value came from the cache and not the network.
    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.ToString('o')
        Release   = [pscustomobject]@{ Tag = 'v9.9.9'; Url = 'x'; Zip = 'x'; Notes = ''; Name = ''; Published = '' }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8

    $cached = Get-BridgeLatestRelease
    Test-That 'a fresh cache is reused' { $cached.Tag -eq 'v9.9.9' } (($cached.Tag) ?? 'null')

    $status = Get-BridgeUpdateStatus
    Test-That 'a newer cached release reads as available' { $status.Available } "latest=$($status.Latest)"
    Test-That 'the v prefix is stripped for display' { $status.Latest -eq '9.9.9' } $status.Latest

    # An expired cache must be refetched rather than trusted.
    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.AddDays(-3).ToString('o')
        Release   = [pscustomobject]@{ Tag = 'v9.9.9'; Url = 'x'; Zip = 'x'; Notes = ''; Name = ''; Published = '' }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    $refreshed = Get-BridgeLatestRelease
    Test-That 'an expired cache is refetched (network)' {
        $null -eq $refreshed -or $refreshed.Tag -ne 'v9.9.9'
    } $(if ($null -ne $refreshed) { $refreshed.Tag } else { 'null' })

    Write-Host '--- the check interval controls how often GitHub is polled ---'
    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.AddHours(-2).ToString('o')
        Release   = [pscustomobject]@{ Tag = 'v9.9.9'; Url = 'x'; Zip = 'x'; Notes = ''; Name = ''; Published = '' }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding UTF8
    Test-That 'a wide interval reuses a 2h-old cache' { (Get-BridgeLatestRelease -CheckHours 24).Tag -eq 'v9.9.9' }
    # A refetch hits the mocked (offline) network and returns null, proving a shorter
    # interval re-polls rather than trusting the cache.
    Test-That 'a short interval re-polls a 2h-old cache' { $null -eq (Get-BridgeLatestRelease -CheckHours 1) }

    Write-Host '--- failure is survivable ---'
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    $script:DecisionBridgeConfig.UpdateRepositoryOverride = $null
    # Point at a repository that cannot exist, which is the same shape as an outage.
    function Get-BridgeUpdateRepository { 'danswett/this-repository-does-not-exist-9f8e7d' }
    $status = Get-BridgeUpdateStatus -Force
    Test-That 'a missing repository is not an available update' { -not $status.Available }
    Test-That 'it still reports the installed version' { $status.Installed -match '^\d+\.\d+' } $status.Installed
    Test-That 'the failed check is recorded so it is not retried immediately' {
        Test-Path -LiteralPath $cachePath
    }
    Test-That 'a self-update is refused when nothing is available' {
        (Invoke-BridgeSelfUpdate).Started -eq $false
    }
}
finally {
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $backup) { Move-Item $backup $cachePath -Force }
}

Write-Host '--- the generated updater is integrity-checked and safely quoted ---'
function Get-BridgeUpdateStatus {
    param([switch]$Force)
    [pscustomobject]@{
        Installed = '1.0.0'; Latest = '9.9.9'; Available = $true
        Url = 'https://github.com/x/y/releases/tag/v9.9.9'
        Notes = ''; Zip = 'https://api.github.com/repos/x/y/zipball/v9.9.9'
    }
}
$generated = Invoke-BridgeSelfUpdate -ScriptOnly
Test-That 'the updater verifies the archive VERSION against the resolved release' {
    ($generated -match 'archiveVersion') -and ($generated -match '9\.9\.9')
}
Test-That 'the updater still runs the installer non-interactively' {
    $generated -match 'install\.ps1.*-NonInteractive'
}
Test-That 'no -TargetHome argument is emitted when none is supplied' {
    $generated -notmatch '-TargetHome'
}
$genValid = Invoke-BridgeSelfUpdate -ScriptOnly -TargetHome $env:TEMP
Test-That 'a valid TargetHome is passed through to the installer' {
    $genValid -match "-TargetHome '"
}
$quoteDir = Join-Path $env:TEMP ("bridge'quote-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $quoteDir -Force | Out-Null
try {
    $genQuote = Invoke-BridgeSelfUpdate -ScriptOnly -TargetHome $quoteDir
    Test-That 'a single quote in TargetHome is doubled, not broken out of' {
        $genQuote -match "-TargetHome '.*''.*'"
    }
}
finally {
    Remove-Item -LiteralPath $quoteDir -Recurse -Force -ErrorAction SilentlyContinue
}
$bogus = Invoke-BridgeSelfUpdate -TargetHome 'Z:\definitely\not\here\at\all'
Test-That 'a non-existent TargetHome is refused, never interpolated' {
    ($bogus.Started -eq $false) -and ($bogus.Detail -match 'not an existing directory')
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed' -ForegroundColor Green
