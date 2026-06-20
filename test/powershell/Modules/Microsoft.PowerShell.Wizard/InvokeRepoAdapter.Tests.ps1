# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Invoke-RepoBuild / Invoke-RepoTest adapters" -Tags "Feature" {
    BeforeAll {
        Get-Module Microsoft.PowerShell.Wizard | Remove-Module -Force
        $modulePath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Modules' 'Shared' 'Microsoft.PowerShell.Wizard' 'Microsoft.PowerShell.Wizard.psd1'
        $modulePath = Resolve-Path $modulePath
        Import-Module $modulePath -Force
    }

    It "routes Wizard_Erasmus builds through the CMake preset/build path" {
        $repoRoot = Join-Path $TestDrive 'Wizard_Erasmus'
        New-Item -ItemType Directory -Force -Path $repoRoot | Out-Null
        $calls = [System.Collections.Generic.List[object]]::new()

        Mock -CommandName Get-RepoProfile -ModuleName Microsoft.PowerShell.Wizard -MockWith {
            [pscustomobject]@{ Root = $repoRoot; IsWizardErasmus = $true; HasBuildPsm1 = $false; HasSolution = $false; HasCMakeLists = $true; HasPackageJson = $false }
        }
        Mock -CommandName Invoke-Bounded -ModuleName Microsoft.PowerShell.Wizard -MockWith {
            param([string]$FilePath, [string[]]$ArgumentList)
            $calls.Add([pscustomobject]@{ FilePath = $FilePath; Args = $ArgumentList })
            [pscustomobject]@{ PSTypeName='WizardBoundedResult'; ExitCode = 0; KilledByTimeout = $false; LogPath = 'test.log' }
        }

        Invoke-RepoBuild -Path $repoRoot -Quiet | Out-Null

        $calls.Count | Should -Be 2
        $calls[0].FilePath | Should -BeExactly 'cmake'
        ($calls[0].Args -join ' ') | Should -BeExactly '--preset default'
        ($calls[1].Args -join ' ') | Should -BeExactly '--build build'
    }

    It "auto-routes Wizard_Erasmus visual loop tests to the LiveLoop lane" {
        $repoRoot = Join-Path $TestDrive 'Wizard_Erasmus'
        New-Item -ItemType Directory -Force -Path $repoRoot | Out-Null
        $captured = @{}

        Mock -CommandName Get-RepoProfile -ModuleName Microsoft.PowerShell.Wizard -MockWith {
            [pscustomobject]@{ Root = $repoRoot; IsWizardErasmus = $true; HasBuildPsm1 = $false; HasSolution = $false; HasCMakeLists = $true; HasPyProject = $true; HasPyTests = $true; HasPackageJson = $false }
        }
        Mock -CommandName Invoke-Bounded -ModuleName Microsoft.PowerShell.Wizard -MockWith {
            param([string]$FilePath, [string[]]$ArgumentList)
            $captured.FilePath = $FilePath
            $captured.Args = $ArgumentList
            $captured.Live = $env:WIZARD_LOOP_LIVE
            [pscustomobject]@{ PSTypeName='WizardBoundedResult'; ExitCode = 0; KilledByTimeout = $false; LogPath = 'test.log' }
        }

        Invoke-RepoTest -Path $repoRoot -TestPath 'ai_wrappers/test_loop_no_focus_live.py' -Quiet | Out-Null

        $captured.FilePath | Should -BeExactly 'python'
        ($captured.Args -join ' ') | Should -Match 'ai_wrappers/test_loop_no_focus_live\.py'
        ($captured.Args -join ' ') | Should -Match 'real_visual_codex_loop'
        $captured.Live | Should -BeExactly '1'
    }

    It "auto-routes Wizard_Erasmus pytest node ids to the Python lane" {
        $repoRoot = Join-Path $TestDrive 'Wizard_Erasmus'
        New-Item -ItemType Directory -Force -Path $repoRoot | Out-Null
        $captured = @{}

        Mock -CommandName Get-RepoProfile -ModuleName Microsoft.PowerShell.Wizard -MockWith {
            [pscustomobject]@{ Root = $repoRoot; IsWizardErasmus = $true; HasBuildPsm1 = $false; HasSolution = $false; HasCMakeLists = $true; HasPyProject = $true; HasPyTests = $true; HasPackageJson = $false }
        }
        Mock -CommandName Invoke-Bounded -ModuleName Microsoft.PowerShell.Wizard -MockWith {
            param([string]$FilePath, [string[]]$ArgumentList)
            $captured.FilePath = $FilePath
            $captured.Args = $ArgumentList
            [pscustomobject]@{ PSTypeName='WizardBoundedResult'; ExitCode = 0; KilledByTimeout = $false; LogPath = 'test.log' }
        }

        Invoke-RepoTest -Path $repoRoot -TestPath 'ai_wrappers/test_idle_watch_loop.py::test_stale_working_status_above_prompt_allows_full_period_nudge' -Filter 'stale and not live' -Quiet | Out-Null

        $captured.FilePath | Should -BeExactly 'python'
        ($captured.Args -join ' ') | Should -Match '^-m pytest -q ai_wrappers/test_idle_watch_loop\.py::test_stale_working_status_above_prompt_allows_full_period_nudge -k stale and not live$'
    }

    It "passes Filter through to CTest regex selection" {
        $repoRoot = Join-Path $TestDrive 'Wizard_Erasmus'
        New-Item -ItemType Directory -Force -Path $repoRoot | Out-Null
        $captured = @{}

        Mock -CommandName Get-RepoProfile -ModuleName Microsoft.PowerShell.Wizard -MockWith {
            [pscustomobject]@{ Root = $repoRoot; IsWizardErasmus = $true; HasBuildPsm1 = $false; HasSolution = $false; HasCMakeLists = $true; HasPyProject = $true; HasPyTests = $true; HasPackageJson = $false }
        }
        Mock -CommandName Invoke-Bounded -ModuleName Microsoft.PowerShell.Wizard -MockWith {
            param([string]$FilePath, [string[]]$ArgumentList)
            $captured.FilePath = $FilePath
            $captured.Args = $ArgumentList
            [pscustomobject]@{ PSTypeName='WizardBoundedResult'; ExitCode = 0; KilledByTimeout = $false; LogPath = 'test.log' }
        }

        Invoke-RepoTest -Path $repoRoot -Filter 'governor' -Quiet | Out-Null

        $captured.FilePath | Should -BeExactly 'ctest'
        ($captured.Args -join ' ') | Should -BeExactly '--test-dir build --output-on-failure -R governor'
    }
}
