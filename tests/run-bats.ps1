# run-bats.ps1 - build the tmuxkeep test image and run bats in Docker Desktop.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 [-Path tests/bats/x.bats] [-Filter regex]
# Exit code: bats' exit code; 2 if Docker is unavailable, the path is wrong, or the build fails.
param(
    [string]$Path = 'tests/bats',
    [string]$Filter = ''
)

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$image = 'tmuxkeep-bats:latest'

& docker info --format '{{.ServerVersion}}' | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'run-bats: Docker is not available. Start Docker Desktop and retry.'
    exit 2
}

$rel = ($Path -replace '\\', '/') -replace '^\./', ''
if (-not (Test-Path -LiteralPath (Join-Path $repo $rel))) {
    Write-Host "run-bats: no such path in the repo: $rel"
    exit 2
}

& docker build --quiet --tag $image (Join-Path $repo 'tests/docker') | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'run-bats: docker build failed'; exit 2 }

$bats = @('bats')
if ($Filter) { $bats += @('--filter', $Filter) }
$bats += "/src/$rel"

# --mount (not -v) so the drive-letter colon in the Windows path is not misparsed.
& docker run --rm --mount "type=bind,source=$repo,target=/src,readonly" $image @bats
exit $LASTEXITCODE
