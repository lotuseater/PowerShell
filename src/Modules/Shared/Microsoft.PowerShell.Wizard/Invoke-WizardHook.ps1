# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Invoke-WizardHook {
    <#
    .SYNOPSIS
        Invoke a registered hook in the warm Python child held by the WizardControlServer.

    .DESCRIPTION
        Sends a `hook.invoke` request over the local control pipe. The first call lazily
        spawns one persistent `py -3.14 -m wizard_mcp.hook_host` child; subsequent calls reuse
        it, eliminating the cold-spawn cost (~200-500 ms × ~14 hooks per agent turn).

        The hook host module path can be overridden by the `WIZARD_HOOKHOST_MODULE` env var
        (default `wizard_mcp.hook_host`); the Python launcher executable by `WIZARD_HOOKHOST_PYTHON`
        (default `py`).

    .PARAMETER Name
        Logical hook name. The Python side dispatches by this string.

    .PARAMETER Payload
        Object passed as JSON to the hook. Hashtables, pscustomobjects, and primitives all serialise.

    .PARAMETER TimeoutMs
        Per-invocation timeout in milliseconds. Default 30000.

    .PARAMETER PipeName
        Override the control pipe name. Default: this process's `wizard-pwsh-$PID` or `WIZARD_PWSH_CONTROL_PIPE`.

    .EXAMPLE
        Invoke-WizardHook -Name pretool_cache -Payload @{ tool_name='Read'; file_path='x.cs' }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Name,

        [Parameter(Position = 1)]
        [object] $Payload,

        [int] $TimeoutMs = 30000,
        [string] $PipeName
    )

    $body = @{
        command   = 'hook.invoke'
        name      = $Name
        timeoutMs = $TimeoutMs
        payload   = $Payload
    }

    Send-WizardControlRequest -Payload $body -PipeName $PipeName -ConnectTimeoutMs 5000
}
