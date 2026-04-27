# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Set-ClaudeTrust" -Tags "Feature" {
    BeforeAll {
        Import-Module (Join-Path $PSHOME "Modules/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psd1") -Force

        $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-trust-tests-$([Guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
        $script:FakeHome = Join-Path $Tmp 'fake.claude.json'
    }

    AfterAll {
        if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) {
            Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    BeforeEach {
        # Fresh empty config each test.
        '{"projects":{}}' | Set-Content -LiteralPath $FakeHome -Encoding utf8 -NoNewline
    }

    It "creates a new trusted project entry when none exists" {
        $r = Set-ClaudeTrust -Path $Tmp -ClaudeJsonPath $FakeHome
        $r.AlreadyTrusted | Should -BeFalse
        $r.Wrote | Should -BeTrue

        $config = Get-Content -LiteralPath $FakeHome -Raw | ConvertFrom-Json -AsHashtable
        $key = $r.Key
        $config['projects'].ContainsKey($key) | Should -BeTrue
        $config['projects'][$key]['hasTrustDialogAccepted'] | Should -BeTrue
    }

    It "is idempotent: second run returns AlreadyTrusted=`$true and does not rewrite" {
        Set-ClaudeTrust -Path $Tmp -ClaudeJsonPath $FakeHome | Out-Null
        $beforeMtime = (Get-Item -LiteralPath $FakeHome).LastWriteTimeUtc

        Start-Sleep -Milliseconds 100
        $r = Set-ClaudeTrust -Path $Tmp -ClaudeJsonPath $FakeHome
        $r.AlreadyTrusted | Should -BeTrue
        $r.Wrote | Should -BeFalse

        # File should not have been touched on the idempotent path.
        $afterMtime = (Get-Item -LiteralPath $FakeHome).LastWriteTimeUtc
        $afterMtime | Should -Be $beforeMtime
    }

    It "uses forward-slash form for the projects key (Claude Code convention)" {
        $r = Set-ClaudeTrust -Path $Tmp -ClaudeJsonPath $FakeHome
        $r.Key | Should -Not -Match '\\'
        $r.Key | Should -Match '/'
    }

    It "preserves an existing project entry's other fields" {
        $existing = @{
            projects = @{
                ($Tmp -replace '\\','/') = @{
                    hasTrustDialogAccepted = $false
                    history                = @('cmd1','cmd2')
                    customField            = 'keep me'
                }
            }
        } | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $FakeHome -Value $existing -Encoding utf8 -NoNewline

        Set-ClaudeTrust -Path $Tmp -ClaudeJsonPath $FakeHome | Out-Null

        $after = Get-Content -LiteralPath $FakeHome -Raw | ConvertFrom-Json -AsHashtable
        $key = $Tmp -replace '\\','/'
        $after['projects'][$key]['hasTrustDialogAccepted'] | Should -BeTrue
        $after['projects'][$key]['history'].Count | Should -Be 2
        $after['projects'][$key]['customField'] | Should -BeExactly 'keep me'
    }

    It "throws clearly when the claude.json path doesn't exist" {
        { Set-ClaudeTrust -Path $Tmp -ClaudeJsonPath (Join-Path $Tmp 'nope.json') } | Should -Throw '*not found*'
    }

    It "supports -WhatIf without writing" {
        Set-ClaudeTrust -Path $Tmp -ClaudeJsonPath $FakeHome -WhatIf
        $config = Get-Content -LiteralPath $FakeHome -Raw | ConvertFrom-Json -AsHashtable
        $key = $Tmp -replace '\\','/'
        $config['projects'].ContainsKey($key) | Should -BeFalse
    }
}
