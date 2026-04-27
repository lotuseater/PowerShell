# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Read-WizardSignal {
    <#
    .SYNOPSIS
        Reads events from a topic on the Wizard signal bus, optionally since a cursor.

    .DESCRIPTION
        Returns the response object: { status, command, topic, head, total, events[] }.
        Caller advances `since` to the largest seq seen and polls again.

        With `-WaitMs N` the cmdlet polls every `-PollIntervalMs` (default 100 ms) until
        new events arrive or the wait deadline elapses, then returns. This is *client-side*
        long-poll — the wizard pipe is single-instance per PID, so a server-side blocking
        wait would serialize every other request behind it. Polling at 100 ms incurs ≤10
        pipe round-trips per second, which is well within the wizard pipe's capacity.

    .EXAMPLE
        $r = Read-WizardSignal -Topic process.heartbeat -Since 0 -Limit 100

    .EXAMPLE
        # Block (with 5 s ceiling) until a new cognitive.pulse arrives.
        $r = Read-WizardSignal -Topic cognitive.pulse -Since $lastSeq -WaitMs 5000
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Topic,

        [long] $Since = 0,
        [int]  $Limit = 64,
        [int]  $WaitMs = 0,
        [int]  $PollIntervalMs = 100,
        [string] $PipeName
    )

    $payload = @{
        command = 'signal.subscribe'
        topic   = $Topic
        since   = $Since
        limit   = $Limit
    }

    if ($WaitMs -le 0) {
        return Send-WizardControlRequest -Payload $payload -PipeName $PipeName
    }

    if ($PollIntervalMs -lt 25) { $PollIntervalMs = 25 }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitMs)
    $latest = $null
    do {
        $latest = Send-WizardControlRequest -Payload $payload -PipeName $PipeName
        if ($latest.status -ne 'ok') { return $latest }
        if ($latest.events -and $latest.events.Count -gt 0) { return $latest }
        $remaining = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remaining -le 0) { break }
        $sleep = [Math]::Min([int]$remaining, $PollIntervalMs)
        Start-Sleep -Milliseconds $sleep
    } while ([DateTime]::UtcNow -lt $deadline)

    return $latest
}
