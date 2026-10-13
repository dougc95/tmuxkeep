# Pester 5 tests for laptop/tmuxkeep.ps1 (spec 9.1, 12.2). ssh is always mocked.
Describe 'tmuxkeep.ps1' {
    BeforeAll {
        $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:Wrapper = Join-Path $Repo 'laptop\tmuxkeep.ps1'
        # Safety net: if a mock ever fails to intercept, this fake answers instead of the real ssh.
        $script:FakeBin = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $FakeBin | Out-Null
        Set-Content -LiteralPath (Join-Path $FakeBin 'ssh.cmd') -Value '@exit /b 99' -Encoding ascii
        $script:OldPath = $env:PATH
        $env:PATH = "$FakeBin;$env:PATH"

        function B64([string]$s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
        function Expected([string[]]$Words, [switch]$Tty) {
            $a = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5')
            if ($Tty) { $a += '-t' }
            $a += @('tmuxkeep', 'b64')
            foreach ($w in $Words) { $a += (B64 $w) }
            $a -join '|'
        }
        function Actual { $global:TmuxkeepSshArgs -join '|' }
    }

    AfterAll {
        $env:PATH = $OldPath
        Remove-Variable -Name TmuxkeepSshArgs -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $global:TmuxkeepSshArgs = $null
        Mock ssh { $global:TmuxkeepSshArgs = @($args); $global:LASTEXITCODE = 0 }
    }

    Describe 'ssh argument array' {
        It '<Line> uses -t: <Tty>' -ForEach @(
            @{ Line = 'new api';        Tty = $true }
            @{ Line = 'go api';         Tty = $true }
            @{ Line = 'send api hi';    Tty = $true }
            @{ Line = 'rename api web'; Tty = $true }
            @{ Line = 'unlock api';     Tty = $true }
            @{ Line = 'rm api';         Tty = $true }
            @{ Line = 'resume api';     Tty = $true }
            @{ Line = 'auth';           Tty = $true }
            @{ Line = 'ls';             Tty = $false }
            @{ Line = 'peek api';       Tty = $false }
            @{ Line = 'log';            Tty = $false }
            @{ Line = 'lock api';       Tty = $false }
            @{ Line = 'restore api';    Tty = $false }
        ) {
            $words = $Line -split ' '
            & $Wrapper @words
            Actual | Should -BeExactly (Expected $words -Tty:$Tty)
        }

        It 'encodes each word of a multi-word send separately' {
            & $Wrapper send api 'echo hi' there
            Actual | Should -BeExactly (Expected @('send', 'api', 'echo hi', 'there') -Tty)
        }

        It 'encodes non-ASCII text as UTF-8' {
            $cafe = 'caf' + [char]0x00E9
            & $Wrapper send api $cafe
            Actual | Should -BeExactly (Expected @('send', 'api', $cafe) -Tty)
            (B64 $cafe) | Should -BeExactly 'Y2Fmw6k='
        }

        It 'stringifies numbers' {
            & $Wrapper peek api -n 20
            Actual | Should -BeExactly (Expected @('peek', 'api', '-n', '20'))
        }

        It 'flattens nested arrays' {
            & $Wrapper send api @('a', @('b', 'c'))
            Actual | Should -BeExactly (Expected @('send', 'api', 'a', 'b', 'c') -Tty)
        }

        It 'passes -n and -d through the profile function unchanged' {
            function tmuxkeep { & $Wrapper @args }
            tmuxkeep peek api -n 20 -d
            Actual | Should -BeExactly (Expected @('peek', 'api', '-n', '20', '-d'))
        }

        It 'never puts a raw -- on the ssh command line' {
            & $Wrapper send api -- x
            $global:TmuxkeepSshArgs | Should -Not -Contain '--'
        }
    }

    Describe 'local prompts' {
        It 'prompts for the text when send has none, and sends it as one word' {
            Mock Read-Host { 'a; b # $c (d) @e, f' } -ParameterFilter { $Prompt -eq 'Text to send' }
            & $Wrapper send api
            Should -Invoke Read-Host -Times 1 -Exactly
            Actual | Should -BeExactly (Expected @('send', 'api', 'a; b # $c (d) @e, f') -Tty)
        }

        It 'exits 2 without calling ssh when the prompted text is empty' {
            Mock Read-Host { '' }
            & $Wrapper send api
            $LASTEXITCODE | Should -Be 2
            Should -Invoke ssh -Times 0 -Exactly
        }

        It 'rm --now prompts and appends --confirm' {
            Mock Read-Host { 'api' } -ParameterFilter { $Prompt -eq 'Type the session name to confirm' }
            & $Wrapper rm api --now
            Should -Invoke Read-Host -Times 1 -Exactly
            Actual | Should -BeExactly (Expected @('rm', 'api', '--now', '--confirm', 'api') -Tty)
        }

        It 'rm --now with --confirm does not prompt' {
            Mock Read-Host { throw 'must not prompt' }
            & $Wrapper rm api --now --confirm api
            Should -Invoke Read-Host -Times 0 -Exactly
            Actual | Should -BeExactly (Expected @('rm', 'api', '--now', '--confirm', 'api') -Tty)
        }

        It 'plain rm does not prompt' {
            Mock Read-Host { throw 'must not prompt' }
            & $Wrapper rm api
            Should -Invoke Read-Host -Times 0 -Exactly
        }

        It 'an empty confirmation exits 2 without calling ssh' {
            Mock Read-Host { '' }
            & $Wrapper rm api --now
            $LASTEXITCODE | Should -Be 2
            Should -Invoke ssh -Times 0 -Exactly
        }

        It 'verb matching is case-sensitive: RM --now does not prompt' {
            Mock Read-Host { throw 'must not prompt' }
            & $Wrapper RM api --now
            Should -Invoke Read-Host -Times 0 -Exactly
        }
    }

    Describe 'argument validation' {
        It 'rejects an empty argument with exit 2 and no ssh call' {
            & $Wrapper send api ''
            $LASTEXITCODE | Should -Be 2
            Should -Invoke ssh -Times 0 -Exactly
        }

        It 'rejects a $null argument with exit 2 and no ssh call' {
            & $Wrapper send api $null
            $LASTEXITCODE | Should -Be 2
            Should -Invoke ssh -Times 0 -Exactly
        }

        It 'rejects <Name> with exit 2 and no ssh call, without recursing' -ForEach @(
            @{ Name = 'a hashtable';                Expr = '@{ k = 1 }' }
            @{ Name = 'an ordered dictionary';      Expr = '[ordered]@{ k = 1 }' }
            @{ Name = 'an XML node';                Expr = '([xml]"<a/>").DocumentElement' }
            @{ Name = 'a hashtable inside an array'; Expr = "@('a', @(@{ k = 1 }))" }
        ) {
            # Without the guard the wrapper recurses for minutes. Prove it returns promptly in a
            # child job first (a stub ssh function there reports any call); only then run it
            # in-process, where the Pester mock can count ssh calls.
            $job = Start-Job -ArgumentList $Wrapper, $Expr -ScriptBlock {
                param($wrapper, $expr)
                function ssh { 'SSH-CALLED'; $global:LASTEXITCODE = 0 }
                $arg = Invoke-Expression $expr
                $out = & $wrapper send api $arg 6>$null
                [pscustomobject]@{ Code = $LASTEXITCODE; Out = (@($out) -join ',') }
            }
            try {
                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                while (($job.State -in 'NotStarted', 'Running') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
                $job.State | Should -Be 'Completed' -Because 'the wrapper must reject the argument at once instead of recursing'
                $result = Receive-Job -Job $job
                $result.Code | Should -Be 2
                $result.Out | Should -Not -Match 'SSH-CALLED'
            }
            finally {
                Stop-Job -Job $job -ErrorAction SilentlyContinue
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }

            $arg = Invoke-Expression $Expr
            & $Wrapper send api $arg
            $LASTEXITCODE | Should -Be 2
            Should -Invoke ssh -Times 0 -Exactly
        }
    }

    Describe 'exit codes' {
        It 'returns the ssh exit code' {
            Mock ssh { $global:LASTEXITCODE = 3 }
            & $Wrapper rm api
            $LASTEXITCODE | Should -Be 3
        }

        It 'prints the hint exactly once on 255' {
            Mock ssh { $global:LASTEXITCODE = 255 }
            $out = & $Wrapper ls 6>&1 | Out-String
            $LASTEXITCODE | Should -Be 255
            # The same line as the bash wrapper prints, prefix included (README troubleshooting has one form).
            $hint = "tmuxkeep: ssh to host 'tmuxkeep' failed (unreachable, key rejected, or remote killed by signal)"
            ([regex]::Matches($out, [regex]::Escape($hint))).Count | Should -Be 1
            @($out -split "\r?\n" | Where-Object { $_ -ceq $hint }).Count | Should -Be 1
            @($out -split "\r?\n" | Where-Object { $_ -like "*ssh to host 'tmuxkeep' failed*" -and $_ -cne $hint }).Count | Should -Be 0
        }

        It 'prints no hint on other failures' {
            Mock ssh { $global:LASTEXITCODE = 5 }
            $out = & $Wrapper peek nosuch 6>&1 | Out-String
            $out | Should -Not -Match 'failed \(unreachable'
        }
    }

    Describe 'contract with the broker' {
        It '$GatedVerbs equals the GATED_VERBS line in vps/tmuxkeep' {
            . $Wrapper
            $line = Select-String -LiteralPath (Join-Path $Repo 'vps\tmuxkeep') -Pattern '^GATED_VERBS="([^"]*)"$' -CaseSensitive
            $line | Should -Not -BeNullOrEmpty
            $broker = @($line.Matches[0].Groups[1].Value -split ' ' | Sort-Object)
            (@($GatedVerbs | Sort-Object) -join ' ') | Should -BeExactly ($broker -join ' ')
        }

        It 'dot-sourcing defines the helpers and calls nothing' {
            . $Wrapper
            Get-Command ConvertTo-TmuxkeepWords -CommandType Function | Should -Not -BeNullOrEmpty
            Should -Invoke ssh -Times 0 -Exactly
        }
    }
}
