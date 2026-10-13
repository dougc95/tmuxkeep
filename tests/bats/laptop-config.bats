#!/usr/bin/env bats
# laptop/deploy.sh config functions (spec 4.1, 4.2, 4.3; plan Q5, Q14; Review Focus 2). The file is
# sourced, so only its functions run. Same table of cases as tests/pester/config.Tests.ps1.
load laptop-helpers

setup() {
  laptop_setup
  # shellcheck source=/dev/null
  source "$REPO/laptop/deploy.sh"
  FIX="$REPO/tests/fixtures/laptop-config"
  C="$BATS_TEST_TMPDIR/config"
}

# with_line KEY VALUE: the fixture with KEY's line replaced, written to $C.
with_line() {
  TK_K=$1 TK_V=$2 awk 'BEGIN { k = ENVIRON["TK_K"]; v = ENVIRON["TK_V"] }
    index($0, k "=") == 1 { print k "=" v; next } { print }' "$FIX" > "$C"
}

# reason FILE: what tk_conf_read reports for FILE, or "no error".
reason() {
  if tk_conf_read "$1"; then echo 'no error'; else printf '%s\n' "$TK_ERR"; fi
}

@test "reads the fixture" {
  tk_conf_read "$FIX"
  [ "$TKC_HOST" = 203.0.113.10 ]
  [ "$TKC_PORT" = 22 ]
  [ "$TKC_KEY" = '~/.ssh/id_tmuxkeep_ed25519' ]
  [ "$TKC_RESUME_CMD" = 'claude --continue' ]
  [ "$TKC_SEND_MAX_BYTES" = 8000 ]
}

@test "tk_conf_text for the defaults and HOST=203.0.113.10 is the fixture, byte for byte" {
  tk_conf_defaults
  TKC_HOST=203.0.113.10
  tk_conf_text > "$C"
  cmp "$C" "$FIX"
}

@test "tk_conf_write creates the folder and writes the same bytes" {
  tk_conf_defaults
  TKC_HOST=203.0.113.10
  tk_conf_write "$HOME/.tmuxkeep/config"
  cmp "$HOME/.tmuxkeep/config" "$FIX"
}

@test "a missing key other than HOST takes its default; a missing HOST is required" {
  grep -v '^PORT=' "$FIX" > "$C"
  TKC_PORT=999
  tk_conf_read "$C"
  [ "$TKC_PORT" = 22 ]
  grep -v '^HOST=' "$FIX" > "$C"
  [ "$(reason "$C")" = "$C: HOST: required" ]
}

@test "blank lines, comments, padding and a repeated key (the last wins)" {
  { printf '\n# note\n \t \n'
    sed 's/^\([A-Z_]*\)=\(.*\)$/  \1 = \2  /' "$FIX"
    printf 'PORT=2200\nPORT=2222\n'
  } > "$C"
  tk_conf_read "$C"
  [ "$TKC_PORT" = 2222 ]
  [ "$TKC_HOST" = 203.0.113.10 ]
  [ "$TKC_RESUME_CMD" = 'claude --continue' ]
}

@test "rejects each invalid value with the key named" {
  local k v want
  while IFS='|' read -r k v want; do
    with_line "$k" "$v"
    [ "$(reason "$C")" = "$C: $want" ] || { echo "$k=$v: $(reason "$C")"; return 1; }
  done <<'EOF'
HOST||HOST: required
HOST|203.0.113.10:2222|HOST: looks like host:port; put the port in PORT
HOST|you@203.0.113.10|HOST: not a hostname, IPv4 or IPv6 address
HOST|-x.example|HOST: not a hostname, IPv4 or IPv6 address
PORT|0|PORT: must be an integer from 1 to 65535
PORT|65536|PORT: must be an integer from 1 to 65535
PORT|ssh|PORT: must be an integer from 1 to 65535
USER|Bob|USER: must match ^[a-z_][a-z0-9_-]{0,31}$
KEY||KEY: must be a non-empty path without double quotes
KEY|a"b|KEY: must be a non-empty path without double quotes
ADMIN_KEY||ADMIN_KEY: must be a non-empty path without double quotes
INSTALL_CLAUDE_CODE|Yes|INSTALL_CLAUDE_CODE: must be yes or no
LEASE_SECS|59|LEASE_SECS: must be an integer from 60 to 86400
LEASE_SECS|86401|LEASE_SECS: must be an integer from 60 to 86400
LEASE_SECS|-60|LEASE_SECS: must be an integer from 60 to 86400
LEASE_SECS|00001800|LEASE_SECS: must be an integer from 60 to 86400
TOMBSTONE_TTL|3599|TOMBSTONE_TTL: must be an integer from 3600 to 2592000
TOMBSTONE_TTL|2592001|TOMBSTONE_TTL: must be an integer from 3600 to 2592000
OTP_FAIL_MAX|0|OTP_FAIL_MAX: must be an integer from 1 to 20
OTP_FAIL_MAX|21|OTP_FAIL_MAX: must be an integer from 1 to 20
OTP_FAIL_WINDOW|59|OTP_FAIL_WINDOW: must be an integer from 60 to 86400
OTP_COOLDOWN|9|OTP_COOLDOWN: must be an integer from 10 to 86400
OTP_HARD_MAX|2|OTP_HARD_MAX: must be an integer from 3 to 100
OTP_HARD_MAX|101|OTP_HARD_MAX: must be an integer from 3 to 100
OTP_READ_TIMEOUT|601|OTP_READ_TIMEOUT: must be an integer from 10 to 600
SEND_MAX_BYTES|0|SEND_MAX_BYTES: must be an integer from 1 to 65536
SEND_MAX_BYTES|65537|SEND_MAX_BYTES: must be an integer from 1 to 65536
EOF
  with_line LAUNCH_CMD "$(printf 'x%.0s' $(seq 1 201))"
  [ "$(reason "$C")" = "$C: LAUNCH_CMD: at most 200 characters" ]
  with_line RESUME_CMD "$(printf 'x%.0s' $(seq 1 201))"
  [ "$(reason "$C")" = "$C: RESUME_CMD: at most 200 characters" ]
}

@test "accepts the bounds and the edge values" {
  local k v
  while IFS='|' read -r k v; do
    with_line "$k" "$v"
    [ "$(reason "$C")" = 'no error' ] || { echo "$k=$v: $(reason "$C")"; return 1; }
  done <<'EOF'
HOST|2001:db8::1
HOST|vps-1.example.org
PORT|65535
USER|_svc
KEY|~/my keys/k
LAUNCH_CMD|
LEASE_SECS|0060
TOMBSTONE_TTL|2592000
OTP_HARD_MAX|3
SEND_MAX_BYTES|65536
EOF
}

@test "the lowest OTP_HARD_MAX is the configured OTP_FAIL_MAX, read as base 10" {
  # The fixture has OTP_HARD_MAX=10, so a larger OTP_FAIL_MAX leaves it below the bound.
  with_line OTP_FAIL_MAX 15
  [ "$(reason "$C")" = "$C: OTP_HARD_MAX: must be an integer from 15 to 100" ]
  sed 's/^OTP_HARD_MAX=.*$/OTP_HARD_MAX=15/' "$C" > "$C.2"
  [ "$(reason "$C.2")" = 'no error' ]
  # 08 is 8, not an octal error: the bound is 8, so the fixture's 10 passes.
  with_line OTP_FAIL_MAX 08
  [ "$(reason "$C")" = 'no error' ]
}

@test "rejects a BOM, a CR, a line without =, an unknown key and non-printable values, naming the file" {
  local n=$(( $(wc -l < "$FIX") + 1 ))
  { printf '\357\273\277'; cat "$FIX"; } > "$C"
  [ "$(reason "$C")" = "$C: byte order mark found (save without BOM)" ]
  awk '{ printf "%s\r\n", $0 }' "$FIX" > "$C"
  [ "$(reason "$C")" = "$C: carriage return found (use LF line endings)" ]
  { cat "$FIX"; printf 'just words\n'; } > "$C"
  [ "$(reason "$C")" = "$C: line $n: expected KEY=value" ]
  { cat "$FIX"; printf 'FROB=1\n'; } > "$C"
  [ "$(reason "$C")" = "$C: line $n: unknown key FROB" ]
  { cat "$FIX"; printf 'host=x\n'; } > "$C"
  [ "$(reason "$C")" = "$C: line $n: unknown key host" ]
  { cat "$FIX"; printf 'B@D=1\n'; } > "$C"
  [ "$(reason "$C")" = "$C: line $n: unknown key" ]
  with_line LAUNCH_CMD "$(printf 'caf\303\251')"
  [[ "$(reason "$C")" == *': non-printable or non-ASCII character in LAUNCH_CMD' ]]
  with_line LAUNCH_CMD "$(printf 'a\tb')"
  [[ "$(reason "$C")" == *': non-printable or non-ASCII character in LAUNCH_CMD' ]]
}

@test "rejects a NUL byte that read would silently drop, naming the file" {
  # Without the whole-file check, read -r drops the NUL and the line below parses as LAUNCH_CMD=claude.
  { cat "$FIX"; printf 'LAUNCH_CMD=cla\0ude\n'; } > "$C"
  [ "$(reason "$C")" = "$C: NUL byte found" ]
}

@test "a UTF-8 locale does not make the trim eat U+3000, so the value is still rejected as non-ASCII" {
  # In C.UTF-8, [[:blank:]] also matches U+3000; tk_trim pins the C locale to keep spaces and tabs only.
  local LC_ALL=C.UTF-8
  with_line LAUNCH_CMD "$(printf 'claude\343\200\200')"
  [ "$(reason "$C")" = "$C: line 15: non-printable or non-ASCII character in LAUNCH_CMD" ]
  with_line LAUNCH_CMD "$(printf '\343\200\200claude')"
  [ "$(reason "$C")" = "$C: line 15: non-printable or non-ASCII character in LAUNCH_CMD" ]
}

@test "tk_conf_read runs every helper tool in the C locale, whatever locale the caller has (M8)" {
  # Stubs for the four tools it uses log the LC_ALL they were started with, then run the real tool.
  local t real log="$BATS_TEST_TMPDIR/locales" bin="$BATS_TEST_TMPDIR/locale-bin"
  mkdir -p "$bin"
  for t in head od wc tr; do
    real=$(command -v "$t")
    printf '#!/bin/sh\nprintf "%%s\\n" "${LC_ALL-unset}" >> "%s"\nexec "%s" "$@"\n' "$log" "$real" > "$bin/$t"
    chmod +x "$bin/$t"
  done
  PATH="$bin:$PATH"
  export LC_ALL=C.UTF-8
  : > "$log"
  tk_conf_read "$FIX"
  [ -s "$log" ]
  [ "$(sort -u "$log")" = C ]
}

@test "file-level errors come first (BOM, CR, NUL), then line errors, then key-list order" {
  # BOM and CR together: the BOM reason.
  { printf '\357\273\277'; awk '{ printf "%s\r\n", $0 }' "$FIX"; } > "$C"
  [ "$(reason "$C")" = "$C: byte order mark found (save without BOM)" ]
  # CR and NUL together: the CR reason.
  printf 'HOST=203.0.113.10\r\nLAUNCH_CMD=cla\0ude\n' > "$C"
  [ "$(reason "$C")" = "$C: carriage return found (use LF line endings)" ]
  # NUL and a line without =: the NUL reason, though the bad line is read first.
  printf 'just words\nLAUNCH_CMD=cla\0ude\n' > "$C"
  [ "$(reason "$C")" = "$C: NUL byte found" ]
  # A line without = on line 2 and no HOST: the line error, not HOST: required.
  printf 'PORT=22\njust words\n' > "$C"
  [ "$(reason "$C")" = "$C: line 2: expected KEY=value" ]
  # A valid PORT and no HOST: HOST: required.
  printf 'PORT=5\n' > "$C"
  [ "$(reason "$C")" = "$C: HOST: required" ]
  # PORT=0 on line 1 and an invalid HOST on line 2: HOST comes first in the key list.
  printf 'PORT=0\nHOST=you@203.0.113.10\n' > "$C"
  [ "$(reason "$C")" = "$C: HOST: not a hostname, IPv4 or IPv6 address" ]
  # PORT=0 that a later PORT=22 overrides is accepted.
  printf 'PORT=0\nHOST=203.0.113.10\nPORT=22\n' > "$C"
  tk_conf_read "$C"
  [ "$TKC_PORT" = 22 ]
  [ "$TKC_HOST" = 203.0.113.10 ]
}

@test "the first-run prompt asks once, trims the answer and writes the fixture" {
  tk_prompt() { printf '%s\n' "$1" >> "$BATS_TEST_TMPDIR/prompts"; printf '%s' ' 203.0.113.10 '; }
  tk_conf_create "$HOME/.tmuxkeep/config"
  [ "$(cat "$BATS_TEST_TMPDIR/prompts")" = 'VPS address (hostname or IP): ' ]
  [ "$TKC_HOST" = 203.0.113.10 ]
  cmp "$HOME/.tmuxkeep/config" "$FIX"
}

@test "the first-run prompt rejects host:port, user@host and blanks, and writes nothing (Review Focus 2)" {
  local a want
  while IFS='|' read -r a want; do
    TK_ANSWER=$a
    tk_prompt() { printf '%s' "$TK_ANSWER"; }
    rm -rf "$HOME/.tmuxkeep"
    if tk_conf_create "$HOME/.tmuxkeep/config"; then echo "accepted '$a'"; return 1; fi
    [ "$TK_ERR" = "$HOME/.tmuxkeep/config: $want" ] || { echo "$TK_ERR"; return 1; }
    [ ! -e "$HOME/.tmuxkeep/config" ] || { echo "wrote a config for '$a'"; return 1; }
  done <<'EOF'
203.0.113.10:2222|HOST: looks like host:port; put the port in PORT
you@203.0.113.10|HOST: not a hostname, IPv4 or IPv6 address
|HOST: required
   |HOST: required
EOF
}

@test "the first-run prompt rejects a non-ASCII host in a UTF-8 locale too, and writes nothing" {
  # tk_conf_validate pins the C locale, so no locale-dependent range can let an accented letter pass.
  local LC_ALL=C.UTF-8
  tk_prompt() { printf '%s' "caf$(printf '\303\251')"; }
  if tk_conf_create "$HOME/.tmuxkeep/config"; then echo 'accepted a non-ASCII host'; return 1; fi
  [ "$TK_ERR" = "$HOME/.tmuxkeep/config: HOST: not a hostname, IPv4 or IPv6 address" ]
  [ ! -e "$HOME/.tmuxkeep/config" ]
}

@test "tk_deploy_conf_text on the defaults is the deploy.conf fixture, and carries the configured values" {
  tk_conf_defaults
  TKC_HOST=203.0.113.10
  tk_deploy_conf_text > "$C"
  cmp "$C" "$REPO/tests/fixtures/deploy.conf"
  TKC_USER=bob
  TKC_LAUNCH_CMD=''
  TKC_LEASE_SECS=600
  run tk_deploy_conf_text
  printf '%s\n' "$output" | grep -qx 'USER=bob'
  printf '%s\n' "$output" | grep -qx 'LAUNCH_CMD='
  printf '%s\n' "$output" | grep -qx 'LEASE_SECS=600'
  [ "$(printf '%s\n' "$output" | grep -cE 'HOST|PORT|KEY=')" = 0 ]
}

@test "tk_expand_path expands only a leading tilde" {
  [ "$(tk_expand_path '~/.ssh/k')" = "$HOME/.ssh/k" ]
  [ "$(tk_expand_path '~')" = "$HOME" ]
  [ "$(tk_expand_path /keys/k)" = /keys/k ]
  [ "$(tk_expand_path 'a~/k')" = 'a~/k' ]
}

@test "the key list is one line" {
  grep -qx 'TK_CONF_KEYS="HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES"' "$REPO/laptop/deploy.sh"
}
