# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Get-WizardSession" -Tags "Feature" {
    BeforeAll {
        $powershell = Join-Path -Path $PSHOME -ChildPath "pwsh"

        function Invoke-WizardPwshJson {
            param(
                [Parameter(Mandatory)]
                [string] $Script,

                [bool] $EnableWizardControl = $true,
                [string] $PipeOverride
            )

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $powershell
            $startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -Command -"
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8

            if ($EnableWizardControl) {
                $startInfo.Environment["WIZARD_PWSH_CONTROL"] = "1"
                if ($PipeOverride) {
                    $startInfo.Environment["WIZARD_PWSH_CONTROL_PIPE"] = $PipeOverride
                }
            } else {
                $startInfo.Environment["WIZARD_PWSH_CONTROL"] = ""
            }

            $process = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $process.StandardInput.WriteLine($Script)
                $process.StandardInput.Close()

                if (-not $process.WaitForExit(20000)) {
                    $process.Kill()
                    throw "pwsh did not exit within 20s"
                }

                $stdout = $process.StandardOutput.ReadToEnd()
                $stderr = $process.StandardError.ReadToEnd()
                if ($process.ExitCode -ne 0) {
                    throw "pwsh exited with $($process.ExitCode). stderr: $stderr. stdout: $stdout"
                }
                return $stdout | ConvertFrom-Json
            }
            finally {
                if ($process -and -not $process.HasExited) {
                    $process.Kill()
                    $process.WaitForExit(5000) | Out-Null
                }
            }
        }
    }

    It "returns a WizardSession record with expected fields when enabled" {
        $custom = "wizard-pwsh-test-getsession-$([Guid]::NewGuid().ToString('N'))"
        $result = Invoke-WizardPwshJson -Script "Get-WizardSession | ConvertTo-Json -Depth 3" -EnableWizardControl $true -PipeOverride $custom

        $result.Pid | Should -BeGreaterThan 0
        $result.WizardControlEnabled | Should -BeTrue
        $result.PipeName | Should -BeExactly $custom
        $result.SessionRecord | Should -Match '\\WizardPowerShell\\sessions\\\d+\.json$'
        $result.LogDir | Should -Match '\\WizardPowerShell\\logs$'
        # Phase 6: hook-host status is 'idle' when the wizard pwsh is up but no hooks have
        # fired yet, 'warm (N hooks)' once hooks have been invoked, and 'disabled' if the
        # pipe lookup fails. The freshly-spawned subprocess in this test won't have invoked
        # any hooks, so 'idle' is the expected steady state.
        $result.HookHostStatus | Should -BeIn @('idle', 'disabled')
        $result.ConsoleEncoding | Should -BeExactly 'utf-8'
        $result.OutputEncoding | Should -BeExactly 'utf-8'
        $result.NativeErrorPreference | Should -BeTrue
    }

    It "still returns a record with WizardControlEnabled=$false when env var is absent" {
        $result = Invoke-WizardPwshJson -Script "Get-WizardSession | ConvertTo-Json -Depth 3" -EnableWizardControl $false

        $result.WizardControlEnabled | Should -BeFalse
        $result.PipeName | Should -BeNullOrEmpty
        $result.SessionRecord | Should -BeNullOrEmpty
        $result.HookHostStatus | Should -BeExactly 'disabled'
        # LogDir is reported regardless so callers can resolve it for log fetch later.
        $result.LogDir | Should -Match '\\WizardPowerShell\\logs$'
    }

    It "ships with the host as a discoverable module under `$PSHOME\Modules" {
        # Single-line script — multi-line pipelines via stdin sometimes lose line continuation.
        $script = '$m = Get-Module Microsoft.PowerShell.Wizard -ListAvailable | Select-Object -First 1; [pscustomobject]@{ Name=$m.Name; Version="$($m.Version)"; UnderPSHome=($m.Path -like "$PSHOME*"); ExportsGetWizardSession=$m.ExportedFunctions.ContainsKey("Get-WizardSession") } | ConvertTo-Json -Depth 3'
        $result = Invoke-WizardPwshJson -Script $script -EnableWizardControl $true

        $result.Name | Should -BeExactly 'Microsoft.PowerShell.Wizard'
        $result.Version | Should -Be '0.1.0'
        $result.UnderPSHome | Should -BeTrue
        $result.ExportsGetWizardSession | Should -BeTrue
    }
}
