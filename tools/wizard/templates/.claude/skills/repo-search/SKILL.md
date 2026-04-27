---
name: repo-search
description: Use when searching this repository for symbols, TODOs, errors, features, or implementation locations. Prefer this skill over broad file reads or recursive listings.
---

# repo-search

Use `Find-Code` first. Cap matches at 80-120. Then read only the relevant snippets with `Get-AIContext`.

```powershell
Find-Code -Pattern 'CLASS_NAME' -MaxCount 50
Get-AIContext -File <hit-path> -StartLine <hit-line> -Radius 30
```

Do not search dependency, generated, build, coverage, log, binary, or artefact directories — they are excluded by `.rgignore`.
