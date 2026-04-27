# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Get-WizardSessions {
    <#
    .SYNOPSIS
        Enumerate live wizard PowerShell sessions on this machine.

    .DESCRIPTION
        Scans `%LOCALAPPDATA%\WizardPowerShell\sessions\*.json` and returns one record per
        wizard pwsh process that is still running. Each record is a `WizardSessionEntry`
        with `Pid`, `PipeName`, `Cwd`, `Executable`, `Started`, `IsAlive`. Stale session
        files (process gone) are excluded by default; pass `-IncludeStale` to see them too.

        This is the discovery primitive for any agent (DAB, external Python, another pwsh)
        that needs to find a live wizard control-pipe to talk to. Pairs with the canonical
        Python client at `tools/wizard/clients/python/wizard_pwsh_client.py`.

        The singular `Get-WizardSession` (no `s`) returns *this* process's session info;
        this cmdlet returns *all* of them.

    .PARAMETER IncludeStale
        Also return entries whose owning PID is no longer alive (`IsAlive=$false`). Useful
        for diagnostics; default behaviour filters them out.

    .PARAMETER SessionRoot
        Override the session-files directory. Default:
        `$env:LOCALAPPDATA\WizardPowerShell\sessions`.

    .EXAMPLE
        Get-WizardSessions

    .EXAMPLE
        Get-WizardSessions | Where-Object Cwd -Match 'Wizard_Erasmus' | ForEach-Object {
            Send-WizardControlRequest -PipeName $_.PipeName -Payload @{ command = 'status' }
        }
    #>
    [CmdletBinding()]
    [OutputType('WizardSessionEntry')]
    param(
        [switch] $IncludeStale,
        [string] $SessionRoot
    )

    if (-not $SessionRoot) {
        $SessionRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\sessions'
    }
    if (-not (Test-Path -LiteralPath $SessionRoot)) {
        return
    }

    Get-ChildItem -LiteralPath $SessionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $sessionPath = $_.FullName
        try {
            $payload = Get-Content -LiteralPath $sessionPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return
        }

        $sessionPid = [int]$payload.pid
        $isAlive = $false
        try {
            $proc = Get-Process -Id $sessionPid -ErrorAction Stop
            $isAlive = $true
        } catch {
            $isAlive = $false
        }
        if (-not $isAlive -and -not $IncludeStale) { return }

        [pscustomobject]@{
            PSTypeName    = 'WizardSessionEntry'
            Pid           = $sessionPid
            PipeName      = [string]$payload.pipe
            Cwd           = [string]$payload.cwd
            Executable    = [string]$payload.executable
            ProcessName   = [string]$payload.processName
            Started       = $payload.startedAt
            UpdatedAt     = $payload.updatedAt
            ProtocolVersion = $payload.protocol
            IsAlive       = $isAlive
            SessionFile   = $sessionPath
        }
    }
}
