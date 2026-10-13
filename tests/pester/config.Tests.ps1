# Pester tests for the laptop config functions in laptop/deploy.ps1 (spec 4.1, 4.2, 4.3; plan Q5,
# Q14; Review Focus 2). The script is dot-sourced, so only its functions are defined; main never runs.
Describe 'laptop config' {
    BeforeAll {
        $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        # Safety net first: fake external tools on PATH, and throwing mocks, before dot-sourcing.
        $script:FakeBin = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $FakeBin | Out-Null
        foreach ($n in 'ssh', 'scp', 'ssh-keygen') {
            Set-Content -LiteralPath (Join-Path $FakeBin "$n.cmd") -Value '@exit /b 99' -Encoding ascii
        }
        $script:OldPath = $env:PATH
        $env:PATH = "$FakeBin;$env:PATH"
        Mock ssh { throw 'ssh must not be called from tests' }
        Mock scp { throw 'scp must not be called from tests' }
        Mock ssh-keygen { throw 'ssh-keygen must not be called from tests' }
        . (Join-Path $Repo 'laptop\deploy.ps1')
        $script:FixturePath = Join-Path $Repo 'tests\fixtures\laptop-config'
        $script:Fixture = [IO.File]::ReadAllText($FixturePath)
        $script:DeployFixture = [IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\deploy.conf'))
        $script:Utf8 = New-Object System.Text.UTF8Encoding $false
        $script:AppendedLine = ([regex]::Matches($Fixture, "`n")).Count + 1

        function New-Cfg([string]$Text) {
            $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.cfg')
            [IO.File]::WriteAllText($p, $Text, $script:Utf8)
            return $p
        }
        function Set-Line([string]$Text, [string]$Key, [string]$Value) {
            $rx = '(?m)^' + [regex]::Escape($Key) + '=.*$'
            return [regex]::Replace($Text, $rx, ($Key + '=' + $Value).Replace('$', '$$'))
        }
        function Get-Reason([string]$Path) {
            try { Read-TmuxkeepConfig -Path $Path | Out-Null; return 'no error' }
            catch { return $_.Exception.Message }
        }
        function Get-InteractiveReason([string]$Path) {
            try { New-TmuxkeepConfigInteractive -Path $Path | Out-Null; return 'no error' }
            catch { return $_.Exception.Message }
        }
    }

    AfterAll { $env:PATH = $OldPath }

    It 'reads the fixture into the sixteen keys, in file order' {
        $v = Read-TmuxkeepConfig -Path (New-Cfg $Fixture)
        (@($v.Keys) -join ' ') | Should -BeExactly 'HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES'
        $v['HOST'] | Should -BeExactly '203.0.113.10'
        $v['PORT'] | Should -BeExactly '22'
        $v['KEY'] | Should -BeExactly '~/.ssh/id_tmuxkeep_ed25519'
        $v['RESUME_CMD'] | Should -BeExactly 'claude --continue'
    }

    It 'Write-TmuxkeepConfig reproduces the fixture byte for byte, creating the folder' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '203.0.113.10'
        $p = Join-Path $TestDrive 'new dir\.tmuxkeep\config'
        Write-TmuxkeepConfig -Path $p -Values $v
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly ([IO.File]::ReadAllBytes($FixturePath) -join ',')
    }

    It 'a missing key other than HOST takes its default; a missing HOST is required' {
        $v = Read-TmuxkeepConfig -Path (New-Cfg ([regex]::Replace($Fixture, '(?m)^PORT=.*\n', '')))
        $v['PORT'] | Should -BeExactly '22'
        $p = New-Cfg ([regex]::Replace($Fixture, '(?m)^HOST=.*\n', ''))
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': HOST: required')
    }

    It 'skips blank and comment lines, trims padding, and lets the last repeated key win' {
        $padded = [regex]::Replace($Fixture, '(?m)^([A-Z_]+)=(.*)$', ('  $1 =' + "`t" + '$2 ' + "`t"))
        $v = Read-TmuxkeepConfig -Path (New-Cfg ("`n# note`n  `t `n" + $padded + "PORT=2200`nPORT=2222`n"))
        $v['PORT'] | Should -BeExactly '2222'
        $v['HOST'] | Should -BeExactly '203.0.113.10'
        $v['RESUME_CMD'] | Should -BeExactly 'claude --continue'
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'an empty HOST';              Key = 'HOST';                Value = '';                  Reason = 'HOST: required' }
        @{ Name = 'host:port';                  Key = 'HOST';                Value = '203.0.113.10:2222'; Reason = 'HOST: looks like host:port; put the port in PORT' }
        @{ Name = 'a user@host address';        Key = 'HOST';                Value = 'you@203.0.113.10';  Reason = 'HOST: not a hostname, IPv4 or IPv6 address' }
        @{ Name = 'a HOST starting with -';     Key = 'HOST';                Value = '-x.example';        Reason = 'HOST: not a hostname, IPv4 or IPv6 address' }
        @{ Name = 'PORT 0';                     Key = 'PORT';                Value = '0';                 Reason = 'PORT: must be an integer from 1 to 65535' }
        @{ Name = 'PORT 65536';                 Key = 'PORT';                Value = '65536';             Reason = 'PORT: must be an integer from 1 to 65535' }
        @{ Name = 'PORT ssh';                   Key = 'PORT';                Value = 'ssh';               Reason = 'PORT: must be an integer from 1 to 65535' }
        @{ Name = 'USER Bob';                   Key = 'USER';                Value = 'Bob';               Reason = 'USER: must match ^[a-z_][a-z0-9_-]{0,31}$' }
        @{ Name = 'an empty KEY';               Key = 'KEY';                 Value = '';                  Reason = 'KEY: must be a non-empty path without double quotes' }
        @{ Name = 'a KEY with a double quote';  Key = 'KEY';                 Value = 'a"b';               Reason = 'KEY: must be a non-empty path without double quotes' }
        @{ Name = 'an empty ADMIN_KEY';         Key = 'ADMIN_KEY';           Value = '';                  Reason = 'ADMIN_KEY: must be a non-empty path without double quotes' }
        @{ Name = 'a 201-character LAUNCH_CMD'; Key = 'LAUNCH_CMD';          Value = ('x' * 201);         Reason = 'LAUNCH_CMD: at most 200 characters' }
        @{ Name = 'a 201-character RESUME_CMD'; Key = 'RESUME_CMD';          Value = ('x' * 201);         Reason = 'RESUME_CMD: at most 200 characters' }
        @{ Name = 'INSTALL_CLAUDE_CODE Yes';    Key = 'INSTALL_CLAUDE_CODE'; Value = 'Yes';               Reason = 'INSTALL_CLAUDE_CODE: must be yes or no' }
        @{ Name = 'LEASE_SECS 59';              Key = 'LEASE_SECS';          Value = '59';                Reason = 'LEASE_SECS: must be an integer from 60 to 86400' }
        @{ Name = 'LEASE_SECS 86401';           Key = 'LEASE_SECS';          Value = '86401';             Reason = 'LEASE_SECS: must be an integer from 60 to 86400' }
        @{ Name = 'LEASE_SECS -60';             Key = 'LEASE_SECS';          Value = '-60';               Reason = 'LEASE_SECS: must be an integer from 60 to 86400' }
        @{ Name = 'LEASE_SECS of eight digits'; Key = 'LEASE_SECS';          Value = '00001800';          Reason = 'LEASE_SECS: must be an integer from 60 to 86400' }
        @{ Name = 'TOMBSTONE_TTL 3599';         Key = 'TOMBSTONE_TTL';       Value = '3599';              Reason = 'TOMBSTONE_TTL: must be an integer from 3600 to 2592000' }
        @{ Name = 'TOMBSTONE_TTL 2592001';      Key = 'TOMBSTONE_TTL';       Value = '2592001';           Reason = 'TOMBSTONE_TTL: must be an integer from 3600 to 2592000' }
        @{ Name = 'OTP_FAIL_MAX 0';             Key = 'OTP_FAIL_MAX';        Value = '0';                 Reason = 'OTP_FAIL_MAX: must be an integer from 1 to 20' }
        @{ Name = 'OTP_FAIL_MAX 21';            Key = 'OTP_FAIL_MAX';        Value = '21';                Reason = 'OTP_FAIL_MAX: must be an integer from 1 to 20' }
        @{ Name = 'OTP_FAIL_WINDOW 59';         Key = 'OTP_FAIL_WINDOW';     Value = '59';                Reason = 'OTP_FAIL_WINDOW: must be an integer from 60 to 86400' }
        @{ Name = 'OTP_COOLDOWN 9';             Key = 'OTP_COOLDOWN';        Value = '9';                 Reason = 'OTP_COOLDOWN: must be an integer from 10 to 86400' }
        @{ Name = 'OTP_HARD_MAX 2';             Key = 'OTP_HARD_MAX';        Value = '2';                 Reason = 'OTP_HARD_MAX: must be an integer from 3 to 100' }
        @{ Name = 'OTP_HARD_MAX 101';           Key = 'OTP_HARD_MAX';        Value = '101';               Reason = 'OTP_HARD_MAX: must be an integer from 3 to 100' }
        @{ Name = 'OTP_READ_TIMEOUT 601';       Key = 'OTP_READ_TIMEOUT';    Value = '601';               Reason = 'OTP_READ_TIMEOUT: must be an integer from 10 to 600' }
        @{ Name = 'SEND_MAX_BYTES 0';           Key = 'SEND_MAX_BYTES';      Value = '0';                 Reason = 'SEND_MAX_BYTES: must be an integer from 1 to 65536' }
        @{ Name = 'SEND_MAX_BYTES 65537';       Key = 'SEND_MAX_BYTES';      Value = '65537';             Reason = 'SEND_MAX_BYTES: must be an integer from 1 to 65536' }
    ) {
        $p = New-Cfg (Set-Line $Fixture $Key $Value)
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': ' + $Reason)
    }

    It 'accepts <Name>' -ForEach @(
        @{ Name = 'an IPv6 literal';        Key = 'HOST';           Value = '2001:db8::1' }
        @{ Name = 'a hostname';             Key = 'HOST';           Value = 'vps-1.example.org' }
        @{ Name = 'PORT 65535';             Key = 'PORT';           Value = '65535' }
        @{ Name = 'USER _svc';              Key = 'USER';           Value = '_svc' }
        @{ Name = 'a KEY with a space';     Key = 'KEY';            Value = '~/my keys/k' }
        @{ Name = 'an empty LAUNCH_CMD';    Key = 'LAUNCH_CMD';     Value = '' }
        @{ Name = 'LEASE_SECS 0060';        Key = 'LEASE_SECS';     Value = '0060' }
        @{ Name = 'TOMBSTONE_TTL 2592000';  Key = 'TOMBSTONE_TTL';  Value = '2592000' }
        @{ Name = 'OTP_HARD_MAX 3';         Key = 'OTP_HARD_MAX';   Value = '3' }
        @{ Name = 'SEND_MAX_BYTES 65536';   Key = 'SEND_MAX_BYTES'; Value = '65536' }
    ) {
        Get-Reason (New-Cfg (Set-Line $Fixture $Key $Value)) | Should -BeExactly 'no error'
    }

    It 'rejects a BOM, a CR, a line without =, an unknown key and non-printable values, naming the file' {
        $n = $AppendedLine
        $p = Join-Path $TestDrive 'bom.cfg'
        [IO.File]::WriteAllBytes($p, [byte[]](@(0xEF, 0xBB, 0xBF) + @([Text.Encoding]::ASCII.GetBytes($Fixture))))
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': byte order mark found (save without BOM)')
        $p = New-Cfg ($Fixture.Replace("`n", "`r`n"))
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': carriage return found (use LF line endings)')
        $p = New-Cfg ($Fixture + "just words`n")
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': line ' + $n + ': expected KEY=value')
        $p = New-Cfg ($Fixture + "FROB=1`n")
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': line ' + $n + ': unknown key FROB')
        $p = New-Cfg ($Fixture + "host=x`n")
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': line ' + $n + ': unknown key host')
        $p = New-Cfg ($Fixture + "B@D=1`n")
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': line ' + $n + ': unknown key')
        $p = New-Cfg (Set-Line $Fixture 'LAUNCH_CMD' ('caf' + [char]0x00E9))
        Get-Reason $p | Should -Match ([regex]::Escape(': non-printable or non-ASCII character in LAUNCH_CMD') + '$')
        $p = New-Cfg (Set-Line $Fixture 'LAUNCH_CMD' ("a`tb"))
        Get-Reason $p | Should -Match ([regex]::Escape(': non-printable or non-ASCII character in LAUNCH_CMD') + '$')
    }

    It 'rejects a NUL byte at the start, inside a value or at the end, before any line is read' {
        $nul = [string][char]0
        foreach ($text in @(($nul + $Fixture), $Fixture.Replace('LAUNCH_CMD=claude', ('LAUNCH_CMD=cla' + $nul + 'ude')), ($Fixture + $nul))) {
            $p = New-Cfg $text
            ([IO.File]::ReadAllBytes($p) -contains 0) | Should -BeTrue
            Get-Reason $p | Should -BeExactly ('config ' + $p + ': NUL byte found')
        }
    }

    It 'reports the first problem in the documented order, each message exact' {
        $nl = "`n"
        $crlf = "`r`n"
        $nul = [string][char]0
        $bom = [string][char]0xFEFF
        $hostLine = 'HOST=203.0.113.10'
        $cases = @(
            @{ Why = 'BOM plus CR gives the BOM reason';                    Text = ($bom + $hostLine + $crlf);                       Reason = 'byte order mark found (save without BOM)' }
            @{ Why = 'CR plus NUL gives the CR reason';                     Text = ($hostLine + $crlf + $nul);                       Reason = 'carriage return found (use LF line endings)' }
            @{ Why = 'NUL plus a line without = gives the NUL reason';      Text = ($hostLine + $nl + 'just words' + $nl + $nul);    Reason = 'NUL byte found' }
            @{ Why = 'a line error on line 2 beats the missing HOST';       Text = ('PORT=22' + $nl + 'just words' + $nl);           Reason = 'line 2: expected KEY=value' }
            @{ Why = 'PORT=5 and no HOST is HOST: required';                Text = ('PORT=5' + $nl);                                 Reason = 'HOST: required' }
            @{ Why = 'the required check runs before any validation';       Text = ('PORT=0' + $nl);                                 Reason = 'HOST: required' }
            @{ Why = 'key-list order beats line order, empty HOST';         Text = ('PORT=0' + $nl + 'HOST=' + $nl);                 Reason = 'HOST: required' }
            @{ Why = 'key-list order beats line order, user@host HOST';     Text = ('PORT=0' + $nl + 'HOST=you@203.0.113.10' + $nl); Reason = 'HOST: not a hostname, IPv4 or IPv6 address' }
            @{ Why = 'validation looks at the last duplicate, not the first'; Text = ($hostLine + $nl + 'PORT=22' + $nl + 'PORT=0' + $nl); Reason = 'PORT: must be an integer from 1 to 65535' }
        )
        foreach ($c in $cases) {
            $p = New-Cfg $c.Text
            Get-Reason $p | Should -BeExactly ('config ' + $p + ': ' + $c.Reason) -Because $c.Why
        }
        $p = New-Cfg ($hostLine + $nl + 'PORT=0' + $nl + 'PORT=22' + $nl)
        Get-Reason $p | Should -BeExactly 'no error' -Because 'a later duplicate repairs an earlier bad value'
        (Read-TmuxkeepConfig -Path $p)['PORT'] | Should -BeExactly '22'
    }

    It 'New-TmuxkeepConfigInteractive asks once, trims the answer and writes the fixture' {
        Mock Read-Host { ' 203.0.113.10 ' } -ParameterFilter { $Prompt -eq 'VPS address (hostname or IP)' }
        $p = Join-Path $TestDrive 'first run\config'
        $v = New-TmuxkeepConfigInteractive -Path $p
        Should -Invoke Read-Host -Times 1 -Exactly
        $v['HOST'] | Should -BeExactly '203.0.113.10'
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly ([IO.File]::ReadAllBytes($FixturePath) -join ',')
    }

    It 'New-TmuxkeepConfigInteractive rejects <Name> and writes nothing (Review Focus 2)' -ForEach @(
        @{ Name = 'host:port';       Answer = '203.0.113.10:2222'; Reason = 'HOST: looks like host:port; put the port in PORT' }
        @{ Name = 'user@host';       Answer = 'you@203.0.113.10';  Reason = 'HOST: not a hostname, IPv4 or IPv6 address' }
        @{ Name = 'an empty answer'; Answer = '';                  Reason = 'HOST: required' }
        @{ Name = 'only spaces';     Answer = '   ';               Reason = 'HOST: required' }
    ) {
        $script:NextAnswer = $Answer
        Mock Read-Host { $script:NextAnswer }
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '\config')
        Get-InteractiveReason $p | Should -BeExactly ('config ' + $p + ': ' + $Reason)
        Test-Path -LiteralPath $p | Should -BeFalse
    }

    It 'ConvertTo-TmuxkeepDeployConf on the defaults is the deploy.conf fixture' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '203.0.113.10'
        ConvertTo-TmuxkeepDeployConf -Values $v | Should -BeExactly $DeployFixture
    }

    It 'ConvertTo-TmuxkeepDeployConf carries the configured values and nothing laptop-only' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '198.51.100.20'
        $v['USER'] = 'bob'
        $v['LAUNCH_CMD'] = ''
        $v['LEASE_SECS'] = '600'
        $t = ConvertTo-TmuxkeepDeployConf -Values $v
        $t | Should -Match '(?m)^USER=bob$'
        $t | Should -Match '(?m)^LAUNCH_CMD=$'
        $t | Should -Match '(?m)^LEASE_SECS=600$'
        $t | Should -Not -Match 'HOST|PORT|KEY='
    }

    It 'Expand-TmuxkeepPath expands only a leading tilde' {
        Expand-TmuxkeepPath -Path '~/.ssh/k' -HomeDir 'C:\h' | Should -BeExactly 'C:\h\.ssh\k'
        Expand-TmuxkeepPath -Path '~\.ssh\k' -HomeDir 'C:\h' | Should -BeExactly 'C:\h\.ssh\k'
        Expand-TmuxkeepPath -Path '~' -HomeDir 'C:\h' | Should -BeExactly 'C:\h'
        Expand-TmuxkeepPath -Path 'D:\keys\k' -HomeDir 'C:\h' | Should -BeExactly 'D:\keys\k'
        Expand-TmuxkeepPath -Path 'a~/k' -HomeDir 'C:\h' | Should -BeExactly 'a~/k'
    }

    It 'the key list is one line the parity test can read' {
        @([IO.File]::ReadAllLines((Join-Path $Repo 'laptop\deploy.ps1')) | Where-Object { $_ -clike 'function Get-TmuxkeepConfigKeys *' }).Count | Should -Be 1
    }
}
