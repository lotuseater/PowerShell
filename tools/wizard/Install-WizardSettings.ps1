#Requires -Version 7.0
<#
.SYNOPSIS
    Rewrite a Claude Code settings.json so selected hooks route through the warm Python
    hook host (Phase 6) instead of cold-spawning Python on every fire.

.DESCRIPTION
    For a given hook name (matching one of the Wizard_Erasmus hook scripts), this script
    finds entries whose command shell-runs `py -3.14 'path/to/<hook>.py'` and rewrites
    them to call `Invoke-WizardHook -Name <hook>` instead. The original settings.json is
    backed up to `settings.json.bak-<utc>` before any write.

    The new behaviour is gated by the `WIZARD_HOOKS_REWIRED` env var. If that env var is
    `0`, the rewritten hook entries fall through to the original Python invocation, so
    you can disable the rewire without restoring the file.

    Use `-DryRun` to preview the rewrites without writing. Use `-Restore` to undo by
    swapping the most recent backup back into place.

.PARAMETER SettingsPath
    Path to the Claude settings.json. Default: `$HOME\.claude\settings.json`.

.PARAMETER HookName
    Logical hook name to rewire (matches the basename of the Python file without `_hook`).
    Examples: `pretool_cache`, `cognitive_pulse`. Use `-WhatIf` first.

.PARAMETER DryRun
    Print what would change but don't write anything.

.PARAMETER Restore
    Restore the most recent backup. Use this to undo a previous rewire.

.EXAMPLE
    Install-WizardSettings.ps1 -HookName pretool_cache -DryRun

.EXAMPLE
    Install-WizardSettings.ps1 -HookName pretool_cache

    Backs up settings.json, swaps the pretool_cache hook to use the warm host. Set
    $env:WIZARD_HOOKS_REWIRED='0' to fall back to the legacy path.

.EXAMPLE
    Install-WizardSettings.ps1 -Restore
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $SettingsPath = (Join-Path $HOME '.claude\settings.json'),

    [string] $HookName,

    [switch] $DryRun,
    [switch] $Restore
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    throw "Install-WizardSettings: settings.json not found at $SettingsPath"
}

if ($Restore) {
    $backupCandidates = Get-ChildItem -LiteralPath (Split-Path -Parent $SettingsPath) -Filter 'settings.json.bak-*' |
        Sort-Object Name -Descending
    if (-not $backupCandidates) {
        throw "No backups found next to $SettingsPath. Nothing to restore."
    }
    $latest = $backupCandidates[0]
    if ($PSCmdlet.ShouldProcess($SettingsPath, "Restore from $($latest.FullName)")) {
        Copy-Item -LiteralPath $latest.FullName -Destination $SettingsPath -Force
        Write-Host "Restored from $($latest.Name)"
    }
    return
}

if (-not $HookName) {
    throw "Install-WizardSettings: -HookName is required (e.g. 'pretool_cache')."
}

$raw = Get-Content -LiteralPath $SettingsPath -Raw -Encoding utf8
$config = $raw | ConvertFrom-Json -AsHashtable

# The replacement preserves the ORIGINAL command as the fallback so we don't lose info
# about subdirectory hooks (e.g. hooks/pretool_cache_hook.py). Kill switch: if
# WIZARD_HOOKS_REWIRED is set to '0', the original path is invoked unchanged.
function New-Replacement {
    param([string] $OriginalCommand, [string] $HookName)
    $escapedOriginal = $OriginalCommand -replace "'", "''"
    # Two-arm command:
    #   * WIZARD_HOOKS_REWIRED='0'  → run the original cold-spawn unchanged (kill switch).
    #   * default                   → relay to the warm Python child and emit the hook's
    #                                  raw JSON output (the C# layer wraps it in an envelope;
    #                                  we extract `.result` to preserve the original
    #                                  Claude-Code stdin/JSON-stdout hook contract).
    return "if (`$env:WIZARD_HOOKS_REWIRED -eq '0') { `$cmd = '$escapedOriginal'; Invoke-Expression `$cmd } else { try { `$rsp = Invoke-WizardHook -Name $HookName -Payload (`$Input | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue) -ErrorAction Stop; if (`$rsp.status -eq 'ok' -and `$rsp.result) { `$rsp.result | ConvertTo-Json -Depth 10 -Compress } } catch { `$cmd = '$escapedOriginal'; Invoke-Expression `$cmd } }"
}

$matches = @()
function Walk-Hooks {
    param($node, $path)
    if ($node -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $node.Count; $i++) {
            Walk-Hooks -node $node[$i] -path "$path[$i]"
        }
    } elseif ($node -is [hashtable]) {
        foreach ($k in @($node.Keys)) {
            $v = $node[$k]
            if ($k -eq 'command' -and $v -is [string] -and $v -match [regex]::Escape("${HookName}_hook.py")) {
                # Skip if already rewired (idempotent re-run).
                if ($v -match 'Invoke-WizardHook\s+-Name\s+' + [regex]::Escape($HookName) + '\b') {
                    continue
                }
                $script:matches += [pscustomobject]@{
                    Path    = "$path.$k"
                    Old     = $v
                    New     = (New-Replacement -OriginalCommand $v -HookName $HookName)
                    Container = $node
                }
            } else {
                Walk-Hooks -node $v -path "$path.$k"
            }
        }
    }
}

Walk-Hooks -node $config -path 'settings'

if ($matches.Count -eq 0) {
    Write-Warning "No settings.json entries reference '${HookName}_hook.py'. Nothing to rewire."
    return
}

Write-Host "Found $($matches.Count) entries referencing ${HookName}_hook.py:"
foreach ($m in $matches) {
    Write-Host "  $($m.Path)"
    Write-Host "    OLD: $($m.Old)"
    Write-Host "    NEW: $($m.New)"
}

if ($DryRun) {
    Write-Host "DryRun — no changes written."
    return [pscustomobject]@{ Changed = $false; Matches = $matches.Count; Backup = $null }
}

# Backup before write.
$backupPath = "$SettingsPath.bak-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))"
if (-not $PSCmdlet.ShouldProcess($SettingsPath, "Backup to $backupPath and rewire ${HookName}")) {
    return
}

Copy-Item -LiteralPath $SettingsPath -Destination $backupPath -Force

# Apply the rewrites.
foreach ($m in $matches) {
    $m.Container['command'] = $m.New
}

$newJson = $config | ConvertTo-Json -Depth 32
$tmp = "$SettingsPath.tmp-$([Guid]::NewGuid().ToString('N'))"
try {
    Set-Content -LiteralPath $tmp -Value $newJson -Encoding utf8 -NoNewline
    Move-Item -LiteralPath $tmp -Destination $SettingsPath -Force
}
catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    throw
}

Write-Host "Rewired ${HookName}: $($matches.Count) entries swapped. Backup at $backupPath."
Write-Host "Kill switch: set `$env:WIZARD_HOOKS_REWIRED='0' to fall back to the legacy path without restoring."
[pscustomobject]@{ Changed = $true; Matches = $matches.Count; Backup = $backupPath }
