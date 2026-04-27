# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Invoke-Bounded + Get-WizardLog" -Tags "Feature" {
    BeforeAll {
        # Use the host pwsh as our test child process — it's always available and we can ask
        # it to do exactly what we need (emit N lines, sleep, exit with a code).
        $childPwsh = Join-Path -Path $PSHOME -ChildPath "pwsh"

        $tempLogDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wizard-bounded-tests-$([Guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Force -Path $tempLogDir | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $tempLogDir) {
            Remove-Item -LiteralPath $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "writes the full output to a log file and returns head + tail" {
        $logPath = Join-Path -Path $tempLogDir -ChildPath "many-lines.log"
        # Emit 1000 lines.
        $cmd = '1..1000 | ForEach-Object { "line $_" }'
        $r = Invoke-Bounded -FilePath $childPwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', $cmd) -MaxLines 50 -LogTo $logPath -Quiet

        $r.ExitCode | Should -Be 0
        $r.KilledByTimeout | Should -BeFalse
        $r.TotalLines | Should -Be 1000
        $r.TruncatedLines | Should -Be 900
        $r.LogPath | Should -BeExactly $logPath
        Test-Path -LiteralPath $logPath | Should -BeTrue

        # Log file should contain all 1000 lines.
        $logCount = (Get-Content -LiteralPath $logPath | Measure-Object).Count
        $logCount | Should -Be 1000

        # Head should start with line 1, tail should end with line 1000.
        ($r.Head -split "`n")[0] | Should -BeExactly 'line 1'
        ($r.Tail -split "`n")[-1] | Should -BeExactly 'line 1000'
    }

    It "returns full output as Head when total lines <= MaxLines * 2" {
        $logPath = Join-Path -Path $tempLogDir -ChildPath "small.log"
        $cmd = '1..10 | ForEach-Object { "line $_" }'
        $r = Invoke-Bounded -FilePath $childPwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', $cmd) -MaxLines 50 -LogTo $logPath -Quiet

        $r.TotalLines | Should -Be 10
        $r.TruncatedLines | Should -Be 0
        ($r.Head -split "`n").Count | Should -Be 10
        $r.Tail | Should -BeNullOrEmpty
    }

    It "kills the child on timeout and reports KilledByTimeout=$true" {
        $logPath = Join-Path -Path $tempLogDir -ChildPath "timeout.log"
        # Sleep longer than the timeout. The child must die without hanging the test.
        $cmd = 'Start-Sleep -Seconds 30'
        $r = Invoke-Bounded -FilePath $childPwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', $cmd) -TimeoutSec 2 -LogTo $logPath -Quiet

        $r.KilledByTimeout | Should -BeTrue
        $r.Duration.TotalSeconds | Should -BeLessThan 10
    }

    It "Get-WizardLog -Range head:N returns the first N lines" {
        $logPath = Join-Path -Path $tempLogDir -ChildPath "range-head.log"
        Invoke-Bounded -FilePath $childPwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', '1..100 | ForEach-Object { "row $_" }') -LogTo $logPath -Quiet | Out-Null

        $head = Get-WizardLog -LogPath $logPath -Range 'head:5'
        $head.Count | Should -Be 5
        $head[0] | Should -BeExactly 'row 1'
        $head[4] | Should -BeExactly 'row 5'
    }

    It "Get-WizardLog -Range tail:N returns the last N lines" {
        $logPath = Join-Path -Path $tempLogDir -ChildPath "range-tail.log"
        Invoke-Bounded -FilePath $childPwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', '1..100 | ForEach-Object { "row $_" }') -LogTo $logPath -Quiet | Out-Null

        $tail = Get-WizardLog -LogPath $logPath -Range 'tail:3'
        $tail.Count | Should -Be 3
        $tail[-1] | Should -BeExactly 'row 100'
    }

    It "Get-WizardLog -Range lines:A-B returns the requested slice" {
        $logPath = Join-Path -Path $tempLogDir -ChildPath "range-lines.log"
        Invoke-Bounded -FilePath $childPwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', '1..100 | ForEach-Object { "row $_" }') -LogTo $logPath -Quiet | Out-Null

        $slice = Get-WizardLog -LogPath $logPath -Range 'lines:50-52'
        $slice.Count | Should -Be 3
        $slice[0] | Should -BeExactly 'row 50'
        $slice[2] | Should -BeExactly 'row 52'
    }

    It "Get-WizardLog -Range grep:PATTERN returns matching lines" {
        $logPath = Join-Path -Path $tempLogDir -ChildPath "range-grep.log"
        Invoke-Bounded -FilePath $childPwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', '"hello"; "error: foo"; "ok"; "Error: bar"; "done"') -LogTo $logPath -Quiet | Out-Null

        $matches = Get-WizardLog -LogPath $logPath -Range 'grep:[Ee]rror'
        $matches.Count | Should -Be 2
        $matches | Should -Contain 'error: foo'
        $matches | Should -Contain 'Error: bar'
    }

    It "throws on unknown range syntax" {
        $logPath = Join-Path -Path $tempLogDir -ChildPath "exists.log"
        Set-Content -LiteralPath $logPath -Value 'x' -NoNewline
        { Get-WizardLog -LogPath $logPath -Range 'first-three' } | Should -Throw "*Unknown range syntax*"
    }

    It "throws on missing log file" {
        $missing = Join-Path -Path $tempLogDir -ChildPath "does-not-exist.log"
        { Get-WizardLog -LogPath $missing -Range 'head:1' } | Should -Throw "*not found*"
    }

    It "β4: -PassThru produces the same bounded result and writes a complete log" {
        $logPath = Join-Path -Path $tempLogDir -ChildPath "passthru.log"
        $cmd = '1..200 | ForEach-Object { "row $_" }'
        $r = Invoke-Bounded -FilePath $childPwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', $cmd) -MaxLines 10 -LogTo $logPath -PassThru -Quiet *>$null

        # The cmdlet must still return the bounded-result object.
        $r2 = Invoke-Bounded -FilePath $childPwsh -ArgumentList @('-NoProfile', '-NoLogo', '-Command', $cmd) -MaxLines 10 -LogTo (Join-Path $tempLogDir 'passthru-control.log') -Quiet
        $r2.TotalLines | Should -Be 200

        # Log file written by -PassThru run must have all 200 rows.
        $logCount = (Get-Content -LiteralPath $logPath | Measure-Object).Count
        $logCount | Should -Be 200
    }
}
