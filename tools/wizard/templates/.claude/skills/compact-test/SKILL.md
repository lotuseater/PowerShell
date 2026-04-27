---
name: compact-test
description: Use when running the repository's tests or build. Bounds output so the model context isn't drowned by passing-test noise or build chatter.
---

# compact-test

```powershell
$r = Invoke-RepoTest -TestPath <narrow-path>     # auto-routes to Pester / dotnet test / pytest / npm test
$r | Format-List ExitCode, TotalLines, TruncatedLines, KilledByTimeout, LogPath
```

If the run fails:

```powershell
Get-WizardLog -LogPath $r.LogPath -Range 'grep:[Ee]rror|FAIL|Traceback'
Get-WizardLog -LogPath $r.LogPath -Range 'tail:200'
```

The full output stays on disk; only head + tail come back to the model. Don't pipe raw test output into context.
