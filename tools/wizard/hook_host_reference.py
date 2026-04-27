# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Minimal reference implementation of the warm Python hook host expected by
# WizardControlServer.HookHost.cs (Phase 6 of the wizard_power_shell branch).
#
# Drop this file into WizardErasmus as `src/mcp/hook_host.py` (or set
# `WIZARD_HOOKHOST_MODULE=path.to.hook_host` env var to point elsewhere). The
# wizard pwsh.exe lazy-spawns this module the first time `hook.invoke` is called
# over the named pipe, then keeps it warm for the lifetime of the shell —
# eliminating ~14 cold Python imports per agent turn.
#
# Protocol (NDJSON, both directions on stdin/stdout):
#   client → host: {"id": <int>, "verb": "invoke", "name": "<hook>", "payload": <obj|null>}
#   host  → client: {"id": <int>, "status": "ok",    "result": <obj|null>}
#                    {"id": <int>, "status": "error", "error":  "<msg>"}
#
# To register a real hook, add an entry to HOOKS below. Each callable receives
# the payload dict and returns a JSON-serialisable result. Exceptions are
# surfaced as status=error to the C# side.

import json
import sys
import traceback
from typing import Any, Callable, Dict


def _hook_pretool_cache(payload: Dict[str, Any]) -> Dict[str, Any]:
    """Stub; real implementation lives in wizard_mcp/hooks/pretool_cache_hook.py.
    The migration story: import that module's `main(payload)` here and forward the call,
    so the warm host pays the import cost once instead of once per hook fire."""
    # from wizard_mcp.hooks.pretool_cache_hook import main as _main
    # return _main(payload)
    return {"warm_stub": True, "note": "wire wizard_mcp.hooks.pretool_cache_hook.main here"}


def _hook_cognitive_pulse(payload: Dict[str, Any]) -> Dict[str, Any]:
    """Stub for the heavy cognitive_pulse_hook. Once warm, an import here pays once;
    each invoke is a function call, not a Python boot."""
    # from wizard_mcp.cognitive_pulse_hook import compute_pulse_block
    # block = compute_pulse_block(payload)
    # return {"block": block}
    return {"warm_stub": True}


HOOKS: Dict[str, Callable[[Dict[str, Any]], Any]] = {
    "pretool_cache": _hook_pretool_cache,
    "cognitive_pulse": _hook_cognitive_pulse,
    "echo": lambda payload: {"echoed": payload},
    "ping": lambda payload: "pong",
}


def _handle_invoke(name: str, payload: Any) -> Any:
    fn = HOOKS.get(name)
    if fn is None:
        raise KeyError(f"hook not registered: {name}")
    return fn(payload or {})


def main() -> int:
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception as ex:
            sys.stdout.write(json.dumps({"id": 0, "status": "error", "error": f"bad_frame: {ex}"}) + "\n")
            sys.stdout.flush()
            continue

        rid = req.get("id", 0)
        verb = req.get("verb")
        try:
            if verb == "invoke":
                result = _handle_invoke(req.get("name", ""), req.get("payload"))
                sys.stdout.write(json.dumps({"id": rid, "status": "ok", "result": result}) + "\n")
            elif verb == "ping":
                sys.stdout.write(json.dumps({"id": rid, "status": "ok", "result": "pong"}) + "\n")
            else:
                sys.stdout.write(json.dumps({"id": rid, "status": "error", "error": f"unknown_verb: {verb}"}) + "\n")
        except Exception as ex:
            sys.stdout.write(json.dumps({"id": rid, "status": "error",
                                         "error": str(ex), "traceback": traceback.format_exc()}) + "\n")
        sys.stdout.flush()

    return 0


if __name__ == "__main__":
    sys.exit(main())
