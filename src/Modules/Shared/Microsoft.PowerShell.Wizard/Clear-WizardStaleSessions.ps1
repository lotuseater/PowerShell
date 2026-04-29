# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Clear-WizardStaleSessions {
    <#
    .SYNOPSIS
        Remove stale Wizard PowerShell session records.

    .DESCRIPTION
        Deletes JSON records under `%LOCALAPPDATA%\WizardPowerShell\sessions` whose
        owning process is no longer alive. The live process table is captured once so
        busy machines do not pay a process lookup per file.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [string] $SessionRoot,
        [int] $OlderThanDays = 0,
        [switch] $PassThru
    )

    if (-not $SessionRoot) {
        $SessionRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\sessions'
    }

    $summary = [ordered]@{
        PSTypeName   = 'WizardSessionCleanupResult'
        SessionRoot  = $SessionRoot
        Scanned      = 0
        Removed      = 0
        KeptLive     = 0
        KeptRecent   = 0
        RemovedFiles = @()
    }

    if (-not (Test-Path -LiteralPath $SessionRoot)) {
        return [pscustomobject]$summary
    }

    $livePids = @{}
    try {
        foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
            $livePids[[int]$process.Id] = $true
        }
    } catch { }

    $cutoffUtc = if ($OlderThanDays -gt 0) { [DateTime]::UtcNow.AddDays(-1 * $OlderThanDays) } else { $null }

    foreach ($file in @(Get-ChildItem -LiteralPath $SessionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $summary.Scanned++
        $pid = 0
        try {
            $payload = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $pid = [int]$payload.pid
        } catch {
            $pid = 0
        }

        if ($pid -gt 0 -and $livePids[[int]$pid]) {
            $summary.KeptLive++
            continue
        }

        if ($cutoffUtc -and $file.LastWriteTimeUtc -gt $cutoffUtc) {
            $summary.KeptRecent++
            continue
        }

        if ($PSCmdlet.ShouldProcess($file.FullName, 'remove stale wizard session record')) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            $summary.Removed++
            $summary.RemovedFiles += $file.FullName
        }
    }

    if ($PassThru -or $summary.Removed -ge 0) {
        return [pscustomobject]$summary
    }
}
