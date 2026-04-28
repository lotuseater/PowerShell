# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

. $PSScriptRoot/Get-WizardSession.ps1
. $PSScriptRoot/Get-WizardSessions.ps1
. $PSScriptRoot/Invoke-Bounded.ps1
. $PSScriptRoot/Get-WizardLog.ps1
. $PSScriptRoot/Get-WizardLogs.ps1
. $PSScriptRoot/Send-WizardControlRequest.ps1
. $PSScriptRoot/Publish-WizardSignal.ps1
. $PSScriptRoot/Read-WizardSignal.ps1
. $PSScriptRoot/Send-WizardLoopWake.ps1
. $PSScriptRoot/Connect-WizardPwshSession.ps1
. $PSScriptRoot/Start-WizardManagedTerminal.ps1
. $PSScriptRoot/Start-MonitoredProcess.ps1
. $PSScriptRoot/Invoke-BashCompat.ps1
. $PSScriptRoot/Find-Code.ps1
. $PSScriptRoot/Find-Repos.ps1
. $PSScriptRoot/Find-CodeAcrossRepos.ps1
. $PSScriptRoot/Get-AIContext.ps1
. $PSScriptRoot/Get-RepoProfile.ps1
. $PSScriptRoot/Invoke-RepoBuild.ps1
. $PSScriptRoot/Invoke-RepoTest.ps1
. $PSScriptRoot/Update-RepoDigest.ps1
. $PSScriptRoot/Measure-RepoSearch.ps1
. $PSScriptRoot/Test-WizardBuildPrereqs.ps1
. $PSScriptRoot/Use-WizardLock.ps1
. $PSScriptRoot/Clear-WizardLock.ps1
. $PSScriptRoot/Set-ClaudeTrust.ps1
. $PSScriptRoot/Invoke-WizardHook.ps1
. $PSScriptRoot/Invoke-AntQuery.ps1
. $PSScriptRoot/Initialize-WizardHookHost.ps1
. $PSScriptRoot/Build-FirstMovesCorpus.ps1
. $PSScriptRoot/Get-WizardEmbedService.ps1
. $PSScriptRoot/Stop-WizardEmbedService.ps1
. $PSScriptRoot/Get-WizardFirstMovesStats.ps1

Export-ModuleMember -Function 'Get-WizardSession', 'Get-WizardSessions', 'Invoke-Bounded', 'Get-WizardLog', 'Get-WizardLogs', 'Publish-WizardSignal', 'Read-WizardSignal', 'Send-WizardLoopWake', 'Connect-WizardPwshSession', 'Start-WizardManagedTerminal', 'Start-MonitoredProcess', 'Invoke-BashCompat', 'Find-Code', 'Find-Repos', 'Find-CodeAcrossRepos', 'Get-AIContext', 'Get-RepoProfile', 'Invoke-RepoBuild', 'Invoke-RepoTest', 'Update-RepoDigest', 'Measure-RepoSearch', 'Test-WizardBuildPrereqs', 'Use-WizardLock', 'Clear-WizardLock', 'Set-ClaudeTrust', 'Invoke-WizardHook', 'Invoke-AntQuery', 'Initialize-WizardHookHost', 'Build-FirstMovesCorpus', 'Get-WizardEmbedService', 'Stop-WizardEmbedService', 'Get-WizardFirstMovesStats'

# Register bash / sh aliases ONLY when the wizard control plane is on. Otherwise leave the
# user's PATH bash.exe alone — these aliases are agent-mode glue, not user-facing reskinning.
if ($env:WIZARD_PWSH_CONTROL -in @('1', 'true', 'True', 'yes')) {
    Set-Alias -Name 'bash' -Value 'Invoke-BashCompat' -Scope Global -Force
    Set-Alias -Name 'sh'   -Value 'Invoke-BashCompat' -Scope Global -Force
}

# Wizard build identity. Adds $PSVersionTable['WizardBuild'] = '<config>-<utc-date>' so
# `$PSVersionTable.WizardBuild` and `$PSVersionTable | Format-Table` both surface the build's
# provenance. Configuration is parsed from the deployed pwsh.exe path (a `\Release\` or
# `\Debug\` segment); date is the pwsh.exe LastWriteTime in UTC. Always runs (independent
# of WIZARD_PWSH_CONTROL) so even non-controlled launches show "wizard" if they're using
# this module — that's the whole point: distinguish from upstream PowerShell at a glance.
$wizardConfig = 'unknown'
$wizardDate   = $null
try {
    $pwshPath = (Get-Process -Id $PID).Path
    if ($pwshPath -match '[\\/](Release|Debug)[\\/]') {
        $wizardConfig = $Matches[1]
    }
    # Take the freshest mtime across the binary AND this module's psm1, so module-only
    # updates bump the version too (a Release build only reaches us if pwsh.exe is rebuilt;
    # but cmdlet additions ship via the build glob without touching the binary).
    $candidates = @()
    if ($pwshPath -and (Test-Path -LiteralPath $pwshPath)) {
        $candidates += (Get-Item -LiteralPath $pwshPath).LastWriteTimeUtc
    }
    $myPsm1 = Join-Path -Path $PSScriptRoot -ChildPath 'Microsoft.PowerShell.Wizard.psm1'
    if (Test-Path -LiteralPath $myPsm1) {
        $candidates += (Get-Item -LiteralPath $myPsm1).LastWriteTimeUtc
    }
    if ($candidates.Count -gt 0) {
        $wizardDate = ($candidates | Sort-Object -Descending | Select-Object -First 1).ToString('yyyy-MM-ddTHH:mm') + 'Z'
    }
} catch { }

if ($null -ne $PSVersionTable -and -not $PSVersionTable.ContainsKey('WizardBuild')) {
    $PSVersionTable['WizardBuild'] = if ($wizardDate) { "$wizardConfig $wizardDate" } else { $wizardConfig }
}

# One-line banner only when stdin is a real terminal — agent-driven sessions skip this so
# they don't get an extra noise line on every prompt-submit. Coloured if host supports it.
if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    $banner = "Wizard PowerShell — $wizardConfig build $wizardDate (WIZARD_PWSH_CONTROL=$($env:WIZARD_PWSH_CONTROL))"
    try { Write-Host $banner -ForegroundColor DarkCyan } catch { Write-Host $banner }
}

# First-moves embedding daemon auto-warm. Mirror of the SessionStart hook in
# Wizard_Erasmus's Claude Code config so that Codex sessions (and any wizard
# pwsh shell) get a warm daemon too. Skip when WIZARD_FIRST_MOVES_EMBED=0 or
# WIZARD_FIRST_MOVES=0. Fire-and-forget — model load is 5-30s but happens in
# a fully detached child while the user reads the banner.
$wizFirstMoves      = ($env:WIZARD_FIRST_MOVES + '').ToLower()
$wizFirstMovesEmbed = ($env:WIZARD_FIRST_MOVES_EMBED + '').ToLower()
if ($wizFirstMoves -notin @('0','false','no','off') -and
    $wizFirstMovesEmbed -notin @('0','false','no','off')) {
    try {
        $wizardRepo = Join-Path $env:USERPROFILE 'Documents\GitHub\Wizard_Erasmus'
        $client     = Join-Path $wizardRepo 'src\mcp\embed_client.py'
        if (Test-Path -LiteralPath $client) {
            $py = if (Get-Command 'py' -ErrorAction SilentlyContinue) { @('py','-3.14') } else { @('python') }
            $pingResult = & $py[0] $py[1..($py.Length - 1)] $client ping 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $pingResult) {
                # Daemon isn't running — detach-spawn it without blocking.
                $service = Join-Path $wizardRepo 'src\mcp\embed_service.py'
                if (Test-Path -LiteralPath $service) {
                    $proc = Start-Process -FilePath $py[0] `
                        -ArgumentList ($py[1..($py.Length - 1)] + @($service)) `
                        -WindowStyle Hidden -PassThru `
                        -ErrorAction SilentlyContinue
                    # Don't wait on it — the daemon writes its discovery file
                    # when the model finishes loading, and first_moves_hook
                    # will pick it up on the next user turn.
                }
            }
        }
    } catch { }
}
