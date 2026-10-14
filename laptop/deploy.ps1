# Operator deploy script for tmuxkeep (spec 6.1, 6.3). Windows PowerShell 5.1, ASCII only.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 [-Config <path>] [-Init] [-HardenRoot] [-RotateTotp] [-UnlockOtp]
# -HomeDir and -ProfilePath exist for the tests and default to $HOME and $PROFILE.
# Agents never run this script themselves. The Pester tests dot-source it (functions only) and
# run it in a child powershell.exe with stub ssh, scp and ssh-keygen first on PATH.
param(
    [string]$Config = '',
    [switch]$Init,
    [switch]$HardenRoot,
    [switch]$RotateTotp,
    [switch]$UnlockOtp,
    [string]$HomeDir = $HOME,
    [string]$ProfilePath = $PROFILE
)

# The eight files staged from vps/, in this order. One line on purpose: the parity test reads it.
function Get-TmuxkeepVpsFiles { @('tmuxkeep', 'tmuxkeep-setup', 'vps-facts.sh', 'sshd.conf.tmpl', 'sudoers.tmpl', 'tmux.conf', 'systemd/tmuxkeep-reaper.service', 'systemd/tmuxkeep-reaper.timer') }

# Staged files are always written with LF: a CR in a bash script breaks it on the VPS.
function ConvertTo-TmuxkeepLf {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", '')
}

# UTF-8 without BOM, LF line endings; creates the parent folder.
function Write-TmuxkeepLfFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    [IO.File]::WriteAllText($full, (ConvertTo-TmuxkeepLf $Text), (New-Object System.Text.UTF8Encoding $false))
}

# Short git hash of HEAD, plus -dirty when the work tree has any change.
function Get-TmuxkeepVersion {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $hash = (@(& git -C $RepoRoot rev-parse --short HEAD) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $hash) {
        throw "git rev-parse failed in $RepoRoot"
    }
    $status = (@(& git -C $RepoRoot status --porcelain) -join '').Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed in $RepoRoot"
    }
    if ($status) {
        $hash = "$hash-dirty"
    }
    return $hash
}

# Builds the folder that is copied to the VPS. Nothing is written unless every input is good.
function New-TmuxkeepStaging {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$PubKeyPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$Destination
    )
    # The version is written into a bash file: only a git hash is allowed.
    if ($Version -cnotmatch '^[0-9a-f]{4,40}(-dirty)?\z') {
        throw "version '$Version' is not a git short hash"
    }
    $staged = [ordered]@{}
    foreach ($rel in Get-TmuxkeepVpsFiles) {
        $src = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
            (Join-Path $RepoRoot ('vps\' + $rel.Replace('/', '\'))))
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            throw "missing $src"
        }
        $text = ConvertTo-TmuxkeepLf ([IO.File]::ReadAllText($src))
        if ($rel -eq 'tmuxkeep') {
            $rx = '(?m)^TMUXKEEP_VERSION=dev$'
            if ([regex]::Matches($text, $rx).Count -ne 1) {
                throw "$src must contain exactly one TMUXKEEP_VERSION=dev line"
            }
            $text = [regex]::Replace($text, $rx, ('TMUXKEEP_VERSION=' + $Version))
        }
        $staged[$rel] = $text
    }
    $pubFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PubKeyPath)
    if (-not (Test-Path -LiteralPath $pubFull -PathType Leaf)) {
        throw "missing $pubFull"
    }
    $staged['laptop.pub'] = [IO.File]::ReadAllText($pubFull)
    $staged['deploy.conf'] = ConvertTo-TmuxkeepDeployConf -Values $Config

    foreach ($rel in $staged.Keys) {
        Write-TmuxkeepLfFile -Path (Join-Path $Destination $rel.Replace('/', '\')) -Text $staged[$rel]
    }
}

# The one remote command (plan Q4). Single-quoted format string: $? and $rc stay literal for the
# remote shell, and there is no double quote (5.1 does not escape them for native programs).
function Get-TmuxkeepSetupCommand {
    param(
        [Parameter(Mandatory)][string]$StageName,
        [switch]$HardenRoot,
        [switch]$RotateTotp,
        [switch]$UnlockOtp
    )
    # The stage name is interpolated into rm -rf.
    if ($StageName -cnotmatch '^tmuxkeep-deploy-[0-9]{14}\z') {
        throw "stage name '$StageName' is not tmuxkeep-deploy-<14 digits>"
    }
    $flags = ''
    if ($HardenRoot) { $flags += ' --harden-root' }
    if ($RotateTotp) { $flags += ' --rotate-totp' }
    if ($UnlockOtp) { $flags += ' --unlock-otp' }
    return ('bash /root/{0}/tmuxkeep-setup --pubkey-file /root/{0}/laptop.pub --key-id laptop --conf /root/{0}/deploy.conf{1}; rc=$?; rm -rf /root/{0}; exit $rc' -f $StageName, $flags)
}

# Spec 6.5 and plan Q11: the six lines that set up the admin key, built from the config. Returned, not
# printed; nothing here is executed. PowerShell does not expand ~ for native programs, so the
# ssh-keygen path is expanded here and wrapped in double quotes when it has a space. The public key
# goes into step 2 only when the file exists and its first line is a plain ssh-ed25519 line.
function Get-TmuxkeepAdminHelp {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$HomeDir
    )
    $adminKey = Expand-TmuxkeepPath -Path ([string]$Config['ADMIN_KEY']) -HomeDir $HomeDir
    $shown = $adminKey
    if ($shown.Contains(' ')) {
        $shown = '"' + $shown + '"'
    }
    $pub = '<contents of ' + [string]$Config['ADMIN_KEY'] + '.pub>'
    $first = @()
    try {
        $first = @(Get-Content -LiteralPath ($adminKey + '.pub') -TotalCount 1 -ErrorAction Stop)
    }
    catch {
        $first = @()
    }
    if ($first.Count -gt 0) {
        $candidate = ([string]$first[0]).Trim()
        if ($candidate -cmatch '^ssh-ed25519 [A-Za-z0-9+/=]+( [A-Za-z0-9@._-]+)?\z') {
            $pub = $candidate
        }
    }
    return @(
        ('1. ssh-keygen -t ed25519 -f ' + $shown + ' -C tmuxkeep-admin        (set a passphrase)')
        '2. Install it on the VPS with one password login:'
        ('   ssh root@' + [string]$Config['HOST'] + ' -p ' + [string]$Config['PORT'] + ' "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && echo ' + $pub + ' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"')
        '3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true'
        ''
        'Never ssh-add the admin key and never set AddKeysToAgent for it.'
    )
}

# ---- Laptop configuration, ~\.tmuxkeep\config (spec 4.1, 4.2, 4.3; plan Q5, Q14) --------------
# The same rules are implemented by the bash broker (parse_conf), the installer (read_deploy_conf)
# and the bash deploy: keep the four in step.

# The eighteen laptop keys in file order. One line on purpose: the parity test reads it.
function Get-TmuxkeepConfigKeys { @('HOST', 'PORT', 'USER', 'KEY', 'ADMIN_KEY', 'LAUNCH_CMD', 'RESUME_CMD', 'INSTALL_CLAUDE_CODE', 'LEASE_SECS', 'TOMBSTONE_TTL', 'OTP_FAIL_MAX', 'OTP_FAIL_WINDOW', 'OTP_COOLDOWN', 'OTP_HARD_MAX', 'OTP_READ_TIMEOUT', 'SEND_MAX_BYTES', 'DASHBOARD_PORT', 'TERMINAL_CMD') }

# A new ordered dictionary with every key at its default; HOST has none and stays empty.
function Get-TmuxkeepConfigDefaults {
    $d = [ordered]@{}
    $d['HOST'] = ''
    $d['PORT'] = '22'
    $d['USER'] = 'claude'
    $d['KEY'] = '~/.ssh/id_tmuxkeep_ed25519'
    $d['ADMIN_KEY'] = '~/.ssh/id_tmuxkeep_admin_ed25519'
    $d['LAUNCH_CMD'] = 'claude'
    $d['RESUME_CMD'] = 'claude --continue'
    $d['INSTALL_CLAUDE_CODE'] = 'no'
    $d['LEASE_SECS'] = '1800'
    $d['TOMBSTONE_TTL'] = '86400'
    $d['OTP_FAIL_MAX'] = '3'
    $d['OTP_FAIL_WINDOW'] = '600'
    $d['OTP_COOLDOWN'] = '300'
    $d['OTP_HARD_MAX'] = '10'
    $d['OTP_READ_TIMEOUT'] = '60'
    $d['SEND_MAX_BYTES'] = '8000'
    $d['DASHBOARD_PORT'] = '7707'
    $d['TERMINAL_CMD'] = ''
    return $d
}

# An integer is 1-7 decimal digits (leading zeros allowed), read as base 10, then range-checked.
function Assert-TmuxkeepInt {
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][int]$Lo,
        [Parameter(Mandatory)][int]$Hi
    )
    if ($Value -cmatch '^[0-9]{1,7}\z') {
        $n = [int]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($n -ge $Lo -and $n -le $Hi) {
            return
        }
    }
    throw "${Key}: must be an integer from $Lo to $Hi"
}

# Throws the bare reason for the first invalid key in list order; returns nothing when all are valid.
function Test-TmuxkeepConfigValues {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $h = [string]$Values['HOST']
    if ($h.Length -eq 0) {
        throw 'HOST: required'
    }
    # Exactly one colon is host:port; an IPv6 literal has two or more.
    if (($h.Length - $h.Replace(':', '').Length) -eq 1) {
        throw 'HOST: looks like host:port; put the port in PORT'
    }
    if ($h -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}\z') {
        throw 'HOST: not a hostname, IPv4 or IPv6 address'
    }
    Assert-TmuxkeepInt -Key 'PORT' -Value ([string]$Values['PORT']) -Lo 1 -Hi 65535
    if (([string]$Values['USER']) -cnotmatch '^[a-z_][a-z0-9_-]{0,31}\z') {
        throw 'USER: must match ^[a-z_][a-z0-9_-]{0,31}$'
    }
    foreach ($k in 'KEY', 'ADMIN_KEY') {
        $p = [string]$Values[$k]
        if ($p.Length -eq 0 -or $p.Contains('"')) {
            throw "${k}: must be a non-empty path without double quotes"
        }
    }
    foreach ($k in 'LAUNCH_CMD', 'RESUME_CMD') {
        if (([string]$Values[$k]).Length -gt 200) {
            throw "${k}: at most 200 characters"
        }
    }
    if (([string]$Values['INSTALL_CLAUDE_CODE']) -cnotmatch '^(yes|no)\z') {
        throw 'INSTALL_CLAUDE_CODE: must be yes or no'
    }
    Assert-TmuxkeepInt -Key 'LEASE_SECS' -Value ([string]$Values['LEASE_SECS']) -Lo 60 -Hi 86400
    Assert-TmuxkeepInt -Key 'TOMBSTONE_TTL' -Value ([string]$Values['TOMBSTONE_TTL']) -Lo 3600 -Hi 2592000
    Assert-TmuxkeepInt -Key 'OTP_FAIL_MAX' -Value ([string]$Values['OTP_FAIL_MAX']) -Lo 1 -Hi 20
    Assert-TmuxkeepInt -Key 'OTP_FAIL_WINDOW' -Value ([string]$Values['OTP_FAIL_WINDOW']) -Lo 60 -Hi 86400
    Assert-TmuxkeepInt -Key 'OTP_COOLDOWN' -Value ([string]$Values['OTP_COOLDOWN']) -Lo 10 -Hi 86400
    # OTP_FAIL_MAX passed above, so it is 1-7 digits and parses.
    $failMax = [int]::Parse(([string]$Values['OTP_FAIL_MAX']), [Globalization.CultureInfo]::InvariantCulture)
    Assert-TmuxkeepInt -Key 'OTP_HARD_MAX' -Value ([string]$Values['OTP_HARD_MAX']) -Lo $failMax -Hi 100
    Assert-TmuxkeepInt -Key 'OTP_READ_TIMEOUT' -Value ([string]$Values['OTP_READ_TIMEOUT']) -Lo 10 -Hi 600
    Assert-TmuxkeepInt -Key 'SEND_MAX_BYTES' -Value ([string]$Values['SEND_MAX_BYTES']) -Lo 1 -Hi 65536
    Assert-TmuxkeepInt -Key 'DASHBOARD_PORT' -Value ([string]$Values['DASHBOARD_PORT']) -Lo 1024 -Hi 65535
    if (([string]$Values['TERMINAL_CMD']).Length -gt 200) {
        throw 'TERMINAL_CMD: at most 200 characters'
    }
}

# Strict reader (spec 4.1, G30): never evaluates the file. Returns the ordered dictionary, or
# throws "config <Path>: <reason>". HOST is required; every other missing key takes its default.
function Read-TmuxkeepConfig {
    param([Parameter(Mandatory)][string]$Path)
    $prefix = "config ${Path}: "
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    try {
        $bytes = [IO.File]::ReadAllBytes($full)
    }
    catch {
        throw ($prefix + 'cannot read')
    }
    # File-level checks, in this order: BOM, CR, NUL.
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw ($prefix + 'byte order mark found (save without BOM)')
    }
    if ([Array]::IndexOf($bytes, [byte]13) -ge 0) {
        throw ($prefix + 'carriage return found (use LF line endings)')
    }
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
        throw ($prefix + 'NUL byte found')
    }
    # Latin-1 maps each byte to one char, so a UTF-8 multi-byte character is caught below as non-ASCII.
    $text = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $keys = @(Get-TmuxkeepConfigKeys)
    $values = Get-TmuxkeepConfigDefaults
    $seen = @{}
    $n = 0
    foreach ($raw in $text.Split([char]10)) {
        $n++
        $line = $raw.Trim([char]32, [char]9)
        if ($line.Length -eq 0 -or $line.StartsWith('#', [StringComparison]::Ordinal)) {
            continue
        }
        $eq = $line.IndexOf([char]61)
        if ($eq -lt 0) {
            throw ($prefix + "line ${n}: expected KEY=value")
        }
        $key = $line.Substring(0, $eq).Trim([char]32, [char]9)
        $val = $line.Substring($eq + 1).Trim([char]32, [char]9)
        if ($key -cnotmatch '^[A-Z_]+\z' -or $keys -cnotcontains $key) {
            if ($key -cmatch '^[A-Za-z0-9_]{1,64}\z') {
                throw ($prefix + "line ${n}: unknown key $key")
            }
            throw ($prefix + "line ${n}: unknown key")
        }
        if ($val -cmatch '[^\x20-\x7E]') {
            throw ($prefix + "line ${n}: non-printable or non-ASCII character in $key")
        }
        $values[$key] = $val
        $seen[$key] = $true
    }
    if (-not $seen.ContainsKey('HOST')) {
        throw ($prefix + 'HOST: required')
    }
    try {
        Test-TmuxkeepConfigValues -Values $values
    }
    catch {
        throw ($prefix + $_.Exception.Message)
    }
    return $values
}

# The full file text, LF line endings: two header lines, a blank line, then each key's comment line
# and KEY=value. tests/fixtures/laptop-config is exactly this for the defaults and a documentation-range HOST.
function ConvertTo-TmuxkeepConfigText {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $comments = @{
        HOST = 'VPS address: hostname, IPv4 or IPv6 literal.'
        PORT = 'SSH port of the VPS.'
        USER = 'Account on the VPS that owns the tmux sessions; the installer creates it.'
        KEY = 'Session key, no passphrase. ~ is your home directory.'
        ADMIN_KEY = 'Admin key for root, with a passphrase. Never add it to ssh-agent.'
        LAUNCH_CMD = 'Typed into every new session; empty opens a shell only.'
        RESUME_CMD = 'Typed by resume; empty opens a shell only.'
        INSTALL_CLAUDE_CODE = 'yes installs Claude Code for USER on the next deploy.'
        LEASE_SECS = 'Seconds one TOTP code keeps the gated verbs open (60-86400).'
        TOMBSTONE_TTL = 'Seconds a removed session survives as a tombstone (3600-2592000).'
        OTP_FAIL_MAX = 'Wrong codes within OTP_FAIL_WINDOW that start a cooldown (1-20).'
        OTP_FAIL_WINDOW = 'Seconds over which wrong codes are counted (60-86400).'
        OTP_COOLDOWN = 'Seconds of cooldown after OTP_FAIL_MAX wrong codes (10-86400).'
        OTP_HARD_MAX = 'Wrong codes since the last good one that lock the gate until root clears it (OTP_FAIL_MAX-100).'
        OTP_READ_TIMEOUT = 'Seconds the VPS waits at the TOTP prompt (10-600).'
        SEND_MAX_BYTES = 'Largest text that send accepts, in bytes (1-65536).'
        DASHBOARD_PORT = 'Loopback port for tmuxkeep ui (1024-65535).'
        TERMINAL_CMD = 'Program that opens a terminal for go and auth; empty picks the platform default.'
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# tmuxkeep laptop configuration, written by the deploy script. Edit it by hand if you like:`n")
    [void]$sb.Append("# one KEY=value per line, no quotes. Run the deploy script again after a change.`n")
    [void]$sb.Append("`n")
    foreach ($k in Get-TmuxkeepConfigKeys) {
        [void]$sb.Append('# ' + $comments[$k] + "`n")
        [void]$sb.Append($k + '=' + [string]$Values[$k] + "`n")
    }
    return $sb.ToString()
}

# UTF-8 without BOM, LF line endings; creates the folder.
function Write-TmuxkeepConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )
    Write-TmuxkeepLfFile -Path $Path -Text (ConvertTo-TmuxkeepConfigText -Values $Values)
}

# First run (plan Q14): one question, then validate and write. Nothing is written for a bad answer.
function New-TmuxkeepConfigInteractive {
    param([Parameter(Mandatory)][string]$Path)
    $answer = [string](Read-Host 'VPS address (hostname or IP)')
    $values = Get-TmuxkeepConfigDefaults
    $values['HOST'] = $answer.Trim([char]32, [char]9)
    try {
        Test-TmuxkeepConfigValues -Values $values
    }
    catch {
        throw ("config ${Path}: " + $_.Exception.Message)
    }
    Write-TmuxkeepConfig -Path $Path -Values $values
    return $values
}

# The deploy.conf text (spec 4.3) that tmuxkeep-setup --conf reads: LF line endings, no HOST, PORT or keys.
function ConvertTo-TmuxkeepDeployConf {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Written by tmuxkeep deploy from the laptop config; read by tmuxkeep-setup --conf.`n")
    foreach ($k in 'USER', 'LAUNCH_CMD', 'RESUME_CMD', 'INSTALL_CLAUDE_CODE', 'LEASE_SECS', 'TOMBSTONE_TTL', 'OTP_FAIL_MAX', 'OTP_FAIL_WINDOW', 'OTP_COOLDOWN', 'OTP_HARD_MAX', 'OTP_READ_TIMEOUT', 'SEND_MAX_BYTES') {
        [void]$sb.Append($k + '=' + [string]$Values[$k] + "`n")
    }
    return $sb.ToString()
}

# A leading ~ (alone, or before / or \) becomes HomeDir; anything else is unchanged. Path.Combine,
# not Join-Path: Join-Path fails when the drive does not exist.
function Expand-TmuxkeepPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$HomeDir
    )
    if ($Path -ceq '~') {
        return $HomeDir
    }
    if ($Path.StartsWith('~/', [StringComparison]::Ordinal) -or $Path.StartsWith('~\', [StringComparison]::Ordinal)) {
        $rest = $Path.Substring(2).Replace('/', '\').TrimStart('\')
        return [IO.Path]::Combine($HomeDir, $rest)
    }
    return $Path
}

# ssh_config reads a value with a space as several words: wrap it in double quotes (plan Q10).
function ConvertTo-TmuxkeepSshValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value.Contains(' ')) {
        return '"' + $Value + '"'
    }
    return $Value
}

# The eighteen lines of the ~/.ssh/config block (spec 6.1 step 3), without line endings. HOST, PORT, USER
# come from the config; KEY and ADMIN_KEY are written as configured (ssh expands a leading ~/ itself
# on every platform). IdentitiesOnly on both hosts. The root host pins the agent option off: ssh takes
# the first value it finds for an option, so a user's own "Host *" block that loads keys into an agent
# must not reach the admin key. The block goes to the top of the file (Set-TmuxkeepMarkedBlock -AtTop)
# so that line comes first. The last line, Host *, closes the admin section: whatever follows the block
# (the user's global lines, an Include) is global again instead of belonging to tmuxkeep-admin. There
# is no macOS keychain option here: an OpenSSH that does not know it rejects the whole file, in any
# section; Get-TmuxkeepSshAgentProblems catches a keychain setting instead. The bash deploy writes the
# same lines (tests/fixtures/ssh-block).
function Get-TmuxkeepSshBlock {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $key = ConvertTo-TmuxkeepSshValue ([string]$Config['KEY'])
    $adminKey = ConvertTo-TmuxkeepSshValue ([string]$Config['ADMIN_KEY'])
    return @(
        '# >>> tmuxkeep'
        'Host tmuxkeep'
        ('    HostName ' + [string]$Config['HOST'])
        ('    Port ' + [string]$Config['PORT'])
        ('    User ' + [string]$Config['USER'])
        ('    IdentityFile ' + $key)
        '    IdentitiesOnly yes'
        '    ServerAliveInterval 30'
        '    ServerAliveCountMax 4'
        'Host tmuxkeep-admin'
        ('    HostName ' + [string]$Config['HOST'])
        ('    Port ' + [string]$Config['PORT'])
        '    User root'
        ('    IdentityFile ' + $adminKey)
        '    IdentitiesOnly yes'
        '    AddKeysToAgent no'
        'Host *'
        '# <<< tmuxkeep'
    )
}

# What "ssh -G tmuxkeep-admin" printed (it reads the ssh config and connects to nothing), checked for
# anything that would put the admin key into an agent or the macOS keychain (I1). Returns the problems as
# bare messages, none when the answer is clean. Only a line that starts with the option name and a space
# counts. The block above normally passes; the check guards against an Include or an edited file.
function Get-TmuxkeepSshAgentProblems {
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$GOutput)
    $agent = ''
    $keychain = ''
    foreach ($raw in $GOutput) {
        $line = $raw.TrimEnd([char]13)
        if ($line.StartsWith('addkeystoagent ', [StringComparison]::Ordinal)) {
            $agent = $line.Substring(15).Trim([char]32, [char]9)
        }
        elseif ($line.StartsWith('usekeychain ', [StringComparison]::Ordinal)) {
            $keychain = $line.Substring(12).Trim([char]32, [char]9)
        }
    }
    $problems = @()
    if ($agent -cnotmatch '^(false|no)?\z') {
        $problems += "your ssh config loads keys into an agent for tmuxkeep-admin; put 'AddKeysToAgent no' under 'Host tmuxkeep-admin' before any 'Host *' block"
    }
    if ($keychain -cnotmatch '^(false|no)?\z') {
        $problems += "your ssh config stores passphrases in the keychain for tmuxkeep-admin; put 'UseKeychain no' under 'Host tmuxkeep-admin' before any 'Host *' block"
    }
    return $problems
}

# The only writer to ~/.ssh/config and the profile (spec 6.1 step 3): write-or-replace the block
# between '# >>> tmuxkeep' and '# <<< tmuxkeep', with CRLF line endings. A block that is already there
# is replaced in place. A new one is appended after a blank line (the default: the PowerShell profile,
# whose first lines may be using statements that nothing may precede) or, with -AtTop, written at the
# top of the file followed by one empty line (the ssh config: ssh takes the first value it finds for an
# option, so the option pinned in the ssh block must come before any "Host *" block of the user's own).
# A leading UTF-8 BOM stays at byte 0 in both placements; at the top the block follows it, because a
# BOM in the middle would turn the user's former first line into an unknown keyword and OpenSSH would
# refuse the whole file. The file is read and written as Latin-1, which maps every byte to one char and
# back, so everything outside the block (UTF-8 text, a BOM, LF or CRLF endings, a missing final
# newline) survives byte for byte.
function Set-TmuxkeepMarkedBlock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [switch]$AtTop
    )
    if ($Lines.Count -lt 2 -or $Lines[0] -cne '# >>> tmuxkeep' -or $Lines[$Lines.Count - 1] -cne '# <<< tmuxkeep') {
        throw "block for $Path must start with '# >>> tmuxkeep' and end with '# <<< tmuxkeep'"
    }
    foreach ($l in $Lines) {
        if ($l -cmatch '[^\x00-\x7F]') {
            throw "block for $Path has a non-ASCII character: $l"
        }
    }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $bytes = @()
    if ([IO.File]::Exists($full)) {
        $bytes = [IO.File]::ReadAllBytes($full)
    }
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
        throw "$Path is UTF-16; convert it to UTF-8 or ASCII first"
    }
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $old = $latin1.GetString($bytes)
    # The begin line starts a line, or the file when a UTF-8 BOM (read as three Latin-1 chars) comes
    # first. The BOM is looked behind, not matched, so a replacement keeps it.
    $begin = '(?:^|(?<=\A\xEF\xBB\xBF))# >>> tmuxkeep'
    if ([regex]::Matches($old, '(?m)' + $begin + '\r?$').Count -gt 1) {
        throw "$Path has more than one '# >>> tmuxkeep' line; remove the extra block by hand"
    }
    $m = [regex]::Match($old, '(?ms)' + $begin + '\r?\n.*?^# <<< tmuxkeep\r?(\n|\z)')
    if (-not $m.Success -and [regex]::IsMatch($old, '(?m)' + $begin + '\r?$')) {
        throw "$Path has '# >>> tmuxkeep' without '# <<< tmuxkeep'; fix it by hand"
    }
    $blockText = ($Lines -join "`r`n") + "`r`n"
    if ($m.Success) {
        $new = $old.Substring(0, $m.Index) + $blockText + $old.Substring($m.Index + $m.Length)
    }
    elseif ($AtTop) {
        # No block yet, placed at the top: it goes first, then one empty line, then the previous content
        # unchanged. An empty or missing file becomes the block alone. A leading UTF-8 BOM stays at
        # byte 0 and the block follows it.
        $bomText = [string][char]0xEF + [char]0xBB + [char]0xBF
        $prefix = ''
        $rest = $old
        if ($old.StartsWith($bomText, [StringComparison]::Ordinal)) {
            $prefix = $bomText
            $rest = $old.Substring(3)
        }
        $new = $prefix + $blockText
        if ($rest.Length -gt 0) {
            $new += "`r`n" + $rest
        }
    }
    else {
        # No block yet, appended: after a blank line, adding a missing final newline first.
        $new = $old
        if ($new.Length -gt 0) {
            if (-not $new.EndsWith("`n", [StringComparison]::Ordinal)) {
                $new += "`r`n"
            }
            $new += "`r`n"
        }
        $new += $blockText
    }
    if ($new -ceq $old) {
        return
    }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    [IO.File]::WriteAllBytes($full, $latin1.GetBytes($new))
}

# Spec 6.1 step 3: both Host blocks into ~/.ssh/config, replaced in place when they are already there
# and written at the top of the file when they are not.
function Set-TmuxkeepHostBlock {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    Set-TmuxkeepMarkedBlock -Path $ConfigPath -Lines @(Get-TmuxkeepSshBlock -Config $Config) -AtTop
}

# laptop\profile-snippet.ps1 into the PowerShell profile, replaced in place when it is already there and
# appended at the end when it is not (plan Q9): a profile may start with using statements, which
# nothing may precede.
function Set-TmuxkeepProfileSnippet {
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$SnippetPath
    )
    $lines = @(Get-Content -LiteralPath $SnippetPath -ErrorAction Stop)
    Set-TmuxkeepMarkedBlock -Path $ProfilePath -Lines $lines
}

# The dashboard (spec 5.3): Destination is removed and made again from <RepoRoot>\dashboard, without
# its test folder. Destination must end in \tmuxkeep-dashboard, so a wrong argument cannot remove
# anything else.
function Install-TmuxkeepDashboard {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Destination
    )
    $src = Join-Path $RepoRoot 'dashboard'
    if (-not (Test-Path -LiteralPath (Join-Path $src 'server.js') -PathType Leaf)) {
        throw ('missing ' + (Join-Path $src 'server.js'))
    }
    if ((Split-Path -Leaf $Destination) -cne 'tmuxkeep-dashboard') {
        throw "refusing to replace ${Destination}: the folder must be named tmuxkeep-dashboard"
    }
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction Stop
    }
    Copy-Item -LiteralPath $src -Destination $Destination -Recurse -ErrorAction Stop
    $tests = Join-Path $Destination 'test'
    if (Test-Path -LiteralPath $tests) {
        Remove-Item -LiteralPath $tests -Recurse -Force -ErrorAction Stop
    }
}

# Dot-sourced (the tests): functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

# ---- Main (operator only) --------------------------------------------------------------
# Only Windows PowerShell 5.1 passes the '""' passphrase below the way this script expects. From
# pwsh 7.3 on, the same argument reaches ssh-keygen as a literal two-character passphrase.
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Host 'deploy: run this with Windows PowerShell 5.1 (powershell.exe), not pwsh'
    exit 2
}
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
# An explicit empty -Config is a mistake (a variable that did not expand), not a request for the default.
if ($PSBoundParameters.ContainsKey('Config') -and $Config.Length -eq 0) { Write-Host 'deploy: -Config needs a path'; exit 2 }
if (-not $Config) { $Config = Join-Path $HomeDir '.tmuxkeep\config' }

# 0. Preflight: the tools, a git checkout, and a config that parses if it exists.
$missing = @(foreach ($t in 'ssh', 'scp', 'ssh-keygen', 'git') { if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $t } })
if ($missing.Count -gt 0) { Write-Host ('deploy: missing required tools: ' + ($missing -join ' ')); exit 2 }
& git -C $repo rev-parse --is-inside-work-tree | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "deploy: not a git checkout: $repo"; exit 2 }
$cfg = $null
if (Test-Path -LiteralPath $Config -PathType Leaf) {
    try { $cfg = Read-TmuxkeepConfig -Path $Config }
    catch { Write-Host ('deploy: ' + $_.Exception.Message); exit 2 }
}

# 1. Config: the one first-run question (spec 4.2).
if ($null -eq $cfg) {
    try { $cfg = New-TmuxkeepConfigInteractive -Path $Config }
    catch { Write-Host ('deploy: ' + $_.Exception.Message); exit 2 }
    Write-Host "deploy: wrote $Config"
}

# 2. The laptop key (no passphrase: the broker's TOTP code is the second factor).
$key = Expand-TmuxkeepPath -Path $cfg['KEY'] -HomeDir $HomeDir
if (-not (Test-Path -LiteralPath $key)) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $key))
    # The '""' is required in 5.1: an empty argument is dropped, and the literal "" reaches
    # ssh-keygen as an empty passphrase.
    & ssh-keygen -t ed25519 -f $key -C tmuxkeep-laptop -N '""'
    if ($LASTEXITCODE -ne 0) { Write-Host "deploy: ssh-keygen failed with exit $LASTEXITCODE"; exit $LASTEXITCODE }
}
if (-not (Test-Path -LiteralPath "$key.pub")) {
    Write-Host "deploy: $key.pub is missing. Move $key aside and run deploy again to make a new pair."
    exit 1
}

# 3. Both Host blocks in ~/.ssh/config, written or replaced.
try { Set-TmuxkeepHostBlock -ConfigPath (Join-Path $HomeDir '.ssh\config') -Config $cfg }
catch { Write-Host ('deploy: ' + $_.Exception.Message); exit 1 }

# 3b. What the ssh config now says about agents for the admin alias, before any connection (I1).
# ssh -G prints the settings and makes no connection. This is the one ssh here whose output is
# captured: it is not the installer and carries no secret.
$g = @(& ssh -G tmuxkeep-admin)
$gExit = $LASTEXITCODE
if ($gExit -ne 0) { Write-Host "deploy: ssh -G tmuxkeep-admin failed with exit $gExit"; exit 1 }
$agentProblems = @(Get-TmuxkeepSshAgentProblems -GOutput ([string[]]$g))
if ($agentProblems.Count -gt 0) {
    foreach ($p in $agentProblems) { Write-Host ('deploy: ' + $p) }
    exit 1
}

if ($Init) {
    Write-Host 'deploy: init done: config, laptop key and ssh config are ready.'
    Write-Host 'Next, set up the admin key once:'
    Write-Host ''
    foreach ($l in Get-TmuxkeepAdminHelp -Config $cfg -HomeDir $HomeDir) { Write-Host $l }
    exit 0
}

# 4. Stage. The folder is removed on every exit path below (step 9).
$ts = (Get-Date).ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
$stage = "tmuxkeep-deploy-$ts"
$parent = Join-Path $env:TEMP "tmuxkeep-stage-$ts"
try {
    try { New-TmuxkeepStaging -RepoRoot $repo -Version (Get-TmuxkeepVersion -RepoRoot $repo) -PubKeyPath "$key.pub" -Config $cfg -Destination (Join-Path $parent $stage) }
    catch { Write-Host ('deploy: ' + $_.Exception.Message); exit 1 }

    # 5. Copy over the admin path. A relative source keeps scp from reading 'C:' as a host.
    Push-Location -LiteralPath $parent
    try {
        & scp -o PreferredAuthentications=publickey -r $stage "tmuxkeep-admin:/root/$stage"
        $scpExit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($scpExit -eq 255) {
        Write-Host 'deploy: the admin key was not accepted, or tmuxkeep-admin is unreachable. Set up the admin path once, then run deploy again.'
        Write-Host 'If you only mistyped the passphrase, run deploy again.'
        Write-Host ''
        foreach ($l in Get-TmuxkeepAdminHelp -Config $cfg -HomeDir $HomeDir) { Write-Host $l }
        exit 1
    }
    if ($scpExit -ne 0) { Write-Host "deploy: scp failed with exit $scpExit"; exit $scpExit }

    # 6. Install. No -t; the output (the TOTP secret, once) goes to the console and is never captured.
    & ssh -o PreferredAuthentications=publickey tmuxkeep-admin (Get-TmuxkeepSetupCommand -StageName $stage -HardenRoot:$HardenRoot -RotateTotp:$RotateTotp -UnlockOtp:$UnlockOtp)
    $setupExit = $LASTEXITCODE
    if ($setupExit -eq 255) {
        # 255 is ssh itself failing (tmuxkeep-setup exits 0, 1 or 2), so nothing says how far setup got.
        Write-Host "deploy: ssh to tmuxkeep-admin failed (exit 255): wrong passphrase or the connection was lost. tmuxkeep-setup may not have run or may have stopped partway, /root/$stage may remain on the VPS, and running deploy again is safe."
        exit 255
    }
    if ($setupExit -ne 0) {
        Write-Host "deploy: tmuxkeep-setup failed with exit $setupExit"
        exit $setupExit
    }

    # 7. The wrapper, the dashboard next to it, and the profile snippet.
    try {
        $scriptsDir = Join-Path $HomeDir 'scripts'
        [void][IO.Directory]::CreateDirectory($scriptsDir)
        Copy-Item -LiteralPath (Join-Path $repo 'laptop\tmuxkeep.ps1') -Destination (Join-Path $scriptsDir 'tmuxkeep.ps1') -Force
        $dashboardDir = Join-Path $scriptsDir 'tmuxkeep-dashboard'
        Install-TmuxkeepDashboard -RepoRoot $repo -Destination $dashboardDir
        Set-TmuxkeepProfileSnippet -ProfilePath $ProfilePath -SnippetPath (Join-Path $repo 'laptop\profile-snippet.ps1')
    }
    catch { Write-Host ('deploy: ' + $_.Exception.Message); exit 1 }

    # 8. Proof of life.
    & ssh -o BatchMode=yes tmuxkeep ls
    Write-Host "deploy: proof of life exit $LASTEXITCODE"
}
finally {
    # 9. Remove the local staging folder.
    Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "dashboard: installed at $dashboardDir (run: tmuxkeep ui)"
Write-Host 'deploy: done. Open a new PowerShell window to load the tmuxkeep function.'
