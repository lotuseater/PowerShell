# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Start-WizardManagedTerminal {
    <#
    .SYNOPSIS
        Spawn a wizard-controlled pwsh tab/window running an agent CLI.

    .DESCRIPTION
        Replaces the WizardErasmus hand-rolled base64-encoded
        `pwsh -EncodedCommand …` spawn dance with one cmdlet. Composes
        the launch script natively, sets the WIZARD env vars (so the
        spawned shell registers a control pipe and joins the managed-
        terminal sidecar contract), and invokes either:
        - `wt.exe -w <WtWindow> new-tab -d <Cwd> --title <Title> pwsh ...`
          (default — every loop lands as a tab in the same wt window),
          or
        - `Start-Process pwsh -NoNewWindow:$false ...` with
          CreateNewConsole flag (`-NewWindow` switch — opt-in legacy
          behavior, useful when wt.exe is unavailable).

        Audit doc `docs/wizard/AUDIT_DAB_LOOP_TEAMAPP_2026-04-28.md`
        §4.2 calls this out as a planned cmdlet replacing
        `ai_wrappers/idle_watch_loop.py:_launch_pwsh_for_loop`.
        Ships additive 2026-04-29 — the WizardErasmus consumer is
        gated by `WIZARD_USE_MANAGED_TERMINAL_CMDLET=0` (default on)
        so a kill-switch is available if the cmdlet path misbehaves.

    .PARAMETER Provider
        `codex`, `claude`, or `gemini`. Stamped on the spawned shell's
        `WIZARD_MANAGED_TERMINAL_PROVIDER` env var.

    .PARAMETER ChildArgs
        Argv passed verbatim to the agent CLI inside the spawned
        shell. The cmdlet does NOT filter or rewrite — caller is
        responsible for compatibility.

    .PARAMETER SessionId
        Managed-terminal session id; the spawned shell publishes it
        as `WIZARD_MANAGED_TERMINAL_SESSION_ID` so the WizardErasmus
        sidecar contract can locate the tab later.

    .PARAMETER Title
        Window/tab title. Defaults to a deterministic
        `<Provider> Loop <pid>-<ms>` shape so DAB find-window-by-title
        keeps working.

    .PARAMETER Cwd
        Working directory the agent starts in. Defaults to the caller's
        current location.

    .PARAMETER WtWindow
        Windows Terminal window name to spawn the tab in. Defaults to
        `wizard-loops` so every loop lands as a tab in the same wt
        window. Pass any string to use a different named window.

    .PARAMETER CurrentWindow
        Spawn the tab in the current/most-recent Windows Terminal window
        using `wt.exe -w 0 new-tab`. Intended for loop controller tabs that
        want the controlled agent tab beside them in the same top-level
        terminal window.

    .PARAMETER NewWindow
        Force the legacy `Start-Process pwsh` path (CreateNewConsole)
        instead of `wt.exe new-tab`. Use when wt.exe is unavailable
        or when you explicitly want a separate console window.

    .PARAMETER Env
        Hashtable of additional env vars to set on the spawned shell.
        Caller-supplied keys override the cmdlet's defaults.

    .PARAMETER PwshExe
        PowerShell executable or wrapper used for the spawned terminal.
        When omitted, the cmdlet honors WIZARD_PWSH_EXE before falling
        back to PATH discovery. This keeps callers from accidentally
        launching a stale pwsh found earlier on PATH.

    .OUTPUTS
        WizardManagedTerminalResult with:
        - Pid: launcher PID (wt.exe or pwsh.exe; the actual agent runs
          as a child of this process tree)
        - Pipe: predicted wizard-pwsh control-pipe name (the spawned
          shell's `WIZARD_PWSH_CONTROL_PIPE`); empty when WIZARD_-
          PWSH_CONTROL didn't activate
        - Title: window title used at spawn
        - SessionId: echoed back for chaining
        - Channel: 'wt_new_tab' or 'new_console'

    .EXAMPLE
        $r = Start-WizardManagedTerminal `
            -Provider claude -ChildArgs @('--dangerously-skip-permissions') `
            -SessionId 'claude-loop-1' -Title 'Claude Loop'
        $r.Pid; $r.Channel
    #>
    [CmdletBinding(DefaultParameterSetName = 'Tab')]
    [OutputType('WizardManagedTerminalResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('codex', 'claude', 'gemini')]
        [string] $Provider,

        [Parameter(Mandatory)]
        [string[]] $ChildArgs,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SessionId,

        [string] $Title,
        [string] $Cwd = (Get-Location).Path,

        [Parameter(ParameterSetName = 'Tab')]
        [string] $WtWindow = 'wizard-loops',

        [Parameter(ParameterSetName = 'Tab')]
        [switch] $CurrentWindow,

        [Parameter(ParameterSetName = 'NewWindow')]
        [switch] $NewWindow,

        [string] $PwshExe,

        [hashtable] $Env
    )

    if (-not $Title) {
        $stamp = [int64]((Get-Date).ToUniversalTime().Subtract([datetime]'1970-01-01T00:00:00Z')).TotalMilliseconds
        $Title = "$Provider Loop $PID-$stamp"
    }

    # Compose the per-tab launch script. Mirrors
    # `ai_wrappers/idle_watch_loop.py:_build_pwsh_launch_script`
    # byte-for-byte so the WE side can rely on identical behavior.
    $singleQuote = { param($s) "'" + $s.Replace("'", "''") + "'" }
    $quotedArgs = ($ChildArgs | ForEach-Object { & $singleQuote $_ }) -join ', '
    $invoke = if ($quotedArgs) {
        "& $Provider @($quotedArgs)"
    } else {
        "& $Provider"
    }

    $bootstrap = @(
        "`$Host.UI.RawUI.WindowTitle = $(& $singleQuote $Title)"
        "`$env:WIZARD_MANAGED_TERMINAL_SESSION_ID = $(& $singleQuote $SessionId)"
        "`$env:WIZARD_MANAGED_TERMINAL_PROVIDER = $(& $singleQuote $Provider)"
        "`$env:WIZARD_PWSH_CONTROL = '1'"
    )
    if ($Env) {
        foreach ($key in $Env.Keys) {
            $value = [string]$Env[$key]
            $bootstrap += "Set-Item -LiteralPath $(& $singleQuote ('Env:' + $key)) -Value $(& $singleQuote $value)"
        }
    }
    $bootstrap += $invoke
    $bootstrap += 'exit 0'
    $launchScript = $bootstrap -join '; '

    # PowerShell -EncodedCommand expects UTF-16LE base64.
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($launchScript)
    $encoded = [Convert]::ToBase64String($bytes)

    $pwshExe = $PwshExe
    if (-not $pwshExe) {
        $pwshExe = $env:WIZARD_PWSH_EXE
    }
    if ($pwshExe) {
        $pwshExe = [Environment]::ExpandEnvironmentVariables($pwshExe)
        if ((Split-Path -Path $pwshExe -Parent) -and -not (Test-Path -LiteralPath $pwshExe -PathType Leaf)) {
            throw "pwsh executable not found: $pwshExe"
        }
    }
    if (-not $pwshExe) {
        $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
    }
    if (-not $pwshExe) {
        $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue)?.Source
    }
    if (-not $pwshExe) {
        throw "pwsh not found on PATH; cannot spawn managed terminal."
    }

    $wtExe = (Get-Command wt.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $wtExe -and $env:LOCALAPPDATA) {
        $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $wtExe = $candidate
        }
    }

    function ConvertTo-WizardNativeArgumentString {
        param([string[]] $ArgumentList)

        $quoted = foreach ($arg in $ArgumentList) {
            $value = [string] $arg
            if ($value.Length -gt 0 -and $value -notmatch '[\s"]') {
                $value
                continue
            }

            $builder = [System.Text.StringBuilder]::new()
            [void] $builder.Append('"')
            $backslashes = 0
            foreach ($ch in $value.ToCharArray()) {
                if ($ch -eq '\') {
                    $backslashes++
                    continue
                }
                if ($ch -eq '"') {
                    [void] $builder.Append('\' * (($backslashes * 2) + 1))
                    [void] $builder.Append('"')
                    $backslashes = 0
                    continue
                }
                if ($backslashes -gt 0) {
                    [void] $builder.Append('\' * $backslashes)
                    $backslashes = 0
                }
                [void] $builder.Append($ch)
            }
            if ($backslashes -gt 0) {
                [void] $builder.Append('\' * ($backslashes * 2))
            }
            [void] $builder.Append('"')
            $builder.ToString()
        }

        $quoted -join ' '
    }

    $usingTab = ($PSCmdlet.ParameterSetName -eq 'Tab') -and $wtExe
    if ($usingTab) {
        $targetWindow = if ($CurrentWindow) { '0' } else { $WtWindow }
        # `wt.exe -w <window> new-tab -d <cwd> --title <title> pwsh -NoLogo -EncodedCommand <b64>`
        $argv = @(
            '-w', $targetWindow,
            'new-tab',
            '-d', $Cwd,
            '--title', $Title,
            $pwshExe, '-NoLogo', '-EncodedCommand', $encoded
        )
        $proc = Start-Process -FilePath $wtExe -ArgumentList (ConvertTo-WizardNativeArgumentString $argv) -PassThru
        $channel = if ($CurrentWindow) { 'wt_current_tab' } else { 'wt_new_tab' }
    } else {
        $argv = @('-NoLogo', '-EncodedCommand', $encoded)
        $proc = Start-Process -FilePath $pwshExe -ArgumentList (ConvertTo-WizardNativeArgumentString $argv) -PassThru -WindowStyle Normal
        $channel = 'new_console'
    }

    # We do not yet know the spawned wizard pwsh pipe (the child shell
    # registers it on startup). Predict the canonical name so callers
    # can wait + connect by name. The actual spawned PID lives under
    # the returned process's tree; WizardErasmus walks descendants via
    # `_candidate_console_pids`.
    $predictedPipe = if ($Env -and $Env.ContainsKey('WIZARD_PWSH_CONTROL_PIPE')) {
        [string] $Env['WIZARD_PWSH_CONTROL_PIPE']
    } else {
        ''
    }

    return [pscustomobject]@{
        PSTypeName = 'WizardManagedTerminalResult'
        Pid        = [int]$proc.Id
        Pipe       = $predictedPipe
        Title      = $Title
        SessionId  = $SessionId
        Channel    = $channel
        Provider   = $Provider
        Cwd        = $Cwd
        WtWindow   = if ($usingTab) { if ($CurrentWindow) { '0' } else { $WtWindow } } else { '' }
        WindowTarget = if ($usingTab) { if ($CurrentWindow) { 'current' } else { 'named' } } else { 'new' }
    }
}
