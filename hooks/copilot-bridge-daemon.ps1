<#
    Copilot CLI bridge daemon.

    One long-running process that owns every always-on concern of the Home Assistant
    bridge, so the CLI hooks no longer have to:

      - Reconciles live sessions. Each live session gets its own set of Home
        Assistant entities published through MQTT discovery, and they are torn down
        when the session exits.
      - Streams live activity from each session transcript, at a verbosity the user
        controls from Home Assistant.
      - Delivers a reply typed on the dashboard straight into the running CLI by
        writing to its console input buffer.

    Why a daemon at all: the old design did this work inside blocking hooks. Blocking
    the agentStop hook to carry a reply back made the CLI queue anything typed in the
    terminal, which deadlocked against the very signal the hook was waiting for. The
    workaround - only arm the reply box on turns longer than three minutes - disabled
    the feature almost entirely (21 of 22 turns skipped in the bridge log). Delivering
    by console injection from an outside process means no turn ever has to be held
    open, so the reply box can be offered on every finished turn.

    The daemon is deliberately not required for `ask_user`. That path must be
    synchronous, so the hook still blocks - but it now waits on a WebSocket push
    rather than polling, and the daemon is not in its critical path.
#>

[CmdletBinding()]
param(
    [int]$ReconcileSeconds = 15,
    [switch]$RunOnce
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot 'decision-mqtt.ps1')
. (Join-Path $PSScriptRoot 'decision-ha-websocket.ps1')
. (Join-Path $PSScriptRoot 'decision-inject.ps1')
. (Join-Path $PSScriptRoot 'bridge-update.ps1')

$script:DaemonConfig = @{
    MutexName = 'Local\CopilotBridgeDaemon'
    VerboseToggle = 'input_boolean.copilot_cli_live_verbose'
    LogFile = (Join-Path $env:TEMP 'copilot-bridge-daemon.log')
    StateFile = (Join-Path $env:TEMP 'copilot-bridge-daemon-state.json')
    # Cap how much transcript is read in one pass, so a session that produced a huge
    # burst cannot stall the loop.
    MaxTailBytes = 512000
    ActivityHistory = 12
    ResponseMaxChars = 6000
    ReasoningMaxChars = 4000
    # Home Assistant renders a text entity holding "" as the literal "(empty value)".
    # A single space renders as a genuinely blank field instead, so the reply box looks
    # ready to type in. Everything that reads the box treats whitespace as empty.
    ReplyBlankValue = ' '
}

# Session-set signature of the last dashboard rebuild, so the dashboard is only
# regenerated when a session appears or exits, not on every reconcile.
$script:DaemonDashboardSignature = $null

# Update-check state. Initialised here rather than left undefined because the daemon
# runs under StrictMode, where reading an unset variable throws.
$script:DaemonUpdateAvailable = $false
$script:DaemonUpdatePublished = $false
$script:DaemonUpdateLastPress = ''
# Anything the dashboard reports as happening before this is a leftover from a
# previous run rather than something the user just did.
$script:DaemonStartedAt = [DateTimeOffset]::Now

function Write-DaemonLog {
    param([Parameter(Mandatory)][string]$Message)

    $line = "$([DateTimeOffset]::Now.ToString('o')) $Message"
    try {
        Add-Content -LiteralPath $script:DaemonConfig.LogFile -Value $line
    }
    catch {
        # Logging must never take the daemon down.
    }
}

function Format-CardText {
    <#
        Truncates card text to a readable preview so a long response or reasoning block
        cannot make one card tower over the others and unbalance the dashboard grid.
        The full text is always available in the terminal.
    #>
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][int]$MaxChars
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $trimmed = $Text.Trim()
    if ($trimmed.Length -le $MaxChars) { return $trimmed }
    $trimmed.Substring(0, $MaxChars).TrimEnd() + '…'
}

function Get-LiveCopilotSessions {
    <#
        Live sessions, keyed by session id, resolved from the `inuse.<pid>.lock` files
        that the CLI maintains. A lock whose process is gone is stale and skipped.

        Built to stay cheap even with hundreds of historical session directories on
        disk (this machine has ~480). The live Copilot pids are fetched once up front,
        directory and lock enumeration go through the .NET APIs rather than the
        PowerShell provider, and no per-lock Get-Process call is made. An earlier
        version cost about 1.9 seconds per call and, run every few seconds, pinned a
        third of a CPU core on its own.
    #>
    $root = $script:DecisionBridgeConfig.SessionStateRoot
    if (-not [IO.Directory]::Exists($root)) { return @{} }

    # One process snapshot; membership is then a hash lookup per lock.
    $livePids = @{}
    foreach ($process in @(Get-Process -Name 'copilot' -ErrorAction SilentlyContinue)) {
        $livePids[$process.Id] = $true
    }
    if ($livePids.Count -eq 0) { return @{} }

    $candidates = @()
    foreach ($dir in [IO.Directory]::EnumerateDirectories($root)) {
        $processId = $null
        foreach ($lock in [IO.Directory]::EnumerateFiles($dir, 'inuse.*.lock')) {
            $name = [IO.Path]::GetFileName($lock)
            if ($name -notmatch '^inuse\.(\d+)\.lock$') { continue }
            $candidatePid = [int]$Matches[1]
            if ($livePids.ContainsKey($candidatePid)) { $processId = $candidatePid; break }
        }
        if ($null -eq $processId) { continue }

        $transcript = [IO.Path]::Combine($dir, 'events.jsonl')

        # A session that has not taken its first turn has no transcript yet. It is
        # still a real, live session, so it is included rather than skipped: the card
        # shows it as idle and, more usefully, its reply box can start the
        # conversation from Home Assistant. Streaming begins on its own once the
        # transcript appears.
        $hasTranscript = [IO.File]::Exists($transcript)

        $candidates += [pscustomobject]@{
            SessionId = [IO.Path]::GetFileName($dir)
            ProcessId = $processId
            Transcript = $transcript
            HasTranscript = $hasTranscript
            # A missing file reports a 1601 sentinel, which naturally loses the
            # per-pid tie-break below to any session that has actually written one.
            LastWrite = if ($hasTranscript) { [IO.File]::GetLastWriteTimeUtc($transcript) } else { [DateTime]::MinValue }
            Kind = 'copilot'
        }
    }

    # One CLI process owns exactly one live session. A process that resumed a
    # different session leaves the old `inuse.<pid>.lock` behind, so the same pid can
    # appear under several session directories. Publishing all of them would create
    # phantom sessions in Home Assistant and, worse, deliver a reply meant for one
    # session into whichever session shares the pid. Keep only the most recently
    # written transcript for each pid.
    $live = @{}
    foreach ($group in ($candidates | Group-Object -Property ProcessId)) {
        $winner = $group.Group | Sort-Object LastWrite -Descending | Select-Object -First 1
        $live[$winner.SessionId] = $winner
    }

    $live
}

# ---------------------------------------------------------------- front ends
# Sessions carry a Kind so the daemon can serve more than one CLI. Everything
# Copilot-specific stays on the 'copilot' path unchanged; 'claude' sessions are
# discovered, streamed and answered through the helpers below. The Claude adapter is
# optional - when it is not installed, these degrade to returning nothing.

$script:ClaudeAdapterLoaded = $false
$claudeHooks = Join-Path $HOME '.claude\ha-bridge'
if (Test-Path -LiteralPath (Join-Path $claudeHooks 'claude-session.ps1')) {
    try {
        . (Join-Path $claudeHooks 'claude-session.ps1')
        . (Join-Path $claudeHooks 'claude-transcript.ps1')
        $script:ClaudeAdapterLoaded = $true
    }
    catch {
        $script:ClaudeAdapterLoaded = $false
    }
}

function Get-LiveClaudeSessions {
    <#
        Live Claude Code sessions, from the registrations its hooks write.

        Claude has no inuse.<pid>.lock, so liveness is the recorded pid still being a
        running claude process - established in Get-ClaudeSessionRegistrations.
    #>
    if (-not $script:ClaudeAdapterLoaded) { return @{} }

    $live = @{}
    foreach ($registration in @(Get-ClaudeSessionRegistrations)) {
        if (-not $registration.IsLive) { continue }
        $transcript = $registration.TranscriptPath
        if (-not $transcript -or -not (Test-Path -LiteralPath $transcript)) { continue }

        $live[$registration.SessionId] = [pscustomobject]@{
            SessionId        = $registration.SessionId
            ProcessId        = $registration.ProcessId
            Transcript       = $transcript
            WorkingDirectory = $registration.WorkingDirectory
            LastWrite        = [IO.File]::GetLastWriteTimeUtc($transcript)
            Kind             = 'claude'
        }
    }
    $live
}

function Get-LiveBridgeSessions {
    <# Every live session across the front ends the bridge supports. #>
    $live = Get-LiveCopilotSessions
    foreach ($entry in (Get-LiveClaudeSessions).GetEnumerator()) {
        $live[$entry.Key] = $entry.Value
    }
    $live
}

function Get-BridgeSessionDisplay {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Kind = 'copilot',
        [string]$WorkingDirectory = 'Unknown folder'
    )

    if ($Kind -eq 'claude' -and $script:ClaudeAdapterLoaded) {
        return Get-ClaudeSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory
    }
    Get-CopilotSessionDisplay -SessionId $SessionId -WorkingDirectory $WorkingDirectory
}

function Read-BridgeTranscriptAppend {
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$Offset = 0,
        [string]$Kind = 'copilot'
    )

    if ($Kind -eq 'claude' -and $script:ClaudeAdapterLoaded) {
        return Read-ClaudeTranscriptAppend -Path $Path -Offset $Offset `
            -MaxTailBytes $script:DaemonConfig.MaxTailBytes
    }
    Read-TranscriptAppend -Path $Path -Offset $Offset
}

function Get-BridgeActivity {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][bool]$VerboseMode,
        [string]$Kind = 'copilot'
    )

    if ($Kind -eq 'claude' -and $script:ClaudeAdapterLoaded) {
        return Get-ClaudeActivityFromTranscript -Lines $Lines -VerboseMode $VerboseMode
    }
    Get-ActivityFromEvents -Lines $Lines -VerboseMode $VerboseMode
}

function Test-BridgeSessionWorking {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$Kind = 'copilot',
        [string]$Transcript
    )

    if ($Kind -ne 'claude') { return Test-CopilotSessionWorking -SessionId $SessionId }
    if (-not $script:ClaudeAdapterLoaded -or -not $Transcript) { return $false }

    # Claude writes no turn-end entry, so freshness is the best available signal at
    # adoption time; the Stop hook corrects it authoritatively at the next turn end.
    try {
        return ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($Transcript)).TotalSeconds -lt 20
    }
    catch { return $false }
}

function Read-DaemonState {
    if (-not (Test-Path -LiteralPath $script:DaemonConfig.StateFile)) {
        return @{}
    }
    try {
        $raw = Get-Content -LiteralPath $script:DaemonConfig.StateFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $parsed = $raw | ConvertFrom-Json
        $state = @{}
        foreach ($property in $parsed.PSObject.Properties) {
            $state[$property.Name] = $property.Value
        }
        return $state
    }
    catch {
        return @{}
    }
}

function Write-DaemonState {
    param([Parameter(Mandatory)][hashtable]$State)

    try {
        $json = $State | ConvertTo-Json -Depth 8 -Compress
        Set-Content -LiteralPath $script:DaemonConfig.StateFile -Value $json -Encoding UTF8
    }
    catch {
        Write-DaemonLog -Message "state save failed: $($_.Exception.Message)"
    }
}

function Test-VerboseStreaming {
    param([Parameter(Mandatory)][hashtable]$Headers)

    try {
        $state = Get-HomeAssistantState -EntityId $script:DaemonConfig.VerboseToggle -Headers $Headers
        return ([string]$state.state -eq 'on')
    }
    catch {
        # Default to quiet if the toggle cannot be read, rather than flooding.
        return $false
    }
}

function Read-TranscriptAppend {
    <#
        Returns transcript lines appended since $Offset, plus the new offset.

        Shared read/write access is required because the CLI keeps the transcript
        open while it writes.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$Offset
    )

    $result = [pscustomobject]@{ Lines = @(); Offset = $Offset }

    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite
        )
        $length = $stream.Length

        # A shorter file means the session was reset; start over from the end.
        if ($length -lt $Offset) {
            $result.Offset = $length
            return $result
        }
        if ($length -eq $Offset) { return $result }

        $start = $Offset
        if (($length - $start) -gt $script:DaemonConfig.MaxTailBytes) {
            $start = $length - $script:DaemonConfig.MaxTailBytes
        }

        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false))
        $text = $reader.ReadToEnd()

        $result.Offset = $length
        $result.Lines = @(
            ($text -split "`n") | Where-Object { $_.Trim().StartsWith('{') }
        )
    }
    catch {
        return $result
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $result
}

function Get-ActivityFromEvents {
    <#
        Reduces a batch of transcript events to the current activity.

        Returns the last meaningful event plus a short rolling history, so the Home
        Assistant card shows what the session is doing now and what it just did.
        Reasoning text is only collected when verbose streaming is on.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)][bool]$VerboseMode
    )

    $summary = $null
    $reasoning = $null
    $response = $null
    $status = $null
    $history = New-Object System.Collections.Generic.List[string]

    foreach ($line in $Lines) {
        if ($line -notmatch '"type":"([^"]+)"') { continue }
        $type = $Matches[1]

        switch ($type) {
            'assistant.turn_start' { $status = 'working'; continue }
            'user.message' { $status = 'working'; $summary = 'Reading your message'; $history.Add($summary); continue }
            'assistant.turn_end' { $status = 'idle'; continue }
        }

        if ($type -eq 'tool.execution_start') {
            try {
                $parsed = $line | ConvertFrom-Json
                $tool = [string]$parsed.data.toolName
                if (-not [string]::IsNullOrWhiteSpace($tool)) {
                    $summary = "Running: $tool"
                    $history.Add($summary)
                }
            }
            catch { }
            continue
        }

        if ($type -eq 'assistant.message') {
            try {
                $parsed = $line | ConvertFrom-Json
                $content = [string]$parsed.data.content
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    # The short summary is the first line, for the sensor state (capped
                    # at 255 chars); the full content is kept separately so the card can
                    # render the whole response, not just its opening line.
                    $first = (($content -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
                    if ($first) {
                        $summary = $first.Trim()
                        $history.Add($summary)
                    }
                    $response = $content.Trim()
                }
                # Reasoning is captured unconditionally, regardless of the verbose
                # toggle. Capture and display are deliberately decoupled: the daemon
                # always keeps the latest reasoning in state, and only publishes it to
                # the card when verbose is on. That lets a verbose toggle show or hide
                # the existing reasoning instantly, without waiting for the session to
                # think again.
                $text = [string]$parsed.data.reasoningText
                if (-not [string]::IsNullOrWhiteSpace($text)) { $reasoning = $text.Trim() }
            }
            catch { }
            continue
        }
    }

    [pscustomobject]@{
        Summary = $summary
        Reasoning = $reasoning
        Response = $response
        Status = $status
        History = @($history)
    }
}

function Invoke-PendingReplies {
    <#
        Delivers any reply box that currently holds text.

        The WebSocket watch only sees a reply if the state change fires during its
        active window, so a reply that lands in the gap between windows would be lost.
        Reading the retained value on every reconcile closes that race: the box keeps
        its value until the daemon clears it, so it is always seen within one
        reconcile interval regardless of timing. The push path stays as a latency
        optimization on top of this.

        A per-session hash guards the brief window between delivering a reply and the
        clear taking effect, so the same text is never injected twice.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    foreach ($sessionId in @($State.Keys)) {
        if (-not $Live.ContainsKey($sessionId)) { continue }

        # A session with a pending-decision marker is answering an ask_user, not
        # continuing a finished turn. Its reply box is owned by Invoke-PendingDecisions,
        # which injects the answer into the live native prompt. Skip it here so the two
        # paths never both inject the same text.
        if ($null -ne (Get-CopilotDecisionMarker -SessionId $sessionId)) { continue }

        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        $replyEntity = "text.${node}_reply"

        # Back-compat safety net for sessions still running the old blocking router.
        # That router never writes a marker, so the marker check above does not protect
        # it: the daemon would inject the reply the blocked hook is itself waiting for,
        # which enqueues the text in the terminal and deadlocks the session. If the
        # decision card holds a question but there is no marker, the session is on the
        # old router — leave its reply box alone and let the hook consume it.
        try {
            $decisionState = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
            if (-not [string]::IsNullOrWhiteSpace([string]$decisionState.attributes.question)) {
                continue
            }
        }
        catch {
            # Unreadable decision state: treat the reply as a continuation, the common case.
        }

        try {
            $replyState = Get-HomeAssistantState -EntityId $replyEntity -Headers $Headers
        }
        catch {
            continue
        }

        $value = [string]$replyState.state
        if ([string]::IsNullOrWhiteSpace($value) -or $value -in @('unknown', 'unavailable')) {
            continue
        }

        $entry = $State[$sessionId]

        # A reply is only sent when Send is pressed. Home Assistant commits a text
        # entity as soon as the field loses focus, so acting on the value alone fired
        # the moment you clicked away - easy to trigger by accident and impossible to
        # correct. The button's state is the timestamp of its last press; a press only
        # counts once, tracked per session, so the same press cannot also fire a
        # later reply.
        $press = ''
        try {
            $btn = Get-HomeAssistantState -EntityId "button.${node}_submit" -Headers $Headers
            $press = [string]$btn.state
        }
        catch {
            continue
        }
        if ($press -in @('unknown', 'unavailable', '')) { continue }

        $lastSubmit = if ($entry.PSObject.Properties['LastSubmitAt']) { [string]$entry.LastSubmitAt } else { '' }
        if ($press -eq $lastSubmit) { continue }

        if ($entry.PSObject.Properties['LastSubmitAt']) { $entry.LastSubmitAt = $press }
        else { $entry | Add-Member -NotePropertyName LastSubmitAt -NotePropertyValue $press -Force }

        $lastReply = if ($entry.PSObject.Properties['LastReply']) { [string]$entry.LastReply } else { '' }
        if ($value -eq $lastReply) { continue }

        if ($entry.PSObject.Properties['LastReply']) {
            $entry.LastReply = $value
        }
        else {
            $entry | Add-Member -NotePropertyName LastReply -NotePropertyValue $value -Force
        }

        [void](Invoke-DaemonReply -SessionId $sessionId -Text $value -Headers $Headers)
    }
}

function Repair-CopilotSessionEntities {
    <#
        Restores the optimistic entities after a Home Assistant restart.

        The decision selector, the per-field dropdowns and the reply box are optimistic
        MQTT entities: they deliberately have no state topic, so their value sticks the
        moment it is set rather than waiting for a device to echo it back. The cost is
        that Home Assistant has nothing to restore them from on restart, and they all
        come back as `unknown` - the reply boxes show "unknown" instead of being blank,
        and an armed question loses its placeholder.

        The retained discovery configs survive, so the entities themselves reappear;
        only their state needs re-driving. The reply box is used as the sentinel (one
        cheap read per session per reconcile); when it is unknown the session's
        optimistic entities are re-primed, re-arming a live question from its marker so
        a decision that was waiting when Home Assistant went down is still answerable.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    foreach ($sessionId in @($State.Keys)) {
        if (-not $Live.ContainsKey($sessionId)) { continue }
        $node = Get-CopilotMqttNodeId -SessionId $sessionId

        $needsRepair = $false
        try {
            # Check both optimistic entities: a session whose reply box happens to hold
            # a value can still have an unknown decision selector, so keying off the
            # reply box alone would leave that session unrepaired.
            $reply = Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers
            if ([string]$reply.state -in @('unknown', 'unavailable')) { $needsRepair = $true }
            if (-not $needsRepair) {
                $dec = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
                if ([string]$dec.state -in @('unknown', 'unavailable')) { $needsRepair = $true }
            }
        }
        catch {
            continue
        }
        if (-not $needsRepair) { continue }

        $entry = $State[$sessionId]
        $name = [string]$entry.Name
        $machine = [string]$entry.Machine
        $marker = Get-CopilotDecisionMarker -SessionId $sessionId

        try {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }

            if ($null -ne $marker) {
                # A question was live when Home Assistant went away - put it back.
                Set-CopilotMqttDecision -SessionId $sessionId -SessionName $name -Machine $machine `
                    -Question ([string]$marker.question) -Choices @($marker.choices) `
                    -Fields @($marker.fields) -DecisionId ([string]$marker.decisionId) -Headers $Headers | Out-Null
                Write-DaemonLog -Message "re-armed live decision for $($sessionId.Substring(0,8)) after Home Assistant restart"
            }
            else {
                Clear-CopilotMqttDecision -SessionId $sessionId -SessionName $name `
                    -Machine $machine -Headers $Headers
                Write-DaemonLog -Message "re-primed optimistic entities for $($sessionId.Substring(0,8)) after Home Assistant restart"
            }
        }
        catch {
            Write-DaemonLog -Message "entity repair failed for $sessionId : $($_.Exception.Message)"
        }
    }
}

function Invoke-PendingDecisions {
    <#
        Feeds Home Assistant answers into a live ask_user prompt, and clears the card
        when the ask_user is answered by either input.

        This is the Home-Assistant half of dual-input ask_user. The non-blocking hook
        arms the card and writes a marker; the native terminal prompt is answerable the
        whole time. For each session with a marker:

          - If the transcript shows the ask_user already completed (answered in the
            terminal, or by a previous injection), clear the card, blank the reply box
            and delete the marker.

          - If the ask_user is still pending and Home Assistant holds an answer that has
            not been injected yet, inject it into the native prompt. A freeform answer
            (reply box) is typed in as text; a choice (selector) is handled by the
            choice-injection strategy. Pending-ness is re-checked immediately before
            injecting so a terminal answer that just landed is never double-answered.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    foreach ($sessionId in @($State.Keys)) {
        if (-not $Live.ContainsKey($sessionId)) { continue }
        $marker = Get-CopilotDecisionMarker -SessionId $sessionId
        if ($null -eq $marker) { continue }

        $session = $Live[$sessionId]
        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        $askState = Get-CopilotAskUserState -TranscriptPath $session.Transcript

        # The hook writes the marker just before the tool runs, so the start event may
        # not be in the transcript yet. Wait a cycle rather than acting on a stale one.
        if (-not $askState.Started) { continue }

        if (-not $askState.Pending) {
            # Answered by whichever input got there first. Tear the card down.
            try {
                Clear-CopilotMqttDecision -SessionId $sessionId `
                    -SessionName ([string]$State[$sessionId].Name) `
                    -Machine ([string]$State[$sessionId].Machine) -Headers $Headers
                Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                    -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }
            }
            catch {
                Write-DaemonLog -Message "decision clear failed for $sessionId : $($_.Exception.Message)"
            }
            Remove-CopilotDecisionMarker -SessionId $sessionId
            $entry = $State[$sessionId]
            if ($entry.PSObject.Properties['LastReply']) { $entry.LastReply = '' }
            Write-DaemonLog -Message "decision answered (either input); cleared card for $($sessionId.Substring(0,8))"
            continue
        }

        # Pending: is there a Home Assistant answer to inject?
        $answer = ''
        $selections = @()
        $isChoice = ([string]$marker.mode -eq 'multiple_choice')
        $markerFields = @($marker.fields)
        $isMultiField = $markerFields.Count -gt 1

        # A hook whose Home Assistant work was cut short by its deadline leaves a
        # marker with no card behind it. Arm it here so an outage during the hook does
        # not silently cost the question its dashboard card.
        try {
            $armed = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
            $armedOptions = @($armed.attributes.options)
            if ($armedOptions.Count -le 1) {
                Set-CopilotMqttDecision -SessionId $sessionId `
                    -SessionName ([string]$State[$sessionId].Name) `
                    -Machine ([string]$State[$sessionId].Machine) `
                    -Question ([string]$marker.question) `
                    -Choices @($marker.choices) -Fields $markerFields `
                    -DecisionId ([string]$marker.decisionId) -Headers $Headers | Out-Null
                Write-DaemonLog -Message "armed card from marker for $($sessionId.Substring(0,8)) (hook could not reach Home Assistant)"
            }
        }
        catch {
            Write-DaemonLog -Message "marker re-arm check failed for $sessionId : $($_.Exception.Message)"
        }

        try {
            if ($isMultiField) {
                # One dropdown per field. Cancel still rides on the main selector, and
                # the answer is only complete once every field has been chosen - a
                # half-filled form must not be injected.
                $sel = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
                if ([string]$sel.state -eq 'Cancel request') {
                    $answer = 'Cancel request'
                }
                else {
                    $picked = @()
                    for ($fi = 1; $fi -le $markerFields.Count; $fi++) {
                        $fs = Get-HomeAssistantState `
                            -EntityId (Get-CopilotMqttFieldEntityId -Node $node -Index $fi) -Headers $Headers
                        $v = [string]$fs.state
                        if ($v -in @('Choose...', 'Idle', 'unknown', 'unavailable', '')) { $picked = @(); break }
                        $picked += $v
                    }

                    # Every field chosen is not enough: a multi-field answer is only
                    # sent when Submit is pressed, so selections can be reviewed and
                    # changed first. An MQTT button's state is the timestamp of its
                    # last press, so a press counts only if it is newer than the moment
                    # this question was armed - otherwise a press left over from a
                    # previous question would fire this one instantly.
                    if ($picked.Count -eq $markerFields.Count) {
                        $submitted = $false
                        try {
                            $btn = Get-HomeAssistantState -EntityId "button.${node}_submit" -Headers $Headers
                            $pressedAt = [string]$btn.state
                            if ($pressedAt -notin @('unknown', 'unavailable', '')) {
                                $armedAt = [datetimeoffset][string]$marker.armedAt
                                $submitted = ([datetimeoffset]$pressedAt) -gt $armedAt
                                if ($submitted) {
                                    # Consume the press so the same one cannot also be
                                    # read as a Send for the reply box afterwards.
                                    $entry = $State[$sessionId]
                                    if ($entry.PSObject.Properties['LastSubmitAt']) { $entry.LastSubmitAt = $pressedAt }
                                    else { $entry | Add-Member -NotePropertyName LastSubmitAt -NotePropertyValue $pressedAt -Force }
                                }
                            }
                        }
                        catch {
                            # No button (older session): fall back to submitting as
                            # soon as every field is chosen rather than hanging.
                            $submitted = $true
                        }
                        if ($submitted) {
                            $selections = @($picked)
                            $answer = ($picked -join ' + ')
                        }
                    }
                }
            }
            elseif ($isChoice) {
                $sel = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
                $s = [string]$sel.state
                if ($s -notin @('Idle', 'Awaiting answer...', 'unknown', 'unavailable', '')) { $answer = $s }
            }
            else {
                $rep = Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers
                $r = [string]$rep.state
                # Whitespace is the blank sentinel the reply box is parked on, not an
                # answer, so it must not be injected.
                if (-not [string]::IsNullOrWhiteSpace($r) -and
                    $r -notin @('unknown', 'unavailable')) { $answer = $r }
            }
        }
        catch {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($answer)) { continue }
        if ($answer -eq [string]$marker.injectedAnswer) { continue }

        # Re-verify the ask_user is still pending right before injecting, so a terminal
        # answer that landed in the last second is never double-answered.
        $recheck = Get-CopilotAskUserState -TranscriptPath $session.Transcript
        if (-not $recheck.Pending) { continue }

        [void](Invoke-DaemonDecisionAnswer -SessionId $sessionId -Marker $marker `
            -Answer $answer -IsChoice $isChoice -Selections $selections -Headers $Headers)
    }
}

function Invoke-DaemonDecisionAnswer {
    <#
        Injects a single Home Assistant answer into a live ask_user prompt. Freeform
        answers are typed as text; choices are handled by the choice-injection
        strategy. Marks the marker as injected on success so it is not repeated, and
        blanks the Home Assistant input field.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][object]$Marker,
        [Parameter(Mandatory)][string]$Answer,
        [Parameter(Mandatory)][bool]$IsChoice,
        [AllowEmptyCollection()][string[]]$Selections = @(),
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $short = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))
    $node = Get-CopilotMqttNodeId -SessionId $SessionId

    if ($IsChoice) {
        # The native prompt is one arrow-key option list per field (tabbed when there
        # is more than one). Selecting by index returns the schema's real value for
        # each field, so prefer that; the per-field "Other (type your answer)" text
        # path is only a fallback when the option cannot be located.
        $fields = @($Marker.fields)
        $sel = @($Selections)
        if ($sel.Count -eq 0 -and $fields.Count -eq 1) {
            # Single-field choice: the selector's value is the field's option.
            $sel = @($Answer)
        }

        $delivery = $null
        if ($fields.Count -gt 0 -and $sel.Count -eq $fields.Count) {
            $delivery = Send-CopilotSessionForm -SessionId $SessionId -Fields $fields -Selections $sel
        }
        if ($null -eq $delivery -or -not $delivery.Delivered) {
            if ($null -ne $delivery) {
                Write-DaemonLog -Message "form injection unavailable for $short ($($delivery.Detail)); falling back to text"
            }
            $delivery = Send-CopilotSessionChoice -SessionId $SessionId -Text $Answer `
                -ChoiceCount (@($Marker.choices).Count)
        }
    }
    else {
        $delivery = Send-CopilotSessionPrompt -SessionId $SessionId -Text $Answer
    }

    if ($delivery.Delivered) {
        Set-CopilotDecisionMarkerInjected -SessionId $SessionId -Answer $Answer
        try {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }
        }
        catch { }
        Write-DaemonLog -Message "decision answer injected to $short (pid $($delivery.ProcessId)): $($delivery.Detail)"
    }
    else {
        Write-DaemonLog -Message "decision answer injection FAILED for $short : $($delivery.Detail)"
    }
    $delivery.Delivered
}

function Clear-CopilotMqttOrphans {
    <#
        Removes published entities for sessions that are no longer live.

        A daemon that is killed rather than shut down cleanly, or a session that exits
        while no daemon is running, leaves its retained MQTT discovery configs in the
        broker with nothing to retire them. On startup the daemon reconciles the full
        published set against the live sessions and clears anything orphaned, so the
        dashboard never accumulates dead sessions across daemon restarts.

        Orphans are matched by node id: every published entity id is
        `<component>.copilot_<node>_<object>`, and the live node ids are computed from
        the live sessions. Anything published under a node id that is not live is
        cleared.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$Live
    )

    $liveNodes = @{}
    foreach ($sessionId in $Live.Keys) {
        $liveNodes[(Get-CopilotMqttNodeId -SessionId $sessionId)] = $true
    }

    try {
        $states = Invoke-RestMethod `
            -Uri "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/states" `
            -Headers $Headers -TimeoutSec 20
    }
    catch {
        Write-DaemonLog -Message "orphan sweep skipped: $($_.Exception.Message)"
        return
    }

    $orphanNodes = @{}
    foreach ($state in $states) {
        if ([string]$state.entity_id -notmatch '^(?:select|sensor|text)\.(copilot_[0-9a-f]{16,})_') {
            continue
        }
        $node = $Matches[1]
        if (-not $liveNodes.ContainsKey($node)) { $orphanNodes[$node] = $true }
    }

    foreach ($node in $orphanNodes.Keys) {
        foreach ($entry in @(
            @{ Component = 'select'; Object = 'decision' }
            @{ Component = 'text'; Object = 'reply' }
            @{ Component = 'sensor'; Object = 'status' }
            @{ Component = 'sensor'; Object = 'activity' }
            @{ Component = 'select'; Object = 'f1' }
            @{ Component = 'select'; Object = 'f2' }
            @{ Component = 'select'; Object = 'f3' }
            @{ Component = 'select'; Object = 'f4' }
            @{ Component = 'button'; Object = 'submit' }
        )) {
            $topic = "$($script:CopilotMqttConfig.DiscoveryPrefix)/$($entry.Component)/$node/$($entry.Object)/config"
            try {
                Publish-CopilotMqttMessage -Topic $topic -Payload '' -Headers $Headers -Retain
            }
            catch {
                # Best effort; a missed one is caught on the next startup sweep.
            }
        }
        Write-DaemonLog -Message "cleared orphaned entities for node $node"
    }
}

function Sync-DaemonUpdateStatus {
    <#
        Publishes the bridge's own update status, and acts on a press of the install
        button.

        Both halves are deliberately forgiving: an update check that fails, or a
        GitHub outage, must never disturb a running session. The check itself is
        cached for a day inside Get-BridgeLatestRelease, so calling this on every
        reconcile costs nothing.
    #>
    param([Parameter(Mandatory)][hashtable]$Headers)

    # Opting out has to stop the network call, not just hide the result, so this is
    # checked before anything else happens.
    if (-not (Get-BridgeSetting 'updates.checkForUpdates' $true)) { return }

    try {
        $status = Get-BridgeUpdateStatus
        $latest = if ($status.Available) { $status.Latest } else { $status.Installed }

        if ($status.Available -ne $script:DaemonUpdateAvailable -or -not $script:DaemonUpdatePublished) {
            Publish-CopilotMqttUpdate -InstalledVersion $status.Installed -LatestVersion $latest `
                -ReleaseUrl $status.Url -ReleaseNotes $status.Notes -Headers $Headers
            [void](Set-CopilotMqttUpdateEntityIds)
            $script:DaemonUpdatePublished = $true
            if ($status.Available -ne $script:DaemonUpdateAvailable) {
                $script:DaemonUpdateAvailable = $status.Available
                if ($status.Available) {
                    Write-DaemonLog -Message "update available: $($status.Installed) -> $($status.Latest)"
                }
            }
        }
    }
    catch {
        Write-DaemonLog -Message "update check failed: $($_.Exception.Message)"
        return
    }

    # The install button is a press timestamp, like the per-session Submit button.
    # A press from before this daemon started is history - a retained value from an
    # earlier run - while anything newer is a real instruction. Comparing against the
    # start time rather than simply ignoring the first value seen means a press made
    # moments after a restart still counts, instead of being silently swallowed.
    try {
        $button = Get-HomeAssistantState -EntityId 'button.copilot_cli_install_update' -Headers $Headers
        $press = [string]$button.state
        if ($press -in @('unknown', 'unavailable', '')) { return }
        if ($press -eq $script:DaemonUpdateLastPress) { return }
        $script:DaemonUpdateLastPress = $press

        $pressedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($press, [ref]$pressedAt)) { return }
        if ($pressedAt -le $script:DaemonStartedAt) { return }

        Write-DaemonLog -Message 'install update requested from Home Assistant'
        $result = Invoke-BridgeSelfUpdate -Detached
        Write-DaemonLog -Message "self-update: $($result.Detail)"
    }
    catch {
        # The button may not exist yet on a first run.
    }
}

function Sync-DaemonSessions {
    <#
        Brings the published Home Assistant entities in line with the live sessions,
        and streams any new transcript activity.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State
    )

    $live = Get-LiveBridgeSessions
    $verbose = Test-VerboseStreaming -Headers $Headers

    # Note sessions that have exited, and drop them from state now, but defer removing
    # their Home Assistant entities until after the dashboard has been rebuilt without
    # them (below). Removing the entities first leaves the still-present card pointing
    # at dead entities, which renders as "Entity not found" until the rebuild catches
    # up. Rebuilding first means the card is gone before the entities are.
    $goneSessions = @()
    foreach ($known in @($State.Keys)) {
        if ($live.ContainsKey($known)) { continue }
        $goneSessions += $known
        $State.Remove($known)
    }

    foreach ($session in $live.Values) {
        $id = $session.SessionId
        $entry = $State[$id]

        if ($null -eq $entry) {
            $kind = if ($session.PSObject.Properties.Name -contains 'Kind') { [string]$session.Kind } else { 'copilot' }
            $workingDirectory = if ($session.PSObject.Properties.Name -contains 'WorkingDirectory' -and $session.WorkingDirectory) {
                [string]$session.WorkingDirectory
            } else { 'Unknown folder' }
            $display = Get-BridgeSessionDisplay -SessionId $id -Kind $kind -WorkingDirectory $workingDirectory
            $node = Get-CopilotMqttNodeId -SessionId $id

            # Only publish the entity set if it does not already exist. The ask_user
            # router publishes a session's entities on demand and then arms its
            # decision selector; a blind re-publish here would reset that selector to
            # Idle and blank a live question. When the entities already exist, adopt
            # the session into state without touching them.
            $alreadyPublished = $false
            try {
                $probe = Get-HomeAssistantState -EntityId "select.${node}_decision" -Headers $Headers
                $alreadyPublished = ($null -ne $probe -and [string]$probe.state -notin @('unavailable', ''))
            }
            catch {
                $alreadyPublished = $false
            }

            if (-not $alreadyPublished) {
                try {
                    Publish-CopilotMqttSession -SessionId $id -SessionName $display.Name `
                        -Machine $display.Machine -Headers $Headers | Out-Null
                    # Discovery needs a moment to register before the ids can be forced.
                    Start-Sleep -Milliseconds 1500
                    [void](Set-CopilotMqttEntityIds -SessionId $id)
                    Write-DaemonLog -Message "published session $($id.Substring(0,8)) as '$($display.Name)'"
                }
                catch {
                    Write-DaemonLog -Message "publish failed for $id : $($_.Exception.Message)"
                    continue
                }
            }
            else {
                Write-DaemonLog -Message "adopted existing session $($id.Substring(0,8)) as '$($display.Name)'"
            }

            # Ensure the per-field dropdown slots and the Submit button exist for every
            # session, including adopted ones and sessions published before either was
            # introduced. The dashboard's cards reference them unconditionally, so a
            # missing entity renders an "Entity not found" box on the session card.
            try {
                $probeField = $null
                try { $probeField = Get-HomeAssistantState -EntityId "select.${node}_f1" -Headers $Headers }
                catch { $probeField = $null }
                if ($null -eq $probeField) {
                    Clear-CopilotMqttDecisionFields -SessionId $id -SessionName $display.Name `
                        -Machine $display.Machine -Headers $Headers
                    Write-DaemonLog -Message "provisioned field slots for $($id.Substring(0,8))"
                }

                $probeSubmit = $null
                try { $probeSubmit = Get-HomeAssistantState -EntityId "button.${node}_submit" -Headers $Headers }
                catch { $probeSubmit = $null }
                if ($null -eq $probeSubmit) {
                    Publish-CopilotMqttSubmitButton -SessionId $id -SessionName $display.Name `
                        -Machine $display.Machine -Headers $Headers
                    Write-DaemonLog -Message "provisioned submit button for $($id.Substring(0,8))"
                }
            }
            catch {
                Write-DaemonLog -Message "provisioning failed for $id : $($_.Exception.Message)"
            }

            $initialStatus = if (Test-BridgeSessionWorking -SessionId $id -Kind $kind -Transcript $session.Transcript) { 'working' } else { 'idle' }
            $initialActivity = if ($initialStatus -eq 'working') { 'Working' } else { 'Idle' }
            try {
                Set-CopilotMqttStatus -SessionId $id -Status $initialStatus -Headers $Headers -Attributes @{
                    session = $display.Name
                    machine = $display.Machine
                    process_id = $session.ProcessId
                    updated = [DateTimeOffset]::Now.ToString('o')
                }
                Set-CopilotMqttActivity -SessionId $id -Summary $initialActivity `
                    -Detail @{ session = $display.Name; machine = $display.Machine } -Headers $Headers
                    # Prime the reply box to empty so the card shows a blank field rather
                    # than 'unknown' before the box has ever been used.
                    Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers `
                        -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }
            }
            catch {
                Write-DaemonLog -Message "initial status publish failed for $id : $($_.Exception.Message)"
            }

            $entry = [pscustomobject]@{
                # A session with no transcript yet starts at offset 0, so the first
                # bytes it writes are picked up rather than skipped.
                Offset = if ([IO.File]::Exists($session.Transcript)) {
                    (Get-Item -LiteralPath $session.Transcript).Length
                } else { 0 }
                Name = $display.Name
                Machine = $display.Machine
                Status = $initialStatus
                Kind = $kind
            }
            $State[$id] = $entry
            continue
        }

        $entryKind = if ($entry.PSObject.Properties.Name -contains 'Kind' -and $entry.Kind) { [string]$entry.Kind } else { 'copilot' }

        # A session published before it wrote its workspace file only had a generic
        # name to go on. Names are otherwise resolved once, so re-resolve while the
        # stored one is still the fallback; the real task name usually appears within
        # a reconcile or two of the session starting.
        if ([string]$entry.Name -match '^Copilot session [0-9a-f]{8}$') {
            $workingDirectory = if ($session.PSObject.Properties.Name -contains 'WorkingDirectory' -and $session.WorkingDirectory) {
                [string]$session.WorkingDirectory
            } else { 'Unknown folder' }
            $refreshed = Get-BridgeSessionDisplay -SessionId $id -Kind $entryKind -WorkingDirectory $workingDirectory
            if ([string]$refreshed.Name -ne [string]$entry.Name) {
                $entry.Name = $refreshed.Name
                try {
                    Set-CopilotMqttStatus -SessionId $id -Status ([string]$entry.Status) -Headers $Headers -Attributes @{
                        session = $entry.Name
                        machine = $entry.Machine
                        process_id = $session.ProcessId
                        updated = [DateTimeOffset]::Now.ToString('o')
                    }
                }
                catch { }
                Write-DaemonLog -Message "renamed $($id.Substring(0,8)) to '$($entry.Name)'"
            }
        }

        $append = Read-BridgeTranscriptAppend -Path $session.Transcript -Offset ([long]$entry.Offset) -Kind $entryKind
        $entry.Offset = $append.Offset
        if ($append.Lines.Count -eq 0) { continue }

        $activity = Get-BridgeActivity -Lines $append.Lines -VerboseMode $verbose -Kind $entryKind

        if (-not [string]::IsNullOrWhiteSpace($activity.Status) -and
            $activity.Status -ne [string]$entry.Status) {
            $entry.Status = $activity.Status
            try {
                Set-CopilotMqttStatus -SessionId $id -Status $activity.Status -Headers $Headers -Attributes @{
                    session = $entry.Name
                    machine = $entry.Machine
                    process_id = $session.ProcessId
                    updated = [DateTimeOffset]::Now.ToString('o')
                }
            }
            catch {
                Write-DaemonLog -Message "status publish failed for $id : $($_.Exception.Message)"
            }
        }

        if ([string]::IsNullOrWhiteSpace($activity.Summary) -and
            [string]::IsNullOrWhiteSpace($activity.Reasoning)) {
            continue
        }

        # Persist the latest reasoning in session state so it stays on the card across
        # batches that carry no reasoning (a tool call, a plain message), and so the
        # verbose toggle can show it instantly. Capture is unconditional; only display
        # is gated on verbose (below).
        $lastReasoning = if ($entry.PSObject.Properties['LastReasoning']) {
            [string]$entry.LastReasoning
        }
        else { '' }
        if (-not [string]::IsNullOrWhiteSpace($activity.Reasoning)) {
            $lastReasoning = $activity.Reasoning
        }
        if ($entry.PSObject.Properties['LastReasoning']) {
            $entry.LastReasoning = $lastReasoning
        }
        else {
            $entry | Add-Member -NotePropertyName LastReasoning -NotePropertyValue $lastReasoning -Force
        }

        # Persist the full text of the last substantive response, likewise, so the
        # card can render the whole answer across later tool-call batches that carry
        # no new content.
        $lastResponse = if ($entry.PSObject.Properties['LastResponse']) {
            [string]$entry.LastResponse
        }
        else { '' }
        if (-not [string]::IsNullOrWhiteSpace($activity.Response)) {
            $lastResponse = $activity.Response
        }
        if ($entry.PSObject.Properties['LastResponse']) {
            $entry.LastResponse = $lastResponse
        }
        else {
            $entry | Add-Member -NotePropertyName LastResponse -NotePropertyValue $lastResponse -Force
        }

        $summary = $activity.Summary
        if ([string]::IsNullOrWhiteSpace($summary)) { $summary = 'Thinking' }
        # Remember the summary so a verbose-toggle refresh can republish the card
        # without needing fresh transcript activity.
        if ($entry.PSObject.Properties['LastSummary']) {
            $entry.LastSummary = $summary
        }
        else {
            $entry | Add-Member -NotePropertyName LastSummary -NotePropertyValue $summary -Force
        }

        $detail = @{
            session = $entry.Name
            machine = $entry.Machine
            verbose = $verbose
            updated = [DateTimeOffset]::Now.ToString('o')
            history = @($activity.History | Select-Object -Last $script:DaemonConfig.ActivityHistory)
        }
        # The card shows the response in full; the expander is reserved for reasoning
        # and extra detail, so nothing is split off into a "show more" remainder.
        if (-not [string]::IsNullOrWhiteSpace($lastResponse)) {
            $capped = $lastResponse
            if ($capped.Length -gt $script:DaemonConfig.ResponseMaxChars) {
                $capped = $capped.Substring(0, $script:DaemonConfig.ResponseMaxChars).TrimEnd() +
                    "`n`n_(truncated - see terminal)_"
            }
            $detail['response'] = $capped
        }
        if ($verbose -and -not [string]::IsNullOrWhiteSpace($lastReasoning)) {
            $capped = $lastReasoning
            if ($capped.Length -gt $script:DaemonConfig.ReasoningMaxChars) {
                $capped = $capped.Substring(0, $script:DaemonConfig.ReasoningMaxChars).TrimEnd() + '…'
            }
            $detail['reasoning'] = $capped
        }

        try {
            Set-CopilotMqttActivity -SessionId $id -Summary $summary -Detail $detail -Headers $Headers
        }
        catch {
            Write-DaemonLog -Message "activity publish failed for $id : $($_.Exception.Message)"
        }
    }

    # Keep the global count sensor and the dashboard in step with the live set. The
    # dashboard is only rebuilt when the set of sessions actually changes, because a
    # rebuild replaces the whole Lovelace config and is far heavier than a state
    # publish; turn-by-turn activity rides on the per-session entities the dashboard
    # already points at.
    $descriptors = @(
        foreach ($id in ($State.Keys | Sort-Object)) {
            $entry = $State[$id]
            [pscustomobject]@{
                Node = Get-CopilotMqttNodeId -SessionId $id
                Name = $entry.Name
                Machine = $entry.Machine
            }
        }
    )

    try {
        Publish-CopilotMqttGlobalStatus -Headers $Headers -Sessions @(
            $descriptors | ForEach-Object { @{ name = $_.Name; machine = $_.Machine; node = $_.Node } }
        )
    }
    catch {
        Write-DaemonLog -Message "global status publish failed: $($_.Exception.Message)"
    }

    # The card header carries the session name, so a rename has to rebuild the
    # dashboard too - a signature of node ids alone would leave a renamed session
    # showing its old generic title until the set of sessions happened to change.
    $signature = ($descriptors | ForEach-Object { "$($_.Node)=$($_.Name)" }) -join '|'
    if ($signature -ne $script:DaemonDashboardSignature) {
        try {
            [void](Set-CopilotMqttGlobalEntityId)
            Save-CopilotSessionDashboard -Sessions $descriptors
            $script:DaemonDashboardSignature = $signature
            Write-DaemonLog -Message "dashboard rebuilt for $($descriptors.Count) session(s)"
        }
        catch {
            Write-DaemonLog -Message "dashboard rebuild failed: $($_.Exception.Message)"
        }
    }

    # Now that the dashboard no longer has a card pointing at them, remove the exited
    # sessions' entities. Done last so there is never a window where a live card
    # references a deleted entity.
    foreach ($known in $goneSessions) {
        try {
            Remove-CopilotMqttSession -SessionId $known -Headers $Headers
            Remove-CopilotDecisionMarker -SessionId $known
            Write-DaemonLog -Message "retired session $($known.Substring(0, [Math]::Min(8, $known.Length)))"
        }
        catch {
            Write-DaemonLog -Message "retire failed for $known : $($_.Exception.Message)"
        }
    }
}

function Update-SessionsForVerbose {
    <#
        Immediately republishes every session's activity to show or hide its reasoning
        the instant the Live Verbose toggle changes, without waiting for the session to
        produce fresh transcript activity. Reasoning is kept in state regardless of the
        toggle, so turning verbose on re-reveals the last captured reasoning at once and
        turning it off hides it at once.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][bool]$VerboseOn
    )

    foreach ($id in @($State.Keys)) {
        $entry = $State[$id]
        $summary = if ($entry.PSObject.Properties['LastSummary'] -and
            -not [string]::IsNullOrWhiteSpace($entry.LastSummary)) {
            [string]$entry.LastSummary
        }
        elseif ([string]$entry.Status -eq 'working') { 'Working' }
        else { 'Idle' }

        $detail = @{
            session = $entry.Name
            machine = $entry.Machine
            verbose = $VerboseOn
            updated = [DateTimeOffset]::Now.ToString('o')
        }
        $lastResponse = if ($entry.PSObject.Properties['LastResponse']) { [string]$entry.LastResponse } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($lastResponse)) {
            $capped = $lastResponse
            if ($capped.Length -gt $script:DaemonConfig.ResponseMaxChars) {
                $capped = $capped.Substring(0, $script:DaemonConfig.ResponseMaxChars).TrimEnd() +
                    "`n`n_(truncated - see terminal)_"
            }
            $detail['response'] = $capped
        }
        $lastReasoning = if ($entry.PSObject.Properties['LastReasoning']) { [string]$entry.LastReasoning } else { '' }
        if ($VerboseOn -and -not [string]::IsNullOrWhiteSpace($lastReasoning)) {
            $capped = $lastReasoning
            if ($capped.Length -gt $script:DaemonConfig.ReasoningMaxChars) {
                $capped = $capped.Substring(0, $script:DaemonConfig.ReasoningMaxChars).TrimEnd() + '…'
            }
            $detail['reasoning'] = $capped
        }

        try {
            Set-CopilotMqttActivity -SessionId $id -Summary $summary -Detail $detail -Headers $Headers
        }
        catch {
            Write-DaemonLog -Message "verbose refresh failed for $id : $($_.Exception.Message)"
        }
    }
}

function Invoke-DaemonReply {
    <#
        Delivers a dashboard reply into the running CLI and clears the box.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $short = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))

    # Claude Code leaves no inuse.<pid>.lock, so its owning process is passed
    # explicitly from the registration the hooks maintain.
    $explicitPid = 0
    $claudeSession = (Get-LiveClaudeSessions)[$SessionId]
    if ($null -ne $claudeSession) { $explicitPid = [int]$claudeSession.ProcessId }

    $delivery = Send-CopilotSessionPrompt -SessionId $SessionId -Text $Text -ProcessId $explicitPid
    if ($delivery.Delivered) {
        Write-DaemonLog -Message "reply delivered to $short (pid $($delivery.ProcessId)): $($delivery.Detail)"
    }
    else {
        Write-DaemonLog -Message "reply delivery FAILED for $short : $($delivery.Detail)"
    }

    # Clear the box either way, so a failed delivery is not silently resent. The
    # reply box is an optimistic MQTT text entity with no state topic, so its value
    # is cleared with the text.set_value service, not by publishing to a state topic
    # that nothing is subscribed to.
    try {
        $node = Get-CopilotMqttNodeId -SessionId $SessionId
        Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers -Data @{
            entity_id = "text.${node}_reply"
            value = $script:DaemonConfig.ReplyBlankValue
        }
    }
    catch {
        # The guard hash still prevents a re-delivery even if the clear fails.
    }

    $delivery.Delivered
}

function Resolve-SessionFromReplyEntity {
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][hashtable]$State
    )

    foreach ($sessionId in @($State.Keys)) {
        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        if ($EntityId -eq "text.${node}_reply") { return $sessionId }
    }
    $null
}

function Start-BridgeDaemon {
    $headers = Get-HomeAssistantHeaders
    $state = Read-DaemonState

    # Deliberately no pruning here. Sync-DaemonSessions retires anything that is no
    # longer live, which both removes its Home Assistant entities and drops it from
    # state. Pruning first would discard the record while leaving the published
    # entities behind as orphans.
    $live = Get-LiveBridgeSessions

    Write-DaemonLog -Message "daemon starting (pid $PID), $($live.Count) live session(s)"

    # Provision the dashboard's Live Verbose helper before anything renders it.
    if (Initialize-CopilotVerboseToggle) {
        Write-DaemonLog -Message "verbose toggle ready ($($script:DaemonConfig.VerboseToggle))"
    }
    else {
        Write-DaemonLog -Message 'verbose toggle unavailable; streaming defaults to quiet'
    }

    Clear-CopilotMqttOrphans -Headers $headers -Live $live

    # Prime every live session's status and activity up front. Persisted state makes
    # a session "already known", so the first reconcile skips the new-session branch
    # that sets these; without priming, an idle session that produced no new
    # transcript activity would sit at 'unknown' on the dashboard after a restart.
    # This is a handful of publishes once per daemon start, so it is done
    # unconditionally rather than guarded.
    Sync-DaemonSessions -Headers $headers -State $state
    foreach ($session in $live.Values) {
        $sid = $session.SessionId
        $entry = $state[$sid]
        if ($null -eq $entry) { continue }
        $node = Get-CopilotMqttNodeId -SessionId $sid
        $status = if (Test-CopilotSessionWorking -SessionId $sid) { 'working' } else { 'idle' }
        $activity = if ($status -eq 'working') { 'Working' } else { 'Idle' }
        try {
            Set-CopilotMqttStatus -SessionId $sid -Status $status -Headers $headers -Attributes @{
                session = $entry.Name
                machine = $entry.Machine
                process_id = $session.ProcessId
                updated = [DateTimeOffset]::Now.ToString('o')
            }
            Set-CopilotMqttActivity -SessionId $sid -Summary $activity `
                -Detail @{ session = $entry.Name; machine = $entry.Machine } -Headers $headers
            # Prime the reply box to empty so the card shows a blank field, not
            # 'unknown', for sessions restored from persisted state.
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $headers `
                -Data @{ entity_id = "text.${node}_reply"; value = $script:DaemonConfig.ReplyBlankValue }
            $entry.Status = $status
        }
        catch {
            Write-DaemonLog -Message "status prime failed for $sid : $($_.Exception.Message)"
        }
    }
    Repair-CopilotSessionEntities -Headers $headers -State $state -Live $live
    Invoke-PendingDecisions -Headers $headers -State $state -Live $live
    Invoke-PendingReplies -Headers $headers -State $state -Live $live
    Sync-DaemonUpdateStatus -Headers $headers
    Write-DaemonState -State $state

    if ($RunOnce) {
        Write-DaemonLog -Message 'run-once complete'
        return
    }

    $lastReconcile = [DateTimeOffset]::Now

    while ($true) {
        # Watch every live session's reply box and decision selector, plus the Live
        # Verbose toggle. The subscription returns the instant Home Assistant pushes a
        # change, so an answer is injected and a verbose toggle reflected immediately.
        # Both are also backed by the authoritative sweep in the reconcile below, which
        # catches anything that lands between watch windows.
        $watchEntities = @(
            foreach ($sessionId in @($state.Keys)) {
                $node = Get-CopilotMqttNodeId -SessionId $sessionId
                "text.${node}_reply"
                "select.${node}_decision"
                "button.${node}_submit"
            }
        ) + @($script:DaemonConfig.VerboseToggle)

        $hit = $null
        try {
            $hit = Wait-CopilotHaStateChange -EntityIds $watchEntities `
                -TimeoutSeconds $ReconcileSeconds
        }
        catch {
            Write-DaemonLog -Message "watch failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }

        # A verbose toggle change refreshes every card's reasoning at once, without
        # waiting for the periodic reconcile or fresh transcript activity.
        if ($null -ne $hit -and $hit.EntityId -eq $script:DaemonConfig.VerboseToggle) {
            try {
                Update-SessionsForVerbose -Headers $headers -State $state `
                    -VerboseOn ($hit.State -eq 'on')
            }
            catch {
                Write-DaemonLog -Message "verbose refresh failed: $($_.Exception.Message)"
            }
        }

        # A push hit only shortcuts latency; the sweep in the reconcile does the
        # authoritative delivery, so both paths funnel through the same guarded code.
        if (([DateTimeOffset]::Now - $lastReconcile).TotalSeconds -ge $ReconcileSeconds -or
            $null -ne $hit) {
            try {
                $live = Get-LiveBridgeSessions
                Sync-DaemonSessions -Headers $headers -State $state
                Repair-CopilotSessionEntities -Headers $headers -State $state -Live $live
                Invoke-PendingDecisions -Headers $headers -State $state -Live $live
                Invoke-PendingReplies -Headers $headers -State $state -Live $live
                Sync-DaemonUpdateStatus -Headers $headers
                Write-DaemonState -State $state
            }
            catch {
                Write-DaemonLog -Message "reconcile failed: $($_.Exception.Message)"
            }
            $lastReconcile = [DateTimeOffset]::Now
        }
    }
}

# A second daemon would publish duplicate activity and race on reply delivery.
$mutex = [Threading.Mutex]::new($false, $script:DaemonConfig.MutexName)
$owned = $false
try {
    $owned = $mutex.WaitOne([TimeSpan]::FromSeconds(2))
    if (-not $owned) {
        Write-DaemonLog -Message 'another daemon instance is already running; exiting'
        return
    }
    Start-BridgeDaemon
}
catch {
    Write-DaemonLog -Message "daemon crashed: $($_.Exception.Message)"
    throw
}
finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
