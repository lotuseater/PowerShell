# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Close-WizardExitedLoopTab {
    <#
    .SYNOPSIS
        Close a managed loop tab only when its transcript proves the process exited.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [int64] $Hwnd,
        [int] $ProcessPid,
        [string] $ManagedSessionId,
        [string] $SessionId,
        [string] $Provider,
        [string] $Project,
        [string] $RequireText = '[process exited with code',
        [string] $WizardRoot = (Join-Path $env:USERPROFILE 'Documents\GitHub\Wizard_Erasmus'),
        [string] $PythonExe = 'python',
        [switch] $DryRun
    )

    $scriptPath = Join-Path -Path $WizardRoot -ChildPath 'scripts\session_handoff.py'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Close-WizardExitedLoopTab: session_handoff.py not found at $scriptPath"
    }

    $args = @($scriptPath, 'close-tab', '--json', '--first', '--require-text', $RequireText, '--confirm-close-tab', '--allow-managed-loop')
    if ($Hwnd) { $args += @('--hwnd', [string]$Hwnd) }
    if ($ProcessPid) { $args += @('--process-pid', [string]$ProcessPid) }
    if ($ManagedSessionId) { $args += @('--managed-session-id', $ManagedSessionId) }
    if ($SessionId) { $args += @('--session-id', $SessionId) }
    if ($Provider) { $args += @('--provider', $Provider) }
    if ($Project) { $args += @('--project', $Project) }
    if ($DryRun) { $args += '--dry-run' }

    $target = if ($ManagedSessionId) { $ManagedSessionId } elseif ($Hwnd) { "hwnd=$Hwnd" } elseif ($ProcessPid) { "pid=$ProcessPid" } else { 'selected loop tab' }
    if (-not $PSCmdlet.ShouldProcess($target, 'close exited Wizard loop tab')) {
        return
    }

    $output = & $PythonExe @args
    if ($LASTEXITCODE -ne 0) {
        throw "Close-WizardExitedLoopTab: session_handoff.py exited with code $LASTEXITCODE. Output: $output"
    }
    $text = ($output -join "`n").Trim()
    if (-not $text) {
        return [pscustomobject]@{ status = 'ok'; output = '' }
    }
    try {
        return $text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ status = 'ok'; output = $text }
    }
}
