// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Microsoft.PowerShell
{
    /// <summary>
    /// Opt-in local control plane for agent-driven terminal automation. Made <c>partial</c>
    /// so feature subsystems (hook host, future signal extensions) can split into their own
    /// files without bloating the dispatch core. Each partial extends `dispatch` via the
    /// `TryHandleHookVerb` / `TryHandleSignalVerb` pattern called from <see cref="HandleRequest"/>.
    /// </summary>
    internal sealed partial class WizardControlServer : IDisposable
    {
        internal const string EnableEnvironmentVariable = "WIZARD_PWSH_CONTROL";
        internal const string PipeEnvironmentVariable = "WIZARD_PWSH_CONTROL_PIPE";
        internal const int ProtocolVersion = 1;

        private readonly ConsoleHost _host;
        private readonly string _pipeName;
        private readonly string _sessionPath;
        private readonly CancellationTokenSource _cancel = new CancellationTokenSource();
        private readonly Task _serverTask;
        private readonly DateTimeOffset _startedAt = DateTimeOffset.UtcNow;
        private DateTimeOffset _lastRequestAt = DateTimeOffset.UtcNow;
        private bool _disposed;

        // Signal-bus state moved to WizardControlServer.Signals.cs partial in β8 (2026-04-27).
        // HookHost.cs's PublishSignalInternal still touches _signalLock / _signals / _nextSignalSeq,
        // which are now declared in the Signals partial — accessible to all partials of this class.

        private WizardControlServer(ConsoleHost host, string pipeName, string sessionPath)
        {
            _host = host;
            _pipeName = pipeName;
            _sessionPath = sessionPath;
            WriteSessionRecord();
            _serverTask = Task.Run(RunAsync);
        }

        internal string PipeName => _pipeName;

        /// <summary>
        /// Returns true when WIZARD_PWSH_CONTROL is set to a truthy value. Cheap, side-effect free,
        /// safe to call from any startup path (including LoadPSReadline) before the server itself runs.
        /// </summary>
        internal static bool IsEnabled
        {
            get
            {
                return IsTruthy(Environment.GetEnvironmentVariable(EnableEnvironmentVariable));
            }
        }

        internal static WizardControlServer StartIfEnabled(ConsoleHost host)
        {
            if (!IsEnabled)
            {
                return null;
            }

            string pipeName = Environment.GetEnvironmentVariable(PipeEnvironmentVariable);
            if (string.IsNullOrWhiteSpace(pipeName))
            {
                pipeName = "wizard-pwsh-" + Environment.ProcessId.ToString(CultureInfo.InvariantCulture);
            }

            string root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "WizardPowerShell",
                "sessions");
            Directory.CreateDirectory(root);
            string sessionPath = Path.Combine(root, Environment.ProcessId.ToString(CultureInfo.InvariantCulture) + ".json");

            try
            {
                return new WizardControlServer(host, pipeName, sessionPath);
            }
            catch
            {
                return null;
            }
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _cancel.Cancel();
            DisposeHookHost();
            try
            {
                if (File.Exists(_sessionPath))
                {
                    File.Delete(_sessionPath);
                }
            }
            catch
            {
            }
        }

        private static bool IsTruthy(string value)
        {
            return string.Equals(value, "1", StringComparison.OrdinalIgnoreCase)
                || string.Equals(value, "true", StringComparison.OrdinalIgnoreCase)
                || string.Equals(value, "yes", StringComparison.OrdinalIgnoreCase);
        }

        private async Task RunAsync()
        {
            while (!_cancel.IsCancellationRequested)
            {
                try
                {
                    using NamedPipeServerStream pipe = CreatePipe();
                    await pipe.WaitForConnectionAsync(_cancel.Token).ConfigureAwait(false);
                    using StreamReader reader = new StreamReader(pipe, Encoding.UTF8, detectEncodingFromByteOrderMarks: false, bufferSize: 4096, leaveOpen: true);
                    using StreamWriter writer = new StreamWriter(pipe, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false), bufferSize: 4096, leaveOpen: true)
                    {
                        AutoFlush = true
                    };

                    while (!_cancel.IsCancellationRequested && pipe.IsConnected)
                    {
                        string line = await reader.ReadLineAsync().ConfigureAwait(false);
                        if (line == null)
                        {
                            break;
                        }

                        string response = HandleRequest(line);
                        await writer.WriteLineAsync(response).ConfigureAwait(false);
                    }
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch
                {
                    Thread.Sleep(100);
                }
            }
        }

        private NamedPipeServerStream CreatePipe()
        {
            return new NamedPipeServerStream(
                _pipeName,
                PipeDirection.InOut,
                maxNumberOfServerInstances: 1,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        }

        private string HandleRequest(string line)
        {
            _lastRequestAt = DateTimeOffset.UtcNow;
            WriteSessionRecord();

            try
            {
                using JsonDocument document = JsonDocument.Parse(line);
                JsonElement root = document.RootElement;
                string command = GetString(root, "command") ?? GetString(root, "op") ?? string.Empty;

                switch (command.ToLowerInvariant())
                {
                    case "hello":
                        return JsonSerializer.Serialize(Hello());
                    case "status":
                        return JsonSerializer.Serialize(Status());
                    case "status.extended":
                        return JsonSerializer.Serialize(StatusExtended());
                    case "read":
                        return JsonSerializer.Serialize(Read(GetInt(root, "maxLines", 120)));
                    case "read.structured":
                        return JsonSerializer.Serialize(ReadStructured(GetInt(root, "maxLines", 200)));
                    case "write":
                        return JsonSerializer.Serialize(Write(GetString(root, "text") ?? string.Empty, GetBool(root, "submit", false)));
                    case "interrupt":
                        _host.WizardInterruptCurrentPipeline();
                        return JsonSerializer.Serialize(new { status = "ok", command });
                    case "signal.publish":
                        return SignalPublish(root);
                    case "signal.subscribe":
                        return SignalSubscribe(root);
                    case "signal.list":
                        return SignalList();
                    case "signal.clear":
                        return SignalClear(root);
                    case "hook.register":
                        return HookRegister(root);
                    case "hook.invoke":
                        return HookInvoke(root);
                    case "hook.list":
                        return HookList();
                    case "hook.unregister":
                        return HookUnregister(root);
                    case "hook.warmup":
                        return HookWarmup(root);
                    default:
                        return JsonSerializer.Serialize(new { status = "error", error = "unknown_command", command });
                }
            }
            catch (Exception exception)
            {
                return JsonSerializer.Serialize(new { status = "error", error = exception.GetType().Name, message = exception.Message });
            }
        }

        private object Hello()
        {
            Process process = Process.GetCurrentProcess();
            return new
            {
                status = "ok",
                protocol = ProtocolVersion,
                provider = "powershell",
                pid = Environment.ProcessId,
                pipe = _pipeName,
                startedAt = _startedAt,
                processName = process.ProcessName,
                executable = Environment.ProcessPath,
                cwd = Environment.CurrentDirectory
            };
        }

        private object Status()
        {
            WizardControlSnapshot snapshot = _host.GetWizardControlSnapshot();
            return new
            {
                status = "ok",
                protocol = ProtocolVersion,
                pid = Environment.ProcessId,
                pipe = _pipeName,
                cwd = Environment.CurrentDirectory,
                startedAt = _startedAt,
                lastRequestAt = _lastRequestAt,
                promptActive = snapshot.PromptActive,
                shouldEndSession = snapshot.ShouldEndSession,
                runspaceState = snapshot.RunspaceState,
                windowTitle = snapshot.WindowTitle
            };
        }

        // γ2: same shape as Status() plus runspace-introspection fields. Lets DAB / agents
        // know what's running in this tab right now without OCR or keystroke-driven
        // diagnostics. Populated by ConsoleHost.GetWizardControlSnapshot(extended:true).
        private object StatusExtended()
        {
            WizardControlSnapshot snapshot = _host.GetWizardControlSnapshot(extended: true);
            return new
            {
                status = "ok",
                protocol = ProtocolVersion,
                pid = Environment.ProcessId,
                pipe = _pipeName,
                cwd = Environment.CurrentDirectory,
                startedAt = _startedAt,
                lastRequestAt = _lastRequestAt,
                promptActive = snapshot.PromptActive,
                shouldEndSession = snapshot.ShouldEndSession,
                runspaceState = snapshot.RunspaceState,
                windowTitle = snapshot.WindowTitle,
                currentCommand = snapshot.CurrentCommand,
                lastCommand = snapshot.LastCommand,
                historyCount = snapshot.HistoryCount
            };
        }

        // SignalPublish / SignalSubscribe / SignalList / SignalClear and the SignalEvent struct
        // moved to WizardControlServer.Signals.cs partial in β8.

        private static object Read(int maxLines)
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                return new { status = "error", error = "unsupported_platform" };
            }

            ConsoleReadResult result = WindowsConsole.Read(maxLines);
            return new
            {
                status = "ok",
                method = "native_console",
                text = result.Text,
                lines = result.Lines,
                width = result.Width,
                height = result.Height,
                window = result.Window
            };
        }

        // Match `error CS1234:` / `Error: ...` / `Exception:` etc. without
        // System.Text.RegularExpressions.Regex compiled at hot-path time —
        // pre-compiled static regex avoids per-line allocation cost.
        private static readonly System.Text.RegularExpressions.Regex ErrorLineRegex =
            new System.Text.RegularExpressions.Regex(
                @"^(?:\s*)(?:Error:|Exception:|FATAL:|FATAL ERROR:|error\s+\w+:|\w+\.?Exception:)",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase
                | System.Text.RegularExpressions.RegexOptions.Compiled);

        // Recognises the PowerShell prompt (`PS C:\path> `), the legacy
        // `>` continuation prompt, and Claude Code's `❯ ` TUI glyph.
        private static readonly System.Text.RegularExpressions.Regex PromptLineRegex =
            new System.Text.RegularExpressions.Regex(
                @"^\s*(?:PS\s+[^>\n]+>\s*$|>\s*$|❯\s*.*$)",
                System.Text.RegularExpressions.RegexOptions.Compiled);

        private static string ClassifyLine(string line)
        {
            if (string.IsNullOrEmpty(line))
            {
                return "output";
            }

            // Error patterns checked first — `Exception:` lines could also
            // visually look like prompts if they contain `>` later, so
            // priority matters.
            if (ErrorLineRegex.IsMatch(line))
            {
                return "error";
            }

            if (PromptLineRegex.IsMatch(line))
            {
                return "prompt";
            }

            return "output";
        }

        // γ3 (2026-04-29): structured read of the console buffer.
        // Returns one entry per line with {lineNum, type, text}. Types are
        // "prompt" (PS prompt glyph or Claude Code ❯), "error" (matches a
        // known error-line shape), or "output" (default). Designed to drive
        // smarter loop classifier behaviour without OCR — see
        // `docs/wizard/Not_Finished.md` for the original spec.
        private static object ReadStructured(int maxLines)
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                return new { status = "error", error = "unsupported_platform" };
            }

            ConsoleReadResult result = WindowsConsole.Read(maxLines);
            string[] sourceLines = result.Lines ?? System.Array.Empty<string>();
            var typed = new object[sourceLines.Length];
            for (int i = 0; i < sourceLines.Length; i++)
            {
                string text = sourceLines[i] ?? string.Empty;
                typed[i] = new
                {
                    lineNum = i + 1,
                    type = ClassifyLine(text),
                    text
                };
            }

            return new
            {
                status = "ok",
                method = "native_console",
                lines = typed,
                width = result.Width,
                height = result.Height,
                window = result.Window
            };
        }

        private static object Write(string text, bool submit)
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                return new { status = "error", error = "unsupported_platform" };
            }

            int written = WindowsConsole.WriteInput(submit ? text + "\r" : text);
            return new { status = "ok", method = "native_console", written };
        }

        private void WriteSessionRecord()
        {
            try
            {
                var payload = new
                {
                    provider = "powershell",
                    pid = Environment.ProcessId,
                    pipe = _pipeName,
                    protocol = ProtocolVersion,
                    cwd = Environment.CurrentDirectory,
                    executable = Environment.ProcessPath,
                    startedAt = _startedAt,
                    updatedAt = DateTimeOffset.UtcNow
                };
                File.WriteAllText(_sessionPath, JsonSerializer.Serialize(payload), Encoding.UTF8);
            }
            catch
            {
            }
        }

        private static string GetString(JsonElement element, string name)
        {
            return element.TryGetProperty(name, out JsonElement property) && property.ValueKind == JsonValueKind.String
                ? property.GetString()
                : null;
        }

        private static int GetInt(JsonElement element, string name, int fallback)
        {
            return element.TryGetProperty(name, out JsonElement property) && property.TryGetInt32(out int value)
                ? value
                : fallback;
        }

        private static bool GetBool(JsonElement element, string name, bool fallback)
        {
            return element.TryGetProperty(name, out JsonElement property) && property.ValueKind is JsonValueKind.True or JsonValueKind.False
                ? property.GetBoolean()
                : fallback;
        }

        private readonly struct ConsoleReadResult
        {
            internal ConsoleReadResult(string text, string[] lines, int width, int height, int[] window)
            {
                Text = text;
                Lines = lines;
                Width = width;
                Height = height;
                Window = window;
            }

            internal string Text { get; }

            internal string[] Lines { get; }

            internal int Width { get; }

            internal int Height { get; }

            internal int[] Window { get; }
        }

        private static class WindowsConsole
        {
            private const int STD_INPUT_HANDLE = -10;
            private const int STD_OUTPUT_HANDLE = -11;

            internal static int WriteInput(string text)
            {
                if (text.Length == 0)
                {
                    return 0;
                }

                IntPtr handle = GetStdHandle(STD_INPUT_HANDLE);
                INPUT_RECORD[] records = BuildInputRecords(text);
                if (!WriteConsoleInput(handle, records, (uint)records.Length, out uint written))
                {
                    throw new IOException("WriteConsoleInput failed: " + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture));
                }

                return (int)written;
            }

            internal static ConsoleReadResult Read(int maxLines)
            {
                IntPtr handle = GetStdHandle(STD_OUTPUT_HANDLE);
                if (!GetConsoleScreenBufferInfo(handle, out CONSOLE_SCREEN_BUFFER_INFO info))
                {
                    throw new IOException("GetConsoleScreenBufferInfo failed: " + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture));
                }

                int width = Math.Max(1, (int)info.dwSize.X);
                int height = Math.Max(1, (int)info.dwSize.Y);
                int firstRow = Math.Max(0, info.srWindow.Bottom - Math.Max(1, maxLines) + 1);
                string[] lines = new string[Math.Max(0, info.srWindow.Bottom - firstRow + 1)];
                StringBuilder text = new StringBuilder();

                for (int row = firstRow; row <= info.srWindow.Bottom; row++)
                {
                    StringBuilder buffer = new StringBuilder(width);
                    buffer.EnsureCapacity(width);
                    if (!ReadConsoleOutputCharacter(handle, buffer, (uint)width, new COORD { X = 0, Y = (short)row }, out uint read))
                    {
                        throw new IOException("ReadConsoleOutputCharacter failed: " + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture));
                    }

                    string line = buffer.ToString().TrimEnd();
                    int index = row - firstRow;
                    lines[index] = line;
                    if (text.Length > 0)
                    {
                        text.Append('\n');
                    }

                    text.Append(line);
                }

                return new ConsoleReadResult(
                    text.ToString().Trim(),
                    lines,
                    width,
                    height,
                    new[] { (int)info.srWindow.Left, (int)info.srWindow.Top, (int)info.srWindow.Right, (int)info.srWindow.Bottom });
            }

            private static INPUT_RECORD[] BuildInputRecords(string text)
            {
                INPUT_RECORD[] records = new INPUT_RECORD[text.Length * 2];
                for (int index = 0; index < text.Length; index++)
                {
                    char value = text[index];
                    short virtualKey = value == '\r' ? (short)0x0D : (short)0;
                    records[index * 2] = INPUT_RECORD.Key(value, virtualKey, keyDown: true);
                    records[index * 2 + 1] = INPUT_RECORD.Key(value, virtualKey, keyDown: false);
                }

                return records;
            }

            [DllImport("kernel32.dll", SetLastError = true)]
            private static extern IntPtr GetStdHandle(int nStdHandle);

            [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
            private static extern bool WriteConsoleInput(IntPtr hConsoleInput, INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsWritten);

            [DllImport("kernel32.dll", SetLastError = true)]
            private static extern bool GetConsoleScreenBufferInfo(IntPtr hConsoleOutput, out CONSOLE_SCREEN_BUFFER_INFO lpConsoleScreenBufferInfo);

            [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
            private static extern bool ReadConsoleOutputCharacter(IntPtr hConsoleOutput, StringBuilder lpCharacter, uint nLength, COORD dwReadCoord, out uint lpNumberOfCharsRead);

            [StructLayout(LayoutKind.Sequential)]
            private struct COORD
            {
                internal short X;
                internal short Y;
            }

            [StructLayout(LayoutKind.Sequential)]
            private struct SMALL_RECT
            {
                internal short Left;
                internal short Top;
                internal short Right;
                internal short Bottom;
            }

            [StructLayout(LayoutKind.Sequential)]
            private struct CONSOLE_SCREEN_BUFFER_INFO
            {
                internal COORD dwSize;
                internal COORD dwCursorPosition;
                internal short wAttributes;
                internal SMALL_RECT srWindow;
                internal COORD dwMaximumWindowSize;
            }

            [StructLayout(LayoutKind.Sequential)]
            private struct KEY_EVENT_RECORD
            {
                [MarshalAs(UnmanagedType.Bool)]
                internal bool bKeyDown;
                internal ushort wRepeatCount;
                internal short wVirtualKeyCode;
                internal short wVirtualScanCode;
                internal char UnicodeChar;
                internal uint dwControlKeyState;
            }

            [StructLayout(LayoutKind.Explicit)]
            private struct INPUT_RECORD
            {
                [FieldOffset(0)]
                internal ushort EventType;

                [FieldOffset(4)]
                internal KEY_EVENT_RECORD KeyEvent;

                internal static INPUT_RECORD Key(char value, short virtualKey, bool keyDown)
                {
                    return new INPUT_RECORD
                    {
                        EventType = 0x0001,
                        KeyEvent = new KEY_EVENT_RECORD
                        {
                            bKeyDown = keyDown,
                            wRepeatCount = 1,
                            wVirtualKeyCode = virtualKey,
                            UnicodeChar = value
                        }
                    };
                }
            }
        }
    }

    internal readonly struct WizardControlSnapshot
    {
        internal WizardControlSnapshot(
            bool promptActive,
            bool shouldEndSession,
            string runspaceState,
            string windowTitle,
            string currentCommand = null,
            string lastCommand = null,
            int historyCount = 0)
        {
            PromptActive = promptActive;
            ShouldEndSession = shouldEndSession;
            RunspaceState = runspaceState;
            WindowTitle = windowTitle;
            CurrentCommand = currentCommand;
            LastCommand = lastCommand;
            HistoryCount = historyCount;
        }

        internal bool PromptActive { get; }

        internal bool ShouldEndSession { get; }

        internal string RunspaceState { get; }

        internal string WindowTitle { get; }

        // Phase γ2: programmatic command introspection so DAB doesn't have to OCR
        // the screen to know what's running in a tab. Populated on demand in
        // ConsoleHost.GetWizardControlSnapshot when the caller asks for the extended view.
        internal string CurrentCommand { get; }

        internal string LastCommand { get; }

        internal int HistoryCount { get; }
    }
}
