# smoke.ps1 - operator end-to-end smoke test for the tmuxkeep session broker (Windows PowerShell 5.1).
#
# Run it yourself, from a terminal, against the real VPS:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 [-Wrapper <path>]
# The default wrapper is $HOME\scripts\tmuxkeep.ps1. Agents never run this against the real wrapper;
# tests\pester\smoke.Tests.ps1 drives it with a fake wrapper instead.
#
# It creates one throwaway session named smoke-<6 random chars>, walks it through the whole
# lifecycle (14 steps), and removes it again. Exit 0 when every step passes. Exit 1 at the first
# mismatch: the script stops there and prints how to clean up by hand. The same cleanup hint is
# printed if the run is interrupted (Ctrl+C) while a session may exist.
#
# Step 1 (auth) runs uncaptured so the "TOTP: " prompt (which arrives on ssh's stdout) reaches the
# console. Every other step is captured with Out-String. The gated verbs after auth reuse the lease.
param([string]$Wrapper = (Join-Path $HOME 'scripts\tmuxkeep.ps1'))

$script:SessionMayExist = $false
$script:HintPrinted = $false
$script:LastOut = ''

# Print how to remove a leftover test session, at most once, and only while one may exist.
# Called from Stop-Smoke (so the hint follows the FAIL text) and from the finally block below
# (so an interrupt still gets it). The HintPrinted flag stops a normal FAIL from printing it twice.
function Write-CleanupHint {
    if (-not $script:SessionMayExist -or $script:HintPrinted) { return }
    $script:HintPrinted = $true
    Write-Host "A test session may be left behind. To clean it up: tmuxkeep rm $n --now --confirm $n"
    Write-Host "If the rm is refused as locked: run 'tmuxkeep restore $n' only if 'tmuxkeep ls' shows a zz~$n~... row, then 'tmuxkeep unlock $n', then the rm again."
}

# Print the failure, the cleanup hint (when a session may be left behind), and stop.
function Stop-Smoke {
    param([string]$Step, [string]$Reason, [string]$Output = '')
    Write-Host "FAIL ${Step}: $Reason"
    if ($Output.Trim().Length -gt 0) {
        Write-Host '--- output ---'
        Write-Host $Output.TrimEnd()
        Write-Host '--- end of output ---'
    }
    Write-CleanupHint
    exit 1
}

# Check one step's exit code and (optionally) its output, print PASS, or stop on the first mismatch.
function Confirm-Step {
    param([string]$Step, [object]$Code, [int]$ExpectCode, [string]$Output = '', [string]$Pattern = '')
    if ($null -eq $Code) {
        Stop-Smoke -Step $Step -Reason 'the wrapper returned no exit code' -Output $Output
    }
    if ($Code -ne $ExpectCode) {
        Stop-Smoke -Step $Step -Reason "exit code $Code, expected $ExpectCode" -Output $Output
    }
    if ($Pattern -ne '' -and $Output -cnotmatch $Pattern) {
        Stop-Smoke -Step $Step -Reason "output did not match /$Pattern/" -Output $Output
    }
    Write-Host "PASS $Step"
}

# Run one captured step: call the wrapper, capture its output as one string, then check it.
# The output is left in $script:LastOut.
function Invoke-Step {
    param([string]$Step, [string[]]$Words, [int]$ExpectCode = 0, [string]$Pattern = '')
    $global:LASTEXITCODE = $null
    $script:LastOut = & $Wrapper @Words | Out-String
    Confirm-Step -Step $Step -Code $LASTEXITCODE -ExpectCode $ExpectCode -Output $script:LastOut -Pattern $Pattern
}

if (-not (Test-Path -LiteralPath $Wrapper)) {
    Write-Host "FAIL setup: wrapper not found: $Wrapper"
    exit 1
}

$chars = 'abcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
$n = 'smoke-' + (-join (1..6 | ForEach-Object { Get-Random -InputObject $chars }))
$e = [regex]::Escape($n)
Write-Host "smoke: session name $n"

# 1. auth, uncaptured, so the TOTP prompt reaches the console.
Write-Host 'Type the code from your phone at the TOTP prompt.'
$global:LASTEXITCODE = $null
& $Wrapper auth
Confirm-Step -Step '1/14 auth' -Code $LASTEXITCODE -ExpectCode 0

# Steps 2-14 run inside try/finally: if the run is interrupted (Ctrl+C) or a step throws while a
# session may exist, the finally block still prints the cleanup hint. A normal FAIL has already
# printed it (once, via Stop-Smoke); a clean run has SessionMayExist false, so nothing prints.
try {
    # A session may exist from here on, even if `new` itself fails halfway.
    $script:SessionMayExist = $true

    Invoke-Step -Step "2/14 new $n" -Words @('new', $n) -Pattern "created $e in "
    Invoke-Step -Step '3/14 ls (live row)' -Words @('ls') -Pattern "(?m)^$e\s+live"

    # 4. The dashboard's status: one JSON object that names the session. PASS only after that check.
    $statusStep = '4/14 status (JSON naming the session)'
    $global:LASTEXITCODE = $null
    $script:LastOut = & $Wrapper status | Out-String
    $statusCode = $LASTEXITCODE
    if ($statusCode -eq 0) {
        $named = $false
        try {
            $obj = $script:LastOut | ConvertFrom-Json -ErrorAction Stop
            $named = @($obj.sessions | Where-Object { $_.name -ceq $n }).Count -gt 0
        }
        catch {
            $named = $false
        }
        if (-not $named) {
            Stop-Smoke -Step $statusStep -Reason "the status output does not name $n" -Output $script:LastOut
        }
    }
    Confirm-Step -Step $statusStep -Code $statusCode -ExpectCode 0 -Output $script:LastOut

    Invoke-Step -Step "5/14 peek $n" -Words @('peek', $n)
    Invoke-Step -Step "6/14 send $n /help" -Words @('send', $n, '/help') -Pattern "sent \d+ bytes to $e"
    Invoke-Step -Step "7/14 lock $n" -Words @('lock', $n) -Pattern "locked $e"
    Invoke-Step -Step "8/14 rm $n (locked, must be refused with exit 3)" -Words @('rm', $n) -ExpectCode 3
    Invoke-Step -Step "9/14 unlock $n" -Words @('unlock', $n)
    Invoke-Step -Step "10/14 rm $n (tombstone)" -Words @('rm', $n) -Pattern "tombstoned $e;"
    Invoke-Step -Step '11/14 ls (tombstone row)' -Words @('ls') -Pattern "(?m)^zz~$e~\d+\s+tombstone"
    Invoke-Step -Step "12/14 restore $n" -Words @('restore', $n) -Pattern "restored $e"
    Invoke-Step -Step "13/14 rm $n --now --confirm $n" -Words @('rm', $n, '--now', '--confirm', $n) -Pattern "killed $e"

    # The session is gone now; a later failure has nothing to clean up.
    $script:SessionMayExist = $false

    # 14. The audit log must show every verb we used, against this session, and the status call of
    # step 4 (status is audited like peek, amended D19; its line has no session name). This step does
    # its own check (instead of Invoke-Step) so that PASS is printed only after the audit lines are verified.
    $logStep = '14/14 log -n 20 (audit lines for this session)'
    $logWords = @('log', '-n', '20')
    $global:LASTEXITCODE = $null
    $script:LastOut = & $Wrapper @logWords | Out-String
    $logCode = $LASTEXITCODE
    if ($logCode -eq 0) {
        $lines = @($script:LastOut -split "\r?\n")
        $sessionKey = '"session":"' + $n + '"'
        $missing = @()
        foreach ($v in @('new', 'peek', 'send', 'lock', 'rm', 'unlock', 'restore')) {
            $verbKey = '"verb":"' + $v + '"'
            $hits = @($lines | Where-Object { $_.Contains($verbKey) -and $_.Contains($sessionKey) })
            if ($hits.Count -eq 0) { $missing += $v }
        }
        if ($missing.Count -gt 0) {
            Stop-Smoke -Step $logStep -Reason ('no audit line for session ' + $n + ' and verb: ' + ($missing -join ', ')) -Output $script:LastOut
        }
        $statusHits = @($lines | Where-Object { $_.Contains('"verb":"status"') -and $_.Contains('"session":""') })
        if ($statusHits.Count -eq 0) {
            Stop-Smoke -Step $logStep -Reason 'no audit line with verb status and no session (status is audited, one line per call)' -Output $script:LastOut
        }
    }
    Confirm-Step -Step $logStep -Code $logCode -ExpectCode 0 -Output $script:LastOut
}
finally {
    Write-CleanupHint
}

Write-Host 'smoke: all steps passed'
exit 0
