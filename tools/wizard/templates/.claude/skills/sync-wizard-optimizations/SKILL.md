---
name: sync-wizard-optimizations
description: Body of the recurring loop that propagates the Wizard PowerShell optimizations across this Claude instance. Use to verify the agent runtime is live, run the relevant tests for this repo, and report deltas vs. the previous loop tick.
---

# sync-wizard-optimizations

This skill is the per-tick body that `/loop 30m /sync-wizard-optimizations` runs in each broadcasted Claude instance.

## Steps

1. **Confirm the runtime is live**
   ```powershell
   $session = Get-WizardSession
   $session | Format-List Pid, WizardControlEnabled, HookHostStatus, ConsoleEncoding, NativeErrorPreference
   ```
   If `WizardControlEnabled` is `$false`, the host pwsh.exe isn't the wizard shim — bail out and tell the user.

2. **Pull recent signals** since the last tick. Read `wizard.broadcast.lastTick` from `%LOCALAPPDATA%\WizardPowerShell\loop-state.json` if present; otherwise `since=0`.
   ```powershell
   Read-WizardSignal -Topic process.* -Since $lastTick -Limit 100
   Read-WizardSignal -Topic cognitive.pulse -Since $lastTick -Limit 20
   ```

3. **Run the right test for this repo**
   ```powershell
   $repo = Get-RepoProfile
   if ($repo.HasBuildPsm1 -and $repo.HasPesterTests) {
       $r = Invoke-RepoTest -Kind Pester -Quiet
   } elseif ($repo.HasCMakeLists) {
       $r = Invoke-RepoTest -Kind Python -Quiet  # WizardErasmus uses pytest
   } else {
       $r = Invoke-RepoTest -Quiet
   }
   ```

4. **Acknowledge the broadcast** so the originator can audit liveness:
   ```powershell
   Publish-WizardSignal -Topic wizard.broadcast.ack -Data @{
       instance = $session.Pid
       repo     = $repo.Root
       exitCode = $r.ExitCode
       tail     = $r.Tail
       at       = (Get-Date).ToUniversalTime().ToString('o')
   }
   ```

5. **Report deltas** in 3-5 lines: `signal counts, test exit code, anything new since previous tick`. Save the cursor to `loop-state.json` for the next tick.

## Self-relaunch idempotency

If this loop body decides to **re-launch the current session** (e.g. swap models or change project), gate it through a Wizard lock so a runaway loop can't fire the same handoff dozens of times:

```powershell
$prior = Use-WizardLock -Key "loop-relaunch-$($session.Pid)" -Note "Phase 10 self-handoff at $(Get-Date -Format o)"
if ($null -eq $prior) {
    # Lock acquired — first time. Do the relaunch.
    # mcp__wizard__terminal_session_handoff(session_id=current, loop=true, period=1800, close_original=true)
} else {
    # Already done at $($prior.AcquiredAt) by PID $($prior.AcquiredBy). Skip.
    "skip-self-relaunch (already handed off at $($prior.AcquiredAt))"
}
```

To re-arm after a deliberate stop, the user runs `Clear-WizardLock -Key loop-relaunch-<pid>`.

## Stop conditions

- Test passes & no new error signals → silent ack and continue.
- Test fails for the first time → annotate the broadcast ack with `failureFirstSeenAt` and surface the failing log path.
- Three consecutive failed ticks → publish `wizard.loop.escalate` and stop the loop with a one-line message to the user.
