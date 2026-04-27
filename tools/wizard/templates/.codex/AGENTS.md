# Codex agent instructions (user-level)

> **Place this file at `C:\Users\Oleh\.codex\AGENTS.md`** — it applies globally to every project Codex opens.

## Wizard cmdlets — always available under the wizard pwsh.exe

| Need                                  | Cmdlet                                                                                            |
| ------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Search the repo for code              | `Find-Code -Pattern '<regex>' -MaxCount 80`                                                       |
| Read a slice of a large file          | `Get-AIContext -File <path> -StartLine N -Radius 40`                                              |
| Run any noisy native command bounded  | `Invoke-Bounded -FilePath <exe> -ArgumentList @('a','b') -MaxLines 80 -TimeoutSec 120`            |
| Build / test using the right toolchain | `Invoke-RepoBuild` / `Invoke-RepoTest` (auto-routes by `Get-RepoProfile`)                        |
| Look at the full log                  | `Get-WizardLog -LogPath <path> -Range tail:200`                                                   |

If the cmdlets aren't loaded (`Get-WizardSession` reports `WizardControlEnabled=$false`), the host pwsh isn't the wizard shim — fall back to `rg`, `head`, `tail`, repo-documented test commands.

## Discipline

1. Search before reading. `Find-Code` first.
2. Slice before dumping. `Get-AIContext`, never whole-file dumps for files over 500 lines.
3. Bound long runs. `Invoke-Bounded` for cmake / pytest / npm test / dotnet test.
4. Run the narrowest test first. `Invoke-RepoTest -TestPath <one>` before the whole suite.

## Per-repo overrides

Each repo can ship its own `AGENTS.md` (and `.agents/skills/<name>/SKILL.md`) — those take precedence over this user-level file for that repo. Generate them via:

```powershell
Install-RepoAIContract.ps1 -Path <repo-root>
```

The `Install-RepoAIContract.ps1` script auto-detects whether a repo is upstream (it adds AI files via `.git/info/exclude` so they stay untracked) or local (committed normally).
