#Requires -Version 7.0
<#
.SYNOPSIS
    Installs the Wizard repo AI-contract templates (AGENTS.md, CLAUDE.md, .rgignore, .aiignore,
    .claude/skills/, .agents/skills/) into a target repository.

.DESCRIPTION
    Idempotent. Re-runs don't duplicate content. For -RepoType Upstream, marker files are
    *not* committed: they go through .git/info/exclude so they remain untracked.

.PARAMETER Path
    Target repository root. Default: current directory.

.PARAMETER RepoType
    Auto (default): detect by reading the remote URL. Upstream: behave as if this is a fork
    we don't want to commit AI files into. Local: commit AI files freely.

.PARAMETER Force
    Overwrite existing AGENTS.md / CLAUDE.md instead of inserting between markers.

.PARAMETER WhatIf
    Standard PowerShell -WhatIf support; report planned changes without writing.

.EXAMPLE
    Install-RepoAIContract.ps1 -Path C:\Users\Oleh\Documents\GitHub\Wizard_Erasmus

    Installs templates into Wizard_Erasmus, picking up its remote URL automatically.

.EXAMPLE
    Install-RepoAIContract.ps1 -Path . -RepoType Upstream

    Installs templates without committing them — uses .git/info/exclude.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $Path = (Get-Location).ProviderPath,

    [ValidateSet('Auto', 'Upstream', 'Local')]
    [string] $RepoType = 'Auto',

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# Resolve the templates dir relative to this script.
$templatesRoot = Join-Path -Path $PSScriptRoot -ChildPath 'templates'
if (-not (Test-Path -LiteralPath $templatesRoot)) {
    throw "Install-RepoAIContract: templates dir missing at $templatesRoot"
}

# Resolve the repo root.
$repoRoot = $null
try { $repoRoot = (& git -C $Path rev-parse --show-toplevel 2>$null).Trim() } catch { }
if (-not $repoRoot) {
    throw "Install-RepoAIContract: $Path is not in a git working tree."
}

# Detect the repo flavour if Auto.
if ($RepoType -eq 'Auto') {
    $remote = ''
    try { $remote = (& git -C $repoRoot config --get remote.origin.url 2>$null).Trim() } catch { }
    # Heuristic: if the user is not the owner, treat as Upstream so we don't pollute their fork.
    if ($remote -match 'github.com[:/]([^/]+)/') {
        $owner = $Matches[1]
        if ($owner -in @('PowerShell', 'microsoft', 'dotnet', 'openai', 'anthropic')) {
            $RepoType = 'Upstream'
        } else {
            $RepoType = 'Local'
        }
    } else {
        $RepoType = 'Local'
    }
    Write-Verbose "Install-RepoAIContract: detected RepoType=$RepoType from remote $remote"
}

$markerStart = '<!-- wizard-managed-block:start -->'
$markerEnd   = '<!-- wizard-managed-block:end -->'

function Copy-OrUpdate-Markdown {
    param([string] $TemplatePath, [string] $TargetPath)

    $body = Get-Content -LiteralPath $TemplatePath -Raw
    $managed = "$markerStart`n$body`n$markerEnd"

    if (-not (Test-Path -LiteralPath $TargetPath) -or $Force) {
        if ($PSCmdlet.ShouldProcess($TargetPath, 'Write template')) {
            $managed | Set-Content -LiteralPath $TargetPath -Encoding utf8 -NoNewline
        }
        return
    }

    $existing = Get-Content -LiteralPath $TargetPath -Raw
    if ($existing -match [regex]::Escape($markerStart)) {
        # Replace just our managed block.
        $pattern = "$([regex]::Escape($markerStart)).*?$([regex]::Escape($markerEnd))"
        $new = [regex]::Replace($existing, $pattern, [System.Text.RegularExpressions.Regex]::Escape($managed) -replace '\\(.)', '$1', 1)
        # Simpler: just rewrite using string find/replace.
        $startIdx = $existing.IndexOf($markerStart)
        $endIdx = $existing.IndexOf($markerEnd, $startIdx)
        if ($startIdx -ge 0 -and $endIdx -gt $startIdx) {
            $new = $existing.Substring(0, $startIdx) + $managed + $existing.Substring($endIdx + $markerEnd.Length)
            if ($PSCmdlet.ShouldProcess($TargetPath, 'Update managed block')) {
                $new | Set-Content -LiteralPath $TargetPath -Encoding utf8 -NoNewline
            }
            return
        }
    }

    # Append a managed block at the end of the existing file.
    if ($PSCmdlet.ShouldProcess($TargetPath, 'Append managed block')) {
        ($existing.TrimEnd() + "`n`n" + $managed + "`n") | Set-Content -LiteralPath $TargetPath -Encoding utf8 -NoNewline
    }
}

function Copy-Verbatim {
    param([string] $TemplatePath, [string] $TargetPath)

    if ((Test-Path -LiteralPath $TargetPath) -and -not $Force) {
        Write-Verbose "Skipping existing $TargetPath (use -Force to overwrite)"
        return
    }
    $targetDir = Split-Path -Parent $TargetPath
    if (-not (Test-Path -LiteralPath $targetDir)) {
        if ($PSCmdlet.ShouldProcess($targetDir, 'Create directory')) {
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess($TargetPath, 'Copy template')) {
        Copy-Item -LiteralPath $TemplatePath -Destination $TargetPath -Force
    }
}

# Walk the templates dir.
$mdFiles = @('AGENTS.md', 'CLAUDE.md')
foreach ($name in $mdFiles) {
    $tpl = Join-Path $templatesRoot $name
    $tgt = Join-Path $repoRoot $name
    Copy-OrUpdate-Markdown -TemplatePath $tpl -TargetPath $tgt
}

$ignoreFiles = @('.rgignore', '.aiignore')
foreach ($name in $ignoreFiles) {
    $tpl = Join-Path $templatesRoot $name
    $tgt = Join-Path $repoRoot $name
    Copy-Verbatim -TemplatePath $tpl -TargetPath $tgt
}

# Skill dirs — copy whole tree.
$skillRoots = @('.claude/skills', '.agents/skills')
foreach ($skillRoot in $skillRoots) {
    $srcDir = Join-Path $templatesRoot $skillRoot
    if (-not (Test-Path -LiteralPath $srcDir)) { continue }
    $tgtDir = Join-Path $repoRoot $skillRoot
    Get-ChildItem -LiteralPath $srcDir -Directory | ForEach-Object {
        $skillName = $_.Name
        $tgtSkill = Join-Path $tgtDir $skillName
        if ((Test-Path -LiteralPath (Join-Path $tgtSkill 'SKILL.md')) -and -not $Force) {
            Write-Verbose "Skipping existing skill $tgtSkill"
            return
        }
        if ($PSCmdlet.ShouldProcess($tgtSkill, 'Copy skill directory')) {
            if (-not (Test-Path -LiteralPath $tgtSkill)) { New-Item -ItemType Directory -Force -Path $tgtSkill | Out-Null }
            Copy-Item -LiteralPath (Join-Path $_.FullName 'SKILL.md') -Destination (Join-Path $tgtSkill 'SKILL.md') -Force
        }
    }
}

# For Upstream repos, add the AI files to .git/info/exclude so they never sneak into a PR.
if ($RepoType -eq 'Upstream') {
    $excludeFile = Join-Path $repoRoot '.git/info/exclude'
    if (Test-Path -LiteralPath $excludeFile) {
        $existing = Get-Content -LiteralPath $excludeFile -Raw
        $marker = '# wizard-ai-contract'
        if ($existing -notmatch [regex]::Escape($marker)) {
            $entries = @(
                ''
                $marker
                'AGENTS.md'
                'CLAUDE.md'
                '.rgignore'
                '.aiignore'
                '.claude/skills/'
                '.agents/skills/'
                '.ai/'
            )
            if ($PSCmdlet.ShouldProcess($excludeFile, 'Append wizard exclude entries')) {
                Add-Content -LiteralPath $excludeFile -Value ($entries -join "`n") -Encoding utf8
            }
        }
    }
}

[pscustomobject]@{
    PSTypeName = 'WizardRepoAIContract'
    RepoRoot   = $repoRoot
    RepoType   = $RepoType
    Installed  = @{
        AGENTS_md   = Join-Path $repoRoot 'AGENTS.md'
        CLAUDE_md   = Join-Path $repoRoot 'CLAUDE.md'
        rgignore    = Join-Path $repoRoot '.rgignore'
        aiignore    = Join-Path $repoRoot '.aiignore'
        ClaudeSkills = Join-Path $repoRoot '.claude/skills'
        AgentSkills = Join-Path $repoRoot '.agents/skills'
    }
}
