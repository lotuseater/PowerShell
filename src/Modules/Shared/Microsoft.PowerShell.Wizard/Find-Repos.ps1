# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Find-Repos {
    <#
    .SYNOPSIS
        Find git working trees under a root directory.

    .DESCRIPTION
        Returns one record per repo: { Name, Path, RemoteUrl }. Defaults to the user's
        likely source roots ($HOME/Documents/GitHub, $HOME/source) but can be overridden.

    .EXAMPLE
        Find-Repos -Root C:\Users\Oleh\Documents\GitHub
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $Root,
        [int] $MaxDepth = 4
    )

    if (-not $Root -or $Root.Count -eq 0) {
        $Root = @(
            (Join-Path $HOME 'Documents/GitHub'),
            (Join-Path $HOME 'source'),
            (Join-Path $HOME 'src')
        ) | Where-Object { Test-Path -LiteralPath $_ }
    }

    foreach ($r in $Root) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                $candidate = $_.FullName
                if (Test-Path -LiteralPath (Join-Path $candidate '.git')) {
                    $remote = $null
                    try {
                        $remote = (& git -C $candidate config --get remote.origin.url 2>$null)
                    } catch { }
                    [pscustomobject]@{
                        PSTypeName = 'WizardRepo'
                        Name       = $_.Name
                        Path       = $candidate
                        RemoteUrl  = $remote
                    }
                }
            }
    }
}
