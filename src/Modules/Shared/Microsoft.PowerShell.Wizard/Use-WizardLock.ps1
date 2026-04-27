# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Use-WizardLock {
    <#
    .SYNOPSIS
        Idempotency sentinel for one-shot operations like "relaunch this session in /loop".

    .DESCRIPTION
        Lock files live under %LOCALAPPDATA%\WizardPowerShell\locks\<key>.lock. The cmdlet
        returns the prior lock record if the lock is already held, or $null if the lock
        was just acquired. Caller branches on the return:

            $prior = Use-WizardLock -Key 'loop-relaunch-self' -Note '...'
            if ($null -eq $prior) {
                # First time — do the work.
            } else {
                # Already done at $prior.AcquiredAt by PID $prior.AcquiredBy. Skip.
            }

        The lock file is JSON, one record per key. Persistent across reboots. Use
        Clear-WizardLock -Key X to release manually.

    .PARAMETER Key
        Lock identifier. Stable string, no path separators (gets sanitized).

    .PARAMETER Note
        Free-form text recorded in the lock file. Helps explain the lock to a future reader.

    .PARAMETER LockRoot
        Override the lock directory. Default: $env:LOCALAPPDATA\WizardPowerShell\locks.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Key,

        [Parameter(Position = 1)]
        [string] $Note,

        [string] $LockRoot
    )

    if (-not $LockRoot) {
        $LockRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\locks'
    }
    if (-not (Test-Path -LiteralPath $LockRoot)) {
        New-Item -ItemType Directory -Force -Path $LockRoot | Out-Null
    }

    $safeKey = $Key -replace '[^A-Za-z0-9._-]', '_'
    $lockFile = Join-Path -Path $LockRoot -ChildPath ($safeKey + '.lock')

    if (Test-Path -LiteralPath $lockFile) {
        $raw = Get-Content -LiteralPath $lockFile -Raw -ErrorAction SilentlyContinue
        if ($raw -and $raw.Trim()) {
            try {
                $existing = ConvertFrom-Json $raw -ErrorAction Stop
                # Augment: mark we observed it.
                Add-Member -InputObject $existing -NotePropertyName 'WasAlreadyHeld' -NotePropertyValue $true -Force
                Add-Member -InputObject $existing -NotePropertyName 'LockFile' -NotePropertyValue $lockFile -Force
                return $existing
            } catch {
                return [pscustomobject]@{
                    PSTypeName     = 'WizardLock'
                    Key            = $Key
                    WasAlreadyHeld = $true
                    Stale          = $true
                    Raw            = $raw
                    LockFile       = $lockFile
                }
            }
        }
        # File exists but is empty — treated as "not held"; we acquire it.
    }

    $record = [pscustomobject]@{
        PSTypeName   = 'WizardLock'
        Key          = $Key
        Note         = $Note
        AcquiredAt   = (Get-Date).ToUniversalTime().ToString('o')
        AcquiredBy   = $PID
        AcquiredFrom = $env:COMPUTERNAME
        LockFile     = $lockFile
    }
    ($record | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $lockFile -Encoding utf8 -Force

    return $null  # null = freshly acquired
}
