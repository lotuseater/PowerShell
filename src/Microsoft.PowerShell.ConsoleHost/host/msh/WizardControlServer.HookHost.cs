// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Microsoft.PowerShell
{
    /// <summary>
    /// Persistent Python hook host. Lazy-spawns a single long-lived
    /// <c>py -3.14 -m wizard_mcp.hook_host</c> child the first time any hook is invoked,
    /// then routes all <c>hook.invoke</c> requests through it as NDJSON. Eliminates the
    /// per-hook Python cold-spawn cost (~14 spawns × 200-500 ms each per agent turn).
    ///
    /// Protocol (line-delimited JSON, both ways):
    ///   client→host: { "verb": "register", "name": "...", "command": [...] }   (optional metadata)
    ///   client→host: { "verb": "invoke",   "name": "...", "payload": {...}, "id": &lt;int&gt; }
    ///   client→host: { "verb": "list" }
    ///   client→host: { "verb": "unregister", "name": "..." }
    ///   host→client: { "id": &lt;int&gt;, "status": "ok"|"error", "result": ..., "error": "..." }
    /// </summary>
    internal sealed partial class WizardControlServer
    {
        private const int DefaultHookTimeoutMs = 30000;

        private readonly object _hookLock = new object();
        private readonly Dictionary<string, HookRecord> _hookRegistry = new Dictionary<string, HookRecord>(StringComparer.Ordinal);
        private long _hookInvokeIdCounter;
        private Process _hookHostProcess;
        private StreamWriter _hookHostStdin;
        private readonly Dictionary<long, TaskCompletionSource<HookHostReply>> _hookPendingReplies = new Dictionary<long, TaskCompletionSource<HookHostReply>>();
        private Task _hookHostReaderTask;
        private DateTimeOffset _hookHostStartedAt = DateTimeOffset.MinValue;
        private int _hookHostRespawnCount;

        /// <summary>Diagnostics-only snapshot used by <c>Get-WizardSession</c> in a future revision.</summary>
        internal HookHostStatusSnapshot GetHookHostStatus()
        {
            lock (_hookLock)
            {
                bool alive = _hookHostProcess != null && !_hookHostProcess.HasExited;
                return new HookHostStatusSnapshot(
                    isWarm: alive,
                    pid: alive ? _hookHostProcess.Id : 0,
                    startedAt: _hookHostStartedAt,
                    respawnCount: _hookHostRespawnCount,
                    registeredCount: _hookRegistry.Count);
            }
        }

        private string HookRegister(JsonElement request)
        {
            string name = GetString(request, "name");
            if (string.IsNullOrWhiteSpace(name))
            {
                return JsonSerializer.Serialize(new { status = "error", error = "missing_name", command = "hook.register" });
            }

            string[] commandArgs = null;
            if (request.TryGetProperty("command", out JsonElement cmd) && cmd.ValueKind == JsonValueKind.Array)
            {
                commandArgs = cmd.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()).ToArray();
            }

            lock (_hookLock)
            {
                _hookRegistry[name] = new HookRecord(name, commandArgs);
            }

            return JsonSerializer.Serialize(new { status = "ok", command = "hook.register", name });
        }

        private string HookList()
        {
            HookRecord[] snapshot;
            lock (_hookLock)
            {
                snapshot = _hookRegistry.Values.ToArray();
            }

            return JsonSerializer.Serialize(new
            {
                status = "ok",
                command = "hook.list",
                hooks = snapshot.Select(h => new
                {
                    name = h.Name,
                    calls = h.InvokeCount,
                    lastInvokedAt = h.LastInvokedAt == DateTimeOffset.MinValue ? null : (DateTimeOffset?)h.LastInvokedAt,
                    p50Ms = h.P50LatencyMs,
                    p95Ms = h.P95LatencyMs
                }).ToArray()
            });
        }

        private string HookUnregister(JsonElement request)
        {
            string name = GetString(request, "name");
            if (string.IsNullOrWhiteSpace(name))
            {
                return JsonSerializer.Serialize(new { status = "error", error = "missing_name", command = "hook.unregister" });
            }
            bool removed;
            lock (_hookLock)
            {
                removed = _hookRegistry.Remove(name);
            }
            return JsonSerializer.Serialize(new { status = "ok", command = "hook.unregister", name, removed });
        }

        private string HookInvoke(JsonElement request)
        {
            string name = GetString(request, "name");
            if (string.IsNullOrWhiteSpace(name))
            {
                return JsonSerializer.Serialize(new { status = "error", error = "missing_name", command = "hook.invoke" });
            }

            int timeoutMs = GetInt(request, "timeoutMs", DefaultHookTimeoutMs);
            if (timeoutMs < 100) { timeoutMs = 100; }

            string payloadJson = "null";
            if (request.TryGetProperty("payload", out JsonElement payload))
            {
                payloadJson = payload.GetRawText();
            }

            try
            {
                EnsureHookHostStarted();
            }
            catch (Exception ex)
            {
                return JsonSerializer.Serialize(new { status = "error", error = "host_unavailable", command = "hook.invoke", message = ex.Message });
            }

            long id = Interlocked.Increment(ref _hookInvokeIdCounter);
            var tcs = new TaskCompletionSource<HookHostReply>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_hookLock)
            {
                _hookPendingReplies[id] = tcs;
            }

            string frame = "{\"id\":" + id +
                ",\"verb\":\"invoke\",\"name\":" + JsonSerializer.Serialize(name) +
                ",\"payload\":" + payloadJson + "}";

            Stopwatch sw = Stopwatch.StartNew();
            try
            {
                lock (_hookLock)
                {
                    if (_hookHostStdin == null)
                    {
                        throw new InvalidOperationException("hook host stdin is not connected");
                    }
                    _hookHostStdin.WriteLine(frame);
                }

                if (!tcs.Task.Wait(timeoutMs, _cancel.Token))
                {
                    lock (_hookLock) { _hookPendingReplies.Remove(id); }
                    return JsonSerializer.Serialize(new { status = "error", error = "timeout", command = "hook.invoke", name, timeoutMs });
                }

                HookHostReply reply = tcs.Task.Result;
                sw.Stop();

                lock (_hookLock)
                {
                    if (_hookRegistry.TryGetValue(name, out HookRecord rec))
                    {
                        rec.RecordInvoke((int)sw.ElapsedMilliseconds);
                    }
                    else
                    {
                        // Auto-register on first invoke so `hook.list` is useful even without explicit register.
                        var auto = new HookRecord(name, null);
                        auto.RecordInvoke((int)sw.ElapsedMilliseconds);
                        _hookRegistry[name] = auto;
                    }
                }

                if (reply.IsError)
                {
                    return JsonSerializer.Serialize(new { status = "error", error = reply.Error ?? "host_error", command = "hook.invoke", name });
                }

                // Splice the result raw JSON into the response.
                StringBuilder sb = new StringBuilder();
                sb.Append("{\"status\":\"ok\",\"command\":\"hook.invoke\",\"name\":");
                sb.Append(JsonSerializer.Serialize(name));
                sb.Append(",\"durationMs\":").Append(sw.ElapsedMilliseconds);
                sb.Append(",\"result\":").Append(string.IsNullOrEmpty(reply.ResultJson) ? "null" : reply.ResultJson);
                sb.Append('}');
                return sb.ToString();
            }
            catch (Exception ex)
            {
                lock (_hookLock) { _hookPendingReplies.Remove(id); }
                return JsonSerializer.Serialize(new { status = "error", error = "invoke_failed", command = "hook.invoke", name, message = ex.Message });
            }
        }

        private string HookWarmup(JsonElement request)
        {
            // β3: pre-import named hook modules in the warm child so the FIRST hook.invoke
            // doesn't pay the cold-import cost (~200-500 ms for cognitive_pulse).
            string[] names = Array.Empty<string>();
            if (request.TryGetProperty("names", out JsonElement namesElement) && namesElement.ValueKind == JsonValueKind.Array)
            {
                names = namesElement.EnumerateArray()
                    .Where(e => e.ValueKind == JsonValueKind.String)
                    .Select(e => e.GetString())
                    .Where(n => !string.IsNullOrWhiteSpace(n))
                    .ToArray();
            }
            if (names.Length == 0)
            {
                return JsonSerializer.Serialize(new { status = "error", error = "missing_names", command = "hook.warmup" });
            }

            int timeoutMs = GetInt(request, "timeoutMs", DefaultHookTimeoutMs);
            if (timeoutMs < 100) { timeoutMs = 100; }

            try
            {
                EnsureHookHostStarted();
            }
            catch (Exception ex)
            {
                return JsonSerializer.Serialize(new { status = "error", error = "host_unavailable", command = "hook.warmup", message = ex.Message });
            }

            long id = Interlocked.Increment(ref _hookInvokeIdCounter);
            var tcs = new TaskCompletionSource<HookHostReply>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_hookLock)
            {
                _hookPendingReplies[id] = tcs;
            }

            string namesJson = JsonSerializer.Serialize(names);
            string frame = "{\"id\":" + id + ",\"verb\":\"warmup\",\"names\":" + namesJson + "}";

            Stopwatch sw = Stopwatch.StartNew();
            try
            {
                lock (_hookLock)
                {
                    if (_hookHostStdin == null)
                    {
                        throw new InvalidOperationException("hook host stdin is not connected");
                    }
                    _hookHostStdin.WriteLine(frame);
                }

                if (!tcs.Task.Wait(timeoutMs, _cancel.Token))
                {
                    lock (_hookLock) { _hookPendingReplies.Remove(id); }
                    return JsonSerializer.Serialize(new { status = "error", error = "timeout", command = "hook.warmup", timeoutMs });
                }

                HookHostReply reply = tcs.Task.Result;
                sw.Stop();

                // Pre-create registry entries so hook.list can show warmed-but-uninvoked hooks
                // (calls=0). Auto-invoke registration also handles them — this is just for
                // diagnostic visibility.
                lock (_hookLock)
                {
                    foreach (string n in names)
                    {
                        if (!_hookRegistry.ContainsKey(n))
                        {
                            _hookRegistry[n] = new HookRecord(n, null);
                        }
                    }
                }

                if (reply.IsError)
                {
                    return JsonSerializer.Serialize(new { status = "error", error = reply.Error ?? "host_error", command = "hook.warmup", names });
                }

                StringBuilder sb = new StringBuilder();
                sb.Append("{\"status\":\"ok\",\"command\":\"hook.warmup\",\"names\":").Append(namesJson);
                sb.Append(",\"durationMs\":").Append(sw.ElapsedMilliseconds);
                sb.Append(",\"result\":").Append(string.IsNullOrEmpty(reply.ResultJson) ? "null" : reply.ResultJson);
                sb.Append('}');
                return sb.ToString();
            }
            catch (Exception ex)
            {
                lock (_hookLock) { _hookPendingReplies.Remove(id); }
                return JsonSerializer.Serialize(new { status = "error", error = "warmup_failed", command = "hook.warmup", message = ex.Message });
            }
        }

        private void EnsureHookHostStarted()
        {
            lock (_hookLock)
            {
                if (_hookHostProcess != null && !_hookHostProcess.HasExited)
                {
                    return;
                }

                StartHookHostUnsafe();
            }
        }

        private void StartHookHostUnsafe()
        {
            // Spawn the warm Python child. Caller holds _hookLock.
            string py = Environment.GetEnvironmentVariable("WIZARD_HOOKHOST_PYTHON") ?? "py";
            string moduleArg = Environment.GetEnvironmentVariable("WIZARD_HOOKHOST_MODULE") ?? "wizard_mcp.hook_host";

            ProcessStartInfo psi = new ProcessStartInfo
            {
                FileName = py,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false),
            };
            // Use Python launcher when available (`py -3.14 -m wizard_mcp.hook_host`).
            if (string.Equals(py, "py", StringComparison.OrdinalIgnoreCase))
            {
                psi.ArgumentList.Add("-3.14");
            }
            psi.ArgumentList.Add("-u");      // unbuffered stdout
            psi.ArgumentList.Add("-m");
            psi.ArgumentList.Add(moduleArg);

            Process p;
            try
            {
                p = Process.Start(psi);
            }
            catch (Exception ex)
            {
                _hookHostRespawnCount++;
                throw new InvalidOperationException($"Failed to start hook host ({py} -m {moduleArg}): {ex.Message}", ex);
            }

            _hookHostProcess = p;
            _hookHostStdin = p.StandardInput;
            _hookHostStartedAt = DateTimeOffset.UtcNow;

            _hookHostReaderTask = Task.Run(() => HookHostReaderLoop(p));
        }

        private void HookHostReaderLoop(Process p)
        {
            try
            {
                StreamReader reader = p.StandardOutput;
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    if (string.IsNullOrWhiteSpace(line)) { continue; }
                    HookHostReply reply = ParseHookHostLine(line);
                    if (reply.Id == 0) { continue; }
                    TaskCompletionSource<HookHostReply> tcs = null;
                    lock (_hookLock)
                    {
                        if (_hookPendingReplies.TryGetValue(reply.Id, out tcs))
                        {
                            _hookPendingReplies.Remove(reply.Id);
                        }
                    }
                    tcs?.TrySetResult(reply);
                }
            }
            catch
            {
                // Reader done — child likely exited. Reply pending tasks with host_crashed and signal.
            }

            // Drain pending replies with host_crashed.
            TaskCompletionSource<HookHostReply>[] pending;
            lock (_hookLock)
            {
                pending = _hookPendingReplies.Values.ToArray();
                _hookPendingReplies.Clear();
                _hookHostStdin = null;
            }
            foreach (var t in pending)
            {
                t.TrySetResult(new HookHostReply(0, "host_crashed", null));
            }

            // Best-effort signal so the agent can react.
            try
            {
                // Inline minimal publish (avoid the JsonElement plumbing of the signal.publish verb):
                lock (_signalLock)
                {
                    if (!_signals.TryGetValue("wizard.hookhost.respawn", out Queue<SignalEvent> q))
                    {
                        q = new Queue<SignalEvent>(DefaultSignalRingSize);
                        _signals["wizard.hookhost.respawn"] = q;
                    }
                    while (q.Count >= DefaultSignalRingSize) { q.Dequeue(); }
                    long seq = ++_nextSignalSeq;
                    q.Enqueue(new SignalEvent(seq, "wizard.hookhost.respawn", DateTimeOffset.UtcNow,
                        "{\"reason\":\"reader_exit\",\"respawnCount\":" + _hookHostRespawnCount + "}"));
                }
            }
            catch
            {
            }
        }

        private static HookHostReply ParseHookHostLine(string line)
        {
            try
            {
                using JsonDocument doc = JsonDocument.Parse(line);
                JsonElement root = doc.RootElement;
                long id = 0;
                if (root.TryGetProperty("id", out JsonElement idEl) && idEl.TryGetInt64(out long parsedId))
                {
                    id = parsedId;
                }
                string status = root.TryGetProperty("status", out JsonElement statusEl) && statusEl.ValueKind == JsonValueKind.String
                    ? statusEl.GetString()
                    : "ok";
                if (string.Equals(status, "error", StringComparison.Ordinal))
                {
                    string err = root.TryGetProperty("error", out JsonElement errEl) && errEl.ValueKind == JsonValueKind.String
                        ? errEl.GetString()
                        : "unknown";
                    return new HookHostReply(id, err, null);
                }
                string resultJson = "null";
                if (root.TryGetProperty("result", out JsonElement resEl))
                {
                    resultJson = resEl.GetRawText();
                }
                return new HookHostReply(id, null, resultJson);
            }
            catch
            {
                return default;
            }
        }

        private void DisposeHookHost()
        {
            lock (_hookLock)
            {
                try
                {
                    _hookHostStdin?.Dispose();
                }
                catch { }
                _hookHostStdin = null;

                Process p = _hookHostProcess;
                _hookHostProcess = null;
                if (p != null)
                {
                    try
                    {
                        if (!p.HasExited)
                        {
                            try { p.Kill(true); } catch { }
                            try { p.WaitForExit(2000); } catch { }
                        }
                        p.Dispose();
                    }
                    catch { }
                }

                foreach (var t in _hookPendingReplies.Values)
                {
                    t.TrySetCanceled();
                }
                _hookPendingReplies.Clear();
            }
        }

        private sealed class HookRecord
        {
            internal HookRecord(string name, string[] command)
            {
                Name = name;
                Command = command;
                _latencies = new List<int>(64);
            }

            internal string Name { get; }

            internal string[] Command { get; }

            internal int InvokeCount { get; private set; }

            internal DateTimeOffset LastInvokedAt { get; private set; } = DateTimeOffset.MinValue;

            internal int P50LatencyMs => Percentile(0.5);

            internal int P95LatencyMs => Percentile(0.95);

            private readonly List<int> _latencies;

            internal void RecordInvoke(int durationMs)
            {
                InvokeCount++;
                LastInvokedAt = DateTimeOffset.UtcNow;
                _latencies.Add(durationMs);
                // Cap retention so the list doesn't grow unboundedly.
                if (_latencies.Count > 1024)
                {
                    _latencies.RemoveRange(0, _latencies.Count - 1024);
                }
            }

            private int Percentile(double p)
            {
                if (_latencies.Count == 0) { return 0; }
                List<int> sorted = _latencies.ToList();
                sorted.Sort();
                int idx = (int)Math.Ceiling(p * sorted.Count) - 1;
                if (idx < 0) { idx = 0; }
                if (idx >= sorted.Count) { idx = sorted.Count - 1; }
                return sorted[idx];
            }
        }

        private readonly struct HookHostReply
        {
            internal HookHostReply(long id, string error, string resultJson)
            {
                Id = id;
                Error = error;
                ResultJson = resultJson;
            }

            internal long Id { get; }

            internal string Error { get; }

            internal string ResultJson { get; }

            internal bool IsError => !string.IsNullOrEmpty(Error);
        }

        internal readonly struct HookHostStatusSnapshot
        {
            internal HookHostStatusSnapshot(bool isWarm, int pid, DateTimeOffset startedAt, int respawnCount, int registeredCount)
            {
                IsWarm = isWarm;
                Pid = pid;
                StartedAt = startedAt;
                RespawnCount = respawnCount;
                RegisteredCount = registeredCount;
            }

            internal bool IsWarm { get; }

            internal int Pid { get; }

            internal DateTimeOffset StartedAt { get; }

            internal int RespawnCount { get; }

            internal int RegisteredCount { get; }
        }
    }
}
