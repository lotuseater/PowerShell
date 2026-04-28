#Requires -Version 7.0
<#
.SYNOPSIS
    Build the wizard PowerShell fork in BOTH Debug and Release configurations, in
    the right order, without self-lock surprises.

.DESCRIPTION
    Per the project's standing rule (`memory/wizard_release_build.md`): the deployed
    `wizard-pwsh.cmd` shim points at the **Release** publish dir. Any improvement that
    should reach live agent sessions therefore needs a Release build. Debug stays
    useful for fast iteration of `.ps1` cmdlets via the publish/Modules copy trick.

    This script ships both builds in one invocation:

      1. Build Debug (Start-PSBuild -Configuration Debug). Fast — Debug pwsh is the
         tool we use to run the Release build without locking ourselves.
      2. Detect any Release pwsh.exe processes that hold publish DLLs open. If found,
         either prompt to kill them (default) or kill silently with -Force. Headless
         pwsh (no MainWindowTitle) is the typical lock-holder and is safe to kill —
         these are stale loop continuations.
      3. Build Release using the freshly-built Debug pwsh as the host, so the build
         host's process never appears in the lock-holder list.

    Either configuration alone is one switch away (-DebugOnly / -ReleaseOnly).

.PARAMETER DebugOnly
    Skip the Release build.

.PARAMETER ReleaseOnly
    Skip the Debug build (won't auto-handle the self-lock; pass -Force if you trust
    that no Release pwsh sessions are alive).

.PARAMETER Force
    Kill lock-holding Release pwsh processes without prompting. Use when running
    unattended (e.g., from a CI tick or a /loop body).

.PARAMETER LogRoot
    Override where build logs are written. Default: %LOCALAPPDATA%\WizardPowerShell\build-logs.

.EXAMPLE
    pwsh -File Build-WizardBoth.ps1

    Build Debug, prompt to kill any Release lockers, build Release.

.EXAMPLE
    pwsh -File Build-WizardBoth.ps1 -Force

    Same as above but kills lockers without prompting.

.EXAMPLE
    pwsh -File Build-WizardBoth.ps1 -DebugOnly

    Iterate fast — build Debug only, skip the Release ceremony.

.NOTES
    Lives at repo root for discoverability. Don't move without updating the
    wizard_release_build.md memory entry.
#>
[CmdletBinding()]
param(
    [switch] $DebugOnly,
    [switch] $ReleaseOnly,
    [switch] $Force,
    [string] $LogRoot
)

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'build.psm1'))) {
    throw "Build-WizardBoth: build.psm1 not found at $repoRoot — run from the PowerShell repo root."
}

if (-not $LogRoot) {
    $LogRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\build-logs'
}
if (-not (Test-Path -LiteralPath $LogRoot)) {
    New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
}

function Get-PublishExe {
    param([string] $Configuration)
    return Join-Path $repoRoot ("src\powershell-win-core\bin\{0}\net11.0\win7-x64\publish\pwsh.exe" -f $Configuration)
}

function Invoke-WizardBuild {
    param(
        [string] $Configuration,
        [string] $UsingPwshExe
    )
    $stamp = (Get-Date -Format 'yyyyMMddTHHmmss')
    $log = Join-Path $LogRoot ("$Configuration-$stamp.log")
    Write-Host "==> Building $Configuration  (log: $log)" -ForegroundColor Cyan

    $script = @"
`$env:Path = 'C:\\Users\\Oleh\\AppData\\Local\\Microsoft\\dotnet;' + `$env:Path
Set-Location '$repoRoot'
Import-Module ./build.psm1 -Force
Start-PSBuild -Configuration $Configuration
"@

    if ($UsingPwshExe -and (Test-Path -LiteralPath $UsingPwshExe)) {
        & $UsingPwshExe -NoProfile -NoLogo -Command $script 2>&1 | Tee-Object -FilePath $log | Out-Null
    } else {
        # Fall back to the host pwsh if the spawn target isn't there yet (first-ever run).
        Invoke-Expression $script *>&1 | Tee-Object -FilePath $log | Out-Null
    }

    if (-not (Select-String -LiteralPath $log -Pattern 'END: Generate PowerShell Configuration' -Quiet)) {
        Write-Host "==> $Configuration build did not reach 'END: Generate PowerShell Configuration' — check $log" -ForegroundColor Yellow
        if (Select-String -LiteralPath $log -Pattern '(error MSB|error CS|Build FAILED|Execution of \{ dotnet)' -Quiet) {
            throw "Build-WizardBoth: $Configuration build FAILED — see $log"
        }
        throw "Build-WizardBoth: $Configuration build incomplete — see $log"
    }
    Write-Host "==> $Configuration build OK" -ForegroundColor Green
}

function Find-ReleaseLockers {
    $relPwsh = Get-PublishExe -Configuration 'Release'
    if (-not (Test-Path -LiteralPath $relPwsh)) { return @() }
    return @(Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -ieq $relPwsh } catch { $false }
    })
}

function Stop-ReleaseLockers {
    param([switch] $NoPrompt)
    $lockers = Find-ReleaseLockers
    if ($lockers.Count -eq 0) {
        Write-Host '==> No Release pwsh processes alive — Release build is unblocked.' -ForegroundColor Green
        return
    }
    Write-Host "==> Found $($lockers.Count) Release pwsh process(es) that may lock the publish DLLs:" -ForegroundColor Yellow
    $lockers | Select-Object Id, @{n='Started';e={$_.StartTime}}, @{n='RSS_MB';e={[Math]::Round($_.WorkingSet64/1MB,1)}}, MainWindowTitle | Format-Table -AutoSize | Out-Host

    if (-not $NoPrompt) {
        $resp = Read-Host 'Kill all of them? [y/N]'
        if ($resp -notmatch '^[yY]') {
            throw 'Build-WizardBoth: aborted by user — Release build would fail with locked DLLs.'
        }
    }
    foreach ($p in $lockers) {
        try {
            $p.Kill()
            Write-Host "    killed PID $($p.Id)" -ForegroundColor DarkGray
        } catch {
            Write-Host "    failed to kill PID $($p.Id): $_" -ForegroundColor Red
        }
    }
    Start-Sleep -Seconds 2
}

# --- Phase 1: Debug ----------------------------------------------------------

if (-not $ReleaseOnly) {
    Invoke-WizardBuild -Configuration 'Debug'
}

# --- Phase 2: Release (run from the just-built Debug pwsh to avoid self-lock) -

if (-not $DebugOnly) {
    Stop-ReleaseLockers -NoPrompt:$Force
    $debugPwsh = Get-PublishExe -Configuration 'Debug'
    Invoke-WizardBuild -Configuration 'Release' -UsingPwshExe $debugPwsh
}

# --- Verify rollout reached the deployed shim ---------------------------------

$shim = Join-Path $env:USERPROFILE 'bin\wizard-pwsh.cmd'
if (Test-Path -LiteralPath $shim) {
    $shimTarget = (Get-Content -LiteralPath $shim -Raw) -split "`n" |
        Where-Object { $_ -match 'pwsh\.exe' } |
        Select-Object -First 1
    Write-Host ''
    Write-Host '==> Deployed shim points at:' -ForegroundColor Cyan
    Write-Host "    $($shimTarget.Trim())"
    if ($shimTarget -match 'Release') {
        $relPwsh = Get-PublishExe -Configuration 'Release'
        if (Test-Path -LiteralPath $relPwsh) {
            $age = (Get-Date) - (Get-Item -LiteralPath $relPwsh).LastWriteTime
            $ageStr = if ($age.TotalMinutes -lt 5) { 'just now' } else { '{0:N1} min ago' -f $age.TotalMinutes }
            Write-Host "==> Release pwsh.exe last touched: $ageStr" -ForegroundColor Cyan
        }
    }
}

Write-Host ''
Write-Host 'Build-WizardBoth: done.' -ForegroundColor Green
