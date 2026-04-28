# Loop revision-3 — out-of-scope follow-ups

This file tracks the deferred items from the WizardErasmus loop
revision-3 cleanup (`docs/wizard/AUDIT_DAB_LOOP_TEAMAPP_2026-04-28.md`).
Updated 2026-04-29.

## Done since revision 3 shipped

- ✅ **Connect-WizardPwshSession cmdlet** — handle wrapper around
  `Get-WizardSessions` + `Send-WizardControlRequest` so callers stop
  passing `-PipeName` to every verb. Auto-resolves from `-Pid`,
  `-PipeName`, `-CwdMatch`, or `WIZARD_PWSH_CONTROL_PIPE`. Exposes
  `Send`, `Status`, `StatusExtended`, `Read`, `Write`, `Interrupt`,
  `Publish`, `ReadSignal`, `Wake` script-methods. Pester tested.
- ✅ **DAB symbolic-shortcut helper** — WizardErasmus side. New
  `KEYBOARD_SHORTCUT_BY_NAME` map and `dab_send_keyboard_shortcut`
  in `ai_wrappers/_dab_bridge.py`. Skill authors use names
  (`reverse_search`, `clear_line`, `history_menu`, `cancel`,
  `tab_complete`, `submit`, `interrupt`, `eof`, `exit_plan_mode`,
  ...) instead of raw vkey codes.
- ✅ **embed_service.py idle watchdog → signal bus** — replaces the
  bare `time.sleep(60)` in `_idle_watchdog` with chunked
  `read_signal("wizard.embed.activity", waitMs=60000)` polling
  through the parent wizard pwsh pipe. Falls back to plain sleep when
  the pipe is unreachable. External callers can now wake / hold off
  the shutdown by publishing to the topic.

## Still deferred

- **Start-WizardManagedTerminal cmdlet** (audit §4.2). High effort,
  widest blast radius — would replace WizardErasmus's hand-rolled
  base64-encoded `pwsh -EncodedCommand` spawn dance with one cmdlet.
  Defer until at least three other rev-3 wirings have soaked in
  production for ≥1 week with no regressions.
- **`read.structured` control-pipe verb** (audit §1.3). Medium C#
  effort. Returns the console buffer as `[{lineNum, type, text}]`
  instead of flat text. Loop's freshness probe + raw `read` cover the
  immediate need; defer until a concrete consumer requires structured
  output.
- **Migrating the team app's file-based JSON IPC to the signal bus**
  (audit §3 explicitly says the team app is fine as-is). Do not
  attempt — the file-based contract is the documented public API.

## Removed from the deferred list

- ~~`Connect-WizardPwshSession`~~ — shipped.
- ~~DAB `send_keyboard_shortcut_by_name`~~ — shipped (called
  `dab_send_keyboard_shortcut` on the Python side).
- ~~Hook host adoption for `embed_service.py`~~ — different scope; the
  signal-bus wakeable watchdog landed instead, which addresses the
  same "kill the bare sleep" intent without re-architecting the
  service to host inside a PowerShell hook host.
