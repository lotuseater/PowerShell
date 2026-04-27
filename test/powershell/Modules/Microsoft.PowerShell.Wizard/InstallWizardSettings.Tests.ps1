# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Install-WizardSettings.ps1 rewriter" -Tags "Feature" {
    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot '..\..\..\..\tools\wizard\Install-WizardSettings.ps1' | Resolve-Path | ForEach-Object Path
        $script:Pwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh'

        function New-FakeSettings {
            param([string] $Dir, [string] $HookFlatPath, [string] $HookSubdirPath)
            $cfg = @{
                hooks = @{
                    UserPromptSubmit = @(@{
                        hooks = @(@{
                            type = 'command'
                            command = "& py -3.14 '$HookFlatPath'"
                            shell = 'powershell'
                        })
                    })
                    PreToolUse = @(
                        @{ matcher = 'Bash'; hooks = @(@{ type = 'command'; command = 'echo unrelated' }) },
                        @{ matcher = 'Read'; hooks = @(@{ type = 'command'; command = "& py -3.14 '$HookSubdirPath'" }) }
                    )
                }
            }
            $path = Join-Path $Dir 'settings.json'
            $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
            return $path
        }

        function Invoke-Rewriter {
            param([string[]] $ExtraArgs)
            $args = @('-NoProfile', '-NoLogo', '-File', $script:Script) + $ExtraArgs
            $proc = & $script:Pwsh @args 2>&1
            return [pscustomobject]@{
                Output   = $proc -join "`n"
                ExitCode = $LASTEXITCODE
            }
        }
    }

    Context "rewrite cognitive_pulse-style flat hook" {
        It "preserves the original command verbatim in the fallback arm" {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-rewrite-$([Guid]::NewGuid().ToString('N'))")
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            try {
                $original = "C:\fake\Wizard_Erasmus\src\mcp\cognitive_pulse_hook.py"
                $settings = New-FakeSettings -Dir $tmp -HookFlatPath $original -HookSubdirPath 'C:\\fake\\hooks\\pretool_cache_hook.py'

                $r = Invoke-Rewriter -ExtraArgs @('-SettingsPath', $settings, '-HookName', 'cognitive_pulse', '-Confirm:$false')
                $r.ExitCode | Should -Be 0

                $body = Get-Content -LiteralPath $settings -Raw
                $body | Should -Match 'Invoke-WizardHook -Name cognitive_pulse'
                # The fallback arm must contain the EXACT original path so subdir paths aren't lost.
                # JSON serialisation double-escapes backslashes, so check both forms.
                $bodyDecoded = $body -replace '\\\\', '\'
                $bodyDecoded | Should -Match ([regex]::Escape($original))
                $body | Should -Match 'WIZARD_HOOKS_REWIRED'
            } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It "is idempotent — second run reports no changes" {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-rewrite-idem-$([Guid]::NewGuid().ToString('N'))")
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            try {
                $settings = New-FakeSettings -Dir $tmp -HookFlatPath 'C:\fake\cognitive_pulse_hook.py' -HookSubdirPath 'C:\fake\hooks\pretool_cache_hook.py'

                $r1 = Invoke-Rewriter -ExtraArgs @('-SettingsPath', $settings, '-HookName', 'cognitive_pulse', '-Confirm:$false')
                $r1.ExitCode | Should -Be 0

                $afterFirst = Get-Content -LiteralPath $settings -Raw
                $r2 = Invoke-Rewriter -ExtraArgs @('-SettingsPath', $settings, '-HookName', 'cognitive_pulse', '-Confirm:$false')
                $r2.ExitCode | Should -Be 0

                $afterSecond = Get-Content -LiteralPath $settings -Raw
                # Body must be unchanged — no double-wrap.
                $afterSecond.TrimEnd() | Should -BeExactly $afterFirst.TrimEnd()
            } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context "rewrite subdirectory hook (pretool_cache)" {
        It "preserves the subdir path so the fallback works" {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-rewrite-sub-$([Guid]::NewGuid().ToString('N'))")
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            try {
                $subPath = "C:\fake\Wizard_Erasmus\src\mcp\hooks\pretool_cache_hook.py"
                $settings = New-FakeSettings -Dir $tmp -HookFlatPath 'C:\fake\cognitive_pulse_hook.py' -HookSubdirPath $subPath

                $r = Invoke-Rewriter -ExtraArgs @('-SettingsPath', $settings, '-HookName', 'pretool_cache', '-Confirm:$false')
                $r.ExitCode | Should -Be 0

                $body = Get-Content -LiteralPath $settings -Raw
                $body | Should -Match 'Invoke-WizardHook -Name pretool_cache'
                # JSON double-escapes backslashes; decode before matching the literal subdir path.
                $bodyDecoded = $body -replace '\\\\', '\'
                $bodyDecoded | Should -Match ([regex]::Escape($subPath))
            } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context "-Restore" {
        It "rolls back to the most recent backup" {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-restore-$([Guid]::NewGuid().ToString('N'))")
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            try {
                $settings = New-FakeSettings -Dir $tmp -HookFlatPath 'C:\fake\cognitive_pulse_hook.py' -HookSubdirPath 'C:\fake\hooks\pretool_cache_hook.py'
                $before = Get-Content -LiteralPath $settings -Raw

                Invoke-Rewriter -ExtraArgs @('-SettingsPath', $settings, '-HookName', 'cognitive_pulse', '-Confirm:$false') | Out-Null
                $after = Get-Content -LiteralPath $settings -Raw
                $after | Should -Not -BeExactly $before

                $r = Invoke-Rewriter -ExtraArgs @('-SettingsPath', $settings, '-Restore', '-Confirm:$false')
                $r.ExitCode | Should -Be 0

                $restored = Get-Content -LiteralPath $settings -Raw
                $restored.TrimEnd() | Should -BeExactly $before.TrimEnd()
            } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
