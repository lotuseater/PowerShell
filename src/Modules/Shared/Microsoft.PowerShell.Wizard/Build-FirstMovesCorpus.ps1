# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Build-FirstMovesCorpus {
    <#
    .SYNOPSIS
        Re-mines the per-machine Claude Code transcript corpus used by the
        first_moves prediction hook.

    .DESCRIPTION
        Walks ~/.claude/projects/*/*.jsonl and produces:
            <repo>/data/first_moves_corpus.jsonl     one line per accepted session
            <repo>/data/first_moves_index.json       per-project rankings

        Filters out machine-generated openings (Wizard Team App role prompts).
        The hook `first_moves_hook.py` consumes the index file at session start
        to predict and pre-cache the first 5 file reads.

        Re-runnable. Idempotent. Use after a long stretch of work, or before
        running the A/B harness.

    .PARAMETER WizardRoot
        Path to the Wizard_Erasmus repo. Defaults to
        ~/Documents/GitHub/Wizard_Erasmus when present.

    .PARAMETER ProjectsDir
        Override for the transcripts dir (rarely needed; defaults to
        ~/.claude/projects).

    .PARAMETER Limit
        Optional cap on number of transcripts processed (debugging only).

    .EXAMPLE
        PS> Build-FirstMovesCorpus

        Re-mines the corpus and prints the manifest:
            { transcripts_seen: 1654, accepted: 372, rejected_role_prompts: 1282 }

    .EXAMPLE
        PS> Build-FirstMovesCorpus -Limit 100

        Quick smoke run.

    .LINK
        https://github.com/OgelGbuzax/Wizard_Erasmus/blob/master/docs/research/first_moves_prediction.md
    #>
    [CmdletBinding()]
    param(
        [string] $WizardRoot,
        [string] $ProjectsDir,
        [int]    $Limit = 0
    )

    if (-not $WizardRoot) {
        $candidate = Join-Path $env:USERPROFILE 'Documents\GitHub\Wizard_Erasmus'
        if (Test-Path -LiteralPath $candidate) {
            $WizardRoot = $candidate
        } else {
            throw "Wizard_Erasmus repo not found. Pass -WizardRoot <path>."
        }
    }
    $script = Join-Path $WizardRoot 'scripts\build_first_moves_corpus.py'
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Corpus miner not found at $script. Pull the latest Wizard_Erasmus."
    }

    $args = @($script)
    if ($ProjectsDir) { $args += @('--projects-dir', $ProjectsDir) }
    if ($Limit -gt 0) { $args += @('--limit', "$Limit") }

    # Prefer Python 3.14 (consistent with the rest of the Wizard hook stack).
    $py = if (Get-Command 'py' -ErrorAction SilentlyContinue) { @('py', '-3.14') } else { @('python') }
    & $py[0] $py[1..($py.Length - 1)] $args
}
