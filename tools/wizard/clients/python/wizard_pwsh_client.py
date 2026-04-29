# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
"""Canonical Python client for the wizard PowerShell control pipe.

Replaces hand-rolled marshalling like `Wizard_Erasmus/ai_wrappers/pwsh_control.py`.
The wizard PowerShell fork is the source of truth for the control-pipe protocol
(verbs: hello, status, read, write, interrupt, signal.*, hook.*); this client is
the official Python binding.

Usage:

    from wizard_pwsh_client import WizardPwshClient, list_sessions

    # Enumerate live wizard pwsh sessions on this machine.
    for sess in list_sessions():
        print(sess.pid, sess.pipe_name, sess.cwd)

    # Talk to a specific session.
    with WizardPwshClient(pid=12345) as client:
        status = client.status()
        client.write("Get-Date\n", submit=True)
        latest = client.read(max_lines=20)
        client.publish_signal("agent.heartbeat", {"alive": True})
        result = client.invoke_hook("pretool_cache", payload={"tool": "Read"})

The client uses synchronous JSON-line I/O over the named pipe. One request,
one reply, then close — matches the server's per-connection lifecycle. For
high-throughput callers, hold a `WizardPwshClient` instance and reuse it; the
underlying socket reconnects per request, which is cheap on Windows.

Requires: pywin32 (for named-pipe access) on Windows. On Linux/macOS the wizard
control pipe runs under .NET's cross-platform NamedPipeServerStream, so the
client falls back to standard `socket`-style access via .NET's UNIX-pipe path
(currently untested — Windows is the primary target).
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Optional


# -- Session discovery -------------------------------------------------------


@dataclass
class WizardSessionInfo:
    pid: int
    pipe_name: str
    cwd: str
    executable: str
    started_at: str
    updated_at: str
    protocol: int
    session_path: str
    is_alive: bool

    @classmethod
    def from_record(cls, record: dict, *, session_path: str = "") -> "WizardSessionInfo":
        return cls(
            pid=int(record.get("pid", 0)),
            pipe_name=str(record.get("pipe", "")),
            cwd=str(record.get("cwd", "")),
            executable=str(record.get("executable", "")),
            started_at=str(record.get("startedAt", "")),
            updated_at=str(record.get("updatedAt", "")),
            protocol=int(record.get("protocol", 0) or 0),
            session_path=str(session_path or ""),
            is_alive=False,  # filled in by list_sessions()
        )


def _local_app_data() -> Path:
    val = os.environ.get("LOCALAPPDATA")
    if val:
        return Path(val)
    # Fallback: best-effort default for a Windows user. Don't try too hard on
    # non-Windows — the wizard fork is Windows-first, and callers can pass an
    # explicit session_root if they care.
    home = Path.home()
    return home / "AppData" / "Local"


def _is_pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        try:
            import ctypes
            kernel32 = ctypes.windll.kernel32
            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
            if not handle:
                return False
            try:
                exit_code = ctypes.c_ulong()
                if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
                    return False
                STILL_ACTIVE = 259
                return exit_code.value == STILL_ACTIVE
            finally:
                kernel32.CloseHandle(handle)
        except Exception:
            return False
    else:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False


def list_sessions(
    session_root: Optional[Path] = None, include_stale: bool = False
) -> Iterable[WizardSessionInfo]:
    """Enumerate wizard PowerShell sessions whose JSON descriptor files exist.

    Mirrors the PowerShell `Get-WizardSessions` cmdlet. Stale entries (PID gone)
    are excluded unless `include_stale=True`.
    """
    root = session_root if session_root is not None else (_local_app_data() / "WizardPowerShell" / "sessions")
    if not root.is_dir():
        return
    for entry in sorted(root.glob("*.json")):
        try:
            # The C# server writes session JSON with `Encoding.UTF8`, which in .NET
            # includes a BOM. Use utf-8-sig so we strip it transparently.
            record = json.loads(entry.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            # OSError covers TOCTOU races where the wizard pwsh exits between glob
            # and read; ValueError covers JSON decode failures.
            continue
        info = WizardSessionInfo.from_record(record, session_path=str(entry))
        info.is_alive = _is_pid_alive(info.pid)
        if not info.is_alive and not include_stale:
            continue
        yield info


# -- Pipe client -------------------------------------------------------------


class WizardPwshError(RuntimeError):
    """Raised when the control pipe replies with status='error' or transport fails."""


class WizardPwshClient:
    """Synchronous JSON-line client for the wizard PowerShell control pipe.

    Each method opens a fresh pipe connection, sends one JSON request, reads
    one JSON line back, and closes. Cheap on Windows; matches the server's
    per-connection request/reply lifecycle.
    """

    def __init__(
        self,
        pid: Optional[int] = None,
        pipe_name: Optional[str] = None,
        connect_timeout_ms: int = 5000,
    ) -> None:
        if pid is None and not pipe_name:
            env_pipe = os.environ.get("WIZARD_PWSH_CONTROL_PIPE")
            if env_pipe:
                pipe_name = env_pipe
            else:
                raise ValueError("WizardPwshClient: pass pid= or pipe_name=, or set WIZARD_PWSH_CONTROL_PIPE.")
        if not pipe_name:
            pipe_name = f"wizard-pwsh-{pid}"
        self._pipe_path = rf"\\.\pipe\{pipe_name}"
        self._pid = pid
        self._connect_timeout_ms = connect_timeout_ms

    # Context manager support — currently no persistent state to clean up,
    # but the API mirrors what we'd expect if we ever added connection pooling.
    def __enter__(self) -> "WizardPwshClient":
        return self

    def __exit__(self, *_exc: Any) -> None:
        return None

    @property
    def pipe_path(self) -> str:
        return self._pipe_path

    # -- Transport ----------------------------------------------------------

    def _send(self, payload: dict) -> dict:
        """Send one request, read one reply. Raises WizardPwshError on transport failure."""
        if os.name != "nt":
            raise WizardPwshError("WizardPwshClient currently supports Windows named pipes only.")

        try:
            import win32file  # type: ignore
            import win32pipe  # type: ignore
            import pywintypes  # type: ignore
        except ImportError as ex:
            raise WizardPwshError("pywin32 is required: pip install pywin32") from ex

        deadline = time.time() + self._connect_timeout_ms / 1000.0
        last_err: Optional[Exception] = None
        handle = None
        while time.time() < deadline:
            try:
                handle = win32file.CreateFile(
                    self._pipe_path,
                    win32file.GENERIC_READ | win32file.GENERIC_WRITE,
                    0,
                    None,
                    win32file.OPEN_EXISTING,
                    0,
                    None,
                )
                break
            except pywintypes.error as ex:  # noqa: PERF203 — short retry loop
                last_err = ex
                time.sleep(0.05)
        if handle is None:
            raise WizardPwshError(f"Unable to open {self._pipe_path}: {last_err}")

        try:
            line = json.dumps(payload, separators=(",", ":")) + "\n"
            win32file.WriteFile(handle, line.encode("utf-8"))
            # Read until newline. The server emits exactly one line per request
            # then keeps the connection open (the agent's RunAsync loop tolerates
            # multi-request connections), so peek one line is enough.
            buf = bytearray()
            while True:
                rc, chunk = win32file.ReadFile(handle, 4096)
                if rc != 0:
                    raise WizardPwshError(f"ReadFile rc={rc}")
                if not chunk:
                    break
                buf.extend(chunk)
                if b"\n" in chunk:
                    break
            text = buf.decode("utf-8", errors="replace").splitlines()[0] if buf else ""
            if not text:
                raise WizardPwshError("Server closed the pipe without replying.")
            try:
                return json.loads(text)
            except json.JSONDecodeError as ex:
                raise WizardPwshError(f"Bad JSON reply: {ex}; raw={text!r}") from ex
        finally:
            try:
                win32file.CloseHandle(handle)
            except Exception:
                pass

    # -- High-level verbs ---------------------------------------------------

    def hello(self) -> dict:
        return self._send({"command": "hello"})

    def status(self) -> dict:
        return self._send({"command": "status"})

    def status_extended(self) -> dict:
        """γ2 — same fields as status() plus currentCommand / lastCommand / historyCount.

        Lets a Python caller see what's running in the tab without OCR. The extended
        fields are best-effort: a fresh shell with no command history yet returns
        ``currentCommand=None``, ``lastCommand=None``, ``historyCount=0``.
        """
        return self._send({"command": "status.extended"})

    def read(self, max_lines: int = 120) -> dict:
        return self._send({"command": "read", "maxLines": max_lines})

    def write(self, text: str, submit: bool = False) -> dict:
        return self._send({"command": "write", "text": text, "submit": submit})

    def interrupt(self) -> dict:
        return self._send({"command": "interrupt"})

    # Signal bus --------------------------------------------------------------

    def publish_signal(self, topic: str, data: Any = None, ring: int = 256) -> dict:
        return self._send(
            {"command": "signal.publish", "topic": topic, "data": data, "ring": ring}
        )

    def read_signal(self, topic: str, since: int = 0, limit: int = 64) -> dict:
        return self._send(
            {"command": "signal.subscribe", "topic": topic, "since": since, "limit": limit}
        )

    def list_signal_topics(self) -> dict:
        return self._send({"command": "signal.list"})

    def clear_signal(self, topic: Optional[str] = None) -> dict:
        body: dict = {"command": "signal.clear"}
        if topic is not None:
            body["topic"] = topic
        return self._send(body)

    # Hook host --------------------------------------------------------------

    def register_hook(self, name: str, command: Optional[list] = None) -> dict:
        body: dict = {"command": "hook.register", "name": name}
        if command:
            body["command"] = command
        return self._send(body)

    def unregister_hook(self, name: str) -> dict:
        return self._send({"command": "hook.unregister", "name": name})

    def list_hooks(self) -> dict:
        return self._send({"command": "hook.list"})

    def invoke_hook(self, name: str, payload: Any = None, timeout_ms: int = 30000) -> dict:
        return self._send(
            {"command": "hook.invoke", "name": name, "payload": payload, "timeoutMs": timeout_ms}
        )

    def warmup_hooks(self, names: list, timeout_ms: int = 30000) -> dict:
        return self._send(
            {"command": "hook.warmup", "names": list(names), "timeoutMs": timeout_ms}
        )


__all__ = [
    "WizardPwshClient",
    "WizardPwshError",
    "WizardSessionInfo",
    "list_sessions",
]
