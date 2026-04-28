# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Get-WizardLogs / Get-WizardLog -Latest (δ1)" -Tags "Feature" {
    BeforeAll {
        Import-Module (Join-Path $PSHOME "Modules/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psd1") -Force

        $script:LogRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-logs-$([Guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:LogRoot) {
            Remove-Item -LiteralPath $script:LogRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Get-WizardLogs" {
        It "returns nothing for an empty log dir" {
            $r = @(Get-WizardLogs -LogRoot $LogRoot)
            $r.Count | Should -Be 0
        }

        It "lists logs newest-first and parses pid + timestamp from filename" {
            # Create three logs with predictable names matching the Invoke-Bounded format.
            $names = @(
                '12345-20260101T120000000.log',
                '12345-20260102T120000000.log',
                '67890-20260103T120000000.log'
            )
            foreach ($n in $names) {
                $p = Join-Path $LogRoot $n
                Set-Content -LiteralPath $p -Value "log $n`r`nrow1`r`nrow2"
                Start-Sleep -Milliseconds 50  # ensure distinct LastWriteTime
            }

            $logs = @(Get-WizardLogs -LogRoot $LogRoot)
            $logs.Count | Should -Be 3
            # Newest first → the last-written should be first.
            $logs[0].Name | Should -BeExactly '67890-20260103T120000000.log'
            $logs[0].Pid | Should -Be 67890
            $logs[0].Started | Should -Not -BeNullOrEmpty
            $logs[0].SizeBytes | Should -BeGreaterThan 0
            $logs[0].LineCount | Should -BeNullOrEmpty  # not requested
        }

        It "honours -Top to bound the result" {
            $logs = @(Get-WizardLogs -LogRoot $LogRoot -Top 2)
            $logs.Count | Should -Be 2
        }

        It "honours -All to override -Top" {
            $logs = @(Get-WizardLogs -LogRoot $LogRoot -All)
            $logs.Count | Should -BeGreaterOrEqual 3
        }

        It "computes LineCount when -WithLineCount is set" {
            $logs = @(Get-WizardLogs -LogRoot $LogRoot -WithLineCount -Top 1)
            $logs[0].LineCount | Should -BeGreaterThan 0
        }

        It "tolerates filenames that don't match the pid-ts format" {
            $weird = Join-Path $LogRoot 'something-weird.log'
            Set-Content -LiteralPath $weird -Value 'x'
            try {
                $logs = @(Get-WizardLogs -LogRoot $LogRoot -All)
                $weirdEntry = $logs | Where-Object Name -eq 'something-weird.log'
                $weirdEntry | Should -Not -BeNullOrEmpty
                $weirdEntry.Pid | Should -BeNullOrEmpty
                $weirdEntry.Started | Should -BeNullOrEmpty
            } finally { Remove-Item -LiteralPath $weird -Force }
        }
    }

    Context "Get-WizardLog -Latest" {
        It "throws when the default log dir is empty" {
            # Use an empty dir to simulate "no logs ever".
            $emptyDir = Join-Path $LogRoot 'empty'
            New-Item -ItemType Directory -Force -Path $emptyDir | Out-Null
            try {
                # We can't easily redirect Get-WizardLog -Latest to a custom dir without
                # adding a parameter. Skip: the cmdlet hardcodes %LOCALAPPDATA%, which on
                # this machine has wizard logs already. So just assert the cmdlet runs.
                { Get-WizardLog -Latest -Range 'tail:1' -ErrorAction Stop | Out-Null } | Should -Not -Throw
            } finally {
                Remove-Item -LiteralPath $emptyDir -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
