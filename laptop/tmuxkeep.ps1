# tmuxkeep.ps1 - laptop wrapper for the tmuxkeep session broker (Windows PowerShell 5.1).
#
# Usage:  & "$HOME\scripts\tmuxkeep.ps1" <words...>      (the profile function passes @args)
# Every word is base64-encoded (UTF-8) and sent as: ssh tmuxkeep b64 <token>...
# The VPS side is a forced command, so quoting never reaches a remote shell.
# Exit code: ssh's own, or 2 for a local usage error.
#
# Windows PowerShell 5.1 notes (each one was verified; keep this file as it is):
#  - No param block and no CmdletBinding attribute at the top of this script.
#    Otherwise -n and -d bind to Verbose/Debug or fail. $args is read verbatim.
#    Helper functions below may declare their own param block.
#  - ASCII only: 5.1 reads BOM-less UTF-8 as ANSI. Build non-ASCII text with [char] codes.
#  - Command mode turns "a, b" into one array argument and 20 into an Int32, so
#    the words are flattened and stringified first.
#  - PowerShell keeps '' when it calls a script but drops it when it calls a native exe,
#    so empty words are rejected here, before ssh is called.
#  - PowerShell drops a bare -- before this script ever sees it; nothing to do here.
#  - ssh runs as a plain statement: no capture, no pipe, no 2> redirect. The console
#    must stay attached to ssh so "go" and the TOTP prompt work.

$GatedVerbs = @('new', 'go', 'send', 'rename', 'unlock', 'rm', 'resume', 'auth')
$TmuxkeepHint = "tmuxkeep: ssh to host 'tmuxkeep' failed (unreachable, key rejected, or remote killed by signal)"

# Flatten any nesting and stringify every element. Always returns one string[] object,
# so callers must assign it (do not wrap the call in @( ... )).
# A dictionary (hashtable, ordered, generic Dictionary) or an XML node cannot be flattened:
# PowerShell treats both as a single value, so @($item) would hand back the same object and
# the recursion would never end. They throw instead; the main script turns that into exit 2.
function ConvertTo-TmuxkeepWords {
    param([object[]]$Items)
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $Items) {
        if ($null -eq $item) {
            $result.Add('')
        }
        elseif ($item -is [string]) {
            $result.Add($item)
        }
        elseif ($item -is [System.Collections.IDictionary] -or $item -is [System.Xml.XmlNode]) {
            throw 'tmuxkeep: unsupported argument type'
        }
        elseif ($item -is [System.Collections.IEnumerable]) {
            $inner = ConvertTo-TmuxkeepWords @($item)
            $result.AddRange([string[]]$inner)
        }
        else {
            $result.Add([string]$item)
        }
    }
    return , $result.ToArray()
}

# Base64 of the UTF-8 bytes of one word.
function ConvertTo-TmuxkeepToken {
    param([string]$Word)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Word))
}

# The full ssh argument array for these words. Always returns one string[] object.
function Get-TmuxkeepSshArgs {
    param([string[]]$Words)
    $list = @($Words)
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($a in @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5')) { $result.Add($a) }
    if ($list.Count -gt 0 -and ($list[0] -cin $GatedVerbs)) { $result.Add('-t') }
    $result.Add('tmuxkeep')
    $result.Add('b64')
    foreach ($w in $list) { $result.Add((ConvertTo-TmuxkeepToken $w)) }
    return , $result.ToArray()
}

# Dot-sourcing (. .\laptop\tmuxkeep.ps1) stops here: the helpers are defined, nothing runs.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    [string[]]$words = ConvertTo-TmuxkeepWords $args
}
catch {
    Write-Host 'tmuxkeep: unsupported argument type'
    exit 2
}

foreach ($w in $words) {
    if ($w.Length -eq 0) {
        Write-Host 'tmuxkeep: empty argument'
        exit 2
    }
}

# "send <name>" with no text: ask for it locally and send it as one word.
if ($words.Count -eq 2 -and $words[0] -ceq 'send') {
    $text = Read-Host 'Text to send'
    if ([string]::IsNullOrEmpty($text)) {
        Write-Host 'tmuxkeep: nothing to send'
        exit 2
    }
    $words = $words + $text
}

# "rm ... --now" without --confirm: ask for the session name locally.
if ($words.Count -gt 0 -and $words[0] -ceq 'rm' -and ($words -ccontains '--now') -and -not ($words -ccontains '--confirm')) {
    $answer = Read-Host 'Type the session name to confirm'
    if ([string]::IsNullOrEmpty($answer)) {
        Write-Host 'tmuxkeep: confirmation required'
        exit 2
    }
    $words = $words + '--confirm' + $answer
}

[string[]]$sshArgs = Get-TmuxkeepSshArgs $words

$global:LASTEXITCODE = $null
& ssh @sshArgs
$code = $LASTEXITCODE
if ($null -eq $code) {
    # ssh could not be started at all; never report success for that.
    $code = 1
}
if ($code -eq 255) {
    Write-Host $TmuxkeepHint
}
exit $code
