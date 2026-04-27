# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Wizard signal channel" -Tags "Feature" {
    BeforeAll {
        $powershell = Join-Path -Path $PSHOME -ChildPath "pwsh"

        function Start-WizardPwsh {
            param([string] $PipeName)
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $powershell
            $startInfo.Arguments = "-NoLogo -NoProfile -NoExit"
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.Environment["WIZARD_PWSH_CONTROL"] = "1"
            $startInfo.Environment["WIZARD_PWSH_CONTROL_PIPE"] = $PipeName
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
            param([string] $PipeName, [hashtable] $Payload)
            $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(".", $PipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
            $pipe.Connect(5000)
            try {
                $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.UTF8Encoding]::new($false), 4096, $true)
                $writer.AutoFlush = $true
                $reader = [System.IO.StreamReader]::new($pipe, [System.Text.Encoding]::UTF8, $false, 4096, $true)
                $writer.WriteLine(($Payload | ConvertTo-Json -Compress -Depth 10))
                return $reader.ReadLine() | ConvertFrom-Json
            } finally {
                $pipe.Dispose()
            }
        }
    }

    It "publishes and reports a seq + ts" {
        $pipeName = "wizard-pwsh-test-publish-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipeName
        try {
            $r = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.t1'; data = @{ x = 1 } }
            $r.status | Should -BeExactly 'ok'
            $r.command | Should -BeExactly 'signal.publish'
            $r.topic | Should -BeExactly 'phase4.t1'
            $r.seq | Should -BeGreaterThan 0
            $r.ts | Should -Not -BeNullOrEmpty
        } finally { Stop-WizardPwsh $proc }
    }

    It "round-trips publish then subscribe (since=0)" {
        $pipeName = "wizard-pwsh-test-rt-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipeName
        try {
            $null = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.t2'; data = @{ n = 1 } }
            $null = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.t2'; data = @{ n = 2 } }
            $null = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.t2'; data = @{ n = 3 } }

            $r = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.subscribe'; topic = 'phase4.t2'; since = 0; limit = 100 }
            $r.status | Should -BeExactly 'ok'
            $r.events.Count | Should -Be 3
            $r.events[0].data.n | Should -Be 1
            $r.events[1].data.n | Should -Be 2
            $r.events[2].data.n | Should -Be 3
            ($r.events[1].seq) | Should -BeGreaterThan ($r.events[0].seq)
        } finally { Stop-WizardPwsh $proc }
    }

    It "advances cursor (since=N returns only events with seq > N)" {
        $pipeName = "wizard-pwsh-test-cursor-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipeName
        try {
            $a = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.t3'; data = @{} }
            $b = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.t3'; data = @{} }
            $c = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.t3'; data = @{} }

            $r = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.subscribe'; topic = 'phase4.t3'; since = $b.seq; limit = 100 }
            $r.events.Count | Should -Be 1
            $r.events[0].seq | Should -Be $c.seq
        } finally { Stop-WizardPwsh $proc }
    }

    It "ring-evicts oldest events past Ring size" {
        $pipeName = "wizard-pwsh-test-ring-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipeName
        try {
            for ($i = 1; $i -le 50; $i++) {
                $null = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.t4'; ring = 10; data = @{ n = $i } }
            }
            $r = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.subscribe'; topic = 'phase4.t4'; since = 0; limit = 100 }
            $r.events.Count | Should -Be 10
            $r.events[0].data.n | Should -Be 41
            $r.events[-1].data.n | Should -Be 50
        } finally { Stop-WizardPwsh $proc }
    }

    It "signal.list reports topics and counts" {
        $pipeName = "wizard-pwsh-test-list-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipeName
        try {
            $null = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.tA'; data = @{} }
            $null = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.tA'; data = @{} }
            $null = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.tB'; data = @{} }

            $r = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.list' }
            $r.status | Should -BeExactly 'ok'
            $byTopic = @{}
            foreach ($t in $r.topics) { $byTopic[$t.topic] = $t.count }
            $byTopic['phase4.tA'] | Should -Be 2
            $byTopic['phase4.tB'] | Should -Be 1
        } finally { Stop-WizardPwsh $proc }
    }

    It "signal.clear -Topic removes only that topic" {
        $pipeName = "wizard-pwsh-test-clear-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipeName
        try {
            $null = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.tC'; data = @{} }
            $null = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; topic = 'phase4.tD'; data = @{} }

            $r = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.clear'; topic = 'phase4.tC' }
            $r.status | Should -BeExactly 'ok'
            $r.removed | Should -Be 1

            $afterC = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.subscribe'; topic = 'phase4.tC'; since = 0 }
            $afterC.events.Count | Should -Be 0

            $afterD = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.subscribe'; topic = 'phase4.tD'; since = 0 }
            $afterD.events.Count | Should -Be 1
        } finally { Stop-WizardPwsh $proc }
    }

    It "rejects publish without topic" {
        $pipeName = "wizard-pwsh-test-bad-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipeName
        try {
            $r = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.publish'; data = @{ x = 1 } }
            $r.status | Should -BeExactly 'error'
            $r.error | Should -BeExactly 'missing_topic'
        } finally { Stop-WizardPwsh $proc }
    }

    It "Start-MonitoredProcess publishes started + heartbeat + exited" {
        $pipeName = "wizard-pwsh-test-monproc-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipeName
        try {
            # Drive the wizard pwsh to start a monitored 3-second sleep child.
            $script = "Start-MonitoredProcess -FilePath '$($powershell.Replace("'", "''"))' -ArgumentList @('-NoProfile','-NoLogo','-Command','Start-Sleep -Seconds 3') -Topic 'phase4.proc' -HeartbeatSeconds 1 | Out-Null"
            $proc.StandardInput.WriteLine($script)
            $proc.StandardInput.Flush()

            # Poll for events for up to ~6 seconds.
            $deadline = (Get-Date).AddSeconds(8)
            $allEvents = @()
            while ((Get-Date) -lt $deadline) {
                $r = Send-WizardRequest -PipeName $pipeName -Payload @{ command = 'signal.subscribe'; topic = 'phase4.proc'; since = 0; limit = 100 }
                if ($r.events) { $allEvents = $r.events }
                if ($allEvents.state -contains 'exited' -or ($allEvents | Where-Object { $_.data.state -eq 'exited' })) { break }
                Start-Sleep -Milliseconds 500
            }

            $states = $allEvents | ForEach-Object { $_.data.state }
            $states | Should -Contain 'started'
            $states | Should -Contain 'heartbeat'
            $states | Should -Contain 'exited'
        } finally {
            Stop-WizardPwsh $proc
        }
    }
}
