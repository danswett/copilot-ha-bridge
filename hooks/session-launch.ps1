<#
    Launching a brand new Copilot CLI session on request.

    Everything else in the bridge attaches to sessions that already exist: the daemon
    discovers them from the `inuse.<pid>.lock` files the CLI leaves behind. This
    module is the one place that starts one, so a session can be opened from the
    Home Assistant dashboard instead of from a keyboard.

    Three details make this work at all, and all three were verified against a live
    machine before this was written:

    * `--session-id` sets the UUID of a *new* session, not only of a resumed one. The
      daemon can therefore choose the id up front and knows exactly which session it
      just created, instead of racing to guess which of several new directories is
      the right one.
    * A process started by the hidden daemon still gets its own visible console
      window, because Start-Process goes through ShellExecute and creates a new
      console rather than inheriting the daemon's hidden one.
    * The session that results is completely ordinary. The daemon discovers it on the
      next reconcile and publishes it like any other, and console injection into it
      works, so the reply box and decision cards all function with no extra wiring.

    Nothing here needs Home Assistant, so it is straightforward to test offline.
#>

function ConvertTo-BridgeArgumentString {
    <#
        Builds a Windows command line from an argument array.

        Start-Process joins an -ArgumentList array with plain spaces and does no
        quoting of its own, so an argument containing a space silently becomes two
        arguments. The prompt typed on a phone is free text and arrives here
        unfiltered, so it has to be escaped properly rather than hopefully.

        Implements the rules CommandLineToArgvW parses: wrap an argument containing
        whitespace or a quote in double quotes, double any run of backslashes that
        immediately precedes a quote (or the closing quote), and escape embedded
        quotes with a backslash.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Arguments
    )

    $parts = foreach ($argument in $Arguments) {
        $value = [string]$argument
        if ($value.Length -gt 0 -and $value -notmatch '[\s"]') {
            $value
            continue
        }

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('"')
        $backslashes = 0
        foreach ($char in $value.ToCharArray()) {
            if ($char -eq '\') {
                $backslashes++
                continue
            }
            if ($char -eq '"') {
                # Every backslash run before a quote is doubled, then the quote itself
                # is escaped.
                [void]$sb.Append('\' * ($backslashes * 2 + 1))
                [void]$sb.Append('"')
                $backslashes = 0
                continue
            }
            if ($backslashes -gt 0) {
                [void]$sb.Append('\' * $backslashes)
                $backslashes = 0
            }
            [void]$sb.Append($char)
        }
        # Backslashes running up to the closing quote are doubled too, so the quote
        # is not swallowed as an escape.
        if ($backslashes -gt 0) { [void]$sb.Append('\' * ($backslashes * 2)) }
        [void]$sb.Append('"')
        $sb.ToString()
    }

    $parts -join ' '
}

function Get-BridgeWorkspaceChoices {
    <#
        The directories offered as launch targets, from `newSession.workspaces`.

        Each entry is either a plain path string or an object with `label` and
        `path`. A label keeps the dropdown readable on a phone, where a full path is
        unusable, and is what the daemon matches against when the button is pressed.

        This list is also the security boundary. The daemon never launches a path
        that came from Home Assistant; it launches a path that came from this file,
        selected by label. A wrong or tampered entity state can therefore only ever
        pick a directory the user already approved, or nothing at all.

        Paths that do not exist are dropped rather than offered, so the dashboard
        cannot present a choice that is guaranteed to fail.
    #>
    $configured = @(Get-BridgeSetting 'newSession.workspaces' @())

    $choices = foreach ($entry in $configured) {
        $label = ''
        $path = ''
        if ($entry -is [string]) {
            $path = [string]$entry
        }
        elseif ($null -ne $entry -and $entry.PSObject.Properties['path']) {
            $path = [string]$entry.path
            if ($entry.PSObject.Properties['label']) { $label = [string]$entry.label }
        }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        # A leading ~ is expanded so the config file stays portable between machines.
        if ($path.StartsWith('~')) { $path = Join-Path $HOME $path.Substring(1).TrimStart('\', '/') }
        try { $path = [System.IO.Path]::GetFullPath($path) } catch { continue }
        if (-not [System.IO.Directory]::Exists($path)) { continue }

        if ([string]::IsNullOrWhiteSpace($label)) { $label = [System.IO.Path]::GetFileName($path.TrimEnd('\', '/')) }
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $path }

        [pscustomobject]@{ Label = $label; Path = $path }
    }

    # Home Assistant select options must be unique, so a duplicate label would make
    # two entries indistinguishable. Keep the first and suffix the rest with their
    # path rather than dropping a directory the user deliberately listed.
    $seen = @{}
    $unique = foreach ($choice in @($choices)) {
        $label = $choice.Label
        if ($seen.ContainsKey($label)) {
            $label = "$label ($($choice.Path))"
        }
        if ($seen.ContainsKey($label)) { continue }
        $seen[$label] = $true
        [pscustomobject]@{ Label = $label; Path = $choice.Path }
    }

    @($unique)
}

function Resolve-BridgeWorkspacePath {
    <#
        Maps a dropdown label back to its approved directory. Returns $null for
        anything not currently on the list, which is what keeps an arbitrary string
        from Home Assistant out of the launch command.
    #>
    param([string]$Label)

    if ([string]::IsNullOrWhiteSpace($Label)) { return $null }
    $match = Get-BridgeWorkspaceChoices | Where-Object { $_.Label -eq $Label } | Select-Object -First 1
    if ($null -eq $match) { return $null }
    $match.Path
}

function Get-BridgeCopilotPath {
    <#
        Locates copilot.exe. An explicit `newSession.copilotPath` wins; otherwise the
        one on PATH is used. The daemon runs from a scheduled task, whose PATH can be
        narrower than an interactive shell's, so the WinGet install location is
        checked as a last resort before giving up.
    #>
    $configured = [string](Get-BridgeSetting 'newSession.copilotPath' '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if ([System.IO.File]::Exists($configured)) { return $configured }
        return $null
    }

    $command = Get-Command 'copilot' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command -and $command.Source) { return [string]$command.Source }

    $wingetPath = Join-Path $HOME 'AppData\Local\Microsoft\WinGet\Packages\GitHub.Copilot_Microsoft.Winget.Source_8wekyb3d8bbwe\copilot.exe'
    if ([System.IO.File]::Exists($wingetPath)) { return $wingetPath }

    $null
}

function Get-BridgeAgencyPath {
    <#
        Locates agency.exe, the Microsoft Agency launcher.

        Agency runs the same copilot.exe but applies a named profile: which MCP
        servers load, which plugins are mounted, and where logs go. Crucially
        `--profile-only` *ignores* the ambient ~/.copilot/mcp-config.json, so a
        session started through Agency loads the curated set for that profile rather
        than every server on the machine - which is the visible difference between a
        session launched here and one launched by hand.
    #>
    $configured = [string](Get-BridgeSetting 'newSession.agencyPath' '')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        if ([System.IO.File]::Exists($configured)) { return $configured }
        return $null
    }

    $command = Get-Command 'agency' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command -and $command.Source) { return [string]$command.Source }

    # Agency installs under Roaming and self-updates behind a CurrentVersion
    # junction, so this path stays correct across versions.
    $installed = Join-Path $env:APPDATA 'agency\CurrentVersion\agency.exe'
    if ([System.IO.File]::Exists($installed)) { return $installed }

    $null
}

function Get-BridgeLauncherKind {
    <#
        Which launcher new sessions use: 'agency' or 'copilot'.

        The default is 'auto', which prefers Agency when it is installed, because a
        machine that has Agency is a machine where sessions are expected to carry an
        Agency profile. Setting it explicitly pins the choice either way, and a
        request for Agency on a machine without it falls back rather than failing.
    #>
    $configured = ([string](Get-BridgeSetting 'newSession.launcher' 'auto')).Trim().ToLowerInvariant()

    switch ($configured) {
        'copilot' { return 'copilot' }
        'agency'  { if (Get-BridgeAgencyPath) { return 'agency' } else { return 'copilot' } }
        default   { if (Get-BridgeAgencyPath) { return 'agency' } else { return 'copilot' } }
    }
}

function Get-BridgeAgencyProfiles {
    <#
        The Agency profiles offered on the dashboard.

        Read from config rather than by shelling out to `agency config profiles` on
        every reconcile: that call costs a process launch and a config-cache read,
        and the profile list changes about as often as the config file does.
    #>
    $configured = @(Get-BridgeSetting 'newSession.profiles' @('work', 'home', 'local'))
    @($configured | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Resolve-BridgeAgencyProfile {
    <#
        Validates a profile name coming from Home Assistant against the configured
        list, for the same reason workspaces are resolved by label: a value arriving
        from outside is never passed to a command line unchecked.
    #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $match = Get-BridgeAgencyProfiles | Where-Object { $_ -eq $Name } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($match)) { return $null }
    $match
}

function Get-BridgeNewSessionArguments {
    <#
        The argument list for a new session, kept separate from the launch itself so
        it can be asserted on in tests without starting anything.

        `-i` starts interactive mode *and* runs the prompt, which is what makes a
        dashboard-launched session useful: it begins working immediately, yet stays
        interactive so the reply box and decision cards keep working afterwards. With
        no prompt the session simply opens and waits.

        Under Agency the same Copilot arguments are forwarded as pass-through
        EXTRA_ARGS, behind Agency's own options. Agency takes `--session-id` itself
        and uses that UUID for both its session and the underlying Copilot one, so
        the daemon still knows the id up front either way.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Prompt = '',
        [string]$Model = '',
        [switch]$AllowAllTools,
        [string[]]$ExtraArguments = @(),
        [ValidateSet('copilot', 'agency')][string]$Launcher = 'copilot',
        [string]$AgencyProfile = ''
    )

    # Copilot-side arguments, identical in both modes.
    $copilotArguments = @('--banner')

    if (-not [string]::IsNullOrWhiteSpace($Model)) { $copilotArguments += @('--model', $Model) }

    # Off unless explicitly configured. A session launched from a phone may well run
    # unattended, and the bridge already routes permission prompts to Home Assistant,
    # so there is no reason to hand it blanket approval by default.
    if ($AllowAllTools.IsPresent) { $copilotArguments += '--allow-all-tools' }

    foreach ($extra in @($ExtraArguments)) {
        if (-not [string]::IsNullOrWhiteSpace($extra)) { $copilotArguments += [string]$extra }
    }

    # The prompt goes last so a stray value in ExtraArguments cannot displace it.
    if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
        $copilotArguments += @('-i', ($Prompt -replace '\r?\n', ' ').Trim())
    }

    if ($Launcher -eq 'agency') {
        $arguments = @('copilot')
        # --profile-only, not --profile: it makes the named profile the whole
        # configuration and ignores ambient MCP sources, which is what keeps a
        # launched session matching a hand-launched one instead of loading every
        # server on the machine.
        if (-not [string]::IsNullOrWhiteSpace($AgencyProfile)) { $arguments += @('--profile-only', $AgencyProfile) }
        $arguments += @('--session-id', $SessionId)
        return @($arguments + $copilotArguments)
    }

    @(@('--session-id', $SessionId) + $copilotArguments)
}

function Start-BridgeCopilotSession {
    <#
        Starts a new Copilot CLI session in its own visible console window, through
        Agency when it is available.

        Returns a result object instead of throwing: a failed launch has to surface
        on the dashboard and leave the daemon running, exactly like a failed reply.

        The window is deliberately visible. A session opened from the sofa should
        still be something you can walk over to, read and take over at the keyboard,
        and an invisible one could only ever be driven through Home Assistant.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$Prompt = '',
        [string]$SessionId = '',
        [string]$AgencyProfile = ''
    )

    $result = [pscustomobject]@{
        Launched  = $false
        SessionId = $SessionId
        ProcessId = 0
        Launcher  = ''
        Detail    = ''
    }

    if (-not [System.IO.Directory]::Exists($WorkingDirectory)) {
        $result.Detail = "working directory does not exist: $WorkingDirectory"
        return $result
    }

    $launcher = Get-BridgeLauncherKind
    $result.Launcher = $launcher

    if ($launcher -eq 'agency') {
        $executable = Get-BridgeAgencyPath
        if ([string]::IsNullOrWhiteSpace($executable)) {
            $result.Detail = 'agency.exe not found; set newSession.agencyPath or newSession.launcher to "copilot"'
            return $result
        }
    }
    else {
        $executable = Get-BridgeCopilotPath
        if ([string]::IsNullOrWhiteSpace($executable)) {
            $result.Detail = 'copilot.exe not found; set newSession.copilotPath in the bridge config'
            return $result
        }
    }

    if ([string]::IsNullOrWhiteSpace($result.SessionId)) {
        $result.SessionId = [guid]::NewGuid().ToString()
    }

    $arguments = Get-BridgeNewSessionArguments `
        -SessionId $result.SessionId `
        -Prompt $Prompt `
        -Model ([string](Get-BridgeSetting 'newSession.model' '')) `
        -AllowAllTools:([bool](Get-BridgeSetting 'newSession.allowAllTools' $false)) `
        -ExtraArguments @(Get-BridgeSetting 'newSession.extraArgs' @()) `
        -Launcher $launcher `
        -AgencyProfile $AgencyProfile

    try {
        # Start-Process (ShellExecute) rather than a redirected .NET process start:
        # it gives the child its own console instead of letting it inherit the
        # daemon's hidden one, which is what makes the window visible.
        $process = Start-Process -FilePath $executable `
            -ArgumentList (ConvertTo-BridgeArgumentString -Arguments $arguments) `
            -WorkingDirectory $WorkingDirectory `
            -WindowStyle Normal -PassThru -ErrorAction Stop

        $result.ProcessId = $process.Id
        $result.Launched = $true
        $detail = "started pid $($process.Id) in $WorkingDirectory via $launcher"
        if ($launcher -eq 'agency' -and $AgencyProfile) { $detail += " (profile $AgencyProfile)" }
        $result.Detail = $detail
    }
    catch {
        $result.Detail = "launch failed: $($_.Exception.Message)"
    }

    $result
}

function Wait-BridgeSessionRegistered {
    <#
        Waits for the CLI to register the session it was told to create.

        The session directory and its `inuse.<pid>.lock` are what the daemon
        discovers sessions from, so their appearance is the real confirmation that
        the launch worked - a process id alone only proves something started, not
        that it got far enough to be a session. Used to report an honest result on
        the dashboard rather than an optimistic one.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [int]$TimeoutSeconds = 25
    )

    $directory = Join-Path $script:DecisionBridgeConfig.SessionStateRoot $SessionId
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)

    while ([DateTimeOffset]::Now -lt $deadline) {
        if ([System.IO.Directory]::Exists($directory)) {
            foreach ($lock in [System.IO.Directory]::EnumerateFiles($directory, 'inuse.*.lock')) {
                return $true
            }
        }
        Start-Sleep -Milliseconds 500
    }

    $false
}

