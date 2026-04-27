# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Set-ClaudeTrust {
    <#
    .SYNOPSIS
        Pre-mark a folder as trusted in Claude Code's per-user state so the "Trust this folder?"
        prompt never appears for new sessions.

    .DESCRIPTION
        Mutates ~/.claude.json's `projects` map to set `hasTrustDialogAccepted=$true` for the
        given path. Idempotent — re-runs are no-ops once trusted. The reason this matters for
        the wizard fork: WizardErasmus's idle-watch loop has an auto-answerer
        (ai_wrappers/idle_watch_loop.py) that picks the highest-numbered option for any menu
        not specifically recognised. Claude Code's trust prompt has options like
        "1. Yes, proceed" / "2. No, exit" — the auto-answerer picks "2" and the window closes.
        Pre-trusting the folder side-steps the prompt entirely.

    .PARAMETER Path
        Folder to pre-trust. Default: current working directory's resolved path.

    .PARAMETER ClaudeJsonPath
        Override the location of claude.json. Default: $HOME\.claude.json.

    .EXAMPLE
        Set-ClaudeTrust -Path C:\Users\Oleh

        Marks the home folder trusted before any subsequent `claude resume` launch.

    .EXAMPLE
        Find-Repos -Root C:\Users\Oleh\Documents\GitHub | ForEach-Object { Set-ClaudeTrust -Path $_.Path }

        Bulk-trust every repo under your GitHub directory.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string] $Path = (Get-Location).ProviderPath,

        [string] $ClaudeJsonPath
    )

    if (-not $ClaudeJsonPath) {
        $ClaudeJsonPath = Join-Path -Path $HOME -ChildPath '.claude.json'
    }
    if (-not (Test-Path -LiteralPath $ClaudeJsonPath)) {
        throw "Set-ClaudeTrust: $ClaudeJsonPath not found. Has Claude Code been launched at least once?"
    }

    # Claude Code uses forward slashes in the projects key on Windows.
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    $key = $resolved -replace '\\', '/'

    $raw = Get-Content -LiteralPath $ClaudeJsonPath -Raw -Encoding utf8
    $config = $raw | ConvertFrom-Json -AsHashtable
    if (-not $config.ContainsKey('projects')) { $config['projects'] = @{} }

    $alreadyTrusted = $false
    if ($config['projects'].ContainsKey($key)) {
        $existing = $config['projects'][$key]
        if ($existing -is [hashtable] -and $existing['hasTrustDialogAccepted'] -eq $true) {
            $alreadyTrusted = $true
        }
        if ($existing -isnot [hashtable]) {
            $existing = @{}
            $config['projects'][$key] = $existing
        }
        $existing['hasTrustDialogAccepted'] = $true
    } else {
        $config['projects'][$key] = @{
            hasTrustDialogAccepted = $true
            projectOnboardingSeenCount = 1
            allowedTools = @()
            history = @()
            mcpContextUris = @()
            mcpServers = @{}
            enabledMcpjsonServers = @()
            disabledMcpjsonServers = @()
            hasClaudeMdExternalIncludesApproved = $false
            hasClaudeMdExternalIncludesWarningShown = $false
            lastTotalWebSearchRequests = 0
            exampleFiles = @()
            exampleFilesGeneratedAt = 0
        }
    }

    if ($alreadyTrusted -and -not $WhatIfPreference) {
        return [pscustomobject]@{
            PSTypeName     = 'WizardClaudeTrust'
            Path           = $resolved
            Key            = $key
            ClaudeJsonPath = $ClaudeJsonPath
            AlreadyTrusted = $true
            Wrote          = $false
        }
    }

    if ($PSCmdlet.ShouldProcess($ClaudeJsonPath, "Mark $key trusted")) {
        # Preserve formatting as much as possible; ConvertTo-Json with depth 32 handles deep
        # configs. The file is otherwise opaque JSON so reformatting it is harmless.
        $newJson = $config | ConvertTo-Json -Depth 32
        # Atomic write via temp file in the same dir.
        $tmp = "$ClaudeJsonPath.tmp-$([Guid]::NewGuid().ToString('N'))"
        try {
            Set-Content -LiteralPath $tmp -Value $newJson -Encoding utf8 -NoNewline
            Move-Item -LiteralPath $tmp -Destination $ClaudeJsonPath -Force
        } catch {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            throw
        }
    }

    [pscustomobject]@{
        PSTypeName     = 'WizardClaudeTrust'
        Path           = $resolved
        Key            = $key
        ClaudeJsonPath = $ClaudeJsonPath
        AlreadyTrusted = $alreadyTrusted
        Wrote          = $true
    }
}
