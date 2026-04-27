# Wizard PowerShell — Python client

Canonical Python binding for the wizard PowerShell control pipe protocol. This is the source of truth — replaces hand-rolled marshalling that used to live downstream (e.g. in `Wizard_Erasmus/ai_wrappers/pwsh_control.py`).

## Install

The client is a single self-contained file. Two ways to consume:

**Direct copy / vendor**:

```bash
cp tools/wizard/clients/python/wizard_pwsh_client.py path/to/your/project/
```

**Or symlink in development**:

```bash
ln -s "$(realpath tools/wizard/clients/python/wizard_pwsh_client.py)" path/to/your/project/
```

Then in Python:

```python
from wizard_pwsh_client import WizardPwshClient, list_sessions
```

## Dependencies

- Windows + `pywin32` (`pip install pywin32`) for named-pipe access.
- Linux/macOS: not yet supported (wizard fork is Windows-first).

## Usage

### Enumerate live sessions

```python
from wizard_pwsh_client import list_sessions

for s in list_sessions():
    print(f"PID {s.pid:>6}  {s.cwd}  pipe={s.pipe_name}")
```

Mirrors the PowerShell `Get-WizardSessions` cmdlet. Stale entries (PID gone) are excluded by default; pass `include_stale=True` to see them.

### Talk to a specific session

```python
from wizard_pwsh_client import WizardPwshClient

with WizardPwshClient(pid=12345) as client:
    status = client.status()
    print(status["runspaceState"], status["windowTitle"])

    client.write("Get-Date\n", submit=True)
    latest = client.read(max_lines=20)
    print(latest["text"])

    # Signal bus
    client.publish_signal("agent.heartbeat", {"alive": True})
    events = client.read_signal("agent.heartbeat", since=0, limit=10)

    # Hook host
    client.warmup_hooks(["cognitive_pulse", "pretool_cache"])
    result = client.invoke_hook("cognitive_pulse", payload={"prompt": "..."})
```

### Resolution order

If `WizardPwshClient` is constructed without a `pid` or `pipe_name`, it reads `WIZARD_PWSH_CONTROL_PIPE` from the environment. Otherwise the pipe path is `\\.\pipe\wizard-pwsh-{pid}`.

## Errors

`WizardPwshError` is raised on transport failures (pipe closed, JSON malformed, server timeout). The server itself signals errors via `{"status": "error", "error": "<code>", ...}` reply objects — those are returned as ordinary dicts so the caller can branch on `reply["status"]`.

## Versioning

The control-pipe protocol version is reported by `WizardPwshClient.hello()["protocol"]`. The fork ships protocol version `1`. Future incompatible changes will bump this.
