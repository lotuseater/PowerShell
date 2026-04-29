# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Initialize-WizardHookHost {
    <#
    .SYNOPSIS
        Eagerly pre-import named hook modules in the warm Python child so the first
        `hook.invoke` doesn't pay the cold-import cost.

    .DESCRIPTION
        Sends a `hook.warmup { names: [...] }` request over the wizard control pipe.
        The C# server forwards a `verb=warmup` NDJSON frame to the warm child;
        `hook_host.py` imports each named module via the same loader path that
        `hook.invoke` would use lazily.

        Typical use: in your wizard pwsh startup (after `Get-WizardSession` reports
        `WizardControlEnabled=$true`), call:

            Initialize-WizardHookHost -Hooks @('cognitive_pulse', 'pretool_cache')

        The first `cognitive_pulse` of the session then takes ≤ a few ms instead of
        the 200-500 ms cold-import on first model turn.

    .PARAMETER Hooks
        Logical hook names to warm. Each must match an entry in the warm child's
        HOOK_PATHS / HOOKS dispatch table.

    .PARAMETER TimeoutMs
        Per-call timeout. Default 30 000 ms.

    .PARAMETER PipeName
        Override the control pipe name. Default: `wizard-pwsh-$PID`.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]] $Hooks,

        [int] $TimeoutMs = 30000,
        [int] $ConnectTimeoutMs = 5000,
        [string] $PipeName
    )

    $body = @{
        command   = 'hook.warmup'
        names     = $Hooks
        timeoutMs = $TimeoutMs
    }

    Send-WizardControlRequest -Payload $body -PipeName $PipeName -ConnectTimeoutMs $ConnectTimeoutMs
}
