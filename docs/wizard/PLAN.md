# Wizard PowerShell — Optimization Plan

_Last updated: 2026-04-27. Tracking branch: `wizard_power_shell`._

Companion to [`RESEARCH.md`](./RESEARCH.md). That doc explains **why**; this one is the **what / how / in what order**.

---

## Goal

Turn the `WizardControlServer` seed in this fork into a small, opt-in **agent runtime** that:

1. Absorbs per-hook Python cold-spawn cost (latency + tokens).
2. Bounds verbose process output before it hits the model context (tokens).
3. Streams structured signals to agents over the existing pipe instead of stdout (tokens + reliability).
4. Normalises Windows-shell quirks (UTF-8, native error semantics, bash idioms) so bash-trained agents stop tripping (reliability).

All new behaviour is gated behind `WIZARD_PWSH_CONTROL=1`. Without that env var the fork behaves exactly like upstream PowerShell.

---

## Design constraints

- **Don't break upstream-merge.** No changes to default cmdlet behaviour, formatters, parser, or PSReadLine outside the env-var-gated startup path.
- **Don't fork the runtime.** Reuse `WizardControlServer.JsonRpcSession` framing for new verbs; reuse `Install-WizardPwsh.ps1` deployment + rollback.
- **Don't migrate the hook fleet eagerly.** Phase 6 unlocks the runtime; migration of the ~28 hooks in `Wizard_Erasmus` is a downstream effort (one hook at a time, after dogfood).
- **Phase boundaries are ship boundaries.** Each phase ends with: build green, focused Pester pass, single commit on `wizard_power_shell`.

---

## Phase 0 — Save research & plan into the fork ✅

- [x] Write [`docs/wizard/RESEARCH.md`](./RESEARCH.md).
- [x] Write [`docs/wizard/PLAN.md`](./PLAN.md) (this file).
- [ ] Commit `docs(wizard): research findings and optimization plan`.

---

## Phase 1 — Startup hardening (smallest, ships first)

**Why**: Eliminates the easiest token-loss class (mojibake) and the easiest reliability class (native errors not breaking chains). Cheapest possible first commit — earns trust that the env-var gate works as advertised.

**Files**

- `src/Microsoft.PowerShell.ConsoleHost/host/msh/ConsoleHost.cs` — add a small `ApplyWizardStartupHardening()` private method called immediately after `WizardControlServer.StartIfEnabled` succeeds.
- `test/powershell/Host/WizardStartup.Tests.ps1` — new Pester file.

**Steps**

1. In `ConsoleHost.cs`, add (under `if (Environment.GetEnvironmentVariable("WIZARD_PWSH_CONTROL") == "1")`):
   - `[Console]::InputEncoding = new UTF8Encoding(false)`
   - `[Console]::OutputEncoding = new UTF8Encoding(false)`
   - Push `$OutputEncoding = [System.Text.UTF8Encoding]::new($false)` onto the initial runspace via the same mechanism the host already uses for setting prefs.
   - Push `$PSNativeCommandUseErrorActionPreference = $true`.
   - If `Console.IsInputRedirected`, skip auto-loading PSReadLine.
2. Add Pester test that:
   - Launches `pwsh -NoProfile` with `WIZARD_PWSH_CONTROL=1`, runs `python -c "print('é')"` over stdin, asserts the byte sequence in stdout is the UTF-8 encoding of `é`, not cp1252 mojibake.
   - Launches without the env var, asserts no behaviour change vs. upstream baseline (input/output encoding unchanged).
3. `Start-PSBuild` (or `Start-PSBuild -Clean` if needed). Run `Invoke-Pester test/powershell/Host/WizardStartup.Tests.ps1`.
4. Commit `feat(wizard): UTF-8 + native-error startup hardening under WIZARD_PWSH_CONTROL`.

**Done when**: build green, Pester green, manual smoke (`pwsh.exe` produced by the build prints UTF-8 cleanly under the env var, identical to upstream without it).

---

## Phase 2 — Wizard cmdlet module skeleton

**Why**: Establishes a place to put the cmdlets the next phases need, and lets us pre-load it once per process instead of from each hook.

**Files**

- `src/Modules/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psd1`
- `src/Modules/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psm1`
- `src/Modules/Microsoft.PowerShell.Wizard/Get-WizardSession.ps1` (advanced function for now; promote to compiled cmdlet only if perf demands)
- Update SDK manifest / `build.psm1` so the module is copied into `$PSHOME/Modules` during `Start-PSBuild`.
- Pre-load hook in `ConsoleHost.cs` (alongside Phase 1 hardening).

**`Get-WizardSession` returns** an object with: `Pid`, `PipeName`, `LogDir`, `HookHostStatus` (`disabled` for now — will fill in Phase 6), `Started`, `WizardControlEnabled`.

**Tests**

- `test/powershell/Modules/Microsoft.PowerShell.Wizard/GetWizardSession.Tests.ps1` asserts shape under env var, returns nothing/errors cleanly without it.

**Commit**: `feat(wizard): scaffold Microsoft.PowerShell.Wizard module + Get-WizardSession`.

---

## Phase 3 — `Invoke-Bounded` + `Get-WizardLog`

**Why**: Highest-impact stdout-token reduction. Every `cmake`/`ninja`/`pytest` run currently sends hundreds of KB of build output back to the model. Replace with head + tail + log path.

**Files**

- `src/Modules/Microsoft.PowerShell.Wizard/Invoke-Bounded.ps1` (start as advanced function)
- `src/Modules/Microsoft.PowerShell.Wizard/Get-WizardLog.ps1`
- `src/Modules/Microsoft.PowerShell.Wizard/Tail-WizardLog.ps1`
- Tests: `test/powershell/Modules/Microsoft.PowerShell.Wizard/InvokeBounded.Tests.ps1`

**Contract — `Invoke-Bounded`**

| Parameter      | Default                                                  | Notes                                          |
| -------------- | -------------------------------------------------------- | ---------------------------------------------- |
| `-FilePath`    | required                                                 | Native exe path.                               |
| `-Args`        | `@()`                                                    |                                                |
| `-MaxBytes`    | `16384`                                                  | Returned-to-stdout cap.                        |
| `-MaxLines`    | `80`                                                     | Head **and** tail line cap.                    |
| `-Timeout`     | `120` s                                                  | Hard kill at deadline.                         |
| `-LogTo`       | `$env:LOCALAPPDATA\WizardPowerShell\logs\<pid>-<utc>.log` |                                                |
| `-WorkingDir`  | `$PWD`                                                   |                                                |
| `-Quiet`       | `$false`                                                 | If set, suppress head/tail in stdout — only object. |

**Returns** a `WizardBoundedResult` with: `ExitCode`, `Head` (first N lines), `Tail` (last N lines), `LogPath`, `TruncatedLines`, `Duration`, `KilledByTimeout`.

**`Get-WizardLog` / `Tail-WizardLog`** — fetch on demand. `Get-WizardLog -LogPath … -Range 'head:120'`, `'tail:200'`, `'lines:1000-1100'`, or `'grep:"error\\b" -Context 5'`.

**Tests**

- Run a script that emits 100 000 lines; assert log has all of them, returned object has 80 head + 80 tail.
- Run a 5 s sleep with `-Timeout 1`; assert `KilledByTimeout=$true`, exit 124-equivalent.
- `Get-WizardLog -Range 'tail:5'` returns the last 5 lines verbatim.

**Commit**: `feat(wizard): Invoke-Bounded + Get-WizardLog for token-bounded execution`.

---

## Phase 4 — Signal channel + `Start-MonitoredProcess`

**Why**: Replaces OCR (`visual_verify_hook`, `dab_wait_idle`) with a structured event stream for process state — agents poll JSON instead of pixels.

**Files**

- `src/Microsoft.PowerShell.ConsoleHost/host/msh/WizardControlServer.cs` — extend dispatch with `signal.publish` (writes), `signal.subscribe` (reads + long-poll cursor), `signal.list` (topic enumeration). Per-topic ring buffer (default 256 entries).
- `src/Modules/Microsoft.PowerShell.Wizard/Start-MonitoredProcess.ps1` — wraps `Start-Process`, posts `process.started`, `process.heartbeat` (every 2 s), `process.stalled` (no output for N s), `process.exited` to the signal bus.
- `src/Modules/Microsoft.PowerShell.Wizard/Publish-WizardSignal.ps1` / `Read-WizardSignal.ps1` — convenience wrappers over the `signal.*` verbs.

**Topics (initial)**

| Topic            | Schema                                                                               |
| ---------------- | ------------------------------------------------------------------------------------ |
| `process.*`      | `{ pid, command, args, state, exitCode?, durationMs?, lastOutputAt? }`               |
| `wizard.startup` | `{ version, pipeName, encodings, modulesLoaded[] }`                                  |
| `hook.*`         | _(reserved for Phase 6)_                                                             |

**Tests**

- Pester subscriber-publisher round-trip in two runspaces.
- Long-poll cursor advances correctly across reconnects.

**Commit**: `feat(wizard): signal channel + Start-MonitoredProcess`.

---

## Phase 5 — `Invoke-BashCompat` + `bash`/`sh` aliases

**Why**: Closes the bash-idiom parser-error class. Even partial coverage of the most common forms (`&&`, `||`, `;`, `|`, `head -n`, `tail -n`, `grep`, `2>&1`) eliminates most observed friction.

**Files**

- `src/Modules/Microsoft.PowerShell.Wizard/Invoke-BashCompat.ps1`
- `src/Modules/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psm1` — register `bash` / `sh` aliases when `WIZARD_PWSH_CONTROL=1` (and **only** then).
- Tests: `BashCompat.Tests.ps1`.

**Approach**: small, explicit translator — not a real bash AST.
- Tokenise on `&&`, `||`, `;`, `|`, redirections.
- `head -n N` → `Select-Object -First N`. `tail -n N` → `Select-Object -Last N`. `grep PAT` → `Select-String -Pattern PAT`. `2>&1` → `*>&1`. `&&` → `-and` chain via `if ($?) { … }`. `||` → `if (-not $?) { … }`.
- Anything outside the supported subset: fall through to `pwsh -Command`, log a warning to a `wizard.bashcompat.unsupported` signal so we can prioritise next additions from real usage.

**Tests**: each idiom + a fall-through case + the negative case (no env var → no alias registered).

**Commit**: `feat(wizard): Invoke-BashCompat + bash/sh aliases under WIZARD_PWSH_CONTROL`.

---

## Phase 6 — Persistent Python hook host

**Why**: Biggest latency win, biggest invisible-token-tax win. Each of the ~14 PowerShell-hosted Python hooks currently re-imports the `wizard_mcp` modules on cold spawn. Holding one warm child cuts that to a single import per shell lifetime.

**This phase touches two repos.** Land the server-side first, then a single dogfood hook on the WizardErasmus side, then evaluate before mass-migrating.

**This repo (PowerShell fork)**

- `src/Microsoft.PowerShell.ConsoleHost/host/msh/WizardControlServer.cs` — new verbs `hook.register`, `hook.invoke`, `hook.list`, `hook.unregister`. Lifecycle for a single child `py -3.14 -m wizard_mcp.hook_host` over an anonymous pipe; lazy-spawn on first `hook.invoke`, kill on shell exit.
- `src/Modules/Microsoft.PowerShell.Wizard/Invoke-WizardHook.ps1` — convenience cmdlet: `Invoke-WizardHook -Name pretool_cache -Payload (Get-Content -Raw input.json)` → JSON over the pipe → JSON back.
- Tests: `HookHost.Tests.ps1` — register a noop hook, invoke 100×, assert mean latency under 50 ms.

**WizardErasmus repo (separate, downstream)**

- New `src/mcp/hook_host.py`: minimal JSON-RPC loop, `register(name, callable)`, dispatches by name. Imports the same `wizard_mcp.*` surface so registered hooks already have context warm.
- Convert one low-risk hook (`pretool_cache_hook`) to call `register(...)` instead of running standalone. Update one entry in `C:\Users\Oleh\.claude\settings.json` from `& py -3.14 'C:\…\pretool_cache_hook.py'` to `Invoke-WizardHook -Name pretool_cache`.
- Dogfood for one session, measure, only then plan the wider migration.

**Commit (this repo)**: `feat(wizard): persistent Python hook host via control pipe`.

---

## Phase 7 — Installer & docs polish

**Files**

- `tools/wizard/Install-WizardPwsh.ps1` — install the new module (copy `src/Modules/Microsoft.PowerShell.Wizard` to `$PSHOME\Modules\` if installing to a system location, or to the user's PSModulePath if user-scope), create the log dir, optionally append `WIZARD_PWSH_CONTROL=1` to the user environment (with a kill-switch `-NoEnableEnv`).
- `docs/wizard/USAGE.md` — env vars, cmdlets, signal topics, recommended `settings.json` patterns, troubleshooting.
- Push `wizard_power_shell` to origin.

**Commit**: `chore(wizard): installer + USAGE.md, finalize wizard_power_shell rollout`.

---

## Verification (cross-cutting)

After every phase:
- `Start-PSBuild` clean.
- Existing `test/powershell/Host/WizardControl.Tests.ps1` still green — guarantees the original control verbs aren't broken by the new ones.
- New phase-specific Pester suite green.

Final end-to-end check (after Phase 7):
1. `Install-WizardPwsh.ps1 -EnableEnvVar`, restart shell.
2. `Get-WizardSession` → object with `WizardControlEnabled=$true`, `HookHostStatus='warm'` after first `Invoke-WizardHook`.
3. From a Python REPL: open `\\.\pipe\wizard-pwsh-{PID}`, subscribe to `process.*`, run `Start-MonitoredProcess -FilePath cmake -Args build` in the shell, observe heartbeats land without OCR.
4. `Invoke-Bounded -FilePath ninja -Args build` on a real WizardErasmus build dir; assert returned object's stdout under 16 KB and `Get-WizardLog -LogPath $r.LogPath -Range 'tail:200'` returns the build's tail end.
5. Migrate `pretool_cache_hook` to `Invoke-WizardHook`, run a normal Claude turn, confirm cognitive-pulse output looks unchanged.

---

## Out of scope

- Rewriting any cmdlet's default formatter (would conflict with upstream merges).
- Changing the parser, the language, or PSReadLine in non-controlled sessions.
- Migrating all 28 hooks in WizardErasmus. Phase 6 enables the runtime; full migration is downstream.
- Codex config changes. Codex inherits the system shell — once the user's `pwsh.exe` is the WizardErasmus shim, Codex benefits transparently.
- Replacing OCR / `dab_*`. Phase 4 makes them less necessary; deciding whether to deprecate them is a separate decision in WizardErasmus.

---

## Status snapshot

| Phase | Status     | Commit                                                                             |
| ----- | ---------- | ---------------------------------------------------------------------------------- |
| 0     | in flight  | `docs(wizard): research findings and optimization plan` (pending)                  |
| 1     | pending    | `feat(wizard): UTF-8 + native-error startup hardening under WIZARD_PWSH_CONTROL`   |
| 2     | pending    | `feat(wizard): scaffold Microsoft.PowerShell.Wizard module + Get-WizardSession`    |
| 3     | pending    | `feat(wizard): Invoke-Bounded + Get-WizardLog for token-bounded execution`         |
| 4     | pending    | `feat(wizard): signal channel + Start-MonitoredProcess`                            |
| 5     | pending    | `feat(wizard): Invoke-BashCompat + bash/sh aliases under WIZARD_PWSH_CONTROL`      |
| 6     | pending    | `feat(wizard): persistent Python hook host via control pipe`                       |
| 7     | pending    | `chore(wizard): installer + USAGE.md, finalize wizard_power_shell rollout`         |
