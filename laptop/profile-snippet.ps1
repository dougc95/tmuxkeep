# >>> tmuxkeep
# Appended to the PowerShell profile by the deploy script. Keep the two marker lines.
# tmuxkeep: call the wrapper in ~\scripts. Defined global: so it behaves the same when the
# profile dot-sources it and when a test does.
function global:tmuxkeep { & "$HOME\scripts\tmuxkeep.ps1" @args }

# Names for tab completion, cached in $env:TEMP for 60 seconds. A failed fetch is cached
# as an empty file, so an offline laptop does not wait on ssh at every Tab press.
function global:Get-TmuxkeepCompletionList {
    param([ValidateSet('names', 'tombstones')][string]$Kind)
    # Under 'Stop', 5.1 turns each stderr line of a native command into a terminating error
    # even with 2>$null. Scoped to this function, so the caller's preference is untouched.
    $ErrorActionPreference = 'Continue'
    $file = Join-Path $env:TEMP ('tmuxkeep-{0}.txt' -f $Kind)
    if (Test-Path -LiteralPath $file) {
        # UTC, and fresh only for 0 <= age < 60: a future-dated file is never trusted.
        $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $file).LastWriteTimeUtc).TotalSeconds
        if ($age -ge 0 -and $age -lt 60) {
            return @(Get-Content -LiteralPath $file | Where-Object { $_ -and $_.Trim() })
        }
    }
    $names = @()
    # Tab must not change the user's $LASTEXITCODE: put it back after reading ssh's own.
    $savedExit = $global:LASTEXITCODE
    try {
        # The one place stderr is discarded: a completer must never print ssh errors.
        # -n keeps ssh off the console input; ServerAlive* bounds a connection that dies after
        # the handshake (ConnectTimeout only covers the connect).
        $out = & ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 tmuxkeep ls "--$Kind" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $names = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        }
    }
    catch {
        $names = @()
    }
    finally {
        $global:LASTEXITCODE = $savedExit
    }
    try {
        [IO.File]::WriteAllLines($file, [string[]]$names)
    }
    catch {
        # TEMP not writable: still return what was fetched, just uncached.
    }
    return $names
}

# Tab completion: verbs, then session names (or tombstone base names for restore).
Register-ArgumentCompleter -Native -CommandName tmuxkeep -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $done = @($commandAst.CommandElements |
            Where-Object { $_.Extent.EndOffset -lt $cursorPosition } |
            ForEach-Object { $_.Extent.Text })
    $candidates = @()
    if ($done.Count -eq 1) {
        $candidates = @('new', 'ls', 'peek', 'go', 'send', 'rename', 'lock', 'unlock', 'rm', 'restore', 'resume', 'log', 'auth', 'status')
    }
    elseif ($done.Count -eq 2) {
        if ($done[1] -cin @('peek', 'go', 'send', 'rename', 'lock', 'unlock', 'rm', 'resume')) {
            $candidates = @(Get-TmuxkeepCompletionList names)
        }
        elseif ($done[1] -ceq 'restore') {
            $candidates = @(Get-TmuxkeepCompletionList tombstones)
        }
    }
    foreach ($n in $candidates) {
        if ($n -like ([System.Management.Automation.WildcardPattern]::Escape($wordToComplete) + '*')) {
            [System.Management.Automation.CompletionResult]::new($n, $n, 'ParameterValue', $n)
        }
    }
}
# <<< tmuxkeep
