# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Test-WizardBuildPrereqs {
    <#
    .SYNOPSIS
        Asserts the prerequisites required to rebuild the wizard fork.

    .DESCRIPTION
        Checks: pinned .NET SDK from global.json is installed; ripgrep is on PATH (for Find-Code);
        Pester 5+ is available; pwsh is the wizard shim. Returns a hashtable per check; throws if
        any required check fails (pass -Quiet to get a result object instead).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $RepoRoot,
        [switch] $Quiet
    )

    if (-not $RepoRoot) {
        # Try to locate the fork by walking up from $PSScriptRoot.
        $candidate = (Get-Location).ProviderPath
        try {
            $candidate = (& git -C $candidate rev-parse --show-toplevel 2>$null).Trim()
        } catch { }
        $RepoRoot = $candidate
    }

    $checks = @()

    # 1) global.json present + dotnet SDK matches
    $globalJson = Join-Path $RepoRoot 'global.json'
    if (Test-Path -LiteralPath $globalJson) {
        $pinned = (Get-Content -LiteralPath $globalJson -Raw | ConvertFrom-Json).sdk.version
        $sdks = @()
        try { $sdks = (& dotnet --list-sdks 2>$null) } catch { }
        $hasPinned = $sdks -match [regex]::Escape($pinned)
        $checks += [pscustomobject]@{
            Check    = 'dotnet-sdk'
            Required = $true
            Pass     = [bool]$hasPinned
            Detail   = if ($hasPinned) { "Found $pinned" } else { "Need .NET SDK $pinned. Install with the dotnet-install script (see tools/dotnet-install.ps1)." }
        }
    } else {
        $checks += [pscustomobject]@{
            Check    = 'global.json'
            Required = $true
            Pass     = $false
            Detail   = "global.json not found at $globalJson — RepoRoot wrong?"
        }
    }

    # 2) ripgrep
    $rg = Get-Command rg -ErrorAction SilentlyContinue
    $checks += [pscustomobject]@{
        Check    = 'ripgrep'
        Required = $false
        Pass     = [bool]$rg
        Detail   = if ($rg) { "Found $($rg.Source)" } else { 'rg not on PATH. Install with `winget install BurntSushi.ripgrep.MSVC` or `scoop install ripgrep`. Required by Find-Code.' }
    }

    # 3) Pester 5
    $pester = Get-Module Pester -ListAvailable | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
    $checks += [pscustomobject]@{
        Check    = 'pester-5+'
        Required = $false
        Pass     = [bool]$pester
        Detail   = if ($pester) { "Found Pester $($pester.Version)" } else { 'No Pester 5+ available. Run `Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0`.' }
    }

    # 4) pwsh shim
    $checks += [pscustomobject]@{
        Check    = 'wizard-shim'
        Required = $false
        Pass     = [bool]$env:WIZARD_PWSH_CONTROL
        Detail   = if ($env:WIZARD_PWSH_CONTROL) { 'WIZARD_PWSH_CONTROL is set; running under wizard pwsh.' } else { 'WIZARD_PWSH_CONTROL is NOT set — runtime cmdlets work, but startup hardening is off.' }
    }

    $required = $checks | Where-Object Required
    $failedRequired = $required | Where-Object { -not $_.Pass }

    $result = [pscustomobject]@{
        PSTypeName     = 'WizardBuildPrereqs'
        RepoRoot       = $RepoRoot
        Checks         = $checks
        AllRequiredPass = (-not $failedRequired)
    }

    if ($failedRequired -and -not $Quiet) {
        $msgs = $failedRequired | ForEach-Object { "[$($_.Check)] $($_.Detail)" }
        throw "Test-WizardBuildPrereqs: required checks failed:`n  - $($msgs -join "`n  - ")"
    }

    return $result
}
