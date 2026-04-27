# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Invoke-Bounded {
    <#
    .SYNOPSIS
        Runs a native process and bounds the output that returns to the caller.

    .DESCRIPTION
        Streams the full stdout+stderr to a log file under %LOCALAPPDATA%\WizardPowerShell\logs
        (or -LogTo) and returns a WizardBoundedResult with only the first MaxLines and last
        MaxLines of stdout. The motivation is agent-driven sessions: a 100,000-line cmake
        run should not consume 100,000 lines of model context. The agent (or a human) can
        fetch arbitrary slices of the full log later via Get-WizardLog.

        Killed-by-timeout is reported in the result rather than thrown — callers branching
        on it can decide whether to retry, raise the timeout, or surface to the user.

    .EXAMPLE
        $r = Invoke-Bounded ninja -- build
        Get-WizardLog -LogPath $r.LogPath -Range tail:500
    #>
    [CmdletBinding()]
    [OutputType('WizardBoundedResult')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $FilePath,

        [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
        [string[]] $ArgumentList = @(),

        [int] $MaxBytes = 16384,
        [int] $MaxLines = 80,
        [int] $TimeoutSec = 120,
        [string] $LogTo,
        [string] $WorkingDirectory,
        [switch] $Quiet,
        [switch] $MergeStdErr,
        # β4: when set, each child stdout line is forwarded to the host in real time so
        # the user/agent sees progress on long-running commands. Stderr lines are forwarded
        # to host stderr. The bounded result (head/tail/log) is still computed at the end.
        [switch] $PassThru
    )

    if (-not $WorkingDirectory) {
        $WorkingDirectory = (Get-Location).ProviderPath
    }

    if (-not $LogTo) {
        $logDir = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\logs'
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        }
        $stamp = (Get-Date -Format 'yyyyMMddTHHmmssfff')
        $LogTo = Join-Path -Path $logDir -ChildPath ("$PID-$stamp.log")
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($a in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add($a)
    }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($PassThru) {
        # β4: line-streamed mode. Use OutputDataReceived / ErrorDataReceived events so each
        # line is forwarded to the host as it arrives. We still accumulate everything for
        # the bounded-result computation at the end. Concurrent-safe: events fire on
        # background threads, so use ConcurrentQueue and a script-scoped sync object.
        $outQ = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $errQ = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

        $outHandler = {
            param($sender, $eventArgs)
            if ($null -ne $eventArgs.Data) {
                $Event.MessageData.OutQueue.Enqueue($eventArgs.Data)
                [Console]::Out.WriteLine($eventArgs.Data)
            }
        }
        $errHandler = {
            param($sender, $eventArgs)
            if ($null -ne $eventArgs.Data) {
                $Event.MessageData.ErrQueue.Enqueue($eventArgs.Data)
                [Console]::Error.WriteLine($eventArgs.Data)
            }
        }
        $msgData = [pscustomobject]@{ OutQueue = $outQ; ErrQueue = $errQ }
        $outSub = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $outHandler -MessageData $msgData
        $errSub = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $errHandler -MessageData $msgData

        try {
            [void]$process.Start()
            $process.BeginOutputReadLine()
            $process.BeginErrorReadLine()

            $killed = $false
            if (-not $process.WaitForExit($TimeoutSec * 1000)) {
                try { $process.Kill($true) } catch { }
                $process.WaitForExit(5000) | Out-Null
                $killed = $true
            }
            # Drain any outstanding events posted just before exit.
            $process.WaitForExit()
        } finally {
            Unregister-Event -SourceIdentifier $outSub.Name -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier $errSub.Name -ErrorAction SilentlyContinue
        }
        $stopwatch.Stop()

        $stdout = ($outQ.ToArray() -join "`n")
        $stderr = ($errQ.ToArray() -join "`n")
    } else {
        [void]$process.Start()

        # Read both pipes asynchronously to prevent the child from blocking on a full buffer.
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()

        $killed = $false
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try { $process.Kill($true) } catch { }
            $process.WaitForExit(5000) | Out-Null
            $killed = $true
        }
        $stopwatch.Stop()

        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
    }

    $writer = [System.IO.StreamWriter]::new($LogTo, $false, [System.Text.UTF8Encoding]::new($false))
    try {
        if ($stdout) { $writer.Write($stdout) }
        if ($stderr) {
            $writer.WriteLine()
            $writer.WriteLine('--- STDERR ---')
            $writer.Write($stderr)
        }
    }
    finally {
        $writer.Dispose()
    }

    $primary = if ($MergeStdErr) { $stdout + "`n" + $stderr } else { $stdout }
    if ($null -eq $primary) { $primary = '' }

    $allLines = [System.Collections.Generic.List[string]]::new()
    if ($primary.Length -gt 0) {
        # Split on CR/LF, preserve middle empties, drop the trailing empty caused by a final newline.
        $split = $primary -split "`r?`n"
        if ($split.Count -gt 0 -and $split[-1] -eq '') {
            for ($i = 0; $i -lt $split.Count - 1; $i++) { $allLines.Add($split[$i]) }
        } else {
            foreach ($s in $split) { $allLines.Add($s) }
        }
    }

    $totalLines = $allLines.Count
    $headEnd = [Math]::Min($MaxLines, $totalLines)
    $head = if ($headEnd -gt 0) { $allLines.GetRange(0, $headEnd) } else { @() }

    $tailStart = [Math]::Max($MaxLines, $totalLines - $MaxLines)
    $tail = if ($tailStart -lt $totalLines) {
        $allLines.GetRange($tailStart, $totalLines - $tailStart)
    } else {
        @()
    }
    $truncated = [Math]::Max(0, $totalLines - ($head.Count + $tail.Count))

    $headStr = ($head -join "`n")
    $tailStr = ($tail -join "`n")
    $maxHalf = [int]($MaxBytes / 2)
    if ($headStr.Length -gt $maxHalf) {
        $headStr = $headStr.Substring(0, $maxHalf) + "`n...[head byte-truncated]"
    }
    if ($tailStr.Length -gt $maxHalf) {
        $tailStr = "[tail byte-truncated]...`n" + $tailStr.Substring($tailStr.Length - $maxHalf)
    }

    $result = [pscustomobject]@{
        PSTypeName      = 'WizardBoundedResult'
        ExitCode        = $process.ExitCode
        Head            = $headStr
        Tail            = $tailStr
        LogPath         = $LogTo
        TotalLines      = $totalLines
        TruncatedLines  = $truncated
        Duration        = $stopwatch.Elapsed
        KilledByTimeout = $killed
        StdErrBytes     = if ($null -eq $stderr) { 0 } else { $stderr.Length }
    }

    if (-not $Quiet) {
        if ($headStr.Length -gt 0) { [Console]::Out.WriteLine($headStr) }
        if ($truncated -gt 0) {
            [Console]::Out.WriteLine("`n[wizard] truncated $truncated lines (total $totalLines). Full log: $LogTo`n")
        }
        if ($tailStr.Length -gt 0 -and $tail.Count -gt 0 -and $head.Count -lt $totalLines) {
            [Console]::Out.WriteLine($tailStr)
        }
    }

    return $result
}
