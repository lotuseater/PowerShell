# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Stop-WizardEmbedService {
    <#
    .SYNOPSIS
        Asks the Wizard warm embedding daemon to shut down cleanly.

    .DESCRIPTION
        Sends a `shutdown` request over the loopback control socket. The
        daemon retracts its discovery file and exits, freeing the
        sentence-transformers model from memory. The next first_moves
        hook fire (or the next Claude SessionStart) will respawn it.

        Useful when:
        - You want to reload the daemon after rebuilding the embedding
          index (`Build-FirstMovesCorpus` + indexer)
        - You're debugging hook latency and want a clean baseline
        - You're temporarily turning the feature off without setting
          `$env:WIZARD_FIRST_MOVES_EMBED=0`

    .EXAMPLE
        PS> Stop-WizardEmbedService
        { "shutting_down": true }

    .LINK
        Get-WizardEmbedService
    #>
    [CmdletBinding()]
    param(
        [string] $WizardRoot
    )

    if (-not $WizardRoot) {
        $candidate = Join-Path $env:USERPROFILE 'Documents\GitHub\Wizard_Erasmus'
        if (Test-Path -LiteralPath $candidate) { $WizardRoot = $candidate }
    }
    if (-not $WizardRoot) {
        Write-Warning "Wizard_Erasmus repo not found. Pass -WizardRoot <path>."
        return $null
    }
    $client = Join-Path $WizardRoot 'src\mcp\embed_client.py'
    if (-not (Test-Path -LiteralPath $client)) {
        Write-Warning "embed_client.py not found at $client."
        return $null
    }
    $py = if (Get-Command 'py' -ErrorAction SilentlyContinue) { @('py', '-3.14') } else { @('python') }
    $output = & $py[0] $py[1..($py.Length - 1)] $client shutdown 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        Write-Warning 'No embedding daemon was running.'
        return $null
    }
    try {
        return ($output | Out-String | ConvertFrom-Json)
    } catch {
        return $output
    }
}
