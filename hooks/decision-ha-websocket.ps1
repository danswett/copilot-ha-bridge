<#
    Home Assistant WebSocket helpers for the Copilot CLI bridge.

    Kept separate from the dashboard builder because that script runs its rebuild on
    load, so it cannot be dot-sourced just to reuse its socket code.
#>

function Invoke-CopilotHaWebSocket {
    <#
        Runs a list of WebSocket commands against Home Assistant and returns one
        result per command, in order.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$Commands,

        [int]$TimeoutSeconds = 60
    )
    # Same token resolution as the REST helpers: config file, then environment.
    $token = (Get-HomeAssistantHeaders).Authorization -replace '^Bearer ', ''

    $wsUri = [Uri](
        ($script:DecisionBridgeConfig.HomeAssistantBaseUrl -replace '^http', 'ws').TrimEnd('/') +
        '/api/websocket'
    )

    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    $results = @()
    try {
        [void]$socket.ConnectAsync($wsUri, $cancel.Token).GetAwaiter().GetResult()

        $receive = {
            $buffer = [ArraySegment[byte]]::new([byte[]]::new(65536))
            $text = [Text.StringBuilder]::new()
            do {
                $result = $socket.ReceiveAsync($buffer, $cancel.Token).GetAwaiter().GetResult()
                [void]$text.Append(
                    [Text.Encoding]::UTF8.GetString($buffer.Array, 0, $result.Count)
                )
            } while (-not $result.EndOfMessage)
            $text.ToString() | ConvertFrom-Json
        }

        $send = {
            param($payload)
            $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 40 -Compress))
            [void]$socket.SendAsync(
                [ArraySegment[byte]]::new($bytes),
                [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token
            ).GetAwaiter().GetResult()
        }

        $hello = & $receive
        if ($hello.type -ne 'auth_required') {
            throw "Unexpected Home Assistant WebSocket greeting: $($hello.type)"
        }
        & $send @{ type = 'auth'; access_token = $token }
        $auth = & $receive
        if ($auth.type -ne 'auth_ok') {
            throw 'Home Assistant WebSocket authentication failed.'
        }

        $id = 0
        foreach ($command in $Commands) {
            $id++
            $command['id'] = $id
            & $send $command
            $reply = & $receive
            while ($reply.type -ne 'result' -or $reply.id -ne $id) {
                $reply = & $receive
            }
            if (-not $reply.success) {
                throw "WebSocket command '$($command.type)' failed: $($reply.error | ConvertTo-Json -Compress)"
            }
            $results += , $reply.result
        }
    }
    finally {
        if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
            try {
                [void]$socket.CloseAsync(
                    [Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $cancel.Token
                ).GetAwaiter().GetResult()
            }
            catch {
                # A close failure does not invalidate results already received.
            }
        }
        $socket.Dispose()
        $cancel.Dispose()
    }

    # -NoEnumerate keeps the outer result array intact. Without it PowerShell unrolls
    # it, so a single command returning a list (for example the entity registry)
    # comes back as thousands of top-level items and indexing [0] yields one entry
    # rather than the list.
    Write-Output -NoEnumerate $results
}

function Wait-CopilotHaStateChange {
    <#
        Blocks until one of the watched entities changes to a state other than the
        ignored placeholders, and returns that entity id and state.

        This uses a server-side state trigger scoped to the watched entities, so Home
        Assistant only sends a message when one of them actually changes. An earlier
        version subscribed to every `state_changed` event and filtered client side,
        which on this instance meant decoding hundreds of unrelated MQTT sensor
        updates per second and burned the CPU. The trigger form sits genuinely idle
        between hits.

        Returns $null on timeout. A dropped socket also returns $null so the caller
        can decide whether to reconnect rather than having the failure thrown into
        the middle of a decision wait.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$EntityIds,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,

        [string[]]$IgnoreStates = @('unknown', 'unavailable', '')
    )
    # Same token resolution as the REST helpers: config file, then environment.
    $token = (Get-HomeAssistantHeaders).Authorization -replace '^Bearer ', ''
    $wsUri = [Uri](
        ($script:DecisionBridgeConfig.HomeAssistantBaseUrl -replace '^http', 'ws').TrimEnd('/') +
        '/api/websocket'
    )

    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds + 15))
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)

    try {
        [void]$socket.ConnectAsync($wsUri, $cancel.Token).GetAwaiter().GetResult()

        $receive = {
            param([int]$WaitSeconds)
            $buffer = [ArraySegment[byte]]::new([byte[]]::new(65536))
            $text = [Text.StringBuilder]::new()
            $perCall = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($WaitSeconds))
            try {
                do {
                    $result = $socket.ReceiveAsync($buffer, $perCall.Token).GetAwaiter().GetResult()
                    [void]$text.Append(
                        [Text.Encoding]::UTF8.GetString($buffer.Array, 0, $result.Count)
                    )
                } while (-not $result.EndOfMessage)
            }
            finally {
                $perCall.Dispose()
            }
            $text.ToString() | ConvertFrom-Json
        }

        $send = {
            param($payload)
            $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 40 -Compress))
            [void]$socket.SendAsync(
                [ArraySegment[byte]]::new($bytes),
                [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token
            ).GetAwaiter().GetResult()
        }

        $hello = & $receive 30
        if ($hello.type -ne 'auth_required') {
            throw "Unexpected Home Assistant WebSocket greeting: $($hello.type)"
        }
        & $send @{ type = 'auth'; access_token = $token }
        $auth = & $receive 30
        if ($auth.type -ne 'auth_ok') {
            throw 'Home Assistant WebSocket authentication failed.'
        }

        & $send @{
            type = 'subscribe_trigger'
            id = 1
            trigger = @{ platform = 'state'; entity_id = @($EntityIds) }
        }
        [void](& $receive 30)

        while ([DateTimeOffset]::Now -lt $deadline) {
            $remaining = [int]([Math]::Max(1, ($deadline - [DateTimeOffset]::Now).TotalSeconds))
            $slice = [Math]::Min(30, $remaining)

            try {
                $message = & $receive $slice
            }
            catch {
                # No trigger fired in this window. With a scoped trigger this is the
                # normal idle path, not an error.
                if ($socket.State -ne [Net.WebSockets.WebSocketState]::Open) { return $null }
                continue
            }

            if ($message.type -ne 'event') { continue }
            $trigger = $message.event.variables.trigger
            $entityId = [string]$trigger.entity_id
            if ([string]::IsNullOrWhiteSpace($entityId)) { continue }

            $newState = [string]$trigger.to_state.state
            if ($IgnoreStates -contains $newState) { continue }

            return [pscustomobject]@{
                EntityId = $entityId
                State = $newState
                Attributes = $trigger.to_state.attributes
            }
        }

        $null
    }
    finally {
        if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
            try {
                [void]$socket.CloseAsync(
                    [Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $cancel.Token
                ).GetAwaiter().GetResult()
            }
            catch {
                # Closing is best effort.
            }
        }
        $socket.Dispose()
        $cancel.Dispose()
    }
}

function Resolve-CopilotMqttEntityIds {
    <#
        Maps the bridge's MQTT unique_ids to the entity_ids Home Assistant actually
        assigned.

        Home Assistant derives an MQTT entity_id from the device name plus the entity
        name and ignores `object_id`, so a session named "Bridge Test" produced
        `select.copilot_bridge_test_decision` rather than the node-based id the bridge
        predicted. Predicting the id from the session name would break the moment a
        session is renamed, so the registry is the source of truth.

        Returns a hashtable keyed Decision/Reply/Status/Activity. Missing entries mean
        discovery has not registered yet.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    $wanted = @{
        "${node}_decision" = 'Decision'
        "${node}_reply" = 'Reply'
        "${node}_status" = 'Status'
        "${node}_activity" = 'Activity'
    }
    for ($i = 1; $i -le 4; $i++) { $wanted["${node}_f$i"] = "Field$i" }
    $wanted["${node}_submit"] = 'Submit'
    $wanted["${node}_stop"] = 'Stop'

    $registry = @(
        (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'config/entity_registry/list' }))[0]
    )

    $map = @{}
    foreach ($entry in $registry) {
        $uniqueId = [string]$entry.unique_id
        if ($wanted.ContainsKey($uniqueId)) {
            $map[$wanted[$uniqueId]] = [string]$entry.entity_id
        }
    }

    $map
}

function Set-CopilotMqttGlobalEntityId {
    <#
        Forces the global session-count sensor onto its deterministic id. Home
        Assistant derives the id from device name plus entity name and ignores
        object_id, so the sensor first appears as sensor.ai_agent_bridge_sessions;
        rename it once so the dashboard and any templates can rely on
        sensor.agent_bridge_sessions.
    #>
    $target = 'sensor.agent_bridge_sessions'
    $reg = (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'config/entity_registry/list' }))[0]
    $entry = @($reg) | Where-Object { $_.unique_id -eq 'agent_bridge_sessions' } | Select-Object -First 1
    if ($null -eq $entry) { return $false }
    if ([string]$entry.entity_id -eq $target) { return $true }

    [void](Invoke-CopilotHaWebSocket -Commands @(@{
        type = 'config/entity_registry/update'
        entity_id = [string]$entry.entity_id
        new_entity_id = $target
    }))
    $true
}

function Initialize-CopilotVerboseToggle {
    <#
        Ensures input_boolean.agent_bridge_detailed_activity exists, without ever resetting
        its value.

        The dashboard's Detailed activity control targets this helper, but nothing
        else creates it, so a fresh install would render an "Entity not found" row.
        There is no config flow to hang this off — the bridge is a set of Windows
        scripts, not a Home Assistant integration — so it self-provisions here
        instead, using the input_boolean collection API over the WebSocket.

        Home Assistant restores a storage-backed input_boolean across a restart: a
        toggle left On reads On again once the core comes back (verified against a
        real core restart). The bridge's only job is therefore to make sure the helper
        exists — it must never recreate one that already exists, because a
        delete+create resets the state to Off and silently discards the user's choice.

        That is the bug this function used to cause. When the daemon (re)starts while
        Home Assistant is still booting, the helper is already in storage (so
        input_boolean/list returns it) but its state has not materialised yet. The old
        code read that transient no-state as "broken" and recreated the helper — which
        is exactly what flipped the toggle off after a restart. It never deletes a
        stored helper now; the state reappears on its own once Home Assistant finishes
        starting.

        Home Assistant slugifies the helper name into the id, so the name below must
        stay in sync with $DaemonConfig.VerboseToggle.

        Returns $true when the helper exists afterwards.
    #>
    param(
        [string]$HelperId = 'agent_bridge_detailed_activity',
        # Home Assistant slugifies this into the helper id, so the two must stay in
        # step: change one and you get a second helper rather than a renamed one.
        [string]$Name = 'Agent Bridge Detailed Activity',
        [string]$Icon = 'mdi:brain',
        # Shown on the dashboard and anywhere else Home Assistant names the entity.
        [string]$DisplayName = 'Detailed activity',
        # The pre-rename helper, migrated once and then removed.
        [string]$LegacyHelperId = 'copilot_cli_live_verbose'
    )

    # Applied on both paths below - an existing helper and a freshly created one -
    # because an install that predates this still carries the old display name.
    $applyDisplayName = {
        try {
            $registry = (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'config/entity_registry/list' }))[0]
            $entry = @($registry) | Where-Object { [string]$_.entity_id -eq "input_boolean.$HelperId" } | Select-Object -First 1
            if ($entry -and [string]$entry.name -ne $DisplayName) {
                [void](Invoke-CopilotHaWebSocket -Commands @(@{
                    type      = 'config/entity_registry/update'
                    entity_id = "input_boolean.$HelperId"
                    name      = $DisplayName
                }))
            }
        }
        catch {
            # A cosmetic rename is never worth failing provisioning over.
        }
    }

    try {
        $existing = (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'input_boolean/list' }))[0]
        $hasCurrent = [bool](@($existing) | Where-Object { [string]$_.id -eq $HelperId })
        $legacy = @($existing) | Where-Object { [string]$_.id -eq $LegacyHelperId } | Select-Object -First 1

        # One-time migration off the pre-rename helper. The value has to be carried
        # across by hand: creating the new helper gives it the default Off, and simply
        # deleting the old one would throw away a deliberate choice. That is the same
        # silent reset this function already exists to prevent, so it is read first
        # and re-applied after.
        if ($null -ne $legacy) {
            $wasOn = $false
            try {
                $legacyState = Get-HomeAssistantState -EntityId "input_boolean.$LegacyHelperId" -Headers (Get-HomeAssistantHeaders)
                $wasOn = ([string]$legacyState.state -eq 'on')
            }
            catch {
                # Unreadable old state: treat as off rather than guessing on.
            }

            if (-not $hasCurrent) {
                $migrated = (Invoke-CopilotHaWebSocket -Commands @(@{
                    type = 'input_boolean/create'; name = $Name; icon = $Icon
                }))[0]
                if ([string]$migrated.id -ne $HelperId) {
                    Write-Warning "Migrated toggle came back as '$($migrated.id)', expected '$HelperId'; leaving the old helper in place."
                    return $false
                }
                $hasCurrent = $true
            }

            if ($wasOn -and (Test-CopilotHelperHasState -EntityId "input_boolean.$HelperId")) {
                try {
                    Invoke-HomeAssistantService -Domain 'input_boolean' -Service 'turn_on' `
                        -Headers (Get-HomeAssistantHeaders) -Data @{ entity_id = "input_boolean.$HelperId" }
                }
                catch {
                    Write-Warning "Could not carry the toggle's On state across the rename; set it again on the dashboard."
                }
            }

            try {
                [void](Invoke-CopilotHaWebSocket -Commands @(@{
                    type = 'input_boolean/delete'; input_boolean_id = $LegacyHelperId
                }))
            }
            catch { }

            & $applyDisplayName
            return $true
        }

        if ($hasCurrent) {
            # The helper is in storage. Never delete it: its value - including one Home
            # Assistant restored across a restart - must be preserved. A missing state
            # here means Home Assistant is still starting, not that the helper is
            # broken; it will materialise on its own, so leave it untouched.
            if (-not (Test-CopilotHelperHasState -EntityId "input_boolean.$HelperId")) {
                Write-Warning "Verbose toggle is in storage but has no state yet; leaving it in place (it appears once Home Assistant finishes starting)."
            }
            & $applyDisplayName
            return $true
        }

        # Genuinely absent from storage, so create it. A brand-new install starts Off,
        # which is the right default.
        $created = (Invoke-CopilotHaWebSocket -Commands @(@{
            type = 'input_boolean/create'
            name = $Name
            icon = $Icon
        }))[0]

        # A slug mismatch almost always means the helper already existed and Home
        # Assistant de-duplicated the id - typically because the list above came back
        # transiently empty during boot. Remove the stray rather than leaving litter,
        # and trust the original helper (whose value is intact).
        if ([string]$created.id -ne $HelperId) {
            Write-Warning "Created verbose toggle as '$($created.id)', expected '$HelperId'; removing the stray and keeping the existing helper."
            try {
                [void](Invoke-CopilotHaWebSocket -Commands @(@{
                    type = 'input_boolean/delete'; input_boolean_id = [string]$created.id
                }))
            }
            catch { }
            return $true
        }
        if (-not (Test-CopilotHelperHasState -EntityId "input_boolean.$HelperId")) { return $false }

        # Give it a harness-agnostic display name without renaming the helper itself:
        # the entity_id is derived from the helper's name, and the dashboard and the
        # daemon both address it as input_boolean.agent_bridge_detailed_activity.
        & $applyDisplayName

        return $true
    }
    catch {
        Write-Warning "Could not ensure the verbose toggle: $($_.Exception.Message)"
        return $false
    }
}

function Test-CopilotHelperHasState {
    <#
        True when the entity is present in the state machine. A helper can exist in
        storage and in the entity registry yet have no state, which renders on a
        dashboard as an unavailable row.
    #>
    param([Parameter(Mandatory)][string]$EntityId)

    foreach ($attempt in 1..5) {
        Start-Sleep -Milliseconds 800
        try {
            # A missing entity is a 404, which the retry layer treats as permanent and
            # rethrows immediately, so this stays fast.
            $state = Get-HomeAssistantState -EntityId $EntityId -Headers (Get-HomeAssistantHeaders)
            if ($null -ne $state -and $state.state) { return $true }
        }
        catch { }
    }
    return $false
}

function Remove-CopilotVerboseToggle {
    <#
        Deletes the verbose toggle helper. Used by uninstall so the bridge does not
        leave a dead control behind in Home Assistant.
    #>
    param([string]$HelperId = 'agent_bridge_detailed_activity')

    $existing = (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'input_boolean/list' }))[0]
    if (-not (@($existing) | Where-Object { [string]$_.id -eq $HelperId })) { return $false }
    [void](Invoke-CopilotHaWebSocket -Commands @(@{
        type = 'input_boolean/delete'
        input_boolean_id = $HelperId
    }))
    return $true
}

function Set-CopilotMqttUpdateEntityIds {
    <#
        Forces the update entity and its install button onto deterministic ids.

        Home Assistant builds an MQTT entity id from the device name plus the entity
        name, so these first appear as update.agent_bridge_bridge_update and
        button.agent_bridge_install_bridge_update. The daemon reads the button
        by id on every reconcile, so it has to be predictable.
    #>
    $wanted = @{
        'agent_bridge_update'         = 'update.agent_bridge_update'
        'agent_bridge_install_update' = 'button.agent_bridge_install_update'
    }

    $registry = (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'config/entity_registry/list' }))[0]
    $byUniqueId = @{}
    foreach ($entry in @($registry)) {
        if ($entry.unique_id) { $byUniqueId[[string]$entry.unique_id] = $entry }
    }

    $changed = $false
    foreach ($uniqueId in $wanted.Keys) {
        $entry = $byUniqueId[$uniqueId]
        if ($null -eq $entry) { continue }
        if ([string]$entry.entity_id -eq $wanted[$uniqueId]) { continue }
        [void](Invoke-CopilotHaWebSocket -Commands @(@{
            type          = 'config/entity_registry/update'
            entity_id     = [string]$entry.entity_id
            new_entity_id = $wanted[$uniqueId]
        }))
        $changed = $true
    }
    $changed
}

function Set-CopilotMqttNewSessionEntityIds {
    <#
        Forces the new-session controls onto deterministic ids.

        Same reason as the update entities: Home Assistant builds an MQTT entity id
        from device name plus entity name and ignores object_id, so these would
        otherwise appear as text.agent_bridge_new_session_prompt and friends.
        The daemon reads all four by id on every reconcile, and the generated
        dashboard references them literally, so they have to be predictable.
    #>
    $wanted = @{
        'agent_bridge_new_prompt'         = 'text.agent_bridge_new_prompt'
        'agent_bridge_new_workspace'      = 'select.agent_bridge_new_workspace'
        'agent_bridge_new_profile'        = 'select.agent_bridge_new_profile'
        'agent_bridge_new_resume'         = 'select.agent_bridge_new_resume'
        'agent_bridge_new_session'        = 'button.agent_bridge_new_session'
        'agent_bridge_new_session_result' = 'sensor.agent_bridge_new_session_result'
    }

    $registry = (Invoke-CopilotHaWebSocket -Commands @(@{ type = 'config/entity_registry/list' }))[0]
    $byUniqueId = @{}
    foreach ($entry in @($registry)) {
        if ($entry.unique_id) { $byUniqueId[[string]$entry.unique_id] = $entry }
    }

    $changed = $false
    foreach ($uniqueId in $wanted.Keys) {
        $entry = $byUniqueId[$uniqueId]
        if ($null -eq $entry) { continue }
        if ([string]$entry.entity_id -eq $wanted[$uniqueId]) { continue }
        [void](Invoke-CopilotHaWebSocket -Commands @(@{
            type          = 'config/entity_registry/update'
            entity_id     = [string]$entry.entity_id
            new_entity_id = $wanted[$uniqueId]
        }))
        $changed = $true
    }
    $changed
}

function Save-CopilotSessionDashboard {
    <#
        Regenerates the copilot-decisions dashboard for the per-session MQTT model.

        The dashboard is fully generated from the live session list, so it is rebuilt
        whenever a session appears or exits rather than hand-edited. It has a control
        section (the session summary with its detailed-activity toggle, the update
        row, and the new-session card) and one card per live session showing status,
        activity, the decision selector and the reply box.

        Live count and pending-decision count are rendered as Jinja templates over the
        exact entity ids, so they stay current between rebuilds as turn state and
        armed questions change.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Sessions,

        [string]$VerboseToggle = 'input_boolean.agent_bridge_detailed_activity',

        # Whether to show the Agency profile row on the new-session card.
        [switch]$IncludeProfile,

        # Whether to show the resume row on the new-session card.
        [switch]$IncludeResume
    )

    $decisionEntities = @($Sessions | ForEach-Object { "select.$($_.Node)_decision" })
    $decisionList = ($decisionEntities | ForEach-Object { "'$_'" }) -join ','

    $liveTemplate = "{{ states('sensor.agent_bridge_sessions') }}"
    $pendingTemplate = "{% set dc = [$decisionList] %}{{ dc | map('states') | reject('in',['Idle','unavailable','unknown','']) | list | count }}"
    # The installed version comes from the update entity, which the daemon always
    # publishes, so the card shows what is running without another moving part.
    $installedTemplate = "{{ state_attr('update.agent_bridge_update', 'installed_version') or '?' }}"

    $controlMarkdown = @{
        type = 'markdown'
        content = @(
            '## Agent sessions'
            ''
            "**Live sessions:** $liveTemplate &bull; **Pending decisions:** $pendingTemplate &bull; **Bridge** $installedTemplate"
            ''
            'Turn on *Detailed activity* to stream each session''s reasoning and every tool call.'
        ) -join "`n"
    }

    # The summary and its one toggle are stacked into a single card rather than left
    # as two. They are the same thing - what is running, and how much of it to show -
    # and the toggle had been sharing a card with a "Live sessions" row that repeated
    # the count printed directly above it.
    $agentSessionsCard = @{
        type = 'vertical-stack'
        cards = @(
            $controlMarkdown
            @{
                type = 'entities'
                entities = @(
                    @{ entity = $VerboseToggle; name = 'Detailed activity' }
                )
            }
        )
    }

    # The update row and its install button only appear when an update exists. A
    # conditional card is used rather than hiding rows inside the entities card,
    # because an entities row has no condition of its own.
    $updateCard = @{
        type = 'conditional'
        conditions = @(@{ entity = 'update.agent_bridge_update'; state = 'on' })
        card = @{
            type = 'entities'
            title = 'Bridge update available'
            entities = @(
                @{ entity = 'update.agent_bridge_update'; name = 'Version' }
                @{ entity = 'button.agent_bridge_install_update'; name = 'Install now' }
            )
        }
    }

    $newSessionRows = @()
    # Resume first: it decides whether the rows under it even apply. Defaults to
    # "New session", so the common case reads top-to-bottom as a fresh launch.
    if ($IncludeResume) {
        $newSessionRows += @{ entity = 'select.agent_bridge_new_resume'; name = 'Resume' }
    }
    $newSessionRows += @{ entity = 'select.agent_bridge_new_workspace'; name = 'Workspace' }
    # The profile row is only meaningful when Agency is the launcher, so it is left
    # out entirely rather than shown as a control that does nothing.
    if ($IncludeProfile) {
        $newSessionRows += @{ entity = 'select.agent_bridge_new_profile'; name = 'Profile' }
    }
    # Launch sits directly under the selectors, because they all carry a default and
    # a launch therefore needs no input at all - open the card, press Launch. The
    # opening prompt is genuinely optional and goes last so it stays out of that path.
    $newSessionRows += @(
        @{ entity = 'button.agent_bridge_new_session'; name = 'Launch' }
        @{ entity = 'sensor.agent_bridge_new_session_result'; name = 'Last launch' }
        @{ entity = 'text.agent_bridge_new_prompt'; name = 'Opening prompt (optional)' }
    )

    # Starting a new session. Placed with the controls rather than among the session
    # cards because it belongs to the bridge, not to any one session, and it stays
    # visible when nothing is running at all - which is exactly when it is needed.
    $newSessionCard = @{
        type = 'entities'
        title = 'Start a new session'
        show_header_toggle = $false
        entities = $newSessionRows
    }

    # The control panel is a plain card pair at the top of the masonry flow.
    $controlCards = @($agentSessionsCard, $updateCard, $newSessionCard)

    $sessionSections = foreach ($session in $Sessions) {
        $node = $session.Node

        # An MCP client publishes only a decision, a reply and a status - it never
        # sees a transcript, so there is no activity, no per-field dropdowns and no
        # submit button. Rendering it with the full template would produce six
        # "Entity not found" rows, so it gets a reduced card instead.
        $isMcp = ($session.PSObject.Properties.Name -contains 'Kind' -and [string]$session.Kind -eq 'mcp')
        if ($isMcp) {
            @{
                type = 'grid'
                square = $false
                columns = 1
                cards = @(
                    @{
                        type = 'markdown'
                        content = "### 🔌 $($session.Name)`n*MCP client* &bull; {{ states('sensor.${node}_status') }}"
                    }
                    @{
                        type = 'entities'
                        entities = @(
                            @{ entity = "select.${node}_decision"; name = 'Answer' }
                            @{ entity = "text.${node}_reply"; name = 'Reply' }
                        )
                    }
                )
            }
            continue
        }

        $statusEntity = "sensor.${node}_status"
        $activityEntity = "sensor.${node}_activity"
        $decisionEntity = "select.${node}_decision"
        $replyEntity = "text.${node}_reply"

        # The whole session is one card, not five stacked ones.
        #
        # Previously the chrome was inconsistent: the header carried the border and
        # glow, the answer and end rows drew their own default card backgrounds, and
        # the reply row was bare. Four different treatments in a column read as four
        # loose cards rather than one session.
        #
        # So the border, background and state glow move to the stack itself, every
        # child is stripped bare, and the stack's inter-card margins are collapsed.
        # `overflow: hidden` keeps the children's square corners inside the rounded
        # outer edge.
        $sessionCardStyle = @"
:host {
  display: block;
  border-radius: var(--ha-card-border-radius, 12px);
  background: var(--ha-card-background, var(--card-background-color, #fff));
  overflow: hidden;
  padding: 4px 12px 10px 12px;
  box-sizing: border-box;
  {% if state_attr('$decisionEntity','question') %}
  border: 1px solid var(--warning-color);
  animation: cpwait 1.6s ease-in-out infinite;
  {% elif is_state('$statusEntity','working') %}
  border: 1px solid var(--primary-color);
  animation: cpwork 1.6s ease-in-out infinite;
  {% else %}
  border: 1px solid var(--divider-color);
  box-shadow: none;
  animation: none;
  {% endif %}
  transition: border 0.4s ease;
}
/* Collapse the 8px the stack puts between children, so the sections butt together
   as one surface instead of floating apart. */
#root > * {
  margin-top: 0 !important;
  margin-bottom: 0 !important;
}
@keyframes cpwork {
  0%   { box-shadow: 0 0 6px 0px var(--primary-color); }
  50%  { box-shadow: 0 0 16px 2px var(--primary-color); }
  100% { box-shadow: 0 0 6px 0px var(--primary-color); }
}
@keyframes cpwait {
  0%   { box-shadow: 0 0 6px 0px var(--warning-color); }
  50%  { box-shadow: 0 0 18px 3px var(--warning-color); }
  100% { box-shadow: 0 0 6px 0px var(--warning-color); }
}
"@

        # Every child is transparent now - the stack above provides the one surface
        # they all sit on. Without this each card draws its own background and the
        # column goes back to looking like separate cards.
        $bareChild = @"
ha-card {
  border: none !important;
  box-shadow: none !important;
  background: none !important;
  margin: 0 !important;
  padding: 0 !important;
  width: 100%;
}
.card-content { padding: 0 !important; }
"@

        # The Answer and per-field dropdowns are styled to line up with the reply box
        # below them. They carried a leading icon, which indented the row, and let the
        # control hug the right edge - the exact opposite of the reply box, which
        # starts hard against the card's left edge and fills the width. Dropping the
        # icon aligns the left edges; stretching the select makes both controls span
        # the same area.
        #
        # The label is kept, unlike the reply box's: with several dropdowns stacked,
        # the field name is the only thing telling them apart.
        $selectRow = @{
            '.' = ':host { --mdc-icon-size: 0px; }'
            'hui-generic-entity-row$' = @'
state-badge { display: none !important; }
.info { flex: 0 1 auto; margin-right: 12px; }
'@
        }
        $selectRowCard = @"
$bareChild
ha-select, mwc-select { width: 100%; }
"@

        # The collapsed card always carries the whole thing: the full question when one
        # is waiting, otherwise the full text of the last response. The expander holds
        # only supporting detail - the model's reasoning when Detailed activity is on, and
        # the recent activity trail otherwise - so opening it is never required to read
        # what was actually asked or answered.
        $header = @{
            type = 'markdown'
            card_mod = @{ style = $bareChild }
            content = @"
### {% if state_attr('$decisionEntity','question') %}🟡{% elif is_state('$statusEntity','working') %}🟢{% else %}⚪{% endif %} $($session.Name)
*$($session.Machine)* &bull; status: **{% if state_attr('$decisionEntity','question') %}waiting for you{% else %}{{ states('$statusEntity') }}{% endif %}** &bull; {{ states('$activityEntity') }}
{% set q = state_attr('$decisionEntity','question') %}{% set resp = state_attr('$activityEntity','response') %}{% if q %}

---
**Waiting on you:**

{{ q }}{% elif resp %}

{{ resp }}{% endif %}
{% set r = state_attr('$activityEntity','reasoning') %}{% set hist = state_attr('$activityEntity','history') %}{% if r %}<details><summary><em>🧠 reasoning</em></summary>

{{ r }}
</details>{% elif hist %}<details><summary><em>recent activity</em></summary>

{% for h in hist[-8:] %}- {{ h }}
{% endfor %}
</details>{% endif %}
"@
        }

        # The Answer control is shown only while a question is actually waiting. The
        # selector is optimistic, so the bridge drives its state to 'Awaiting answer...'
        # when arming and 'Idle' when clearing; keying off that state is what makes the
        # control appear exactly when it is usable. (An earlier version also excluded
        # 'Awaiting answer...', which hid the dropdown precisely when it was needed.)
        $answerCard = @{
            type = 'conditional'
            conditions = @(
                @{ condition = 'state'; entity = $decisionEntity; state_not = 'Idle' }
                @{ condition = 'state'; entity = $decisionEntity; state_not = 'unknown' }
                @{ condition = 'state'; entity = $decisionEntity; state_not = 'unavailable' }
            )
            card = @{
                type = 'entities'
                show_header_toggle = $false
                card_mod = @{ style = $selectRowCard }
                entities = @(@{ entity = $decisionEntity; name = 'Answer'; card_mod = @{ style = $selectRow } })
            }
        }

        # A multi-field question publishes one dropdown per field. Each is shown only
        # while it actually carries options (its state is not 'Idle'), so a question
        # with two fields shows exactly two dropdowns and the unused slots stay hidden.
        # The name is deliberately omitted: an entities card's `name` is not templated,
        # so a Jinja expression there renders as literal text. The bridge instead sets
        # each dropdown's MQTT name to the field's own label, and the card inherits it.
        $fieldCards = foreach ($fi in 1..4) {
            $fe = "select.${node}_f$fi"
            @{
                type = 'conditional'
                conditions = @(
                    @{ condition = 'state'; entity = $fe; state_not = 'Idle' }
                    @{ condition = 'state'; entity = $fe; state_not = 'unknown' }
                    @{ condition = 'state'; entity = $fe; state_not = 'unavailable' }
                )
                card = @{
                    type = 'entities'
                    show_header_toggle = $false
                    card_mod = @{ style = $selectRowCard }
                    entities = @(@{ entity = $fe; card_mod = @{ style = $selectRow } })
                }
            }
        }

        # Reply box and Send side by side as one control. layout-card's grid gives an
        # exact "text fills the row, button is a fixed 56px column" split - a
        # horizontal-stack splits 50/50, which left a huge button beside a cramped
        # field. Each child is styled directly with card-mod rather than trying to
        # pierce the stack from its parent, which is what failed before.
        #
        # Send is what commits a reply. Home Assistant commits a text entity as soon as
        # the field loses focus, so acting on the value alone fired the moment you
        # clicked away - easy to trigger by accident and impossible to take back.
        # The row's leading icon and the card's own padding pushed the text field well
        # right of the card above it, and made the pair sit lower than the button.
        # Dropping both lines the field's left edge up with the cards above and lets
        # align-items centre the two controls against each other.
        #
        # The icon lives inside hui-generic-entity-row's shadow root, so it needs
        # card-mod's map form with a "$" suffixed selector to reach it - plain CSS in a
        # style string cannot pierce a shadow boundary.
        $bare = @"
ha-card {
  border: none;
  box-shadow: none;
  background: none;
  margin: 0;
  width: 100%;
  padding: 0;
}
.card-content { padding: 0 !important; }
"@
        $noIcon = @{
            '.' = ':host { --mdc-icon-size: 0px; }'
            'hui-generic-entity-row$' = 'state-badge { display: none !important; } .info { display: none !important; }'
        }

        $replyCard = @{
            type = 'custom:layout-card'
            layout_type = 'custom:grid-layout'
            layout = @{
                'grid-template-columns' = '1fr 56px'
                'grid-gap' = '0px'
                # align-items centres the pair vertically; justify-items must stay
                # stretch or the text field shrinks to its content width and floats in
                # the middle of the row instead of filling it.
                'align-items' = 'center'
                'justify-items' = 'stretch'
                margin = '6px 0 0 0'
            }
            cards = @(
                @{
                    type = 'entities'
                    show_header_toggle = $false
                    card_mod = @{ style = $bare }
                    entities = @(@{
                        entity = $replyEntity
                        name = 'Reply / continue'
                        card_mod = @{ style = $noIcon }
                    })
                }
                @{
                    type = 'custom:button-card'
                    entity = "button.${node}_submit"
                    icon = 'mdi:send'
                    show_name = $false
                    show_state = $false
                    size = '22px'
                    tap_action = @{ action = 'toggle' }
                    styles = @{
                        card = @(
                            @{ height = '48px' }
                            @{ width = '48px' }
                            @{ border = 'none' }
                            @{ 'box-shadow' = 'none' }
                            @{ background = 'none' }
                            @{ padding = '0' }
                        )
                        # button-card lays its contents out on an internal grid that
                        # still reserves a row for the (hidden) name, which floats the
                        # icon above the card's true centre. Collapsing the grid to a
                        # single centred cell puts it in the middle.
                        grid = @(
                            @{ 'grid-template-areas' = '"i"' }
                            @{ 'grid-template-rows' = '1fr' }
                            @{ 'grid-template-columns' = '1fr' }
                            @{ 'place-items' = 'center' }
                        )
                        img_cell = @(
                            @{ 'align-self' = 'center' }
                            @{ 'justify-self' = 'center' }
                            @{ margin = '0' }
                            @{ padding = '0' }
                        )
                        icon = @(@{ color = 'var(--primary-color)' })
                    }
                }
            )
        }

        # Ending the session, as a footer action rather than another control in the
        # stack of controls.
        #
        # It used to be a full-width row directly beneath the reply box, which put it
        # immediately under Send - the one button you tap most, and the one you least
        # want to miss. Send sits at the right edge of the row above, so End is pinned
        # to the left and rendered small and muted: furthest from Send, and clearly
        # secondary to everything above it.
        #
        # The hairline above it does double duty - it separates End from Send, and it
        # closes the card off as a footer, which is what makes the whole thing read as
        # one unit rather than a column that simply stops.
        $stopCard = @{
            type = 'custom:button-card'
            entity = "button.${node}_stop"
            name = 'End session'
            icon = 'mdi:stop-circle-outline'
            show_state = $false
            tap_action = @{ action = 'toggle' }
            styles = @{
                card = @(
                    @{ background = 'none' }
                    @{ border = 'none' }
                    @{ 'border-top' = '1px solid var(--divider-color)' }
                    @{ 'border-radius' = '0' }
                    @{ 'box-shadow' = 'none' }
                    @{ height = 'auto' }
                    @{ padding = '8px 0 0 0' }
                    @{ 'margin-top' = '10px' }
                )
                # Icon and label on one left-aligned row. Without collapsing
                # button-card's default grid the label stacks under the icon and
                # centres itself, which reads as a primary action rather than a
                # footer link.
                grid = @(
                    @{ 'grid-template-areas' = '"i n"' }
                    @{ 'grid-template-columns' = 'min-content auto' }
                    @{ 'grid-template-rows' = 'auto' }
                    @{ 'justify-items' = 'start' }
                    @{ 'align-items' = 'center' }
                    @{ 'grid-gap' = '6px' }
                )
                img_cell = @(
                    @{ 'justify-self' = 'start' }
                    @{ margin = '0' }
                    @{ padding = '0' }
                )
                icon = @(
                    @{ color = 'var(--secondary-text-color)' }
                    @{ width = '17px' }
                )
                name = @(
                    @{ 'font-size' = '12px' }
                    @{ color = 'var(--secondary-text-color)' }
                    @{ 'justify-self' = 'start' }
                    @{ 'text-align' = 'left' }
                )
            }
        }

        # Each session is a vertical stack of its own cards. In a masonry view these
        # stacks are packed into columns by height rather than aligned into rows, which
        # is what stops one tall session from leaving dead space under every shorter
        # card beside it.
        @{
            type = 'vertical-stack'
            card_mod = @{ style = $sessionCardStyle }
            cards = @($header) + @($fieldCards) + @($answerCard, $replyCard, $stopCard)
        }
    }

    $sessionSections = @($sessionSections)
    if ($sessionSections.Count -eq 0) {
        $sessionSections = @(@{
            type = 'markdown'
            content = 'No live agent sessions right now.'
        })
    }

    # A masonry view, not a sections view. The sections view lays its sections out on a
    # CSS grid that aligns them into rows, so a single tall session card left a column
    # of dead space under every shorter card beside it. Masonry packs cards into
    # columns by height instead, so cards of very different lengths - which is normal
    # here, since a card carries a whole response - sit flush against each other.
    $config = @{
        title = 'Agent Sessions'
        views = @(@{
            title = 'Sessions'
            path = 'decision'
            type = 'masonry'
            cards = @($controlCards) + $sessionSections
        })
    }

    [void](Invoke-CopilotHaWebSocket -Commands @(
        @{
            type = 'lovelace/config/save'
            url_path = $script:DecisionBridgeConfig.DashboardUrlPath
            config = $config
        }
    ))
}

function Set-CopilotMqttEntityIds {
    <#
        Forces the bridge's MQTT entities onto deterministic, node-based entity_ids.

        Without this the ids follow the session's display name, so renaming a session
        would silently move every entity and strand any dashboard card pointing at
        the old id.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    $current = Resolve-CopilotMqttEntityIds -SessionId $SessionId

    $targets = @{
        Decision = "select.${node}_decision"
        Reply = "text.${node}_reply"
        Status = "sensor.${node}_status"
        Activity = "sensor.${node}_activity"
    }
    # Per-field dropdowns for multi-field questions share the same treatment.
    for ($i = 1; $i -le 4; $i++) { $targets["Field$i"] = "select.${node}_f$i" }
    $targets['Submit'] = "button.${node}_submit"
    $targets['Stop'] = "button.${node}_stop"

    $commands = @()
    foreach ($key in @($targets.Keys)) {
        if (-not $current.ContainsKey($key)) { continue }
        if ($current[$key] -eq $targets[$key]) { continue }
        $commands += @{
            type = 'config/entity_registry/update'
            entity_id = $current[$key]
            new_entity_id = $targets[$key]
        }
    }

    if ($commands.Count -gt 0) {
        [void](Invoke-CopilotHaWebSocket -Commands $commands)
    }

    $targets
}


