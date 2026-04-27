# PowerShell + WizardErasmus Optimization Plan
_Superseded — see `RESEARCH.md` and `PLAN.md` for the active plan._

This document was an early proposal written before the local PowerShell fork and the WizardErasmus framework were inspected. It contained sound general principles for AI-friendly developer shells (`rg`-based search, line-numbered context slices, bounded build/test output, per-repo `AGENTS.md` / `CLAUDE.md`, `.rgignore` / `.aiignore`, repo digests, search benchmarks). After auditing the local repos, most of those ideas have been adopted and **shipped** into the host process itself rather than as a separate module:

| Original idea                                       | Now in                                                                                         |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `Find-Code` ripgrep wrapper                         | `Find-Code` cmdlet in `src/Modules/Shared/Microsoft.PowerShell.Wizard/`.                       |
| `Find-Repos` / `Find-CodeAcrossRepos`               | Same module.                                                                                   |
| `Get-AIContext` line-numbered slices                | Same module — streams via `[System.IO.File]::ReadLines()` for big files.                       |
| `Get-RepoProfile`                                   | Same module — detects HasSolution / HasBuildPsm1 / HasPyProject / HasCMakeLists / etc.         |
| `Invoke-RepoBuild` / `Invoke-RepoTest`              | Same module — both pipe through `Invoke-Bounded` so default output is bounded.                 |
| `Update-RepoDigest`                                 | Same module — writes `.ai/repo-map.md` from `git ls-files`.                                    |
| `Measure-RepoSearch`                                | Same module — `rg` vs PS-recursion benchmark.                                                  |
| `Invoke-CompactCommand`                             | **Replaced by** `Invoke-Bounded`, which writes the full log to disk and returns head + tail + log path + timeout/kill semantics — strictly more useful for agent contexts.                                              |
| `.rgignore` / `.aiignore`                           | Templates under `tools/wizard/templates/` (Phase 8).                                           |
| Per-repo `AGENTS.md` / `CLAUDE.md` + skills         | Templates under `tools/wizard/templates/` (Phase 8); deployed by `Install-RepoAIContract.ps1`. |
| Token-budget table                                  | Enforced implicitly by cmdlet defaults (16 KB, 80 lines).                                      |
| PowerShell perf rules                               | Folded into `docs/wizard/USAGE.md` (Phase 11).                                                 |
| Local-only AI files for upstream forks              | Honoured by `Install-RepoAIContract -RepoType Upstream` (Phase 8).                             |

What this fork **does** that the original proposal did not:

- A built-in `WizardControlServer` named-pipe JSON-RPC surface (opt-in via `WIZARD_PWSH_CONTROL=1`) for agent-driven control. Verbs include `read`/`write`/`interrupt` on the live console plus a structured `signal.publish/subscribe/list/clear` bus that lets hooks emit JSON events instead of OCR-able text, replacing `dab_wait_idle`-style polling.
- Startup hardening (UTF-8 console + `$PSNativeCommandUseErrorActionPreference = $true` + PSReadLine guard) so bash-trained agents don't trip on Windows console quirks.
- `Invoke-BashCompat` plus opt-in `bash`/`sh` aliases that translate the most common bash idioms (`&&`, `||`, `head -n`, `tail -n`, `grep`, `2>&1`, `cd && …`) to PowerShell. Anything outside the supported subset publishes `wizard.bashcompat.unsupported` and falls through to a real `bash.exe` if present.
- A planned persistent Python hook host (`hook.register/invoke/list/unregister` verbs) so the ~14 `& py -3.14 hook.py` cold-spawns per turn collapse into one warm child for the lifetime of the shell. _(Phase 6 in `PLAN.md`.)_

The retained framing from the original doc — **search narrowly, read sparingly, patch deliberately** — still applies, and is reflected in the cmdlet defaults (`-MaxCount 120`, `-Radius 40`, etc.).

For the live, ordered work plan, read `docs/wizard/PLAN.md`. For the underlying findings (what the fork looked like before this work and what friction motivated it), read `docs/wizard/RESEARCH.md`. For env vars, signal topics, cmdlet reference and troubleshooting, read `docs/wizard/USAGE.md` once Phase 11 ships.
