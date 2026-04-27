# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

function Invoke-AntQuery {
    <#
    .SYNOPSIS
        Send a one-shot Claude API query through the `ant` CLI from
        github.com/anthropics/anthropic-cli, with bounded output and signal-bus audit.

    .DESCRIPTION
        Wraps `ant messages create` with the wizard's Invoke-Bounded so the model's response
        plus any debug noise stays log-on-disk while only the parsed text + usage stats
        return to the caller. Useful as a building block when a hook or skill needs to call
        Claude programmatically without going through the Claude Code TUI (e.g. for
        reformatting build errors, summarising long logs, or verifying a hypothesis).

        Locates the binary via (in order): -AntPath, $env:WIZARD_ANT_PATH, `Get-Command ant`.
        Throws clearly if none resolve. The API key is sourced by the binary itself
        (ANTHROPIC_API_KEY env var or stored credential).

    .PARAMETER Prompt
        The user message text. Mandatory.

    .PARAMETER Model
        Claude model id. Default: claude-sonnet-4-6.

    .PARAMETER MaxTokens
        Cap on the response. Default: 1024.

    .PARAMETER System
        Optional system prompt.

    .PARAMETER AntPath
        Override the binary path.

    .PARAMETER TimeoutSec
        Hard kill if `ant` runs past this. Default: 60s.

    .PARAMETER Quiet
        Suppress the head/tail console echo from Invoke-Bounded.

    .EXAMPLE
        Invoke-AntQuery -Prompt "Summarise this stack trace in one line: $tail" -MaxTokens 200
    #>
    [CmdletBinding()]
    [OutputType('WizardAntResponse', 'WizardBoundedResult')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Prompt,

        [string] $Model = 'claude-sonnet-4-6',
        [int] $MaxTokens = 1024,
        [string] $System,
        [string] $AntPath,
        [int] $TimeoutSec = 60,
        [switch] $Quiet
    )

    if (-not $AntPath) {
        $AntPath = $env:WIZARD_ANT_PATH
        if (-not $AntPath) {
            $cmd = Get-Command ant -ErrorAction SilentlyContinue
            if ($cmd) { $AntPath = $cmd.Source }
        }
    }
    if (-not $AntPath -or -not (Test-Path -LiteralPath $AntPath)) {
        throw "Invoke-AntQuery: ant binary not found. Install with `go install github.com/anthropics/anthropic-cli/cmd/ant@latest`, or set `$env:WIZARD_ANT_PATH`. Resolved candidate: '$AntPath'."
    }

    # Ant accepts the message envelope as inline JSON. We build it as a hashtable and
    # ConvertTo-Json so the quoting survives PowerShell -> native-exe arg passing.
    $messageObj = @{
        role    = 'user'
        content = @(@{ type = 'text'; text = $Prompt })
    }
    $messageJson = $messageObj | ConvertTo-Json -Compress -Depth 6

    $argList = @(
        'messages', 'create',
        '--max-tokens', $MaxTokens.ToString(),
        '--model', $Model,
        '--message', $messageJson,
        '--format', 'json'
    )
    if ($System) { $argList += @('--system', $System) }

    # Audit: publish a wizard.ant.query signal (best-effort; never fails the call).
    try {
        Publish-WizardSignal -Topic 'wizard.ant.query' -Data @{
            model      = $Model
            promptHead = ($Prompt.Substring(0, [Math]::Min(120, $Prompt.Length)))
            maxTokens  = $MaxTokens
            ts         = (Get-Date).ToUniversalTime().ToString('o')
        } | Out-Null
    } catch { }

    $bounded = Invoke-Bounded -FilePath $AntPath -ArgumentList $argList -TimeoutSec $TimeoutSec -MaxLines 200 -Quiet:$Quiet

    if ($bounded.ExitCode -ne 0) {
        return $bounded
    }

    # Parse the JSON response. Ant emits one object per --format json invocation.
    $bodyText = ($bounded.Head + "`n" + $bounded.Tail).Trim()
    try {
        $parsed = $bodyText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # Truncated head+tail couldn't be parsed; reach for the full log.
        try {
            $full = Get-Content -LiteralPath $bounded.LogPath -Raw
            $parsed = $full | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return $bounded
        }
    }

    $contentText = ''
    if ($parsed.content) {
        $contentText = ($parsed.content |
            Where-Object { $_.type -eq 'text' } |
            ForEach-Object { $_.text }) -join "`n"
    }

    [pscustomobject]@{
        PSTypeName  = 'WizardAntResponse'
        Content     = $contentText
        Model       = $parsed.model
        UsageInput  = ($parsed.usage.input_tokens  | Select-Object -First 1)
        UsageOutput = ($parsed.usage.output_tokens | Select-Object -First 1)
        StopReason  = $parsed.stop_reason
        DurationMs  = [int]$bounded.Duration.TotalMilliseconds
        LogPath     = $bounded.LogPath
    }
}
