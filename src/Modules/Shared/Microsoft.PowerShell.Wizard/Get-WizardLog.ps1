# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Get-WizardLog {
    <#
    .SYNOPSIS
        Fetches a slice of a Wizard log file produced by Invoke-Bounded.

    .DESCRIPTION
        Range syntax:
          head:N        first N lines
          tail:N        last N lines
          lines:A-B     lines A through B (1-based, inclusive)
          grep:PATTERN  Select-String -Pattern PATTERN against the file (returns matched lines)

        Defaults to tail:200 — the most common "what happened at the end" question.

    .EXAMPLE
        Get-WizardLog -LogPath $r.LogPath -Range head:100
        Get-WizardLog -LogPath $r.LogPath -Range "lines:5000-5050"
        Get-WizardLog -LogPath $r.LogPath -Range "grep:error\b"
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByPath')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'ByPath')]
        [string] $LogPath,

        # δ1: when set, auto-locate the most recent log under
        # %LOCALAPPDATA%\WizardPowerShell\logs\. Saves the agent from having to
        # remember the LogPath returned by the previous Invoke-Bounded.
        [Parameter(Mandatory, ParameterSetName = 'Latest')]
        [switch] $Latest,

        [Parameter(Position = 1)]
        [string] $Range = 'tail:200'
    )

    if ($Latest) {
        $logDir = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\logs'
        $newest = Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if (-not $newest) {
            throw "Get-WizardLog -Latest: no logs in $logDir."
        }
        $LogPath = $newest.FullName
        Write-Verbose "Get-WizardLog -Latest resolved to $LogPath"
    }

    if (-not (Test-Path -LiteralPath $LogPath)) {
        throw "Wizard log not found: $LogPath"
    }

    switch -regex ($Range) {
        '^head:(\d+)$' {
            return Get-Content -LiteralPath $LogPath -TotalCount ([int]$Matches[1])
        }
        '^tail:(\d+)$' {
            return Get-Content -LiteralPath $LogPath -Tail ([int]$Matches[1])
        }
        '^lines:(\d+)-(\d+)$' {
            $from = [int]$Matches[1]
            $to = [int]$Matches[2]
            if ($from -lt 1 -or $to -lt $from) {
                throw "Invalid line range: '$Range'. A must be >= 1 and <= B."
            }
            return Get-Content -LiteralPath $LogPath | Select-Object -Skip ($from - 1) -First ($to - $from + 1)
        }
        '^grep:(.+)$' {
            $pattern = $Matches[1]
            return (Select-String -LiteralPath $LogPath -Pattern $pattern) | ForEach-Object { $_.Line }
        }
        default {
            throw "Unknown range syntax: '$Range'. Use head:N, tail:N, lines:A-B, or grep:PATTERN."
        }
    }
}
