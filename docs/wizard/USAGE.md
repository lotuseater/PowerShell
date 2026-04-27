# Wizard PowerShell — Usage

_Branch `wizard_power_shell`. Companion to [`RESEARCH.md`](./RESEARCH.md) and [`PLAN.md`](./PLAN.md)._

This doc is for someone who just installed the wizard fork and wants to know what to run. For why-the-fork-exists, read RESEARCH.md. For the rolling work plan, read PLAN.md.

---

## Activation

Set the env var **before** launching `pwsh.exe`:

```
$env:WIZARD_PWSH_CONTROL = '1'
```

Or use the deployed shim from `tools/wizard/Install-WizardPwsh.ps1` which sets the env var for you.

When active, the host:

- Forces UTF-8 console encodings (no more cp1252 mojibake on non-ASCII paths or build output).
- Sets `$PSNativeCommandUseErrorActionPreference = $true` so failed native exes break pipelines like `set -e`.
- Skips PSReadLine when stdin is redirected (saves startup ms + ANSI noise in agent sessions).
- Starts a named-pipe JSON-RPC server at `\\.\pipe\wizard-pwsh-{PID}` for agent control.
- Pre-loads the `Microsoft.PowerShell.Wizard` module so its cmdlets are available before any hook fires.

When inactive, the host behaves exactly like upstream PowerShell.

---

## Cmdlet reference

### Session

| Cmdlet | What |
| ------ | ---- |
| `Get-WizardSession` | One-line snapshot: PID, pipe name, log dir, `WizardControlEnabled`, `HookHostStatus`, encoding, native-error pref, started time. |

### Token-bounded execution

| Cmdlet | What |
| ------ | ---- |
| `Invoke-Bounded -FilePath <exe> -ArgumentList @(…) -MaxLines 80 -TimeoutSec 120 [-LogTo <path>] [-Quiet] [-MergeStdErr]` | Run a child process, stream full stdout+stderr to a log under `%LOCALAPPDATA%\WizardPowerShell\logs\`, return a `WizardBoundedResult` with `ExitCode`, `Head`, `Tail`, `LogPath`, `TotalLines`, `TruncatedLines`, `Duration`, `KilledByTimeout`. |
| `Get-WizardLog -LogPath <path> -Range head:N\|tail:N\|lines:A-B\|grep:PATTERN` | Fetch a slice of the on-disk log on demand. |

### Signal bus (over the named pipe)

| Cmdlet | What |
| ------ | ---- |
| `Publish-WizardSignal -Topic <name> -Data <object> [-Ring 256]` | Push an event onto a per-topic ring buffer. |
| `Read-WizardSignal -Topic <name> [-Since <seq>] [-Limit 64]` | Read events with seq > Since. |
| `Start-MonitoredProcess -FilePath <exe> -ArgumentList @(…) [-Topic <name>] [-HeartbeatSeconds 2]` | Launch a child detached; publish `process.started` / `process.heartbeat` / `process.exited` events to the topic. |

### Bash compatibility

| Cmdlet | What |
| ------ | ---- |
| `Invoke-BashCompat -c '<command>'` | Translate a small bash subset (`&&`, `\|\|`, `;`, `\|`, `head -n`, `tail -n`, `grep`, `2>&1`, leading `cd DIR && …`) to PowerShell and execute. Falls back to `bash.exe` for anything outside the subset (publishing `wizard.bashcompat.unsupported`). Aliases `bash` and `sh` are registered automatically when `WIZARD_PWSH_CONTROL=1`. |

### Persistent Python hook host (Phase 6)

| Cmdlet | What |
| ------ | ---- |
| `Invoke-WizardHook -Name <hook> [-Payload <object>] [-TimeoutMs 30000]` | JSON-RPC over the local pipe to a warm Python child. The first call lazy-spawns `py -3.14 -m wizard_mcp.hook_host`; subsequent calls reuse the warm process. |

Wiring on the WizardErasmus side: drop `tools/wizard/hook_host_reference.py` into `Wizard_Erasmus/src/mcp/hook_host.py`, register your hook callables in the `HOOKS` dict, and (optionally) point `$env:WIZARD_HOOKHOST_MODULE` at a different module path. Each callable runs inside the warm child — pay the import cost once per shell, not once per hook fire.

The warm child is killed automatically when the host pwsh exits (`WizardControlServer.Dispose()` calls `DisposeHookHost()`).

### Idempotency locks

| Cmdlet | What |
| ------ | ---- |
| `Use-WizardLock -Key <name> [-Note <text>] [-LockRoot <dir>]` | Sentinel-file gate. Returns `$null` if just acquired (first time), or the prior record if already held. Lock files live at `%LOCALAPPDATA%\WizardPowerShell\locks\<key>.lock`. Persistent across restarts. |
| `Clear-WizardLock -Key <name>` | Release the lock. Use to re-arm a one-shot operation. |

Pattern for "do this only once":

```powershell
$prior = Use-WizardLock -Key 'loop-relaunch-self' -Note 'Phase 10 self-handoff'
if ($null -eq $prior) {
    # First time — do the work.
} else {
    # Already done at $prior.AcquiredAt by PID $prior.AcquiredBy. Skip.
}
```

### AI search & repo profile

| Cmdlet | What |
| ------ | ---- |
| `Find-Code -Pattern <regex> [-Path <root>] [-MaxCount 120] [-Context 2] [-FilesOnly] [-Json] [-Compact] [-Include @('*.cs','*.py')]` | Ripgrep wrapper with broad ignore globs and bounded match count. |
| `Find-Repos [-Root @('C:\Users\Oleh\Documents\GitHub')]` | Find git working trees under one or more roots. |
| `Find-CodeAcrossRepos -Pattern <regex> [-MaxPerRepo 40]` | Compose the two. |
| `Get-AIContext -File <path> -StartLine <N> [-Radius 40]` | Streamed line-numbered slice for big files. |
| `Get-RepoProfile [-Path <dir>]` | Detect HasSolution / HasBuildPsm1 / HasPyProject / HasCMakeLists / HasPesterTests / HasDotNetTests / HasPyTests + PrimaryHints (csharp/python/typescript/cpp/…). |
| `Invoke-RepoBuild [-Path <dir>] [-TimeoutSec 600]` | Auto-route by profile (build.psm1 / dotnet / cmake / npm). Output bounded by `Invoke-Bounded`. |
| `Invoke-RepoTest [-Path <dir>] [-TestPath <narrow>] [-Kind Auto\|Pester\|XUnit\|DotNet\|Python\|Node]` | Same shape, for tests. |
| `Update-RepoDigest [-Path <dir>]` | Write `.ai/repo-map.md` from `git ls-files`. |
| `Measure-RepoSearch -Pattern <regex> [-Path <dir>] [-MaxCount 100]` | Benchmark `rg` vs PowerShell's recursive `Select-String`. |

---

## Signal topics (conventions)

| Topic                                   | Producer                       | Schema                                                                              |
| --------------------------------------- | ------------------------------ | ----------------------------------------------------------------------------------- |
| `process.<exe>`                          | `Start-MonitoredProcess`       | `{ state: started\|heartbeat\|exited, pid, command?, args?, cwd?, exitCode?, … }` |
| `wizard.bashcompat.unsupported`          | `Invoke-BashCompat`            | `{ command, reason }`                                                              |
| `wizard.broadcast`                       | Phase-10 broadcaster           | `{ at, recipients[], excluded[], prompt }`                                          |
| `wizard.broadcast.ack`                   | Each looped instance           | `{ instance, repo, exitCode, tail, at }`                                            |
| `cognitive.pulse`                        | _planned_ rewired cognitive_pulse_hook | The full pulse block; the prompt-submit injection becomes a 1-line pointer. |
| `wizard.hookhost.respawn`                | _planned_ Phase-6 hook host    | `{ name, reason, at }`                                                              |

---

## Settings.json swap recipes

**Hard rule**: never wrap a Claude Code hook (`type:"command"`) in `Invoke-Bounded`. Hooks have a JSON-stdin → JSON-stdout protocol; bounding the output corrupts it.

Where you **can** swap:

- WizardErasmus internal Python wrappers that shell out (cmake, ninja, pytest). Wrap *inside* the wrapper.
- MCP tool implementations (`smart_build`, `smart_test`, `error_diagnosis`).
- Agent-issued Bash/PowerShell tool calls — encourage via `CLAUDE.md` + skill, not enforced via hook.

What hooks **can** do safely:

- Compute a heavy payload (e.g. cognitive-pulse).
- Call `Publish-WizardSignal -Topic cognitive.pulse -Data $payload`.
- Return only a tiny `{ "hookEventName": "UserPromptSubmit", "additionalContext": "<cognitive-pulse signalSeq=N/>" }` so the model receives a pointer instead of the full block.

The user can fetch the body on demand via `Read-WizardSignal -Topic cognitive.pulse` (or via a planned `mcp__wizard__check_pulse`).

Use `tools/wizard/Install-WizardSettings.ps1` once shipped — it backs up `settings.json` to `settings.json.bak-<utc>` and supports `-DryRun` / `-Restore`.

---

## Performance rules (when authoring new cmdlets)

| Problem                  | Prefer                                                  | Avoid                                            |
| ------------------------ | ------------------------------------------------------- | ------------------------------------------------ |
| Repo search              | `rg` via `Find-Code`                                    | `Get-ChildItem -Recurse \| Select-String`         |
| Large file processing    | `[System.IO.File]::ReadLines()` or `StreamReader`       | `Get-Content` on multi-MB files                  |
| String building          | `-join` or `StringBuilder`                              | `$s += …` in large loops                          |
| Large collections        | `List<T>` or pipeline                                   | repeated `+=` on arrays                          |
| Lookup                   | hashtable                                               | repeated `Where-Object`                          |
| Suppressing loop output  | `$null = …` or `[void]…`                                | `… \| Out-Null` in hot loops                      |
| AI-facing output         | objects or compact JSON                                 | pretty tables, full logs                         |
| Repeated work            | cache the repo profile                                  | re-scan on every command                         |

---

## Troubleshooting

- **`Get-WizardSession` shows `WizardControlEnabled=$false`** — the env var isn't set, or the user pwsh.exe isn't the wizard build. Check `(Get-Process -Id $PID).Path` matches the path produced by `Start-PSBuild`.
- **UTF-8 issues persist** — run `chcp` in the same shell; should be `65001`. Phase 1 hardening sets the .NET-side encodings; if a parent process pre-set the legacy code page, restart the shell.
- **`Find-Code` errors with `ripgrep is required`** — install `rg`: `winget install BurntSushi.ripgrep.MSVC` or `scoop install ripgrep`.
- **`Invoke-Bounded` log path uses forward slashes on Windows** — that's how `git rev-parse` reports paths and is harmless. Use `-LogTo` to override.
- **Invoke-BashCompat falls through to bash.exe but bash isn't installed** — install Git Bash or WSL, or stick to PowerShell-native commands.
- **Phase-10 `wizard.broadcast.ack` missing for an instance** — that instance probably wasn't actually idle; the loop body skipped its first tick. Re-list state and try again.

---

## Codex parity

Codex on Windows inherits the parent shell, so once `pwsh.exe` is the wizard shim, Codex picks up `WIZARD_PWSH_CONTROL=1` and the cmdlets transparently. Verify by asking Codex to run `Get-WizardSession` — `WizardControlEnabled` must be `$true`.

To install Codex-side AI guidance:

- User-level: copy `tools/wizard/templates/.codex/AGENTS.md` to `C:\Users\Oleh\.codex\AGENTS.md`.
- User-level config example: `tools/wizard/templates/.codex/config.toml.example`.
- Per-repo skills: `Install-RepoAIContract.ps1` already deploys `.agents/skills/{repo-search,compact-test}/SKILL.md` which Codex reads for project skills.

If Codex shows `WizardControlEnabled=$false`, the parent terminal wasn't the shim. Relaunch via `mcp__wizard__vscode_launch_agent` from a Wizard-shim shell, or pick the Wizard profile in Windows Terminal.

---

## Local-only AI files for upstream forks

If the repo is `microsoft/PowerShell` or another upstream repo, run `Install-RepoAIContract -RepoType Upstream` (it auto-detects from the remote URL). That mode adds `AGENTS.md`, `CLAUDE.md`, `.rgignore`, `.aiignore`, and the skill dirs **without** committing them — they go through `.git/info/exclude` so they stay untracked. Use this for any fork where the AI-helper files would be unwelcome upstream.
