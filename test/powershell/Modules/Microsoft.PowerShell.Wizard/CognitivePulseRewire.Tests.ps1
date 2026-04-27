# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Cognitive-pulse rewire end-to-end (β7)" -Tags "Feature" {
    BeforeAll {
        $script:Pwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh'
        $script:FixtureRoot = Join-Path $PSScriptRoot 'fixtures/cognitive_pulse_stub'

        # Skip everything if Python isn't available — this suite drives the warm Python child.
        $py = Get-Command py -ErrorAction SilentlyContinue
        if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $py) {
            Set-ItResult -Skipped -Because 'No py / python on PATH'
            return
        }
        $script:PythonExe = $py.Source

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
            $startInfo.Environment['PYTHONPATH'] = $script:FixtureRoot
            $startInfo.Environment['WIZARD_HOOKHOST_MODULE'] = 'wizard_mcp.hook_host'
            $startInfo.Environment['WIZARD_HOOKHOST_PYTHON'] = $script:PythonExe
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
            param([string] $PipeName, [hashtable] $Payload, [int] $TimeoutMs = 8000)
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
    }

    It "delivers a valid Claude-Code hook reply via the warm host" {
        $pipe = "wizard-pwsh-test-pulse-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $payload = @{
                prompt     = 'help me with X'
                cwd        = (Get-Location).ProviderPath
                session_id = 'test-session'
            }

            $r = Send-WizardRequest -PipeName $pipe -Payload @{
                command = 'hook.invoke'
                name    = 'cognitive_pulse'
                payload = $payload
            }

            $r.status | Should -BeExactly 'ok'
            $r.command | Should -BeExactly 'hook.invoke'
            $r.name | Should -BeExactly 'cognitive_pulse'
            $r.durationMs | Should -BeGreaterOrEqual 0
            $r.result.additionalContext | Should -Match 'cognitive-pulse-stub'
        } finally { Stop-WizardPwsh $proc }
    }

    It "increments the hook.list calls counter for cognitive_pulse" {
        $pipe = "wizard-pwsh-test-pulse-list-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            1..3 | ForEach-Object {
                $null = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.invoke'; name = 'cognitive_pulse'; payload = @{ prompt = "p$_" } }
            }
            $list = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.list' }
            $list.status | Should -BeExactly 'ok'
            $entry = $list.hooks | Where-Object name -eq 'cognitive_pulse' | Select-Object -First 1
            $entry | Should -Not -BeNullOrEmpty
            $entry.calls | Should -BeGreaterOrEqual 3
        } finally { Stop-WizardPwsh $proc }
    }

    It "warmup completes successfully and subsequent invoke is fast" {
        $pipe = "wizard-pwsh-test-pulse-warmup-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $w = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.warmup'; names = @('cognitive_pulse') }
            $w.status | Should -BeExactly 'ok'
            $w.result.warmed.cognitive_pulse | Should -BeExactly 'warm'

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.invoke'; name = 'cognitive_pulse'; payload = @{ prompt = 'after warmup' } }
            $sw.Stop()
            $r.status | Should -BeExactly 'ok'
            # The stub is a no-op; with warmup paid, this round-trip should be well under the
            # default invoke timeout.
            $sw.ElapsedMilliseconds | Should -BeLessThan 3000
        } finally { Stop-WizardPwsh $proc }
    }
}
