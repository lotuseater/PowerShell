# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Wizard maintenance cmdlets" -Tags "Feature" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Modules' 'Shared' 'Microsoft.PowerShell.Wizard' 'Microsoft.PowerShell.Wizard.psd1'
        $modulePath = Resolve-Path $modulePath
        Import-Module $modulePath -Force
    }

    It "Get-WizardLoopSessions reads managed terminal sidecars and filters stale sessions" {
        $root = Join-Path $TestDrive 'managed_terminals'
        New-Item -ItemType Directory -Force -Path $root | Out-Null

        $live = [pscustomobject]@{
            session_id = 'loop-live'
            provider = 'codex'
            command_name = 'codex'
            cwd = 'C:\Repo'
            window_title = 'codex live'
            transport = 'wizard_pwsh'
            hwnd = 123
            process_pid = $PID
            state = 'ready'
            updated_at = 20
            created_at = 10
        }
        $stale = $live.PSObject.Copy()
        $stale.session_id = 'loop-stale'
        $stale.process_pid = 999999
        $stale.updated_at = 30
        $live | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'live.json') -Encoding utf8
        $stale | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'stale.json') -Encoding utf8

        $rows = @(Get-WizardLoopSessions -SidecarRoot $root)
        $rows.Count | Should -Be 1
        $rows[0].SessionId | Should -BeExactly 'loop-live'
        $rows[0].ProcessAlive | Should -BeTrue

        $all = @(Get-WizardLoopSessions -SidecarRoot $root -IncludeStale)
        $all.Count | Should -Be 2
        ($all | Where-Object SessionId -eq 'loop-stale').ProcessAlive | Should -BeFalse
    }

    It "Close-WizardExitedLoopTab delegates to session_handoff.py with a dry-run guard" {
        $root = Join-Path $TestDrive 'Wizard_Erasmus'
        $scripts = Join-Path $root 'scripts'
        New-Item -ItemType Directory -Force -Path $scripts | Out-Null
        $fake = Join-Path $scripts 'session_handoff.py'
        Set-Content -LiteralPath $fake -Encoding utf8 -Value @'
import json, sys
print(json.dumps({"status": "ok", "args": sys.argv[1:]}))
'@

        $r = Close-WizardExitedLoopTab -WizardRoot $root -PythonExe python -ManagedSessionId 'loop-1' -DryRun
        $r.status | Should -BeExactly 'ok'
        $r.args | Should -Contain 'close-tab'
        $r.args | Should -Contain '--dry-run'
        $r.args | Should -Contain '--allow-managed-loop'
        $r.args | Should -Contain '--confirm-close-tab'
        $r.args | Should -Contain '--require-text'
    }

    It "exports the Release repair cmdlet" {
        Get-Command Repair-WizardPowerShellRelease -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
