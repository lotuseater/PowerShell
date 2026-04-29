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
        $global:WizardManagedTerminalTestCaptured = @{}
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $global:WizardManagedTerminalTestCaptured['FilePath'] = $FilePath
            $global:WizardManagedTerminalTestCaptured['ArgumentList'] = $ArgumentList
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
        $global:WizardManagedTerminalTestCaptured.FilePath | Should -Be 'C:\fake\wt.exe'
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match '^-w wizard-loops new-tab '
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match '--title "Claude Loop Test"'
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match '-EncodedCommand'
    }

    It "quotes wt.exe argv values with spaces before Start-Process flattens them" {
        $global:WizardManagedTerminalTestCaptured = @{}
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $global:WizardManagedTerminalTestCaptured['FilePath'] = $FilePath
            $global:WizardManagedTerminalTestCaptured['ArgumentList'] = $ArgumentList
            return [pscustomobject]@{ Id = 4245 }
        } -ModuleName Microsoft.PowerShell.Wizard
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'wt.exe'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\wt.exe' } }

        Start-WizardManagedTerminal `
            -Provider codex `
            -ChildArgs @('resume') `
            -SessionId 'codex-test-spaces' `
            -Title 'Codex Loop 11176-1777414748911' `
            -Cwd 'C:\Repo With Spaces' `
            -WtWindow 'wizard loops' `
            -PwshExe 'C:\Program Files\PowerShell\7\pwsh.exe'

        $global:WizardManagedTerminalTestCaptured.FilePath | Should -Be 'C:\fake\wt.exe'
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match '^-w "wizard loops" new-tab -d "C:\\Repo With Spaces" --title "Codex Loop 11176-1777414748911" "C:\\Program Files\\PowerShell\\7\\pwsh.exe" -NoLogo -EncodedCommand '
    }

    It "spawns into the current Windows Terminal window and returns the supplied pipe" {
        $global:WizardManagedTerminalTestCaptured = @{}
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $global:WizardManagedTerminalTestCaptured['FilePath'] = $FilePath
            $global:WizardManagedTerminalTestCaptured['ArgumentList'] = $ArgumentList
            return [pscustomobject]@{ Id = 4247 }
        } -ModuleName Microsoft.PowerShell.Wizard
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'wt.exe'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\wt.exe' } }
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'pwsh'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\pwsh.exe' } }

        $result = Start-WizardManagedTerminal `
            -Provider codex `
            -ChildArgs @('resume') `
            -SessionId 'codex-current-window' `
            -Title 'Codex Loop Current' `
            -CurrentWindow `
            -Env @{ WIZARD_PWSH_CONTROL_PIPE = 'wizard-loop-codex-current-window' }

        $result.Channel | Should -Be 'wt_current_tab'
        $result.WindowTarget | Should -Be 'current'
        $result.WtWindow | Should -Be '0'
        $result.Pipe | Should -Be 'wizard-loop-codex-current-window'
        $global:WizardManagedTerminalTestCaptured.FilePath | Should -Be 'C:\fake\wt.exe'
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match '^-w 0 new-tab '
    }

    It "sets Env keys with parentheses through literal provider paths" {
        $global:WizardManagedTerminalTestCaptured = @{}
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $global:WizardManagedTerminalTestCaptured['FilePath'] = $FilePath
            $global:WizardManagedTerminalTestCaptured['ArgumentList'] = $ArgumentList
            return [pscustomobject]@{ Id = 4246 }
        } -ModuleName Microsoft.PowerShell.Wizard
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'pwsh'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\pwsh.exe' } }

        Start-WizardManagedTerminal `
            -Provider codex `
            -ChildArgs @('resume') `
            -SessionId 'codex-test-env' `
            -NewWindow `
            -Env @{ 'COMMONPROGRAMFILES(X86)' = 'C:\Program Files (x86)\Common Files' }

        $encoded = [regex]::Match($global:WizardManagedTerminalTestCaptured.ArgumentList, '-EncodedCommand (?<encoded>\S+)').Groups['encoded'].Value
        $launchScript = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $launchScript | Should -Not -Match '\$env:COMMONPROGRAMFILES\(X86\)'
        $launchScript | Should -Match "Set-Item -LiteralPath 'Env:COMMONPROGRAMFILES\(X86\)' -Value 'C:\\Program Files \(x86\)\\Common Files'"
    }

    It "spawns directly via pwsh in NewWindow parameter set" {
        $global:WizardManagedTerminalTestCaptured = @{}
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $global:WizardManagedTerminalTestCaptured['FilePath'] = $FilePath
            $global:WizardManagedTerminalTestCaptured['ArgumentList'] = $ArgumentList
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
        $global:WizardManagedTerminalTestCaptured.FilePath | Should -Be 'C:\fake\pwsh.exe'
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match '-EncodedCommand'
    }

    It "sets control env before starting the child process" {
        $global:WizardManagedTerminalTestCaptured = @{}
        $beforePipe = $env:WIZARD_PWSH_CONTROL_PIPE
        $beforeControl = $env:WIZARD_PWSH_CONTROL
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $global:WizardManagedTerminalTestCaptured['FilePath'] = $FilePath
            $global:WizardManagedTerminalTestCaptured['ArgumentList'] = $ArgumentList
            $global:WizardManagedTerminalTestCaptured['Pipe'] = $env:WIZARD_PWSH_CONTROL_PIPE
            $global:WizardManagedTerminalTestCaptured['Control'] = $env:WIZARD_PWSH_CONTROL
            return [pscustomobject]@{ Id = 4248 }
        } -ModuleName Microsoft.PowerShell.Wizard
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'pwsh'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\pwsh.exe' } }

        try {
            $result = Start-WizardManagedTerminal `
                -Provider codex `
                -ChildArgs @('--version') `
                -SessionId 'codex-test-env-before-start' `
                -NewWindow `
                -Env @{ WIZARD_PWSH_CONTROL_PIPE = 'wizard-loop-codex-env-before-start' }

            $result.Pipe | Should -Be 'wizard-loop-codex-env-before-start'
            $global:WizardManagedTerminalTestCaptured.Pipe | Should -Be 'wizard-loop-codex-env-before-start'
            $global:WizardManagedTerminalTestCaptured.Control | Should -Be '1'
        } finally {
            $env:WIZARD_PWSH_CONTROL_PIPE | Should -Be $beforePipe
            $env:WIZARD_PWSH_CONTROL | Should -Be $beforeControl
        }
    }

    It "uses explicit PwshExe instead of PATH discovery" {
        $global:WizardManagedTerminalTestCaptured = @{}
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $global:WizardManagedTerminalTestCaptured['FilePath'] = $FilePath
            $global:WizardManagedTerminalTestCaptured['ArgumentList'] = $ArgumentList
            return [pscustomobject]@{ Id = 4244 }
        } -ModuleName Microsoft.PowerShell.Wizard
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'pwsh'
        } -MockWith { [pscustomobject]@{ Source = 'C:\stale\pwsh.exe' } }

        Start-WizardManagedTerminal `
            -Provider codex `
            -ChildArgs @('resume') `
            -SessionId 'codex-test-3' `
            -NewWindow `
            -PwshExe 'pwsh'

        $global:WizardManagedTerminalTestCaptured.FilePath | Should -Be 'pwsh'
    }
}
