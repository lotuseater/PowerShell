# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Find-Code {
    <#
    .SYNOPSIS
        Fast ripgrep-based code search with sane defaults for agent contexts.

    .DESCRIPTION
        Wraps `rg` with broad artifact-ignore globs, line numbers, and a default cap of 120
        matches. The point is to keep the model's context bounded by default; raise -MaxCount
        only when you actually need more.

        Returns plain rg output by default. With -Json, emits rg's JSON event stream (one
        per line). With -Compact, emits one match per line as `path:line:col:snippet` for
        easy ConvertFrom-Csv-style downstream use.

    .EXAMPLE
        Find-Code -Pattern 'TODO' -MaxCount 50
        Find-Code -Pattern 'class \w+:' -Path src/ -Include @('*.py')
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Pattern,

        [string] $Path = (Get-Location).ProviderPath,

        [int] $Context = 2,
        # Default lowered from 120 → 40 (2026-04-28). 80 % of agent searches want the first
        # handful of hits; rare callers bump explicitly. Each match averages ~100 chars
        # incl. context, so the default emits ≤ 4 KB / ~1 k tokens by itself.
        [int] $MaxCount = 40,
        [string[]] $Include,
        [switch] $FilesOnly,
        [switch] $Json,
        [switch] $Compact
    )

    $rg = Get-Command rg -ErrorAction SilentlyContinue
    if (-not $rg) {
        throw "Find-Code: ripgrep (rg) is required. Install it with 'winget install BurntSushi.ripgrep.MSVC' or 'scoop install ripgrep'."
    }

    $ignoreGlobs = @(
        '!.git/**', '!bin/**', '!obj/**', '!dist/**', '!build/**',
        '!coverage/**', '!node_modules/**', '!packages/**', '!Packages/**',
        '!nuget-artifacts/**', '!.venv/**', '!venv/**', '!__pycache__/**',
        '!.pytest_cache/**', '!.mypy_cache/**', '!.ruff_cache/**',
        '!storage/**', '!artifacts/**', '!tmp/**', '!logfile/**', '!crtf/**',
        '!**/pester-analysis-*/**', '!test/perf/BenchmarkDotNet.Artifacts/**',
        '!*.dll', '!*.pdb', '!*.nupkg', '!*.zip', '!*.tar.gz', '!*.binlog',
        '!*.log', '!*.min.js', '!*.map'
    )

    $rgArgs = @('--line-number', '--column', '--smart-case', '--trim', '--hidden', '--max-columns', '220')
    foreach ($g in $ignoreGlobs) { $rgArgs += @('--glob', $g) }
    foreach ($g in ($Include | Where-Object { $_ })) { $rgArgs += @('--glob', $g) }

    if ($FilesOnly) {
        $rgArgs += '--files-with-matches'
    } else {
        $rgArgs += @('--context', $Context.ToString())
    }
    if ($Json) { $rgArgs += '--json' }

    $rgArgs += '--max-count'; $rgArgs += $MaxCount.ToString()
    $rgArgs += '--'; $rgArgs += $Pattern; $rgArgs += $Path

    $output = & rg @rgArgs

    if ($Compact -and -not $Json -and -not $FilesOnly) {
        # rg default: path:line:col:text  on hit lines; group separators "--" between context.
        return $output | Where-Object { $_ -and $_ -notmatch '^--$' } | Select-Object -First $MaxCount
    }
    $hardCap = if ($MaxCount -lt 1024) { 1024 } else { $MaxCount * 4 }
    return $output | Select-Object -First $hardCap
}
