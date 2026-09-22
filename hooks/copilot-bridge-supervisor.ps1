<#
    Supervises the Copilot CLI bridge daemon.

    Launched by a scheduled task at logon. Keeps a single daemon instance running,
    restarting it if it ever exits, with a short backoff so a persistent failure
    cannot spin. The daemon itself holds a named mutex, so even if this supervisor is
    started twice only one daemon runs.

    Deliberately thin: all real logic lives in copilot-bridge-daemon.ps1, so this
    wrapper rarely needs to change.
#>

$ErrorActionPreference = 'Continue'

$daemon = Join-Path $PSScriptRoot 'copilot-bridge-daemon.ps1'
$logFile = Join-Path $env:TEMP 'copilot-bridge-supervisor.log'

function Write-SupervisorLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $logFile -Value "$([DateTimeOffset]::Now.ToString('o')) $Message"
    }
    catch { }
}

# One supervisor only. If the scheduled task fires more than once - a second logon
# trigger, a manual start - the second instance must not spawn a competing daemon
# that then loops against the first one's mutex. Hold a named mutex for the lifetime
# of the supervisor; a second instance that cannot acquire it exits immediately.
$supervisorMutex = [Threading.Mutex]::new($false, 'Local\CopilotBridgeSupervisor')
$ownsSupervisor = $false
try {
    $ownsSupervisor = $supervisorMutex.WaitOne([TimeSpan]::FromSeconds(2))
}
catch [System.Threading.AbandonedMutexException] {
    $ownsSupervisor = $true
}
if (-not $ownsSupervisor) {
    Write-SupervisorLog -Message "another supervisor is already running (pid $PID); exiting"
    return
}

Write-SupervisorLog -Message "supervisor starting (pid $PID)"

$backoffSeconds = 5
$maxBackoff = 120

try {
    while ($true) {
        $started = [DateTimeOffset]::Now
        try {
            $process = Start-Process -FilePath 'pwsh' `
                -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $daemon `
                -WindowStyle Hidden -PassThru
            $process.WaitForExit()
        }
        catch {
            Write-SupervisorLog -Message "daemon launch error: $($_.Exception.Message)"
        }

        $ranFor = ([DateTimeOffset]::Now - $started).TotalSeconds
        # A daemon that ran for a good while and then exited is a one-off; reset the
        # backoff. One that dies immediately is failing, so back off progressively.
        if ($ranFor -ge 60) {
            $backoffSeconds = 5
        }
        else {
            $backoffSeconds = [Math]::Min($backoffSeconds * 2, $maxBackoff)
        }

        Write-SupervisorLog -Message "daemon exited after $([Math]::Round($ranFor, 0))s; restarting in $backoffSeconds s"
        Start-Sleep -Seconds $backoffSeconds
    }
}
finally {
    if ($ownsSupervisor) {
        $supervisorMutex.ReleaseMutex()
    }
    $supervisorMutex.Dispose()
}

