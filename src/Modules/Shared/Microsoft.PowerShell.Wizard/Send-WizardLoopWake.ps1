# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Send-WizardLoopWake {
    <#
    .SYNOPSIS
        Wake a sleeping WizardErasmus loop driver early.

    .DESCRIPTION
        Wraps Publish-WizardSignal with the well-known
        `wizard.loop.wake.<sid>` topic convention agreed in
        `docs/wizard/AUDIT_DAB_LOOP_TEAMAPP_2026-04-28.md` § 2.2. The
        WizardErasmus loop driver subscribes to this topic during its
        chunked rate-limit sleep and breaks out at the next 5s poll
        boundary.

        Pairs with the WizardErasmus-side
        `python -m ai_wrappers.idle_watch_loop --wake <sid>` CLI: both
        publish to the same topic shape, so PowerShell users get a
        one-word command and Python users get the same effect from
        any shell.

    .PARAMETER SessionId
        Managed-terminal session id of the loop you want to wake. The
        loop driver records its `loop_driver_pwsh_pipe` field on the
        sidecar at startup; that field tells you which pwsh pipe the
        loop is listening on. Pass that pipe name as `-PipeName` if
        the wake should target a specific pwsh; otherwise this cmdlet
        defaults to the current pwsh's own pipe.

    .PARAMETER PipeName
        Optional override — pass the loop driver's `loop_driver_pwsh_pipe`
        when waking a loop that lives in a different pwsh shell.

    .EXAMPLE
        Send-WizardLoopWake -SessionId claude-24624-1777343499545

        Publishes wizard.loop.wake.claude-24624-1777343499545 on the
        current pwsh's pipe. The loop driver attached to that session
        wakes within 5 seconds and re-runs its parser + nudge cycle.

    .EXAMPLE
        Send-WizardLoopWake -SessionId sess-123 -PipeName wizard-pwsh-19636

        Targets a specific pwsh shell — the one identified in the
        managed-terminal sidecar's loop_driver_pwsh_pipe.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $SessionId,

        [string] $PipeName
    )

    $topic = "wizard.loop.wake.$SessionId"
    $payload = @{
        sessionId = $SessionId
        at        = [DateTime]::UtcNow.ToString('o')
    }

    Publish-WizardSignal -Topic $topic -Data $payload -PipeName $PipeName
}
