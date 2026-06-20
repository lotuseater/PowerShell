# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Start-WizardManagedTerminal" -Tags "Feature" {
    BeforeAll {
        Get-Module Microsoft.PowerShell.Wizard | Remove-Module -Force
        $modulePath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Modules' 'Shared' 'Microsoft.PowerShell.Wizard' 'Microsoft.PowerShell.Wizard.psd1'
        $modulePath = Resolve-Path $modulePath
        Import-Module $modulePath -Force
    }

    BeforeEach {
        $script:beforeWizardWtExe = $env:WIZARD_WT_EXE
        $script:beforeWizardTerminalRepo = $env:WIZARD_TERMINAL_REPO
        $env:WIZARD_WT_EXE = $null
        $env:WIZARD_TERMINAL_REPO = Join-Path $TestDrive 'missing-terminal-checkout'
    }

    AfterEach {
        $env:WIZARD_WT_EXE = $script:beforeWizardWtExe
        $env:WIZARD_TERMINAL_REPO = $script:beforeWizardTerminalRepo
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
        $result.TerminalDisplayHost | Should -Be 'windows_terminal'
        $result.SessionId | Should -Be 'claude-test-1'
        $result.WtWindow | Should -Be 'wizard-loops'
        $result.WtWindowTarget | Should -Be 'wizard-loops'
        $result.WtTabTitle | Should -Be 'Claude Loop Test'
        $result.WtTabColor | Should -Match '^#[0-9A-F]{6}$'
        $result.WtExe | Should -Be 'C:\fake\wt.exe'
        $result.ShellExecutable | Should -Match '\\src\\powershell-win-core\\bin\\Release\\net11\.0\\win7-x64\\publish\\pwsh\.exe$'
        $result.WtCommandLine | Should -Match '^C:\\fake\\wt.exe -w wizard-loops new-tab '
        $result.Title | Should -Be 'Claude Loop Test'
        $global:WizardManagedTerminalTestCaptured.FilePath | Should -Be 'C:\fake\wt.exe'
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match '^-w wizard-loops new-tab '
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match '--title "Claude Loop Test"'
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match '--tabColor #[0-9A-F]{6}'
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match '-EncodedCommand'
    }

    It "generates stable distinct automatic tab colors for nearby sessions" {
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            return [pscustomobject]@{ Id = 4249 }
        } -ModuleName Microsoft.PowerShell.Wizard
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'wt.exe'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\wt.exe' } }

        $colors = 1..12 | ForEach-Object {
            (Start-WizardManagedTerminal `
                -Provider codex `
                -ChildArgs @('--version') `
                -SessionId "codex-color-$($_)" `
                -Title "Codex Loop $($_)" `
                -WtWindow 'wizard-loops').WtTabColor
        }
        $again = Start-WizardManagedTerminal `
            -Provider codex `
            -ChildArgs @('--version') `
            -SessionId 'codex-color-1' `
            -Title 'Codex Loop 1' `
            -WtWindow 'wizard-loops'

        ($colors | Select-Object -Unique).Count | Should -Be 12
        $again.WtTabColor | Should -Be $colors[0]
        foreach ($color in $colors) {
            $color | Should -Match '^#[0-9A-F]{6}$'
        }
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

        $result = Start-WizardManagedTerminal `
            -Provider codex `
            -ChildArgs @('resume') `
            -SessionId 'codex-test-spaces' `
            -Title 'Codex Loop 11176-1777414748911' `
            -Cwd 'C:\Repo With Spaces' `
            -WtWindow 'wizard loops'

        $global:WizardManagedTerminalTestCaptured.FilePath | Should -Be 'C:\fake\wt.exe'
        $escapedPwsh = [regex]::Escape($result.ShellExecutable)
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match ('^-w "wizard loops" new-tab -d "C:\\Repo With Spaces" --title "Codex Loop 11176-1777414748911" --tabColor #[0-9A-F]{6} ' + $escapedPwsh + ' -NoLogo -EncodedCommand ')
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
        $result.TerminalDisplayHost | Should -Be 'windows_terminal'
        $result.ShellExecutable | Should -Match '\\src\\powershell-win-core\\bin\\Release\\net11\.0\\win7-x64\\publish\\pwsh\.exe$'
        $result.WindowTarget | Should -Be 'current'
        $result.WtWindow | Should -Be '0'
        $result.WtWindowTarget | Should -Be '0'
        $result.WtTabTitle | Should -Be 'Codex Loop Current'
        $result.WtTabColor | Should -Match '^#[0-9A-F]{6}$'
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

    It "runs a caller supplied command script in a managed utility tab" {
        $global:WizardManagedTerminalTestCaptured = @{}
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList, $WorkingDirectory)
            $global:WizardManagedTerminalTestCaptured['FilePath'] = $FilePath
            $global:WizardManagedTerminalTestCaptured['ArgumentList'] = $ArgumentList
            $global:WizardManagedTerminalTestCaptured['WorkingDirectory'] = $WorkingDirectory
            return [pscustomobject]@{ Id = 4252 }
        } -ModuleName Microsoft.PowerShell.Wizard
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'wt.exe'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\wt.exe' } }

        $result = Start-WizardManagedTerminal `
            -Provider teamapp `
            -CommandScript "Write-Output 'mirror ready'" `
            -SessionId 'teamapp-mirror-worker-1' `
            -Title 'Team App Single Agent' `
            -Cwd 'C:\Repo With Spaces' `
            -WtWindow 'wizard-team'

        $result.Provider | Should -Be 'teamapp'
        $result.TerminalDisplayHost | Should -Be 'windows_terminal'
        $global:WizardManagedTerminalTestCaptured.WorkingDirectory | Should -Be 'C:\Repo With Spaces'
        $encoded = [regex]::Match($global:WizardManagedTerminalTestCaptured.ArgumentList, '-EncodedCommand (?<encoded>\S+)').Groups['encoded'].Value
        $launchScript = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $launchScript | Should -Match "Set-Location -LiteralPath 'C:\\Repo With Spaces'"
        $launchScript | Should -Match "Write-Output 'mirror ready'"
        $launchScript | Should -Not -Match '& teamapp'
    }

    It "prefers a built custom terminal checkout before PATH discovery" {
        $global:WizardManagedTerminalTestCaptured = @{}
        $customTerminalRoot = Join-Path $TestDrive 'terminal'
        $customWtExe = Join-Path $customTerminalRoot 'bin\x64\Release\wt.exe'
        New-Item -ItemType Directory -Path (Split-Path -Path $customWtExe -Parent) -Force | Out-Null
        New-Item -ItemType File -Path $customWtExe -Force | Out-Null
        $env:WIZARD_TERMINAL_REPO = $customTerminalRoot

        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $global:WizardManagedTerminalTestCaptured['FilePath'] = $FilePath
            $global:WizardManagedTerminalTestCaptured['ArgumentList'] = $ArgumentList
            return [pscustomobject]@{ Id = 4253 }
        } -ModuleName Microsoft.PowerShell.Wizard
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'wt.exe'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\wt.exe' } }

        $result = Start-WizardManagedTerminal `
            -Provider teamapp `
            -CommandScript "Write-Output 'mirror ready'" `
            -SessionId 'teamapp-custom-terminal' `
            -Title 'Team App Custom Terminal' `
            -WtWindow 'wizard-team'

        $result.WtExe | Should -Be $customWtExe
        $global:WizardManagedTerminalTestCaptured.FilePath | Should -Be $customWtExe
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
        $result.TerminalDisplayHost | Should -Be 'classic_console'
        $result.ShellExecutable | Should -Match '\\src\\powershell-win-core\\bin\\Release\\net11\.0\\win7-x64\\publish\\pwsh\.exe$'
        $result.WtWindow | Should -BeNullOrEmpty
        $result.WtWindowTarget | Should -BeNullOrEmpty
        $result.WtTabTitle | Should -BeNullOrEmpty
        $result.WtTabColor | Should -BeNullOrEmpty
        $result.WtExe | Should -BeNullOrEmpty
        $result.WtCommandLine | Should -BeNullOrEmpty
        $global:WizardManagedTerminalTestCaptured.FilePath | Should -Match '\\src\\powershell-win-core\\bin\\Release\\net11\.0\\win7-x64\\publish\\pwsh\.exe$'
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

    It "sets an isolated module analysis cache by default and reports it" {
        $global:WizardManagedTerminalTestCaptured = @{}
        $beforeCache = $env:PSModuleAnalysisCachePath
        $beforeLocalAppData = $env:LOCALAPPDATA
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $global:WizardManagedTerminalTestCaptured['FilePath'] = $FilePath
            $global:WizardManagedTerminalTestCaptured['ArgumentList'] = $ArgumentList
            $global:WizardManagedTerminalTestCaptured['AnalysisCache'] = $env:PSModuleAnalysisCachePath
            return [pscustomobject]@{ Id = 4250 }
        } -ModuleName Microsoft.PowerShell.Wizard
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'pwsh'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\pwsh.exe' } }

        try {
            $env:PSModuleAnalysisCachePath = $null
            $env:LOCALAPPDATA = $TestDrive
            $result = Start-WizardManagedTerminal `
                -Provider codex `
                -ChildArgs @('--version') `
                -SessionId 'codex-test-cache-default' `
                -NewWindow

            $expected = Join-Path $TestDrive 'WizardPowerShell\ModuleAnalysisCache\codex-test-cache-default.cache'
            $result.PSModuleAnalysisCachePath | Should -Be $expected
            $result.PSModuleAnalysisCachePathSource | Should -Be 'default'
            $result.AnalysisCacheIsolated | Should -BeTrue
            $global:WizardManagedTerminalTestCaptured.AnalysisCache | Should -Be $expected
        } finally {
            $env:PSModuleAnalysisCachePath = $beforeCache
            $env:LOCALAPPDATA = $beforeLocalAppData
        }
    }

    It "preserves an explicit module analysis cache and explicit tab color" {
        $global:WizardManagedTerminalTestCaptured = @{}
        Mock -CommandName Start-Process -MockWith {
            param($FilePath, $ArgumentList)
            $global:WizardManagedTerminalTestCaptured['FilePath'] = $FilePath
            $global:WizardManagedTerminalTestCaptured['ArgumentList'] = $ArgumentList
            $global:WizardManagedTerminalTestCaptured['AnalysisCache'] = $env:PSModuleAnalysisCachePath
            return [pscustomobject]@{ Id = 4251 }
        } -ModuleName Microsoft.PowerShell.Wizard
        Mock -CommandName Get-Command -ModuleName Microsoft.PowerShell.Wizard -ParameterFilter {
            $Name -eq 'wt.exe'
        } -MockWith { [pscustomobject]@{ Source = 'C:\fake\wt.exe' } }

        $explicitCache = Join-Path $TestDrive 'custom-cache\analysis.cache'
        $result = Start-WizardManagedTerminal `
            -Provider claude `
            -ChildArgs @('--version') `
            -SessionId 'claude-test-cache-explicit' `
            -Title 'Claude Explicit Color' `
            -TabColor '#00aa77' `
            -WtWindow 'wizard-loops' `
            -Env @{ PSModuleAnalysisCachePath = $explicitCache }

        $result.PSModuleAnalysisCachePath | Should -Be $explicitCache
        $result.PSModuleAnalysisCachePathSource | Should -Be 'env'
        $result.AnalysisCacheIsolated | Should -BeFalse
        $result.WtTabColor | Should -Be '#00AA77'
        $global:WizardManagedTerminalTestCaptured.AnalysisCache | Should -Be $explicitCache
        $global:WizardManagedTerminalTestCaptured.ArgumentList | Should -Match '--tabColor #00AA77'
    }

    It "rejects malformed tab colors" {
        { Start-WizardManagedTerminal -Provider codex -ChildArgs @('--version') -SessionId 'bad-color' -TabColor 'blue' } |
            Should -Throw '*TabColor must be a #RRGGBB value*'
    }

    It "uses explicit Wizard PwshExe instead of PATH discovery" {
        $global:WizardManagedTerminalTestCaptured = @{}
        $wizardPwsh = Join-Path $env:USERPROFILE 'Documents\GitHub\PowerShell\src\powershell-win-core\bin\Release\net11.0\win7-x64\publish\pwsh.exe'
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
            -PwshExe $wizardPwsh

        $global:WizardManagedTerminalTestCaptured.FilePath | Should -Be $wizardPwsh
    }
}
