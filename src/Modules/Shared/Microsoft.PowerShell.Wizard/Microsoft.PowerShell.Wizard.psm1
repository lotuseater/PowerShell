# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

. $PSScriptRoot/Get-WizardSession.ps1
. $PSScriptRoot/Invoke-Bounded.ps1
. $PSScriptRoot/Get-WizardLog.ps1
. $PSScriptRoot/Send-WizardControlRequest.ps1
. $PSScriptRoot/Publish-WizardSignal.ps1
. $PSScriptRoot/Read-WizardSignal.ps1
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

Export-ModuleMember -Function 'Get-WizardSession', 'Invoke-Bounded', 'Get-WizardLog', 'Publish-WizardSignal', 'Read-WizardSignal', 'Start-MonitoredProcess', 'Invoke-BashCompat', 'Find-Code', 'Find-Repos', 'Find-CodeAcrossRepos', 'Get-AIContext', 'Get-RepoProfile', 'Invoke-RepoBuild', 'Invoke-RepoTest', 'Update-RepoDigest', 'Measure-RepoSearch', 'Test-WizardBuildPrereqs'

# Register bash / sh aliases ONLY when the wizard control plane is on. Otherwise leave the
# user's PATH bash.exe alone — these aliases are agent-mode glue, not user-facing reskinning.
if ($env:WIZARD_PWSH_CONTROL -in @('1', 'true', 'True', 'yes')) {
    Set-Alias -Name 'bash' -Value 'Invoke-BashCompat' -Scope Global -Force
    Set-Alias -Name 'sh'   -Value 'Invoke-BashCompat' -Scope Global -Force
}
