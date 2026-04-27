# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Send-WizardControlRequest {
    <#
    .SYNOPSIS
        Sends one JSON-RPC request to the WizardControlServer named pipe and returns the parsed reply.

    .DESCRIPTION
        Internal helper used by Publish-WizardSignal, Read-WizardSignal, and Start-MonitoredProcess.
        Defaults to this process's pipe (wizard-pwsh-$PID) and a 5-second connect timeout.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Payload,

        [string] $PipeName,
        [int]    $ConnectTimeoutMs = 5000
    )

    if (-not $PipeName) {
        if ($env:WIZARD_PWSH_CONTROL_PIPE) {
            $PipeName = $env:WIZARD_PWSH_CONTROL_PIPE
        } else {
            $PipeName = "wizard-pwsh-$PID"
        }
    }

    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
        ".",
        $PipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::None)
    try {
        $pipe.Connect($ConnectTimeoutMs)
        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.UTF8Encoding]::new($false), 4096, $true)
        $writer.AutoFlush = $true
        $reader = [System.IO.StreamReader]::new($pipe, [System.Text.Encoding]::UTF8, $false, 4096, $true)
        $writer.WriteLine(($Payload | ConvertTo-Json -Compress -Depth 10))
        $line = $reader.ReadLine()
        if ($null -eq $line) {
            throw "WizardControlServer closed the pipe without responding."
        }
        return $line | ConvertFrom-Json
    }
    finally {
        $pipe.Dispose()
    }
}
