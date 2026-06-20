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
        wt.exe discovery prefers explicit WIZARD_WT_EXE, then a built
        WIZARD_TERMINAL_REPO checkout, then the standard
        Documents\GitHub\terminal checkout, before PATH/WindowsApps.

        Audit doc `docs/wizard/AUDIT_DAB_LOOP_TEAMAPP_2026-04-28.md`
        §4.2 calls this out as a planned cmdlet replacing
        `ai_wrappers/idle_watch_loop.py:_launch_pwsh_for_loop`.
        Ships additive 2026-04-29 — the WizardErasmus consumer is
        gated by `WIZARD_USE_MANAGED_TERMINAL_CMDLET=0` (default on)
        so a kill-switch is available if the cmdlet path misbehaves.

    .PARAMETER Provider
        `codex`, `claude`, `gemini`, or `teamapp`. Stamped on the spawned shell's
        `WIZARD_MANAGED_TERMINAL_PROVIDER` env var.

    .PARAMETER ChildArgs
        Argv passed verbatim to the agent CLI inside the spawned
        shell. The cmdlet does NOT filter or rewrite — caller is
        responsible for compatibility.

    .PARAMETER CommandScript
        Raw PowerShell script to run inside the managed terminal instead
        of invoking the provider CLI. Used by Team App visible terminal
        mirrors and other Wizard-controlled utility tabs that still need
        the same terminal host, sidecar, control, color, and analysis-cache
        behavior as agent loop tabs.

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
        - Pid: launcher PID (wt.exe or pwsh.exe)
        - ShellPid: spawned Wizard PowerShell PID when its control
          session can be resolved
        - Pipe: predicted wizard-pwsh control-pipe name (the spawned
          shell's `WIZARD_PWSH_CONTROL_PIPE`); empty when WIZARD_-
          PWSH_CONTROL didn't activate
        - Title: window title used at spawn
        - SessionId: echoed back for chaining
        - Channel: 'wt_new_tab' or 'new_console'
        - TerminalDisplayHost: 'windows_terminal' or 'classic_console'
        - WtExe/WtWindowTarget/WtTabTitle/WtTabColor/WtCommandLine: populated for
          Windows Terminal tab launches
        - PSModuleAnalysisCachePath/AnalysisCacheIsolated: the effective
          per-session module analysis cache used by the child shell

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
        [ValidateSet('codex', 'claude', 'gemini', 'teamapp')]
        [string] $Provider,

        [string[]] $ChildArgs = @(),

        [string] $CommandScript,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SessionId,

        [string] $Title,

        [string] $TabColor,

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
    $invoke = if (-not [string]::IsNullOrWhiteSpace($CommandScript)) {
        $CommandScript
    } elseif ($quotedArgs) {
        "& $Provider @($quotedArgs)"
    } else {
        "& $Provider"
    }

    $launchEnv = @{
        WIZARD_PWSH_CONTROL = '1'
        WIZARD_MANAGED_TERMINAL_SESSION_ID = $SessionId
        WIZARD_MANAGED_TERMINAL_PROVIDER = $Provider
    }
    if ($Env) {
        foreach ($key in $Env.Keys) {
            $launchEnv[[string]$key] = [string]$Env[$key]
        }
    }

    function ConvertTo-WizardSafeFileStem {
        param([Parameter(Mandatory)][string] $Value)

        $builder = [System.Text.StringBuilder]::new()
        foreach ($ch in $Value.ToCharArray()) {
            if ([char]::IsLetterOrDigit($ch) -or $ch -eq '-' -or $ch -eq '_') {
                [void] $builder.Append($ch)
            } else {
                [void] $builder.Append('-')
            }
        }

        $safe = $builder.ToString().Trim('-')
        if ($safe.Length -eq 0) {
            return 'session'
        }
        if ($safe.Length -gt 96) {
            return $safe.Substring(0, 96)
        }
        return $safe
    }

    function Resolve-WizardModuleAnalysisCache {
        param(
            [Parameter(Mandatory)][string] $EffectiveSessionId,
            [Parameter(Mandatory)][hashtable] $EffectiveEnv
        )

        $source = 'default'
        $path = ''
        if ($EffectiveEnv.ContainsKey('PSModuleAnalysisCachePath') -and [string]$EffectiveEnv['PSModuleAnalysisCachePath']) {
            $source = 'env'
            $path = [string]$EffectiveEnv['PSModuleAnalysisCachePath']
        } else {
            $inherited = [Environment]::GetEnvironmentVariable('PSModuleAnalysisCachePath', 'Process')
            if (-not [string]::IsNullOrWhiteSpace($inherited)) {
                $source = 'process'
                $path = $inherited
            }
        }

        if ([string]::IsNullOrWhiteSpace($path)) {
            $base = if ($env:LOCALAPPDATA) {
                $env:LOCALAPPDATA
            } elseif ($env:TEMP) {
                $env:TEMP
            } else {
                [System.IO.Path]::GetTempPath()
            }
            $path = Join-Path (Join-Path $base 'WizardPowerShell') ('ModuleAnalysisCache\' + (ConvertTo-WizardSafeFileStem $EffectiveSessionId) + '.cache')
        }

        $expanded = [Environment]::ExpandEnvironmentVariables($path)
        try {
            $parent = Split-Path -Path $expanded -Parent
            if ($parent) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
        } catch {
        }

        [pscustomobject]@{
            Path = $expanded
            Source = $source
            Isolated = $source -eq 'default'
        }
    }

    function Resolve-WizardTabColor {
        param(
            [string] $ExplicitColor,
            [Parameter(Mandatory)][string] $Seed
        )

        $trimmed = ([string]$ExplicitColor).Trim()
        if ($trimmed) {
            if ($trimmed -notmatch '^#[0-9A-Fa-f]{6}$') {
                throw "TabColor must be a #RRGGBB value."
            }
            return $trimmed.ToUpperInvariant()
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash($bytes)
        } finally {
            $sha.Dispose()
        }

        $hue = [BitConverter]::ToUInt16($hash, 0) % 360
        $saturation = 0.58 + (($hash[2] % 18) / 100.0)
        $lightness = 0.38 + (($hash[3] % 14) / 100.0)
        $chroma = (1.0 - [Math]::Abs((2.0 * $lightness) - 1.0)) * $saturation
        $hPrime = $hue / 60.0
        $x = $chroma * (1.0 - [Math]::Abs(($hPrime % 2.0) - 1.0))

        $red1 = 0.0
        $green1 = 0.0
        $blue1 = 0.0
        if ($hPrime -lt 1.0) {
            $red1 = $chroma; $green1 = $x
        } elseif ($hPrime -lt 2.0) {
            $red1 = $x; $green1 = $chroma
        } elseif ($hPrime -lt 3.0) {
            $green1 = $chroma; $blue1 = $x
        } elseif ($hPrime -lt 4.0) {
            $green1 = $x; $blue1 = $chroma
        } elseif ($hPrime -lt 5.0) {
            $red1 = $x; $blue1 = $chroma
        } else {
            $red1 = $chroma; $blue1 = $x
        }

        $match = $lightness - ($chroma / 2.0)
        $red = [int][Math]::Round(($red1 + $match) * 255)
        $green = [int][Math]::Round(($green1 + $match) * 255)
        $blue = [int][Math]::Round(($blue1 + $match) * 255)
        return ('#{0:X2}{1:X2}{2:X2}' -f $red, $green, $blue)
    }

    $analysisCache = Resolve-WizardModuleAnalysisCache -EffectiveSessionId $SessionId -EffectiveEnv $launchEnv
    $launchEnv['PSModuleAnalysisCachePath'] = $analysisCache.Path
    if (-not $launchEnv.ContainsKey('WIZARD_PWSH_CONTROL_PIPE') -or
        [string]::IsNullOrWhiteSpace([string]$launchEnv['WIZARD_PWSH_CONTROL_PIPE'])) {
        $stamp = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        $launchEnv['WIZARD_PWSH_CONTROL_PIPE'] =
            ConvertTo-WizardSafeFileStem "wizard-$Provider-$SessionId-$PID-$stamp"
    }
    $effectiveTabColor = Resolve-WizardTabColor -ExplicitColor $TabColor -Seed "$Provider`n$SessionId`n$Title"

    $bootstrap = @(
        "`$Host.UI.RawUI.WindowTitle = $(& $singleQuote $Title)"
        "`$env:WIZARD_MANAGED_TERMINAL_SESSION_ID = $(& $singleQuote $SessionId)"
        "`$env:WIZARD_MANAGED_TERMINAL_PROVIDER = $(& $singleQuote $Provider)"
        "`$env:WIZARD_PWSH_CONTROL = '1'"
        "`$env:WIZARD_PWSH_CONTROL_PIPE = $(& $singleQuote ([string]$launchEnv['WIZARD_PWSH_CONTROL_PIPE']))"
        "`$env:PSModuleAnalysisCachePath = $(& $singleQuote $analysisCache.Path)"
        "Set-Location -LiteralPath $(& $singleQuote $Cwd)"
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

    function Test-WizardPwshExecutable {
        param([Parameter(Mandatory)][string] $Path)

        $expanded = [Environment]::ExpandEnvironmentVariables($Path)
        try {
            $full = [System.IO.Path]::GetFullPath($expanded)
        } catch {
            return $false
        }

        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            return $false
        }

        $allowNonWizard = [string] $env:WIZARD_ALLOW_NON_WIZARD_PWSH
        if ($allowNonWizard -in @('1', 'true', 'True', 'yes', 'on')) {
            return $true
        }

        $userBin = if ($env:USERPROFILE) {
            [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'bin\pwsh.exe'))
        } else {
            ''
        }
        if ($userBin -and [string]::Equals($full, $userBin, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        $repoRoot = if ($env:USERPROFILE) {
            [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE 'Documents\GitHub\PowerShell'))
        } else {
            ''
        }
        return (
            $repoRoot -and
            $full.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([System.IO.Path]::GetFileName($full), 'pwsh.exe', [System.StringComparison]::OrdinalIgnoreCase)
        )
    }

    function Resolve-WizardPwshExecutable {
        $candidates = New-Object System.Collections.Generic.List[string]
        if ($PwshExe) {
            [void] $candidates.Add($PwshExe)
        }
        if ($env:WIZARD_PWSH_EXE) {
            [void] $candidates.Add($env:WIZARD_PWSH_EXE)
        }
        if ($env:USERPROFILE) {
            [void] $candidates.Add((Join-Path $env:USERPROFILE 'Documents\GitHub\PowerShell\src\powershell-win-core\bin\Release\net11.0\win7-x64\publish\pwsh.exe'))
            [void] $candidates.Add((Join-Path $env:USERPROFILE 'Documents\GitHub\PowerShell\src\powershell-win-core\bin\Debug\net11.0\win7-x64\publish\pwsh.exe'))
            [void] $candidates.Add((Join-Path $env:USERPROFILE 'bin\pwsh.exe'))
        }

        foreach ($candidate in $candidates) {
            if (-not $candidate) {
                continue
            }
            $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
            if ((Split-Path -Path $expanded -Parent) -and -not (Test-Path -LiteralPath $expanded -PathType Leaf)) {
                continue
            }
            if (Test-WizardPwshExecutable -Path $expanded) {
                return [System.IO.Path]::GetFullPath($expanded)
            }
            throw "Refusing to spawn non-Wizard PowerShell for managed loop target: $expanded"
        }

        throw "Wizard PowerShell executable not found. Set WIZARD_PWSH_EXE to the wizard_power_shell pwsh.exe."
    }

    $pwshExe = Resolve-WizardPwshExecutable

    function Resolve-WizardWtExecutable {
        if ($env:WIZARD_WT_EXE) {
            $explicitWtExe = [Environment]::ExpandEnvironmentVariables($env:WIZARD_WT_EXE)
            if (Test-Path -LiteralPath $explicitWtExe -PathType Leaf) {
                return [System.IO.Path]::GetFullPath($explicitWtExe)
            }
            throw "WIZARD_WT_EXE does not point to an existing wt.exe: $explicitWtExe"
        }

        $terminalRoots = [System.Collections.Generic.List[string]]::new()
        if ($env:WIZARD_TERMINAL_REPO) {
            [void] $terminalRoots.Add([Environment]::ExpandEnvironmentVariables($env:WIZARD_TERMINAL_REPO))
        } elseif ($env:USERPROFILE) {
            [void] $terminalRoots.Add((Join-Path $env:USERPROFILE 'Documents\GitHub\terminal'))
        }

        $relativeCandidates = @(
            'bin\x64\Release\wt.exe',
            'bin\x64\Debug\wt.exe',
            'bin\x64\Release\wtd.exe',
            'bin\x64\Debug\wtd.exe',
            'bin\Release\wt.exe',
            'bin\Debug\wt.exe'
        )

        foreach ($terminalRoot in $terminalRoots) {
            if (-not $terminalRoot) {
                continue
            }
            foreach ($relativeCandidate in $relativeCandidates) {
                $candidate = Join-Path $terminalRoot $relativeCandidate
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return [System.IO.Path]::GetFullPath($candidate)
                }
            }
        }

        $pathWtExe = (Get-Command wt.exe -ErrorAction SilentlyContinue)?.Source
        if ($pathWtExe) {
            return $pathWtExe
        }

        if ($env:LOCALAPPDATA) {
            $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }

        return ''
    }

    $wtExe = Resolve-WizardWtExecutable

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

    function Start-WizardProcessWithEnvironment {
        param(
            [Parameter(Mandatory)]
            [string] $FilePath,

            [Parameter(Mandatory)]
            [string] $ArgumentList,

            [Parameter(Mandatory)]
            [hashtable] $Environment,

            [string] $WorkingDirectory,

            [switch] $NormalWindow
        )

        $previous = @{}
        try {
            foreach ($key in $Environment.Keys) {
                $name = [string] $key
                $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, [string] $Environment[$key], 'Process')
            }
            $startArgs = @{
                FilePath = $FilePath
                ArgumentList = $ArgumentList
                PassThru = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
                $startArgs['WorkingDirectory'] = $WorkingDirectory
            }
            if ($NormalWindow) {
                $startArgs['WindowStyle'] = 'Normal'
            }
            return Start-Process @startArgs
        } finally {
            foreach ($key in $Environment.Keys) {
                $name = [string] $key
                [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
            }
        }
    }

    function Resolve-WizardSpawnedPowerShellSession {
        param(
            [string] $PipeName,
            [int] $TimeoutMs = 3500
        )

        if ([string]::IsNullOrWhiteSpace($PipeName)) {
            return $null
        }

        $sessionRoot = Join-Path -Path ([Environment]::GetFolderPath('LocalApplicationData')) -ChildPath 'WizardPowerShell\sessions'
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        do {
            if (Test-Path -LiteralPath $sessionRoot) {
                $files = @(Get-ChildItem -LiteralPath $sessionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
                foreach ($file in $files) {
                    try {
                        $payload = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 -ErrorAction Stop |
                            ConvertFrom-Json -ErrorAction Stop
                    } catch {
                        continue
                    }

                    if ([string]$payload.pipe -ne $PipeName) {
                        continue
                    }

                    $shellPid = 0
                    if ($payload.pid) {
                        $shellPid = [int]$payload.pid
                    }
                    if ($shellPid -le 0) {
                        continue
                    }
                    $process = Get-Process -Id $shellPid -ErrorAction SilentlyContinue
                    if ($process) {
                        return [pscustomobject]@{
                            Pid = $shellPid
                            PipeName = [string]$payload.pipe
                            SessionFile = $file.FullName
                        }
                    }
                }
            }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)

        return $null
    }

    $usingTab = ($PSCmdlet.ParameterSetName -eq 'Tab') -and $wtExe
    $wtWindowTarget = ''
    $wtCommandLine = ''
    if ($usingTab) {
        $targetWindow = if ($CurrentWindow) { '0' } else { $WtWindow }
        $wtWindowTarget = $targetWindow
        # `wt.exe -w <window> new-tab -d <cwd> --title <title> pwsh -NoLogo -EncodedCommand <b64>`
        $argv = @(
            '-w', $targetWindow,
            'new-tab',
            '-d', $Cwd,
            '--title', $Title,
            '--tabColor', $effectiveTabColor,
            $pwshExe, '-NoLogo', '-EncodedCommand', $encoded
        )
        $wtArgumentString = ConvertTo-WizardNativeArgumentString $argv
        $wtCommandLine = $wtExe + ' ' + $wtArgumentString
        $proc = Start-WizardProcessWithEnvironment `
            -FilePath $wtExe `
            -ArgumentList $wtArgumentString `
            -Environment $launchEnv `
            -WorkingDirectory $Cwd
        $channel = if ($CurrentWindow) { 'wt_current_tab' } else { 'wt_new_tab' }
    } else {
        $argv = @('-NoLogo', '-EncodedCommand', $encoded)
        $proc = Start-WizardProcessWithEnvironment `
            -FilePath $pwshExe `
            -ArgumentList (ConvertTo-WizardNativeArgumentString $argv) `
            -Environment $launchEnv `
            -WorkingDirectory $Cwd `
            -NormalWindow
        $channel = 'new_console'
    }

    # We do not yet know the spawned wizard pwsh pipe (the child shell
    # registers it on startup). Predict the canonical name so callers
    # can wait + connect by name. The actual spawned PID lives under
    # the returned process's tree; WizardErasmus walks descendants via
    # `_candidate_console_pids`.
    $predictedPipe = if ($launchEnv.ContainsKey('WIZARD_PWSH_CONTROL_PIPE')) {
        [string] $launchEnv['WIZARD_PWSH_CONTROL_PIPE']
    } else {
        ''
    }
    $spawnedSession = Resolve-WizardSpawnedPowerShellSession -PipeName $predictedPipe

    return [pscustomobject]@{
        PSTypeName = 'WizardManagedTerminalResult'
        Pid        = [int]$proc.Id
        ShellPid   = if ($spawnedSession) { [int]$spawnedSession.Pid } else { 0 }
        Pipe       = $predictedPipe
        ShellPipe  = if ($spawnedSession) { [string]$spawnedSession.PipeName } else { '' }
        ShellSessionFile = if ($spawnedSession) { [string]$spawnedSession.SessionFile } else { '' }
        Title      = $Title
        SessionId  = $SessionId
        Channel    = $channel
        Provider   = $Provider
        Cwd        = $Cwd
        WtWindow   = if ($usingTab) { if ($CurrentWindow) { '0' } else { $WtWindow } } else { '' }
        WtWindowTarget = $wtWindowTarget
        WtTabTitle = if ($usingTab) { $Title } else { '' }
        WtTabColor = if ($usingTab) { $effectiveTabColor } else { '' }
        WtExe = if ($usingTab) { $wtExe } else { '' }
        WtCommandLine = $wtCommandLine
        TerminalDisplayHost = if ($usingTab) { 'windows_terminal' } else { 'classic_console' }
        WindowTarget = if ($usingTab) { if ($CurrentWindow) { 'current' } else { 'named' } } else { 'new' }
        ShellExecutable = $pwshExe
        ShellIsWizardPwsh = $true
        PSModuleAnalysisCachePath = $analysisCache.Path
        PSModuleAnalysisCachePathSource = $analysisCache.Source
        AnalysisCacheIsolated = [bool]$analysisCache.Isolated
    }
}
