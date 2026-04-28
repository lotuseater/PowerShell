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
| `Get-WizardSession` | One-line snapshot of *this* process: PID, pipe name, log dir, `WizardControlEnabled`, `HookHostStatus`, encoding, native-error pref, started time. |
| `status.extended` (control-pipe verb, **γ2**) | Same shape as `status` plus `currentCommand`, `lastCommand`, `historyCount`. Lets DAB / agents see what's running in a tab right now without OCR. Call via `Send-WizardControlRequest -Payload @{ command = 'status.extended' }` or from Python: `WizardPwshClient(pid).status_extended()`. |
| `Get-WizardSessions [-Top 10] [-All] [-IncludeStale] [-SessionRoot <path>]` | **γ1.** Enumerates wizard pwsh sessions on this machine by scanning `%LOCALAPPDATA%\WizardPowerShell\sessions\*.json`. Returns `WizardSessionEntry` records sorted newest-first with `Pid`, `PipeName`, `Cwd`, `Executable`, `Started`, `IsAlive`. **Default emits the 10 most recent**; pass `-All` for the full list (often 30-50+ on a busy box) or `-Top N` to override. Stale entries (PID gone) excluded by default. Discovery primitive for agents that need to find a live wizard pipe by enumeration. |

### Python client

A canonical Python binding at `tools/wizard/clients/python/wizard_pwsh_client.py` ships the same protocol for non-PowerShell callers. Replaces hand-rolled marshalling like `Wizard_Erasmus/ai_wrappers/pwsh_control.py`.

```python
from wizard_pwsh_client import WizardPwshClient, list_sessions

for s in list_sessions():
    print(s.pid, s.pipe_name, s.cwd)

with WizardPwshClient(pid=12345) as client:
    client.publish_signal("agent.heartbeat", {"alive": True})
    client.warmup_hooks(["cognitive_pulse", "pretool_cache"])
```

Requires `pywin32` on Windows. See `tools/wizard/clients/python/README.md` for details.

### Token-bounded execution

| Cmdlet | What |
| ------ | ---- |
| `Invoke-Bounded -FilePath <exe> -ArgumentList @(…) -MaxLines 80 -TimeoutSec 120 [-LogTo <path>] [-Quiet] [-MergeStdErr] [-PassThru]` | Run a child process, stream full stdout+stderr to a log under `%LOCALAPPDATA%\WizardPowerShell\logs\`, return a `WizardBoundedResult` with `ExitCode`, `Head`, `Tail`, `LogPath`, `TotalLines`, `TruncatedLines`, `Duration`, `KilledByTimeout`. **`-PassThru`** (β4) line-streams each child stdout/stderr line to the host as it arrives, so the agent sees progress on long builds while still receiving the bounded result at the end. |
| `Get-WizardLog -LogPath <path> -Range head:N\|tail:N\|lines:A-B\|grep:PATTERN` | Fetch a slice of the on-disk log on demand. |

### Signal bus (over the named pipe)

| Cmdlet | What |
| ------ | ---- |
| `Publish-WizardSignal -Topic <name> -Data <object> [-Ring 256]` | Push an event onto a per-topic ring buffer. |
| `Read-WizardSignal -Topic <name> [-Since <seq>] [-Limit 64] [-WaitMs <ms>] [-PollIntervalMs 100]` | Read events with seq > Since. **`-WaitMs N`** (β2) blocks up to N ms (client-side polling at `-PollIntervalMs`) until new events arrive, then returns. Cheaper than busy-waiting in an agent loop body. |
| `Start-MonitoredProcess -FilePath <exe> -ArgumentList @(…) [-Topic <name>] [-HeartbeatSeconds 2]` | Launch a child detached; publish `process.started` / `process.heartbeat` / `process.exited` events to the topic. |

### Bash compatibility

| Cmdlet | What |
| ------ | ---- |
| `Invoke-BashCompat -c '<command>'` | Translate a small bash subset (`&&`, `\|\|`, `;`, `\|`, `head -n`, `tail -n`, `grep`, `2>&1`, leading `cd DIR && …`) to PowerShell and execute. Falls back to `bash.exe` for anything outside the subset (publishing `wizard.bashcompat.unsupported`). Aliases `bash` and `sh` are registered automatically when `WIZARD_PWSH_CONTROL=1`. |

### Persistent Python hook host (Phase 6)

| Cmdlet | What |
| ------ | ---- |
| `Invoke-WizardHook -Name <hook> [-Payload <object>] [-TimeoutMs 30000]` | JSON-RPC over the local pipe to a warm Python child. The first call lazy-spawns `py -3.14 -m wizard_mcp.hook_host`; subsequent calls reuse the warm process. |
| `Initialize-WizardHookHost -Hooks @('hook1','hook2','...') [-TimeoutMs 30000]` | **β3.** Eagerly pre-import named hook modules in the warm Python child. Eliminates the cold-import cost on the FIRST `hook.invoke` of each name (~200-500 ms for `cognitive_pulse`). Recommended startup line for an agent-driven session: `Initialize-WizardHookHost @('cognitive_pulse','pretool_cache')`. |

Wiring on the WizardErasmus side: drop `tools/wizard/hook_host_reference.py` into `Wizard_Erasmus/src/mcp/hook_host.py`, register your hook callables in the `HOOKS` / `HOOK_PATHS` dispatch table, and (optionally) point `$env:WIZARD_HOOKHOST_MODULE` at a different module path. Each callable runs inside the warm child — pay the import cost once per shell, not once per hook fire. The shipped Wizard_Erasmus implementation is on feature branch `wizard/hook-host-and-trust-regex` (commit `461f443`).

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

### Anthropic CLI integration

| Cmdlet | What |
| ------ | ---- |
| `Invoke-AntQuery -Prompt <text> [-Model <id>] [-MaxTokens 1024] [-System <text>] [-AntPath <path>] [-TimeoutSec 60]` | One-shot Claude API query through `ant` (github.com/anthropics/anthropic-cli), bounded via Invoke-Bounded. Returns `WizardAntResponse` with `Content`, `Model`, `UsageInput`, `UsageOutput`, `StopReason`, `DurationMs`, `LogPath`. Locates the binary via `-AntPath`, `$env:WIZARD_ANT_PATH`, or `Get-Command ant`. Publishes `wizard.ant.query` signal for audit. |

Useful when a hook or skill needs to call Claude programmatically — e.g. to summarise a long error trace or reformat build output — without going through the Claude Code TUI. See also: `tools/wizard/templates/skills/sync-wizard-optimizations/SKILL.md` for a skill that uses it.

### AI search & repo profile

| Cmdlet | What |
| ------ | ---- |
| `Find-Code -Pattern <regex> [-Path <root>] [-MaxCount 40] [-Context 2] [-FilesOnly] [-Json] [-Compact] [-Include @('*.cs','*.py')]` | Ripgrep wrapper with broad ignore globs and bounded match count. **Default `-MaxCount` is 40** (was 120 pre-2026-04-28 — emitted ~600 lines / ~5 KB / 1 k tokens by itself on a typical search). Bump explicitly when you genuinely want more. |
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
| `cognitive.pulse`                        | rewired cognitive_pulse_hook (Phase 9a, live) | The full pulse block; the prompt-submit injection becomes a 1-line pointer. |
| `wizard.hookhost.respawn`                | Phase-6 hook host (live)       | `{ name, reason, at }`                                                              |
| `wizard.ant.query`                       | `Invoke-AntQuery`              | `{ model, promptHead, maxTokens, ts }`                                              |
| `wizard.bashcompat.unsupported`          | `Invoke-BashCompat` (when input falls outside the supported subset) | `{ command, reason }` |
| `wizard.loop.wake.<sid>`                 | `Send-WizardLoopWake` (or WizardErasmus `--wake` CLI) | `{ sessionId, at }` — wake a sleeping `idle_watch_loop` driver early. WE consumer at `ai_wrappers/idle_watch_loop.py:_interruptible_sleep`. |
| `wizard.loop.tick.complete`              | WizardErasmus `idle_watch_loop` (rev-3, live) | `{ session_id, event_kind, duration_ms, nudge_count, menu_answer_count }` — published once per tick when the loop driver has a wizard pwsh pipe. Use to dashboard loop liveness without OCR. |
| `wizard.loop.rate_limited`               | WizardErasmus `idle_watch_loop` (rev-3, live) | `{ session_id, parsed_delay_s, at }` — emitted before the chunked rate-limit sleep so external monitors can show "loop sleeping until X". |
| `wizard.loop.rate_limit.cleared`         | WizardErasmus `idle_watch_loop` (rev-3, live) | `{ session_id, woken_externally, at }` — emitted after the post-sleep nudge fires; pairs with `wizard.loop.rate_limited` for the full transition. |

### Send-WizardLoopWake (rev-3, live)

| Cmdlet | What |
| ------ | ---- |
| `Send-WizardLoopWake -SessionId <sid> [-PipeName <name>]` | One-line wrapper around `Publish-WizardSignal -Topic wizard.loop.wake.<sid>`. Pairs with the WizardErasmus-side `python -m ai_wrappers.idle_watch_loop --wake <sid>` CLI — both publish the same topic. PowerShell users get a one-word command, Python users get the same effect from any shell. |

### read.structured verb (γ3, live)

Control-pipe verb that returns the console buffer as typed lines
instead of flat text. Drives smarter loop classifier behaviour
without OCR.

| Verb | Request | Response |
| ---- | ------- | -------- |
| `read.structured` | `{ command: 'read.structured', maxLines: 200 }` | `{ status, method:'native_console', lines:[{lineNum, type, text}], width, height, window }` |

`type` is one of:
- `prompt` — line matches the host's prompt glyph (`PS C:\repo>`,
  trailing `>`, or Claude Code's `❯`).
- `error` — line matches a known error-line shape (`Error:`,
  `Exception:`, `error CS1234:`, `FATAL:`, ...).
- `output` — default classification.

Call from PowerShell:

```powershell
$h = Connect-WizardPwshSession -Pid 12345
$lines = $h.ReadStructured(120).lines
$lines | Where-Object type -eq 'error' | ForEach-Object { Write-Warning $_.text }
```

Call from Python:

```python
from wizard_pwsh_client import WizardPwshClient
with WizardPwshClient(pid=12345) as c:
    structured = c.read_structured(120)
    for entry in structured.get("lines", []):
        if entry["type"] == "error":
            handle(entry["text"])
```

Older servers without the verb return `{ status: 'error', error: 'unknown_command' }`.

### Start-WizardManagedTerminal (rev-4, live)

| Cmdlet | What |
| ------ | ---- |
| `Start-WizardManagedTerminal -Provider <codex\|claude\|gemini> -ChildArgs <argv> -SessionId <sid> [-Title <text>] [-Cwd <path>] [-WtWindow <name>] [-NewWindow] [-Env <hashtable>]` | Spawn a wizard-controlled pwsh tab (or window) running the requested agent CLI. Replaces WizardErasmus's hand-rolled `pwsh -EncodedCommand` spawn dance with one cmdlet. Default = `wt.exe -w wizard-loops new-tab` so all loops collapse into one Windows Terminal window; `-NewWindow` opts into the legacy CreateNewConsole path when wt.exe is unavailable or you explicitly want a separate console. Returns `WizardManagedTerminalResult` with `Pid`, `Title`, `SessionId`, `Channel='wt_new_tab'\|'new_console'`, `Provider`, `Cwd`, `WtWindow`. |

```powershell
# Spawn a Claude loop tab as a sibling of any other wizard-loops tabs
$r = Start-WizardManagedTerminal -Provider claude `
    -ChildArgs @('--dangerously-skip-permissions') `
    -SessionId 'claude-loop-1' -Title 'Claude Loop'
$r.Pid; $r.Channel  # 'wt_new_tab' on hosts with wt.exe

# Force a separate console window (audit / debug)
Start-WizardManagedTerminal -Provider codex `
    -ChildArgs @('resume') -SessionId 'codex-debug-1' -NewWindow
```

The WizardErasmus side shells out to this cmdlet by default (env var
`WIZARD_USE_MANAGED_TERMINAL_CMDLET`, default on). Set
`WIZARD_USE_MANAGED_TERMINAL_CMDLET=0` as a kill-switch to use the
legacy in-process spawn path.

```powershell
# Wake the loop driving managed terminal session claude-24624-…
Send-WizardLoopWake -SessionId claude-24624-1777343499545

# Target a specific pwsh pipe (when the loop driver lives in a different shell):
Send-WizardLoopWake -SessionId sess-123 -PipeName wizard-pwsh-19636
```

The driver records its own pipe name on the managed-terminal sidecar at startup (field `loop_driver_pwsh_pipe`); use that when waking from a different pwsh shell.

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

Use `tools/wizard/Install-WizardSettings.ps1` (shipped) — backs up `settings.json` to `settings.json.bak-<utc>` and supports `-DryRun` / `-Restore`. Already applied for `cognitive_pulse` and `pretool_cache`; the kill switch `$env:WIZARD_HOOKS_REWIRED='0'` reverts to the cold-spawn original without needing `-Restore`.

---

## Recommended startup snippet (drops the first-turn cold-import)

For agent-driven sessions, add this to your `$PROFILE` or `tools/wizard/Install-WizardPwsh.ps1` rollout. It fires once per shell, well before the first model turn:

```powershell
if ($env:WIZARD_PWSH_CONTROL -eq '1') {
    Initialize-WizardHookHost -Hooks @('cognitive_pulse','pretool_cache') -ErrorAction SilentlyContinue | Out-Null
}
```

Verify after one Claude turn: `Send-WizardControlRequest -Payload @{command='hook.list'}` should show `cognitive_pulse` with `calls > 0` and `p50ms` ≤ 50.

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
