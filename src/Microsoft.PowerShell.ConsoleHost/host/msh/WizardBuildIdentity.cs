// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using System;
using System.IO;
using System.Reflection;

namespace Microsoft.PowerShell
{
    /// <summary>
    /// Wizard PowerShell fork build identity. Appended to both startup banner and
    /// `pwsh -Version` so the fork is distinguishable from upstream at a glance, with a
    /// human-readable date and configuration. Cheap: computed once on first access from
    /// the host assembly's path (config) and mtime (date).
    /// </summary>
    internal static class WizardBuildIdentity
    {
        private static readonly Lazy<string> s_suffix = new Lazy<string>(ComputeSuffix);

        /// <summary>
        /// Returns "(wizard Release 2026-04-28T0427Z)" or empty string on any failure.
        /// Format matches the date+config the rest of the wizard surface uses
        /// (`$PSVersionTable.WizardBuild`).
        /// </summary>
        internal static string Suffix => s_suffix.Value;

        private static string ComputeSuffix()
        {
            try
            {
                string assemblyPath = typeof(WizardBuildIdentity).Assembly.Location;
                if (string.IsNullOrEmpty(assemblyPath))
                {
                    return string.Empty;
                }

                string config = "unknown";
                if (assemblyPath.Contains("\\Release\\", StringComparison.OrdinalIgnoreCase)
                    || assemblyPath.Contains("/Release/", StringComparison.OrdinalIgnoreCase))
                {
                    config = "Release";
                }
                else if (assemblyPath.Contains("\\Debug\\", StringComparison.OrdinalIgnoreCase)
                         || assemblyPath.Contains("/Debug/", StringComparison.OrdinalIgnoreCase))
                {
                    config = "Debug";
                }

                string date = File.GetLastWriteTimeUtc(assemblyPath).ToString("yyyy-MM-ddTHHmm");
                return $"(wizard {config} {date}Z)";
            }
            catch
            {
                return string.Empty;
            }
        }
    }
}
