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

## Still deferred

### `read.structured` control-pipe verb (audit §1.3)

Medium C# effort in `WizardControlServer.cs`. Returns the console
buffer as typed lines instead of flat text. Defer until a concrete
consumer requires structured output — `_build_pwsh_freshness_probe`
+ raw `read` cover the immediate "did anything change" need.

**Verb spec** (so the implementer doesn't have to re-derive it):

Request:
```json
{ "command": "read.structured", "maxLines": 200 }
```

Response:
```json
{
  "status": "ok",
  "lines": [
    { "lineNum": 1, "type": "prompt", "text": "PS C:\\repo>" },
    { "lineNum": 2, "type": "output", "text": "Building..." },
    { "lineNum": 3, "type": "error",  "text": "error CS1234..." }
  ]
}
```

Type tags:
- `prompt` — line ends with `> ` and matches the host's prompt
  function output (or starts with `❯ ` for Claude Code's TUI prompt
  glyph).
- `output` — default classification.
- `error` — written to the stderr stream OR matches a known
  error-line shape (`error \w+:`, `Error:`, `Exception:`).

Drives smarter `IdleWatchLoop` state-classifier behaviour
(distinguishes "agent producing output" from "agent showing the same
prompt as before") without OCR. Ship when a `Start-PSBuild`-capable
session is available.

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
