@{
GUID="6F8B4D1C-2A3E-4F5B-9C6D-7E8F1A2B3C4D"
Author="Wizard PowerShell"
CompanyName="Microsoft Corporation"
Copyright="Copyright (c) Microsoft Corporation."
ModuleVersion="0.1.0"
CompatiblePSEditions = @("Core")
PowerShellVersion="7.0"
RootModule="Microsoft.PowerShell.Wizard.psm1"
Description="Opt-in agent runtime cmdlets for the wizard_power_shell fork. Active only when WIZARD_PWSH_CONTROL=1."
FunctionsToExport = @("Get-WizardSession", "Invoke-Bounded", "Get-WizardLog", "Publish-WizardSignal", "Read-WizardSignal", "Start-MonitoredProcess", "Invoke-BashCompat", "Find-Code", "Find-Repos", "Find-CodeAcrossRepos", "Get-AIContext", "Get-RepoProfile", "Invoke-RepoBuild", "Invoke-RepoTest", "Update-RepoDigest", "Measure-RepoSearch", "Test-WizardBuildPrereqs", "Use-WizardLock", "Clear-WizardLock")
CmdletsToExport = @()
AliasesToExport = @("bash", "sh")
VariablesToExport = @()
}
