<#
    Shared configuration and helpers for the Copilot <-> Home Assistant bridge.

    Machine-specific settings live in a JSON config file outside this folder, because
    Copilot parses every *.json under ~/.copilot/hooks as a hook definition and logs a
    startup error for anything that is not one. Resolution order:

        1. $env:COPILOT_HA_BRIDGE_CONFIG            (explicit override)
        2. ~/.copilot/copilot-ha-bridge.config.json (what install.ps1 writes)

    Everything in the file is optional; anything absent falls back to the defaults
    below. See config.example.json in the repository root.
#>

function Get-BridgeUserConfig {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:COPILOT_HA_BRIDGE_CONFIG)) {
        $candidates += $env:COPILOT_HA_BRIDGE_CONFIG
    }
    $candidates += (Join-Path $HOME '.copilot\copilot-ha-bridge.config.json')

    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) { return ($raw | ConvertFrom-Json) }
        }
        catch {
            throw "Copilot HA bridge config at '$path' is not valid JSON: $($_.Exception.Message)"
        }
    }
    $null
}

$script:BridgeUserConfig = Get-BridgeUserConfig

function Get-BridgeSetting {
    <#
        Reads a dotted path out of the user config, returning $Default when the file,
        the section or the value is absent.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        $Default = $null
    )

    $node = $script:BridgeUserConfig
    if ($null -eq $node) { return $Default }
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $node) { return $Default }
        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop) { return $Default }
        $node = $prop.Value
    }
    if ($null -eq $node) { return $Default }
    if ($node -is [string] -and [string]::IsNullOrWhiteSpace($node)) { return $Default }
    $node
}

$script:DecisionBridgeConfig = @{
    # --- machine specific, overridable from the config file -------------------
    HomeAssistantBaseUrl = (Get-BridgeSetting 'homeAssistant.baseUrl' 'http://homeassistant.local:8123')
    HomeAssistantToken = (Get-BridgeSetting 'homeAssistant.token' '')
    HomeAssistantTokenEnvVar = (Get-BridgeSetting 'homeAssistant.tokenEnvVar' 'COPILOT_HA_TOKEN')
    SessionStateRoot = (Get-BridgeSetting 'copilot.sessionStateRoot' (Join-Path $HOME '.copilot\session-state'))
    DashboardUrlPath = (Get-BridgeSetting 'dashboard.urlPath' 'copilot-decisions')
    DashboardPath = ('/' + (Get-BridgeSetting 'dashboard.urlPath' 'copilot-decisions') + '/decision')
    # Notifications are optional. `service` is any HA notify-style service, e.g.
    # notify.notify, notify.mobile_app_pixel, or ticker.notify.
    NotifyEnabled = [bool](Get-BridgeSetting 'notifications.enabled' $false)
    NotifyService = (Get-BridgeSetting 'notifications.service' 'notify.notify')
    TickerCategory = (Get-BridgeSetting 'notifications.tickerCategory' '')

    # --- behaviour, rarely changed -------------------------------------------
    DecisionQuestionMaxChars = 6000
    DecisionChoiceMaxChars = 600
    ResponsePlaceholder = 'Select an answer...'
    CancelOption = 'Cancel request'
    LogFile = (Join-Path $env:TEMP 'copilot-decision-bridge.log')
    HttpRetryCount = 4
    HttpRetryInitialDelayMs = 400
    # How long the ask_user wait tolerates an unreachable Home Assistant before it
    # gives up. A restart of Home Assistant takes well under this.
    WaitTransientFailureGraceMinutes = 5
}

function Test-DecisionTransientHttpError {
    <#
        True for the failures a Home Assistant restart produces - connection refused,
        timeouts, DNS blips and 5xx - as opposed to a real error like a bad token or a
        missing entity, which retrying cannot fix.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response) {
        $status = 0
        try { $status = [int]$response.StatusCode } catch { $status = 0 }
        if ($status -ge 500 -or $status -eq 429) { return $true }
        if ($status -gt 0) { return $false }
    }

    $message = [string]$ErrorRecord.Exception.Message
    foreach ($pattern in @(
        'actively refused',
        'Unable to connect',
        'timed out',
        'HttpClient\.Timeout',
        'The operation has timed out',
        'Unable to read data from the transport connection',
        'The underlying connection was closed',
        'An existing connection was forcibly closed',
        'No such host is known'
    )) {
        if ($message -match $pattern) { return $true }
    }

    $false
}

# No deadline unless a caller sets one. This must be initialised rather than left
# undefined: under Set-StrictMode -Version Latest, reading an unset variable throws,
# which would make every caller that does not set a budget - the daemon included -
# fail inside the retry layer.
$script:DecisionBridgeDeadline = $null

function Test-HomeAssistantReachable {    <#
        Cheap liveness probe, used by hooks before they commit to any Home Assistant
        work.

        A flat budget cannot serve both cases: the healthy publish path legitimately
        takes many seconds (discovery, a registry rename over WebSocket, then arming),
        while an unreachable host must not cost more than a moment because a PreToolUse
        hook runs before the native prompt appears. Probing first separates them - a
        host that is gone is detected in about a second, and only a host that answers
        earns the longer budget.

        Deliberately single-shot with no retry: this is a reachability question, not a
        request worth salvaging.
    #>
    param([int]$TimeoutSec = 2)

    try {
        $null = Invoke-RestMethod -Uri "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/" `
            -Headers (Get-HomeAssistantHeaders) -TimeoutSec $TimeoutSec
        return $true
    }
    catch {
        return $false
    }
}

function Set-DecisionBridgeDeadline {
    <#
        Bounds how long the Home Assistant calls in this process may take in total.

        The retry layer exists so a blip cannot break a live question, but in a hook
        that resilience becomes latency: with Home Assistant unreachable the routers
        took 19-34 seconds, and a PreToolUse hook that slow delays the very prompt the
        bridge promises never to block. Hooks therefore set a hard budget and fail open
        the moment it is spent; the daemon, which has time, sets none.

        Pass 0 to clear it.
    #>
    param([Parameter(Mandatory)][int]$Seconds)

    $script:DecisionBridgeDeadline = if ($Seconds -gt 0) {
        [DateTimeOffset]::Now.AddSeconds($Seconds)
    } else { $null }
}

function Get-DecisionBridgeRemainingSeconds {
    if ($null -eq $script:DecisionBridgeDeadline) { return [double]::PositiveInfinity }
    [Math]::Max(0, ($script:DecisionBridgeDeadline - [DateTimeOffset]::Now).TotalSeconds)
}

function Invoke-DecisionHttpRequest {
    <#
        Wraps Invoke-RestMethod with bounded exponential backoff.

        Without this a single transient failure - a Home Assistant restart, a Wi-Fi
        blip - propagated out of the eight hour ask_user wait, the hook failed open,
        and the CLI re-prompted the same question while the dashboard card was still
        live. Two answer paths for one question.

        When a deadline is set the retries are also bounded by wall clock, and each
        request's own timeout is clamped to what is left, so the caller can never
        overrun its budget waiting on a host that is simply gone.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Parameters,

        [int]$RetryCount = $script:DecisionBridgeConfig.HttpRetryCount
    )

    $delayMs = $script:DecisionBridgeConfig.HttpRetryInitialDelayMs
    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        $remaining = Get-DecisionBridgeRemainingSeconds
        if ($remaining -le 0) {
            throw [TimeoutException]::new('Home Assistant budget for this hook is spent.')
        }

        $call = $Parameters
        if ([double]::IsFinite($remaining)) {
            $call = @{} + $Parameters
            $requested = if ($call.ContainsKey('TimeoutSec')) { [int]$call['TimeoutSec'] } else { 15 }
            $call['TimeoutSec'] = [Math]::Max(1, [Math]::Min($requested, [int][Math]::Floor($remaining)))
        }

        try {
            return Invoke-RestMethod @call
        }
        catch {
            $isLast = $attempt -ge $RetryCount
            if ($isLast -or -not (Test-DecisionTransientHttpError -ErrorRecord $_)) {
                throw
            }
            # No point sleeping into a deadline that will already have passed.
            if ((Get-DecisionBridgeRemainingSeconds) * 1000 -le $delayMs) {
                throw [TimeoutException]::new('Home Assistant budget for this hook is spent.')
            }
            Start-Sleep -Milliseconds $delayMs
            $delayMs = [Math]::Min($delayMs * 2, 5000)
        }
    }
}

function Write-DecisionBridgeLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $timestamp = [DateTimeOffset]::Now.ToString('o')
    Add-Content -LiteralPath $script:DecisionBridgeConfig.LogFile -Value "$timestamp $Message"
}

function Split-CardText {
    <#
        Splits long card text into a short preview and the remainder, breaking on a
        paragraph boundary (then a sentence, then a word) rather than mid-word, so the
        dashboard's expandable "show more" never cuts through the middle of a word.

        Returns a hashtable with Preview and Rest. When the text is already short, Rest
        is empty and the whole text is the preview.
    #>
    param(
        [AllowNull()][string]$Text,
        [int]$TargetChars = 260
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @{ Preview = ''; Rest = '' }
    }
    $t = ($Text -replace "`r`n", "`n").Trim()
    if ($t.Length -le $TargetChars) {
        return @{ Preview = $t; Rest = '' }
    }

    $split = Split-CardTextCore -Text $t -TargetChars $TargetChars

    # A split that lands inside a fenced code block leaves the preview holding an
    # unclosed ``` fence, so everything after it - including the <details> markup the
    # card wraps the remainder in - renders as literal code. Close the fence at the end
    # of the preview and reopen it at the start of the remainder so both halves are
    # valid markdown on their own.
    $fenceCount = ([regex]::Matches($split.Preview, '(?m)^\s*```')).Count
    if ($fenceCount % 2 -eq 1) {
        $fence = '```'
        $split.Preview = $split.Preview.TrimEnd() + "`n" + $fence
        if (-not [string]::IsNullOrWhiteSpace($split.Rest)) {
            $split.Rest = $fence + "`n" + $split.Rest
        }
    }

    $split
}

function Split-CardTextCore {
    <#
        The paragraph/sentence/word boundary search behind Split-CardText. Kept
        separate so the fence-balancing above can post-process its result.
    #>
    param(
        [AllowNull()][string]$Text,
        [int]$TargetChars = 260
    )

    $t = $Text

    # Prefer whole paragraphs: keep adding paragraphs to the preview while they fit
    # under the target (with a little slack), so the break lands between paragraphs.
    $paragraphs = @(
        [regex]::Split($t, "`n\s*`n") | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' }
    )
    $slack = 140
    if ($paragraphs.Count -gt 1) {
        $preview = ''
        $restList = New-Object System.Collections.Generic.List[string]
        $filling = $true
        foreach ($p in $paragraphs) {
            if ($filling) {
                if ($preview -eq '') {
                    $preview = $p
                }
                elseif (($preview.Length + 2 + $p.Length) -le ($TargetChars + $slack)) {
                    $preview = "$preview`n`n$p"
                }
                else {
                    $filling = $false
                    $restList.Add($p)
                }
            }
            else {
                $restList.Add($p)
            }
        }
        if ($restList.Count -gt 0) {
            return @{ Preview = $preview.Trim(); Rest = ($restList -join "`n`n").Trim() }
        }
        # One big paragraph absorbed everything; fall through to break it below.
        $t = $preview
    }

    # A single long paragraph: break at the last sentence end, else the last space,
    # within a window around the target, so no word is split.
    $windowEnd = [Math]::Min($t.Length, $TargetChars + $slack)
    $window = $t.Substring(0, $windowEnd)
    $floor = [Math]::Max(1, $TargetChars - $slack)

    $cut = -1
    foreach ($m in [regex]::Matches($window, '[.!?]["'')\]]?\s')) {
        if ($m.Index + 1 -ge $floor) { $cut = $m.Index + $m.Length; break }
    }
    if ($cut -lt 0) {
        $sp = $window.LastIndexOf(' ')
        if ($sp -ge $floor) { $cut = $sp }
    }
    if ($cut -lt 0) { $cut = $TargetChars }

    @{ Preview = $t.Substring(0, $cut).Trim(); Rest = $t.Substring($cut).Trim() }
}

function Repair-DecisionTextEncoding {
    param(
        [AllowNull()]
        [string]$Text
    )

    if (
        [string]::IsNullOrEmpty($Text) -or
        $Text -notmatch 'ΓÇ|Γé|├|┬|ÔÇ'
    ) {
        return $Text
    }

    try {
        $bytes = [Text.Encoding]::GetEncoding(437).GetBytes($Text)
        $decoded = [Text.Encoding]::UTF8.GetString($bytes)
        if ($decoded.Contains([char]0xFFFD)) {
            return $Text
        }
        return $decoded
    }
    catch {
        return $Text
    }
}

function ConvertFrom-DecisionChoiceList {
    <#
        Parses a leaked `choices` payload, which arrives as the JSON array literal the
        model meant to pass as a real argument. Falls back to scanning complete quoted
        strings when the array is unterminated, because a tool call cut off mid-write
        is exactly the case this recovers from.
    #>
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $start = $Text.IndexOf('[')
    if ($start -lt 0) {
        return @()
    }
    $payload = $Text.Substring($start)

    $end = $payload.LastIndexOf(']')
    if ($end -gt 0) {
        try {
            # Windows PowerShell 5.1 emits a parsed JSON array as a single nested
            # object rather than unrolling it, so flatten one level explicitly.
            $parsed = $payload.Substring(0, $end + 1) | ConvertFrom-Json
            $items = New-Object System.Collections.Generic.List[string]
            foreach ($entry in @($parsed)) {
                if ($entry -is [System.Collections.IEnumerable] -and $entry -isnot [string]) {
                    foreach ($inner in $entry) {
                        $items.Add([string]$inner)
                    }
                }
                else {
                    $items.Add([string]$entry)
                }
            }

            $items = @($items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($items.Count -gt 0) {
                return $items
            }
        }
        catch {
            # Malformed JSON falls through to the lenient scan below.
        }
    }

    $quoted = [regex]::Matches($payload, '"((?:[^"\\]|\\.)*)"')
    $recovered = foreach ($item in $quoted) {
        $value = $item.Groups[1].Value
        try {
            [string]("`"$value`"" | ConvertFrom-Json)
        }
        catch {
            $value -replace '\\"', '"' -replace '\\\\', '\'
        }
    }

    @($recovered | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function ConvertFrom-DecisionRequestedSchema {
    <#
        Derives a choice list from an `ask_user` `requestedSchema`.

        Current Copilot CLI builds pass `message` + `requestedSchema` (a JSON Schema
        form) instead of the older `question` + `choices` pair. Without this the bridge
        found no `choices`, published a free-text box for what was really a multiple
        choice, and — because it also found no `question` — titled the card
        "Copilot CLI needs your input."

        The dashboard renders one question with one option list, so only a
        single-field form can become choice buttons. Multi-field forms and free-text
        fields deliberately return nothing and stay freeform.
    #>
    param(
        [AllowNull()]
        [psobject]$Schema
    )

    if ($null -eq $Schema) { return @() }
    $properties = $Schema.properties
    if ($null -eq $properties) { return @() }

    $names = @($properties.PSObject.Properties.Name)
    if ($names.Count -ne 1) { return @() }

    @(Get-DecisionSchemaFieldOptions -Field $properties.($names[0]))
}

function ConvertFrom-DecisionSchemaText {
    <#
        Parses a `requestedSchema` payload that leaked into the question string as raw
        text, including the common case where the tool call was cut off mid-write and
        the JSON is unterminated. Unbalanced braces and brackets are closed off before
        parsing, which is enough to recover the option list from a truncated form.
    #>
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $start = $Text.IndexOf('{')
    if ($start -lt 0) { return $null }
    $payload = $Text.Substring($start)

    # Walk the payload tracking string state so closers inside strings are ignored.
    $stack = New-Object System.Collections.Generic.Stack[char]
    $inString = $false
    $escaped = $false
    $lastSafe = -1
    for ($i = 0; $i -lt $payload.Length; $i++) {
        $ch = $payload[$i]
        if ($escaped) { $escaped = $false; continue }
        if ($ch -eq '\') { if ($inString) { $escaped = $true }; continue }
        if ($ch -eq '"') { $inString = -not $inString; continue }
        if ($inString) { continue }

        switch ($ch) {
            '{' { $stack.Push('}') }
            '[' { $stack.Push(']') }
            '}' { if ($stack.Count -gt 0) { [void]$stack.Pop() } }
            ']' { if ($stack.Count -gt 0) { [void]$stack.Pop() } }
        }
        if ($stack.Count -eq 0) { $lastSafe = $i }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($lastSafe -ge 0) {
        $candidates.Add($payload.Substring(0, $lastSafe + 1))
    }
    if ($stack.Count -gt 0) {
        # Trim a dangling partial token, then close every open container.
        $trimmed = $payload.TrimEnd()
        $trimmed = $trimmed -replace '(?s),\s*"[^"]*"?\s*:?\s*$', ''
        $trimmed = $trimmed -replace '(?s),\s*$', ''
        if ($inString) { $trimmed += '"' }
        $closers = ($stack.ToArray() -join '')
        $candidates.Add($trimmed + $closers)
    }

    foreach ($candidate in $candidates) {
        try {
            $parsed = $candidate | ConvertFrom-Json
            if ($null -ne $parsed) { return $parsed }
        }
        catch {
            continue
        }
    }

    $null
}

function Get-DecisionSchemaFieldOptions {
    <#
        Option list for a single JSON-Schema field, or an empty array for free text.
    #>
    param(
        [AllowNull()]
        [psobject]$Field
    )

    if ($null -eq $Field) { return @() }
    $options = @()

    if ($null -ne $Field.enum) {
        $values = @($Field.enum | ForEach-Object { [string]$_ })
        $labels = @()
        if ($null -ne $Field.enumNames) {
            $labels = @($Field.enumNames | ForEach-Object { [string]$_ })
        }
        for ($index = 0; $index -lt $values.Count; $index++) {
            if (
                $index -lt $labels.Count -and
                -not [string]::IsNullOrWhiteSpace($labels[$index])
            ) {
                $options += $labels[$index]
            }
            else {
                $options += $values[$index]
            }
        }
        return @($options | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($null -ne $Field.oneOf) {
        foreach ($option in @($Field.oneOf)) {
            $label = [string]$option.title
            if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$option.const }
            if (-not [string]::IsNullOrWhiteSpace($label)) { $options += $label }
        }
        return @($options)
    }

    if ($null -ne $Field.items) {
        if ($null -ne $Field.items.enum) {
            return @(
                $Field.items.enum |
                    ForEach-Object { [string]$_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        }
        if ($null -ne $Field.items.anyOf) {
            foreach ($option in @($Field.items.anyOf)) {
                $label = [string]$option.title
                if ([string]::IsNullOrWhiteSpace($label)) { $label = [string]$option.const }
                if (-not [string]::IsNullOrWhiteSpace($label)) { $options += $label }
            }
            return @($options)
        }
        return @()
    }

    if ([string]$Field.type -eq 'boolean') { return @('Yes', 'No') }

    @()
}

function Format-DecisionSchemaOutline {
    <#
        Renders a multi-field form as readable text to append to the question.

        A card shows one question with one option list, so a multi-field form cannot
        become buttons. It used to publish a bare text box with no hint of what the
        options were, which is unanswerable from a phone. Spelling the fields and
        their options out in the question body keeps the freeform answer while making
        it obvious what can be typed.
    #>
    param(
        [AllowNull()]
        [psobject]$Schema
    )

    if ($null -eq $Schema -or $null -eq $Schema.properties) { return '' }
    $names = @($Schema.properties.PSObject.Properties.Name)
    if ($names.Count -le 1) { return '' }

    $lines = New-Object System.Collections.Generic.List[string]
    $fieldNumber = 0
    foreach ($name in $names) {
        $field = $Schema.properties.$name
        $label = [string]$field.title
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $name }
        $fieldNumber++

        $options = @(Get-DecisionSchemaFieldOptions -Field $field)
        if ($options.Count -gt 0) {
            $lines.Add("$fieldNumber. $label")
            $default = [string]$field.default
            foreach ($option in $options) {
                $marker = if (
                    -not [string]::IsNullOrWhiteSpace($default) -and
                    $option -eq $default
                ) { ' (default)' } else { '' }
                $lines.Add("   - $option$marker")
            }
        }
        else {
            $lines.Add("$fieldNumber. $label (free text)")
        }
    }

    if ($lines.Count -eq 0) { return '' }
    "Answer these in one message:`n" + ($lines -join "`n")
}

function Test-DecisionFieldIsText {
    <#
        True when a captured field is a free-text box rather than an option list.

        A field with no options is one the user types into. Recorded explicitly rather
        than inferred from an empty Options list everywhere, because that emptiness
        used to mean "unanswerable" and the distinction now matters.
    #>
    param([AllowNull()][object]$Field)

    if ($null -eq $Field) { return $false }
    if ($Field.PSObject.Properties['IsText']) { return [bool]$Field.IsText }
    return (@($Field.Options).Count -eq 0)
}

function Test-DecisionFieldsAnswerable {
    <#
        Whether a captured field set can actually be answered from Home Assistant.

        Answerable means every field maps to a control on the card: a dropdown per
        choice field, and the existing Reply box for a free-text field. That allows at
        most one text field, and no more fields than the card publishes dropdowns for.

        Anything else has to be answered at the terminal. Saying so is the point - the
        bridge used to publish a plain text box for these, and typing into the live
        arrow-key prompt discarded the answer silently.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Fields,
        [int]$MaxFields = 4
    )

    $list = @($Fields)
    if ($list.Count -eq 0 -or $list.Count -gt $MaxFields) { return $false }
    $textCount = @($list | Where-Object { Test-DecisionFieldIsText -Field $_ }).Count
    ($textCount -le 1)
}

function Get-DecisionSchemaFields {
    <#
        Returns the per-field definitions of a requestedSchema, in order.

        The native ask_user prompt renders a multi-field form as tabbed sections -
        "tab next" moves between fields, each with its own arrow-key option list or
        text entry. To answer such a form by injection the bridge needs each field in
        order, so it can compute how many Down presses select a given option, or know
        to type instead.

        Free-text fields are included and flagged, not discarded. Discarding them used
        to throw away the entire form - a single free-text field among four dropdowns
        left the card with no options at all, and the resulting free-text answer was
        swallowed by the live prompt.

        Returns an array of @{ Label; Options; IsText }.
    #>
    param(
        [AllowNull()][psobject]$Schema
    )

    if ($null -eq $Schema -or $null -eq $Schema.properties) { return @() }
    $names = @($Schema.properties.PSObject.Properties.Name)
    if ($names.Count -eq 0) { return @() }

    $fields = @()
    foreach ($name in $names) {
        $field = $Schema.properties.$name
        $label = [string]$field.title
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $name }
        $options = @(Get-DecisionSchemaFieldOptions -Field $field)
        $fields += [pscustomobject]@{
            Label   = $label
            Options = @($options)
            IsText  = ($options.Count -eq 0)
        }
    }
    @($fields)
}

function Get-DecisionSchemaCombos {
    <#
        Turns a small multi-field form into a flat list of combined choices, so it can
        be answered with buttons instead of a free-text outline.

        A form with two fields - say Visibility (Public/Private) and Push (Yes/No) -
        becomes the cartesian product of their options: "Public + Yes", "Public + No",
        "Private + Yes", "Private + No". The user taps one button that answers every
        field at once, and the mapping back to per-field values is carried alongside so
        the answer can be reported to the model in full.

        Returns $null when the form is not suited to this: a single field (handled as a
        plain choice), any free-text field, or a product large enough that the button
        list would be unwieldy.
    #>
    param(
        [AllowNull()]
        [psobject]$Schema,

        [int]$MaxCombos = 12
    )

    if ($null -eq $Schema -or $null -eq $Schema.properties) { return $null }
    $names = @($Schema.properties.PSObject.Properties.Name)
    if ($names.Count -lt 2) { return $null }

    $fields = @()
    $product = 1
    foreach ($name in $names) {
        $field = $Schema.properties.$name
        $label = [string]$field.title
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $name }
        $options = @(Get-DecisionSchemaFieldOptions -Field $field)
        if ($options.Count -eq 0) { return $null }
        $fields += [pscustomobject]@{ Label = $label; Options = $options }
        $product *= $options.Count
    }
    if ($product -lt 2 -or $product -gt $MaxCombos) { return $null }

    # Iteratively expand the cartesian product. Each combo carries an ordered map of
    # field label to chosen option, and a joined display label for the button.
    $combos = @([pscustomobject]@{ Label = ''; Values = [ordered]@{} })
    foreach ($field in $fields) {
        $next = @()
        foreach ($combo in $combos) {
            foreach ($option in $field.Options) {
                $values = [ordered]@{}
                foreach ($k in $combo.Values.Keys) { $values[$k] = $combo.Values[$k] }
                $values[$field.Label] = $option
                $label = if ([string]::IsNullOrEmpty($combo.Label)) { $option } else { "$($combo.Label) + $option" }
                $next += [pscustomobject]@{ Label = $label; Values = $values }
            }
        }
        $combos = $next
    }

    @($combos)
}

function Repair-DecisionToolArguments {
    <#
        Normalises `ask_user` arguments, recovering the multiple-choice case from a
        malformed tool call.

        When the model fails to terminate the tool-call markup, the closing tag and
        every later parameter are swallowed into the `question` string:

            question = "Real question?</question>\n<parameter name=""choices"">[""A"",""B""]"

        `choices` then never arrives as an argument, so the bridge would publish a
        free-text box for what is really a multiple choice, with raw markup showing in
        the card. Splitting the question at the leak and parsing the trailing payload
        restores the intended choice buttons. Real arguments always win over recovered
        ones.

        A small multi-field form is turned into combined choice buttons (the cartesian
        product of its fields) rather than a free-text outline, and the per-field
        breakdown of each combo is returned in `Combos` so the selected button can be
        reported to the model field by field.
    #>
    param(
        [AllowNull()]
        [psobject]$ToolArgs
    )

    $question = ''
    $choices = @()
    $combos = @()
    $fields = @()
    $terminalOnly = $false

    if ($null -ne $ToolArgs) {
        # Current Copilot CLI ask_user passes `message`; older builds passed `question`.
        $rawQuestion = [string]$ToolArgs.message
        if ([string]::IsNullOrWhiteSpace($rawQuestion)) {
            $rawQuestion = [string]$ToolArgs.question
        }
        $question = Repair-DecisionTextEncoding -Text $rawQuestion

        if ($null -ne $ToolArgs.choices) {
            if ($ToolArgs.choices -is [string]) {
                # A choice list handed over as a JSON string rather than an array.
                $choices = @(ConvertFrom-DecisionChoiceList -Text ([string]$ToolArgs.choices))
                if ($choices.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($ToolArgs.choices)) {
                    $choices = @([string]$ToolArgs.choices)
                }
            }
            else {
                $choices = @(
                    $ToolArgs.choices |
                        ForEach-Object { [string]$_ } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
            }
            $choices = @($choices | ForEach-Object { Repair-DecisionTextEncoding -Text $_ })
        }

        # An explicit `choices` argument always wins; otherwise derive the options
        # from the modern `requestedSchema` form.
        if ($choices.Count -eq 0 -and $null -ne $ToolArgs.requestedSchema) {
            $schema = $ToolArgs.requestedSchema
            if ($schema -is [string]) {
                $schema = ConvertFrom-DecisionSchemaText -Text ([string]$schema)
            }
            $schemaChoices = @(ConvertFrom-DecisionRequestedSchema -Schema $schema)
            if ($schemaChoices.Count -gt 0) {
                $choices = @(
                    $schemaChoices | ForEach-Object { Repair-DecisionTextEncoding -Text $_ }
                )
                $fields = @(Get-DecisionSchemaFields -Schema $schema)
            }
            else {
                # A multi-field form is published as one dropdown per field, so the
                # combined cartesian list is no longer used for display - it only
                # remains as the text fallback. Capture the fields; leave $choices
                # empty so nothing flattens into a single unreadable list.
                $schemaFields = Get-DecisionSchemaFields -Schema $schema
                if (@($schemaFields).Count -gt 1 -and (Test-DecisionFieldsAnswerable -Fields $schemaFields)) {
                    $fields = @($schemaFields)
                }
                else {
                    $outline = Format-DecisionSchemaOutline -Schema $schema
                    if (-not [string]::IsNullOrWhiteSpace($outline)) {
                        $question = "$question`n`n$outline"
                    }
                    # A multi-field prompt the card cannot drive must be flagged, not
                    # quietly turned into a text box. The native prompt is an
                    # arrow-key form, and typed characters sent to it are discarded -
                    # the answer disappears and the prompt keeps waiting.
                    if (@($schemaFields).Count -gt 1) { $terminalOnly = $true }
                }
            }
        }
    }

    # Only a closing tag for the question/message parameter, or a `choices` /
    # `requestedSchema` parameter opener, counts as a leak. Matching a bare
    # `<parameter` would truncate any question that merely mentions one.
    $recovered = $false
    if (-not [string]::IsNullOrWhiteSpace($question)) {
        $leakIndex = -1
        foreach ($pattern in @(
            '(?is)</(?:\w+:)?question\s*>',
            '(?is)</(?:\w+:)?message\s*>',
            '(?is)<(?:\w+:)?parameter\s+name\s*=\s*(?:"|'')?choices(?:"|'')?\s*>',
            '(?is)<(?:\w+:)?parameter\s+name\s*=\s*(?:"|'')?requestedSchema(?:"|'')?\s*>'
        )) {
            $match = [regex]::Match($question, $pattern)
            if ($match.Success -and ($leakIndex -lt 0 -or $match.Index -lt $leakIndex)) {
                $leakIndex = $match.Index
            }
        }

        if ($leakIndex -ge 0) {
            $leaked = $question.Substring($leakIndex)
            $question = $question.Substring(0, $leakIndex).TrimEnd()

            if ($choices.Count -eq 0) {
                $block = [regex]::Match(
                    $leaked,
                    '(?is)<(?:\w+:)?parameter\s+name\s*=\s*(?:"|'')?choices(?:"|'')?\s*>(.*)'
                )
                if ($block.Success) {
                    $payload = $block.Groups[1].Value
                    $close = [regex]::Match($payload, '(?is)</(?:\w+:)?parameter\s*>')
                    if ($close.Success) {
                        $payload = $payload.Substring(0, $close.Index)
                    }
                    $choices = @(
                        ConvertFrom-DecisionChoiceList -Text $payload |
                            ForEach-Object { Repair-DecisionTextEncoding -Text $_ }
                    )
                    $recovered = $choices.Count -gt 0
                }
            }

            # The current ask_user shape leaks `requestedSchema`, not `choices`. This
            # was the gap that made a malformed modern tool call publish a free-text
            # box with raw markup instead of the intended buttons.
            if ($choices.Count -eq 0) {
                $block = [regex]::Match(
                    $leaked,
                    '(?is)<(?:\w+:)?parameter\s+name\s*=\s*(?:"|'')?requestedSchema(?:"|'')?\s*>(.*)'
                )
                if ($block.Success) {
                    $payload = $block.Groups[1].Value
                    $close = [regex]::Match($payload, '(?is)</(?:\w+:)?parameter\s*>')
                    if ($close.Success) {
                        $payload = $payload.Substring(0, $close.Index)
                    }
                    $schema = ConvertFrom-DecisionSchemaText -Text $payload
                    if ($null -ne $schema) {
                        $schemaChoices = @(
                            ConvertFrom-DecisionRequestedSchema -Schema $schema
                        )
                        if ($schemaChoices.Count -gt 0) {
                            $choices = @(
                                $schemaChoices |
                                    ForEach-Object { Repair-DecisionTextEncoding -Text $_ }
                            )
                            $recovered = $true
                        }
                        else {
                            $comboList = Get-DecisionSchemaCombos -Schema $schema
                            if ($null -ne $comboList -and @($comboList).Count -gt 0) {
                                $combos = @($comboList)
                                $choices = @(
                                    $combos | ForEach-Object { Repair-DecisionTextEncoding -Text $_.Label }
                                )
                                $recovered = $true
                            }
                            else {
                                $outline = Format-DecisionSchemaOutline -Schema $schema
                                if (-not [string]::IsNullOrWhiteSpace($outline)) {
                                    $question = "$question`n`n$outline"
                                    $recovered = $true
                                }
                            }
                        }
                    }
                }
            }

            # Strip stray closers the truncated call left in the question itself.
            $question = (
                $question -replace
                    '(?is)</?(?:\w+:)?(?:question|message|parameter|invoke|function_calls|antml:\w+)[^>]*>',
                    ''
            ).Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($question)) {
        $question = 'Copilot CLI needs your input.'
    }

    [pscustomobject]@{
        Question = $question
        Choices = @($choices)
        Combos = @($combos)
        Fields = @($fields)
        TerminalOnly = $terminalOnly
        Recovered = $recovered
    }
}

function Get-HomeAssistantHeaders {
    <#
        Resolves the Home Assistant long-lived access token.

        Order: the config file's homeAssistant.token, then the environment variable it
        names in homeAssistant.tokenEnvVar (default COPILOT_HA_TOKEN). The token is
        never stored in the repository - config.json is gitignored.
    #>
    $token = [string]$script:DecisionBridgeConfig.HomeAssistantToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        $envVar = [string]$script:DecisionBridgeConfig.HomeAssistantTokenEnvVar
        if (-not [string]::IsNullOrWhiteSpace($envVar)) {
            $token = [string][Environment]::GetEnvironmentVariable($envVar)
        }
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw ("No Home Assistant token. Set homeAssistant.token in the bridge config " +
            "or the $($script:DecisionBridgeConfig.HomeAssistantTokenEnvVar) environment variable.")
    }

    @{ Authorization = "Bearer $token" }
}

function Invoke-HomeAssistantService {
    param(
        [Parameter(Mandatory)]
        [string]$Domain,

        [Parameter(Mandatory)]
        [string]$Service,

        [Parameter(Mandatory)]
        [hashtable]$Data,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [ValidateRange(1, 60)]
        [int]$TimeoutSec = 15
    )

    $uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/services/$Domain/$Service"
    # Send raw UTF-8 bytes: Windows PowerShell 5.1 encodes a string body with the
    # default codepage unless the charset is spelled out, which corrupts non-ASCII
    # payloads and makes Home Assistant reject the request with a 500.
    $payload = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Depth 10 -Compress))
    Invoke-DecisionHttpRequest -Parameters @{
        Method = 'Post'
        Uri = $uri
        Headers = $Headers
        ContentType = 'application/json; charset=utf-8'
        Body = $payload
        TimeoutSec = $TimeoutSec
    } | Out-Null
}

function Get-HomeAssistantState {
    param(
        [Parameter(Mandatory)]
        [string]$EntityId,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [ValidateRange(1, 60)]
        [int]$TimeoutSec = 15
    )

    $uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/states/$EntityId"
    Invoke-DecisionHttpRequest -Parameters @{
        Method = 'Get'
        Uri = $uri
        Headers = $Headers
        TimeoutSec = $TimeoutSec
    }
}



function Remove-CopilotTemplateMarkup {
    <#
        Neutralises Home Assistant template syntax in text that will be interpolated
        into a Lovelace template.

        Session display names are not trusted input: a Copilot session is named after
        its task, and a Claude session after its working directory, so a repository or
        folder called "{{ states('device_tracker.me') }}" would otherwise be rendered
        as a template by Home Assistant. That was confirmed against a live instance -
        the injected expression evaluated and read real entity state - so anything
        session-derived is sanitised here before it can reach a card, a notification
        or a device name.

        The delimiters are broken with a zero-width space rather than stripped, so the
        text still reads correctly while being inert.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $zws = [char]0x200B
    $Text -replace '\{\{', "{$zws{" -replace '\{%', "{$zws%" -replace '\{#', "{$zws#"
}

function Get-CopilotSessionDisplay {
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    # Prefixed to match the Claude and Codex adapters, so a shared dashboard shows at
    # a glance which front end each card belongs to.
    $name = "Copilot: $($SessionId.Substring(0, [Math]::Min(8, $SessionId.Length)))"
    # Resolve the session directory through the filesystem-safe key, never the raw id:
    # a crafted id must not be able to walk out of the session-state root and read an
    # arbitrary workspace.yaml.
    $safeKey = Get-CopilotSafeSessionKey -SessionId $SessionId
    $workspacePath = Join-Path (
        Join-Path $script:DecisionBridgeConfig.SessionStateRoot $safeKey
    ) 'workspace.yaml'

    if (Test-Path -LiteralPath $workspacePath) {
        $nameMatch = Select-String -LiteralPath $workspacePath -Encoding UTF8 `
            -Pattern '^name:\s*(.+)$' | Select-Object -First 1
        if ($nameMatch) {
            $parsedName = $nameMatch.Matches.Groups[1].Value.Trim().Trim('"', "'")
            if (-not [string]::IsNullOrWhiteSpace($parsedName)) {
                $name = "Copilot: $parsedName"
            }
        }

    }

    $machine = [Environment]::MachineName

    # The name comes from the session's own workspace file, which is named after the
    # task, so treat it as untrusted before it reaches a template.
    $name = Remove-CopilotTemplateMarkup -Text $name

    $label = "$name - $machine"
    if ($label.Length -gt 255) {
        $label = $label.Substring(0, 252) + '...'
    }

    [pscustomobject]@{
        Name = $name
        Machine = $machine
        WorkingDirectory = $WorkingDirectory
        Label = $label
    }
}


function Get-CopilotSafeSessionKey {
    <#
        A filesystem-safe key for a session id.

        Session ids arrive in hook payloads and are used to build paths, so a value
        containing separators or traversal segments must not be able to escape the
        directory it belongs in. Real ids are UUIDs and pass through unchanged.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SessionId)

    $clean = ($SessionId -replace '[^a-zA-Z0-9._-]', '')
    $clean = $clean.TrimStart('.')
    if ([string]::IsNullOrWhiteSpace($clean)) { return 'unknown' }
    if ($clean.Length -gt 96) { $clean = $clean.Substring(0, 96) }
    $clean
}

function Get-CopilotDecisionMarkerPath {
    <#
        Resolves the pending-decision marker for a session.

        Copilot sessions keep it beside their session state. Other front ends - Claude
        Code, for instance - have no such folder, so those fall back to a bridge-owned
        directory. All three marker helpers go through here, so the hook that writes a
        marker and the daemon that consumes it always agree on the location.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    $key = Get-CopilotSafeSessionKey -SessionId $SessionId
    $sessionDirectory = Join-Path $script:DecisionBridgeConfig.SessionStateRoot $key
    if (Test-Path -LiteralPath $sessionDirectory) {
        return Join-Path $sessionDirectory 'copilot-pending-decision.json'
    }

    $fallback = Join-Path (Join-Path $env:TEMP 'copilot-bridge-markers') $key
    if (-not (Test-Path -LiteralPath $fallback)) {
        New-Item -ItemType Directory -Path $fallback -Force | Out-Null
    }
    Join-Path $fallback 'copilot-pending-decision.json'
}

function Write-CopilotDecisionMarker {
    <#
        Records that an ask_user is in flight for a session. Written by the
        non-blocking hook and consumed by the daemon: its existence is the gate that
        says "a decision is awaiting input", and it carries the choice/combo mapping
        the daemon needs to inject a selected option and to clear the card on
        completion. Deleted by the daemon once the ask_user completes.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$DecisionId,
        [AllowEmptyString()][string]$Question = '',
        [string[]]$Choices = @(),
        [AllowNull()][object[]]$Combos = @(),
        [AllowNull()][object[]]$Fields = @(),
        [switch]$TerminalOnly,
        [Parameter(Mandatory)][ValidateSet('freeform', 'multiple_choice')][string]$Mode
    )

    $marker = @{
        decisionId = $DecisionId
        question = $Question
        choices = @($Choices)
        combos = @($Combos)
        fields = @($Fields)
        # The daemon refuses to inject when this is set: the native prompt is a form
        # the card cannot drive, and text sent to it would be silently discarded.
        terminalOnly = [bool]$TerminalOnly
        mode = $Mode
        armedAt = [DateTimeOffset]::Now.ToString('o')
        injectedAnswer = ''
    }
    $path = Get-CopilotDecisionMarkerPath -SessionId $SessionId
    $json = $marker | ConvertTo-Json -Depth 8 -Compress
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-CopilotDecisionMarker {
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Get-CopilotDecisionMarkerPath -SessionId $SessionId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Set-CopilotDecisionMarkerInjected {
    <#
        Records the answer the daemon has already injected, so the same HA answer is
        never injected twice while the ask_user is still (briefly) shown as pending.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Answer,

        # The per-field option labels that were driven into the prompt, kept so the
        # recorded answer can be checked against them once the tool completes.
        [AllowNull()][AllowEmptyCollection()][string[]]$Selections = @()
    )
    $marker = Get-CopilotDecisionMarker -SessionId $SessionId
    if ($null -eq $marker) { return }
    $path = Get-CopilotDecisionMarkerPath -SessionId $SessionId
    $obj = @{}
    foreach ($p in $marker.PSObject.Properties) { $obj[$p.Name] = $p.Value }
    $obj['injectedAnswer'] = $Answer
    $obj['injectedSelections'] = @($Selections)
    Set-Content -LiteralPath $path -Value ($obj | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
}

function Remove-CopilotDecisionMarker {
    param([Parameter(Mandatory)][string]$SessionId)
    $path = Get-CopilotDecisionMarkerPath -SessionId $SessionId
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-CopilotAskUserState {
    <#
        Inspects the transcript for the most recent ask_user tool call and reports
        whether it is still awaiting input.

        The pair (tool.execution_start with toolName=ask_user) → (tool.execution_complete
        with the same toolCallId) is the authoritative "answered" signal, regardless of
        whether the answer came from the terminal or from an injected Home Assistant
        reply. Returns:
          Started   - $true if an ask_user start was found
          Pending   - $true if that start has no matching complete yet
          ToolCallId- the id of the most recent ask_user
          StartedAt - its timestamp
    #>
    param(
        [Parameter(Mandatory)][string]$TranscriptPath
    )

    $result = [pscustomobject]@{ Started = $false; Pending = $false; ToolCallId = ''; StartedAt = $null; ResultContent = '' }

    $lines = @(Get-CopilotTranscriptTailLines -Path $TranscriptPath)
    if ($lines.Count -eq 0) { return $result }

    # Walk forward, tracking the latest ask_user start and the set of completed ids.
    $latestStartId = ''
    $latestStartAt = $null
    $completed = @{}
    $results = @{}
    foreach ($line in $lines) {
        if ($line -notmatch '"type":"tool\.execution_(start|complete)"') { continue }
        try {
            $o = $line | ConvertFrom-Json
        }
        catch { continue }

        if ($o.type -eq 'tool.execution_start' -and [string]$o.data.toolName -eq 'ask_user') {
            $latestStartId = [string]$o.data.toolCallId
            $latestStartAt = $o.timestamp
        }
        elseif ($o.type -eq 'tool.execution_complete') {
            $cid = [string]$o.data.toolCallId
            if (-not [string]::IsNullOrWhiteSpace($cid)) {
                $completed[$cid] = $true
                # Keep the answer the CLI actually recorded, so an injected form can be
                # checked against it. An arrow-key selection that lands one option
                # short is otherwise indistinguishable from a correct one, and answers
                # with the wrong choice in the user's name.
                $results[$cid] = [string]$o.data.result.content
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($latestStartId)) { return $result }
    $result.Started = $true
    $result.ToolCallId = $latestStartId
    $result.StartedAt = $latestStartAt
    $result.Pending = -not $completed.ContainsKey($latestStartId)
    if ($results.ContainsKey($latestStartId)) { $result.ResultContent = [string]$results[$latestStartId] }
    $result
}

function Test-CopilotAnswerMatchesSelections {
    <#
        Whether the answer the CLI recorded contains every option that was injected.

        The injector drives an arrow-key list by index, so a single dropped keystroke
        selects the neighbouring option and the prompt reports it as though the user
        had chosen it. Nothing downstream can tell the difference, which makes it the
        worst possible failure: a confident, wrong answer attributed to the user.

        Comparing the recorded result against what was sent turns that into something
        visible. Text fields are skipped - the CLI may reformat what was typed - so
        this only asserts on the option labels, which are reproduced verbatim.
    #>
    param(
        [AllowEmptyString()][string]$ResultContent,
        [AllowNull()][AllowEmptyCollection()][object[]]$Fields,
        [AllowNull()][AllowEmptyCollection()][string[]]$Selections
    )

    if ([string]::IsNullOrWhiteSpace($ResultContent)) { return $true }
    $fieldList = @($Fields)
    $selectionList = @($Selections)
    if ($fieldList.Count -eq 0 -or $selectionList.Count -ne $fieldList.Count) { return $true }

    for ($i = 0; $i -lt $fieldList.Count; $i++) {
        if (Test-DecisionFieldIsText -Field $fieldList[$i]) { continue }
        $wanted = [string]$selectionList[$i]
        if ([string]::IsNullOrWhiteSpace($wanted)) { continue }
        if ($ResultContent -notlike "*$wanted*") { return $false }
    }
    $true
}

function Get-CopilotTranscriptTailLines {
    <#
        `Get-Content -Tail` walks a transcript backwards line by line and takes over
        twenty seconds on a multi-megabyte events.jsonl, which is long enough to blow
        the agentStop hook timeout. Seeking to a byte offset and decoding forward is
        effectively instant.

        Seeking can land mid-character or mid-line, so the first line of a partial
        read is discarded.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MaxBytes = 4194304
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $stream = $null
    $partial = $false
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite
        )
        $start = [Math]::Max(0, $stream.Length - $MaxBytes)
        $partial = $start -gt 0
        if ($partial) {
            [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        }
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false))
        $text = $reader.ReadToEnd()
    }
    catch {
        return @()
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    $lines = @(($text -replace "`r", '') -split "`n")
    if ($partial -and $lines.Count -gt 1) {
        $lines = @($lines[1..($lines.Count - 1)])
    }
    $lines
}

function Test-CopilotSessionWorking {
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $safeKey = Get-CopilotSafeSessionKey -SessionId $SessionId
    $eventsPath = Join-Path (
        Join-Path $script:DecisionBridgeConfig.SessionStateRoot $safeKey
    ) 'events.jsonl'
    if (-not (Test-Path -LiteralPath $eventsPath)) {
        return $false
    }

    $turnState = $null
    $lines = @(Get-CopilotTranscriptTailLines -Path $eventsPath)
    foreach ($line in $lines) {
        if ($line.StartsWith('{"type":"assistant.turn_start"')) {
            $turnState = 'working'
        }
        elseif ($line.StartsWith('{"type":"assistant.turn_end"')) {
            $turnState = 'idle'
        }
    }

    if ($null -eq $turnState) {
        foreach ($line in (Get-Content -LiteralPath $eventsPath)) {
            if ($line.StartsWith('{"type":"assistant.turn_start"')) {
                $turnState = 'working'
            }
            elseif ($line.StartsWith('{"type":"assistant.turn_end"')) {
                $turnState = 'idle'
            }
        }
    }

    $turnState -eq 'working'
}










function Send-BridgeNotification {
    <#
        Sends an out-of-band notification, if one is configured.

        `notifications.service` is any Home Assistant notify-style service, so this
        works with notify.notify, a mobile app notifier, or a custom integration. The
        extra Ticker-specific fields are only sent to a ticker.* service, because a
        standard notify service rejects unknown keys.

        A notification failure is logged and swallowed: the decision is already on the
        dashboard, and losing the push must not fail the ask_user.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    if (-not $script:DecisionBridgeConfig.NotifyEnabled) { return }
    $service = [string]$script:DecisionBridgeConfig.NotifyService
    $parts = $service.Split('.')
    if ($parts.Count -ne 2) {
        Write-DecisionBridgeLog -Message "notifications.service '$service' is not domain.service; skipping"
        return
    }

    $data = @{ title = $Title; message = $Message }
    if ($parts[0] -eq 'ticker') {
        $data['category'] = $script:DecisionBridgeConfig.TickerCategory
        $data['actions'] = 'none'
        $data['navigate_to'] = $script:DecisionBridgeConfig.DashboardPath
        $data['expiration'] = 8
    }

    try {
        Invoke-HomeAssistantService -Domain $parts[0] -Service $parts[1] -Headers $Headers -Data $data
    }
    catch {
        Write-DecisionBridgeLog -Message "notification via $service failed: $($_.Exception.Message)"
    }
}














