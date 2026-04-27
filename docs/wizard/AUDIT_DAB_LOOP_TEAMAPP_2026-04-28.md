# Audit — DAB / Loop / Team-app / PowerShell wrappers

_Snapshot 2026-04-28. Branch: `wizard_power_shell`._

In-depth audit of four cross-repo questions, sources cited inline. Companion to [`RESEARCH.md`](./RESEARCH.md), [`PLAN.md`](./PLAN.md), and [`USAGE.md`](./USAGE.md).

---

## 1 — DAB ↔ PowerShell capabilities (`Wizard_Erasmus/ai_wrappers/_dab_bridge.py` + `src/automation/python/dab.py`)

### 1.1 What works today

| Capability                                       | DAB | Source                                                                                  |
| ------------------------------------------------ | --- | --------------------------------------------------------------------------------------- |
| Read whole console buffer                        | ✓   | `WizardControlServer.cs:382-422` (`Read` verb, `ReadConsoleOutputCharacter`)            |
| Read visible region only                         | ✓   | `WizardControlServer.cs:392-393` (filter to `srWindow.Bottom`)                          |
| Send keystrokes (Ctrl+C/L/R, F1-F12, modifiers)  | ✓   | `dab.py:1327-1365` (`cmd_send_keys` via pywinauto)                                      |
| Send literal text                                | ✓   | `dab.py:1375-1416` (clipboard+Ctrl+V fallback)                                          |
| Locate window by title regex                     | ✓   | `dab.py:cmd_find_window`                                                                |
| Resize / maximise / minimise / focus             | ✓   | `dab.py:cmd_minimize/maximize/restore/focus`                                            |
| Screenshot the tab                               | ✓   | `wizard_mcp_server.py:819-829` (`dab_screenshot`)                                       |
| OCR the tab text                                 | ✓   | `wizard_mcp_server.py:1067-1090` (`dab_ocr`, `dab_ocr_click`)                           |

### 1.2 Gaps

| Gap                                                       | Impact                                                                                                              |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| No enumeration of live wizard-pwsh PIDs                   | Agents must hand-roll a scan of `%LOCALAPPDATA%\WizardPowerShell\sessions\*.json`. Not wrapped anywhere.             |
| No "tab on screen → pipe name" mapping                    | DAB finds the window; deriving its PID + `wizard-pwsh-{PID}` pipe name is manual Win32 (`GetWindowThreadProcessId`). |
| Symbolic shortcut by name                                 | Raw vkey codes (`{F7} = 0x76`) — no "clear_line" / "reverse_search" / "history_menu" abstractions.                  |
| Read currently-running command programmatically           | Only OCR — there is runspace state in the snapshot but no command-text exposure.                                    |
| Structured console parse (line-typed: prompt/output/err)  | Flat text only.                                                                                                     |
| Multi-tab tracking inside one pwsh process                | Not possible — DAB sees `pwsh.exe` monolithically.                                                                  |

### 1.3 Proposed additions

**Wizard PowerShell fork** (this repo):
- **`Get-WizardSessions`** (plural, new cmdlet) — enumerates session JSON files, returns `[{Pid, PipeName, Cwd, Started, IsAlive}, …]`. Covers the discovery gap from the PS side without DAB changes. **← First pick (see § 5).**
- **`status.extended`** (new control-pipe verb) — extends `status` with current pipeline command text, last history entry, and CWD.
- **`read.structured`** (new control-pipe verb) — return console buffer as `[{lineNum, type:'prompt'|'output'|'error', text}, …]` so callers don't OCR.
- **`Connect-WizardPwshSession -Pid N`** (cmdlet) — returns a session handle that subsequent cmdlets target. Sugar on top of `WIZARD_PWSH_CONTROL_PIPE`.

**WizardErasmus DAB** (separate effort, feature branch needed):
- **`window_to_pwsh_pipe(hwnd)`** — given a window handle, detect wizard-pwsh and return `{pid, pipe, cwd}`.
- **`send_keyboard_shortcut_by_name(hwnd, name)`** — symbolic shortcut library (`reverse_search`, `clear_line`, `history_menu`, …).

---

## 2 — Loop subsystem (`Wizard_Erasmus/ai_wrappers/idle_watch_loop.py`)

### 2.1 WE-side improvements

1. **Hardcoded sleep, no early-wake** (line 865). When a menu appears mid-sleep, response latency is up to `effective_poll_period()` (≈ 15 s). Fix: subscribe to a `wizard.loop.wake` signal and break sleep early. **Cuts modal-answer latency 15 s → sub-second.**
2. **Multiple `observer()` (OCR) calls per tick** (lines 825, 870, 877, 922-923). Recovery paths re-OCR 2-3 times for the same snapshot. Fix: cache the snapshot for tick duration; have `_apply_menu_decision` return the snapshot it used.
3. **Rate-limit recovery is a synchronous sleep** (line 869-873) — blocks the entire loop for 30 min default with no signal. Fix: publish `wizard.loop.rate_limited` and check `stop_fn` periodically, or transition to async `state="rate_limited_waiting"` across ticks.
4. **No telemetry per tick.** Emit `wizard.loop.tick.complete` with `(event_kind, duration_ms, snapshot_hash)` so the PS side has visibility without OCR-ing the loop's own output.

### 2.2 PS-side companions

1. **`wizard.loop.wake` topic convention** + `Send-WizardLoopWake` cmdlet (one-line wrapper around `Publish-WizardSignal -Topic wizard.loop.wake`). Pairs with WE-2.1.1.
2. **Publish `wizard.loop.tick.due`** before each tick so MagicHat / external monitors can show "loop running, last fired Ys ago".
3. **`--rate-limit-callback`** flag on the loop entry point — PS publishes `wizard.loop.rate_limit.cleared` when its remote checker says the API is back.

### 2.3 Skill-template gaps

- **`wizard-loop-broadcast/SKILL.md`** — fire-and-forget; if N instances receive the prompt simultaneously they all OCR in lock-step. Stagger via `Publish-WizardSignal -Topic wizard.broadcast.ready-to-receive`.
- **`sync-wizard-optimizations/SKILL.md`** — `loop-state.json` is process-local, lost on `terminal_session_handoff`. Use `loop-state-<session-id>.json` keyed by Claude session id.

---

## 3 — Team app (`Wizard_Erasmus/src/team_app/`)

### 3.1 What it is

Win32 C++ desktop app at `app_window.cpp:WinMain()`. Orchestrates multi-agent AI teams via a **file-based JSON contract** (`{prefix}_cmd.json`, `_resp.jsonl`, `_events.jsonl`). UI: prompt bar + Chat / Terminals / Summary tabs. Spawns Codex/Claude agents through `agent_process.cpp`. **Does not** drive PowerShell, OCR, or send keystrokes — automation is purely file-based via `AutomationClient` (`team_app_ui_test_support.py:368+`).

### 3.2 Hard-coded paths

None for PowerShell. Agent launcher is configurable in the UI (Codex/Claude/legacy).

### 3.3 Improvements (downstream of the team app — in the agents it spawns)

1. `agent_process.cpp:77-120` — process spawn + manual pipe threading. Could delegate to `Start-MonitoredProcess` + signal bus instead of two C++ reader threads per agent.
2. `StdoutMonitor()` — same; could be `Invoke-Bounded -PassThru` if the agent is a CLI that emits structured output.
3. `AutomationClient` polling at `team_app_ui_test_support.py:388-410` — exactly the use case for `Read-WizardSignal -WaitMs`, **if** the team app were ever hosted in a managed_terminal. Today it's a separate Win32 app, so no change needed there.

**Verdict on team app proper**: clean, file-based, doesn't need wizard-fork changes.

---

## 4 — PowerShell wrappers in `Wizard_Erasmus/`

Two found outside `team_app/`:

### 4.1 `ai_wrappers/pwsh_control.py:44-100`

- **Purpose**: Issue commands (`status`/`read`/`write`) to a running wizard PowerShell session via the `\\.\pipe\wizard-pwsh-{PID}` named pipe.
- **Style**: **Hand-roll** — `win32file.WriteFile/ReadFile`, JSON marshalling, manual session discovery from `LOCALAPPDATA/WizardPowerShell/sessions/*.json`.
- **Verdict**: **Candidate for replacement**. The wrapper reimplements work the wizard fork should formally own. Two options:
  - **A.** Ship `tools/wizard/clients/python/wizard_pwsh_client.py` in the fork as the canonical Python client. WE replaces `pwsh_control.py` with `from wizard_pwsh_client import WizardPwshClient`. Single source of truth for the protocol.
  - **B.** Add `Connect-WizardPwshSession -Pid N` + `Invoke-WizardCommand -Handle $h -Cmd 'read'` on the PS side. Doesn't directly help Python callers (different language) but documents the protocol formally.
- **Recommendation**: **A** — Python clients dominate this code path.

### 4.2 `ai_wrappers/idle_watch_loop.py:1228-1422`

- **Purpose**: Spawn fresh managed PowerShell terminals carrying Codex/Claude agents, inject env vars, set window titles. Builds a pwsh script string, base64-encodes, calls `pwsh -EncodedCommand …`.
- **Style**: **Hand-roll script-builder + subprocess**.
- **Verdict**: **Partial replacement.** Add `Start-WizardManagedTerminal -Provider codex -ChildArgs @(...) -SessionId $id -Title "…"` to the fork. Cmdlet does env setup + child invocation + beacon registration in one call, eliminating the base64-encoded-command dance.

### 4.3 Other wrappers

Routine `subprocess.run(['pwsh', '-Command', …])` invocations across various Python tools are subprocess-capture style — fine to leave.

---

## 5 — Priorities & first pick

**Impact × effort matrix:**

| Item                                                | Impact   | Effort | Risk                                                                        | Repo |
| --------------------------------------------------- | -------- | ------ | --------------------------------------------------------------------------- | ---- |
| Loop early-wake (`wizard.loop.wake`)                | **High** | Med    | WE has uncommitted WIP — needs feature branch + careful staging              | WE   |
| `Get-WizardSessions` cmdlet                          | Med      | Low    | None — pure additive cmdlet                                                  | PS   |
| `tools/wizard/clients/python/wizard_pwsh_client.py` | Med      | Low    | None — additive file; WE adoption is a separate later step                   | PS   |
| `status.extended` / `read.structured` verbs         | Med      | Med    | C# changes; needs build + tests                                              | PS   |
| `Start-WizardManagedTerminal` cmdlet                | Med      | High   | Touches process-launching invariants; wide blast radius if wrong              | PS   |
| Loop snapshot caching (WE-2.1.2)                    | Med      | Low    | Localised refactor in `idle_watch_loop.py`                                   | WE   |
| Loop rate-limit signal (WE-2.1.3)                   | Low      | Low    | Localised                                                                    | WE   |
| DAB symbolic-shortcut tool                          | Low      | Med    | WE — feature branch                                                          | WE   |

### 5.1 First pick

**Ship `Get-WizardSessions` cmdlet + the canonical Python client `wizard_pwsh_client.py`** in this single batch. Rationale:

- **Both are PS-side-only**, additive, zero risk to existing tests/cmdlets, no WE-WIP entanglement.
- **`Get-WizardSessions`** closes the discovery-gap call-out from § 1.3 and § 1.2 row 1 with one cmdlet.
- **`wizard_pwsh_client.py`** establishes the canonical protocol owner. WE can later replace `pwsh_control.py` with `from wizard_pwsh_client import WizardPwshClient` on its own schedule — no coordination needed for the fork ship.
- Ships in one commit, one push, one regression run.

### 5.2 Recommended order after the first pick

1. **`status.extended` + `read.structured` verbs** — closes two more § 1.3 gaps with one C# build cycle. Medium effort.
2. **Loop early-wake** — feature-branch the WE side; add the `wizard.loop.wake` topic + a tiny `Send-WizardLoopWake` cmdlet on the PS side. Highest user-facing win once both halves land.
3. **Loop snapshot caching** — small WE refactor.
4. **`Start-WizardManagedTerminal`** — last because it has the widest blast radius.

### 5.3 Out of scope for this round

- Multi-tab semantics inside one pwsh.exe (DAB-side gap row 6) — uncertain whether PowerShell ever exposes per-tab state to host code; deferred.
- `Wait-WizardSignal` as a friendlier alias for `Read-WizardSignal -WaitMs` — cosmetic; skip until there's a callsite that benefits.

---

## Verification (per pick)

Each implementation phase ends with: `Start-PSBuild` clean (only when C# touched), full Pester regression against all wizard suites (current baseline 77 passing / 1 expected-skip / 1 known timing-flake), `analyze_git_diff`, single-line commit message, push.

The first pick (§ 5.1) ships **without** a build (pure PowerShell + Python additions) — only the run-loop copy step + Pester for the new cmdlet.
