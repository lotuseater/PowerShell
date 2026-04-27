# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Start-MonitoredProcess {
    <#
    .SYNOPSIS
        Starts a child process and publishes its lifecycle to the Wizard signal bus.

    .DESCRIPTION
        Launches the process detached (no stdout capture — that's Invoke-Bounded's job),
        then in a background runspace publishes process.started / process.heartbeat /
        process.exited events to the topic specified by -Topic (default: process.<exe>).
        Returns immediately with a record describing the started process.

        The intent is to replace the OCR + dab_wait_idle polling loop with structured
        signal events: agents subscribe to process.* and learn about completion without
        screen scraping.

    .EXAMPLE
        Start-MonitoredProcess -FilePath cmake -ArgumentList @('--build','build') -Topic process.build
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $FilePath,

        [Parameter(Position = 1)]
        [string[]] $ArgumentList = @(),

        [string] $Topic,
        [string] $WorkingDirectory,
        [int]    $HeartbeatSeconds = 2
    )

    if (-not $WorkingDirectory) {
        $WorkingDirectory = (Get-Location).ProviderPath
    }
    if (-not $Topic) {
        $Topic = "process.$([System.IO.Path]::GetFileNameWithoutExtension($FilePath))"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($a in $ArgumentList) { [void]$startInfo.ArgumentList.Add($a) }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $process.EnableRaisingEvents = $true
    [void]$process.Start()

    Publish-WizardSignal -Topic $Topic -Data @{
        state    = 'started'
        pid      = $process.Id
        command  = $FilePath
        args     = $ArgumentList
        cwd      = $WorkingDirectory
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | Out-Null

    # Heartbeat loop in a background runspace. Publishes one event per HeartbeatSeconds
    # while the child is alive, then a final 'exited' event with the exit code.
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create().AddScript({
        param($childPid, $topic, $heartbeat, $pipe)
        try {
            $p = Get-Process -Id $childPid -ErrorAction SilentlyContinue
            while ($p -and -not $p.HasExited) {
                $payload = @{
                    state = 'heartbeat'
                    pid = $childPid
                    cpuSeconds = [Math]::Round($p.TotalProcessorTime.TotalSeconds, 2)
                    workingSetMB = [Math]::Round($p.WorkingSet64 / 1MB, 1)
                    elapsedSeconds = [Math]::Round(((Get-Date) - $p.StartTime).TotalSeconds, 1)
                }
                $body = @{
                    command = 'signal.publish'
                    topic = $topic
                    data = $payload
                } | ConvertTo-Json -Compress -Depth 10
                try {
                    $client = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
                    $client.Connect(2000)
                    $w = [System.IO.StreamWriter]::new($client, [System.Text.UTF8Encoding]::new($false), 4096, $true)
                    $w.AutoFlush = $true
                    $r = [System.IO.StreamReader]::new($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)
                    $w.WriteLine($body)
                    $null = $r.ReadLine()
                    $client.Dispose()
                } catch {
                    # Pipe gone (parent exiting) — abort.
                    return
                }
                Start-Sleep -Seconds $heartbeat
                $p.Refresh()
            }

            # Final 'exited'.
            $exitCode = if ($p) { try { $p.ExitCode } catch { -1 } } else { -1 }
            $body = @{
                command = 'signal.publish'
                topic = $topic
                data = @{
                    state = 'exited'
                    pid = $childPid
                    exitCode = $exitCode
                    exitedAt = (Get-Date).ToUniversalTime().ToString('o')
                }
            } | ConvertTo-Json -Compress -Depth 10
            try {
                $client = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
                $client.Connect(2000)
                $w = [System.IO.StreamWriter]::new($client, [System.Text.UTF8Encoding]::new($false), 4096, $true)
                $w.AutoFlush = $true
                $r = [System.IO.StreamReader]::new($client, [System.Text.Encoding]::UTF8, $false, 4096, $true)
                $w.WriteLine($body)
                $null = $r.ReadLine()
                $client.Dispose()
            } catch { }
        } catch { }
    }).AddArgument($process.Id).AddArgument($Topic).AddArgument($HeartbeatSeconds).AddArgument(
        $(if ($env:WIZARD_PWSH_CONTROL_PIPE) { $env:WIZARD_PWSH_CONTROL_PIPE } else { "wizard-pwsh-$PID" })
    )
    $ps.Runspace = $runspace
    [void]$ps.BeginInvoke()

    [pscustomobject]@{
        PSTypeName = 'WizardMonitoredProcess'
        Pid        = $process.Id
        Topic      = $Topic
        Command    = $FilePath
        Args       = $ArgumentList
        Cwd        = $WorkingDirectory
    }
}
