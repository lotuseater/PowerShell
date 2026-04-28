# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Get-WizardFirstMovesStats {
    <#
    .SYNOPSIS
        Reports first_moves prediction stats for a repo.

    .DESCRIPTION
        Reads the per-repo `.first_moves.db` SQLite file (auto-created by
        the first_moves UserPromptSubmit hook on first fire) and reports
        total fires, unique paths predicted, paths that were actually hit
        by subsequent Read calls, and last fire timestamp. Useful to see
        whether the predictor is paying off in a given project.

    .PARAMETER RepoPath
        Path to the repo. Defaults to the current location.

    .EXAMPLE
        PS> Get-WizardFirstMovesStats

        RepoPath         : C:\Users\Oleh\Documents\GitHub\Wizard_Erasmus
        TotalFires       : 14
        UniquePaths      : 23
        PathsWithHits    : 8
        TotalHits        : 47
        HitRate          : 2.04
        LastFiredUtc     : 2026-04-28T12:34:56Z

    .EXAMPLE
        PS> Get-WizardFirstMovesStats -RepoPath C:\Users\Oleh\Documents\GitHub\Cognos
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [string] $RepoPath
    )

    if (-not $RepoPath) { $RepoPath = (Get-Location).ProviderPath }
    if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
        Write-Warning "Not a directory: $RepoPath"
        return $null
    }
    $db = Join-Path $RepoPath '.first_moves.db'
    if (-not (Test-Path -LiteralPath $db)) {
        Write-Warning "No .first_moves.db in $RepoPath. The predictor hasn't fired here yet — open a Claude Code session or call mcp__wizard__first_moves_predict to seed it."
        return $null
    }
    # Use Python's sqlite3 since pwsh has no native SQLite.
    $py = if (Get-Command 'py' -ErrorAction SilentlyContinue) { @('py', '-3.14') } else { @('python') }
    $script = @"
import json, sqlite3, sys
db = sys.argv[1]
conn = sqlite3.connect(db)
try:
    total = conn.execute('SELECT COUNT(*) FROM prefetch_log').fetchone()[0]
    paths = conn.execute('SELECT COUNT(*) FROM path_freq').fetchone()[0]
    with_hits = conn.execute('SELECT COUNT(*) FROM path_freq WHERE hit_count > 0').fetchone()[0]
    hits = conn.execute('SELECT COALESCE(SUM(hit_count), 0) FROM path_freq').fetchone()[0]
    last = conn.execute('SELECT MAX(fired_at) FROM prefetch_log').fetchone()[0]
finally:
    conn.close()
print(json.dumps({
    'total_fires': total,
    'unique_paths': paths,
    'paths_with_hits': with_hits,
    'total_hits': hits,
    'hit_rate': (hits / paths) if paths else 0.0,
    'last_fired': last,
}))
"@
    $tmp = New-TemporaryFile
    Set-Content -LiteralPath $tmp.FullName -Value $script -Encoding utf8
    try {
        $out = & $py[0] $py[1..($py.Length - 1)] $tmp.FullName $db 2>$null
    } finally {
        Remove-Item -LiteralPath $tmp.FullName -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0 -or -not $out) {
        Write-Warning "Failed to read $db (corrupted or python unavailable)."
        return $null
    }
    $stats = $out | ConvertFrom-Json
    $lastUtc = $null
    if ($stats.last_fired) {
        $lastUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$stats.last_fired).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    [pscustomobject]@{
        RepoPath      = $RepoPath
        TotalFires    = [int]$stats.total_fires
        UniquePaths   = [int]$stats.unique_paths
        PathsWithHits = [int]$stats.paths_with_hits
        TotalHits     = [int]$stats.total_hits
        HitRate       = [math]::Round([double]$stats.hit_rate, 2)
        LastFiredUtc  = $lastUtc
    }
}
