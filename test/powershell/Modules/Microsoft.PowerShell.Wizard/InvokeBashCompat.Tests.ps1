# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Invoke-BashCompat" -Tags "Feature" {
    BeforeAll {
        # Import the published Wizard module straight into the Pester runspace — avoids
        # all the stdin/quoting headaches of subprocess-based tests.
        $modulePath = Join-Path -Path $PSHOME -ChildPath "Modules/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psd1"
        Import-Module -Name $modulePath -Force

        $script:OriginalEnvVar = $env:WIZARD_PWSH_CONTROL
        # Set up a wizard pwsh subprocess so Publish-WizardSignal has a pipe to talk to.
        $pipeName = "wizard-pwsh-test-bashcompat-$([Guid]::NewGuid().ToString('N'))"
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Join-Path $PSHOME 'pwsh')
        $startInfo.Arguments = "-NoLogo -NoProfile -NoExit"
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Environment["WIZARD_PWSH_CONTROL"] = "1"
        $startInfo.Environment["WIZARD_PWSH_CONTROL_PIPE"] = $pipeName
        $script:HostProcess = [System.Diagnostics.Process]::Start($startInfo)
        # Tell our in-process Publish-WizardSignal where to talk.
        $env:WIZARD_PWSH_CONTROL = "1"
        $env:WIZARD_PWSH_CONTROL_PIPE = $pipeName
        # Give the wizard server a moment to come up.
        Start-Sleep -Milliseconds 500
    }

    AfterAll {
        if ($script:HostProcess -and -not $script:HostProcess.HasExited) {
            try { $script:HostProcess.Kill() } catch { }
            $script:HostProcess.WaitForExit(3000) | Out-Null
        }
        $env:WIZARD_PWSH_CONTROL = $script:OriginalEnvVar
        $env:WIZARD_PWSH_CONTROL_PIPE = $null
    }

    It "translates A && B (both succeed)" {
        $out = Invoke-BashCompat -c 'echo A && echo B' 2>&1 | Out-String
        $out | Should -Match 'A'
        $out | Should -Match 'B'
    }

    It "short-circuits A && B when A fails" {
        $out = Invoke-BashCompat -c '(Write-Error fail) && echo SHOULD_NOT_RUN' 2>&1 | Out-String
        $out | Should -Not -Match 'SHOULD_NOT_RUN'
    }

    It "translates A || B (B runs only if A failed)" {
        $out = Invoke-BashCompat -c '(Write-Error fail) || echo recover' 2>&1 | Out-String
        $out | Should -Match 'recover'
    }

    It "translates head -n N to Select-Object -First N" {
        $result = @(Invoke-BashCompat -c '1..10 | head -n 3')
        $result.Count | Should -Be 3
        $result[0] | Should -Be 1
        $result[2] | Should -Be 3
    }

    It "translates tail -n N to Select-Object -Last N" {
        $result = @(Invoke-BashCompat -c '1..10 | tail -n 2')
        $result.Count | Should -Be 2
        $result[-1] | Should -Be 10
    }

    It "translates grep PATTERN in pipe position" {
        $result = @(Invoke-BashCompat -c '@("ok","error here","done") | grep error') | ForEach-Object { $_.ToString() }
        ($result -join ' ') | Should -Match 'error here'
        ($result -join ' ') | Should -Not -Match '\bok\b'
    }

    It "registers bash/sh aliases when WIZARD_PWSH_CONTROL is set (loaded module did so)" {
        $cmd = Get-Alias bash -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.ResolvedCommandName | Should -BeExactly 'Invoke-BashCompat'
    }

    It "publishes wizard.bashcompat.unsupported for command-substitution input" {
        # $(...) is in the bail-out list — should publish a signal then either fall through
        # to bash.exe or throw.
        try {
            $null = Invoke-BashCompat -c 'echo $(date)' 2>&1
        } catch {
            # Expected when bash.exe isn't available; we still want the signal published.
        }
        $r = Read-WizardSignal -Topic 'wizard.bashcompat.unsupported' -Since 0 -Limit 5
        $r.events.Count | Should -BeGreaterThan 0
        $r.events[-1].data.reason | Should -BeExactly 'command_substitution'
    }

    It "translates a leading 'cd DIR && CMD' to Push-Location with Pop-Location cleanup" {
        $tmp = New-Item -ItemType Directory -Force -Path (Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-bashcd-$([Guid]::NewGuid().ToString('N'))"))
        try {
            $before = (Get-Location).ProviderPath
            $out = Invoke-BashCompat -c "cd $($tmp.FullName) && Get-Location | ForEach-Object ProviderPath" 2>&1 | Out-String
            $out | Should -Match ([regex]::Escape($tmp.FullName))
            (Get-Location).ProviderPath | Should -BeExactly $before
        } finally {
            Remove-Item -LiteralPath $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
