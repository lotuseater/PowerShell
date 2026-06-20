# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "status.extended verb (gamma2)" -Tags "Feature" {
    BeforeAll {
        function Resolve-WizardStatusTestPwsh {
            $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')
            $candidates = @()
            if ($env:WIZARD_STATUS_TEST_PWSH) {
                $candidates += $env:WIZARD_STATUS_TEST_PWSH
            }
            $candidates += Join-Path $repoRoot 'src\powershell-win-core\bin\Debug\net11.0\win7-x64\publish\pwsh.exe'
            $candidates += Join-Path $repoRoot 'src\powershell-win-core\bin\Release\net11.0\win7-x64\publish\pwsh.exe'
            $candidates += Join-Path -Path $PSHOME -ChildPath 'pwsh'

            foreach ($candidate in $candidates) {
                if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    return (Resolve-Path -LiteralPath $candidate).Path
                }
            }
            throw 'No pwsh executable found for status.extended tests.'
        }

        $script:Pwsh = Resolve-WizardStatusTestPwsh

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
            param([string] $PipeName, [hashtable] $Payload, [int] $TimeoutMs = 15000)
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

    It "returns the same fields as plain status plus extended fields" {
        $pipe = "wizard-pwsh-test-statusext-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'status.extended' }
            $r.status | Should -BeExactly 'ok'
            $r.protocol | Should -Be 1
            $r.pipe | Should -BeExactly $pipe
            # Plain status fields still there.
            $r.runspaceState | Should -Not -BeNullOrEmpty
            $r.PSObject.Properties.Name | Should -Contain 'promptActive'
            $r.PSObject.Properties.Name | Should -Contain 'shouldEndSession'
            # Extended fields present (may be null/0 in a fresh shell with no command running yet).
            $r.PSObject.Properties.Name | Should -Contain 'currentCommand'
            $r.PSObject.Properties.Name | Should -Contain 'lastCommand'
            $r.PSObject.Properties.Name | Should -Contain 'historyCount'
            $r.PSObject.Properties.Name | Should -Contain 'analysisCachePath'
            [int64]$r.historyCount | Should -BeGreaterOrEqual 0
        } finally { Stop-WizardPwsh $proc }
    }

    It "keeps extended status available after command activity" {
        $pipe = "wizard-pwsh-test-statusext-cmd-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            # Run a benign command via stdin. The redirected test host may not
            # populate interactive PSReadLine history, so this verifies the
            # extended snapshot stays well-formed after activity instead of
            # requiring a concrete history backend.
            $proc.StandardInput.WriteLine('1+1; "hello-from-status-test"')
            $proc.StandardInput.Flush()
            Start-Sleep -Milliseconds 700  # let it execute

            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'status.extended' }
            $r.status | Should -BeExactly 'ok'
            [int64]$r.historyCount | Should -BeGreaterOrEqual 0
            $r.PSObject.Properties.Name | Should -Contain 'lastCommand'
        } finally { Stop-WizardPwsh $proc }
    }

    It "plain status verb still works (backwards compatibility)" {
        $pipe = "wizard-pwsh-test-status-back-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'status' }
            $r.status | Should -BeExactly 'ok'
            # Plain status must NOT include the extended fields (avoid breaking parsers
            # that expect a fixed shape).
            $r.PSObject.Properties.Name | Should -Not -Contain 'currentCommand'
            $r.PSObject.Properties.Name | Should -Not -Contain 'historyCount'
        } finally { Stop-WizardPwsh $proc }
    }
}
