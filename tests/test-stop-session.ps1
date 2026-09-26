#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for ending a session from Home Assistant.

.DESCRIPTION
    The bridge could start a session remotely but not stop one, so a session that
    went wrong could only be dealt with at the keyboard - and sessions accumulated.

    These cover the two halves without touching Home Assistant or killing anything:

      * Stop-BridgeCopilotSession - graceful `/exit` first, terminate only if the
        process outlives the grace period, and honest reporting either way.
      * Invoke-PendingStops - the press-timestamp contract shared with the Submit and
        Launch buttons: one press acts once, a retained press from a previous run is
        ignored, and a session that is not live is never touched.
      * The stop button is published, cleared with the rest of the session, and
        carries a deterministic entity id.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')

$script:DaemonConfig.LogFile = Join-Path ([IO.Path]::GetTempPath()) "test-stop-session-$([guid]::NewGuid().ToString('N').Substring(0,8)).log"
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

# --- Stop-BridgeCopilotSession ---------------------------------------------------

Write-Host '--- stopping a session ---'

$script:Injected = @()
$script:InjectResult = $true
function Send-CopilotSessionPrompt {
    param([string]$SessionId, [string]$Text, [switch]$NoSubmit, [int]$SubmitDelayMs = 300, [int]$ProcessId = 0)
    $script:Injected += [pscustomobject]@{ SessionId = $SessionId; Text = $Text; ProcessId = $ProcessId }
    [pscustomobject]@{ Delivered = $script:InjectResult; ProcessId = $ProcessId; Detail = if ($script:InjectResult) { 'ok:5' } else { 'attach-failed:5' } }
}

# Process liveness is modelled rather than scripted: the process is alive until it
# either exits on its own after N probes (the graceful case) or is terminated, which
# is what makes the post-terminate confirmation meaningful.
$script:Probes = 0
$script:ExitsAfterProbes = 0
$script:ProcKilled = $false
$script:Killed = @()
function Get-Process {
    param([int]$Id, [string]$Name, [switch]$ErrorAction)
    $script:Probes++
    if ($script:ProcKilled) { return $null }
    if ($script:ExitsAfterProbes -gt 0 -and $script:Probes -ge $script:ExitsAfterProbes) { return $null }
    [pscustomobject]@{ Id = $Id }
}
function Stop-Process {
    param([int]$Id, [switch]$Force, [string]$ErrorAction)
    $script:Killed += $Id
    $script:ProcKilled = $true
}

function Reset-StopMocks {
    param([int]$ExitsAfterProbes = 0, [bool]$Inject = $true, [bool]$StartsDead = $false)
    $script:Injected = @()
    $script:Killed = @()
    $script:InjectResult = $Inject
    $script:Probes = 0
    $script:ProcKilled = $StartsDead
    $script:ExitsAfterProbes = $ExitsAfterProbes
}

# Exits on its own at the second probe: the graceful path.
Reset-StopMocks -ExitsAfterProbes 2
$r = Stop-BridgeCopilotSession -SessionId 'sess-1' -ProcessId 1234 -GraceSeconds 3
Test-That 'a graceful stop reports success' { $r.Stopped }
Test-That 'it was not forced' { -not $r.Forced }
Test-That 'it typed /exit into the session' { $script:Injected[0].Text -eq '/exit' }
Test-That 'it targeted the right process' { $script:Injected[0].ProcessId -eq 1234 }
Test-That 'nothing was killed' { $script:Killed.Count -eq 0 }

# Never exits on its own: falls through to termination, which then makes it gone.
Reset-StopMocks
$r = Stop-BridgeCopilotSession -SessionId 'sess-2' -ProcessId 2345 -GraceSeconds 1
Test-That 'a stubborn session is terminated' { $r.Stopped -and $r.Forced }
Test-That 'the right pid was terminated' { $script:Killed -contains 2345 }
Test-That 'the detail says it was terminated' { $r.Detail -match 'terminated' }

# Already gone before the stop even starts.
Reset-StopMocks -StartsDead $true
$r = Stop-BridgeCopilotSession -SessionId 'sess-3' -ProcessId 3456
Test-That 'an already-exited session reports success' { $r.Stopped }
Test-That 'and is not injected into' { $script:Injected.Count -eq 0 }
Test-That 'and is not killed' { $script:Killed.Count -eq 0 }

# No pid to work with.
Reset-StopMocks
$r = Stop-BridgeCopilotSession -SessionId 'sess-4' -ProcessId 0
Test-That 'a missing process id fails cleanly' { -not $r.Stopped -and $r.Detail -match 'no process id' }

# Injection fails, so the terminate path still has to run.
Reset-StopMocks -Inject $false
$r = Stop-BridgeCopilotSession -SessionId 'sess-5' -ProcessId 5678 -GraceSeconds 1
Test-That 'a failed /exit still ends the session' { $r.Stopped -and $r.Forced }
Test-That 'and the failure is reported' { $r.Detail -match 'terminated' }

# --- Invoke-PendingStops ---------------------------------------------------------

Write-Host ''
Write-Host '--- press handling ---'

$script:HaStates = @{}
$script:Stopped = @()
$script:Activity = @()

function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if (-not $script:HaStates.ContainsKey($EntityId)) { throw "no such entity $EntityId" }
    [pscustomobject]@{ state = $script:HaStates[$EntityId] }
}
function Stop-BridgeCopilotSession {
    param([string]$SessionId, [int]$ProcessId, [int]$GraceSeconds = 12)
    $script:Stopped += [pscustomobject]@{ SessionId = $SessionId; ProcessId = $ProcessId }
    [pscustomobject]@{ Stopped = $true; Forced = $false; Detail = 'exited cleanly' }
}
function Set-CopilotMqttActivity {
    param([string]$SessionId, [string]$Summary, $Detail, [hashtable]$Headers)
    $script:Activity += $Summary
}

$node = Get-CopilotMqttNodeId -SessionId 'aaaaaaaa-1111-2222-3333-444444444444'

function Reset-PressTest {
    param([string]$Press, [bool]$Live = $true)
    $script:Stopped = @()
    $script:Activity = @()
    $script:DaemonStartedAt = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
    $script:HaStates = @{ "button.${node}_stop" = $Press }
    $state = @{ 'aaaaaaaa-1111-2222-3333-444444444444' = [pscustomobject]@{ Name = 'S'; Offset = 0 } }
    $liveSet = @{}
    if ($Live) {
        $liveSet['aaaaaaaa-1111-2222-3333-444444444444'] = [pscustomobject]@{ SessionId = 'aaaaaaaa-1111-2222-3333-444444444444'; ProcessId = 999 }
    }
    @{ State = $state; Live = $liveSet }
}

$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00'
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a fresh press ends the session' { $script:Stopped.Count -eq 1 }
Test-That 'it passes the live process id' { $script:Stopped[0].ProcessId -eq 999 }
Test-That 'it shows progress on the card' { ($script:Activity -join ' ') -match 'Ending' }

# Same press again must not act twice.
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'the same press does not end it twice' { $script:Stopped.Count -eq 1 }

$ctx = Reset-PressTest -Press '2025-01-01T00:00:00+00:00'
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a press from before the daemon started is ignored' { $script:Stopped.Count -eq 0 }

$ctx = Reset-PressTest -Press 'unknown'
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'an unknown button state is ignored' { $script:Stopped.Count -eq 0 }

$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00' -Live $false
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a session that is not live is never stopped' { $script:Stopped.Count -eq 0 }

# A session published before the stop button existed has no such entity yet.
$ctx = Reset-PressTest -Press '2026-06-01T12:00:00+00:00'
$script:HaStates = @{}
Invoke-PendingStops -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a missing stop button is survived' { $script:Stopped.Count -eq 0 }

# --- discovery payloads ----------------------------------------------------------

Write-Host ''
Write-Host '--- the stop button is published and cleaned up ---'

$script:MqttMsgs = @()
function Publish-CopilotMqttMessage {
    param([string]$Topic, [AllowEmptyString()][string]$Payload, [hashtable]$Headers, [switch]$Retain)
    $script:MqttMsgs += [pscustomobject]@{ Topic = $Topic; Payload = $Payload }
}

$script:MqttMsgs = @()
[void](Publish-CopilotMqttSession -SessionId 'aaaaaaaa-1111-2222-3333-444444444444' -SessionName 'S' -Machine 'M' -Headers $headers)
$stopCfg = ($script:MqttMsgs | Where-Object { $_.Topic -match "/button/$node/stop/config$" } | Select-Object -First 1)
Test-That 'a stop button is published for the session' { $null -ne $stopCfg }
Test-That 'it has a node-scoped unique id' { $stopCfg.Payload -match "`"unique_id`":`"${node}_stop`"" }
Test-That 'it is named End session' { $stopCfg.Payload -match '"name":"End session"' }
Test-That 'it carries the session availability topic' { $stopCfg.Payload -match '"availability"' }

$script:MqttMsgs = @()
Remove-CopilotMqttSession -SessionId 'aaaaaaaa-1111-2222-3333-444444444444' -Headers $headers
$cleared = ($script:MqttMsgs | Where-Object { $_.Topic -match "/button/$node/stop/config$" } | Select-Object -First 1)
Test-That 'retiring a session clears the stop button too' { $null -ne $cleared -and $cleared.Payload -eq '' }

Write-Host ''
Write-Host '--- reporting what Send did must not empty the card ---'
# Set-CopilotMqttActivity replaces the whole attribute set, and the card header renders
# the last response and the reasoning out of those attributes. Publishing a bare
# "Sending..." therefore blanked both until the next transcript update happened to
# restore them - visible as the card emptying and refilling on every Send.
$script:PublishedSummary = ''
$script:PublishedDetail = $null
$script:CurrentAttributes = [pscustomobject]@{
    response      = 'the last thing the agent said'
    reasoning     = 'its chain of thought'
    history       = 'earlier activity'
    friendly_name = 'Activity'
    icon          = 'mdi:robot'
    hint          = 'stale hint from a previous action'
}

function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    [pscustomobject]@{ state = 'Idle'; attributes = $script:CurrentAttributes }
}
function Set-CopilotMqttActivity {
    param([string]$SessionId, [string]$Summary, $Detail, [hashtable]$Headers)
    $script:PublishedSummary = $Summary
    $script:PublishedDetail = $Detail
}

Set-DaemonTransientActivity -SessionId 'dddddddd-1111-2222-3333-444444444444' `
    -Summary 'Sending...' -Headers $headers

Test-That 'the status itself is published' { $script:PublishedSummary -eq 'Sending...' }
Test-That 'the last response survives' {
    $script:PublishedDetail['response'] -eq 'the last thing the agent said'
}
Test-That 'and so does the reasoning the card renders' {
    $script:PublishedDetail['reasoning'] -eq 'its chain of thought' -and
    $script:PublishedDetail['history'] -eq 'earlier activity'
}
Test-That 'stale detail from a previous action is dropped' {
    -not $script:PublishedDetail.ContainsKey('hint')
}
Test-That "Home Assistant's own attributes are not echoed back" {
    -not $script:PublishedDetail.ContainsKey('friendly_name') -and
    -not $script:PublishedDetail.ContainsKey('icon')
}

Set-DaemonTransientActivity -SessionId 'dddddddd-1111-2222-3333-444444444444' `
    -Summary 'Reply sent' -Extra @{ sent = 'hello' } -Headers $headers
Test-That 'new detail is carried alongside what was preserved' {
    $script:PublishedDetail['sent'] -eq 'hello' -and
    $script:PublishedDetail['response'] -eq 'the last thing the agent said'
}

Write-Host ''
Write-Host '--- a mis-delivered answer is corrected, not just logged ---'
# A warning on the card is not enough: the agent carries straight on from the wrong
# answer, and the next activity update overwrites the warning within seconds.
$correctionFields = @(
    [pscustomobject]@{ Label = 'Glow';  Options = @('Amber', 'Blue', 'No glow'); IsText = $false }
    [pscustomobject]@{ Label = 'Notes'; Options = @();                           IsText = $true }
)

$msg = Get-DaemonAnswerCorrection -Fields $correctionFields -Selections @('No glow', '')
Test-That 'it says the recorded answer is wrong' { $msg -match 'WRONG' -and $msg -match 'Disregard' }
Test-That 'it names the field and the value actually chosen' { $msg -match 'Glow : No glow' }
Test-That 'and marks an empty field as blank rather than dropping it' { $msg -match 'Notes : \(left blank\)' }
Test-That 'it survives having no fields at all' {
    $null -ne (Get-DaemonAnswerCorrection -Fields @() -Selections @())
}

Write-Host ''
Write-Host '--- a follow-up typed while a reply is delivering must survive ---'
# The failure this catches: delivery is not instant - a long reply is typed into the
# console a character at a time - and the box was cleared unconditionally afterwards.
# A follow-up typed in that window was wiped, and the next Send reported "Nothing to
# send". Seen live: ok:460 delivered, then an empty box 11 seconds later.
$script:ClearCalls = @()
$script:BoxValue = ''
$script:Activity = @()

function Get-LiveClaudeSessions { @{} }
function Get-LiveCodexSessions { @{} }
function Set-DaemonTransientActivity {
    param([string]$SessionId, [string]$Summary, $Extra, [hashtable]$Headers)
    $script:Activity += $Summary
}
function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    [pscustomobject]@{ state = $script:BoxValue; attributes = [pscustomobject]@{ question = '' } }
}
function Invoke-HomeAssistantService {
    param([string]$Domain, [string]$Service, [hashtable]$Headers, [hashtable]$Data)
    $script:ClearCalls += [pscustomobject]@{ EntityId = $Data.entity_id; Value = $Data.value }
}

$replySession = 'cccccccc-1111-2222-3333-444444444444'

$script:InjectResult = $true
$script:BoxValue = 'the message that was just sent'
$script:ClearCalls = @()
[void](Invoke-DaemonReply -SessionId $replySession -Text 'the message that was just sent' -Headers $headers)
Test-That 'the box is cleared when it still holds what was sent' {
    $script:ClearCalls.Count -eq 1 -and $script:ClearCalls[0].Value -eq $script:DaemonConfig.ReplyBlankValue
}

$script:BoxValue = 'a follow-up typed while the first was delivering'
$script:ClearCalls = @()
[void](Invoke-DaemonReply -SessionId $replySession -Text 'the message that was just sent' -Headers $headers)
Test-That 'but a follow-up typed in the meantime is left alone' { $script:ClearCalls.Count -eq 0 }

$script:BoxValue = 'the message that was just sent'
$script:ClearCalls = @()
$script:InjectResult = $false
[void](Invoke-DaemonReply -SessionId $replySession -Text 'the message that was just sent' -Headers $headers)
Test-That 'a failed delivery still clears, so it is not silently resent' {
    $script:ClearCalls.Count -eq 1
}
$script:InjectResult = $true

Write-Host ''
Write-Host '--- Send always says something ---'
# A press that produces no visible change reads as a dead button, which is why it
# was getting pressed twice. Every press now ends in a visible outcome.
$script:Activity = @()
$script:Replies = @()
$script:HaStates = @{}

function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if (-not $script:HaStates.ContainsKey($EntityId)) { throw "no such entity $EntityId" }
    [pscustomobject]@{ state = $script:HaStates[$EntityId]; attributes = [pscustomobject]@{ question = '' } }
}
function Set-CopilotMqttActivity {
    param([string]$SessionId, [string]$Summary, $Detail, [hashtable]$Headers)
    $script:Activity += $Summary
}
function Invoke-DaemonReply {
    param([string]$SessionId, [string]$Text, [hashtable]$Headers)
    $script:Replies += $Text
}
function Get-CopilotDecisionMarker { param([string]$SessionId) $null }

$replyNode = Get-CopilotMqttNodeId -SessionId 'bbbbbbbb-1111-2222-3333-444444444444'
function Reset-SendTest {
    param([string]$Press, [string]$Reply)
    $script:Activity = @()
    $script:Replies = @()
    $script:HaStates = @{
        "button.${replyNode}_submit"   = $Press
        "text.${replyNode}_reply"      = $Reply
        "select.${replyNode}_decision" = 'Idle'
    }
    $state = @{ 'bbbbbbbb-1111-2222-3333-444444444444' = [pscustomobject]@{ Name = 'S'; Offset = 0 } }
    $live = @{ 'bbbbbbbb-1111-2222-3333-444444444444' = [pscustomobject]@{ SessionId = 'bbbbbbbb-1111-2222-3333-444444444444'; ProcessId = 5 } }
    @{ State = $state; Live = $live }
}

$ctx = Reset-SendTest -Press '2026-06-01T12:00:00+00:00' -Reply 'hello there'
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a press with text sends it' { $script:Replies -contains 'hello there' }
Test-That 'and acknowledges the press immediately' { $script:Activity -contains 'Sending...' }

Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'the same press does not send twice' { $script:Replies.Count -eq 1 }

$ctx = Reset-SendTest -Press '2026-06-01T12:05:00+00:00' -Reply ' '
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a press with an empty box sends nothing' { $script:Replies.Count -eq 0 }
Test-That 'but still reports why, rather than looking dead' {
    $script:Activity -contains 'Nothing to send'
}

$ctx = Reset-SendTest -Press 'unknown' -Reply 'text'
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'an unpressed button sends nothing and says nothing' {
    $script:Replies.Count -eq 0 -and $script:Activity.Count -eq 0
}

Remove-Item -LiteralPath $testLogFile -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '--- a value committed just after the press is still sent ---'
# Home Assistant commits a text entity when it loses focus, and the tap that commits
# it IS the tap on Send. The daemon is woken by the button's own state change, so it
# reads the box before the typed value lands - and a single short re-read meant the
# first Send of a message reported "Nothing to send" and needed pressing twice.
$script:ReadCount = 0
$script:LateValue = 'typed just before pressing Send'
$script:BlankReads = 3

function Get-HomeAssistantState {
    param([string]$EntityId, [hashtable]$Headers)
    if ($EntityId -match '_reply$') {
        $script:ReadCount++
        $v = if ($script:ReadCount -le $script:BlankReads) { ' ' } else { $script:LateValue }
        return [pscustomobject]@{ state = $v; attributes = [pscustomobject]@{ question = '' } }
    }
    if (-not $script:HaStates.ContainsKey($EntityId)) { throw "no such entity $EntityId" }
    [pscustomobject]@{ state = $script:HaStates[$EntityId]; attributes = [pscustomobject]@{ question = '' } }
}

# Keep the test fast; the ratio of attempts to blank reads is what matters.
$script:DaemonConfig.ReplyCommitWaitMs = 1

$ctx = Reset-SendTest -Press '2026-06-01T13:00:00+00:00' -Reply ' '
$script:ReadCount = 0
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a late commit is picked up rather than reported as empty' {
    $script:Replies -contains $script:LateValue
}
Test-That 'and it is not reported as nothing to send' {
    $script:Activity -notcontains 'Nothing to send'
}

# A box that never fills must still give up and say so, rather than polling forever.
$script:BlankReads = 999
$ctx = Reset-SendTest -Press '2026-06-01T13:05:00+00:00' -Reply ' '
$script:ReadCount = 0
Invoke-PendingReplies -Headers $headers -State $ctx.State -Live $ctx.Live
Test-That 'a genuinely empty box still reports nothing to send' {
    $script:Activity -contains 'Nothing to send'
}
Test-That 'and it stops after the configured number of attempts' {
    $script:ReadCount -le ($script:DaemonConfig.ReplyCommitAttempts + 1)
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
