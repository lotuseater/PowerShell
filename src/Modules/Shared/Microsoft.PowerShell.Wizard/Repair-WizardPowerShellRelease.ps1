# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Repair-WizardPowerShellRelease {
    <#
    .SYNOPSIS
        Rebuild and smoke-test the system-wide Wizard PowerShell Release shim.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path,
        [string] $Configuration = 'Release',
        [string] $Runtime = 'win7-x64',
        [int] $TimeoutSec = 3600,
        [switch] $SkipBuild,
        [switch] $InstallShim,
        [switch] $SetPwshShim,
        [switch] $StopLockingProcesses,
        [switch] $Quiet
    )

    $repoRootFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
    $buildModule = Join-Path -Path $repoRootFull -ChildPath 'build.psm1'
    if (-not (Test-Path -LiteralPath $buildModule)) {
        throw "Repair-WizardPowerShellRelease: build.psm1 not found at $repoRootFull"
    }

    $hostPwsh = (Get-Process -Id $PID).Path
    $publishExe = Join-Path -Path $repoRootFull -ChildPath ("src\powershell-win-core\bin\{0}\net11.0\{1}\publish\pwsh.exe" -f $Configuration, $Runtime)
    $buildResult = $null
    Push-Location $repoRootFull
    try {
        if ($StopLockingProcesses -and (Test-Path -LiteralPath $publishExe)) {
            $lockers = @(Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object {
                try { $_.Path -ieq $publishExe } catch { $false }
            })
            foreach ($process in $lockers) {
                if ($process.Id -eq $PID) { continue }
                if ($PSCmdlet.ShouldProcess("PID $($process.Id)", "stop Release pwsh locking $publishExe")) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
            }
            if ($lockers.Count -gt 0) { Start-Sleep -Seconds 2 }
        }

        if (-not $SkipBuild) {
            $localDotnet = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\dotnet'
            $pathPrefix = if (Test-Path -LiteralPath $localDotnet) { "`$env:Path = '$localDotnet;' + `$env:Path; " } else { "" }
            $script = $pathPrefix + "Import-Module ./build.psm1 -Force; Start-PSBuild -Configuration '$Configuration' -Runtime '$Runtime'"
            if ($PSCmdlet.ShouldProcess($repoRootFull, "build Wizard PowerShell $Configuration/$Runtime")) {
                $buildResult = Invoke-Bounded -FilePath $hostPwsh -ArgumentList @('-NoLogo', '-NoProfile', '-Command', $script) -TimeoutSec $TimeoutSec -Quiet:$Quiet -MergeStdErr
                if ($buildResult.ExitCode -ne 0 -or $buildResult.KilledByTimeout) {
                    throw "Repair-WizardPowerShellRelease: build failed. Log: $($buildResult.LogPath)"
                }
            }
        }

        if (-not (Test-Path -LiteralPath $publishExe)) {
            throw "Repair-WizardPowerShellRelease: publish executable not found: $publishExe"
        }

        if ($InstallShim) {
            $installer = Join-Path -Path $repoRootFull -ChildPath 'tools\wizard\Install-WizardPwsh.ps1'
            if (-not (Test-Path -LiteralPath $installer)) {
                throw "Repair-WizardPowerShellRelease: installer not found: $installer"
            }
            $installArgs = @('-NoLogo', '-NoProfile', '-File', $installer, '-PublishPath', $publishExe)
            if ($SetPwshShim) { $installArgs += '-SetPwshShim' }
            if ($PSCmdlet.ShouldProcess($publishExe, 'install wizard-pwsh shim')) {
                $installResult = Invoke-Bounded -FilePath $hostPwsh -ArgumentList $installArgs -TimeoutSec 180 -Quiet:$Quiet -MergeStdErr
                if ($installResult.ExitCode -ne 0 -or $installResult.KilledByTimeout) {
                    throw "Repair-WizardPowerShellRelease: shim install failed. Log: $($installResult.LogPath)"
                }
            }
        }

        $shim = Join-Path $env:USERPROFILE 'bin\wizard-pwsh.cmd'
        $smokeExe = if (Test-Path -LiteralPath $shim) { $shim } else { $publishExe }
        $smoke = Invoke-Bounded -FilePath $smokeExe -ArgumentList @('-NoLogo', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString(); $PSVersionTable.WizardBuild') -TimeoutSec 60 -Quiet:$true -MergeStdErr
        if ($smoke.ExitCode -ne 0 -or $smoke.KilledByTimeout) {
            throw "Repair-WizardPowerShellRelease: smoke failed. Log: $($smoke.LogPath)"
        }

        return [pscustomobject]@{
            PSTypeName = 'WizardPowerShellReleaseRepairResult'
            Status     = 'ok'
            PublishExe = $publishExe
            SmokeExe   = $smokeExe
            BuildLog   = if ($buildResult) { $buildResult.LogPath } else { $null }
            SmokeLog   = $smoke.LogPath
            SmokeTail  = $smoke.Tail
        }
    }
    finally {
        Pop-Location
    }
}
