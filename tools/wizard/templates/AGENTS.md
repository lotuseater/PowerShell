# Agent instructions for this repository

> **TL;DR**: Search narrowly. Read sparingly. Bound build/test output. Use the Wizard cmdlets when present.

## Wizard cmdlets (available when running under `pwsh.exe` from the wizard fork)

| Need                                  | Cmdlet                                                                                            |
| ------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Search the repo for code              | `Find-Code -Pattern '<regex>' -MaxCount 80`                                                       |
| Read a slice of a large file          | `Get-AIContext -File <path> -StartLine N -Radius 40`                                              |
| Run any noisy native command bounded  | `Invoke-Bounded -FilePath <exe> -ArgumentList @('a','b') -MaxLines 80 -TimeoutSec 120`            |
| Build / test using the right toolchain | `Invoke-RepoBuild` / `Invoke-RepoTest` (auto-routes by `Get-RepoProfile`)                        |
| Look at the full log of a bounded run | `Get-WizardLog -LogPath <path> -Range tail:200`                                                   |
| Watch a long-running process          | `Start-MonitoredProcess` + `Read-WizardSignal -Topic process.<exe>`                               |

If those cmdlets aren't present, fall back to: `rg`, line-numbered `head/tail/sed`, the repo's documented test command.

## Repository map

- `src/` — production code.
- `test/` — tests.
- `docs/` — design notes.
- `.ai/repo-map.md` — auto-generated repo digest (refresh with `Update-RepoDigest`).

## Workflow

1. **Search before reading.** `Find-Code` or `rg` first; never `Get-ChildItem -Recurse | Select-String`.
2. **Slice before dumping.** `Get-AIContext` or `Read -offset` rather than reading whole multi-thousand-line files.
3. **Bound long runs.** `Invoke-Bounded` for cmake / ninja / pytest / npm test / dotnet test. Read the full log on demand with `Get-WizardLog`.
4. **Run the narrowest test first.** `Invoke-RepoTest -TestPath <one>` before the whole suite.
5. **Summarise diffs as `git diff --unified=2`** unless debugging merge-sensitive code.

## Token rules

- Skip generated dirs, dependency dirs, build artefacts, logs, binary assets — see `.aiignore`.
- Prefer line-numbered snippets over full-file reads.
- Default per-task budgets: 120 search hits, 120-line snippets, 160-line test summaries, 2-line diff context, 200-line repo map.
