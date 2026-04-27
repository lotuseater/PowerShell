// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace Microsoft.PowerShell
{
    /// <summary>
    /// Signal-bus subsystem for <see cref="WizardControlServer"/>. Per-topic ring buffers,
    /// monotonic global sequence; lets hooks publish structured events that agents read by
    /// (topic, cursor) instead of OCR-polling the screen. Split out from the main file in
    /// β8 to keep <see cref="WizardControlServer"/> close to its dispatch core.
    /// </summary>
    internal sealed partial class WizardControlServer
    {
        private const int DefaultSignalRingSize = 256;

        // Per-topic ring buffers, monotonic global sequence. All access under _signalLock.
        // Visible to other partials (HookHost.cs uses PublishSignalInternal which touches these).
        private readonly object _signalLock = new object();
        private readonly Dictionary<string, Queue<SignalEvent>> _signals = new Dictionary<string, Queue<SignalEvent>>(StringComparer.Ordinal);
        private long _nextSignalSeq;

        private string SignalPublish(JsonElement request)
        {
            string topic = GetString(request, "topic");
            if (string.IsNullOrWhiteSpace(topic))
            {
                return JsonSerializer.Serialize(new { status = "error", error = "missing_topic" });
            }

            int ring = GetInt(request, "ring", DefaultSignalRingSize);
            if (ring < 1) { ring = DefaultSignalRingSize; }

            string dataJson = "null";
            if (request.TryGetProperty("data", out JsonElement dataElement))
            {
                dataJson = dataElement.GetRawText();
            }

            long seq;
            DateTimeOffset ts;
            lock (_signalLock)
            {
                if (!_signals.TryGetValue(topic, out Queue<SignalEvent> queue))
                {
                    queue = new Queue<SignalEvent>(ring);
                    _signals[topic] = queue;
                }

                while (queue.Count >= ring)
                {
                    queue.Dequeue();
                }

                seq = ++_nextSignalSeq;
                ts = DateTimeOffset.UtcNow;
                queue.Enqueue(new SignalEvent(seq, topic, ts, dataJson));
            }

            return JsonSerializer.Serialize(new { status = "ok", command = "signal.publish", topic, seq, ts });
        }

        private string SignalSubscribe(JsonElement request)
        {
            string topic = GetString(request, "topic");
            if (string.IsNullOrWhiteSpace(topic))
            {
                return JsonSerializer.Serialize(new { status = "error", error = "missing_topic" });
            }

            long since = 0;
            if (request.TryGetProperty("since", out JsonElement sinceElement) && sinceElement.TryGetInt64(out long parsedSince))
            {
                since = parsedSince;
            }

            int limit = GetInt(request, "limit", 64);
            if (limit < 1) { limit = 1; }
            if (limit > 1024) { limit = 1024; }

            SignalEvent[] page;
            long head;
            int total;
            lock (_signalLock)
            {
                if (!_signals.TryGetValue(topic, out Queue<SignalEvent> queue))
                {
                    page = Array.Empty<SignalEvent>();
                    head = _nextSignalSeq;
                    total = 0;
                }
                else
                {
                    page = queue.Where(e => e.Seq > since).Take(limit).ToArray();
                    head = _nextSignalSeq;
                    total = queue.Count;
                }
            }

            // Hand-roll the JSON so the per-event `data` field is emitted as raw JSON (the
            // payload was stored as a JSON string in SignalPublish). Re-parsing into JsonNode
            // and re-serialising would allocate a tree per event — unnecessary at our cadence.
            StringBuilder sb = new StringBuilder();
            sb.Append("{\"status\":\"ok\",\"command\":\"signal.subscribe\",\"topic\":");
            sb.Append(JsonSerializer.Serialize(topic));
            sb.Append(",\"head\":").Append(head);
            sb.Append(",\"total\":").Append(total);
            sb.Append(",\"events\":[");
            for (int i = 0; i < page.Length; i++)
            {
                if (i > 0) { sb.Append(','); }
                SignalEvent e = page[i];
                sb.Append("{\"seq\":").Append(e.Seq);
                sb.Append(",\"topic\":").Append(JsonSerializer.Serialize(e.Topic));
                sb.Append(",\"ts\":").Append(JsonSerializer.Serialize(e.Timestamp));
                sb.Append(",\"data\":").Append(string.IsNullOrEmpty(e.DataJson) ? "null" : e.DataJson);
                sb.Append('}');
            }
            sb.Append("]}");
            return sb.ToString();
        }

        private string SignalList()
        {
            KeyValuePair<string, int>[] topics;
            long head;
            lock (_signalLock)
            {
                topics = _signals.Select(kv => new KeyValuePair<string, int>(kv.Key, kv.Value.Count)).ToArray();
                head = _nextSignalSeq;
            }

            return JsonSerializer.Serialize(new
            {
                status = "ok",
                command = "signal.list",
                head,
                topics = topics.Select(t => new { topic = t.Key, count = t.Value }).ToArray()
            });
        }

        private string SignalClear(JsonElement request)
        {
            string topic = GetString(request, "topic");
            int removed;
            lock (_signalLock)
            {
                if (string.IsNullOrEmpty(topic))
                {
                    removed = _signals.Sum(kv => kv.Value.Count);
                    _signals.Clear();
                }
                else if (_signals.TryGetValue(topic, out Queue<SignalEvent> queue))
                {
                    removed = queue.Count;
                    _signals.Remove(topic);
                }
                else
                {
                    removed = 0;
                }
            }

            return JsonSerializer.Serialize(new { status = "ok", command = "signal.clear", topic = topic ?? "*", removed });
        }

        private readonly struct SignalEvent
        {
            internal SignalEvent(long seq, string topic, DateTimeOffset timestamp, string dataJson)
            {
                Seq = seq;
                Topic = topic;
                Timestamp = timestamp;
                DataJson = dataJson;
            }

            internal long Seq { get; }

            internal string Topic { get; }

            internal DateTimeOffset Timestamp { get; }

            internal string DataJson { get; }
        }
    }
}
