# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Install-RepoAIContract.ps1" -Tags "Feature" {
    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot '..\..\..\..\tools\wizard\Install-RepoAIContract.ps1' | Resolve-Path | ForEach-Object Path
        $script:Pwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh'

        function New-FakeRepo {
            param([string] $Dir, [string] $RemoteUrl)
            New-Item -ItemType Directory -Force -Path $Dir | Out-Null
            & git -C $Dir init --quiet 2>$null | Out-Null
            & git -C $Dir config user.email 'test@example.com' 2>$null
            & git -C $Dir config user.name 'test' 2>$null
            if ($RemoteUrl) {
                & git -C $Dir remote add origin $RemoteUrl 2>$null
            }
            Set-Content -LiteralPath (Join-Path $Dir 'README.md') -Value 'fake repo'
            & git -C $Dir add . 2>$null
            & git -C $Dir commit -m init --quiet 2>$null | Out-Null
        }

        function Invoke-Installer {
            param([string[]] $ExtraArgs)
            $args = @('-NoProfile', '-NoLogo', '-File', $script:Script) + $ExtraArgs
            $proc = & $script:Pwsh @args 2>&1
            return [pscustomobject]@{
                Output   = $proc -join "`n"
                ExitCode = $LASTEXITCODE
            }
        }
    }

    It "Local mode writes AI files into the repo root" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-aic-local-$([Guid]::NewGuid().ToString('N'))")
        try {
            New-FakeRepo -Dir $tmp -RemoteUrl 'https://github.com/some-user/some-repo.git'
            $r = Invoke-Installer -ExtraArgs @('-Path', $tmp, '-RepoType', 'Local', '-Confirm:$false')
            $r.ExitCode | Should -Be 0
            (Test-Path -LiteralPath (Join-Path $tmp 'AGENTS.md'))           | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $tmp 'CLAUDE.md'))           | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $tmp '.rgignore'))            | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $tmp '.aiignore'))            | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $tmp '.claude/skills/repo-search/SKILL.md')) | Should -BeTrue
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Upstream mode adds entries to .git/info/exclude (no commit pollution)" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-aic-up-$([Guid]::NewGuid().ToString('N'))")
        try {
            New-FakeRepo -Dir $tmp -RemoteUrl 'https://github.com/PowerShell/PowerShell.git'
            $r = Invoke-Installer -ExtraArgs @('-Path', $tmp, '-RepoType', 'Upstream', '-Confirm:$false')
            $r.ExitCode | Should -Be 0

            $excludeFile = Join-Path $tmp '.git/info/exclude'
            (Test-Path -LiteralPath $excludeFile) | Should -BeTrue
            $content = Get-Content -LiteralPath $excludeFile -Raw
            $content | Should -Match 'wizard-ai-contract'
            $content | Should -Match 'AGENTS\.md'
            $content | Should -Match 'CLAUDE\.md'
            $content | Should -Match '\.rgignore'

            # Re-running should be idempotent — no duplicate marker block.
            $r2 = Invoke-Installer -ExtraArgs @('-Path', $tmp, '-RepoType', 'Upstream', '-Confirm:$false')
            if ($r2.ExitCode -ne 0) {
                throw "Second run failed (exit $($r2.ExitCode)). Output: $($r2.Output)"
            }
            $content2 = Get-Content -LiteralPath $excludeFile -Raw
            ([regex]::Matches($content2, 'wizard-ai-contract')).Count | Should -Be 1
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
