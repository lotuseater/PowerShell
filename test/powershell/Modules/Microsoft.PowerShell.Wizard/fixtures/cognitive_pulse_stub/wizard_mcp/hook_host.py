# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Test fixture: minimal hook-host stub that knows the `cognitive_pulse` hook.
# Used by CognitivePulseRewire.Tests.ps1 to drive an end-to-end smoke through
# WizardControlServer.HookHost.cs without depending on the real WizardErasmus
# cognitive-pulse implementation.

import json
import sys


def _hook_cognitive_pulse(payload):
    return {"additionalContext": "<cognitive-pulse-stub />"}


HOOKS = {
    "cognitive_pulse": _hook_cognitive_pulse,
}


def main():
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception as ex:  # noqa: BLE001
            sys.stdout.write(json.dumps({"id": 0, "status": "error", "error": "bad_frame: %s" % ex}) + "\n")
            sys.stdout.flush()
            continue

        rid = req.get("id", 0)
        verb = req.get("verb")
        if verb == "invoke":
            try:
                fn = HOOKS[req.get("name", "")]
                result = fn(req.get("payload") or {})
                sys.stdout.write(json.dumps({"id": rid, "status": "ok", "result": result}) + "\n")
            except KeyError:
                sys.stdout.write(json.dumps({"id": rid, "status": "error", "error": "unknown_hook"}) + "\n")
            except Exception as ex:  # noqa: BLE001
                sys.stdout.write(json.dumps({"id": rid, "status": "error", "error": str(ex)}) + "\n")
            sys.stdout.flush()
        elif verb == "warmup":
            names = req.get("names") or []
            warmed = {n: ("warm" if n in HOOKS else "unknown_hook") for n in names}
            sys.stdout.write(json.dumps({"id": rid, "status": "ok", "result": {"warmed": warmed}}) + "\n")
            sys.stdout.flush()
        else:
            sys.stdout.write(json.dumps({"id": rid, "status": "error", "error": "unknown_verb"}) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
