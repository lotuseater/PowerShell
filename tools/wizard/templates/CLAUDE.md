# Claude instructions for this repository

> **TL;DR**: Search narrowly. Read sparingly. Bound build/test output. Use the Wizard cmdlets when present.

## Wizard cmdlets (available under the wizard `pwsh.exe`)

- `Find-Code -Pattern '<regex>' -MaxCount 80` — fast, ignore-aware ripgrep wrapper.
- `Get-AIContext -File <path> -StartLine N -Radius 40` — line-numbered slice; streams big files.
- `Invoke-Bounded -FilePath <exe> -ArgumentList @(…) -MaxLines 80 -TimeoutSec 120` — token-bounded process execution; full log on disk.
- `Get-WizardLog -LogPath <path> -Range head:N|tail:N|lines:A-B|grep:PAT` — fetch slices of the log on demand.
- `Get-RepoProfile`, `Invoke-RepoBuild`, `Invoke-RepoTest` — auto-route by detected toolchain.
- `Publish-WizardSignal` / `Read-WizardSignal` — structured event bus over the control pipe.

Fall back to `rg`, `head`, `tail`, etc. when the wizard cmdlets aren't loaded.

## For bug fixes

1. Reproduce or pin down the failing test.
2. `Find-Code` for the relevant symbol. Cap at 50 hits.
3. `Get-AIContext` around the suspect lines. Don't read the full file.
4. Patch.
5. `Invoke-RepoTest -TestPath <narrow>` first; full suite only if the narrow run passes.
6. Summarise the diff in 2-4 lines.

## For architecture questions

- Start with `.ai/repo-map.md` if it exists.
- Then `Find-Code` for entrypoint symbols.
- Read only the files the search points at; never the whole tree.

## Out of scope for AI

- Generated, dependency, build, log, and binary directories listed in `.aiignore`.
- Non-text assets (images, archives, PDFs).
