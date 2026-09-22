<#
    Mirrors a Copilot permission prompt to Home Assistant as a one-way alert.

    Wired to the `notification` hook with a `permission_prompt` matcher. It is purely
    informational - the prompt is still answered in the terminal - so a delivery
    failure is swallowed rather than allowed to disturb the session.
#>

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'decision-bridge-common.ps1')

    $rawEvent = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($rawEvent)) {
        Write-Output '{}'
        exit 0
    }

    $event = $rawEvent | ConvertFrom-Json
    $title = [string]$event.title
    $message = [string]$event.message

    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = if ($event.notification_type -eq 'permission_prompt') {
            'Copilot permission needed'
        }
        else {
            'Copilot decision needed'
        }
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = 'Copilot CLI is waiting for your input.'
    }

    # Send-BridgeNotification is a no-op when notifications are disabled in the config.
    Send-BridgeNotification -Title $title -Message $message -Headers (Get-HomeAssistantHeaders)
}
catch {
    try {
        Write-DecisionBridgeLog -Message "permission notification failed: $($_.Exception.Message)"
    }
    catch {
        # Notification delivery must never affect the session.
    }
}

Write-Output '{}'