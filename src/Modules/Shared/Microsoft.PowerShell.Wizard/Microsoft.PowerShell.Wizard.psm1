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

Export-ModuleMember -Function 'Get-WizardSession', 'Invoke-Bounded', 'Get-WizardLog', 'Publish-WizardSignal', 'Read-WizardSignal', 'Start-MonitoredProcess', 'Invoke-BashCompat'

# Register bash / sh aliases ONLY when the wizard control plane is on. Otherwise leave the
# user's PATH bash.exe alone — these aliases are agent-mode glue, not user-facing reskinning.
if ($env:WIZARD_PWSH_CONTROL -in @('1', 'true', 'True', 'yes')) {
    Set-Alias -Name 'bash' -Value 'Invoke-BashCompat' -Scope Global -Force
    Set-Alias -Name 'sh'   -Value 'Invoke-BashCompat' -Scope Global -Force
}
