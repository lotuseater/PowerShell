# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Wizard PowerShell startup hardening" -Tags "Feature" {
    BeforeAll {
        $powershell = Join-Path -Path $PSHOME -ChildPath "pwsh"

        function Invoke-WizardPwsh {
            param(
                [Parameter(Mandatory)]
                [string] $Script,

                [bool] $EnableWizardControl = $true
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
                $startInfo.Environment["WIZARD_PWSH_CONTROL_PIPE"] = "wizard-pwsh-startup-$PID-$([Guid]::NewGuid().ToString('N'))"
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

                return [pscustomobject]@{
                    StdOut   = $process.StandardOutput.ReadToEnd()
                    StdErr   = $process.StandardError.ReadToEnd()
                    ExitCode = $process.ExitCode
                }
            }
            finally {
                if ($process -and -not $process.HasExited) {
                    $process.Kill()
                    $process.WaitForExit(5000) | Out-Null
                }
            }
        }
    }

    It "sets UTF-8 console encodings and runspace prefs when WIZARD_PWSH_CONTROL=1" {
        $script = @'
[Console]::OutputEncoding.WebName
"---"
$OutputEncoding.WebName
"---"
($PSNativeCommandUseErrorActionPreference).ToString()
'@
        $result = Invoke-WizardPwsh -Script $script -EnableWizardControl $true
        $result.ExitCode | Should -Be 0

        $parts = $result.StdOut -split "(?:\r?\n)?---(?:\r?\n)?"
        # Trim and filter empty entries because output may end with a trailing newline.
        $values = $parts | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

        $values.Count | Should -Be 3
        $values[0] | Should -BeExactly "utf-8"
        $values[1] | Should -BeExactly "utf-8"
        $values[2] | Should -BeExactly "True"
    }

    It "round-trips non-ASCII bytes through stdout under WIZARD_PWSH_CONTROL=1" {
        # The literal byte sequence for U+00E9 (é) in UTF-8 is 0xC3 0xA9. In cp1252 it would be 0xE9.
        $result = Invoke-WizardPwsh -Script '[Console]::Out.Write([char]0x00E9)' -EnableWizardControl $true
        $result.ExitCode | Should -Be 0
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($result.StdOut)
        # Strip any trailing CR/LF the host might add.
        $payload = $bytes | Where-Object { $_ -ne 13 -and $_ -ne 10 }
        $payload.Count | Should -Be 2
        $payload[0] | Should -Be 0xC3
        $payload[1] | Should -Be 0xA9
    }

    It "leaves PSNativeCommandUseErrorActionPreference at its default when env var is absent" {
        # Sanity check: hardening must be opt-in. Without the env var, we should not be flipping
        # this preference for the user. We don't check encoding here because the test process
        # itself may have already set Console encoding, and we only care about the runspace pref.
        $script = '($PSNativeCommandUseErrorActionPreference).ToString()'
        $result = Invoke-WizardPwsh -Script $script -EnableWizardControl $false
        $result.ExitCode | Should -Be 0

        # Default in PS7+ is False. We assert "not True" rather than equality so the test stays
        # robust if upstream flips the default in a future release.
        $result.StdOut.Trim() | Should -Not -BeExactly "True"
    }
}
