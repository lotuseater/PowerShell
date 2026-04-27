# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Use-WizardLock / Clear-WizardLock" -Tags "Feature" {
    BeforeAll {
        Import-Module (Join-Path $PSHOME "Modules/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psd1") -Force
        $script:LockRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-lock-tests-$([Guid]::NewGuid().ToString('N'))")
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:LockRoot) {
            Remove-Item -LiteralPath $script:LockRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "returns `$null on first acquire" {
        $r = Use-WizardLock -Key 'first' -Note 'init' -LockRoot $LockRoot
        $r | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $LockRoot 'first.lock') | Should -BeTrue
    }

    It "returns the existing record on second acquire (idempotency)" {
        $r1 = Use-WizardLock -Key 'second' -Note 'first call' -LockRoot $LockRoot
        $r1 | Should -BeNullOrEmpty
        $r2 = Use-WizardLock -Key 'second' -Note 'second call (should not be recorded)' -LockRoot $LockRoot
        $r2 | Should -Not -BeNullOrEmpty
        $r2.WasAlreadyHeld | Should -BeTrue
        $r2.Note | Should -BeExactly 'first call'
    }

    It "Clear-WizardLock removes the lock and lets a subsequent Use- re-acquire" {
        $null = Use-WizardLock -Key 'cycle' -Note 'first' -LockRoot $LockRoot
        $cleared = Clear-WizardLock -Key 'cycle' -LockRoot $LockRoot
        $cleared | Should -BeTrue
        $r = Use-WizardLock -Key 'cycle' -Note 'second' -LockRoot $LockRoot
        $r | Should -BeNullOrEmpty
        $second = Use-WizardLock -Key 'cycle' -Note 'third' -LockRoot $LockRoot
        $second.Note | Should -BeExactly 'second'
    }

    It "sanitizes path-separator characters in the key" {
        $r = Use-WizardLock -Key 'a/b\c' -Note 'sep' -LockRoot $LockRoot
        $r | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $LockRoot 'a_b_c.lock') | Should -BeTrue
    }

    It "Clear-WizardLock returns false when the lock is missing" {
        Clear-WizardLock -Key 'never-locked' -LockRoot $LockRoot | Should -BeFalse
    }
}
