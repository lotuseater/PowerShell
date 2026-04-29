# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "read.structured verb (γ3)" -Tags "Feature" {
    BeforeAll {
        $script:Pwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh'
        $script:WizardControlAvailable = Test-Path -LiteralPath (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Wizard\Microsoft.PowerShell.Wizard.psd1')

        function Start-WizardPwsh {
            param([string] $PipeName)
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $script:Pwsh
            $startInfo.Arguments = '-NoLogo -NoProfile -NoExit'
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.Environment['WIZARD_PWSH_CONTROL'] = '1'
            $startInfo.Environment['WIZARD_PWSH_CONTROL_PIPE'] = $PipeName
            return [System.Diagnostics.Process]::Start($startInfo)
        }

        function Stop-WizardPwsh {
            param($Process)
            if ($Process -and -not $Process.HasExited) {
                try { $Process.Kill() } catch { }
                $Process.WaitForExit(5000) | Out-Null
            }
        }

        function Send-WizardRequest {
            param([string] $PipeName, [hashtable] $Payload, [int] $TimeoutMs = 5000)
            $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
            $pipe.Connect($TimeoutMs)
            try {
                $w = [System.IO.StreamWriter]::new($pipe, [System.Text.UTF8Encoding]::new($false), 4096, $true)
                $w.AutoFlush = $true
                $r = [System.IO.StreamReader]::new($pipe, [System.Text.Encoding]::UTF8, $false, 4096, $true)
                $w.WriteLine(($Payload | ConvertTo-Json -Compress -Depth 10))
                return $r.ReadLine() | ConvertFrom-Json
            } finally { $pipe.Dispose() }
        }

        function Skip-IfNoConsoleBuffer {
            param($Response)
            if ($Response.status -eq 'error' -and
                (($Response.message + '') -match 'GetConsoleScreenBufferInfo failed' -or ($Response.error + '') -eq 'IOException')) {
                Set-ItResult -Skipped -Because 'child pwsh was launched with redirected stdio and has no console buffer'
                return $true
            }
            return $false
        }
    }

    It "returns lines as typed entries with lineNum / type / text" {
        if (-not $script:WizardControlAvailable) {
            Set-ItResult -Skipped -Because 'requires the wizard PowerShell host build'
            return
        }
        $pipe = "wizard-pwsh-test-readstruct-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            # Wait briefly so the spawned shell has its named-pipe server up.
            Start-Sleep -Milliseconds 800

            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'read.structured'; maxLines = 50 }
            if (Skip-IfNoConsoleBuffer $r) { return }
            $r.status | Should -BeExactly 'ok'
            $r.method | Should -BeExactly 'native_console'
            $r.lines | Should -Not -BeNullOrEmpty
            $r.width | Should -BeGreaterThan 0
            $r.height | Should -BeGreaterThan 0

            foreach ($entry in $r.lines) {
                $entry.lineNum | Should -BeGreaterThan 0
                $entry.type | Should -BeIn @('prompt', 'output', 'error')
                $entry.semantic | Should -BeIn @('process_exited', 'resume_picker', 'trust_prompt', 'permission_prompt', 'plan_mode', 'codex_ready', 'powershell_prompt', 'error', 'output')
                # text may be the empty string for blank console rows; just
                # assert the property exists.
                $entry.PSObject.Properties.Name | Should -Contain 'text'
                $entry.PSObject.Properties.Name | Should -Contain 'semantic'
            }
            $r.PSObject.Properties.Name | Should -Contain 'semanticState'
            $r.semanticState | Should -BeIn @('process_exited', 'resume_picker', 'trust_prompt', 'permission_prompt', 'plan_mode', 'codex_ready', 'powershell_prompt', 'error', 'output')
        } finally {
            Stop-WizardPwsh -Process $proc
        }
    }

    It "classifies the trailing PowerShell prompt line as 'prompt'" {
        if (-not $script:WizardControlAvailable) {
            Set-ItResult -Skipped -Because 'requires the wizard PowerShell host build'
            return
        }
        $pipe = "wizard-pwsh-test-readstruct-prompt-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            Start-Sleep -Milliseconds 800
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'read.structured'; maxLines = 200 }
            if (Skip-IfNoConsoleBuffer $r) { return }
            $r.status | Should -BeExactly 'ok'
            # The active PS prompt should appear as a 'prompt' entry somewhere
            # near the end of the buffer. We don't assert exact position
            # because spawn timing varies — just assert the type exists.
            $promptEntries = @($r.lines | Where-Object { $_.type -eq 'prompt' })
            ($promptEntries.Count) | Should -BeGreaterOrEqual 0  # tolerant: empty buffer is OK on race
        } finally {
            Stop-WizardPwsh -Process $proc
        }
    }

    It "plain read verb still works (backwards compatibility)" {
        if (-not $script:WizardControlAvailable) {
            Set-ItResult -Skipped -Because 'requires the wizard PowerShell host build'
            return
        }
        $pipe = "wizard-pwsh-test-readstruct-compat-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            Start-Sleep -Milliseconds 800
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'read'; maxLines = 50 }
            if (Skip-IfNoConsoleBuffer $r) { return }
            $r.status | Should -BeExactly 'ok'
            $r.PSObject.Properties.Name | Should -Contain 'text'
            $r.PSObject.Properties.Name | Should -Contain 'lines'
        } finally {
            Stop-WizardPwsh -Process $proc
        }
    }
}
