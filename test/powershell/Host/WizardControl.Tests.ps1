# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Wizard PowerShell control pipe" -Tags "Feature" {
    BeforeAll {
        $powershell = Join-Path -Path $PSHOME -ChildPath "pwsh"

        function Send-WizardControlRequest {
            param(
                [Parameter(Mandatory)]
                [string] $PipeName,

                [Parameter(Mandatory)]
                [hashtable] $Payload
            )

            $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
                ".",
                $PipeName,
                [System.IO.Pipes.PipeDirection]::InOut,
                [System.IO.Pipes.PipeOptions]::None)
            $pipe.Connect(10000)
            try {
                $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.UTF8Encoding]::new($false), 4096, $true)
                $writer.AutoFlush = $true
                $reader = [System.IO.StreamReader]::new($pipe, [System.Text.Encoding]::UTF8, $false, 4096, $true)
                $writer.WriteLine(($Payload | ConvertTo-Json -Compress))
                return $reader.ReadLine() | ConvertFrom-Json
            }
            finally {
                $pipe.Dispose()
            }
        }
    }

    It "starts only when enabled and answers hello/status requests" {
        $pipeName = "wizard-pwsh-test-$PID-$([Guid]::NewGuid().ToString('N'))"
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $powershell
        $startInfo.Arguments = "-NoLogo -NoProfile -NoExit"
        $startInfo.UseShellExecute = $false
        $startInfo.Environment["WIZARD_PWSH_CONTROL"] = "1"
        $startInfo.Environment["WIZARD_PWSH_CONTROL_PIPE"] = $pipeName

        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $hello = Send-WizardControlRequest -PipeName $pipeName -Payload @{ command = "hello" }
            $hello.status | Should -BeExactly "ok"
            $hello.protocol | Should -Be 1
            $hello.provider | Should -BeExactly "powershell"
            $hello.pid | Should -Be $process.Id
            $hello.pipe | Should -BeExactly $pipeName

            $status = Send-WizardControlRequest -PipeName $pipeName -Payload @{ command = "status" }
            $status.status | Should -BeExactly "ok"
            $status.pid | Should -Be $process.Id
            $status.pipe | Should -BeExactly $pipeName
        }
        finally {
            if ($process -and -not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit(10000) | Out-Null
            }
        }
    }
}
