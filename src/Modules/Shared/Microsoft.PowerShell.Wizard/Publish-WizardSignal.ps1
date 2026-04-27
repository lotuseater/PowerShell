# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Publish-WizardSignal {
    <#
    .SYNOPSIS
        Publishes a structured event to a topic on the Wizard signal bus.

    .DESCRIPTION
        Use this from hooks, build wrappers, or long-running cmdlets to surface state changes
        that an external agent (Claude/Codex/WizardErasmus) can poll for, instead of forcing
        the agent to OCR the screen or re-run a status check.

    .EXAMPLE
        Publish-WizardSignal -Topic process.heartbeat -Data @{ pid = 1234; lastOutputAt = (Get-Date) }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Topic,

        [Parameter(Position = 1)]
        [object] $Data,

        [int] $Ring = 256,
        [string] $PipeName
    )

    $payload = @{
        command = 'signal.publish'
        topic   = $Topic
        ring    = $Ring
        data    = $Data
    }

    Send-WizardControlRequest -Payload $payload -PipeName $PipeName
}
