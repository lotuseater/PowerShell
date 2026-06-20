#Requires -Version 7.0
<#
.SYNOPSIS
    Build the wizard PowerShell fork in Debug configuration.
#>
[CmdletBinding()]
param(
    [string] $LogRoot
)

$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'build.psm1'))) {
    throw "Build-WizardDebug: build.psm1 not found at $repoRoot - run from the PowerShell repo root."
}

if (-not $LogRoot) {
    $LogRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\build-logs'
}
if (-not (Test-Path -LiteralPath $LogRoot)) {
    New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMddTHHmmss'
$log = Join-Path $LogRoot "Debug-$stamp.log"
Write-Host "==> Building Debug  (log: $log)" -ForegroundColor Cyan

$script = @"
`$env:Path = 'C:\Users\Oleh\AppData\Local\Microsoft\dotnet;' + `$env:Path
Set-Location '$repoRoot'
Import-Module ./build.psm1 -Force
Start-PSBuild -Configuration Debug
"@

Invoke-Expression $script *>&1 | Tee-Object -FilePath $log | Out-Null

if (-not (Select-String -LiteralPath $log -Pattern 'END: Generate PowerShell Configuration' -Quiet)) {
    Write-Host "==> Debug build did not reach 'END: Generate PowerShell Configuration' - check $log" -ForegroundColor Yellow
    if (Select-String -LiteralPath $log -Pattern '(error MSB|error CS|Build FAILED|Execution of \{ dotnet)' -Quiet) {
        throw "Build-WizardDebug: Debug build FAILED - see $log"
    }
    throw "Build-WizardDebug: Debug build incomplete - see $log"
}

Write-Host "==> Debug build OK" -ForegroundColor Green
