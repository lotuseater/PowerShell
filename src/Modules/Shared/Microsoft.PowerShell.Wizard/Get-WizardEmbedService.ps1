# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Get-WizardEmbedService {
    <#
    .SYNOPSIS
        Reports the status of the Wizard warm embedding daemon used by
        the first_moves prediction hook.

    .DESCRIPTION
        Pings the embedding daemon (sentence-transformers all-MiniLM-L6-v2)
        and returns its uptime, request count, and idle time. The daemon
        normally lives at 127.0.0.1:<port> with discovery via
        ~/.claude/cache/wizard_embed_service.json and is auto-spawned by
        the Claude SessionStart hook when WIZARD_FIRST_MOVES_EMBED is not
        explicitly disabled.

        Returns $null and writes a warning if the daemon isn't reachable.

    .EXAMPLE
        PS> Get-WizardEmbedService

        pong       : True
        uptime_s   : 2374.1
        served     : 142
        idle_s     : 18.7

    .LINK
        Stop-WizardEmbedService
        Build-FirstMovesCorpus
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
    $output = & $py[0] $py[1..($py.Length - 1)] $client ping 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        Write-Warning 'Embedding daemon is not running. The Claude SessionStart hook will spawn it on next session boot, or run `python src/mcp/embed_client.py ensure-started`.'
        return $null
    }
    try {
        return ($output | Out-String | ConvertFrom-Json)
    } catch {
        return $output
    }
}
