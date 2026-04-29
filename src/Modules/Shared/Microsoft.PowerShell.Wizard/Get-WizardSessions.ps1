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
        [string] $SessionRoot,
        # Compact-default for agent contexts (2026-04-28). On a busy box the wizard fork
        # easily produces 30-50 live sessions; emitting the full list on every call wastes
        # ~3 k tokens. By default we emit the most recently-started 10 sessions; pass -All
        # to override.
        [int] $Top = 10,
        [switch] $All
    )

    if (-not $SessionRoot) {
        $SessionRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\sessions'
    }
    if (-not (Test-Path -LiteralPath $SessionRoot)) {
        return
    }

    $livePids = @{}
    try {
        foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
            $livePids[[int]$process.Id] = $true
        }
    } catch { }

    $files = @(Get-ChildItem -LiteralPath $SessionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTimeUtc -Descending)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $sessionPath = $file.FullName
        try {
            # -ErrorAction Stop on Get-Content too — without it the cmdlet's
            # non-terminating "file not found" (TOCTOU race when a wizard pwsh
            # exits between Get-ChildItem and our read) leaks past the try/catch.
            $raw = Get-Content -LiteralPath $sessionPath -Raw -Encoding utf8 -ErrorAction Stop
            $payload = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }

        $sessionPid = [int]$payload.pid
        $isAlive = [bool]$livePids[$sessionPid]
        if (-not $isAlive -and -not $IncludeStale) { continue }

        $entry = [pscustomobject]@{
            PSTypeName      = 'WizardSessionEntry'
            Pid             = $sessionPid
            PipeName        = [string]$payload.pipe
            Cwd             = [string]$payload.cwd
            Executable      = [string]$payload.executable
            ProcessName     = [string]$payload.processName
            Started         = $payload.startedAt
            UpdatedAt       = $payload.updatedAt
            ProtocolVersion = $payload.protocol
            IsAlive         = $isAlive
            SessionFile     = $sessionPath
        }
        $records.Add($entry)
        if (-not $All -and -not $IncludeStale -and $Top -gt 0 -and $records.Count -ge $Top) {
            break
        }
    }

    if ($records.Count -eq 0) { return }
    # Sort newest-first (most-recently started → most relevant for diagnostics).
    $sorted = @($records) | Sort-Object -Property Started -Descending
    if ($All) { return $sorted }
    if ($Top -gt 0 -and $sorted.Count -gt $Top) { return $sorted | Select-Object -First $Top }
    return $sorted
}
