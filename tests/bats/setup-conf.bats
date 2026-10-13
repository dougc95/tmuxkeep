#!/usr/bin/env bats
# vps/tmuxkeep-setup, spec 4.3 and 7.2: --conf parsing, the configurable user, the account guards
# (Review Focus 1 and 5), the Claude Code opt-in and the next-steps text. The file is sourced;
# main runs only with arguments that make it exit 2 before any step.
load helpers

FIX=/src/tests/fixtures/deploy.conf

setup() {
  source /src/vps/tmuxkeep-setup
  C="$BATS_TEST_TMPDIR/deploy.conf"
}
teardown() {
  rm -f /etc/tmuxkeep/tmuxkeep.conf
}

fresh() { cp "$FIX" "$C"; }

# rejects FILE SUFFIX: read_deploy_conf fails and CONF_ERR is "FILE: ...SUFFIX".
rejects() {
  conf_defaults
  if read_deploy_conf "$1"; then echo "accepted, wanted: $2"; return 1; fi
  [[ "$CONF_ERR" == "$1: "*"$2" ]] || { echo "CONF_ERR: $CONF_ERR"; echo "wanted suffix: $2"; return 1; }
}

# rejects_exactly FILE REASON: read_deploy_conf fails and CONF_ERR is exactly "FILE: REASON".
rejects_exactly() {
  conf_defaults
  if read_deploy_conf "$1"; then echo "accepted, wanted: $2"; return 1; fi
  [[ "$CONF_ERR" == "$1: $2" ]] || { echo "CONF_ERR: $CONF_ERR"; echo "wanted: $1: $2"; return 1; }
}

@test "sourcing defines the new functions and runs nothing" {
  declare -F conf_defaults read_deploy_conf validate_deploy_conf account_ok user_unchanged home_of \
    check_user_sshd step_claude_code install_claude_code report_root_claude print_next_steps >/dev/null
  [ "$TK_USER" = claude ]
  [ -z "$TK_HOME" ]
}

@test "read_deploy_conf accepts the fixture and sets every CONF_* value" {
  conf_defaults
  CONF_USER=x
  CONF_LEASE_SECS=1
  read_deploy_conf "$FIX"
  [ "$CONF_USER" = claude ]
  [ "$CONF_LAUNCH_CMD" = claude ]
  [ "$CONF_RESUME_CMD" = 'claude --continue' ]
  [ "$CONF_INSTALL_CLAUDE_CODE" = no ]
  [ "$CONF_LEASE_SECS" = 1800 ]
  [ "$CONF_TOMBSTONE_TTL" = 86400 ]
  [ "$CONF_OTP_FAIL_MAX" = 3 ]
  [ "$CONF_OTP_FAIL_WINDOW" = 600 ]
  [ "$CONF_OTP_COOLDOWN" = 300 ]
  [ "$CONF_OTP_HARD_MAX" = 10 ]
  [ "$CONF_OTP_READ_TIMEOUT" = 60 ]
  [ "$CONF_SEND_MAX_BYTES" = 8000 ]
}

@test "an unknown key, a bad USER, a bad yes/no and out-of-range values are rejected with the key named" {
  local n=$(( $(wc -l < "$FIX") + 1 )) v
  { cat "$FIX"; printf 'HOST=203.0.113.10\n'; } > "$C"
  rejects "$C" "line $n: unknown key HOST"
  for v in Bob 1abc '' 'a b' "$(printf 'a%.0s' $(seq 1 33))"; do
    fresh; conf_set_in "$C" USER "$v"
    rejects "$C" 'USER: must match ^[a-z_][a-z0-9_-]{0,31}$' || { echo "USER=$v"; return 1; }
  done
  for v in yes no; do
    fresh; conf_set_in "$C" INSTALL_CLAUDE_CODE "$v"; conf_defaults; read_deploy_conf "$C"
  done
  for v in Yes YES true 1 ''; do
    fresh; conf_set_in "$C" INSTALL_CLAUDE_CODE "$v"
    rejects "$C" 'INSTALL_CLAUDE_CODE: must be yes or no' || { echo "INSTALL_CLAUDE_CODE=$v"; return 1; }
  done
  fresh; conf_set_in "$C" LEASE_SECS 59
  rejects "$C" 'LEASE_SECS: must be an integer from 60 to 86400'
  fresh; conf_set_in "$C" OTP_HARD_MAX 2
  rejects "$C" 'OTP_HARD_MAX: must be an integer from 3 to 100'
  fresh; conf_set_in "$C" LAUNCH_CMD "$(printf 'x%.0s' $(seq 1 201))"
  rejects "$C" 'LAUNCH_CMD: at most 200 characters'
}

@test "a missing key, a CR, a BOM and a non-ASCII value are rejected" {
  local k
  for k in USER LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX \
           OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES; do
    grep -v "^$k=" "$FIX" > "$C"
    rejects "$C" "$k: required" || return 1
  done
  sed 's/$/\r/' "$FIX" > "$C"
  rejects "$C" 'carriage return found (use LF line endings)'
  { printf '\xef\xbb\xbf'; cat "$FIX"; } > "$C"
  rejects "$C" 'byte order mark found (save without BOM)'
  fresh; conf_set_in "$C" RESUME_CMD "$(printf 'caf\xc3\xa9')"
  rejects "$C" 'non-printable or non-ASCII character in RESUME_CMD'
}

@test "a NUL byte anywhere in the file is rejected" {
  { grep -v '^LAUNCH_CMD=' "$FIX"; printf 'LAUNCH_CMD=cla\0ude\n'; } > "$C"
  rejects_exactly "$C" 'NUL byte found'
  { printf '\0'; cat "$FIX"; } > "$C"
  rejects_exactly "$C" 'NUL byte found'
}

@test "error precedence: file checks, then lines, then required keys, then validation in list order" {
  # BOM before CR, CR before NUL, NUL before the line checks.
  { printf '\xef\xbb\xbf'; sed 's/$/\r/' "$FIX"; } > "$C"
  rejects_exactly "$C" 'byte order mark found (save without BOM)'
  { sed 's/$/\r/' "$FIX"; printf '\0'; } > "$C"
  rejects_exactly "$C" 'carriage return found (use LF line endings)'
  { cat "$FIX"; printf 'just words\n'; printf '\0'; } > "$C"
  rejects_exactly "$C" 'NUL byte found'
  # A bad line beats a missing key (USER is the one that goes missing here), and the first bad
  # line is the one reported.
  { sed -n 1p "$FIX"; printf 'FROB=1\n'; sed -n '3,$p' "$FIX"; } > "$C"
  rejects_exactly "$C" 'line 2: unknown key FROB'
  { sed -n 1p "$FIX"; printf 'FROB=1\njust words\n'; sed -n '3,$p' "$FIX"; } > "$C"
  rejects_exactly "$C" 'line 2: unknown key FROB'
  # A missing key beats an invalid value.
  { grep -v '^SEND_MAX_BYTES=' "$FIX"; printf 'USER=Bob\n'; } > "$C"
  rejects_exactly "$C" 'SEND_MAX_BYTES: required'
  # Values are validated in key-list order, not in file order.
  { cat "$FIX"; printf 'LEASE_SECS=5\nUSER=Bob\n'; } > "$C"
  rejects_exactly "$C" 'USER: must match ^[a-z_][a-z0-9_-]{0,31}$'
  # Validation sees the last of a repeated key.
  { cat "$FIX"; printf 'LEASE_SECS=5\nLEASE_SECS=60\n'; } > "$C"
  conf_defaults
  read_deploy_conf "$C"
  [ "$CONF_LEASE_SECS" = 60 ]
  { cat "$FIX"; printf 'LEASE_SECS=60\nLEASE_SECS=5\n'; } > "$C"
  rejects_exactly "$C" 'LEASE_SECS: must be an integer from 60 to 86400'
}

@test "main: an invalid or unreadable --conf is exit 2 before any step, with the key named" {
  { cat "$FIX"; printf 'LEASE_SECS=5\n'; } > "$C"
  run --separate-stderr bash /src/vps/tmuxkeep-setup --pubkey-file /nonexistent --conf "$C"
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep-setup: deploy.conf invalid: $C: LEASE_SECS: must be an integer from 60 to 86400" ]
  run --separate-stderr bash /src/vps/tmuxkeep-setup --pubkey-file /nonexistent --conf "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep-setup: deploy.conf invalid: $BATS_TEST_TMPDIR/none: cannot read" ]
}

@test "main: --conf without a value, or with an option as its value, is usage (2)" {
  run bash /src/vps/tmuxkeep-setup --pubkey-file /x --conf
  [ "$status" -eq 2 ]
  run bash /src/vps/tmuxkeep-setup --pubkey-file /x --conf --harden-root
  [ "$status" -eq 2 ]
  [[ "$output" == *'[--conf <file>]'* ]]
}

@test "account_ok refuses a system account (Review Focus 1) and accepts a regular or absent one" {
  local u
  for u in root daemon nobody; do
    run account_ok "$u"
    [ "$status" -ne 0 ] || { echo "accepted $u"; return 1; }
    [[ "$output" == "tmuxkeep-setup: refusing USER=$u: uid "*" is a system account; choose a dedicated user name" ]] || { echo "$output"; return 1; }
  done
  run account_ok claude
  [ "$status" -eq 0 ]
  run account_ok tk-no-such-user
  [ "$status" -eq 0 ]
}

@test "user_unchanged refuses a USER change against the installed tmuxkeep.conf (Review Focus 5)" {
  run user_unchanged /etc/tmuxkeep/tmuxkeep.conf bob
  [ "$status" -eq 0 ]
  cp /src/tests/fixtures/tmuxkeep.conf /etc/tmuxkeep/tmuxkeep.conf
  run user_unchanged /etc/tmuxkeep/tmuxkeep.conf claude
  [ "$status" -eq 0 ]
  run user_unchanged /etc/tmuxkeep/tmuxkeep.conf bob
  [ "$status" -ne 0 ]
  [ "$output" = 'tmuxkeep-setup: USER changed from claude to bob since the last deploy; see README "Changing the VPS user"' ]
}

@test "home_of reads the home from getent and refuses one the broker would reject" {
  run home_of claude
  [ "$status" -eq 0 ]
  [ "$output" = /home/claude ]
  run home_of tk-no-such-user
  [ "$status" -ne 0 ]
  useradd -M -d '/srv/a b' tk-bad-home
  run home_of tk-bad-home
  userdel tk-bad-home
  [ "$status" -ne 0 ]
  [[ "$output" == *'not a plain absolute path: /srv/a b'* ]]
}

@test "allowusers_ok and user_systemctl use TK_USER" {
  TK_USER=bob
  run allowusers_ok 'allowusers root bob'
  [ "$status" -eq 0 ]
  run allowusers_ok 'allowusers root claude'
  [ "$status" -ne 0 ]
  [[ "$output" == *'does not admit bob'* ]]
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "$*"\n' > "$BATS_TEST_TMPDIR/bin/runuser"
  chmod +x "$BATS_TEST_TMPDIR/bin/runuser"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run user_systemctl 1001 daemon-reload
  [ "$output" = '-u bob -- env XDG_RUNTIME_DIR=/run/user/1001 systemctl --user daemon-reload' ]
}

@test "step_claude_code installs only when INSTALL_CLAUDE_CODE=yes" {
  install_claude_code() { echo INSTALL-CALLED; }
  CONF_INSTALL_CLAUDE_CODE=no
  run step_claude_code
  [ "$status" -eq 0 ]
  [ "$output" = 'Claude Code: not installed (INSTALL_CLAUDE_CODE=no)' ]
  CONF_INSTALL_CLAUDE_CODE=yes
  run step_claude_code
  [ "$output" = INSTALL-CALLED ]
}

@test "report_root_claude names the PIDs and the work directory, and is silent when there are none" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nprintf "123\\n456\\n"\n' > "$BATS_TEST_TMPDIR/bin/pgrep"
  chmod +x "$BATS_TEST_TMPDIR/bin/pgrep"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  TK_HOME=/home/bob
  run report_root_claude
  [ "$output" = 'WARNING: claude is running as root (PIDs: 123 456); stop it and move its work to /home/bob/work' ]
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/pgrep"
  run report_root_claude
  [ -z "$output" ]
}

@test "main runs the Claude Code install and the root warning only through the opt-in functions" {
  local body="$BATS_TEST_TMPDIR/main.body"
  sed -n '/^main() {/,/^}/p' /src/vps/tmuxkeep-setup > "$body"
  grep -qx '  step_claude_code || exit 1' "$body"
  grep -qxF '  if [[ $CONF_INSTALL_CLAUDE_CODE == yes ]]; then report_root_claude; fi' "$body"
  run grep -c 'install.sh' "$body"
  [ "$output" = 0 ]
  run grep -c 'pgrep -u' "$body"
  [ "$output" = 0 ]
}

@test "print_next_steps names the work directory, with and without Claude Code" {
  run print_next_steps /home/bob/work yes
  [ "$output" = "$(printf '%s\n' \
    'First run:' \
    '  1. Scan the QR code into an authenticator app.' \
    '  2. On the laptop: tmuxkeep new scratch, then tmuxkeep go scratch, complete the Claude Code login inside it, detach with Ctrl-b d.' \
    '  3. Move any existing projects from /root to /home/bob/work/ and stop any root tmux sessions (README section "Migrating work from root").' \
    '  4. Once tmuxkeep-admin logs in with the admin key, run deploy again with --harden-root (-HardenRoot on Windows).')" ]
  run print_next_steps /home/bob/work no
  [ "${lines[2]}" = '  2. On the laptop: tmuxkeep new scratch, then tmuxkeep go scratch to check the session, detach with Ctrl-b d.' ]
  [ "${lines[3]}" = '  3. Move any existing projects from /root to /home/bob/work/ and stop any root tmux sessions (README section "Migrating work from root").' ]
}

@test "no literal claude account remains in the installer" {
  run grep -nE 'CLAUDE_USER|CLAUDE_HOME|/home/claude' /src/vps/tmuxkeep-setup
  [ "$status" -eq 1 ]
}

# ---- task 6: Task 5 review follow-ups ----

@test "user_unchanged fails closed when the installed file exists but names no USER" {
  local f="$BATS_TEST_TMPDIR/installed.conf" want
  want="tmuxkeep-setup: $f exists but names no USER; see README \"Changing the VPS user\""
  printf 'LEASE_SECS=1800\n' > "$f"
  run --separate-stderr user_unchanged "$f" claude
  [ "$status" -eq 1 ]
  [ "$stderr" = "$want" ]
  : > "$f"
  run --separate-stderr user_unchanged "$f" claude
  [ "$status" -eq 1 ]
  [ "$stderr" = "$want" ]
  printf 'USER=\nUSER_HOME=/home/claude\n' > "$f"
  run --separate-stderr user_unchanged "$f" claude
  [ "$status" -eq 1 ]
  [ "$stderr" = "$want" ]
  printf 'USER=   \n' > "$f"
  run --separate-stderr user_unchanged "$f" claude
  [ "$status" -eq 1 ]
  [ "$stderr" = "$want" ]
  run user_unchanged "$BATS_TEST_TMPDIR/none.conf" claude
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "audit_owner_ok refuses an audit log owned by someone other than USER" {
  declare -F audit_owner_ok >/dev/null
  AUDIT_DIR=$BATS_TEST_TMPDIR
  run audit_owner_ok bob
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  : > "$BATS_TEST_TMPDIR/audit.log"
  run --separate-stderr audit_owner_ok bob
  [ "$status" -eq 1 ]
  [ "$stderr" = "tmuxkeep-setup: $BATS_TEST_TMPDIR/audit.log is owned by root, not bob; see README \"Changing the VPS user\"" ]
  run audit_owner_ok root
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "main: --conf with an empty value is usage (2), like an empty --pubkey-file" {
  run --separate-stderr bash /src/vps/tmuxkeep-setup --pubkey-file /x --conf ''
  [ "$status" -eq 2 ]
  [[ "$stderr" == 'tmuxkeep-setup: usage: tmuxkeep-setup --pubkey-file <path>'*'[--conf <file>]'* ]]
  run bash /src/vps/tmuxkeep-setup --conf '' --pubkey-file /x
  [ "$status" -eq 2 ]
  run --separate-stderr bash /src/vps/tmuxkeep-setup --pubkey-file '' --conf "$FIX"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *'usage: tmuxkeep-setup'* ]]
}

@test "main runs the account, USER and audit-owner guards after the root check and before any system probe" {
  local body="$BATS_TEST_TMPDIR/main.body" root acct unch aud allow chat
  sed -n '/^main() {/,/^}/p' /src/vps/tmuxkeep-setup > "$body"
  root=$(grep -n 'if (( EUID != 0 )); then die "must run as root"; fi' "$body" | cut -d: -f1)
  acct=$(grep -n 'account_ok "$TK_USER" || exit 1' "$body" | cut -d: -f1)
  unch=$(grep -n 'user_unchanged "$VPS_CONF" "$TK_USER" || exit 1' "$body" | cut -d: -f1)
  aud=$(grep -n 'audit_owner_ok "$TK_USER" || exit 1' "$body" | cut -d: -f1)
  allow=$(grep -n 'allowusers_ok "$sshd_all" || exit 1' "$body" | cut -d: -f1)
  chat=$(grep -n 'chattr_probe || exit 1' "$body" | cut -d: -f1)
  [ "$root" -lt "$acct" ]
  [ "$acct" -lt "$unch" ]
  [ "$unch" -lt "$aud" ]
  [ "$aud" -lt "$allow" ]
  [ "$aud" -lt "$chat" ]
}
