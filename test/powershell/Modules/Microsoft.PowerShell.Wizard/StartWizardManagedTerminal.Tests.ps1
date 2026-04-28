# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Start-WizardManagedTerminal" -Tags "Feature" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Modules' 'Shared' 'Microsoft.PowerShell.Wizard' 'Microsoft.PowerShell.Wizard.psd1'
        $modulePath = Resolve-Path $modulePath
        Import-Module $modulePath -Force
    }

    It "is exported as a function" {
        Get-Command Start-WizardManagedTerminal -ErrorAction SilentlyContinue | Should -Not -Be $null
    }

    It "rejects an empty session id" {
        { Start-WizardManagedTerminal -Provider claude -ChildArgs @() -SessionId '' } | Should -Throw
    }

    It "rejects an unknown provider" {
        { Start-WizardManagedTerminal -Provider 'gpt-5' -ChildArgs @() -SessionId 'sid' } | Should -Throw
    }

    It "spawns via wt.exe new-tab in Tab parameter set" {
        $captured = @{}
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $captured.FilePath = $FilePath
            $captured.ArgumentList = $ArgumentList
            return [pscustomobject]@{ Id = 4242 }
        } -ModuleName Microsoft.PowerShell.Wizard

        # Pretend wt.exe exists by stubbing Get-Command — tests the
        # tab-spawn argv composition without needing wt.exe installed.
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'wt.exe'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\wt.exe' } }
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'pwsh'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\pwsh.exe' } }

        $result = Start-WizardManagedTerminal `
            -Provider claude `
            -ChildArgs @('--dangerously-skip-permissions') `
            -SessionId 'claude-test-1' `
            -Title 'Claude Loop Test' `
            -Cwd 'C:\repo' `
            -WtWindow 'wizard-loops'

        $result.Channel | Should -Be 'wt_new_tab'
        $result.SessionId | Should -Be 'claude-test-1'
        $result.WtWindow | Should -Be 'wizard-loops'
        $result.Title | Should -Be 'Claude Loop Test'
        $captured.FilePath | Should -Be 'C:\fake\wt.exe'
        $captured.ArgumentList[0] | Should -Be '-w'
        $captured.ArgumentList[1] | Should -Be 'wizard-loops'
        $captured.ArgumentList[2] | Should -Be 'new-tab'
        $captured.ArgumentList | Should -Contain '-d'
        $captured.ArgumentList | Should -Contain '--title'
        $captured.ArgumentList | Should -Contain '-EncodedCommand'
    }

    It "spawns directly via pwsh in NewWindow parameter set" {
        $captured = @{}
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $captured.FilePath = $FilePath
            $captured.ArgumentList = $ArgumentList
            return [pscustomobject]@{ Id = 4243 }
        } -ModuleName Microsoft.PowerShell.Wizard
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'pwsh'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\pwsh.exe' } }

        $result = Start-WizardManagedTerminal `
            -Provider codex `
            -ChildArgs @('resume') `
            -SessionId 'codex-test-2' `
            -NewWindow

        $result.Channel | Should -Be 'new_console'
        $result.WtWindow | Should -BeNullOrEmpty
        $captured.FilePath | Should -Be 'C:\fake\pwsh.exe'
        $captured.ArgumentList | Should -Contain '-EncodedCommand'
    }
}
