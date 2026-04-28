# Loop revision-3/4 — out-of-scope follow-ups

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
- ✅ **Start-WizardManagedTerminal cmdlet** (audit §4.2) —
  one-cmdlet replacement for WizardErasmus's hand-rolled base64-
  encoded `pwsh -EncodedCommand` spawn dance. Spawns via `wt.exe -w
  <window> new-tab` by default, `Start-Process pwsh` with
  `-NewWindow`. Returns `WizardManagedTerminalResult` with `Pid`,
  `Title`, `SessionId`, `Channel`, `Provider`, `Cwd`, `WtWindow`.
  WizardErasmus consumer gates on `WIZARD_USE_MANAGED_TERMINAL_CMDLET`
  (default = on; set to `0` for kill-switch). Falls back silently to
  the legacy in-process spawn on cmdlet failure. Pester test +
  WE-side pytest both green.
- ✅ **`read.structured` control-pipe verb** (audit §1.3, γ3) —
  returns the console buffer as `[{lineNum, type:'prompt'|'output'|
  'error', text}]` so callers can drive smarter classifier behaviour
  without OCR. C# implementation in
  `src/Microsoft.PowerShell.ConsoleHost/host/msh/WizardControlServer.cs`,
  Python client method
  `WizardPwshClient.read_structured(max_lines=200)`, PS-side handle
  method `Connect-WizardPwshSession -Pid X` → `.ReadStructured()`.
  Pester test exercises happy-path + backwards-compat with plain
  `read`.
- ✅ **Build-WizardBoth.ps1 hardening** — `Find-ReleaseLockers` now
  also matches pwsh processes that loaded any DLL from the Release
  publish dir (not just those whose `.Path` IS the Release pwsh.exe).
  Release build retries once on MSB3027 / "is being used by another
  process" race after a second sweep — covers the case where a new
  pwsh session spawns between the pre-publish kill and the file copy.

## Still deferred

(none in this list — pull in audit follow-ups as needed)

## Won't fix per audit §3

### Migrating the team app's file-based JSON IPC to the signal bus

Audit `AUDIT_DAB_LOOP_TEAMAPP_2026-04-28.md` §3 explicitly says:
> The team app itself is "clean, file-based, doesn't need
> wizard-fork changes." Verdict on team app proper: clean,
> file-based, doesn't need wizard-fork changes.

The file-based JSON contract (`{prefix}_cmd.json`, `_resp.jsonl`,
`_events.jsonl`) is the documented public API of the team app and
the source of truth for cross-language interop. Migrating it to the
signal bus would either:
1. Break every existing team-app consumer (status: not acceptable),
2. Or duplicate the file API and the signal bus (status: doubles
   maintenance with no user benefit).

Do not attempt.
