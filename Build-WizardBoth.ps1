#Requires -Version 7.0
<#
.SYNOPSIS
    Build the wizard PowerShell fork in Debug and Release.

.DESCRIPTION
    Compatibility wrapper for the split build entrypoints:

      1. Build-WizardDebug.ps1
      2. Build-WizardRelease.ps1

    The deployed wizard-pwsh.cmd shim points at the Release publish directory, so
    the default path still builds both configurations in order. DebugOnly and
    ReleaseOnly are retained for existing callers.
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
$debugScript = Join-Path $repoRoot 'Build-WizardDebug.ps1'
$releaseScript = Join-Path $repoRoot 'Build-WizardRelease.ps1'

foreach ($script in @($debugScript, $releaseScript)) {
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Build-WizardBoth: required script not found: $script"
    }
}

if ($DebugOnly -and $ReleaseOnly) {
    throw 'Build-WizardBoth: -DebugOnly and -ReleaseOnly cannot be used together.'
}

if (-not $ReleaseOnly) {
    $debugArgs = @{}
    if ($LogRoot) { $debugArgs.LogRoot = $LogRoot }
    & $debugScript @debugArgs
}

if (-not $DebugOnly) {
    $releaseArgs = @{}
    if ($Force) { $releaseArgs.Force = $true }
    if ($LogRoot) { $releaseArgs.LogRoot = $LogRoot }
    & $releaseScript @releaseArgs
}

Write-Host ''
Write-Host 'Build-WizardBoth: done.' -ForegroundColor Green
