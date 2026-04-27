# Wizard PowerShell — Research Findings

_Snapshot date: 2026-04-27. Branch: `wizard_power_shell`._

This document records what we observed on this Windows 11 PC about the way Claude Code, Codex, and the WizardErasmus framework interact with PowerShell, and why that motivates the changes planned in [`PLAN.md`](./PLAN.md).

---

_See `PLAN.md` for the live phase ↔ commit map. This file captures the **findings** that motivated the plan; once a phase ships, it stops being "research" and moves to the plan / USAGE._

## 1. Current state of the fork (snapshot 2026-04-27 start of work)

- **Branch**: `wizard_power_shell`, 3 local commits past `master`, working tree clean.
- The fork has since shipped 22 Wizard cmdlets and ~16 commits (see `PLAN.md` for the running map). The list below is the **starting** state — preserved as historical context for why the work began.
- **Local commits** (newest first):
  - `c604643a` — `fix(consolehost): start wizard control before commands`. Re-orders startup so the named-pipe server is listening before runspace init / first prompt. Prevents a race where an external client could connect before the server bound.
  - `829b3e0c` — `chore(wizard): add controlled pwsh rollout helper`. Adds `tools/wizard/Install-WizardPwsh.ps1` (≈240 lines): writes a `wizard-pwsh.cmd` shim into `%USERPROFILE%\bin\`, optionally compiles a small `pwsh.exe` wrapper that sets `WIZARD_PWSH_CONTROL=1`, and optionally rewrites Windows Terminal's default profile to use the shim. Has rollback.
  - `2f117c58` — `feat(consolehost): add wizard control pipe`. Core feature: `WizardControlServer.cs` (≈491 lines). Opt-in JSON-RPC named-pipe server (`\\.\pipe\wizard-pwsh-{PID}` by default). Verbs: `hello`, `status`, `read` (capture native console), `write` (send input), `interrupt` (kill running pipeline). Activated by `WIZARD_PWSH_CONTROL=1`. Session metadata is persisted to `%LOCALAPPDATA%\WizardPowerShell\sessions\{PID}.json`.
- **Tests**: `test/powershell/Host/WizardControl.Tests.ps1` (66 lines) covers the original control verbs.
- **Customization theme**: pure agent-control surface. No cmdlet-behaviour changes, no formatting changes, no parser changes. Stays clean against upstream.

The fork ships the right primitive (an in-process server that's up before the prompt) but currently uses it only as a remote-control surface. We can extend it into a shared agent-runtime fabric without breaking that property.

---

## 2. Agent-side surface on this PC

Where shell I/O actually gets consumed.

### 2.1 Claude Code — `C:\Users\Oleh\.claude\settings.json`

- 390 lines. Effort `xhigh`. Auto-permission and dangerous-mode prompts skipped. Voice input on (`hold`).
- 107 explicit allow rules (broad Bash / PowerShell / Python / git patterns).
- `additionalDirectories` includes `Wizard_Erasmus`, `Serial_to_Google_Doc`, and home.
- **All 14+ command-shell hooks pin `"shell": "powershell"`** and call `& py -3.14 'C:\…\hook.py'`.

### 2.2 Hooks — ≈28 declared

Implementations live under `C:\Users\Oleh\Documents\GitHub\Wizard_Erasmus\src\mcp\` (≈61 k LOC of Python across ~50 files).

| Event             | Notable hooks                                                                                                                                                            |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| UserPromptSubmit  | `cognitive_pulse_hook.py` (1 412 LOC, 8 s budget), `claude_route_hint_hook`, `skill_route_hint_hook`, `large_file_slicing_hint_hook`                                     |
| PreToolUse        | `commit_guard`, `bash_bloat_guard`, `commit_msg`, `pretool_cache`, `edit_progress`                                                                                       |
| PostToolUse       | `visual_verify_hook` (12 s OCR), `session_tracker`, `syntax_check`, `edit_quality`, `posttool_cache`, `edit_invalidate`, `error_recall`, `error_triage`, `error_memory`, `bash_chain`, `grep_prefetch` |
| Stop              | `test_guard`, `premature_stop`, `flaky_dismissal_guard`, `caveat_hedge`, `claude_quota_handoff` (5 sequential)                                                           |
| PreCompact        | `claude_precompact`, `claude_quota_handoff`                                                                                                                              |
| SessionStart      | `session_start_hook`                                                                                                                                                     |

Aggregate cost per turn (declared timeouts, not measured): UserPromptSubmit ≈23 s budget, PostToolUse easily 20-30 s on Bash, Stop chain 25-40 s. Each fire is a fresh `powershell` → `& py -3.14 hook.py` cold spawn.

### 2.3 WizardErasmus — `C:\Users\Oleh\Documents\GitHub\Wizard_Erasmus`

- C++23 core (`build/wizard_erasmus.exe`) + Python 3.14 MCP server (`src/mcp/wizard_mcp_server.py`).
- MCP entry points (`.mcp.json`): `wizard-codex-rollout` (Python `codex_bridge_server.py`) and `serena`.
- Tool surface (`mcp__wizard__*`): DAB desktop automation (`dab_screenshot`, `dab_click`, `dab_send_keys`, …), VS Code control (`vscode_terminal_run`, `vscode_launch_claude`, …), instance management (`create_instance`, `read_instance_output`, …), cognitive (`cognitive_pulse`, `recall_memories`, …), build/test (`smart_build`, `smart_test`, `smart_lint`, `smart_format`, `error_diagnosis`), terminal sessions, prolog, memory, magichat.
- State: SQLite at `.wizard_erasmus.sqlite`, project graph at `.wizard_project_graph.db`.
- Already consumes the fork: `C:\Users\Oleh\Documents\PowerShell\profile.ps1` routes the bare `claude` command through `Wizard_Erasmus/src/mcp/claude_cli_wrapper.py` (kill-switch `WIZARD_CLAUDE_ROUTE_V2`).

### 2.4 Codex — `C:\Users\Oleh\.codex\`

- `config.toml` is sparse — no shell pinning. Inherits the system shell on Windows.
- `history.jsonl` ≈518 KB on the snapshot date.
- Codex hooks **are not** present in `.codex` — all hooks are centralised in `C:\Users\Oleh\.claude\settings.json` and execute via the same PowerShell + Python path.

---

## 3. Conversation patterns (3 most-recent JSONL transcripts)

Across the three latest sessions on this PC (`Wizard-Erasmus-src-team-app`, `C--Users-Oleh`, `Serial-to-Google-Doc-topdown`):

| Keyword       | Mentions | Reading                                          |
| ------------- | -------: | ------------------------------------------------ |
| `compile`     |      324 | Heavy C++ rebuild loops in WizardErasmus.        |
| `bash`        |      276 | Agents prefer bash idioms even on Windows.       |
| `error`       |       69 |                                                  |
| `hang`        |       68 | **Major friction**: long builds stall terminals. |
| `test`        |       57 |                                                  |
| `build`       |       45 |                                                  |
| `cmake`       |       27 |                                                  |
| `shell`       |       23 |                                                  |
| `powershell`  |       19 |                                                  |
| `ps1`         |       19 |                                                  |
| `timeout`     |       17 | Builds blowing 120 s smart-tool budget.          |
| `terminal`    |       15 |                                                  |
| `pytest`      |       14 |                                                  |
| `failed`      |        6 |                                                  |
| `stuck`       |        6 | Impasse-detection trips.                         |
| `wait`        |        6 |                                                  |
| `encoding`    |        3 | Mojibake / UTF-8 incidents.                      |
| `utf`         |        3 |                                                  |
| `quoting`     |        3 | PowerShell escape bugs.                          |

---

## 4. Friction signals (what hurts, concretely)

| Signal                                  | Evidence                                                     | Root cause                                                                       |
| --------------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| ~14 cold Python spawns per turn         | Every `& py -3.14 hook.py` in `settings.json`                | No persistent hook host; each fire re-imports `wizard_mcp.*`.                    |
| Long build output consumed verbatim     | `cmake`, `ninja`, `pytest` runs through `smart_build/test`   | Output streamed straight back to the model. No bounded-output channel.           |
| Hangs on long I/O                       | 324 `compile` ↔ 68 `hang`                                    | No budget-bounded `Start-MonitoredProcess`; `dab_wait_idle` polls blindly.       |
| Bash-idiom parser errors                | Agents emit `cmd1 && cmd2`, `head -n`, `2>&1` pipelines      | PS 5.1 has no `&&`; PS 7's `2>&1` on native exes wraps stderr poorly.            |
| Mojibake / UTF-8 corruption             | 3 explicit incidents; non-ASCII paths in build output        | Console code page defaults to cp1252; no startup normalisation.                  |
| Backslash-escape bugs in hook configs   | Double-backslash visible in `settings.json` hook strings     | `& py -3.14 'C:\\path\\hook.py'` is fragile around spaces or repath.             |
| WizardControlServer underused           | Only `read`/`write`/`interrupt`/`status`/`hello`             | No verb for hooks to publish structured signals; agents fall back to OCR.        |

---

## 5. Token-cost hot spots (visible in code)

In rough order of likely cost:

1. **`cognitive_pulse_hook.py`** — 1 412 LOC, fires every UserPromptSubmit, injects the `<cognitive-pulse-hook>` block straight into the prompt. Highest single source of recurring tokens.
2. **`visual_verify_hook.py`** — OCR after every Bash / `dab_*` / `smart_*` / `vscode_terminal*` postcall (12 s budget). Captures the screen and posts text-form results.
3. **Stop guard chain** — 5 sequential guards on every Stop event; even when one blocks, the others have already consumed tokens.
4. **PowerShell preamble × 14** — each `& py -3.14 hook.py` invocation pays Python startup + module imports (`wizard_mcp.*` is heavy).
5. **`session_tracker_hook.py`** — fires on every `mcp__wizard__*`, `Edit`, `Write`, `Bash`. High-frequency, even when nothing useful changes.
6. **`error_memory` / `error_triage` / `error_recall`** — fire on every Bash/`smart_build`/`smart_test`. Memory lookups + hypothesis generation.

---

## 6. Why the fork is the right place to fix this

Two of the three layers we want require the fix to be running **before the first command**:

- A persistent hook host has to be alive before `cognitive_pulse_hook` fires on UserPromptSubmit.
- A signal bus has to be reachable from inside the same process that will run the hook.
- Bash-idiom translation and bounded-execution wrappers can technically live in a profile module — but the user already pays for one of those (`profile.ps1`) and it doesn't cover hook-shell invocations, which run with `-NoProfile`.

The fork already arranged the right starting condition (`WizardControlServer` boots before runspace init, commit `c604643a`). Extending that boot path is the minimum-friction surface for the changes we want.

---

## 7. Sources

- `C:\Users\Oleh\Documents\GitHub\PowerShell\src\Microsoft.PowerShell.ConsoleHost\host\msh\WizardControlServer.cs`
- `C:\Users\Oleh\Documents\GitHub\PowerShell\src\Microsoft.PowerShell.ConsoleHost\host\msh\ConsoleHost.cs`
- `C:\Users\Oleh\Documents\GitHub\PowerShell\tools\wizard\Install-WizardPwsh.ps1`
- `C:\Users\Oleh\Documents\GitHub\PowerShell\test\powershell\Host\WizardControl.Tests.ps1`
- `C:\Users\Oleh\.claude\settings.json`
- `C:\Users\Oleh\.claude\rules\cognitive-tools.md`, `no-premature-stop.md`
- `C:\Users\Oleh\.claude\projects\*\*.jsonl` (3 most-recent sessions)
- `C:\Users\Oleh\Documents\GitHub\Wizard_Erasmus\src\mcp\` (hook scripts, MCP server)
- `C:\Users\Oleh\Documents\GitHub\Wizard_Erasmus\.mcp.json`
- `C:\Users\Oleh\.codex\config.toml`, `.codex\history.jsonl`
- `C:\Users\Oleh\Documents\PowerShell\profile.ps1`
