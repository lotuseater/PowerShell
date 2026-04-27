# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Clear-WizardLock {
    <#
    .SYNOPSIS
        Release a Wizard lock previously taken by Use-WizardLock.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Key,

        [string] $LockRoot
    )

    if (-not $LockRoot) {
        $LockRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\locks'
    }
    $safeKey = $Key -replace '[^A-Za-z0-9._-]', '_'
    $lockFile = Join-Path -Path $LockRoot -ChildPath ($safeKey + '.lock')

    if (-not (Test-Path -LiteralPath $lockFile)) {
        return $false
    }
    if ($PSCmdlet.ShouldProcess($lockFile, 'Remove Wizard lock')) {
        Remove-Item -LiteralPath $lockFile -Force
    }
    return $true
}
