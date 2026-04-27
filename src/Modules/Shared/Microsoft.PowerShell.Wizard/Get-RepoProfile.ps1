# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Get-RepoProfile {
    <#
    .SYNOPSIS
        Detect the repo's build/test type so Invoke-RepoBuild / Invoke-RepoTest can route correctly.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string] $Path = (Get-Location).ProviderPath)

    $root = $null
    try {
        $root = (& git -C $Path rev-parse --show-toplevel 2>$null).Trim()
    } catch { }
    if (-not $root) { $root = $Path }

    $files = @()
    try {
        $files = & git -C $root ls-files 2>$null
    } catch { }

    function Test-AnyMatch { param($items, $pattern) [bool]($items | Where-Object { $_ -match $pattern } | Select-Object -First 1) }

    [pscustomobject]@{
        PSTypeName     = 'WizardRepoProfile'
        Root           = $root
        HasSolution    = [bool](Get-ChildItem -LiteralPath $root -Filter '*.sln' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        HasBuildPsm1   = Test-Path -LiteralPath (Join-Path $root 'build.psm1')
        HasPackageJson = Test-Path -LiteralPath (Join-Path $root 'package.json')
        HasPyProject   = Test-Path -LiteralPath (Join-Path $root 'pyproject.toml')
        HasCMakeLists  = Test-Path -LiteralPath (Join-Path $root 'CMakeLists.txt')
        HasPesterTests = Test-AnyMatch $files '\.Tests\.ps1$'
        HasDotNetTests = Test-AnyMatch $files 'Tests?\.csproj$'
        HasPyTests     = Test-AnyMatch $files '(^|/)tests?/.*\.py$'
        PrimaryHints   = @(
            if (Test-AnyMatch $files '\.cs$')              { 'csharp' }
            if (Test-AnyMatch $files '\.ps1$|\.psm1$')      { 'powershell' }
            if (Test-AnyMatch $files '\.py$')               { 'python' }
            if (Test-AnyMatch $files '\.ts$|\.tsx$')        { 'typescript' }
            if (Test-AnyMatch $files '\.js$|\.jsx$')        { 'javascript' }
            if (Test-AnyMatch $files '\.go$')               { 'go' }
            if (Test-AnyMatch $files '\.rs$')               { 'rust' }
            if (Test-AnyMatch $files '\.cpp$|\.cc$|\.h$')   { 'cpp' }
        ) | Select-Object -Unique
    }
}
