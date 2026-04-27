# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Read-WizardSignal {
    <#
    .SYNOPSIS
        Reads events from a topic on the Wizard signal bus, optionally since a cursor.

    .DESCRIPTION
        Returns the response object: { status, command, topic, head, total, events[] }.
        Caller advances `since` to the largest seq seen and polls again. No long-poll;
        the server is single-instance per PID and unblocking polls is more important
        than reducing poll count for the expected cadence (1-5s).

    .EXAMPLE
        $r = Read-WizardSignal -Topic process.heartbeat -Since 0 -Limit 100
        $r.events | ForEach-Object { $_.data.pid }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Topic,

        [long] $Since = 0,
        [int]  $Limit = 64,
        [string] $PipeName
    )

    $payload = @{
        command = 'signal.subscribe'
        topic   = $Topic
        since   = $Since
        limit   = $Limit
    }

    Send-WizardControlRequest -Payload $payload -PipeName $PipeName
}
