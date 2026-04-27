# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Test-WizardBuildPrereqs" -Tags "Feature" {
    BeforeAll {
        Import-Module (Join-Path $PSHOME "Modules/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psd1") -Force
    }

    It "returns a structured result with required + optional checks" {
        $r = Test-WizardBuildPrereqs -RepoRoot 'C:\Users\Oleh\Documents\GitHub\PowerShell' -Quiet
        $r.PSTypeNames | Should -Contain 'WizardBuildPrereqs'
        $r.RepoRoot | Should -Be 'C:\Users\Oleh\Documents\GitHub\PowerShell'
        ($r.Checks | ForEach-Object Check) | Should -Contain 'dotnet-sdk'
        ($r.Checks | ForEach-Object Check) | Should -Contain 'ripgrep'
        ($r.Checks | ForEach-Object Check) | Should -Contain 'pester-5+'
        ($r.Checks | ForEach-Object Check) | Should -Contain 'wizard-shim'
    }

    It "throws when a required check fails (no global.json)" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-prereqs-fake-$([Guid]::NewGuid().ToString('N')))")
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            { Test-WizardBuildPrereqs -RepoRoot $tmp } | Should -Throw -ExpectedMessage '*required checks failed*'
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "with -Quiet returns the result object even when checks fail" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-prereqs-fake-$([Guid]::NewGuid().ToString('N')))")
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            $r = Test-WizardBuildPrereqs -RepoRoot $tmp -Quiet
            $r.AllRequiredPass | Should -BeFalse
            ($r.Checks | Where-Object { $_.Required -and -not $_.Pass }).Count | Should -BeGreaterThan 0
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Invoke-AntQuery" -Tags "Feature" {
    BeforeAll {
        Import-Module (Join-Path $PSHOME "Modules/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psd1") -Force
    }

    It "throws helpfully when ant binary is missing" {
        $oldEnv = $env:WIZARD_ANT_PATH
        try {
            $env:WIZARD_ANT_PATH = 'C:\does\not\exist\ant.exe'
            { Invoke-AntQuery -Prompt 'test' -AntPath 'C:\does\not\exist\ant.exe' } | Should -Throw -ExpectedMessage '*ant binary not found*'
        } finally {
            if ($null -ne $oldEnv) { $env:WIZARD_ANT_PATH = $oldEnv } else { Remove-Item Env:\WIZARD_ANT_PATH -ErrorAction SilentlyContinue }
        }
    }
}
