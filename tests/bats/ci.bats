#!/usr/bin/env bats
# Static checks on .github/workflows/ci.yml (spec 9.6, 14). The workflow itself first runs on GitHub;
# these checks keep its required parts from drifting.
load laptop-helpers

setup() { CI_FILE="$REPO/.github/workflows/ci.yml"; }

@test "runs on push and pull_request" {
  grep -qx 'on:' "$CI_FILE"
  grep -qx '  push:' "$CI_FILE"
  grep -qx '  pull_request:' "$CI_FILE"
}

@test "the token is read-only: permissions contents: read at the top level, before the jobs" {
  local p c j
  grep -qx 'permissions:' "$CI_FILE"
  grep -qx '  contents: read' "$CI_FILE"
  [ "$(grep -c '^permissions:' "$CI_FILE")" -eq 1 ]
  [ "$(grep -c 'contents:' "$CI_FILE")" -eq 1 ]
  # Nothing but read: no write permission anywhere, and no job-level override.
  [ "$(grep -c 'write' "$CI_FILE")" -eq 0 ]
  [ "$(grep -c '^    permissions:' "$CI_FILE")" -eq 0 ]
  p=$(grep -n '^permissions:' "$CI_FILE" | cut -d: -f1)
  c=$(grep -n '^  contents: read$' "$CI_FILE" | cut -d: -f1)
  j=$(grep -n '^jobs:' "$CI_FILE" | cut -d: -f1)
  [ "$c" -eq $(( p + 1 )) ]
  [ "$p" -lt "$j" ]
}

@test "has the three jobs on the three runners" {
  grep -qx '  bats:' "$CI_FILE"
  grep -qx '    runs-on: ubuntu-latest' "$CI_FILE"
  grep -qx '  pester:' "$CI_FILE"
  grep -qx '    runs-on: windows-latest' "$CI_FILE"
  grep -qx '  macos:' "$CI_FILE"
  grep -qx '    runs-on: macos-latest' "$CI_FILE"
}

@test "the bats job runs every suite through tests/run-bats.sh" {
  grep -qx '          bash tests/run-bats.sh' "$CI_FILE"
}

@test "the pester job proves Windows PowerShell 5.1 and runs Pester under powershell.exe -NoProfile" {
  [ "$(grep -c '        shell: cmd' "$CI_FILE")" -eq 3 ]
  grep -qF "PSEdition -ne 'Desktop' -or \$PSVersionTable.PSVersion.Major -ne 5" "$CI_FILE"
  grep -qF 'Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser' "$CI_FILE"
  grep -qF "\$c.Run.Path = 'tests\pester'" "$CI_FILE"
  [ "$(grep -c 'powershell.exe -NoProfile' "$CI_FILE")" -eq 3 ]
}

@test "the macos job proves /bin/bash 3.2 and runs every laptop suite under it" {
  grep -qF "/bin/bash -c '[ \"\${BASH_VERSINFO[0]}\" = 3 ]'" "$CI_FILE"
  grep -qF 'env PATH="/bin:/usr/bin:$(brew --prefix)/bin" TK_EXPECT_BASH_MAJOR=3' "$CI_FILE"
  local f
  for f in laptop-wrapper completion laptop-config laptop-blocks laptop-deploy parity smoke lint-laptop; do
    grep -qF "tests/bats/$f.bats" "$CI_FILE" || { echo "missing tests/bats/$f.bats"; return 1; }
  done
}

@test "the workflow is ASCII, uses spaces only, and has LF line endings" {
  [ "$(LC_ALL=C tr -d '\000-\177' < "$CI_FILE" | wc -c | tr -d ' ')" = 0 ]
  [ "$(tr -cd '\t\r' < "$CI_FILE" | wc -c | tr -d ' ')" = 0 ]
}

@test "every job has a 20 minute timeout, so a hang cannot run for the default six hours" {
  [ "$(grep -c '^    timeout-minutes: 20$' "$CI_FILE")" -eq 3 ]
  local r t
  for r in ubuntu-latest windows-latest macos-latest; do
    t=$(grep -n "^    runs-on: $r$" "$CI_FILE" | cut -d: -f1)
    sed -n "$(( t + 1 ))p" "$CI_FILE" | grep -qx '    timeout-minutes: 20'
  done
}
