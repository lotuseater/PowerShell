# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Invoke-RepoTest {
    <#
    .SYNOPSIS
        Run the repo's tests using its detected toolchain, bounded.
    #>
    [CmdletBinding()]
    [OutputType('WizardBoundedResult')]
    param(
        [string] $Path = (Get-Location).ProviderPath,
        [string] $TestPath,
        [ValidateSet('Auto', 'Pester', 'XUnit', 'DotNet', 'Python', 'Node')]
        [string] $Kind = 'Auto',
        [int] $TimeoutSec = 600,
        [switch] $Quiet
    )

    $repo = Get-RepoProfile -Path $Path
    Push-Location $repo.Root
    try {
        $resolvedKind = $Kind
        if ($Kind -eq 'Auto') {
            if ($repo.HasBuildPsm1 -and $repo.HasPesterTests) { $resolvedKind = 'Pester' }
            elseif ($repo.HasBuildPsm1 -and $repo.HasDotNetTests) { $resolvedKind = 'XUnit' }
            elseif ($repo.HasSolution) { $resolvedKind = 'DotNet' }
            elseif ($repo.HasPyProject -or $repo.HasPyTests) { $resolvedKind = 'Python' }
            elseif ($repo.HasPackageJson) { $resolvedKind = 'Node' }
            else { throw "Invoke-RepoTest: no test runner detected at $($repo.Root). Use -Kind explicitly." }
        }

        $self = (Get-Process -Id $PID).Path
        switch ($resolvedKind) {
            'Pester' {
                $script = if ($TestPath) { "Import-Module ./build.psm1 -Force; Start-PSPester -Path '$TestPath'" } else { 'Import-Module ./build.psm1 -Force; Start-PSPester' }
                return Invoke-Bounded -FilePath $self -ArgumentList @('-NoProfile', '-Command', $script) -TimeoutSec $TimeoutSec -Quiet:$Quiet
            }
            'XUnit' {
                return Invoke-Bounded -FilePath $self -ArgumentList @('-NoProfile', '-Command', 'Import-Module ./build.psm1 -Force; Start-PSxUnit') -TimeoutSec $TimeoutSec -Quiet:$Quiet
            }
            'DotNet' {
                return Invoke-Bounded -FilePath 'dotnet' -ArgumentList @('test', '--nologo', '--logger', 'console;verbosity=minimal') -TimeoutSec $TimeoutSec -Quiet:$Quiet
            }
            'Python' {
                $args = @('-q')
                if ($TestPath) { $args += $TestPath }
                return Invoke-Bounded -FilePath 'pytest' -ArgumentList $args -TimeoutSec $TimeoutSec -Quiet:$Quiet
            }
            'Node' {
                return Invoke-Bounded -FilePath 'npm' -ArgumentList @('test') -TimeoutSec $TimeoutSec -Quiet:$Quiet
            }
        }
    }
    finally { Pop-Location }
}
