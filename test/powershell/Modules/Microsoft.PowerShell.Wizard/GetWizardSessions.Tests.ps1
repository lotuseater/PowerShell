# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

Describe "Get-WizardSessions" -Tags "Feature" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Modules' 'Shared' 'Microsoft.PowerShell.Wizard' 'Microsoft.PowerShell.Wizard.psd1'
        $modulePath = Resolve-Path $modulePath
        Import-Module $modulePath -Force

        $script:Pwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh'
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wizard-sessions-$([Guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TempRoot) {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "returns nothing when the session root is empty" {
        $r = @(Get-WizardSessions -SessionRoot $TempRoot)
        $r.Count | Should -Be 0
    }

    It "lists live sessions and excludes stale ones by default" {
        $live = [pscustomobject]@{
            pid         = $PID
            pipe        = "wizard-pwsh-$PID"
            protocol    = 1
            cwd         = (Get-Location).ProviderPath
            executable  = (Get-Process -Id $PID).Path
            processName = (Get-Process -Id $PID).ProcessName
            startedAt   = (Get-Date).ToUniversalTime().ToString('o')
            updatedAt   = (Get-Date).ToUniversalTime().ToString('o')
        }
        $livePath = Join-Path $TempRoot "$PID.json"
        $live | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $livePath -Encoding utf8

        $stalePid = 999999
        $stale = $live.PSObject.Copy()
        $stale.pid = $stalePid
        $stale.pipe = "wizard-pwsh-$stalePid"
        $stalePath = Join-Path $TempRoot "$stalePid.json"
        $stale | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stalePath -Encoding utf8

        $alive = @(Get-WizardSessions -SessionRoot $TempRoot)
        $alive.Count | Should -Be 1
        $alive[0].Pid | Should -Be $PID
        $alive[0].PipeName | Should -BeExactly "wizard-pwsh-$PID"
        $alive[0].IsAlive | Should -BeTrue

        $all = @(Get-WizardSessions -SessionRoot $TempRoot -IncludeStale)
        $all.Count | Should -Be 2
        ($all | Where-Object Pid -eq $stalePid).IsAlive | Should -BeFalse
    }

    It "tolerates malformed JSON files (skips them silently)" {
        $bogusPath = Join-Path $TempRoot 'bogus.json'
        Set-Content -LiteralPath $bogusPath -Value '{this is not json'
        { Get-WizardSessions -SessionRoot $TempRoot | Out-Null } | Should -Not -Throw
        Remove-Item -LiteralPath $bogusPath -Force
    }

    It "exposes PSTypeName='WizardSessionEntry' on each result" {
        $r = @(Get-WizardSessions -SessionRoot $TempRoot)
        if ($r.Count -gt 0) {
            $r[0].PSTypeNames | Should -Contain 'WizardSessionEntry'
        }
    }

    It "returns nothing without throwing when the SessionRoot doesn't exist" {
        $missing = Join-Path $TempRoot 'definitely-not-there'
        $r = @(Get-WizardSessions -SessionRoot $missing)
        $r.Count | Should -Be 0
    }

    It "caps live sessions after sorting newest files first" {
        $root = Join-Path $TempRoot "top-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        try {
            foreach ($idx in 1..3) {
                $payload = [pscustomobject]@{
                    pid         = $PID
                    pipe        = "wizard-pwsh-top-$idx"
                    protocol    = 1
                    cwd         = (Get-Location).ProviderPath
                    executable  = (Get-Process -Id $PID).Path
                    processName = (Get-Process -Id $PID).ProcessName
                    startedAt   = (Get-Date).AddMinutes($idx).ToUniversalTime().ToString('o')
                    updatedAt   = (Get-Date).AddMinutes($idx).ToUniversalTime().ToString('o')
                }
                $path = Join-Path $root "$idx.json"
                $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8
                (Get-Item -LiteralPath $path).LastWriteTimeUtc = (Get-Date).AddMinutes($idx).ToUniversalTime()
            }

            $r = @(Get-WizardSessions -SessionRoot $root -Top 2)
            $r.Count | Should -Be 2
            $r[0].PipeName | Should -BeExactly 'wizard-pwsh-top-3'
            $r[1].PipeName | Should -BeExactly 'wizard-pwsh-top-2'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Clear-WizardStaleSessions removes dead records and keeps live records" {
        $root = Join-Path $TempRoot "cleanup-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        try {
            $live = [pscustomobject]@{
                pid         = $PID
                pipe        = "wizard-pwsh-live-$PID"
                protocol    = 1
                cwd         = (Get-Location).ProviderPath
                executable  = (Get-Process -Id $PID).Path
                processName = (Get-Process -Id $PID).ProcessName
                startedAt   = (Get-Date).ToUniversalTime().ToString('o')
                updatedAt   = (Get-Date).ToUniversalTime().ToString('o')
            }
            $stale = $live.PSObject.Copy()
            $stale.pid = 999999
            $stale.pipe = 'wizard-pwsh-stale-999999'
            $live | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'live.json') -Encoding utf8
            $stale | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'stale.json') -Encoding utf8

            $result = Clear-WizardStaleSessions -SessionRoot $root
            $result.Scanned | Should -Be 2
            $result.Removed | Should -Be 1
            $result.KeptLive | Should -Be 1
            Test-Path -LiteralPath (Join-Path $root 'live.json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root 'stale.json') | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
