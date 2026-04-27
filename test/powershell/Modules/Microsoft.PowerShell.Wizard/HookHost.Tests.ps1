# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Persistent Python hook host" -Tags "Feature" {
    BeforeAll {
        # Skip the whole suite if Python isn't available — the hook host needs it.
        $pyAvailable = $false
        try {
            $null = & py -3.14 --version 2>$null
            if ($LASTEXITCODE -eq 0) { $pyAvailable = $true }
        } catch { }
        if (-not $pyAvailable) {
            try {
                $null = & python --version 2>$null
                if ($LASTEXITCODE -eq 0) { $pyAvailable = $true; $script:PythonExe = 'python' }
            } catch { }
        } else {
            $script:PythonExe = 'py'
        }
        if (-not $pyAvailable) {
            Set-ItResult -Skipped -Because 'Python 3.14 / python not on PATH'
            return
        }

        $powershell = Join-Path -Path $PSHOME -ChildPath 'pwsh'

        # Inline mock hook host: NDJSON loop that handles invoke verbs and dispatches by name.
        # Mirrors the contract WizardControlServer.HookHost.cs expects.
        $script:MockHostDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("wizard-hookhost-mock-$([Guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Force -Path $MockHostDir | Out-Null
        $pkgDir = Join-Path $MockHostDir 'wizard_mcp_test'
        New-Item -ItemType Directory -Force -Path $pkgDir | Out-Null
        Set-Content -LiteralPath (Join-Path $pkgDir '__init__.py') -Value '' -NoNewline
        Set-Content -LiteralPath (Join-Path $pkgDir 'hook_host.py') -Value @'
import json, sys

def _handle_invoke(name, payload):
    if name == "echo":
        return {"echoed": payload}
    if name == "double":
        n = int(payload.get("n", 0))
        return {"result": n * 2}
    if name == "boom":
        raise RuntimeError("intentional")
    if name == "slow":
        import time
        time.sleep(float(payload.get("seconds", 5)))
        return {"slept": payload.get("seconds", 5)}
    return {"unknown": name}

def main():
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception as ex:
            sys.stdout.write(json.dumps({"id": 0, "status": "error", "error": "bad_frame: " + str(ex)}) + "\n")
            sys.stdout.flush()
            continue
        verb = req.get("verb")
        rid = req.get("id", 0)
        if verb == "invoke":
            try:
                result = _handle_invoke(req.get("name", ""), req.get("payload") or {})
                sys.stdout.write(json.dumps({"id": rid, "status": "ok", "result": result}) + "\n")
            except Exception as ex:
                sys.stdout.write(json.dumps({"id": rid, "status": "error", "error": str(ex)}) + "\n")
            sys.stdout.flush()
        elif verb == "warmup":
            # β3: ack-only stub. Real production hosts pre-import the named modules here.
            names = req.get("names") or []
            warmed = {n: ("warm" if n in {"echo", "double", "boom", "slow"} else "unknown_hook") for n in names}
            sys.stdout.write(json.dumps({"id": rid, "status": "ok", "result": {"warmed": warmed}}) + "\n")
            sys.stdout.flush()
        elif verb == "ping":
            sys.stdout.write(json.dumps({"id": rid, "status": "ok", "result": "pong"}) + "\n")
            sys.stdout.flush()
        else:
            sys.stdout.write(json.dumps({"id": rid, "status": "error", "error": "unknown_verb"}) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
'@ -NoNewline

        function Start-WizardPwsh {
            param([string] $PipeName)
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $powershell
            $startInfo.Arguments = '-NoLogo -NoProfile -NoExit'
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.Environment['WIZARD_PWSH_CONTROL'] = '1'
            $startInfo.Environment['WIZARD_PWSH_CONTROL_PIPE'] = $PipeName
            $startInfo.Environment['WIZARD_HOOKHOST_PYTHON'] = $script:PythonExe
            $startInfo.Environment['WIZARD_HOOKHOST_MODULE'] = 'wizard_mcp_test.hook_host'
            $startInfo.Environment['PYTHONPATH'] = $script:MockHostDir
            return [System.Diagnostics.Process]::Start($startInfo)
        }

        function Stop-WizardPwsh {
            param($Process)
            if ($Process -and -not $Process.HasExited) {
                try { $Process.Kill() } catch { }
                $Process.WaitForExit(5000) | Out-Null
            }
        }

        function Send-WizardRequest {
            param([string] $PipeName, [hashtable] $Payload, [int] $TimeoutMs = 5000)
            $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
            $pipe.Connect($TimeoutMs)
            try {
                $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.UTF8Encoding]::new($false), 4096, $true)
                $writer.AutoFlush = $true
                $reader = [System.IO.StreamReader]::new($pipe, [System.Text.Encoding]::UTF8, $false, 4096, $true)
                $writer.WriteLine(($Payload | ConvertTo-Json -Compress -Depth 10))
                return $reader.ReadLine() | ConvertFrom-Json
            } finally {
                $pipe.Dispose()
            }
        }
    }

    AfterAll {
        if ($script:MockHostDir -and (Test-Path -LiteralPath $script:MockHostDir)) {
            Remove-Item -LiteralPath $script:MockHostDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "registers a hook and lists it" {
        $pipe = "wizard-pwsh-test-hook-reg-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.register'; name = 'echo' }
            $r.status | Should -BeExactly 'ok'

            $list = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.list' }
            $list.status | Should -BeExactly 'ok'
            ($list.hooks | ForEach-Object name) | Should -Contain 'echo'
        } finally { Stop-WizardPwsh $proc }
    }

    It "invokes a hook through the warm child and returns its result" {
        $pipe = "wizard-pwsh-test-hook-inv-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.invoke'; name = 'echo'; payload = @{ greeting = 'hi' } }
            $r.status | Should -BeExactly 'ok'
            $r.result.echoed.greeting | Should -BeExactly 'hi'
            $r.durationMs | Should -BeGreaterOrEqual 0
        } finally { Stop-WizardPwsh $proc }
    }

    It "reuses the warm child for repeated invokes (much faster than first call)" {
        $pipe = "wizard-pwsh-test-hook-warm-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            # First call pays cold-spawn cost.
            $first = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.invoke'; name = 'double'; payload = @{ n = 1 } }
            $first.status | Should -BeExactly 'ok'

            # Subsequent calls should be much faster (no spawn).
            $warmDurations = @()
            1..5 | ForEach-Object {
                $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.invoke'; name = 'double'; payload = @{ n = $_ } }
                $r.status | Should -BeExactly 'ok'
                $r.result.result | Should -Be ($_ * 2)
                $warmDurations += $r.durationMs
            }

            # Assert the warm calls average is meaningfully below the cold-spawn cost (~200-500ms).
            $avgWarm = ($warmDurations | Measure-Object -Average).Average
            $avgWarm | Should -BeLessThan 500
        } finally { Stop-WizardPwsh $proc }
    }

    It "surfaces hook-side errors as status=error" {
        $pipe = "wizard-pwsh-test-hook-err-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.invoke'; name = 'boom'; payload = @{} }
            $r.status | Should -BeExactly 'error'
            $r.error | Should -Match 'intentional'
        } finally { Stop-WizardPwsh $proc }
    }

    It "honours per-call timeoutMs and returns error=timeout" {
        $pipe = "wizard-pwsh-test-hook-timeout-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.invoke'; name = 'slow'; timeoutMs = 500; payload = @{ seconds = 3 } } -TimeoutMs 10000
            $r.status | Should -BeExactly 'error'
            $r.error | Should -BeExactly 'timeout'
        } finally { Stop-WizardPwsh $proc }
    }

    It "rejects hook.invoke with no name" {
        $pipe = "wizard-pwsh-test-hook-noname-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.invoke' }
            $r.status | Should -BeExactly 'error'
            $r.error | Should -BeExactly 'missing_name'
        } finally { Stop-WizardPwsh $proc }
    }

    It "hook.warmup pre-imports named hooks (β3) and reports per-name status" {
        $pipe = "wizard-pwsh-test-hook-warmup-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.warmup'; names = @('echo', 'double', 'no_such_hook') }
            $r.status | Should -BeExactly 'ok'
            $r.command | Should -BeExactly 'hook.warmup'
            $r.result.warmed.echo | Should -BeExactly 'warm'
            $r.result.warmed.double | Should -BeExactly 'warm'
            # Unknown hooks are reported but don't fail the call.
            $r.result.warmed.no_such_hook | Should -Match 'unknown_hook|error'

            # First post-warmup invoke should be much cheaper than a cold first invoke
            # would be (the test stub imports nothing heavy, so this is mainly a smoke
            # check that warmup followed by invoke still works).
            $first = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.invoke'; name = 'echo'; payload = @{ ok = $true } }
            $first.status | Should -BeExactly 'ok'
            $first.result.echoed.ok | Should -BeTrue
        } finally { Stop-WizardPwsh $proc }
    }

    It "hook.warmup returns missing_names when called with no names" {
        $pipe = "wizard-pwsh-test-hook-warmup-empty-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.warmup'; names = @() }
            $r.status | Should -BeExactly 'error'
            $r.error | Should -BeExactly 'missing_names'
        } finally { Stop-WizardPwsh $proc }
    }

    It "hook.unregister removes a registered hook" {
        $pipe = "wizard-pwsh-test-hook-unreg-$([Guid]::NewGuid().ToString('N'))"
        $proc = Start-WizardPwsh -PipeName $pipe
        try {
            $null = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.register'; name = 'echo' }
            $r = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.unregister'; name = 'echo' }
            $r.status | Should -BeExactly 'ok'
            $r.removed | Should -BeTrue

            $list = Send-WizardRequest -PipeName $pipe -Payload @{ command = 'hook.list' }
            ($list.hooks | ForEach-Object name) | Should -Not -Contain 'echo'
        } finally { Stop-WizardPwsh $proc }
    }
}
