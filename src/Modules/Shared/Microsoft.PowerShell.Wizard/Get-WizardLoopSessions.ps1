# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Get-WizardLoopSessions {
    <#
    .SYNOPSIS
        Enumerate WizardErasmus managed-loop terminal sidecars.
    #>
    [CmdletBinding()]
    [OutputType('WizardLoopSessionEntry')]
    param(
        [string] $SidecarRoot,
        [string] $Provider,
        [switch] $IncludeStale,
        [int] $Top = 20,
        [switch] $All
    )

    if (-not $SidecarRoot) {
        $home = if ($env:WIZARD_MANAGED_TERMINAL_HOME) { $env:WIZARD_MANAGED_TERMINAL_HOME }
            elseif ($env:CODEX_HOME) { $env:CODEX_HOME }
            elseif ($env:CLAUDE_HOME) { $env:CLAUDE_HOME }
            else { Join-Path $HOME '.codex' }
        $SidecarRoot = Join-Path -Path $home -ChildPath 'wizard_sidecars\managed_terminals'
    }

    if (-not (Test-Path -LiteralPath $SidecarRoot)) {
        return
    }

    $livePids = @{}
    try {
        foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
            $livePids[[int]$process.Id] = $true
        }
    } catch { }

    $wantedProvider = ($Provider + '').Trim().ToLowerInvariant()
    $records = [System.Collections.Generic.List[object]]::new()
    $files = @(Get-ChildItem -LiteralPath $SidecarRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTimeUtc -Descending)
    foreach ($file in $files) {
        try {
            $payload = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }

        $providerValue = [string]$payload.provider
        if ($wantedProvider -and $providerValue.ToLowerInvariant() -ne $wantedProvider) {
            continue
        }

        $pid = 0
        if ($payload.process_pid) { $pid = [int]$payload.process_pid }
        $isAlive = $pid -gt 0 -and [bool]$livePids[$pid]
        if (-not $isAlive -and -not $IncludeStale) { continue }

        $entry = [pscustomobject]@{
            PSTypeName        = 'WizardLoopSessionEntry'
            SessionId         = [string]$payload.session_id
            Provider          = $providerValue
            CommandName       = [string]$payload.command_name
            Cwd               = [string]$payload.cwd
            WindowTitle       = [string]$payload.window_title
            Hwnd              = if ($null -ne $payload.hwnd) { [int64]$payload.hwnd } else { $null }
            ProcessPid        = $pid
            ProcessAlive      = $isAlive
            State             = [string]$payload.state
            Transport         = [string]$payload.transport
            LastDeliveryMode  = [string]$payload.last_delivery_mode
            LastTextChangedAt = $payload.last_text_changed_at
            CreatedAt         = $payload.created_at
            UpdatedAt         = $payload.updated_at
            SidecarFile       = $file.FullName
        }
        $records.Add($entry)
        if (-not $All -and $Top -gt 0 -and $records.Count -ge $Top) {
            break
        }
    }

    if ($records.Count -eq 0) { return }
    $sorted = @($records) | Sort-Object -Property UpdatedAt -Descending
    if ($All) { return $sorted }
    if ($Top -gt 0 -and $sorted.Count -gt $Top) { return $sorted | Select-Object -First $Top }
    return $sorted
}
