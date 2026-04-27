# Wizard PowerShell — Optimization Plan
_Refreshed 2026-04-27. Tracking branch: `wizard_power_shell` (~16 commits ahead of master)._

Mirror of `C:\Users\Oleh\.claude\plans\please-see-our-custom-purring-piglet.md`. The plan file is the live document; this is the in-repo snapshot for offline readers.

## Context

Extends the fork's existing `WizardControlServer` (named-pipe JSON-RPC, opt-in via `WIZARD_PWSH_CONTROL=1`) into a small **agent runtime**: hook latency absorbed by a warm Python child, build/test output bounded before it hits the model, signals replace OCR polling, bash idioms translated, AI search and AI-contract templates surfaced, and now an `ant`-CLI integration vector.

All new behaviour is gated behind `WIZARD_PWSH_CONTROL=1`. Without that env var the fork behaves exactly like upstream PowerShell.

---

## Status snapshot

| Phase | Subject                                                                          | Commit       |
| ----- | -------------------------------------------------------------------------------- | ------------ |
| 0     | `RESEARCH.md` + `PLAN.md`                                                        | `893d318a`   |
| 1     | UTF-8 + native-error startup hardening                                           | `a5b51441`   |
| 2     | `Microsoft.PowerShell.Wizard` module + `Get-WizardSession`                       | `4a512319`   |
| 3     | `Invoke-Bounded` + `Get-WizardLog`                                               | `11faed36`   |
| 4 (C#)| Signal-channel verbs in `WizardControlServer.cs`                                  | `2381187c`   |
| 4 (PS)| `Publish-/Read-WizardSignal`, `Start-MonitoredProcess`, signal tests             | `e92879eb`   |
| 5     | `Invoke-BashCompat` + `bash`/`sh` aliases under `WIZARD_PWSH_CONTROL`             | `9d878e10`   |
| 7     | AI-search, repo-profile, digest, benchmark cmdlets; legacy plan superseded        | `cde6abfc`   |
| 8     | Repo AI-contract templates + `Install-RepoAIContract.ps1`                         | `123b9fd6`   |
| 11    | `Test-WizardBuildPrereqs` + `USAGE.md`                                            | `eb2546cd`   |
| 11+   | `Use-WizardLock` / `Clear-WizardLock` idempotency sentinel                        | `822c8332`   |
| 12    | Codex parity templates + `wizard-loop-broadcast` skill                            | `1b9b2372`   |
| 11++  | `Set-ClaudeTrust` (pre-marks folders to bypass Claude Code's trust prompt)        | `77599b15`   |
| 6     | Persistent Python hook host (`hook.*` verbs, warm child, NDJSON, latency stats)   | `1c25f753`   |
| 9a-fix| `Install-WizardSettings.ps1` preserves original command + try/catch fallback      | `587b16a1`   |
| 9a    | Live `cognitive_pulse` + `pretool_cache` rewires applied (settings.json)          | _operational, backups at `~/.claude/settings.json.bak-<utc>`_ |
| 9b    | `Install-RepoAIContract` deployed to 8 active repos                                | _operational_ |
| ant   | `Invoke-AntQuery` cmdlet wrapping `ant` (github.com/anthropics/anthropic-cli)     | _pending commit_ |

**Test count**: 64 Pester tests across 11 suites (60-1 expected-skip + 4 new). All wizard suites green.

**Cmdlet count** (export from `Microsoft.PowerShell.Wizard`):
`Get-WizardSession`, `Invoke-Bounded`, `Get-WizardLog`, `Publish-WizardSignal`, `Read-WizardSignal`, `Start-MonitoredProcess`, `Invoke-BashCompat`, `Find-Code`, `Find-Repos`, `Find-CodeAcrossRepos`, `Get-AIContext`, `Get-RepoProfile`, `Invoke-RepoBuild`, `Invoke-RepoTest`, `Update-RepoDigest`, `Measure-RepoSearch`, `Test-WizardBuildPrereqs`, `Use-WizardLock`, `Clear-WizardLock`, `Set-ClaudeTrust`, `Invoke-WizardHook`, `Invoke-AntQuery` (22).

---

## Critical-files cheat sheet

Routine Wizard work touches **only** these files. Anything else — including the 9-10 k-LOC files in `System.Management.Automation/` — is wasted tokens and rebuild time.

### C# (assembly: `Microsoft.PowerShell.ConsoleHost.dll`)

| File | Read this much |
| ---- | -------------- |
| `src/Microsoft.PowerShell.ConsoleHost/host/msh/WizardControlServer.cs` | `HandleRequest()` switch ~line 175. New verbs go between cases ~188-217. `IsEnabled` accessor at top. `SignalEvent` struct after the dispatchers. ~700 LOC. |
| `src/Microsoft.PowerShell.ConsoleHost/host/msh/WizardControlServer.HookHost.cs` (partial) | `HookInvoke` ~line 118 (auto-registers on first invoke). `HookHostManager` nested class. `HookRecord` latency stats. ~470 LOC. |
| `src/Microsoft.PowerShell.ConsoleHost/host/msh/ConsoleHost.cs` (3 188 LOC, **already partial**) | Wizard server start: 1807. Hardening: 1808. PSReadLine guard: 1695. Dispose: 1338. Field decl: 3133. **Do not** add more code here — split into `ConsoleHost.Wizard.cs` if needed. |

### Module (auto-deploys via `<Content Include="..\Modules\Shared\**\*">`)

| File | Purpose |
| ---- | ------- |
| `src/Modules/Shared/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psd1` | Manifest. Update `FunctionsToExport` per phase. |
| `src/Modules/Shared/Microsoft.PowerShell.Wizard/Microsoft.PowerShell.Wizard.psm1` | Loader. Dot-source new `*.ps1`s; add to `Export-ModuleMember`. |
| `src/Modules/Shared/Microsoft.PowerShell.Wizard/*.ps1` | One file per cmdlet. |

### Tests (Pester 5)

`test/powershell/Host/{WizardControl,WizardStartup}.Tests.ps1` and `test/powershell/Modules/Microsoft.PowerShell.Wizard/{GetWizardSession,InvokeBounded,SignalChannel,InvokeBashCompat,WizardLock,SetClaudeTrust,AISearch,HookHost,TestBuildPrereqs}.Tests.ps1`.

### Run-loop (no full build needed for PS-only changes)

1. Edit `.ps1` under `src/Modules/Shared/Microsoft.PowerShell.Wizard/`.
2. `cp` into `src/powershell-win-core/bin/Debug/net11.0/win7-x64/publish/Modules/Microsoft.PowerShell.Wizard/`.
3. `Invoke-Pester -Path test/powershell/Modules/Microsoft.PowerShell.Wizard/<NewSuite>.Tests.ps1`.
4. Once green, `Start-PSBuild -Configuration Debug` to confirm the build glob picks it up too.
5. `analyze_git_diff` → commit.

---

## Anthropic-CLI integration

A separate effort at `C:\Users\Oleh\Documents\GitHub\Antropic\anthropic-cli` is building / spreading a custom version of the Go-based `ant` CLI (the Anthropic API CLI, not Claude Code TUI). Phase ant: ship a Wizard-side `Invoke-AntQuery` cmdlet that wraps `ant messages create`, bounded via Invoke-Bounded, audited via the signal bus. Locates the binary via `-AntPath` / `$env:WIZARD_ANT_PATH` / `Get-Command ant`.

Use case: hooks or skills that need to call Claude programmatically (summarise a stack trace, reformat build output, verify a hypothesis) without spawning a Claude Code TUI. The cmdlet is shipped; the binary itself is installed by the user (`go install github.com/anthropics/anthropic-cli/cmd/ant@latest` or via the parallel custom-build effort).

---

## Pending / deferred

- **Wizard_Erasmus committed work**: `src/mcp/hook_host.py` (warm-host shim) and `ai_wrappers/idle_watch_loop.py` regex fix were written but stayed uncommitted on master because the user has unrelated WIP intermixed. The user owns staging + committing alongside their other in-flight changes.
- **ConsoleHost.Wizard.cs split**: when `WizardControlServer.cs` crosses ~1 000 LOC (Phase 6 pushed it to ~700), break out the next subsystem into a new partial. Same trick available for `ConsoleHost.cs` (already partial since line 42).
- **End-to-end hook-rewire smoke**: there's no automated test that the live `cognitive_pulse` rewire delivers via the warm host (only unit tests of the C# verbs against a stub). Adding one would require launching a wizard pwsh subprocess and triggering a real UserPromptSubmit — heavy. Workaround: ad-hoc verification by inspecting `wizard.ant.query` signal counts / `hook.list` calls field after a normal session.

---

## Verification

After every phase: `Start-PSBuild` clean, then `Invoke-Pester` against the **full** Wizard suite list; never just the new one.

Phase-specific (latest):
- **Phase ant**: `Invoke-AntQuery -Prompt 'hi' -AntPath C:\does\not\exist\ant.exe` throws helpfully (covered in `TestBuildPrereqs.Tests.ps1`).
- **Phase 9a**: open `~/.claude/settings.json`; the `cognitive_pulse` and `pretool_cache` hook commands should be the new two-arm form. To verify warm-host activation, run a normal Claude turn, then in a wizard pwsh: `Send-WizardControlRequest -Payload @{ command='hook.list' }` should show `cognitive_pulse` with `calls > 0`.
- **Phase 9b**: `Get-Item C:\Users\Oleh\Documents\GitHub\Wizard_Erasmus\AGENTS.md` exists and is wizard-managed (`Get-Content … | Select-String 'wizard-managed-block'`).

---

## Out of scope

- Touching `System.Management.Automation` (the engine). Big files there are upstream concerns.
- Changing default cmdlet behaviour outside the env-var-gated startup path. Stays clean against upstream merges.
- Replacing OCR / `dab_*` outright. Phase 4's signals make them less necessary; deciding to deprecate is downstream in WizardErasmus.
- Codex config beyond Phase 12. Codex inherits the system shell; the wizard shim's effects propagate transparently.
