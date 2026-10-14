# Pester 5 tests for laptop/deploy.ps1. The script is dot-sourced (functions only); main never runs.
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
    $script:Pub = Join-Path $TestDrive 'k.pub'
    [IO.File]::WriteAllText($Pub, "ssh-ed25519 AAAATEST tmuxkeep-laptop`r`n")
}

AfterAll { $env:PATH = $OldPath }

Describe 'dot-sourcing' {
    It 'defines the deploy functions and no longer the v1 append-once ones' {
        foreach ($f in 'Get-TmuxkeepVersion', 'Get-TmuxkeepVpsFiles', 'New-TmuxkeepStaging', 'Set-TmuxkeepMarkedBlock',
                       'Get-TmuxkeepSshBlock', 'Set-TmuxkeepHostBlock', 'Set-TmuxkeepProfileSnippet', 'Get-TmuxkeepSetupCommand',
                       'Get-TmuxkeepAdminHelp', 'Read-TmuxkeepConfig', 'Write-TmuxkeepConfig', 'New-TmuxkeepConfigInteractive',
                       'ConvertTo-TmuxkeepDeployConf', 'Expand-TmuxkeepPath', 'Get-TmuxkeepSshAgentProblems',
                       'Install-TmuxkeepDashboard') {
            Get-Command $f -CommandType Function | Should -Not -BeNullOrEmpty
        }
        foreach ($f in 'Add-TmuxkeepMarkedBlock', 'Add-TmuxkeepHostBlock', 'Add-TmuxkeepProfileSnippet', 'Show-TmuxkeepAdminHelp') {
            Get-Command $f -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-TmuxkeepVersion' {
    It 'returns the short hash, with -dirty when the tree is dirty' {
        $r = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $r | Out-Null
        & git -C $r init -q
        & git -C $r -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
        $hash = (& git -C $r rev-parse --short HEAD).Trim()
        Get-TmuxkeepVersion -RepoRoot $r | Should -BeExactly $hash
        Set-Content -LiteralPath (Join-Path $r 'x.txt') -Value 'x' -Encoding ascii
        Get-TmuxkeepVersion -RepoRoot $r | Should -BeExactly "$hash-dirty"
    }
}

Describe 'New-TmuxkeepStaging' {
    BeforeAll {
        $script:Defaults = Get-TmuxkeepConfigDefaults
        $script:Defaults['HOST'] = '203.0.113.10'
    }

    It 'stages the VPS files, laptop.pub and deploy.conf with LF, no BOM and the version, under a path with spaces' {
        $dest = Join-Path $TestDrive 'stage dir\tmuxkeep-deploy-20261012120000'
        New-TmuxkeepStaging -RepoRoot $Repo -Version 'abc1234' -PubKeyPath $Pub -Config $Defaults -Destination $dest
        $names = [string[]]@(Get-ChildItem -LiteralPath $dest -Recurse -File | ForEach-Object { $_.FullName.Substring($dest.Length + 1).Replace('\', '/') })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        ($names -join ',') | Should -BeExactly 'deploy.conf,laptop.pub,sshd.conf.tmpl,sudoers.tmpl,systemd/tmuxkeep-reaper.service,systemd/tmuxkeep-reaper.timer,tmux.conf,tmuxkeep,tmuxkeep-setup,vps-facts.sh'
        foreach ($f in Get-ChildItem -LiteralPath $dest -Recurse -File) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            ($b -contains 13) | Should -BeFalse -Because "$($f.Name) must have LF endings"
            ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeFalse -Because "$($f.Name) must have no BOM"
        }
        $broker = [IO.File]::ReadAllText((Join-Path $dest 'tmuxkeep'))
        $broker | Should -Match '(?m)^TMUXKEEP_VERSION=abc1234$'
        $broker | Should -Not -Match '(?m)^TMUXKEEP_VERSION=dev$'
        [IO.File]::ReadAllText((Join-Path $dest 'deploy.conf')) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\deploy.conf')))
        [IO.File]::ReadAllText((Join-Path $dest 'laptop.pub')) | Should -BeExactly "ssh-ed25519 AAAATEST tmuxkeep-laptop`n"
    }

    It 'rejects a version string that is not a git hash' {
        { New-TmuxkeepStaging -RepoRoot $Repo -Version 'abc; rm -rf /' -PubKeyPath $Pub -Config $Defaults -Destination (Join-Path $TestDrive 's2') } |
            Should -Throw
    }

    It 'throws when vps/tmuxkeep lacks exactly one TMUXKEEP_VERSION=dev line' {
        $fake = Join-Path $TestDrive 'fakerepo'
        New-Item -ItemType Directory -Path $fake | Out-Null
        Copy-Item -LiteralPath (Join-Path $Repo 'vps') -Destination (Join-Path $fake 'vps') -Recurse
        $p = Join-Path $fake 'vps\tmuxkeep'
        [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) -replace '(?m)^TMUXKEEP_VERSION=dev\r?$', 'TMUXKEEP_VERSION=other'))
        { New-TmuxkeepStaging -RepoRoot $fake -Version 'abc1234' -PubKeyPath $Pub -Config $Defaults -Destination (Join-Path $TestDrive 's3') } |
            Should -Throw
    }

    It 'Get-TmuxkeepVpsFiles is the spec list, in order' {
        (@(Get-TmuxkeepVpsFiles) -join ' ') | Should -BeExactly 'tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer'
    }
}

Describe 'Get-TmuxkeepSetupCommand' {
    It 'builds the spec 6.1 command with --conf, then the cleanup and the exit code (plan Q4)' {
        Get-TmuxkeepSetupCommand -StageName 'tmuxkeep-deploy-20261012120000' |
            Should -BeExactly 'bash /root/tmuxkeep-deploy-20261012120000/tmuxkeep-setup --pubkey-file /root/tmuxkeep-deploy-20261012120000/laptop.pub --key-id laptop --conf /root/tmuxkeep-deploy-20261012120000/deploy.conf; rc=$?; rm -rf /root/tmuxkeep-deploy-20261012120000; exit $rc'
    }

    It 'appends the flags in a fixed order' {
        Get-TmuxkeepSetupCommand -StageName 'tmuxkeep-deploy-20261012120000' -UnlockOtp -HardenRoot -RotateTotp |
            Should -Match '/deploy\.conf --harden-root --rotate-totp --unlock-otp; rc='
    }

    It 'never contains a double quote' {
        Get-TmuxkeepSetupCommand -StageName 'tmuxkeep-deploy-20261012120000' -HardenRoot | Should -Not -Match '"'
    }

    It 'refuses a stage name that is not tmuxkeep-deploy- followed by 14 digits' {
        { Get-TmuxkeepSetupCommand -StageName 'x; rm -rf /' } | Should -Throw
        { Get-TmuxkeepSetupCommand -StageName 'tmuxkeep-deploy-123' } | Should -Throw
    }
}

Describe 'Get-TmuxkeepAdminHelp' {
    BeforeAll {
        $script:HelpHome = Join-Path $TestDrive 'help home'
        New-Item -ItemType Directory -Path (Join-Path $HelpHome '.ssh') -Force | Out-Null
    }

    It 'builds the spec 6.5 steps from the config, with no other address in them' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '198.51.100.20'
        $v['PORT'] = '2222'
        $h = @(Get-TmuxkeepAdminHelp -Config $v -HomeDir $HelpHome)
        $adminPath = Join-Path $HelpHome '.ssh\id_tmuxkeep_admin_ed25519'
        $h.Count | Should -Be 6
        $h[0] | Should -BeExactly ('1. ssh-keygen -t ed25519 -f "' + $adminPath + '" -C tmuxkeep-admin        (set a passphrase)')
        $h[1] | Should -BeExactly '2. Install it on the VPS with one password login:'
        $h[2] | Should -BeExactly '   ssh root@198.51.100.20 -p 2222 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && echo <contents of ~/.ssh/id_tmuxkeep_admin_ed25519.pub> >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"'
        $h[3] | Should -BeExactly '3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true'
        $h[4] | Should -BeExactly ''
        $h[5] | Should -BeExactly 'Never ssh-add the admin key and never set AddKeysToAgent for it.'
        ($h -join "`n") | Should -Not -Match '203\.0\.113\.10'
    }

    It 'puts the public key into step 2 once it exists, and only a plain ssh-ed25519 line' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '198.51.100.20'
        $pubPath = Join-Path $HelpHome '.ssh\id_tmuxkeep_admin_ed25519.pub'
        [IO.File]::WriteAllText($pubPath, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdminAdminAdmin tmuxkeep-admin`r`n")
        $h = @(Get-TmuxkeepAdminHelp -Config $v -HomeDir $HelpHome)
        $h[2] | Should -Match ([regex]::Escape('&& echo ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdminAdminAdmin tmuxkeep-admin >> ~/.ssh/authorized_keys'))
        [IO.File]::WriteAllText($pubPath, "ssh-ed25519 AAAA `$(reboot)`n")
        $h = @(Get-TmuxkeepAdminHelp -Config $v -HomeDir $HelpHome)
        $h[2] | Should -Match ([regex]::Escape('echo <contents of ~/.ssh/id_tmuxkeep_admin_ed25519.pub> >>'))
        Remove-Item -LiteralPath $pubPath
    }
}

Describe 'Install-TmuxkeepDashboard' {
    BeforeAll {
        # A stand-in repository: dashboard\ with a lib file, a page file and a test folder.
        $script:DashRepo = Join-Path $TestDrive 'dash repo'
        foreach ($d in 'dashboard\lib', 'dashboard\public', 'dashboard\test') {
            New-Item -ItemType Directory -Path (Join-Path $DashRepo $d) -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $DashRepo 'dashboard\server.js') -Value '// server' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $DashRepo 'dashboard\lib\a.js') -Value '// a' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $DashRepo 'dashboard\public\app.js') -Value '// app' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $DashRepo 'dashboard\test\a.test.js') -Value '// test' -Encoding ascii
        function Get-Tree([string]$Root) {
            $names = [string[]]@(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { $_.FullName.Substring($Root.Length + 1).Replace('\', '/') })
            [Array]::Sort($names, [StringComparer]::Ordinal)
            return ($names -join ',')
        }
    }

    It 'copies dashboard\ without test\ into a new folder under a path with spaces (Review Focus 2)' {
        $dest = Join-Path $TestDrive 'home dir\scripts\tmuxkeep-dashboard'
        Install-TmuxkeepDashboard -RepoRoot $DashRepo -Destination $dest
        Get-Tree $dest | Should -BeExactly 'lib/a.js,public/app.js,server.js'
    }

    It 'replaces the folder: a file from an older version is gone' {
        $dest = Join-Path $TestDrive 'again\scripts\tmuxkeep-dashboard'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'stale.js') -Value 'old' -Encoding ascii
        Install-TmuxkeepDashboard -RepoRoot $DashRepo -Destination $dest
        Get-Tree $dest | Should -BeExactly 'lib/a.js,public/app.js,server.js'
    }

    It 'refuses a destination that is not a tmuxkeep-dashboard folder, and a repository without the dashboard' {
        $other = Join-Path $TestDrive 'precious'
        New-Item -ItemType Directory -Path $other | Out-Null
        Set-Content -LiteralPath (Join-Path $other 'keep.txt') -Value 'keep' -Encoding ascii
        { Install-TmuxkeepDashboard -RepoRoot $DashRepo -Destination $other } | Should -Throw -ExpectedMessage "refusing to replace ${other}: the folder must be named tmuxkeep-dashboard"
        Test-Path -LiteralPath (Join-Path $other 'keep.txt') | Should -BeTrue
        { Install-TmuxkeepDashboard -RepoRoot (Join-Path $TestDrive 'empty') -Destination (Join-Path $TestDrive 'x\tmuxkeep-dashboard') } | Should -Throw -ExpectedMessage '*dashboard\server.js'
    }
}

Describe 'deploy.ps1 main sequence' {
    BeforeAll {
        $script:DeployText = [IO.File]::ReadAllText((Join-Path $Repo 'laptop\deploy.ps1'))
        $script:DeployLines = @($DeployText -split "\r?\n")
    }

    It 'refuses to run outside Windows PowerShell before the first ssh-keygen call' {
        # Under pwsh 7.3+ the '""' passphrase would reach ssh-keygen as two literal characters.
        $edition = $DeployText.IndexOf('$PSVersionTable.PSEdition')
        $keygen = $DeployText.IndexOf('& ssh-keygen')
        ($edition -ge 0) | Should -BeTrue -Because 'the PSEdition check must exist'
        ($keygen -gt $edition) | Should -BeTrue -Because 'the check must come before the ssh-keygen call'
        ($DeployText -match "(?s)PSEdition -ne 'Desktop'\)\s*\{[^}]*not pwsh[^}]*exit 2") | Should -BeTrue -Because 'the check must say why and exit 2'
    }

    It 'explains an ssh exit of 255 from the setup step, and the README documents the same message' {
        $msg = 'ssh to tmuxkeep-admin failed (exit 255)'
        $DeployText.Contains($msg) | Should -BeTrue -Because 'deploy.ps1 must print the 255 message'
        ($DeployText -match '(?s)\$setupExit -eq 255.*?exit 255') | Should -BeTrue -Because 'step 6 must exit 255 on it'
        [IO.File]::ReadAllText((Join-Path $Repo 'README.md')).Contains($msg) | Should -BeTrue -Because 'the README must document the message'
    }

    It 'keeps the generic message for any other setup failure' {
        $DeployText.Contains('deploy: tmuxkeep-setup failed with exit $setupExit') | Should -BeTrue
    }

    It 'runs the installer ssh as a plain statement, never captured (G3)' {
        $l = @($DeployLines | Where-Object { $_ -match 'tmuxkeep-admin \(Get-TmuxkeepSetupCommand' })
        $l.Count | Should -Be 1
        $l[0].Trim() | Should -BeExactly '& ssh -o PreferredAuthentications=publickey tmuxkeep-admin (Get-TmuxkeepSetupCommand -StageName $stage -HardenRoot:$HardenRoot -RotateTotp:$RotateTotp -UnlockOtp:$UnlockOtp)'
    }

    It 'never calls ssh-add and spells AddKeysToAgent in three lines only: the help sentence, the block line and the refusal (G3 as amended)' {
        @($DeployLines | Where-Object { $_ -match '^\s*(&\s*)?ssh-add\b' }).Count | Should -Be 0
        # -cmatch: the parser reads ssh -G's lower-case addkeystoagent line, which is not a mention.
        $a = @($DeployLines | Where-Object { $_ -cmatch 'AddKeysToAgent' })
        $a.Count | Should -Be 3
        @($a | Where-Object { $_.Contains('Never ssh-add the admin key and never set AddKeysToAgent for it.') }).Count | Should -Be 1
        @($a | Where-Object { $_.Trim() -ceq "'    AddKeysToAgent no'" }).Count | Should -Be 1
        @($a | Where-Object { $_.Contains("put 'AddKeysToAgent no' under 'Host tmuxkeep-admin' before any 'Host *' block") }).Count | Should -Be 1
    }

    It 'asks ssh -G for the admin alias as a captured statement, and keeps the setup and proof-of-life ssh plain' {
        @($DeployLines | Where-Object { $_ -match '^\s*\$g = @\(& ssh -G tmuxkeep-admin\)\s*$' }).Count | Should -Be 1
        @($DeployLines | Where-Object { $_ -match '^\s*& ssh -o BatchMode=yes tmuxkeep ls\s*$' }).Count | Should -Be 1
    }

    It 'holds no IPv4 address' {
        $DeployText | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
    }
}

Describe 'deploy.ps1 run in a child powershell.exe with stub ssh, scp and ssh-keygen' {
    BeforeAll {
        $script:Deploy = Join-Path $Repo 'laptop\deploy.ps1'
        $script:Stubs = Join-Path $TestDrive 'stubs'
        New-Item -ItemType Directory -Path $Stubs | Out-Null
        # PowerShell finds a .ps1 on PATH before ssh.exe further down PATH, and passes -o, -t and
        # -N to a script without a param block in $args. Each stub logs name|arg|arg... per call.
        Set-Content -LiteralPath (Join-Path $Stubs 'ssh.ps1') -Encoding ascii -Value @'
Add-Content -LiteralPath $env:TK_STUB_LOG -Value ('ssh|' + ($args -join '|')) -Encoding ascii
# ssh -G (deploy asks what the ssh config says for tmuxkeep-admin): the file TK_STUB_SSH_G, or the
# default answer, and exit TK_STUB_SSH_G_RC (default 0). Every other call exits with TK_STUB_SSH_RC.
if ($args.Count -ge 1 -and [string]$args[0] -ceq '-G') {
    if ($env:TK_STUB_SSH_G) { Get-Content -LiteralPath $env:TK_STUB_SSH_G } else { 'addkeystoagent false' }
    $grc = 0
    if ($env:TK_STUB_SSH_G_RC) { $grc = [int]$env:TK_STUB_SSH_G_RC }
    exit $grc
}
$rc = 0
if ($env:TK_STUB_SSH_RC) { $rc = [int]$env:TK_STUB_SSH_RC }
exit $rc
'@
        Set-Content -LiteralPath (Join-Path $Stubs 'scp.ps1') -Encoding ascii -Value @'
Add-Content -LiteralPath $env:TK_STUB_LOG -Value ('scp|' + ($args -join '|')) -Encoding ascii
if ($env:TK_STUB_SCP_DEST -and $args.Count -ge 2) {
    Copy-Item -LiteralPath ([string]$args[$args.Count - 2]) -Destination $env:TK_STUB_SCP_DEST -Recurse
}
$rc = 0
if ($env:TK_STUB_SCP_RC) { $rc = [int]$env:TK_STUB_SCP_RC }
exit $rc
'@
        Set-Content -LiteralPath (Join-Path $Stubs 'ssh-keygen.ps1') -Encoding ascii -Value @'
Add-Content -LiteralPath $env:TK_STUB_LOG -Value ('ssh-keygen|' + ($args -join '|')) -Encoding ascii
$f = $null
for ($i = 0; $i -lt $args.Count - 1; $i++) { if ([string]$args[$i] -ceq '-f') { $f = [string]$args[$i + 1] } }
if ($f) {
    [IO.File]::WriteAllText($f, "FAKE PRIVATE KEY`n")
    [IO.File]::WriteAllText("$f.pub", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubStubStubStubStubStubStub tmuxkeep-laptop`n")
}
exit 0
'@

        # Runs the script at $Script in a child powershell.exe with exactly the arguments in $All. The
        # stubs come first on PATH and TEMP is inside the test drive, so nothing touches the real home.
        function Invoke-DeployScript([string]$Script, [string[]]$All) {
            $savedPath = $env:PATH
            $savedTemp = $env:TEMP
            try {
                $env:PATH = "$script:Stubs;$savedPath"
                $env:TEMP = $script:TempRoot
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @All | Out-String -Width 4096
                return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
            }
            finally {
                $env:PATH = $savedPath
                $env:TEMP = $savedTemp
            }
        }
        function Invoke-Deploy([string[]]$Extra) {
            Invoke-DeployScript $script:Deploy (@('-Config', $script:Cfg, '-HomeDir', $script:HomeRoot, '-ProfilePath', $script:Prof) + $Extra)
        }
        function Get-StubLog { @(Get-Content -LiteralPath $env:TK_STUB_LOG -ErrorAction SilentlyContinue) }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:HomeRoot = Join-Path $root 'home dir'
        $script:TempRoot = Join-Path $root 'temp'
        $script:Prof = Join-Path $script:HomeRoot 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
        $script:Cfg = Join-Path $script:HomeRoot '.tmuxkeep\config'
        foreach ($d in $script:HomeRoot, $script:TempRoot, (Split-Path $script:Cfg), (Join-Path $root 'scp')) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $Repo 'tests\fixtures\laptop-config') -Destination $script:Cfg
        $env:TK_STUB_LOG = Join-Path $root 'stub.log'
        $env:TK_STUB_SCP_DEST = Join-Path $root 'scp'
        Remove-Item Env:\TK_STUB_SSH_RC, Env:\TK_STUB_SCP_RC, Env:\TK_STUB_SSH_G, Env:\TK_STUB_SSH_G_RC -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item Env:\TK_STUB_LOG, Env:\TK_STUB_SCP_DEST, Env:\TK_STUB_SSH_RC, Env:\TK_STUB_SCP_RC, Env:\TK_STUB_SSH_G, Env:\TK_STUB_SSH_G_RC -ErrorAction SilentlyContinue
    }

    It 'runs keygen, ssh -G, scp, the setup ssh and the proof of life in that order, with the exact arguments' {
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
        $log = Get-StubLog
        $log.Count | Should -Be 5
        $log[0] | Should -BeExactly ('ssh-keygen|-t|ed25519|-f|' + (Join-Path $HomeRoot '.ssh\id_tmuxkeep_ed25519') + '|-C|tmuxkeep-laptop|-N|""')
        $log[1] | Should -BeExactly 'ssh|-G|tmuxkeep-admin'
        $log[2] | Should -Match '^scp\|-o\|PreferredAuthentications=publickey\|-r\|tmuxkeep-deploy-\d{14}\|tmuxkeep-admin:/root/tmuxkeep-deploy-\d{14}$'
        $stage = ($log[2] -split '\|')[4]
        $log[3] | Should -BeExactly ('ssh|-o|PreferredAuthentications=publickey|tmuxkeep-admin|' + (Get-TmuxkeepSetupCommand -StageName $stage))
        $log[4] | Should -BeExactly 'ssh|-o|BatchMode=yes|tmuxkeep|ls'
        $r.Out | Should -Match 'deploy: proof of life exit 0'
        $r.Out | Should -Match 'deploy: done\.'
    }

    It 'stages the eight VPS files, laptop.pub and deploy.conf, then removes the local staging folder' {
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
        $copied = @(Get-ChildItem -LiteralPath $env:TK_STUB_SCP_DEST -Directory)
        $copied.Count | Should -Be 1
        $dest = $copied[0].FullName
        $names = [string[]]@(Get-ChildItem -LiteralPath $dest -Recurse -File | ForEach-Object { $_.FullName.Substring($dest.Length + 1).Replace('\', '/') })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        ($names -join ',') | Should -BeExactly 'deploy.conf,laptop.pub,sshd.conf.tmpl,sudoers.tmpl,systemd/tmuxkeep-reaper.service,systemd/tmuxkeep-reaper.timer,tmux.conf,tmuxkeep,tmuxkeep-setup,vps-facts.sh'
        [IO.File]::ReadAllText((Join-Path $dest 'deploy.conf')) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\deploy.conf')))
        [IO.File]::ReadAllText((Join-Path $dest 'laptop.pub')) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $HomeRoot '.ssh\id_tmuxkeep_ed25519.pub')))
        [IO.File]::ReadAllText((Join-Path $dest 'tmuxkeep')) | Should -Match '(?m)^TMUXKEEP_VERSION=[0-9a-f]{4,40}(-dirty)?$'
        @(Get-ChildItem -LiteralPath $TempRoot -Filter 'tmuxkeep-stage-*').Count | Should -Be 0
    }

    It 'installs the wrapper, the profile block and the ssh config block' {
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
        ([IO.File]::ReadAllBytes((Join-Path $HomeRoot 'scripts\tmuxkeep.ps1')) -join ',') | Should -BeExactly ([IO.File]::ReadAllBytes((Join-Path $Repo 'laptop\tmuxkeep.ps1')) -join ',')
        [IO.File]::ReadAllText($Prof) | Should -Match ([regex]::Escape('Register-ArgumentCompleter -Native -CommandName tmuxkeep'))
        [IO.File]::ReadAllText((Join-Path $HomeRoot '.ssh\config')) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\ssh-block')).Replace("`n", "`r`n"))
        $dash = Join-Path $HomeRoot 'scripts\tmuxkeep-dashboard'
        ([IO.File]::ReadAllBytes((Join-Path $dash 'server.js')) -join ',') | Should -BeExactly ([IO.File]::ReadAllBytes((Join-Path $Repo 'dashboard\server.js')) -join ',')
        Test-Path -LiteralPath (Join-Path $dash 'public\app.js') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dash 'test') | Should -BeFalse
        $r.Out | Should -Match ([regex]::Escape("dashboard: installed at $dash (run: tmuxkeep ui)"))
    }

    It 'replaces the dashboard folder on every deploy, and a failing installer leaves it alone' {
        $dash = Join-Path $HomeRoot 'scripts\tmuxkeep-dashboard'
        New-Item -ItemType Directory -Path $dash -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dash 'stale.js') -Value 'old' -Encoding ascii
        $env:TK_STUB_SSH_RC = '3'
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 3 -Because $r.Out
        Test-Path -LiteralPath (Join-Path $dash 'stale.js') | Should -BeTrue
        $r.Out | Should -Not -Match 'dashboard: installed'
        Remove-Item Env:\TK_STUB_SSH_RC
        # The staging folder is named by the second; the stub scp keeps the first run's copy, so a
        # second run in the same second would collide with it.
        Start-Sleep -Seconds 1
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
        Test-Path -LiteralPath (Join-Path $dash 'stale.js') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dash 'server.js') | Should -BeTrue
    }

    It 'puts the ssh block at the top of an existing ssh config and appends the snippet to an existing profile' {
        $sshCfg = Join-Path $HomeRoot '.ssh\config'
        New-Item -ItemType Directory -Path (Split-Path $sshCfg) -Force | Out-Null
        [IO.File]::WriteAllText($sshCfg, "Host old`r`n    User me`r`n")
        New-Item -ItemType Directory -Path (Split-Path $Prof) -Force | Out-Null
        [IO.File]::WriteAllText($Prof, "using namespace System`r`nSet-Alias ll Get-ChildItem`r`n")
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
        $fixture = [IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\ssh-block')).Replace("`n", "`r`n")
        [IO.File]::ReadAllText($sshCfg) | Should -BeExactly ($fixture + "`r`nHost old`r`n    User me`r`n")
        $profText = [IO.File]::ReadAllText($Prof)
        $profText | Should -Match '^using namespace System\r\nSet-Alias ll Get-ChildItem\r\n\r\n# >>> tmuxkeep\r\n'
        $profText | Should -Match '# <<< tmuxkeep\r\n$'
        # A second deploy replaces both blocks where they are.
        Start-Sleep -Seconds 1
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
        [IO.File]::ReadAllText($sshCfg) | Should -BeExactly ($fixture + "`r`nHost old`r`n    User me`r`n")
        ([regex]::Matches([IO.File]::ReadAllText($Prof), '(?m)^# >>> tmuxkeep\r?$')).Count | Should -Be 1
    }

    It '-Init stops after step 3 and prints the admin-key steps; no scp and no ssh except the ssh -G check' {
        $r = Invoke-Deploy @('-Init')
        $r.Code | Should -Be 0 -Because $r.Out
        $log = @(Get-StubLog)
        $log.Count | Should -Be 2
        $log[0] | Should -Match '^ssh-keygen\|'
        $log[1] | Should -BeExactly 'ssh|-G|tmuxkeep-admin'
        Test-Path -LiteralPath (Join-Path $HomeRoot '.ssh\config') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $HomeRoot 'scripts\tmuxkeep.ps1') | Should -BeFalse
        $r.Out | Should -Match 'deploy: init done'
        $r.Out | Should -Match ([regex]::Escape('3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true'))
    }

    It 'passes -HardenRoot, -RotateTotp and -UnlockOtp to the installer in a fixed order' {
        $r = Invoke-Deploy @('-UnlockOtp', '-HardenRoot', '-RotateTotp')
        $r.Code | Should -Be 0 -Because $r.Out
        (Get-StubLog)[3] | Should -Match '/deploy\.conf --harden-root --rotate-totp --unlock-otp; rc='
    }

    It 'scp exit 255 prints the admin-key help built from the config and stops with exit 1' {
        $env:TK_STUB_SCP_RC = '255'
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'the admin key was not accepted'
        $r.Out | Should -Match ([regex]::Escape('ssh root@203.0.113.10 -p 22 "mkdir -p ~/.ssh'))
        $sshCalls = @(Get-StubLog | Where-Object { $_ -like 'ssh|*' })
        $sshCalls.Count | Should -Be 1
        $sshCalls[0] | Should -BeExactly 'ssh|-G|tmuxkeep-admin'
        @(Get-ChildItem -LiteralPath $TempRoot -Filter 'tmuxkeep-stage-*').Count | Should -Be 0
    }

    It 'a failing installer stops before the wrapper is installed' {
        $env:TK_STUB_SSH_RC = '3'
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 3
        $r.Out | Should -Match 'deploy: tmuxkeep-setup failed with exit 3'
        Test-Path -LiteralPath (Join-Path $HomeRoot 'scripts\tmuxkeep.ps1') | Should -BeFalse
    }

    It 'an ssh exit 255 from the setup step explains itself and exits 255' {
        $env:TK_STUB_SSH_RC = '255'
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 255
        $r.Out | Should -Match ([regex]::Escape('deploy: ssh to tmuxkeep-admin failed (exit 255)'))
    }

    It 'an invalid config stops with exit 2, naming the key, before any tool runs' {
        [IO.File]::WriteAllText($Cfg, ([IO.File]::ReadAllText($Cfg) -replace '(?m)^PORT=22$', 'PORT=0'))
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 2
        $r.Out | Should -Match ([regex]::Escape('deploy: config ' + $Cfg + ': PORT: must be an integer from 1 to 65535'))
        @(Get-StubLog).Count | Should -Be 0
    }

    # I1: the admin key must not reach an agent whatever the user's ssh config says. Deploy asks
    # ssh -G tmuxkeep-admin (it connects to nothing; the stub answers it) after step 3, before any connection.
    It 'ssh -G answering addkeystoagent false and usekeychain no passes' {
        $g = Join-Path $TestDrive 'g-ok.txt'
        Set-Content -LiteralPath $g -Encoding ascii -Value @('host tmuxkeep-admin', 'hostname 203.0.113.10', 'addkeystoagent false', 'usekeychain no', 'identitiesonly true')
        $env:TK_STUB_SSH_G = $g
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
        @(Get-StubLog | Where-Object { $_ -like 'scp|*' }).Count | Should -Be 1
    }

    It 'ssh -G answering addkeystoagent no passes too' {
        $g = Join-Path $TestDrive 'g-no.txt'
        Set-Content -LiteralPath $g -Encoding ascii -Value @('addkeystoagent no')
        $env:TK_STUB_SSH_G = $g
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
    }

    It 'ssh -G answering addkeystoagent <Value> is refused with exit 1 before any connection' -ForEach @(
        @{ Value = 'yes' }, @{ Value = 'true' }, @{ Value = 'ask' }, @{ Value = 'confirm' }
    ) {
        $g = Join-Path $TestDrive "g-$Value.txt"
        Set-Content -LiteralPath $g -Encoding ascii -Value @('host tmuxkeep-admin', "addkeystoagent $Value", 'usekeychain no')
        $env:TK_STUB_SSH_G = $g
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 1 -Because $r.Out
        $r.Out | Should -Match ([regex]::Escape("deploy: your ssh config loads keys into an agent for tmuxkeep-admin; put 'AddKeysToAgent no' under 'Host tmuxkeep-admin' before any 'Host *' block"))
        $r.Out | Should -Not -Match 'usekeychain|UseKeychain'
        @(Get-StubLog | Where-Object { $_ -like 'scp|*' }).Count | Should -Be 0
        @(Get-StubLog | Where-Object { $_ -like 'ssh|*' }).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $HomeRoot 'scripts\tmuxkeep.ps1') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TempRoot -Filter 'tmuxkeep-stage-*').Count | Should -Be 0
    }

    It 'ssh -G answering usekeychain yes is refused with exit 1 before any connection' {
        $g = Join-Path $TestDrive 'g-keychain.txt'
        Set-Content -LiteralPath $g -Encoding ascii -Value @('host tmuxkeep-admin', 'addkeystoagent false', 'usekeychain yes')
        $env:TK_STUB_SSH_G = $g
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 1 -Because $r.Out
        $r.Out | Should -Match ([regex]::Escape("deploy: your ssh config stores passphrases in the keychain for tmuxkeep-admin; put 'UseKeychain no' under 'Host tmuxkeep-admin' before any 'Host *' block"))
        $r.Out | Should -Not -Match 'loads keys into an agent'
        @(Get-StubLog | Where-Object { $_ -like 'scp|*' }).Count | Should -Be 0
        @(Get-StubLog | Where-Object { $_ -like 'ssh|*' }).Count | Should -Be 1
    }

    It '-Init is refused too, because the check comes before -Init returns' {
        $g = Join-Path $TestDrive 'g-init.txt'
        Set-Content -LiteralPath $g -Encoding ascii -Value @('addkeystoagent yes', 'usekeychain yes')
        $env:TK_STUB_SSH_G = $g
        $r = Invoke-Deploy @('-Init')
        $r.Code | Should -Be 1 -Because $r.Out
        $r.Out | Should -Match 'loads keys into an agent'
        $r.Out | Should -Match 'stores passphrases in the keychain'
        $r.Out | Should -Not -Match 'init done'
    }

    It 'an ssh -G that fails stops the deploy and names its exit code' {
        $env:TK_STUB_SSH_G_RC = '255'
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 1 -Because $r.Out
        $r.Out | Should -Match ([regex]::Escape('deploy: ssh -G tmuxkeep-admin failed with exit 255'))
        @(Get-StubLog | Where-Object { $_ -like 'scp|*' }).Count | Should -Be 0
    }

    # -Config '' (task 14 ruling): an explicit empty value is an error, not "use the default". The empty
    # argument is written '""' because 5.1 drops a real empty argument when it calls powershell.exe.
    It 'an explicitly empty -Config stops with exit 2 and runs no tool' {
        $r = Invoke-DeployScript $Deploy @('-Config', '""', '-HomeDir', $HomeRoot, '-ProfilePath', $Prof)
        $r.Code | Should -Be 2 -Because $r.Out
        $r.Out | Should -Match ([regex]::Escape('deploy: -Config needs a path'))
        @(Get-StubLog).Count | Should -Be 0
    }

    It 'leaving -Config out still reads ~\.tmuxkeep\config under -HomeDir' {
        $r = Invoke-DeployScript $Deploy @('-HomeDir', $HomeRoot, '-ProfilePath', $Prof, '-Init')
        $r.Code | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match 'deploy: init done'
    }

    It 'a staging failure prints deploy: and the reason, exits 1, runs no scp and leaves no staging folder' {
        # A private copy of the repository whose broker has no TMUXKEEP_VERSION=dev line.
        $copy = Join-Path $TestDrive ('repo-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $copy | Out-Null
        Copy-Item -LiteralPath (Join-Path $Repo 'laptop') -Destination (Join-Path $copy 'laptop') -Recurse
        Copy-Item -LiteralPath (Join-Path $Repo 'vps') -Destination (Join-Path $copy 'vps') -Recurse
        & git -C $copy init -q | Out-Null
        & git -C $copy -c core.autocrlf=false add -A | Out-Null
        & git -C $copy -c core.autocrlf=false -c user.email=t@example.com -c user.name=t commit -q -m init | Out-Null
        $b = Join-Path $copy 'vps\tmuxkeep'
        [IO.File]::WriteAllText($b, ([IO.File]::ReadAllText($b) -replace '(?m)^TMUXKEEP_VERSION=dev\r?$', 'TMUXKEEP_VERSION=other'))
        $r = Invoke-DeployScript (Join-Path $copy 'laptop\deploy.ps1') @('-Config', $Cfg, '-HomeDir', $HomeRoot, '-ProfilePath', $Prof)
        $r.Code | Should -Be 1 -Because $r.Out
        $r.Out | Should -Match ('deploy: .*' + [regex]::Escape('must contain exactly one TMUXKEEP_VERSION=dev line'))
        $r.Out | Should -Not -Match 'At line:|CategoryInfo|FullyQualifiedErrorId'
        @(Get-StubLog | Where-Object { $_ -like 'scp|*' }).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $TempRoot -Filter 'tmuxkeep-stage-*').Count | Should -Be 0
    }

    It 'a failure to install the wrapper prints deploy: and the reason, exits 1 and skips the proof of life' {
        # ~\scripts is a file, so the folder for the wrapper cannot be created.
        Set-Content -LiteralPath (Join-Path $HomeRoot 'scripts') -Value 'in the way' -Encoding ascii
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 1 -Because $r.Out
        $r.Out | Should -Match 'deploy: \S'
        $r.Out | Should -Not -Match 'At line:|CategoryInfo|FullyQualifiedErrorId'
        $r.Out | Should -Not -Match 'proof of life'
        $r.Out | Should -Not -Match 'deploy: done'
        @(Get-StubLog | Where-Object { $_ -eq 'ssh|-o|BatchMode=yes|tmuxkeep|ls' }).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $TempRoot -Filter 'tmuxkeep-stage-*').Count | Should -Be 0
    }

    It 'a profile that cannot be written prints deploy: and the reason, exits 1 and skips the proof of life' {
        # The profile path is a folder, so the snippet cannot be written to it.
        New-Item -ItemType Directory -Path $Prof -Force | Out-Null
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 1 -Because $r.Out
        $r.Out | Should -Match 'deploy: \S'
        $r.Out | Should -Not -Match 'At line:|CategoryInfo|FullyQualifiedErrorId'
        $r.Out | Should -Not -Match 'proof of life'
        @(Get-StubLog | Where-Object { $_ -eq 'ssh|-o|BatchMode=yes|tmuxkeep|ls' }).Count | Should -Be 0
    }
}

Describe 'Get-TmuxkeepSshAgentProblems' {
    It 'finds nothing when ssh -G says addkeystoagent false or no and usekeychain no or false, or says nothing' {
        @(Get-TmuxkeepSshAgentProblems -GOutput @('addkeystoagent false', 'usekeychain no')).Count | Should -Be 0
        @(Get-TmuxkeepSshAgentProblems -GOutput @('addkeystoagent no', 'usekeychain false')).Count | Should -Be 0
        @(Get-TmuxkeepSshAgentProblems -GOutput @('hostname 203.0.113.10')).Count | Should -Be 0
        @(Get-TmuxkeepSshAgentProblems -GOutput @()).Count | Should -Be 0
    }

    It 'names the agent problem and the keychain problem, each once, agent first' {
        $p = @(Get-TmuxkeepSshAgentProblems -GOutput @('usekeychain yes', 'addkeystoagent yes'))
        $p.Count | Should -Be 2
        $p[0] | Should -BeExactly "your ssh config loads keys into an agent for tmuxkeep-admin; put 'AddKeysToAgent no' under 'Host tmuxkeep-admin' before any 'Host *' block"
        $p[1] | Should -BeExactly "your ssh config stores passphrases in the keychain for tmuxkeep-admin; put 'UseKeychain no' under 'Host tmuxkeep-admin' before any 'Host *' block"
    }

    It 'reads only lines that start with the option name and a space, and ignores a trailing CR' {
        @(Get-TmuxkeepSshAgentProblems -GOutput @('identityfile ~/.ssh/addkeystoagent yes', 'xaddkeystoagent yes', 'hostname usekeychain yes')).Count | Should -Be 0
        @(Get-TmuxkeepSshAgentProblems -GOutput @("addkeystoagent false`r", "usekeychain no`r")).Count | Should -Be 0
        @(Get-TmuxkeepSshAgentProblems -GOutput @("addkeystoagent true`r")).Count | Should -Be 1
    }
}

Describe '.gitignore' {
    It 'ignores agent worktrees, superpowers scratch files and the VPS facts output' {
        foreach ($p in '.claude/worktrees/x', '.superpowers/x', 'docs/vps-facts.md') {
            & git -C $Repo check-ignore -q $p
            $LASTEXITCODE | Should -Be 0 -Because "$p must be ignored"
        }
    }
}

Describe 'Set-TmuxkeepMarkedBlock' {
    BeforeAll {
        $script:Block = @('# >>> tmuxkeep', 'line one', '# <<< tmuxkeep')
        $script:BlockText = "# >>> tmuxkeep`r`nline one`r`n# <<< tmuxkeep`r`n"
    }

    It 'creates a missing file and its folder, with CRLF lines' {
        $p = Join-Path $TestDrive 'mb new dir\f'
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        [IO.File]::ReadAllText($p) | Should -BeExactly $BlockText
    }

    It 'appends after a blank line, adding a missing final newline first (the default: the profile)' {
        $p = Join-Path $TestDrive 'mb-append'
        [IO.File]::WriteAllText($p, "Host x`n    HostName 198.51.100.20")
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        [IO.File]::ReadAllText($p) | Should -BeExactly ("Host x`n    HostName 198.51.100.20`r`n`r`n" + $BlockText)
        $q = Join-Path $TestDrive 'mb-append-nl'
        [IO.File]::WriteAllText($q, "using namespace System`r`nSet-Alias ll Get-ChildItem`r`n")
        Set-TmuxkeepMarkedBlock -Path $q -Lines $Block
        [IO.File]::ReadAllText($q) | Should -BeExactly ("using namespace System`r`nSet-Alias ll Get-ChildItem`r`n`r`n" + $BlockText)
    }

    It 'keeps a leading UTF-8 BOM at byte 0 when a block is appended' {
        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        $p = Join-Path $TestDrive 'mb-bom-append'
        [IO.File]::WriteAllBytes($p, [byte[]]($bom + [Text.Encoding]::ASCII.GetBytes("Host x`r`n")))
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        $want = [byte[]]($bom + [Text.Encoding]::ASCII.GetBytes("Host x`r`n`r`n" + $BlockText))
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly ($want -join ',')
        # The block is at the end, so a second call replaces it there and changes nothing.
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly ($want -join ',')
    }

    It '-AtTop puts a new block at the top: the block, one empty line, then the previous content byte for byte (I1)' {
        $p = Join-Path $TestDrive 'mb-top'
        [IO.File]::WriteAllText($p, "Host x`n    HostName 198.51.100.20")
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block -AtTop
        [IO.File]::ReadAllText($p) | Should -BeExactly ($BlockText + "`r`n" + "Host x`n    HostName 198.51.100.20")
        # CRLF content, blank lines and a final newline survive unchanged below the block.
        $q = Join-Path $TestDrive 'mb-top-crlf'
        [IO.File]::WriteAllText($q, "Host y`r`n`r`n    User z`r`n")
        Set-TmuxkeepMarkedBlock -Path $q -Lines $Block -AtTop
        [IO.File]::ReadAllText($q) | Should -BeExactly ($BlockText + "`r`n" + "Host y`r`n`r`n    User z`r`n")
    }

    It 'turns an empty existing file into the block alone, at the top or appended' {
        $p = Join-Path $TestDrive 'mb-empty'
        [IO.File]::WriteAllText($p, '')
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block -AtTop
        [IO.File]::ReadAllText($p) | Should -BeExactly $BlockText
        $q = Join-Path $TestDrive 'mb-empty2'
        [IO.File]::WriteAllText($q, '')
        Set-TmuxkeepMarkedBlock -Path $q -Lines $Block
        [IO.File]::ReadAllText($q) | Should -BeExactly $BlockText
    }

    It '-AtTop puts a new block right after a leading UTF-8 BOM, never above it: BOM, block, one empty line, then the former first line' {
        # A BOM in the middle of the file would make the user's first line an unknown keyword to OpenSSH.
        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        $p = Join-Path $TestDrive 'mb-bom-top'
        [IO.File]::WriteAllBytes($p, [byte[]]($bom + [Text.Encoding]::ASCII.GetBytes('Host x')))
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block -AtTop
        $want = [byte[]]($bom + [Text.Encoding]::ASCII.GetBytes($BlockText + "`r`n" + 'Host x'))
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly ($want -join ',')
        # The marker after the BOM is recognised on the next run: nothing changes, and a changed block
        # is replaced in place with the BOM kept at byte 0.
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block -AtTop
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly ($want -join ',')
        Set-TmuxkeepMarkedBlock -Path $p -Lines @('# >>> tmuxkeep', 'line two', '# <<< tmuxkeep') -AtTop
        $want2 = [byte[]]($bom + [Text.Encoding]::ASCII.GetBytes("# >>> tmuxkeep`r`nline two`r`n# <<< tmuxkeep`r`n" + "`r`n" + 'Host x'))
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly ($want2 -join ',')
        # A file that is only the BOM becomes BOM + block, with no empty line after it.
        $q = Join-Path $TestDrive 'mb-bom-only'
        [IO.File]::WriteAllBytes($q, $bom)
        Set-TmuxkeepMarkedBlock -Path $q -Lines $Block -AtTop
        ([IO.File]::ReadAllBytes($q) -join ',') | Should -BeExactly (([byte[]]($bom + [Text.Encoding]::ASCII.GetBytes($BlockText))) -join ',')
    }

    It '-AtTop keeps non-ASCII bytes of the previous content below the block' {
        $p = Join-Path $TestDrive 'mb-top-utf8'
        $e = [string][char]0x00E9
        [IO.File]::WriteAllBytes($p, [Text.Encoding]::UTF8.GetBytes("# caf$e`n"))
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block -AtTop
        [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($p)) | Should -BeExactly ($BlockText + "`r`n" + "# caf$e`n")
    }

    It 'replaces a block that is already there where it is, with or without -AtTop' {
        $p = Join-Path $TestDrive 'mb-stays'
        [IO.File]::WriteAllText($p, "first`r`n# >>> tmuxkeep`r`nold`r`n# <<< tmuxkeep`r`nlast`r`n")
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block -AtTop
        [IO.File]::ReadAllText($p) | Should -BeExactly ("first`r`n" + $BlockText + "last`r`n")
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        [IO.File]::ReadAllText($p) | Should -BeExactly ("first`r`n" + $BlockText + "last`r`n")
    }

    It 'replaces a changed block in place and keeps every byte around it' {
        $p = Join-Path $TestDrive 'mb-replace'
        $e = [string][char]0x00E9
        [IO.File]::WriteAllBytes($p, [Text.Encoding]::UTF8.GetBytes("top$e`r`n# >>> tmuxkeep`r`nold`r`n# <<< tmuxkeep`r`nbottom`n"))
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($p)) | Should -BeExactly ("top$e`r`n" + $BlockText + "bottom`n")
    }

    It 'replaces an LF-only block at the very end of a file without a final newline' {
        $p = Join-Path $TestDrive 'mb-lf'
        [IO.File]::WriteAllText($p, "a`n# >>> tmuxkeep`nold`n# <<< tmuxkeep")
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        [IO.File]::ReadAllText($p) | Should -BeExactly ("a`n" + $BlockText)
    }

    It 'leaves a file with an identical block untouched' {
        $p = Join-Path $TestDrive 'mb-same'
        [IO.File]::WriteAllText($p, "x`r`n`r`n" + $BlockText)
        (Get-Item -LiteralPath $p).LastWriteTimeUtc = [DateTime]::new(2001, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        (Get-Item -LiteralPath $p).LastWriteTimeUtc.Year | Should -Be 2001
    }

    It 'refuses <Name> and leaves the file untouched' -ForEach @(
        @{ Name = 'two begin markers';                    Message = "*has more than one '# >>> tmuxkeep' line*"; Text = "# >>> tmuxkeep`n1`n# <<< tmuxkeep`n# >>> tmuxkeep`n2`n# <<< tmuxkeep`n" }
        @{ Name = 'a begin marker without an end marker'; Message = "*without '# <<< tmuxkeep'*";               Text = "x`n# >>> tmuxkeep`nold`n" }
    ) {
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($p, $Text)
        $before = [IO.File]::ReadAllBytes($p) -join ','
        { Set-TmuxkeepMarkedBlock -Path $p -Lines $Block } | Should -Throw -ExpectedMessage $Message
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly $before
    }

    It 'refuses a UTF-16 file and a non-ASCII block line, writing nothing' {
        $p = Join-Path $TestDrive 'mb-utf16'
        [IO.File]::WriteAllText($p, "Host x`r`n", [Text.Encoding]::Unicode)
        $before = [IO.File]::ReadAllBytes($p) -join ','
        { Set-TmuxkeepMarkedBlock -Path $p -Lines $Block } | Should -Throw -ExpectedMessage '*is UTF-16; convert it to UTF-8 or ASCII first'
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly $before
        $q = Join-Path $TestDrive 'mb-ascii'
        { Set-TmuxkeepMarkedBlock -Path $q -Lines @('# >>> tmuxkeep', ('caf' + [char]0x00E9), '# <<< tmuxkeep') } | Should -Throw -ExpectedMessage '*non-ASCII*'
        Test-Path -LiteralPath $q | Should -BeFalse
    }

    It 'does not take a longer marker, such as the VPS PATH block, for its own' {
        $p = Join-Path $TestDrive 'mb-longer'
        [IO.File]::WriteAllText($p, "# >>> tmuxkeep path`nx`n# <<< tmuxkeep path`n")
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        [IO.File]::ReadAllText($p) | Should -BeExactly ("# >>> tmuxkeep path`nx`n# <<< tmuxkeep path`n`r`n" + $BlockText)
        $q = Join-Path $TestDrive 'mb-longer-top'
        [IO.File]::WriteAllText($q, "# >>> tmuxkeep path`nx`n# <<< tmuxkeep path`n")
        Set-TmuxkeepMarkedBlock -Path $q -Lines $Block -AtTop
        [IO.File]::ReadAllText($q) | Should -BeExactly ($BlockText + "`r`n" + "# >>> tmuxkeep path`nx`n# <<< tmuxkeep path`n")
    }
}

Describe 'Get-TmuxkeepSshBlock' {
    It 'renders the fixture block for the default config' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '203.0.113.10'
        $expected = [IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\ssh-block')).TrimEnd("`n").Split([char]10)
        (@(Get-TmuxkeepSshBlock -Config $v) -join '|') | Should -BeExactly ($expected -join '|')
    }

    It 'takes HOST, PORT, USER and both keys from the config, quoting a key path with a space (plan Q10)' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '2001:db8::5'
        $v['PORT'] = '2222'
        $v['USER'] = 'bob'
        $v['KEY'] = '~/my keys/k'
        $v['ADMIN_KEY'] = 'C:\keys\admin'
        $b = @(Get-TmuxkeepSshBlock -Config $v)
        $b.Count | Should -Be 18
        $b[2] | Should -BeExactly '    HostName 2001:db8::5'
        $b[3] | Should -BeExactly '    Port 2222'
        $b[4] | Should -BeExactly '    User bob'
        $b[5] | Should -BeExactly '    IdentityFile "~/my keys/k"'
        $b[10] | Should -BeExactly '    HostName 2001:db8::5'
        $b[12] | Should -BeExactly '    User root'
        $b[13] | Should -BeExactly '    IdentityFile C:\keys\admin'
    }

    It 'pins AddKeysToAgent no under Host tmuxkeep-admin only, has no UseKeychain or IgnoreUnknown, and ends with Host * (I1)' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '203.0.113.10'
        $b = @(Get-TmuxkeepSshBlock -Config $v)
        $b[9] | Should -BeExactly 'Host tmuxkeep-admin'
        $b[14] | Should -BeExactly '    IdentitiesOnly yes'
        $b[15] | Should -BeExactly '    AddKeysToAgent no'
        # Host * hands global scope back to whatever follows the block; the option above still comes first.
        $b[16] | Should -BeExactly 'Host *'
        $b[17] | Should -BeExactly '# <<< tmuxkeep'
        @($b | Where-Object { $_ -cmatch 'AddKeysToAgent' }).Count | Should -Be 1
        # An OpenSSH without UseKeychain rejects the whole config for the keyword, in any section.
        @($b | Where-Object { $_ -match 'UseKeychain|IgnoreUnknown' }).Count | Should -Be 0
        @($b | Where-Object { $_ -cmatch '^Host ' }).Count | Should -Be 3
    }
}

Describe 'Set-TmuxkeepHostBlock' {
    It 'writes both hosts at the top of ssh config so they win over a later Host *, then replaces them in place when HOST changes (spec 6.1 step 3, I1)' {
        $cfgPath = Join-Path $TestDrive 'hb home\.ssh\config'
        New-Item -ItemType Directory -Path (Split-Path $cfgPath) | Out-Null
        $old = "Host other`n    HostName 198.51.100.7`n`nHost *`n    AddKeysToAgent yes`n    UseKeychain yes`n"
        [IO.File]::WriteAllText($cfgPath, $old)
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '203.0.113.10'
        Set-TmuxkeepHostBlock -ConfigPath $cfgPath -Config $v
        $fixture = [IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\ssh-block')).Replace("`n", "`r`n")
        [IO.File]::ReadAllText($cfgPath) | Should -BeExactly ($fixture + "`r`n" + $old)
        $v['HOST'] = '198.51.100.20'
        Set-TmuxkeepHostBlock -ConfigPath $cfgPath -Config $v
        $text = [IO.File]::ReadAllText($cfgPath)
        ([regex]::Matches($text, '(?m)^# >>> tmuxkeep\r?$')).Count | Should -Be 1
        ([regex]::Matches($text, '(?m)^    HostName 198\.51\.100\.20\r?$')).Count | Should -Be 2
        $text | Should -Not -Match '203\.0\.113\.10'
        $text | Should -Match '^# >>> tmuxkeep\r\n'
        $text.EndsWith("`r`n" + $old) | Should -BeTrue
    }

    It 'replaces a block that starts right after a UTF-8 BOM, keeping the BOM bytes' {
        $cfgPath = Join-Path $TestDrive 'hb-bom\config'
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '198.51.100.7'
        $oldBlock = (@(Get-TmuxkeepSshBlock -Config $v) -join "`r`n") + "`r`n"
        New-Item -ItemType Directory -Path (Split-Path $cfgPath) | Out-Null
        [IO.File]::WriteAllBytes($cfgPath, [byte[]]([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes($oldBlock)))
        $v['HOST'] = '203.0.113.10'
        Set-TmuxkeepHostBlock -ConfigPath $cfgPath -Config $v
        $bytes = [IO.File]::ReadAllBytes($cfgPath)
        ($bytes[0..2] -join ',') | Should -BeExactly '239,187,191'
        $text = [Text.Encoding]::GetEncoding(28591).GetString($bytes, 3, $bytes.Length - 3)
        ([regex]::Matches($text, '# >>> tmuxkeep')).Count | Should -Be 1
        ([regex]::Matches($text, 'HostName 203\.0\.113\.10')).Count | Should -Be 2
        $text | Should -Not -Match '198\.51\.100\.7'
        $text | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\ssh-block')).Replace("`n", "`r`n"))
    }
}

Describe 'Set-TmuxkeepProfileSnippet (a profile path with spaces, v1 Review Focus 5)' {
    It 'writes the snippet once to a profile path with spaces, creating folders' {
        $p = Join-Path $TestDrive 'Cloud Drive\My Docs\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
        $snippet = Join-Path $Repo 'laptop\profile-snippet.ps1'
        Set-TmuxkeepProfileSnippet -ProfilePath $p -SnippetPath $snippet
        Set-TmuxkeepProfileSnippet -ProfilePath $p -SnippetPath $snippet
        $text = [IO.File]::ReadAllText($p)
        ([regex]::Matches($text, '(?m)^# >>> tmuxkeep\r?$')).Count | Should -Be 1
        $text | Should -Match ([regex]::Escape('Register-ArgumentCompleter -Native -CommandName tmuxkeep'))
    }

    It 'appends the snippet after the profile, so a profile that starts with using statements still works' {
        $p = Join-Path $TestDrive 'prof-using\p.ps1'
        New-Item -ItemType Directory -Path (Split-Path $p) | Out-Null
        [IO.File]::WriteAllText($p, "using namespace System.Collections`r`nSet-Alias ll Get-ChildItem`r`n")
        Set-TmuxkeepProfileSnippet -ProfilePath $p -SnippetPath (Join-Path $Repo 'laptop\profile-snippet.ps1')
        $text = [IO.File]::ReadAllText($p)
        $text | Should -Match '^using namespace System\.Collections\r\nSet-Alias ll Get-ChildItem\r\n\r\n# >>> tmuxkeep\r\n'
        $text | Should -Match '# <<< tmuxkeep\r\n$'
    }

    It 'replaces an older snippet in place and keeps the rest of the profile (plan Q9)' {
        $p = Join-Path $TestDrive 'prof2\a b.ps1'
        New-Item -ItemType Directory -Path (Split-Path $p) | Out-Null
        [IO.File]::WriteAllText($p, "Set-Alias ll Get-ChildItem`r`n# >>> tmuxkeep`r`nfunction global:tmuxkeep { 'old' }`r`n# <<< tmuxkeep`r`nSet-Alias gs git`r`n")
        Set-TmuxkeepProfileSnippet -ProfilePath $p -SnippetPath (Join-Path $Repo 'laptop\profile-snippet.ps1')
        $text = [IO.File]::ReadAllText($p)
        $text | Should -Match '^Set-Alias ll Get-ChildItem\r\n# >>> tmuxkeep\r\n'
        $text | Should -Match 'Set-Alias gs git\r\n$'
        $text | Should -Not -Match "'old'"
    }

    It 'refuses a UTF-16 profile' {
        $u = Join-Path $TestDrive 'prof3\u16.ps1'
        New-Item -ItemType Directory -Path (Split-Path $u) | Out-Null
        [IO.File]::WriteAllText($u, "# x`r`n", [Text.Encoding]::Unicode)
        { Set-TmuxkeepProfileSnippet -ProfilePath $u -SnippetPath (Join-Path $Repo 'laptop\profile-snippet.ps1') } | Should -Throw -ExpectedMessage '*is UTF-16; convert it to UTF-8 or ASCII first'
    }
}
