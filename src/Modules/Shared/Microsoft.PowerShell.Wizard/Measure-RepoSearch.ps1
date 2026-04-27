# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Measure-RepoSearch {
    <#
    .SYNOPSIS
        Benchmark `rg` vs PowerShell's recursive Select-String for the same pattern.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Pattern = 'TODO',
        [string] $Path = (Get-Location).ProviderPath,
        [int] $MaxCount = 100
    )

    $rgAvailable = [bool](Get-Command rg -ErrorAction SilentlyContinue)

    $results = @()

    if ($rgAvailable) {
        $sw1 = [System.Diagnostics.Stopwatch]::StartNew()
        $rgHits = & rg --line-number --smart-case --hidden `
            --glob '!.git/**' --glob '!bin/**' --glob '!obj/**' `
            --glob '!node_modules/**' --glob '!dist/**' --glob '!build/**' `
            --max-count $MaxCount -- $Pattern $Path 2>$null
        $sw1.Stop()
        $results += [pscustomobject]@{
            Tool     = 'rg'
            Hits     = ($rgHits | Measure-Object).Count
            Elapsed  = $sw1.Elapsed
            ElapsedMs = [Math]::Round($sw1.Elapsed.TotalMilliseconds, 1)
        }
    }

    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    $psHits = Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](\.git|bin|obj|node_modules|dist|build|coverage)[\\/]' } |
        Select-String -Pattern $Pattern -SimpleMatch:$false |
        Select-Object -First $MaxCount
    $sw2.Stop()
    $results += [pscustomobject]@{
        Tool     = 'powershell-recursion'
        Hits     = ($psHits | Measure-Object).Count
        Elapsed  = $sw2.Elapsed
        ElapsedMs = [Math]::Round($sw2.Elapsed.TotalMilliseconds, 1)
    }

    return $results
}
