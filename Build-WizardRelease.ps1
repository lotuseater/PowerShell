#Requires -Version 7.0
<#
.SYNOPSIS
    Build the wizard PowerShell fork in Release configuration.

.DESCRIPTION
    Uses the freshly built Debug pwsh as the build host when available so the
    Release publish pwsh.exe does not lock its own publish directory.
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [string] $LogRoot
)

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'build.psm1'))) {
    throw "Build-WizardRelease: build.psm1 not found at $repoRoot - run from the PowerShell repo root."
}

if (-not $LogRoot) {
    $LogRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\build-logs'
}
if (-not (Test-Path -LiteralPath $LogRoot)) {
    New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
}

function Get-WizardPublishExe {
    param([ValidateSet('Debug', 'Release')] [string] $Configuration)
    Join-Path $repoRoot ("src\powershell-win-core\bin\{0}\net11.0\win7-x64\publish\pwsh.exe" -f $Configuration)
}

function Invoke-WizardReleaseBuild {
    param([string] $UsingPwshExe)

    $stamp = Get-Date -Format 'yyyyMMddTHHmmss'
    $log = Join-Path $LogRoot "Release-$stamp.log"
    Write-Host "==> Building Release  (log: $log)" -ForegroundColor Cyan

    $script = @"
`$env:Path = 'C:\Users\Oleh\AppData\Local\Microsoft\dotnet;' + `$env:Path
Set-Location '$repoRoot'
Import-Module ./build.psm1 -Force
Start-PSBuild -Configuration Release
"@

    if ($UsingPwshExe -and (Test-Path -LiteralPath $UsingPwshExe)) {
        & $UsingPwshExe -NoProfile -NoLogo -Command $script 2>&1 | Tee-Object -FilePath $log | Out-Null
    } else {
        Invoke-Expression $script *>&1 | Tee-Object -FilePath $log | Out-Null
    }

    if (-not (Select-String -LiteralPath $log -Pattern 'END: Generate PowerShell Configuration' -Quiet)) {
        Write-Host "==> Release build did not reach 'END: Generate PowerShell Configuration' - check $log" -ForegroundColor Yellow
        if (Select-String -LiteralPath $log -Pattern '(error MSB|error CS|Build FAILED|Execution of \{ dotnet)' -Quiet) {
            throw "Build-WizardRelease: Release build FAILED - see $log"
        }
        throw "Build-WizardRelease: Release build incomplete - see $log"
    }

    Write-Host "==> Release build OK" -ForegroundColor Green
}

function Find-ReleaseLockers {
    $releasePwsh = Get-WizardPublishExe -Configuration Release
    if (-not (Test-Path -LiteralPath $releasePwsh)) {
        return [object[]]::Empty
    }

    $publishDir = [System.IO.Path]::GetDirectoryName($releasePwsh)
    $publishDirNorm = ($publishDir.TrimEnd('\') + '\').ToLowerInvariant()
    $lockers = [System.Collections.Generic.List[object]]::new()

    foreach ($process in Get-Process pwsh -ErrorAction SilentlyContinue) {
        $isMatch = $false
        try {
            if ($process.Path -ieq $releasePwsh) {
                $isMatch = $true
            }
        } catch { }

        if (-not $isMatch) {
            try {
                foreach ($module in $process.Modules) {
                    $modulePath = if ($module.FileName) { $module.FileName.ToLowerInvariant() } else { '' }
                    if ($modulePath.StartsWith($publishDirNorm)) {
                        $isMatch = $true
                        break
                    }
                }
            } catch {
                # Access denied is common for elevated processes. Skip those
                # because we cannot safely claim they are locking this publish dir.
            }
        }

        if ($isMatch) {
            $lockers.Add($process)
        }
    }

    return $lockers.ToArray()
}

function Stop-ReleaseLockers {
    param([switch] $NoPrompt)

    $lockers = @(Find-ReleaseLockers)
    if ($lockers.Count -eq 0) {
        Write-Host '==> No Release pwsh processes alive - Release build is unblocked.' -ForegroundColor Green
        return
    }

    Write-Host "==> Found $($lockers.Count) Release pwsh process(es) that may lock the publish DLLs:" -ForegroundColor Yellow
    $lockers |
        Select-Object Id, @{n='Started';e={$_.StartTime}}, @{n='RSS_MB';e={[Math]::Round($_.WorkingSet64 / 1MB, 1)}}, MainWindowTitle |
        Format-Table -AutoSize |
        Out-Host

    if (-not $NoPrompt) {
        $response = Read-Host 'Kill all of them? [y/N]'
        if ($response -notmatch '^[yY]') {
            throw 'Build-WizardRelease: aborted by user - Release build would fail with locked DLLs.'
        }
    }

    foreach ($process in $lockers) {
        try {
            $process.Kill()
            Write-Host "    killed PID $($process.Id)" -ForegroundColor DarkGray
        } catch {
            Write-Host "    failed to kill PID $($process.Id): $_" -ForegroundColor Red
        }
    }
    Start-Sleep -Seconds 2
}

Stop-ReleaseLockers -NoPrompt:$Force
$debugPwsh = Get-WizardPublishExe -Configuration Debug

try {
    Invoke-WizardReleaseBuild -UsingPwshExe $debugPwsh
} catch {
    $latestLog = Get-ChildItem -LiteralPath $LogRoot -Filter 'Release-*.log' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    $isLockRace = $false
    if ($latestLog) {
        $isLockRace = Select-String -LiteralPath $latestLog.FullName -Pattern 'MSB3027|is being used by another process' -Quiet
    }

    if (-not $isLockRace) {
        throw
    }

    Write-Host '==> Release build hit a file-lock race; sweeping again and retrying once.' -ForegroundColor Yellow
    Stop-ReleaseLockers -NoPrompt
    Start-Sleep -Seconds 3
    Invoke-WizardReleaseBuild -UsingPwshExe $debugPwsh
}

$shim = Join-Path $env:USERPROFILE 'bin\wizard-pwsh.cmd'
if (Test-Path -LiteralPath $shim) {
    $shimTarget = (Get-Content -LiteralPath $shim -Raw) -split "`n" |
        Where-Object { $_ -match 'pwsh\.exe' } |
        Select-Object -First 1
    Write-Host ''
    Write-Host '==> Deployed shim points at:' -ForegroundColor Cyan
    Write-Host "    $($shimTarget.Trim())"
    if ($shimTarget -match 'Release') {
        $releasePwsh = Get-WizardPublishExe -Configuration Release
        if (Test-Path -LiteralPath $releasePwsh) {
            $age = (Get-Date) - (Get-Item -LiteralPath $releasePwsh).LastWriteTime
            $ageText = if ($age.TotalMinutes -lt 5) { 'just now' } else { '{0:N1} min ago' -f $age.TotalMinutes }
            Write-Host "==> Release pwsh.exe last touched: $ageText" -ForegroundColor Cyan
        }
    }
}

Write-Host ''
Write-Host 'Build-WizardRelease: done.' -ForegroundColor Green
