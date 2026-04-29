# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Invoke-RepoBuild {
    <#
    .SYNOPSIS
        Build a repo using its detected toolchain. Output is bounded by Invoke-Bounded.
    #>
    [CmdletBinding()]
    [OutputType('WizardBoundedResult')]
    param(
        [string] $Path = (Get-Location).ProviderPath,
        [int] $TimeoutSec = 600,
        [switch] $Quiet
    )

    $repo = Get-RepoProfile -Path $Path
    Push-Location $repo.Root
    try {
        if ($repo.IsWizardErasmus) {
            if (-not (Test-Path -LiteralPath (Join-Path $repo.Root 'build'))) {
                Invoke-Bounded -FilePath 'cmake' -ArgumentList @('--preset', 'default') -TimeoutSec $TimeoutSec -Quiet | Out-Null
            }
            return Invoke-Bounded -FilePath 'cmake' -ArgumentList @('--build', 'build') -TimeoutSec $TimeoutSec -Quiet:$Quiet
        }
        if ($repo.HasBuildPsm1) {
            return Invoke-Bounded -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-Command', 'Import-Module ./build.psm1 -Force; Start-PSBuild') -TimeoutSec $TimeoutSec -Quiet:$Quiet
        }
        if ($repo.HasSolution) {
            return Invoke-Bounded -FilePath 'dotnet' -ArgumentList @('build', '--nologo') -TimeoutSec $TimeoutSec -Quiet:$Quiet
        }
        if ($repo.HasCMakeLists) {
            $build = Join-Path $repo.Root 'build'
            if (-not (Test-Path -LiteralPath $build)) {
                Invoke-Bounded -FilePath 'cmake' -ArgumentList @('-S', '.', '-B', 'build') -TimeoutSec $TimeoutSec -Quiet | Out-Null
            }
            return Invoke-Bounded -FilePath 'cmake' -ArgumentList @('--build', 'build') -TimeoutSec $TimeoutSec -Quiet:$Quiet
        }
        if ($repo.HasPackageJson) {
            return Invoke-Bounded -FilePath 'npm' -ArgumentList @('run', 'build') -TimeoutSec $TimeoutSec -Quiet:$Quiet
        }
        throw "Invoke-RepoBuild: no recognised build entrypoint at $($repo.Root). Add a repo adapter."
    }
    finally { Pop-Location }
}
