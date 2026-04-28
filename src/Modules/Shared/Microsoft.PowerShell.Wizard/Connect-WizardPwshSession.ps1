# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Connect-WizardPwshSession {
    <#
    .SYNOPSIS
        Resolve a wizard PowerShell session into a reusable handle.

    .DESCRIPTION
        Sugar on top of `Get-WizardSessions` and the `WIZARD_PWSH_-
        CONTROL_PIPE` env var. Returns a `WizardSessionHandle` that
        carries the resolved `PipeName`, `Pid`, `Cwd`, and a built-in
        `Send` script-method so callers can issue verbs without
        passing `-PipeName` every time.

        Resolution order:
        1. Explicit `-Pid` parameter — looks up the session in
           `Get-WizardSessions` (or `-IncludeStale` for forensics).
        2. Explicit `-PipeName` parameter — used verbatim.
        3. Explicit `-CwdMatch` regex — picks the newest live wizard
           pwsh whose Cwd matches.
        4. Falls back to `$env:WIZARD_PWSH_CONTROL_PIPE` (this
           process's own pipe, when WIZARD_PWSH_CONTROL=1).

        Audit doc `docs/wizard/AUDIT_DAB_LOOP_TEAMAPP_2026-04-28.md`
        §1.3 calls this out as a planned cmdlet — landed 2026-04-29
        as part of the loop revision-3 cleanup.

    .EXAMPLE
        $h = Connect-WizardPwshSession -Pid 19636
        $h.Send(@{ command = 'status.extended' })

    .EXAMPLE
        $h = Connect-WizardPwshSession -CwdMatch 'Wizard_Erasmus'
        $h.Read(60)         # last 60 lines from the console buffer
        $h.Write('go on')   # focus-free input via WriteConsoleInput
        $h.Wake('sess-id')  # publish wizard.loop.wake.<sid>
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByEnv')]
    [OutputType('WizardSessionHandle')]
    param(
        [Parameter(ParameterSetName = 'ByPid', Mandatory)]
        [int] $Pid,

        [Parameter(ParameterSetName = 'ByPipe', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PipeName,

        [Parameter(ParameterSetName = 'ByCwd', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CwdMatch,

        [switch] $IncludeStale
    )

    $resolvedPid = 0
    $resolvedPipe = ''
    $resolvedCwd = ''
    $resolvedExe = ''
    $sourceEntry = $null

    switch ($PSCmdlet.ParameterSetName) {
        'ByPid' {
            $sessions = Get-WizardSessions -All -IncludeStale:$IncludeStale
            $sourceEntry = $sessions | Where-Object { [int]$_.Pid -eq $Pid } | Select-Object -First 1
            if (-not $sourceEntry) {
                throw "No wizard pwsh session found for PID $Pid (try -IncludeStale)."
            }
            $resolvedPid = $Pid
            $resolvedPipe = [string]$sourceEntry.PipeName
            $resolvedCwd = [string]$sourceEntry.Cwd
            $resolvedExe = [string]$sourceEntry.Executable
        }
        'ByPipe' {
            $resolvedPipe = $PipeName
            $sessions = Get-WizardSessions -All -IncludeStale:$IncludeStale
            $sourceEntry = $sessions | Where-Object { [string]$_.PipeName -eq $PipeName } | Select-Object -First 1
            if ($sourceEntry) {
                $resolvedPid = [int]$sourceEntry.Pid
                $resolvedCwd = [string]$sourceEntry.Cwd
                $resolvedExe = [string]$sourceEntry.Executable
            }
        }
        'ByCwd' {
            $sessions = Get-WizardSessions -All
            $sourceEntry = $sessions | Where-Object { [string]$_.Cwd -match $CwdMatch } | Select-Object -First 1
            if (-not $sourceEntry) {
                throw "No live wizard pwsh session matched Cwd regex '$CwdMatch'."
            }
            $resolvedPid = [int]$sourceEntry.Pid
            $resolvedPipe = [string]$sourceEntry.PipeName
            $resolvedCwd = [string]$sourceEntry.Cwd
            $resolvedExe = [string]$sourceEntry.Executable
        }
        'ByEnv' {
            $envPipe = [string]$env:WIZARD_PWSH_CONTROL_PIPE
            if (-not $envPipe) {
                throw "Set WIZARD_PWSH_CONTROL_PIPE or pass -Pid / -PipeName / -CwdMatch."
            }
            $resolvedPipe = $envPipe
            $resolvedPid = $PID
            $resolvedCwd = (Get-Location).Path
        }
    }

    $handle = [pscustomobject]@{
        PSTypeName  = 'WizardSessionHandle'
        Pid         = $resolvedPid
        PipeName    = $resolvedPipe
        Cwd         = $resolvedCwd
        Executable  = $resolvedExe
        Source      = $sourceEntry
    }

    # Method: send an arbitrary control-pipe payload through this handle.
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Send -Value {
        param([hashtable] $Payload)
        if (-not $Payload) { throw 'Send: $Payload is required.' }
        Send-WizardControlRequest -PipeName $this.PipeName -Payload $Payload
    } -Force

    # Convenience wrappers — match the Python WizardPwshClient surface.
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Status -Value {
        $this.Send(@{ command = 'status' })
    } -Force

    Add-Member -InputObject $handle -MemberType ScriptMethod -Name StatusExtended -Value {
        $this.Send(@{ command = 'status.extended' })
    } -Force

    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Read -Value {
        param([int] $MaxLines = 120)
        $this.Send(@{ command = 'read'; maxLines = $MaxLines })
    } -Force

    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Write -Value {
        param([string] $Text, [bool] $Submit = $true)
        $this.Send(@{ command = 'write'; text = $Text; submit = $Submit })
    } -Force

    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Interrupt -Value {
        $this.Send(@{ command = 'interrupt' })
    } -Force

    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Publish -Value {
        param([string] $Topic, $Data, [int] $Ring = 256)
        $this.Send(@{ command = 'signal.publish'; topic = $Topic; data = $Data; ring = $Ring })
    } -Force

    Add-Member -InputObject $handle -MemberType ScriptMethod -Name ReadSignal -Value {
        param([string] $Topic, [int] $Since = 0, [int] $Limit = 64)
        $this.Send(@{ command = 'signal.subscribe'; topic = $Topic; since = $Since; limit = $Limit })
    } -Force

    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Wake -Value {
        param([string] $SessionId)
        if (-not $SessionId) { throw 'Wake: $SessionId is required.' }
        $this.Publish("wizard.loop.wake.$SessionId", @{
            sessionId = $SessionId
            at        = [DateTime]::UtcNow.ToString('o')
        })
    } -Force

    return $handle
}
