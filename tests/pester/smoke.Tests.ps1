# Pester 5 tests for tests/smoke.ps1, driven by a fake wrapper that simulates the broker.
Describe 'smoke.ps1' {
    BeforeAll {
        $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:Smoke = Join-Path $Repo 'tests\smoke.ps1'
        $script:Fake = Join-Path $TestDrive 'fake-tmuxkeep.ps1'
        $fakeText = @'
# Fake wrapper: simulates the broker for smoke.ps1 tests. State lives in $env:TMUXKEEP_FAKE_DIR.
$dir = $env:TMUXKEEP_FAKE_DIR
Add-Content -LiteralPath (Join-Path $dir 'calls.log') -Value ($args -join ' ') -Encoding ascii
$stateFile = Join-Path $dir 'state'
$nameFile = Join-Path $dir 'name'
$lockFile = Join-Path $dir 'locked'
$verb = [string]$args[0]
$name = [string]$args[1]
switch -CaseSensitive ($verb) {
    'auth'    { exit 0 }
    'new'     { Set-Content -LiteralPath $nameFile -Value $name -Encoding ascii
                Set-Content -LiteralPath $stateFile -Value 'live' -Encoding ascii
                "created $name in /home/claude/work/$name"; exit 0 }
    'ls'      { $s = Get-Content -LiteralPath $stateFile -ErrorAction SilentlyContinue
                $n = Get-Content -LiteralPath $nameFile -ErrorAction SilentlyContinue
                'NAME  STATE  ATTACHED  AGE  IDLE  TITLE'
                if ($s -eq 'live') { "$n  live    1m  1m  x" }
                if ($s -eq 'tombstone') { "zz~$n~1790000000  tombstone    1m  1m  x" }
                exit 0 }
    'status'  { if ($env:TMUXKEEP_FAKE_STATUS_BAD) { '{"sessions":[{"name":"'; exit 0 }
                $s = Get-Content -LiteralPath $stateFile -ErrorAction SilentlyContinue
                $n = Get-Content -LiteralPath $nameFile -ErrorAction SilentlyContinue
                if ($s -eq 'live' -and -not $env:TMUXKEEP_FAKE_STATUS_EMPTY) { '{"version":"x","sessions":[{"name":"' + $n + '","state":"live"}]}' }
                else { '{"version":"x","sessions":[]}' }
                exit 0 }
    'peek'    { 'some pane text'; exit 0 }
    'send'    { "sent 5 bytes to $name"; exit 0 }
    'lock'    { Set-Content -LiteralPath $lockFile -Value 1 -Encoding ascii; "locked $name"; exit 0 }
    'unlock'  { Remove-Item -LiteralPath $lockFile -ErrorAction SilentlyContinue; "unlocked $name"; exit 0 }
    'rm'      { if ((Test-Path -LiteralPath $lockFile) -and -not $env:TMUXKEEP_FAKE_IGNORE_LOCK) { exit 3 }
                if (($args -ccontains '--now') -and $env:TMUXKEEP_FAKE_RM_NOW_LOCKED) { exit 3 }
                if ($args -ccontains '--now') { Set-Content -LiteralPath $stateFile -Value 'gone' -Encoding ascii; "killed $name"; exit 0 }
                Set-Content -LiteralPath $stateFile -Value 'tombstone' -Encoding ascii
                "tombstoned $name; still running, reaped after 24h; restore with: tmuxkeep restore $name"; exit 0 }
    'restore' { Set-Content -LiteralPath $stateFile -Value 'live' -Encoding ascii; "restored $name"; exit 0 }
    'log'     { foreach ($c in Get-Content -LiteralPath (Join-Path $dir 'calls.log')) {
                    $w = $c -split ' '
                    if ($env:TMUXKEEP_FAKE_STATUS_UNAUDITED -and $w[0] -ceq 'status') { continue }
                    if ($w[0] -ceq 'status') {
                        # What the broker writes for a one-shot status: ok true, detail lines=N (12 unless told otherwise).
                        $ok = if ($env:TMUXKEEP_FAKE_STATUS_AUDIT -ceq 'failed') { 'false' } else { 'true' }
                        $detail = if ($env:TMUXKEEP_FAKE_STATUS_AUDIT -ceq 'other') { 'lines=5' } else { 'lines=12' }
                        '{{"verb":"status","session":"","ok":{0},"detail":"{1}"}}' -f $ok, $detail
                        continue
                    }
                    '{{"verb":"{0}","session":"{1}"}}' -f $w[0], $(if ($w.Count -gt 1) { $w[1] } else { '' })
                }
                exit 0 }
    default   { exit 2 }
}
'@
        Set-Content -LiteralPath $Fake -Value $fakeText -Encoding ascii
    }

    BeforeEach {
        $env:TMUXKEEP_FAKE_DIR = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
        Remove-Item Env:\TMUXKEEP_FAKE_IGNORE_LOCK -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_RM_NOW_LOCKED -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_STATUS_EMPTY -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_STATUS_BAD -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_STATUS_UNAUDITED -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_STATUS_AUDIT -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item Env:\TMUXKEEP_FAKE_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_IGNORE_LOCK -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_RM_NOW_LOCKED -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_STATUS_EMPTY -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_STATUS_BAD -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_STATUS_UNAUDITED -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_STATUS_AUDIT -ErrorAction SilentlyContinue
    }

    It 'passes against a broker that behaves' {
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String -Width 4096
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'smoke: all steps passed'
        ([regex]::Matches($out, '(?m)^PASS ')).Count | Should -Be 14
    }

    It 'runs auth first and uses a fresh smoke-xxxxxx name (6 chars)' {
        & $Smoke -Wrapper $Fake *>&1 | Out-Null
        $calls = @(Get-Content -LiteralPath (Join-Path $env:TMUXKEEP_FAKE_DIR 'calls.log'))
        $calls[0] | Should -BeExactly 'auth'
        $calls[1] | Should -Match '^new smoke-[a-z0-9]{6}$'
    }

    It 'fails with exit 1 when rm is not refused on a locked session' {
        $env:TMUXKEEP_FAKE_IGNORE_LOCK = '1'
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String -Width 4096
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'FAIL'
        $out | Should -Not -Match 'smoke: all steps passed'
    }

    It 'stops at the first failure' {
        $env:TMUXKEEP_FAKE_IGNORE_LOCK = '1'
        & $Smoke -Wrapper $Fake *>&1 | Out-Null
        $calls = @(Get-Content -LiteralPath (Join-Path $env:TMUXKEEP_FAKE_DIR 'calls.log'))
        $calls[-1] | Should -Match '^rm smoke-[a-z0-9]{6}$'
    }

    It 'prints the cleanup hint once, with restore before unlock, when rm --now is refused as locked' {
        $env:TMUXKEEP_FAKE_RM_NOW_LOCKED = '1'
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String -Width 4096
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'FAIL 13/14'
        $out | Should -Match '(?s)tmuxkeep rm smoke-[a-z0-9]{6} --now --confirm smoke-[a-z0-9]{6}.*restore.*unlock'
        [regex]::Matches($out, 'To clean it up').Count | Should -Be 1
    }

    It 'step 4 fails, with the cleanup hint, when the status JSON does not name the session' {
        $env:TMUXKEEP_FAKE_STATUS_EMPTY = '1'
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String -Width 4096
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'FAIL 4/14 status \(JSON naming the session\): the status output does not name smoke-[a-z0-9]{6}'
        [regex]::Matches($out, 'To clean it up').Count | Should -Be 1
        $calls = @(Get-Content -LiteralPath (Join-Path $env:TMUXKEEP_FAKE_DIR 'calls.log'))
        $calls[-1] | Should -BeExactly 'status'
    }

    It 'step 14 fails when the audit log has no status line, as with a broker that does not audit status' {
        $env:TMUXKEEP_FAKE_STATUS_UNAUDITED = '1'
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String -Width 4096
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'FAIL 14/14 log -n 20 \(audit lines for this session\): no audit line with verb status, no session, ok true and detail lines=12'
        $out | Should -Not -Match 'smoke: all steps passed'
    }

    # Final review L180: the status line must be a successful one with the default 12 lines, not just any line.
    It 'step 14 fails when the status audit line is a failure, or has another detail than lines=12' -ForEach @('failed', 'other') {
        $env:TMUXKEEP_FAKE_STATUS_AUDIT = $_
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String -Width 4096
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'FAIL 14/14 log -n 20 \(audit lines for this session\): no audit line with verb status, no session, ok true and detail lines=12'
        $out | Should -Not -Match 'smoke: all steps passed'
    }

    It 'step 14 passes on a status audit line with ok true and detail lines=12' {
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String -Width 4096
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'PASS 14/14 log -n 20'
        $out | Should -Match 'smoke: all steps passed'
    }

    It 'step 4 fails when the status output is not JSON' {
        $env:TMUXKEEP_FAKE_STATUS_BAD = '1'
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String -Width 4096
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'FAIL 4/14'
    }
}
