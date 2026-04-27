[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PublishPath = (Join-Path $PSScriptRoot '..\..\src\powershell-win-core\bin\Release\net11.0\win7-x64\publish\pwsh.exe'),
    [string]$BinDir = (Join-Path $env:USERPROFILE 'bin'),
    [string]$ProfileName = 'Wizard PowerShell',
    [string]$ProfileGuid = '{d6f6fc55-56bc-4da6-a12f-9d0f7a4a2195}',
    [switch]$SetPwshShim,
    [switch]$SetWindowsTerminalDefault,
    [switch]$Rollback,
    [string]$RollbackSettingsPath
)

$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-WindowsTerminalSettingsPath {
    $packagePath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    if (Test-Path $packagePath) {
        return $packagePath
    }
    return Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
}

function Backup-File([string]$Path) {
    if (-not (Test-Path $Path)) {
        return $null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$Path.wizard-backup-$stamp"
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    return $backup
}

function Get-CSharpCompiler {
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    throw 'Could not find csc.exe for building the pwsh.exe user shim'
}

function New-PwshExeShim([string]$TargetExe, [string]$OutputPath) {
    $escapedTarget = $TargetExe.Replace('\', '\\').Replace('"', '\"')
    $source = @"
using System;
using System.Diagnostics;
using System.Text;

internal static class Program
{
    private static int Main(string[] args)
    {
        var psi = new ProcessStartInfo();
        psi.FileName = "$escapedTarget";
        psi.Arguments = JoinArguments(args);
        psi.UseShellExecute = false;
        psi.WorkingDirectory = Environment.CurrentDirectory;
        psi.EnvironmentVariables["WIZARD_PWSH_CONTROL"] = "1";
        using (var process = Process.Start(psi))
        {
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static string JoinArguments(string[] args)
    {
        var builder = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0)
            {
                builder.Append(' ');
            }
            AppendQuoted(builder, args[i] ?? string.Empty);
        }
        return builder.ToString();
    }

    private static void AppendQuoted(StringBuilder builder, string value)
    {
        if (value.Length == 0)
        {
            builder.Append("\"\"");
            return;
        }
        bool quote = value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) >= 0;
        if (!quote)
        {
            builder.Append(value);
            return;
        }
        builder.Append('"');
        int backslashes = 0;
        foreach (char ch in value)
        {
            if (ch == '\\')
            {
                backslashes++;
                continue;
            }
            if (ch == '"')
            {
                builder.Append('\\', backslashes * 2 + 1);
                builder.Append('"');
                backslashes = 0;
                continue;
            }
            builder.Append('\\', backslashes);
            builder.Append(ch);
            backslashes = 0;
        }
        builder.Append('\\', backslashes * 2);
        builder.Append('"');
    }
}
"@
    $tempSource = Join-Path ([System.IO.Path]::GetTempPath()) "wizard-pwsh-shim-$PID.cs"
    Set-Content -LiteralPath $tempSource -Value $source -Encoding UTF8
    try {
        $compiler = Get-CSharpCompiler
        & $compiler /nologo /target:exe "/out:$OutputPath" $tempSource
        if ($LASTEXITCODE -ne 0) {
            throw "csc.exe failed with exit code $LASTEXITCODE"
        }
    } finally {
        Remove-Item -LiteralPath $tempSource -Force -ErrorAction SilentlyContinue
    }
}

if ($Rollback) {
    if (-not $RollbackSettingsPath) {
        throw '-Rollback requires -RollbackSettingsPath'
    }
    $settingsPath = Get-WindowsTerminalSettingsPath
    if ($PSCmdlet.ShouldProcess($settingsPath, "restore Windows Terminal settings from $RollbackSettingsPath")) {
        Copy-Item -LiteralPath $RollbackSettingsPath -Destination $settingsPath -Force
    }
    return
}

$publishExe = Resolve-FullPath $PublishPath
if (-not (Test-Path $publishExe)) {
    throw "PowerShell publish executable was not found: $publishExe"
}

$binPath = Resolve-FullPath $BinDir
$shimPath = Join-Path $binPath 'wizard-pwsh.cmd'
$pwshShimPath = Join-Path $binPath 'pwsh.cmd'
$pwshExeShimPath = Join-Path $binPath 'pwsh.exe'

if ($PSCmdlet.ShouldProcess($binPath, 'create user shim directory')) {
    New-Item -ItemType Directory -Path $binPath -Force | Out-Null
}

$shimContent = @"
@echo off
set WIZARD_PWSH_CONTROL=1
"$publishExe" %*
"@

if ($PSCmdlet.ShouldProcess($shimPath, 'write Wizard PowerShell shim')) {
    if (Test-Path $shimPath) {
        Backup-File $shimPath | Out-Null
    }
    Set-Content -LiteralPath $shimPath -Value $shimContent -Encoding ASCII
}

if ($SetPwshShim) {
    if ($PSCmdlet.ShouldProcess($pwshShimPath, 'write pwsh convenience shim')) {
        if (Test-Path $pwshShimPath) {
            Backup-File $pwshShimPath | Out-Null
        }
        Set-Content -LiteralPath $pwshShimPath -Value $shimContent -Encoding ASCII
    }
    if ($PSCmdlet.ShouldProcess($pwshExeShimPath, 'write pwsh executable shim')) {
        if (Test-Path $pwshExeShimPath) {
            Backup-File $pwshExeShimPath | Out-Null
        }
        New-PwshExeShim -TargetExe $publishExe -OutputPath $pwshExeShimPath
    }
}

$settingsBackup = $null
if ($SetWindowsTerminalDefault) {
    $settingsPath = Get-WindowsTerminalSettingsPath
    if (-not (Test-Path $settingsPath)) {
        throw "Windows Terminal settings were not found: $settingsPath"
    }

    $settingsBackup = Backup-File $settingsPath
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if (-not $settings.profiles) {
        $settings | Add-Member -MemberType NoteProperty -Name profiles -Value ([pscustomobject]@{ list = @() })
    }
    if (-not $settings.profiles.list) {
        $settings.profiles | Add-Member -MemberType NoteProperty -Name list -Value @() -Force
    }

    $profiles = @($settings.profiles.list)
    $profile = $profiles | Where-Object { $_.guid -eq $ProfileGuid } | Select-Object -First 1
    if (-not $profile) {
        $profile = [pscustomobject]@{
            guid = $ProfileGuid
            name = $ProfileName
            commandline = $shimPath
            startingDirectory = '%USERPROFILE%'
        }
        $settings.profiles.list = @($profiles + $profile)
    } else {
        $profile.name = $ProfileName
        $profile.commandline = $shimPath
        if (-not $profile.PSObject.Properties['startingDirectory']) {
            $profile | Add-Member -MemberType NoteProperty -Name startingDirectory -Value '%USERPROFILE%'
        }
    }
    $settings.defaultProfile = $ProfileGuid

    if ($PSCmdlet.ShouldProcess($settingsPath, "set Windows Terminal default profile to $ProfileName")) {
        $settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    }
}

[pscustomobject]@{
    status = 'ok'
    publish = $publishExe
    shim = $shimPath
    pwshShim = if ($SetPwshShim) { $pwshShimPath } else { $null }
    pwshExeShim = if ($SetPwshShim) { $pwshExeShimPath } else { $null }
    windowsTerminalSettingsBackup = $settingsBackup
}
