# Static checks on every PowerShell file: ASCII only, parses cleanly; the wrapper has no param block.
BeforeDiscovery {
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:PsFiles = @(Get-ChildItem -Path (Join-Path $repo 'laptop'), (Join-Path $repo 'tests') -Recurse -Filter *.ps1 -File |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repo.Length + 1) } })
}

Describe 'PowerShell file <Name>' -ForEach $PsFiles {
    It 'is ASCII only' {
        $bytes = [IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'parses without errors' {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

Describe 'laptop/tmuxkeep.ps1 shape' {
    It 'has no param block and no CmdletBinding' {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'laptop\tmuxkeep.ps1'), [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $ast.ParamBlock | Should -BeNullOrEmpty
        $ast.Extent.Text | Should -Not -Match '\[CmdletBinding'
    }
}

Describe 'LF-only files (spec 9.5)' {
    BeforeDiscovery {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:LfFiles = @(
            @(Get-ChildItem -Path (Join-Path $repo 'laptop') -Filter '*.sh' -File) +
            @(Get-Item -LiteralPath (Join-Path $repo 'laptop\completion.bash')) +
            @(Get-ChildItem -Path (Join-Path $repo 'vps') -Recurse -File) +
            @(Get-ChildItem -Path (Join-Path $repo 'tests\fixtures') -File) |
                ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repo.Length + 1) } })
    }

    It '<Name> has no CR, no BOM and only ASCII' -ForEach $LfFiles {
        $b = [IO.File]::ReadAllBytes($Path)
        ($b -contains 13) | Should -BeFalse -Because 'bash and the VPS need LF line endings'
        ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeFalse
        @($b | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe '.gitattributes' {
    It 'forces LF on the laptop bash files, vps and tests, and leaves the PowerShell files alone' {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        foreach ($p in 'laptop/tmuxkeep.sh', 'laptop/deploy.sh', 'laptop/completion.bash', 'vps/tmuxkeep', 'tests/smoke.sh') {
            ((& git -C $repo check-attr eol -- $p) -join '') | Should -BeExactly ($p + ': eol: lf')
        }
        ((& git -C $repo check-attr eol -- 'laptop/deploy.ps1') -join '') | Should -BeExactly 'laptop/deploy.ps1: eol: unspecified'
    }
}
