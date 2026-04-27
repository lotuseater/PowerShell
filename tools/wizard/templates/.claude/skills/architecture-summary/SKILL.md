---
name: architecture-summary
description: Use when answering "how does this repo work?" or "where would I add feature X?" Reads the repo map and entry points instead of dumping files.
---

# architecture-summary

1. Refresh / read the digest:
   ```powershell
   Update-RepoDigest | Out-Null
   Get-Content .ai/repo-map.md
   ```
2. Find entry points by searching for `main`, top-level `Program.cs`, package entrypoints:
   ```powershell
   Find-Code -Pattern '(static\s+void\s+Main|^def\s+main|"main"\s*:)' -MaxCount 30
   ```
3. Read targeted slices around hits with `Get-AIContext -Radius 30`.
4. Summarise in 5-8 lines: top-level dirs, build/test commands, key entry points, notable abstractions.
