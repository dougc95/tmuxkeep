#!/usr/bin/env bats
# vps/vps-facts.sh: read-only, ASCII-only, survives PowerShell 5.1's BOM + CRLF piping.
load helpers

FACTS=/src/vps/vps-facts.sh
SECTIONS=(
  '# VPS facts'
  '## Distro'
  '## Versions'
  '## Package candidates'
  '## oathtool stdin key'
  '## sshd'
  '## logind'
  '## Time sync'
  '## Locale'
  '## chattr and /var/log'
  '## /tmp cleanup'
  '## Root tmux sessions'
  '## claude processes'
  '## Root Claude Code state'
  '## Disk'
  '## Users and groups'
  '## Outbound HTTPS'
)

assert_sections() {
  local s
  for s in "${SECTIONS[@]}"; do
    printf '%s\n' "$output" | grep -qxF -- "$s" || { echo "missing section: $s"; return 1; }
  done
}

@test "facts script is ASCII only" {
  run grep -nP '[^\x00-\x7F]' "$FACTS"
  [ "$status" -eq 1 ]
}

@test "facts script passes bash -n and shellcheck" {
  run bash -n "$FACTS"
  [ "$status" -eq 0 ]
  run shellcheck -S warning "$FACTS"
  [ "$status" -eq 0 ]
}

@test "lines 1 and 2 are the BOM/CRLF guard, and line 2 forwards the arguments" {
  local want
  want=$(cat <<'EOF'
case "$0" in *vps-facts.sh) ;; *) tr -d '\r' | bash -s -- "$@"; exit $? ;; esac #
EOF
)
  [ "$(sed -n 1p "$FACTS")" = '#!/bin/bash' ]
  [ "$(sed -n 2p "$FACTS")" = "$want" ]
}

@test "runs as a file: exit 0, every section, empty stderr" {
  run --separate-stderr bash "$FACTS"
  [ "$status" -eq 0 ]
  assert_sections
  [ -z "$stderr" ]
}

@test "survives PowerShell 5.1 piping: UTF-8 BOM and CRLF on stdin" {
  run --separate-stderr bash -c "{ printf '\xef\xbb\xbf'; sed 's/\$/\r/' '$FACTS'; } | bash -s"
  [ "$status" -eq 0 ]
  assert_sections
  [[ "$output" != *$'\r'* ]]
  [ "${#stderr_lines[@]}" -le 1 ]
}

@test "the Versions section probes sudo, visudo, systemd-timesyncd and dbus-user-session" {
  run bash "$FACTS"
  [ "$status" -eq 0 ]
  local versions
  versions=$(printf '%s\n' "$output" | sed -n '/^## Versions$/,/^## Package candidates$/p')
  # A probe prints the path it found, or an "(unavailable: command -v X ...)" line.
  printf '%s\n' "$versions" | grep -Eq '(^/.*/visudo$|command -v visudo)'
  printf '%s\n' "$versions" | grep -Eq '(^/.*/sudo$|command -v sudo)'
  [[ "$versions" == *systemd-timesyncd* ]]
  [[ "$versions" == *dbus-user-session* ]]
}

@test "survives plain LF on stdin" {
  run --separate-stderr bash -c "bash -s < '$FACTS'"
  [ "$status" -eq 0 ]
  assert_sections
  [ -z "$stderr" ]
}

@test "output is ASCII only and holds no key material" {
  run bash "$FACTS"
  [ "$status" -eq 0 ]
  local bad
  bad=$(printf '%s\n' "$output" | grep -cP '[^\x00-\x7F]' || true)
  [ "$bad" -eq 0 ]
  [[ "$output" != *"PRIVATE KEY"* ]]
}

@test "never touches secrets or dumps the environment" {
  run grep -nE 'printenv|^[[:space:]]*env[[:space:]]*$|totp\.secret|authorized_keys|bash_history|/etc/shadow|id_ed25519|id_rsa' "$FACTS"
  [ "$status" -eq 1 ]
}

@test "is read-only: changes no file outside /tmp" {
  local marker="$BATS_TEST_TMPDIR/marker"
  touch "$marker"
  sleep 1
  run bash "$FACTS"
  [ "$status" -eq 0 ]
  run find /etc /var /home /root /usr /opt /srv -xdev -newer "$marker" -print
  [ -z "$output" ]
}

@test "finishes within 60 seconds" {
  run timeout 60 bash "$FACTS"
  [ "$status" -eq 0 ]
}

@test "--user is reported and probed when run as a file" {
  run --separate-stderr bash "$FACTS" --user nobody
  [ "$status" -eq 0 ]
  assert_sections
  printf '%s\n' "$output" | grep -qx 'User: nobody'
  printf '%s\n' "$output" | grep -q '^nobody:x:65534:'
  [ -z "$stderr" ]
}

@test "--user is forwarded through the PowerShell-style piped form (BOM and CRLF)" {
  run --separate-stderr bash -c "{ printf '\xef\xbb\xbf'; sed 's/\$/\r/' '$FACTS'; } | bash -s -- --user nobody"
  [ "$status" -eq 0 ]
  assert_sections
  printf '%s\n' "$output" | grep -qx 'User: nobody'
  printf '%s\n' "$output" | grep -q '^nobody:x:65534:'
  [ "${#stderr_lines[@]}" -le 1 ]
}

@test "the default user is claude" {
  run bash "$FACTS"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'User: claude'
  printf '%s\n' "$output" | grep -q '^claude:x:1000:'
}

@test "a bad --user, a missing value and an unknown argument are usage (2)" {
  run --separate-stderr bash "$FACTS" --user Bob
  [ "$status" -eq 2 ]
  [ "$stderr" = 'vps-facts: --user must match ^[a-z_][a-z0-9_-]{0,31}$' ]
  run --separate-stderr bash "$FACTS" --user
  [ "$status" -eq 2 ]
  [ "$stderr" = 'vps-facts: --user needs a value' ]
  run --separate-stderr bash "$FACTS" --frob
  [ "$status" -eq 2 ]
  [ "$stderr" = 'vps-facts: unknown argument' ]
}
