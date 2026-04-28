# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Send-WizardLoopWake" -Tags "Feature" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Modules' 'Shared' 'Microsoft.PowerShell.Wizard' 'Microsoft.PowerShell.Wizard.psd1'
        $modulePath = Resolve-Path $modulePath
        Import-Module $modulePath -Force
    }

    It "is exported as a function" {
        Get-Command Send-WizardLoopWake -ErrorAction SilentlyContinue | Should -Not -Be $null
    }

    It "requires a non-empty session id" {
        { Send-WizardLoopWake -SessionId "" } | Should -Throw
        { Send-WizardLoopWake -SessionId $null } | Should -Throw
    }

    It "delegates to Publish-WizardSignal with topic wizard.loop.wake.<sid>" {
        $captured = @{}
        Mock -CommandName Publish-WizardSignal -MockWith {
            param([string]$Topic, [object]$Data, [int]$Ring, [string]$PipeName)
            $captured.Topic = $Topic
            $captured.Data = $Data
            $captured.PipeName = $PipeName
        } -ModuleName Microsoft.PowerShell.Wizard

        Send-WizardLoopWake -SessionId "sess-test-1"

        $captured.Topic | Should -Be "wizard.loop.wake.sess-test-1"
        $captured.Data.sessionId | Should -Be "sess-test-1"
        $captured.Data.at | Should -Not -BeNullOrEmpty
    }

    It "forwards an explicit -PipeName to Publish-WizardSignal" {
        $captured = @{}
        Mock -CommandName Publish-WizardSignal -MockWith {
            param([string]$Topic, [object]$Data, [int]$Ring, [string]$PipeName)
            $captured.PipeName = $PipeName
        } -ModuleName Microsoft.PowerShell.Wizard

        Send-WizardLoopWake -SessionId "sess-test-2" -PipeName "wizard-pwsh-12345"

        $captured.PipeName | Should -Be "wizard-pwsh-12345"
    }
}
