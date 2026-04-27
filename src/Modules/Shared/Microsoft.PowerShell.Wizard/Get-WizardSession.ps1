# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Get-WizardSession {
    <#
    .SYNOPSIS
        Reports the current Wizard PowerShell agent-runtime session state.

    .DESCRIPTION
        When WIZARD_PWSH_CONTROL=1, the host process runs an opt-in named-pipe control
        server, applies UTF-8 startup hardening, and (in later phases) hosts a persistent
        Python hook host and signal bus. Get-WizardSession returns a single object
        describing what's actually live in this process.

        When the env var is absent, the cmdlet still runs and returns a session record
        with WizardControlEnabled=$false so callers can branch on it without try/catch.

    .OUTPUTS
        WizardSession (PSCustomObject) with:
          Pid                   - this process id
          PipeName              - control-pipe name (when enabled)
          SessionRecord         - path to the per-pid session JSON
          LogDir                - WizardPowerShell log directory
          WizardControlEnabled  - $true iff WIZARD_PWSH_CONTROL is truthy
          HookHostStatus        - 'disabled' (Phase 6 lights this up)
          ConsoleEncoding       - [Console]::OutputEncoding.WebName
          OutputEncoding        - $OutputEncoding.WebName
          NativeErrorPreference - $PSNativeCommandUseErrorActionPreference
          Started               - process start time (local)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $enabled = $env:WIZARD_PWSH_CONTROL
    $isEnabled = $enabled -and ($enabled -in @('1', 'true', 'True', 'TRUE', 'yes', 'Yes', 'YES'))

    $pipeName = $null
    $sessionRecord = $null
    if ($isEnabled) {
        if ($env:WIZARD_PWSH_CONTROL_PIPE) {
            $pipeName = $env:WIZARD_PWSH_CONTROL_PIPE
        }
        else {
            $pipeName = "wizard-pwsh-$PID"
        }

        $sessionRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\sessions'
        $sessionRecord = Join-Path -Path $sessionRoot -ChildPath ("$PID.json")
    }

    $logDir = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\logs'

    $started = (Get-Process -Id $PID).StartTime

    # Phase 6: ask the warm Python hook host (if any) for its live status. Cheap pipe call;
    # if WIZARD_PWSH_CONTROL is not set or the server isn't up, falls back to "disabled".
    $hookHostStatus = 'disabled'
    if ($isEnabled) {
        try {
            $listResp = Send-WizardControlRequest -Payload @{ command = 'hook.list' } -PipeName $pipeName -ConnectTimeoutMs 250
            if ($listResp.status -eq 'ok') {
                if ($listResp.hooks -and $listResp.hooks.Count -gt 0) {
                    $hookHostStatus = "warm ($($listResp.hooks.Count) hooks)"
                } else {
                    $hookHostStatus = 'idle'
                }
            }
        } catch {
            # Pipe unreachable from a non-host context (e.g. cmdlet running outside the wizard pwsh).
            $hookHostStatus = 'disabled'
        }
    }

    [pscustomobject]@{
        PSTypeName            = 'WizardSession'
        Pid                   = $PID
        PipeName              = $pipeName
        SessionRecord         = $sessionRecord
        LogDir                = $logDir
        WizardControlEnabled  = [bool]$isEnabled
        HookHostStatus        = $hookHostStatus
        ConsoleEncoding       = [Console]::OutputEncoding.WebName
        OutputEncoding        = $OutputEncoding.WebName
        NativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        Started               = $started
    }
}
