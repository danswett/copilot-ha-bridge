#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for launching a new Copilot CLI session from Home Assistant.

.DESCRIPTION
    The bridge used to be able only to attach to sessions someone had already
    started at a keyboard. These cover the pieces that let a dashboard button start
    one:

      * ConvertTo-BridgeArgumentString - Windows command-line quoting. Asserted by
        round-tripping through the real CommandLineToArgvW parser rather than by
        matching strings, because the prompt is free text typed on a phone and
        getting this wrong would split or mangle arguments.
      * Get-BridgeWorkspaceChoices / Resolve-BridgeWorkspacePath - the approved
        directory list, which is also the security boundary: a path from Home
        Assistant is never launched, only a label resolved against this list.
      * Get-BridgeNewSessionArguments - the command line itself, including that
        --allow-all-tools is opt-in.
      * Publish-CopilotMqttNewSession - the discovery payloads.
      * Sync-DaemonNewSession - press-timestamp semantics and refusal cases.

    Nothing here contacts Home Assistant or starts a real process.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:COPILOT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\copilot-bridge-daemon.ps1')

# Send this run's log lines to a throwaway file. Dot-sourcing the daemon brings its
# real log path with it, so without this a test run writes entries like
# "new session launched: started pid 4242" into the live daemon log, where they look
# exactly like real events during a later investigation.
$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-new-session-$([guid]::NewGuid().ToString('N').Substring(0,8)).log"
$testLogFile = $script:DaemonConfig.LogFile

$headers = @{ Authorization = '******' }

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

# --- argument quoting, verified against the real parser --------------------------

Add-Type -Namespace BridgeTest -Name Cmd -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr CommandLineToArgvW(string lpCmdLine, out int pNumArgs);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr LocalFree(System.IntPtr hMem);
'@

function ConvertFrom-CommandLine {
    <#
        Parses a command line exactly the way a launched process will. argv[0] is
        parsed under different rules, so a dummy program name is prepended and then
        dropped.
    #>
    param([string]$CommandLine)

    $count = 0
    $ptr = [BridgeTest.Cmd]::CommandLineToArgvW("app.exe $CommandLine", [ref]$count)
    if ($ptr -eq [IntPtr]::Zero) { throw 'CommandLineToArgvW failed' }
    try {
        $parsed = for ($i = 1; $i -lt $count; $i++) {
            [System.Runtime.InteropServices.Marshal]::PtrToStringUni(
                [System.Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $i * [IntPtr]::Size))
        }
        @($parsed)
    }
    finally { [void][BridgeTest.Cmd]::LocalFree($ptr) }
}

Write-Host '--- argument quoting round-trips through CommandLineToArgvW ---'

$cases = @(
    @{ Name = 'a plain argument';            Args = @('--banner') }
    @{ Name = 'an argument with spaces';     Args = @('-i', 'fix the bug in main.js') }
    @{ Name = 'embedded double quotes';      Args = @('-i', 'say "hello world" twice') }
    @{ Name = 'a trailing backslash';        Args = @('-C', 'C:\repos\bridge\') }
    @{ Name = 'a backslash before a quote';  Args = @('-i', 'path is C:\x\" ok') }
    @{ Name = 'several backslashes';         Args = @('-i', 'a\\\b c') }
    @{ Name = 'an empty argument';           Args = @('-i', '') }
    @{ Name = 'a full launch line';          Args = @('--session-id', '0cb916db-26aa-40f2-86b5-1ba81b225fd2', '--banner', '-i', 'refactor the "login" flow') }
)

foreach ($case in $cases) {
    $line = ConvertTo-BridgeArgumentString -Arguments $case.Args
    $round = @(ConvertFrom-CommandLine -CommandLine $line)
    $expected = @($case.Args)
    Test-That "$($case.Name) survives a round trip" {
        $round.Count -eq $expected.Count -and
        (0..($expected.Count - 1) | ForEach-Object { $round[$_] -ceq $expected[$_] }) -notcontains $false
    } "line='$line' parsed=[$($round -join '][')]"
}

Test-That 'a prompt with a space is one argument, not several' {
    (ConvertFrom-CommandLine -CommandLine (ConvertTo-BridgeArgumentString -Arguments @('-i', 'two words'))).Count -eq 2
}

Test-That 'a quote in the prompt cannot inject an extra argument' {
    $evil = 'hi" --allow-all-tools "'
    $parsed = @(ConvertFrom-CommandLine -CommandLine (ConvertTo-BridgeArgumentString -Arguments @('-i', $evil)))
    $parsed.Count -eq 2 -and $parsed[1] -ceq $evil -and $parsed -notcontains '--allow-all-tools'
}

# --- the approved workspace list -------------------------------------------------

$root = Join-Path ([IO.Path]::GetTempPath()) "bridge-ws-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$alpha = Join-Path $root 'alpha'
$beta = Join-Path $root 'nested\beta'
$dupe = Join-Path $root 'other\alpha'
foreach ($d in @($alpha, $beta, $dupe)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
$missing = Join-Path $root 'does-not-exist'

$script:FakeSettings = @{}
function Get-BridgeSetting {
    param([Parameter(Mandatory)][string]$Path, $Default = $null)
    if ($script:FakeSettings.ContainsKey($Path)) { return $script:FakeSettings[$Path] }
    $Default
}

Write-Host ''
Write-Host '--- the workspace list ---'

$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha, $missing) }
$choices = @(Get-BridgeWorkspaceChoices)
Test-That 'a plain path string becomes a choice' { $choices.Count -eq 1 -and $choices[0].Path -eq $alpha }
Test-That 'the label defaults to the folder name' { $choices[0].Label -eq 'alpha' }
Test-That 'a directory that does not exist is dropped' { $choices.Path -notcontains $missing }

$script:FakeSettings = @{ 'newSession.workspaces' = @(
    [pscustomobject]@{ label = 'Beta project'; path = $beta }
) }
$choices = @(Get-BridgeWorkspaceChoices)
Test-That 'an explicit label is used' { $choices.Count -eq 1 -and $choices[0].Label -eq 'Beta project' }

$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha, $dupe) }
$choices = @(Get-BridgeWorkspaceChoices)
Test-That 'two folders with the same name both survive' { $choices.Count -eq 2 }
Test-That 'the duplicate label is disambiguated' { ($choices | Select-Object -Expand Label | Sort-Object -Unique).Count -eq 2 }

$script:FakeSettings = @{ 'newSession.workspaces' = @() }
Test-That 'no configuration yields no choices' { @(Get-BridgeWorkspaceChoices).Count -eq 0 }

Write-Host ''
Write-Host '--- defaults, so a launch needs no input ---'

$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha, $beta) }
Test-That 'the first workspace is the default when none is configured' {
    (Get-BridgeDefaultWorkspaceLabel) -eq 'alpha'
}
$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha, $beta); 'newSession.defaultWorkspace' = 'beta' }
Test-That 'a configured default workspace is used' { (Get-BridgeDefaultWorkspaceLabel) -eq 'beta' }
$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha, $beta); 'newSession.defaultWorkspace' = 'gone' }
Test-That 'a default naming a missing workspace falls back to the first' {
    (Get-BridgeDefaultWorkspaceLabel) -eq 'alpha'
}
$script:FakeSettings = @{ 'newSession.workspaces' = @() }
Test-That 'no workspaces means no default' { (Get-BridgeDefaultWorkspaceLabel) -eq '' }

$script:FakeSettings = @{ 'newSession.profiles' = @('work', 'home') }
Test-That 'the first profile is the default when none is configured' { (Get-BridgeDefaultAgencyProfile) -eq 'work' }
$script:FakeSettings = @{ 'newSession.profiles' = @('work', 'home'); 'newSession.defaultProfile' = 'home' }
Test-That 'a configured default profile is used' { (Get-BridgeDefaultAgencyProfile) -eq 'home' }
$script:FakeSettings = @{ 'newSession.profiles' = @('work', 'home'); 'newSession.defaultProfile' = 'nope' }
Test-That 'a default naming a missing profile falls back to the first' { (Get-BridgeDefaultAgencyProfile) -eq 'work' }

Write-Host ''
Write-Host '--- label resolution is the security boundary ---'

$script:FakeSettings = @{ 'newSession.workspaces' = @($alpha) }
Test-That 'a known label resolves to its approved path' { (Resolve-BridgeWorkspacePath -Label 'alpha') -eq $alpha }
Test-That 'an unknown label resolves to nothing' { $null -eq (Resolve-BridgeWorkspacePath -Label 'alpha-evil') }
Test-That 'an arbitrary path is not accepted as a label' { $null -eq (Resolve-BridgeWorkspacePath -Label 'C:\Windows\System32') }
Test-That 'an empty label resolves to nothing' { $null -eq (Resolve-BridgeWorkspacePath -Label '') }

# --- the command line ------------------------------------------------------------

Write-Host ''
Write-Host '--- the launch arguments ---'

$sid = '0cb916db-26aa-40f2-86b5-1ba81b225fd2'
$args1 = @(Get-BridgeNewSessionArguments -SessionId $sid)
Test-That 'the session id is set explicitly' { $args1 -contains '--session-id' -and $args1 -contains $sid }
Test-That 'no prompt means no -i' { $args1 -notcontains '-i' }
Test-That 'tools are not auto-approved by default' { $args1 -notcontains '--allow-all-tools' }

$args2 = @(Get-BridgeNewSessionArguments -SessionId $sid -Prompt 'do the thing')
Test-That 'a prompt is passed with -i so the session stays interactive' {
    $args2 -contains '-i' -and $args2[$args2.IndexOf('-i') + 1] -eq 'do the thing'
}

$args3 = @(Get-BridgeNewSessionArguments -SessionId $sid -Prompt "line one`r`nline two")
Test-That 'a newline in the prompt is flattened' {
    $args3[$args3.IndexOf('-i') + 1] -eq 'line one line two'
}

$args4 = @(Get-BridgeNewSessionArguments -SessionId $sid -Prompt '   ')
Test-That 'a whitespace-only prompt is treated as no prompt' { $args4 -notcontains '-i' }

$args5 = @(Get-BridgeNewSessionArguments -SessionId $sid -Model 'gpt-5.4' -AllowAllTools)
Test-That 'a configured model is passed through' { $args5[$args5.IndexOf('--model') + 1] -eq 'gpt-5.4' }
Test-That 'tools are auto-approved only when asked for' { $args5 -contains '--allow-all-tools' }

$args6 = @(Get-BridgeNewSessionArguments -SessionId $sid -Prompt 'p' -ExtraArguments @('--plan'))
Test-That 'extra arguments are included' { $args6 -contains '--plan' }
Test-That 'the prompt stays last so extras cannot displace it' { $args6[-2] -eq '-i' -and $args6[-1] -eq 'p' }

# --- Agency ----------------------------------------------------------------------

Write-Host ''
Write-Host '--- launching through Agency ---'

$ag = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'agency' -AgencyProfile 'work' -Prompt 'do it')
Test-That 'the agency command is copilot' { $ag[0] -eq 'copilot' }
Test-That 'the profile is applied with --profile-only' {
    $ag[$ag.IndexOf('--profile-only') + 1] -eq 'work'
}
Test-That 'agency is given the session id so both layers share it' {
    $ag[$ag.IndexOf('--session-id') + 1] -eq $sid
}
Test-That 'agency options precede the copilot pass-through args' {
    $ag.IndexOf('--profile-only') -lt $ag.IndexOf('--banner') -and
    $ag.IndexOf('--session-id') -lt $ag.IndexOf('--banner')
}
Test-That 'the prompt still rides on -i' { $ag[$ag.IndexOf('-i') + 1] -eq 'do it' }
Test-That '--profile is never used, only --profile-only' { $ag -notcontains '--profile' }

$agNoProfile = @(Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'agency')
Test-That 'no profile means no --profile-only' { $agNoProfile -notcontains '--profile-only' }
Test-That 'and agency still gets the session id' { $agNoProfile -contains '--session-id' }

$agLine = ConvertTo-BridgeArgumentString -Arguments (
    Get-BridgeNewSessionArguments -SessionId $sid -Launcher 'agency' -AgencyProfile 'work' -Prompt 'refactor the "login" flow')
$agParsed = @(ConvertFrom-CommandLine -CommandLine $agLine)
Test-That 'the whole agency line survives a round trip' {
    $agParsed[0] -eq 'copilot' -and $agParsed[-1] -ceq 'refactor the "login" flow'
}

Write-Host ''
Write-Host '--- profile validation ---'

$script:FakeSettings = @{ 'newSession.profiles' = @('work', 'home', 'local') }
Test-That 'configured profiles are offered' { (Get-BridgeAgencyProfiles) -join ',' -eq 'work,home,local' }
Test-That 'a known profile resolves' { (Resolve-BridgeAgencyProfile -Name 'home') -eq 'home' }
Test-That 'an unknown profile is refused' { $null -eq (Resolve-BridgeAgencyProfile -Name 'prod') }
Test-That 'an injected profile string is refused' { $null -eq (Resolve-BridgeAgencyProfile -Name 'work --yolo') }
Test-That 'an empty profile is refused' { $null -eq (Resolve-BridgeAgencyProfile -Name '') }

$script:FakeSettings = @{}
Test-That 'the default profile list is work, home, local' { (Get-BridgeAgencyProfiles) -join ',' -eq 'work,home,local' }

Write-Host ''
Write-Host '--- launcher selection ---'

# Shadow the probes so launcher selection can be tested without either tool present.
$script:AgencyPresent = $true
function Get-BridgeAgencyPath { if ($script:AgencyPresent) { 'C:\agency.exe' } else { $null } }

$script:FakeSettings = @{ 'newSession.launcher' = 'auto' }
$script:AgencyPresent = $true
Test-That 'auto prefers Agency when it is installed' { (Get-BridgeLauncherKind) -eq 'agency' }
$script:AgencyPresent = $false
Test-That 'auto falls back to copilot without Agency' { (Get-BridgeLauncherKind) -eq 'copilot' }

$script:FakeSettings = @{ 'newSession.launcher' = 'copilot' }
$script:AgencyPresent = $true
Test-That 'an explicit copilot setting is honoured even with Agency installed' { (Get-BridgeLauncherKind) -eq 'copilot' }

$script:FakeSettings = @{ 'newSession.launcher' = 'agency' }
$script:AgencyPresent = $false
Test-That 'asking for Agency without it installed falls back rather than failing' { (Get-BridgeLauncherKind) -eq 'copilot' }

$script:FakeSettings = @{ 'newSession.launcher' = 'AGENCY' }
$script:AgencyPresent = $true
Test-That 'the launcher setting is case-insensitive' { (Get-BridgeLauncherKind) -eq 'agency' }

# --- the resume list ---------------------------------------------------------------

Write-Host ''
Write-Host '--- the resumable session list ---'

# Shadow the one slow, machine-dependent step so the parsing is testable offline.
$script:AgencyJson = ''
function Get-BridgeAgencySessionJson { $script:AgencyJson }

function Set-AgencySessions {
    param([object[]]$Sessions)
    $script:AgencyJson = (@{ sessions = $Sessions } | ConvertTo-Json -Depth 8)
}

$script:FakeSettings = @{ 'newSession.resumeCount' = 10 }

Set-AgencySessions -Sessions @(
    @{ session_id = 'aaaaaaaa-0000-0000-0000-000000000001'; summary = 'Older work'; folder = 'C:\repos\alpha'; can_resume = $true;  updated_at = '2026-09-20T10:00:00Z' }
    @{ session_id = 'bbbbbbbb-0000-0000-0000-000000000002'; summary = 'Newest work'; folder = 'C:\repos\beta'; can_resume = $true;  updated_at = '2026-09-23T10:00:00Z' }
    @{ session_id = 'cccccccc-0000-0000-0000-000000000003'; summary = 'A VS Code one'; folder = 'C:\repos\beta'; can_resume = $false; updated_at = '2026-09-23T11:00:00Z' }
    @{ session_id = 'dddddddd-0000-0000-0000-000000000004'; summary = '';             folder = 'C:\repos\beta'; can_resume = $true;  updated_at = '2026-09-21T10:00:00Z' }
)
$resume = @(Get-BridgeResumableSessions)

Test-That 'non-resumable sessions are dropped' { $resume.SessionId -notcontains 'cccccccc-0000-0000-0000-000000000003' }
Test-That 'the newest session comes first' { $resume[0].SessionId -eq 'bbbbbbbb-0000-0000-0000-000000000002' }
Test-That 'the label carries the summary and the folder' { $resume[0].Label -eq 'Newest work - beta' }
Test-That 'a session with no summary still gets a usable label' {
    ($resume | Where-Object { $_.SessionId -like 'dddddddd*' }).Label -match '^Session dddddddd'
}
Test-That 'the folder is carried through for the working directory' { $resume[0].Folder -eq 'C:\repos\beta' }

$excluded = @(Get-BridgeResumableSessions -Exclude @('bbbbbbbb-0000-0000-0000-000000000002'))
Test-That 'a live session is excluded' { $excluded.SessionId -notcontains 'bbbbbbbb-0000-0000-0000-000000000002' }

$limited = @(Get-BridgeResumableSessions -Limit 1)
Test-That 'the list honours its limit' { $limited.Count -eq 1 -and $limited[0].SessionId -eq 'bbbbbbbb-0000-0000-0000-000000000002' }

Set-AgencySessions -Sessions @(
    @{ session_id = 'aaaaaaaa-0000-0000-0000-000000000001'; summary = 'Same name'; folder = 'C:\repos\alpha'; can_resume = $true; updated_at = '2026-09-23T10:00:00Z' }
    @{ session_id = 'bbbbbbbb-0000-0000-0000-000000000002'; summary = 'Same name'; folder = 'C:\repos\alpha'; can_resume = $true; updated_at = '2026-09-22T10:00:00Z' }
)
$dupes = @(Get-BridgeResumableSessions)
Test-That 'two sessions with the same summary stay distinguishable' {
    $dupes.Count -eq 2 -and ($dupes.Label | Sort-Object -Unique).Count -eq 2
}

Set-AgencySessions -Sessions @(
    @{ session_id = 'eeeeeeee-0000-0000-0000-000000000005'; summary = ('z' * 400); folder = 'C:\repos\alpha'; can_resume = $true; updated_at = '2026-09-23T10:00:00Z' }
)
Test-That 'a very long summary is trimmed to stay a valid option' {
    (Get-BridgeResumableSessions)[0].Label.Length -le 130
}

$script:AgencyJson = 'not json at all'
Test-That 'malformed output yields an empty list rather than throwing' { @(Get-BridgeResumableSessions).Count -eq 0 }
$script:AgencyJson = ''
Test-That 'no Agency output yields an empty list' { @(Get-BridgeResumableSessions).Count -eq 0 }
$script:AgencyJson = '{"unexpected":true}'
Test-That 'output without a sessions array yields an empty list' { @(Get-BridgeResumableSessions).Count -eq 0 }

# --- discovery payloads ----------------------------------------------------------

Write-Host ''
Write-Host '--- the published entities ---'

$script:MqttMsgs = @()
function Publish-CopilotMqttMessage {
    param([string]$Topic, [AllowEmptyString()][string]$Payload, [hashtable]$Headers, [switch]$Retain)
    $script:MqttMsgs += [pscustomobject]@{ Topic = $Topic; Payload = $Payload }
}

$script:MqttMsgs = @()
Publish-CopilotMqttNewSession -Workspaces @(
    [pscustomobject]@{ Label = 'alpha'; Path = $alpha }
    [pscustomobject]@{ Label = 'Beta project'; Path = $beta }
) -Profiles @('work', 'home') -Resumable @(
    [pscustomobject]@{ Label = 'Fix the thing - alpha'; SessionId = 'aaaaaaaa-0000-0000-0000-000000000001'; Folder = 'C:\repos\alpha' }
) -Headers $headers

function Get-Config { param([string]$Match) ($script:MqttMsgs | Where-Object { $_.Topic -match $Match } | Select-Object -First 1).Payload }

Test-That 'a prompt text entity is published'  { (Get-Config 'text/agent_bridge/new_prompt/config') -match '"unique_id":"agent_bridge_new_prompt"' }
Test-That 'a workspace select is published'    { (Get-Config 'select/agent_bridge/new_workspace/config') -match '"unique_id":"agent_bridge_new_workspace"' }
Test-That 'a profile select is published'      { (Get-Config 'select/agent_bridge/new_profile/config') -match '"unique_id":"agent_bridge_new_profile"' }
Test-That 'the profile select offers the profiles' { (Get-Config 'new_profile/config') -match 'work' -and (Get-Config 'new_profile/config') -match 'home' }
Test-That 'a launch button is published'       { (Get-Config 'button/agent_bridge/new_session/config') -match '"unique_id":"agent_bridge_new_session"' }
Test-That 'a resume select is published'       { (Get-Config 'select/agent_bridge/new_resume/config') -match '"unique_id":"agent_bridge_new_resume"' }
Test-That 'resume defaults to starting fresh'  { (Get-Config 'new_resume/config') -match '"options":\["New session"' }
Test-That 'the resume list offers the session' { (Get-Config 'new_resume/config') -match 'Fix the thing - alpha' }
Test-That 'a result sensor is published'       { (Get-Config 'sensor/agent_bridge/new_session_result/config') -match '"unique_id":"agent_bridge_new_session_result"' }
Test-That 'the select offers both workspaces'  { (Get-Config 'new_workspace/config') -match 'alpha' -and (Get-Config 'new_workspace/config') -match 'Beta project' }
Test-That 'they all land on the bridge device' { (Get-Config 'new_prompt/config') -match '"identifiers":\["agent_bridge"\]' }
Test-That 'the prompt box is optimistic (no state topic)' { (Get-Config 'new_prompt/config') -notmatch '"state_topic"' }
Test-That 'the result sensor does have a state topic' { (Get-Config 'new_session_result/config') -match '"state_topic"' }

$script:MqttMsgs = @()
Publish-CopilotMqttNewSession -Workspaces @() -Headers $headers
Test-That 'an empty list still publishes a valid select' {
    $cfg = Get-Config 'new_workspace/config'
    $cfg -match '"options":\[' -and $cfg -match 'no workspaces configured'
}
Test-That 'no profiles still publishes a valid profile select' {
    $cfg = Get-Config 'new_profile/config'
    $cfg -match '"options":\[' -and $cfg -match 'default'
}

$script:MqttMsgs = @()
Set-CopilotMqttNewSessionResult -Text ('y' * 400) -Headers $headers
Test-That 'a long result is truncated to the state limit' {
    ($script:MqttMsgs | Where-Object { $_.Topic -match '/newsession/result$' } | Select-Object -First 1).Payload.Length -le 255
}

# --- the daemon reconcile --------------------------------------------------------

Write-Host ''
Write-Host '--- press handling ---'

$script:HaStates = @{}
$script:Launches = @()
$script:Results = @()
$script:Cleared = @()

function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if (-not $script:HaStates.ContainsKey($EntityId)) { throw "no such entity $EntityId" }
    [pscustomobject]@{ state = $script:HaStates[$EntityId] }
}
function Publish-CopilotMqttNewSession { param([object[]]$Workspaces, [string[]]$Profiles = @(), [object[]]$Resumable = @(), [string]$LastResult = '', [hashtable]$Headers) }
function Set-CopilotMqttNewSessionEntityIds { $false }
function Set-CopilotMqttNewSessionResult {
    param([string]$Text = '', [hashtable]$Headers)
    $script:Results += $Text
}
function Start-BridgeCopilotSession {
    param([string]$WorkingDirectory, [string]$Prompt = '', [string]$SessionId = '', [string]$AgencyProfile = '', [switch]$Resume)
    $script:Launches += [pscustomobject]@{
        Directory = $WorkingDirectory; Prompt = $Prompt; AgencyProfile = $AgencyProfile
        SessionId = $SessionId; Resumed = $Resume.IsPresent
    }
    $id = if ($SessionId) { $SessionId } else { '11111111-2222-3333-4444-555555555555' }
    [pscustomobject]@{ Launched = $true; SessionId = $id; ProcessId = 4242; Launcher = 'agency'; Detail = 'started pid 4242' }
}
function Wait-BridgeSessionRegistered { param([string]$SessionId, [int]$TimeoutSeconds = 25) $true }
function Invoke-HomeAssistantService {
    param([string]$Domain, [string]$Service, [hashtable]$Data, [hashtable]$Headers)
    $script:Cleared += "$Domain.$Service"
}

function Reset-NewSessionTest {
    param(
        [string]$Press,
        [string]$Workspace = 'alpha',
        [string]$Prompt = 'do the thing',
        [string]$ProfileState = 'work',
        [string]$ResumeState = 'New session'
    )
    $script:Launches = @()
    $script:Results = @()
    $script:Cleared = @()
    $script:DaemonNewSessionPublished = $true
    $script:DaemonNewSessionSignature = "alpha=$alpha"
    $script:DaemonNewSessionLastPress = ''
    $script:DaemonStartedAt = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
    $script:HaStates = @{
        'button.agent_bridge_new_session'   = $Press
        'select.agent_bridge_new_workspace' = $Workspace
        'select.agent_bridge_new_profile'   = $ProfileState
        'select.agent_bridge_new_resume'    = $ResumeState
        'text.agent_bridge_new_prompt'      = $Prompt
    }
}

# No resumable sessions unless a test asks for them, and an empty live set.
$script:AgencyJson = ''
$noLive = @{}
function Reset-ResumeCache { $script:DaemonResumeCache = @(); $script:DaemonResumeCacheAt = [DateTimeOffset]::MinValue }
Reset-ResumeCache

# Agency is the launcher for these, so the profile path is exercised.
$script:AgencyPresent = $true
$script:FakeSettings = @{
    'newSession.workspaces' = @($alpha)
    'newSession.launcher'   = 'agency'
    'newSession.profiles'   = @('work', 'home', 'local')
}

Reset-NewSessionTest -Press '2026-06-01T12:00:00+00:00'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a fresh press launches a session' { $script:Launches.Count -eq 1 }
Test-That 'it launches in the selected workspace' { $script:Launches[0].Directory -eq $alpha }
Test-That 'it passes the typed prompt' { $script:Launches[0].Prompt -eq 'do the thing' }
Test-That 'it passes the selected profile' { $script:Launches[0].AgencyProfile -eq 'work' }
Test-That 'it reports the result' { ($script:Results -join ' ') -match 'Started' }
Test-That 'the result names the profile' { ($script:Results -join ' ') -match 'work' }
Test-That 'it clears the prompt box afterwards' { $script:Cleared -contains 'text.set_value' }

Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'the same press does not launch twice' { $script:Launches.Count -eq 1 }

Reset-NewSessionTest -Press '2025-01-01T00:00:00+00:00'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a press from before the daemon started is ignored' { $script:Launches.Count -eq 0 }

Reset-NewSessionTest -Press 'unknown'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an unknown button state is ignored' { $script:Launches.Count -eq 0 }

Reset-NewSessionTest -Press '2026-06-01T12:05:00+00:00' -Workspace 'somewhere-else'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an unapproved workspace refuses to launch' { $script:Launches.Count -eq 0 }
Test-That 'and says why' { ($script:Results -join ' ') -match 'Unknown workspace' }

Reset-NewSessionTest -Press '2026-06-01T12:06:00+00:00' -Workspace 'unknown'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an untouched selector falls back to the first workspace' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].Directory -eq $alpha
}

Reset-NewSessionTest -Press '2026-06-01T12:07:00+00:00' -Prompt 'unknown'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an untouched prompt box launches with no prompt' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].Prompt -eq ''
}
# An untouched box reads `unknown`, which renders as "(empty value)". Priming it to
# blank is the point of the defaults pass, so one write here is correct - what must
# not happen is the post-launch clear running as well for a prompt that was empty.
Test-That 'an untouched prompt box is primed blank rather than left unknown' {
    $script:Cleared -contains 'text.set_value'
}
Test-That 'and it is written exactly once, not primed and then cleared again' {
    @($script:Cleared | Where-Object { $_ -eq 'text.set_value' }).Count -eq 1
}

Reset-NewSessionTest -Press '2026-06-01T12:10:00+00:00' -ProfileState 'home'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a different profile is honoured' { $script:Launches[0].AgencyProfile -eq 'home' }

Write-Host ''
Write-Host '--- resuming a previous session ---'

# A resumable session whose folder really exists, so the resume path can assert on
# the working directory it chooses.
Set-AgencySessions -Sessions @(
    @{ session_id = 'f0f0f0f0-1111-2222-3333-444444444444'; summary = 'Earlier work'; folder = $beta; can_resume = $true; updated_at = '2026-09-23T10:00:00Z' }
)
$resumeLabel = 'Earlier work - beta'

Reset-NewSessionTest -Press '2026-06-01T12:20:00+00:00' -ResumeState $resumeLabel
Reset-ResumeCache
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a resume selection launches that session id' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].SessionId -eq 'f0f0f0f0-1111-2222-3333-444444444444'
}
Test-That 'it is flagged as a resume' { $script:Launches[0].Resumed }
Test-That 'it uses the session own folder, not the workspace' { $script:Launches[0].Directory -eq $beta }
Test-That 'the profile still applies to a resume' { $script:Launches[0].AgencyProfile -eq 'work' }
Test-That 'the result says it resumed' { ($script:Results -join ' ') -match 'Resum' }

Reset-NewSessionTest -Press '2026-06-01T12:21:00+00:00' -ResumeState 'New session'
Reset-ResumeCache
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'the New session option starts a fresh session' {
    $script:Launches.Count -eq 1 -and -not $script:Launches[0].Resumed -and $script:Launches[0].SessionId -eq ''
}
Test-That 'and uses the selected workspace' { $script:Launches[0].Directory -eq $alpha }

Reset-NewSessionTest -Press '2026-06-01T12:22:00+00:00' -ResumeState 'Something that vanished - old'
Reset-ResumeCache
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'a stale resume selection refuses to launch' { $script:Launches.Count -eq 0 }
Test-That 'and says so' { ($script:Results -join ' ') -match 'no longer resumable' }

# A live session must never be offered for resume: two CLIs on one transcript.
Reset-ResumeCache
$live = @{ 'f0f0f0f0-1111-2222-3333-444444444444' = $true }
Test-That 'a live session is kept out of the resume list' {
    @(Get-DaemonResumableSessions -LiveSessionIds @($live.Keys)).Count -eq 0
}

# The Agency query is expensive, so it must be cached between reconciles.
Reset-ResumeCache
$script:AgencyJsonCalls = 0
function Get-BridgeAgencySessionJson { $script:AgencyJsonCalls++; $script:AgencyJson }
$null = Get-DaemonResumableSessions -LiveSessionIds @()
$null = Get-DaemonResumableSessions -LiveSessionIds @()
$null = Get-DaemonResumableSessions -LiveSessionIds @()
Test-That 'the session list is fetched once within the cache window' { $script:AgencyJsonCalls -eq 1 }
$script:DaemonResumeCacheAt = [DateTimeOffset]::Now.AddSeconds(-9999)
$null = Get-DaemonResumableSessions -LiveSessionIds @()
Test-That 'an expired cache refetches' { $script:AgencyJsonCalls -eq 2 }
$null = Get-DaemonResumableSessions -LiveSessionIds @() -Force
Test-That 'a forced refresh refetches' { $script:AgencyJsonCalls -eq 3 }

Write-Host ''
Write-Host '--- press handling, continued ---'
$script:AgencyJson = ''
Reset-ResumeCache

Reset-NewSessionTest -Press '2026-06-01T12:11:00+00:00' -ProfileState 'unknown'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an untouched profile selector falls back to the first profile' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].AgencyProfile -eq 'work'
}

Reset-NewSessionTest -Press '2026-06-01T12:12:00+00:00' -ProfileState 'prod --yolo'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'an unapproved profile refuses to launch' { $script:Launches.Count -eq 0 }
Test-That 'and says which profile' { ($script:Results -join ' ') -match 'Unknown profile' }

# Under the plain copilot launcher the profile is irrelevant and must not be passed.
$script:FakeSettings = @{
    'newSession.workspaces' = @($alpha)
    'newSession.launcher'   = 'copilot'
    'newSession.profiles'   = @('work', 'home', 'local')
}
Reset-NewSessionTest -Press '2026-06-01T12:13:00+00:00' -ProfileState 'home'
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'the copilot launcher ignores the profile entirely' {
    $script:Launches.Count -eq 1 -and $script:Launches[0].AgencyProfile -eq ''
}

$script:FakeSettings = @{
    'newSession.workspaces' = @($alpha)
    'newSession.launcher'   = 'agency'
    'newSession.profiles'   = @('work', 'home', 'local')
}

Reset-NewSessionTest -Press '2026-06-01T12:08:00+00:00'
$script:FakeSettings = @{ 'newSession.workspaces' = @() }
$script:DaemonNewSessionSignature = ''
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'no configured workspaces refuses to launch' { $script:Launches.Count -eq 0 }
Test-That 'and explains what to configure' { ($script:Results -join ' ') -match 'No workspaces configured' }

$script:FakeSettings = @{ 'newSession.enabled' = $false; 'newSession.workspaces' = @($alpha) }
Reset-NewSessionTest -Press '2026-06-01T12:09:00+00:00'
Sync-DaemonNewSession -Headers $headers -Live $noLive
Test-That 'the whole feature can be turned off' { $script:Launches.Count -eq 0 -and $script:Results.Count -eq 0 }

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $testLogFile -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green


