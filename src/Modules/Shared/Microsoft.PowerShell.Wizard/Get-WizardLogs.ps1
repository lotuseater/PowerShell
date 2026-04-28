# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Get-WizardLogs {
    <#
    .SYNOPSIS
        Enumerate recent Invoke-Bounded log files.

    .DESCRIPTION
        Lists log files under `%LOCALAPPDATA%\WizardPowerShell\logs\` (or `-LogRoot`),
        newest first. Returns one `WizardLogEntry` per file with `Path`, `Pid`, `Started`,
        `SizeBytes`, `LineCount` (lazy — only computed if `-WithLineCount` is set, since
        `wc -l` on every log can be slow on a large log dir).

        Default emits the **10 most recent** logs (matches `Get-WizardSessions` discipline).
        Pass `-All` for the full list, `-Top N` to override.

        Pairs with `Get-WizardLog -Latest` for the common "I just ran something, what
        was in its log?" workflow:

            Invoke-Bounded -FilePath cmake -ArgumentList @('--build','build') -Quiet | Out-Null
            Get-WizardLog -Latest -Range 'tail:200'

        Or for a wider survey:

            Get-WizardLogs | Format-Table Started, Pid, SizeBytes, Path
            Get-WizardLog  -LogPath (Get-WizardLogs)[2].Path -Range 'grep:error'

    .PARAMETER LogRoot
        Override the directory. Default: `$env:LOCALAPPDATA\WizardPowerShell\logs`.

    .PARAMETER Top
        Maximum number of entries to emit (newest first). Default 10.

    .PARAMETER All
        Emit every log; ignore `-Top`.

    .PARAMETER WithLineCount
        Compute `LineCount` per file. Costs one full read per file; off by default.
    #>
    [CmdletBinding()]
    [OutputType('WizardLogEntry')]
    param(
        [string] $LogRoot,
        [int] $Top = 10,
        [switch] $All,
        [switch] $WithLineCount
    )

    if (-not $LogRoot) {
        $LogRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\logs'
    }
    if (-not (Test-Path -LiteralPath $LogRoot)) {
        return
    }

    $entries = Get-ChildItem -LiteralPath $LogRoot -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if (-not $All -and $Top -gt 0) {
        $entries = $entries | Select-Object -First $Top
    }

    foreach ($file in $entries) {
        # File names are `<pid>-<utc>.log` per Invoke-Bounded; parse pid + started ts when we can.
        $sessionPid = $null
        $started = $null
        $match = [regex]::Match($file.Name, '^(?<pid>\d+)-(?<ts>\d{8}T\d{9})\.log$')
        if ($match.Success) {
            $sessionPid = [int]$match.Groups['pid'].Value
            $tsRaw = $match.Groups['ts'].Value
            try {
                $started = [datetime]::ParseExact($tsRaw, 'yyyyMMddTHHmmssfff', [System.Globalization.CultureInfo]::InvariantCulture)
            } catch { }
        }

        $lineCount = $null
        if ($WithLineCount) {
            try {
                $lineCount = (Get-Content -LiteralPath $file.FullName -ErrorAction Stop | Measure-Object).Count
            } catch { }
        }

        [pscustomobject]@{
            PSTypeName    = 'WizardLogEntry'
            Path          = $file.FullName
            Name          = $file.Name
            Pid           = $sessionPid
            Started       = $started
            LastWriteTime = $file.LastWriteTime
            SizeBytes     = $file.Length
            LineCount     = $lineCount
        }
    }
}
