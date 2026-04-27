# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Find-CodeAcrossRepos {
    <#
    .SYNOPSIS
        Run Find-Code across every git repo discovered by Find-Repos.

    .DESCRIPTION
        Returns one record per repo that has matches: { Repository, Path, Matches }. The
        per-repo cap defaults to 40 to keep aggregate output bounded.

    .EXAMPLE
        Find-CodeAcrossRepos -Pattern 'WizardControlServer'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Pattern,

        [string[]] $Root,
        [int] $MaxPerRepo = 40
    )

    Find-Repos -Root $Root | ForEach-Object {
        $repo = $_
        $matches = Find-Code -Pattern $Pattern -Path $repo.Path -MaxCount $MaxPerRepo
        if ($matches) {
            [pscustomobject]@{
                PSTypeName = 'WizardRepoMatches'
                Repository = $repo.Name
                Path       = $repo.Path
                Matches    = @($matches)
            }
        }
    }
}
