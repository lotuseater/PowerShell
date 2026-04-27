# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function ConvertTo-WizardBashTranslation {
    <#
    .SYNOPSIS
        Translates a small subset of bash idioms to a PowerShell pipeline string.
    .OUTPUTS
        @{ Pipeline = '<ps>'; Unsupported = $true|$false; Reason = '<why>' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $BashCommand)

    # Bail-out detectors — known constructs we don't translate.
    if ($BashCommand -match '<<\s*\w+') {
        return @{ Pipeline = $null; Unsupported = $true; Reason = 'heredoc' }
    }
    if ($BashCommand -match '\bset\s+-[eu]o?\b' -or $BashCommand -match '\bset\s+-o\s+pipefail\b') {
        return @{ Pipeline = $null; Unsupported = $true; Reason = 'set-e_or_pipefail' }
    }
    if ($BashCommand -match '\$\([^)]') {
        return @{ Pipeline = $null; Unsupported = $true; Reason = 'command_substitution' }
    }
    if ($BashCommand -match '`[^`]') {
        return @{ Pipeline = $null; Unsupported = $true; Reason = 'backtick_substitution' }
    }

    # 1) Top-level split on '&&' and '||'. Preserve quoted regions.
    $segments = @()
    $current = [System.Text.StringBuilder]::new()
    $prevOp = $null
    $inSingle = $false
    $inDouble = $false
    $escapeNext = $false
    $i = 0
    while ($i -lt $BashCommand.Length) {
        $ch = $BashCommand[$i]
        if ($escapeNext) {
            [void]$current.Append($ch)
            $escapeNext = $false
            $i++
            continue
        }
        if ($ch -eq '\') {
            $escapeNext = $true
            [void]$current.Append($ch)
            $i++
            continue
        }
        if ((-not $inSingle) -and (-not $inDouble) -and ($i + 1 -lt $BashCommand.Length)) {
            $two = $BashCommand.Substring($i, 2)
            if ($two -eq '&&') {
                $segments += [pscustomobject]@{ Cmd = $current.ToString().Trim(); PrevOp = $prevOp }
                $current = [System.Text.StringBuilder]::new()
                $prevOp = 'AND'
                $i += 2
                continue
            }
            if ($two -eq '||') {
                $segments += [pscustomobject]@{ Cmd = $current.ToString().Trim(); PrevOp = $prevOp }
                $current = [System.Text.StringBuilder]::new()
                $prevOp = 'OR'
                $i += 2
                continue
            }
        }
        if ($ch -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle }
        elseif ($ch -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble }
        [void]$current.Append($ch)
        $i++
    }
    $segments += [pscustomobject]@{ Cmd = $current.ToString().Trim(); PrevOp = $prevOp }

    # 2) Per-segment token translation.
    $translated = @()
    foreach ($seg in $segments) {
        $cmd = $seg.Cmd
        if (-not $cmd) { continue }

        # head -n N
        $cmd = [regex]::Replace($cmd, '(?<![\w-])head\s+-n\s+(\d+)(?!\w)', 'Select-Object -First $1')
        # tail -n N
        $cmd = [regex]::Replace($cmd, '(?<![\w-])tail\s+-n\s+(\d+)(?!\w)', 'Select-Object -Last $1')
        # grep PATTERN  /  grep -E PATTERN  (only when used at the start of a pipe segment)
        $cmd = [regex]::Replace($cmd, '(?<=\||^)\s*grep(?:\s+-E)?\s+(\S+)\s*$', ' Select-String -Pattern $1 ')
        $cmd = [regex]::Replace($cmd, '(?<=\||^)\s*grep(?:\s+-E)?\s+(\S+)(?=\s*\|)', ' Select-String -Pattern $1 ')
        # 2>&1 → *>&1 (merges all streams into success — closest PS analogue)
        $cmd = $cmd -replace '\b2>&1\b', '*>&1'

        # Special case: leading 'cd DIR' segment — wrap in Push/Pop later if it's a chain head.
        $translated += [pscustomobject]@{ Cmd = $cmd.Trim(); PrevOp = $seg.PrevOp }
    }

    # 3) Stitch segments with PS conditional chain semantics.
    $sb = [System.Text.StringBuilder]::new()
    $cdPushDepth = 0
    foreach ($seg in $translated) {
        if (-not $seg.Cmd) { continue }
        # Detect leading 'cd DIR' — convert to Push-Location DIR if followed by &&
        $cdMatch = [regex]::Match($seg.Cmd, '^cd\s+(\S+)$')
        $stmt = $seg.Cmd
        if ($cdMatch.Success) {
            $stmt = "Push-Location $($cdMatch.Groups[1].Value)"
            $cdPushDepth++
        }

        if (-not $seg.PrevOp) {
            [void]$sb.Append($stmt)
        } elseif ($seg.PrevOp -eq 'AND') {
            [void]$sb.Append('; if ($?) { ')
            [void]$sb.Append($stmt)
            [void]$sb.Append(' }')
        } elseif ($seg.PrevOp -eq 'OR') {
            [void]$sb.Append('; if (-not $?) { ')
            [void]$sb.Append($stmt)
            [void]$sb.Append(' }')
        }
    }
    if ($cdPushDepth -gt 0) {
        for ($k = 0; $k -lt $cdPushDepth; $k++) {
            [void]$sb.Append('; Pop-Location')
        }
    }

    return @{ Pipeline = $sb.ToString(); Unsupported = $false; Reason = $null }
}

function Invoke-BashCompat {
    <#
    .SYNOPSIS
        Translate a bash command string to PowerShell and run it. Falls back to bash.exe when
        the input uses unsupported constructs.

    .DESCRIPTION
        Active mainly via the `bash` and `sh` aliases registered when WIZARD_PWSH_CONTROL=1.
        Supported: `&&`, `||`, `;`, `|`, `head -n N`, `tail -n N`, `grep [-E] PATTERN` (pipe
        position), `2>&1`, leading `cd DIR && …`. Anything else publishes `wizard.bashcompat.unsupported`
        and falls through to bash.exe if available.

    .EXAMPLE
        bash -c "echo a && echo b | head -n 1"
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $RawArgs
    )

    if (-not $RawArgs -or $RawArgs.Count -eq 0) {
        throw "Invoke-BashCompat: no arguments. Pass '-c COMMAND' (the wizard alias mimics 'bash -c …')."
    }

    # Strip leading login-shell/no-rcfile flags we don't care about.
    $args = @($RawArgs)
    while ($args.Count -gt 0 -and $args[0] -match '^-(l|i|--login)$') {
        $args = $args[1..($args.Count - 1)]
    }

    # Look for -c; everything after it joined back into the command (bash semantics).
    $cmdString = $null
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ($args[$i] -eq '-c') {
            if ($i + 1 -lt $args.Count) {
                $cmdString = $args[$i + 1]
            }
            break
        }
    }

    if ($null -eq $cmdString) {
        # bash 'script.sh' or interactive — pass through.
        $bashExe = Get-Command bash.exe -ErrorAction SilentlyContinue
        if ($bashExe) { return & $bashExe.Path @RawArgs }
        throw "Invoke-BashCompat: '-c COMMAND' is required and bash.exe is not available."
    }

    $translation = ConvertTo-WizardBashTranslation -BashCommand $cmdString
    if ($translation.Unsupported) {
        try {
            Publish-WizardSignal -Topic 'wizard.bashcompat.unsupported' -Data @{ command = $cmdString; reason = $translation.Reason } | Out-Null
        } catch { }
        $bashExe = Get-Command bash.exe -ErrorAction SilentlyContinue
        if ($bashExe) { return & $bashExe.Path -c $cmdString }
        throw "Invoke-BashCompat: command uses unsupported bash construct ($($translation.Reason)) and bash.exe is not available."
    }

    # Run the translated pipeline. Invoke-Expression is the right tool here — we want this
    # function to behave as if the user typed the translated command directly.
    return Invoke-Expression $translation.Pipeline
}
