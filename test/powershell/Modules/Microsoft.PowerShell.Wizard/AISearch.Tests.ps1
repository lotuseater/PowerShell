# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Find-Code, Get-AIContext, Find-Repos" -Tags "Feature" {
    BeforeAll {
        Import-Module (Join-Path $PSHOME "Modules/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psd1") -Force

        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-aisearch-tests-$([Guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

        # Build a tiny synthetic git repo with two files containing distinct patterns.
        $repoA = Join-Path $TempRoot 'repoA'
        New-Item -ItemType Directory -Force -Path $repoA | Out-Null
        & git -C $repoA init --quiet 2>$null | Out-Null
        & git -C $repoA config user.email 'test@example.com' 2>$null
        & git -C $repoA config user.name 'test' 2>$null
        Set-Content -LiteralPath (Join-Path $repoA 'a.txt') -Value @'
line 1
ZAP-PATTERN-X here
line 3 with TODO
line 4
'@ -NoNewline
        Set-Content -LiteralPath (Join-Path $repoA 'b.py') -Value @'
def foo():
    return 'ZAP-PATTERN-X'
'@ -NoNewline
        & git -C $repoA add . 2>$null
        & git -C $repoA commit -m init --quiet 2>$null

        $repoB = Join-Path $TempRoot 'repoB'
        New-Item -ItemType Directory -Force -Path $repoB | Out-Null
        & git -C $repoB init --quiet 2>$null | Out-Null
        & git -C $repoB config user.email 'test@example.com' 2>$null
        & git -C $repoB config user.name 'test' 2>$null
        Set-Content -LiteralPath (Join-Path $repoB 'README.md') -Value 'no zaps here'
        & git -C $repoB add . 2>$null
        & git -C $repoB commit -m init --quiet 2>$null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Find-Code finds matches in the synthetic repo" -Skip:(-not (Get-Command rg -ErrorAction SilentlyContinue)) {
        $hits = Find-Code -Pattern 'ZAP-PATTERN-X' -Path $TempRoot
        ($hits -join "`n") | Should -Match 'a\.txt'
        ($hits -join "`n") | Should -Match 'b\.py'
    }

    It "Find-Code -FilesOnly returns only file paths" -Skip:(-not (Get-Command rg -ErrorAction SilentlyContinue)) {
        $files = Find-Code -Pattern 'ZAP-PATTERN-X' -Path $TempRoot -FilesOnly
        $files.Count | Should -BeGreaterThan 0
        foreach ($f in $files) {
            (Test-Path -LiteralPath $f) | Should -BeTrue
        }
    }

    It "Find-Code throws when rg is missing" -Skip:([bool](Get-Command rg -ErrorAction SilentlyContinue)) {
        { Find-Code -Pattern 'TODO' } | Should -Throw '*ripgrep*'
    }

    It "Find-Repos discovers our two synthetic repos" {
        $repos = Find-Repos -Root $TempRoot
        $names = $repos | ForEach-Object Name
        $names | Should -Contain 'repoA'
        $names | Should -Contain 'repoB'
    }

    It "Find-CodeAcrossRepos isolates by repo" -Skip:(-not (Get-Command rg -ErrorAction SilentlyContinue)) {
        $results = @(Find-CodeAcrossRepos -Pattern 'ZAP-PATTERN-X' -Root $TempRoot)
        $results.Count | Should -Be 1
        $results[0].Repository | Should -BeExactly 'repoA'
    }

    It "Get-AIContext returns the requested line range with line numbers" {
        $file = Join-Path $TempRoot 'repoA/a.txt'
        $lines = Get-AIContext -File $file -StartLine 2 -Radius 1
        $lines.Count | Should -Be 3
        $lines[0] | Should -Match '^\s+1: line 1'
        $lines[1] | Should -Match '^\s+2: ZAP-PATTERN-X'
    }

    It "Get-AIContext throws on missing file" {
        { Get-AIContext -File (Join-Path $TempRoot 'nope.txt') } | Should -Throw
    }
}

Describe "Get-RepoProfile, Update-RepoDigest, Measure-RepoSearch" -Tags "Feature" {
    BeforeAll {
        Import-Module (Join-Path $PSHOME "Modules/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psd1") -Force

        $script:Repo = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-repoprofile-$([Guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Force -Path $Repo | Out-Null
        & git -C $Repo init --quiet 2>$null | Out-Null
        & git -C $Repo config user.email 'test@example.com' 2>$null
        & git -C $Repo config user.name 'test' 2>$null
        Set-Content -LiteralPath (Join-Path $Repo 'pyproject.toml') -Value '[project]'
        New-Item -ItemType Directory -Force -Path (Join-Path $Repo 'tests') | Out-Null
        Set-Content -LiteralPath (Join-Path $Repo 'tests/test_foo.py') -Value 'def test_x(): assert True'
        Set-Content -LiteralPath (Join-Path $Repo 'main.py') -Value 'print("hi")'
        & git -C $Repo add . 2>$null
        & git -C $Repo commit -m init --quiet 2>$null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:Repo) { Remove-Item -LiteralPath $script:Repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Get-RepoProfile detects python repo" {
        $p = Get-RepoProfile -Path $Repo
        # Compare paths normalised — git returns forward slashes on Windows, Join-Path returns back-slashes.
        $p.Root.Replace('/', '\') | Should -BeExactly $Repo.Replace('/', '\')
        $p.HasPyProject | Should -BeTrue
        $p.HasPyTests | Should -BeTrue
        $p.HasSolution | Should -BeFalse
        $p.PrimaryHints | Should -Contain 'python'
    }

    It "Update-RepoDigest writes .ai/repo-map.md with top-level paths" {
        $r = Update-RepoDigest -Path $Repo
        $r.OutFile | Should -Match '\.ai[\\/]repo-map\.md$'
        Test-Path -LiteralPath $r.OutFile | Should -BeTrue
        $content = Get-Content -LiteralPath $r.OutFile -Raw
        $content | Should -Match 'main\.py|tests'
        # β5: managed-block markers are present so subsequent runs preserve hand-written content.
        $content | Should -Match '<!-- wizard-managed-block:start -->'
        $content | Should -Match '<!-- wizard-managed-block:end -->'
    }

    It "Update-RepoDigest preserves user content outside the managed block on regeneration" {
        $r = Update-RepoDigest -Path $Repo
        $userAddition = "`n`n## User addition`n- This line must survive regeneration.`n"
        $original = Get-Content -LiteralPath $r.OutFile -Raw
        ($original + $userAddition) | Set-Content -LiteralPath $r.OutFile -Encoding utf8 -NoNewline

        $r2 = Update-RepoDigest -Path $Repo
        $regenerated = Get-Content -LiteralPath $r2.OutFile -Raw
        $regenerated | Should -Match 'This line must survive regeneration'
        # The managed block should still be a single pair of markers (no duplicates).
        ([regex]::Matches($regenerated, '<!-- wizard-managed-block:start -->')).Count | Should -Be 1
        ([regex]::Matches($regenerated, '<!-- wizard-managed-block:end -->')).Count | Should -Be 1
    }

    It "Measure-RepoSearch returns at least one tool result" {
        $r = @(Measure-RepoSearch -Pattern 'def' -Path $Repo)
        $r.Count | Should -BeGreaterOrEqual 1
        ($r | Where-Object Tool -eq 'powershell-recursion').Count | Should -Be 1
    }
}
