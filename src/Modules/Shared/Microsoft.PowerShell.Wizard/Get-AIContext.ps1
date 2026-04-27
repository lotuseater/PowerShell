# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Get-AIContext {
    <#
    .SYNOPSIS
        Return a line-numbered slice of a file. Streams large files via ReadLines() so memory
        stays bounded for multi-MB sources.

    .DESCRIPTION
        The right tool for "show me the function around line 1850 of ConsoleHost.cs" without
        loading the whole 10k-line file into the model.

    .EXAMPLE
        Get-AIContext -File ConsoleHost.cs -StartLine 1800 -Radius 50
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $File,

        [Parameter(Position = 1)]
        [int] $StartLine = 1,

        [int] $Radius = 40
    )

    $resolved = (Resolve-Path -LiteralPath $File).ProviderPath
    if (-not (Test-Path -LiteralPath $resolved)) {
        throw "Get-AIContext: file not found: $File"
    }

    $startWanted = [Math]::Max(1, $StartLine - $Radius)
    $endWanted = $StartLine + $Radius
    $lineNum = 0
    foreach ($line in [System.IO.File]::ReadLines($resolved)) {
        $lineNum++
        if ($lineNum -lt $startWanted) { continue }
        if ($lineNum -gt $endWanted) { break }
        '{0,6}: {1}' -f $lineNum, $line
    }
}
