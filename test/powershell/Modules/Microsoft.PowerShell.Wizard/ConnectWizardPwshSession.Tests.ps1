# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Connect-WizardPwshSession" -Tags "Feature" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Modules' 'Shared' 'Microsoft.PowerShell.Wizard' 'Microsoft.PowerShell.Wizard.psd1'
        $modulePath = Resolve-Path $modulePath
        Import-Module $modulePath -Force
    }

    It "is exported as a function" {
        Get-Command Connect-WizardPwshSession -ErrorAction SilentlyContinue | Should -Not -Be $null
    }

    It "throws when no resolution source is available" {
        $savedPipe = $env:WIZARD_PWSH_CONTROL_PIPE
        try {
            $env:WIZARD_PWSH_CONTROL_PIPE = ''
            { Connect-WizardPwshSession } | Should -Throw '*WIZARD_PWSH_CONTROL_PIPE*'
        } finally {
            $env:WIZARD_PWSH_CONTROL_PIPE = $savedPipe
        }
    }

    It "uses WIZARD_PWSH_CONTROL_PIPE env var as the default source" {
        $savedPipe = $env:WIZARD_PWSH_CONTROL_PIPE
        try {
            $env:WIZARD_PWSH_CONTROL_PIPE = 'test-pipe-env'
            $handle = Connect-WizardPwshSession
            $handle.PipeName | Should -Be 'test-pipe-env'
            $handle.PSObject.TypeNames | Should -Contain 'WizardSessionHandle'
        } finally {
            $env:WIZARD_PWSH_CONTROL_PIPE = $savedPipe
        }
    }

    It "uses explicit -PipeName when provided" {
        $handle = Connect-WizardPwshSession -PipeName 'wizard-pwsh-explicit'
        $handle.PipeName | Should -Be 'wizard-pwsh-explicit'
    }

    It "exposes Send + convenience methods" {
        $handle = Connect-WizardPwshSession -PipeName 'wizard-pwsh-methods'
        $handle.PSObject.Methods.Name | Should -Contain 'Send'
        $handle.PSObject.Methods.Name | Should -Contain 'Status'
        $handle.PSObject.Methods.Name | Should -Contain 'StatusExtended'
        $handle.PSObject.Methods.Name | Should -Contain 'Read'
        $handle.PSObject.Methods.Name | Should -Contain 'Write'
        $handle.PSObject.Methods.Name | Should -Contain 'Interrupt'
        $handle.PSObject.Methods.Name | Should -Contain 'Publish'
        $handle.PSObject.Methods.Name | Should -Contain 'ReadSignal'
        $handle.PSObject.Methods.Name | Should -Contain 'Wake'
    }

    It "Wake() composes wizard.loop.wake.<sid> via Publish" {
        $captured = @{}
        Mock -CommandName Send-WizardControlRequest -MockWith {
            param([hashtable]$Payload, [string]$PipeName)
            $captured.Payload = $Payload
            $captured.PipeName = $PipeName
        } -ModuleName Microsoft.PowerShell.Wizard

        $handle = Connect-WizardPwshSession -PipeName 'wizard-pwsh-wake'
        $handle.Wake('sess-cwd-1')

        $captured.Payload.command | Should -Be 'signal.publish'
        $captured.Payload.topic | Should -Be 'wizard.loop.wake.sess-cwd-1'
        $captured.PipeName | Should -Be 'wizard-pwsh-wake'
    }
}
