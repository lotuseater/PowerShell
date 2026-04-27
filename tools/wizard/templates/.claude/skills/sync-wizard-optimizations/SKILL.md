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

## Stop conditions

- Test passes & no new error signals → silent ack and continue.
- Test fails for the first time → annotate the broadcast ack with `failureFirstSeenAt` and surface the failing log path.
- Three consecutive failed ticks → publish `wizard.loop.escalate` and stop the loop with a one-line message to the user.
