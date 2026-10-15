# Pester 5 tests for laptop/profile-snippet.ps1 (spec 9.2, 12.2). ssh is always mocked.
Describe 'profile snippet' {
    BeforeAll {
        $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:Snippet = Join-Path $Repo 'laptop\profile-snippet.ps1'
        $script:FakeBin = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $FakeBin | Out-Null
        Set-Content -LiteralPath (Join-Path $FakeBin 'ssh.cmd') -Value '@exit /b 99' -Encoding ascii
        $script:OldPath = $env:PATH
        $script:OldTemp = $env:TEMP
        $env:PATH = "$FakeBin;$env:PATH"
        . $Snippet
    }

    AfterAll {
        $env:PATH = $OldPath
        $env:TEMP = $OldTemp
        Remove-Variable -Name TmuxkeepSshArgs -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $env:TEMP = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
        $global:TmuxkeepSshArgs = $null
        Mock ssh { $global:TmuxkeepSshArgs = @($args); $global:LASTEXITCODE = 0; 'api'; 'web' }
    }

    Describe 'profile snippet text' {
        It 'is wrapped in the tmuxkeep markers' {
            $lines = @(Get-Content -LiteralPath $Snippet | Where-Object { $_.Trim() })
            $lines[0] | Should -BeExactly '# >>> tmuxkeep'
            $lines[-1] | Should -BeExactly '# <<< tmuxkeep'
        }

        It 'is ASCII only' {
            @([IO.File]::ReadAllBytes($Snippet) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }

        It 'defines tmuxkeep as a call to ~\scripts\tmuxkeep.ps1 with @args' {
            (Get-Command tmuxkeep -CommandType Function).Definition |
                Should -Match ([regex]::Escape('& "$HOME\scripts\tmuxkeep.ps1" @args'))
        }
    }

    Describe 'Get-TmuxkeepCompletionList' {
        It 'fetches names with plain ls --names over BatchMode ssh, then serves the cache' {
            (@(Get-TmuxkeepCompletionList names) -join ',') | Should -BeExactly 'api,web'
            ($global:TmuxkeepSshArgs -join ' ') | Should -BeExactly '-n -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 tmuxkeep ls --names'
            (@(Get-TmuxkeepCompletionList names) -join ',') | Should -BeExactly 'api,web'
            Should -Invoke ssh -Times 1 -Exactly
            Test-Path -LiteralPath (Join-Path $env:TEMP 'tmuxkeep-names.txt') | Should -BeTrue
        }

        It 'uses ls --tombstones and its own cache file' {
            Get-TmuxkeepCompletionList tombstones | Out-Null
            ($global:TmuxkeepSshArgs -join ' ') | Should -BeExactly '-n -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 tmuxkeep ls --tombstones'
            Test-Path -LiteralPath (Join-Path $env:TEMP 'tmuxkeep-tombstones.txt') | Should -BeTrue
        }

        It 'refetches once the cache is older than 60 seconds' {
            Get-TmuxkeepCompletionList names | Out-Null
            (Get-Item -LiteralPath (Join-Path $env:TEMP 'tmuxkeep-names.txt')).LastWriteTime = (Get-Date).AddSeconds(-61)
            Get-TmuxkeepCompletionList names | Out-Null
            Should -Invoke ssh -Times 2 -Exactly
        }

        It 'caches a failed fetch as empty for 60 seconds' {
            Mock ssh { $global:LASTEXITCODE = 255 }
            @(Get-TmuxkeepCompletionList names).Count | Should -Be 0
            @(Get-TmuxkeepCompletionList names).Count | Should -Be 0
            Should -Invoke ssh -Times 1 -Exactly
            (Get-Item -LiteralPath (Join-Path $env:TEMP 'tmuxkeep-names.txt')).Length | Should -Be 0
        }

        It 'still returns the names when ssh writes to stderr and the caller has ErrorActionPreference Stop' {
            # A real native child writing to stderr: [Console]::Error would bypass the PowerShell
            # error stream, so it could not reproduce the 2>$null error record under Stop.
            Mock ssh { & cmd.exe /c 'echo banner 1>&2'; $global:LASTEXITCODE = 0; 'api'; 'web' }
            $old = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Stop'
                $got = @(Get-TmuxkeepCompletionList names)
            }
            finally {
                $ErrorActionPreference = $old
            }
            ($got -join ',') | Should -BeExactly 'api,web'
        }

        It 'a future-dated cache is refetched; a fresh one is served' {
            $file = Join-Path $env:TEMP 'tmuxkeep-names.txt'
            Set-Content -LiteralPath $file -Value @('stale') -Encoding ascii
            (Get-Item -LiteralPath $file).LastWriteTime = (Get-Date).AddHours(2)
            (@(Get-TmuxkeepCompletionList names) -join ',') | Should -BeExactly 'api,web'
            Should -Invoke ssh -Times 1 -Exactly
            (@(Get-TmuxkeepCompletionList names) -join ',') | Should -BeExactly 'api,web'
            Should -Invoke ssh -Times 1 -Exactly
        }

        It 'leaves the caller LASTEXITCODE as it was' {
            $global:LASTEXITCODE = 42
            Get-TmuxkeepCompletionList names | Out-Null
            Should -Invoke ssh -Times 1 -Exactly
            $LASTEXITCODE | Should -Be 42
        }
    }

    Describe 'registered completer' {
        It 'completes verbs for the first word' {
            $r = TabExpansion2 -inputScript 'tmuxkeep re' -cursorColumn 11
            ($r.CompletionMatches.CompletionText -join ',') | Should -BeExactly 'rename,restore,resume'
        }

        It 'completes status for the first word' {
            $r = TabExpansion2 -inputScript 'tmuxkeep st' -cursorColumn 11
            ($r.CompletionMatches.CompletionText -join ',') | Should -BeExactly 'status'
        }

        It 'completes the local ui verb for the first word' {
            $r = TabExpansion2 -inputScript 'tmuxkeep ui' -cursorColumn 11
            ($r.CompletionMatches.CompletionText -join ',') | Should -BeExactly 'ui'
        }

        It 'completes cached session names after go' {
            Set-Content -LiteralPath (Join-Path $env:TEMP 'tmuxkeep-names.txt') -Value @('api', 'web') -Encoding ascii
            $r = TabExpansion2 -inputScript 'tmuxkeep go a' -cursorColumn 13
            ($r.CompletionMatches.CompletionText -join ',') | Should -BeExactly 'api'
        }

        It 'completes tombstone base names after restore' {
            Set-Content -LiteralPath (Join-Path $env:TEMP 'tmuxkeep-tombstones.txt') -Value @('old') -Encoding ascii
            $r = TabExpansion2 -inputScript 'tmuxkeep restore ' -cursorColumn 17
            ($r.CompletionMatches.CompletionText -join ',') | Should -BeExactly 'old'
        }

        It 'offers no session names after new' {
            Set-Content -LiteralPath (Join-Path $env:TEMP 'tmuxkeep-names.txt') -Value @('api') -Encoding ascii
            $r = TabExpansion2 -inputScript 'tmuxkeep new ' -cursorColumn 13
            @($r.CompletionMatches | Where-Object { $_.CompletionText -eq 'api' }).Count | Should -Be 0
        }

        It 'a bracket in the typed word does not throw' {
            Set-Content -LiteralPath (Join-Path $env:TEMP 'tmuxkeep-names.txt') -Value @('a[b', 'api') -Encoding ascii
            $before = $Error.Count
            $r = TabExpansion2 -inputScript 'tmuxkeep go a[' -cursorColumn 14
            $after = $Error.Count
            ($r.CompletionMatches.CompletionText -join ',') | Should -BeExactly 'a[b'
            $after | Should -Be $before
        }
    }
}
