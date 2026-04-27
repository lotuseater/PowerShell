---
name: wizard-loop-broadcast
description: Use to broadcast `/loop 30m /sync-wizard-optimizations` to running, idle Claude instances and self-handoff the current session into a continuation loop. Idempotent via Use-WizardLock — re-running this skill is a no-op once the lock is held.
---

# wizard-loop-broadcast

Broadcasts the Wizard sync prompt to all idle Claude instances except the current one, then self-hands-off the current session so it keeps working after the tab is closed.

## Preconditions

1. The current pwsh.exe is the wizard shim (`Get-WizardSession` reports `WizardControlEnabled=$true`).
2. `mcp__wizard__list_instances` is reachable (WizardErasmus MCP server up).
3. There are no `working` instances the user is actively in — broadcasting to a working instance disrupts them.

## Steps

```powershell
# Step 1 — idempotency lock for the broadcast itself.
$priorBroadcast = Use-WizardLock -Key 'wizard-loop-broadcast' -Note "Phase 10 broadcast at $(Get-Date -Format o)"
if ($priorBroadcast) {
    "skip-broadcast (already done at $($priorBroadcast.AcquiredAt))"
    return
}
```

Then call (via the agent):

```text
$inst = mcp__wizard__list_instances()
$idle = $inst.instances | Where-Object {
    $_.state -in @('idle','sleeping') -and
    $_.id -ne $myInstanceId -and
    $_.project_path                     # skip synthetic empty-path test fixtures
}
foreach ($i in $idle) {
    mcp__wizard__send_to_instance(
        instance_id = $i.id,
        instruction = "/loop 30m /sync-wizard-optimizations"
    )
}
Publish-WizardSignal -Topic 'wizard.broadcast' -Data @{
    at = (Get-Date).ToUniversalTime().ToString('o')
    recipients = ($idle | ForEach-Object id)
    excluded   = $myInstanceId
    prompt     = '/loop 30m /sync-wizard-optimizations'
}
```

## Self-handoff (per user 2026-04-27 directive)

```powershell
$priorSelf = Use-WizardLock -Key "wizard-loop-self-handoff-$($session.Pid)" -Note "Self-handoff for continuation after tab close"
if ($null -eq $priorSelf) {
    # First time — invoke handoff. Use close_original=false to leave the user's tab alone;
    # they close it manually when ready.
    mcp__wizard__terminal_session_handoff(
        loop = true,
        period = 1800,
        max_seconds = 86400,
        close_original = false,
        first = true            # let the tool pick the most-recent matching session
    )
}
# else: already handed off — no-op.
```

## Re-arming

To re-enable a future broadcast (e.g. next time the user wants to spread updates again):

```powershell
Clear-WizardLock -Key 'wizard-loop-broadcast'
Clear-WizardLock -Key "wizard-loop-self-handoff-$PID"
```

## Failure handling

- If `mcp__wizard__terminal_session_handoff` times out (>30s), do NOT retry blindly — it usually means the tool is busy discovering the session. Publish `wizard.broadcast.deferred` with the reason and exit cleanly. The lock keeps the broadcast portion claimed so we don't double-broadcast on the next attempt.
- If `mcp__wizard__list_instances` reports a `working` instance with non-empty `current_task`, **skip it** — broadcasting `/loop` would interrupt the user's active work in that tab.
