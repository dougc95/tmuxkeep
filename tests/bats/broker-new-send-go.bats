#!/usr/bin/env bats
# new, send and go (spec 6). A valid lease exists unless a test removes it.
load helpers
setup() { setup_local; mk_lease t -; }
teardown() { teardown_local; }

no_lease() { rm -f "$TMUXKEEP_HOME"/leases/*; }

# ---- new ----
@test "new creates the session in the work dir and starts claude" {
  run tmuxkeep new api
  [ "$status" -eq 0 ]
  [ "$output" = "created api in $TMUXKEEP_WORK/api" ]
  [ -d "$TMUXKEEP_WORK/api" ]
  [ "$(tm display-message -p -t '=api:' '#{session_path}')" = "$TMUXKEEP_WORK/api" ]
  wait_for_pane_contains api claude
  [ "$(audit_field verb)" = new ]
  [ "$(audit_field session)" = api ]
  [ "$(audit_field detail)" = "created dir=$TMUXKEEP_WORK/api" ]
}

@test "new refuses a live duplicate (3)" {
  mk_session api
  run tmuxkeep new api
  [ "$status" -eq 3 ]
}

@test "new refuses while a tombstone of that name exists (3)" {
  mk_session 'zz~api~1789990000'
  run --separate-stderr tmuxkeep new api
  [ "$status" -eq 3 ]
  [[ "$stderr" == *restore* ]]
}

@test "new refuses a directory another session already uses (3)" {
  mkdir -p "$TMUXKEEP_WORK/api"
  mk_session web "$TMUXKEEP_WORK/api"
  run --separate-stderr tmuxkeep new api
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"in use"* ]]
  [ "$(session_names)" = web ]
}

@test "new validates the name (2) and creates nothing" {
  local n
  for n in 1kb Api 'zz~api~1' "$(printf 'a%.0s' $(seq 1 33))"; do
    run tmuxkeep new "$n"
    [ "$status" -eq 2 ] || { echo "name '$n' gave $status"; return 1; }
  done
  [ -z "$(session_names)" ]
}

@test "new without a lease and without a TTY is 4 and creates nothing" {
  no_lease
  run tmuxkeep new api
  [ "$status" -eq 4 ]
  [ ! -e "$TMUXKEEP_WORK/api" ]
  [ -z "$(session_names)" ]
}

@test "--repo must be an https:// URL with a value (2)" {
  local u
  for u in http://example.com/x.git git@github.com:a/b.git 'https://' 'ext::sh -c x' 'file:///etc'; do
    run tmuxkeep new api --repo "$u"
    [ "$status" -eq 2 ] || { echo "url '$u' gave $status"; return 1; }
  done
  run tmuxkeep new api --repo
  [ "$status" -eq 2 ]
  [ -z "$(session_names)" ]
}

@test "--repo with an existing directory skips the clone; option order is free" {
  mkdir -p "$TMUXKEEP_WORK/api"
  run tmuxkeep new api --repo https://127.0.0.1:9/x.git
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping clone"* ]]
  [[ "$output" == *"created api in $TMUXKEEP_WORK/api"* ]]
  mkdir -p "$TMUXKEEP_WORK/web"
  run tmuxkeep new --repo https://127.0.0.1:9/x.git web
  [ "$status" -eq 0 ]
}

@test "--repo credentials never reach the audit log" {
  mkdir -p "$TMUXKEEP_WORK/api"
  run tmuxkeep new api --repo https://user:s3cret@127.0.0.1:9/x.git
  [ "$status" -eq 0 ]
  run grep -c s3cret "$TMUXKEEP_AUDIT"
  [ "$output" = 0 ]
  [[ "$(audit_field detail)" == *'repo=https://***@127.0.0.1:9/x.git'* ]]
}

@test "a failed clone is exit 1 with one redacted stderr line and no session" {
  run --separate-stderr tmuxkeep new api --repo https://user:s3cret@127.0.0.1:9/nope.git
  [ "$status" -eq 1 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *"git clone failed"* ]]
  [[ "$stderr" != *s3cret* ]]
  [ -z "$(session_names)" ]
  [ "$(audit_field ok)" = false ]
}

@test "SSH variables do not leak into the tmux server; LANG is C.UTF-8" {
  SSH_CLIENT='198.51.100.7 1 22' SSH_CONNECTION='198.51.100.7 1 10.0.0.1 22' SSH_TTY=/dev/pts/9 run tmuxkeep new api
  [ "$status" -eq 0 ]
  run tm show-environment -g
  [[ "$output" != *SSH_CLIENT=* ]]
  [[ "$output" != *SSH_CONNECTION=* ]]
  [[ "$output" != *SSH_TTY=* ]]
  [ "$(tm show-environment -g LANG)" = LANG=C.UTF-8 ]
}

@test "the tmux server does not inherit the gate lock" {
  run tmuxkeep new api
  [ "$status" -eq 0 ]
  run flock -n "$TMUXKEEP_HOME/gate.lock" true
  [ "$status" -eq 0 ]
}

@test "after the server dies leaving a stale socket, ls is empty and new works (Review Focus 4)" {
  mk_session old
  kill -9 "$(tm display-message -p '#{pid}')"
  sleep 0.3
  [ -S "$TMUXKEEP_TMUX_SOCKET" ]
  run tmuxkeep ls --names
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tmuxkeep new api
  [ "$status" -eq 0 ]
  [ "$(session_names)" = api ]
}

# ---- send ----
@test "send types the text and presses Enter" {
  mk_session api
  run tmuxkeep send api echo hello-tmuxkeep
  [ "$status" -eq 0 ]
  [ "$output" = "sent 19 bytes to api" ]
  wait_for_pane_line api hello-tmuxkeep
}

@test "send passes shell metacharacters through unchanged" {
  mk_session api
  run tmuxkeep $(b64cmd send api "echo 'semi;colon #hash \$HOME'")
  [ "$status" -eq 0 ]
  wait_for_pane_line api 'semi;colon #hash $HOME'
}

@test "send types tmux key names and dash words literally (Review Focus 2)" {
  mk_session api
  run tmuxkeep send api echo C-c Enter -l
  [ "$status" -eq 0 ]
  wait_for_pane_line api 'C-c Enter -l'
  run tmuxkeep send api -n
  [ "$status" -eq 0 ]
  wait_for_pane_contains api '-n: command not found'
}

@test "send rejects control characters (2)" {
  mk_session api
  local c
  for c in $'\t' $'\n' $'\r' $'\e' $'\x7f' $'\x01'; do
    run tmuxkeep b64 "$(b64 send)" "$(b64 api)" "$(b64 "a${c}b")"
    [ "$status" -eq 2 ] || { echo "char $(printf %q "$c") gave $status"; return 1; }
  done
}

@test "send enforces SEND_MAX_BYTES in bytes, not characters (Review Focus 3)" {
  mk_session_cmd api 'exec cat >/dev/null'
  local a8000 e4000
  a8000=$(printf 'a%.0s' $(seq 1 8000))
  e4000=$(printf '\xc3\xa9%.0s' $(seq 1 4000))
  run tmuxkeep b64 "$(b64 send)" "$(b64 api)" "$(b64 "$a8000")"
  [ "$status" -eq 0 ]
  [ "$(audit_field detail)" = len:8000 ]
  run tmuxkeep b64 "$(b64 send)" "$(b64 api)" "$(b64 "${a8000}a")"
  [ "$status" -eq 2 ]
  run tmuxkeep b64 "$(b64 send)" "$(b64 api)" "$(b64 "$e4000")"
  [ "$status" -eq 0 ]
  run tmuxkeep b64 "$(b64 send)" "$(b64 api)" "$(b64 "${e4000}"$'\xc3\xa9')"
  [ "$status" -eq 2 ]
}

@test "send audits the byte length, never the text" {
  mk_session api
  run tmuxkeep send api echo secret-text
  [ "$status" -eq 0 ]
  [ "$(audit_field detail)" = len:16 ]
  run grep -c secret-text "$TMUXKEEP_AUDIT"
  [ "$output" = 0 ]
}

@test "send: missing text or name (2), tombstone (2), missing session (5), no lease (4)" {
  mk_session api
  mk_session 'zz~api~1'
  run tmuxkeep send api
  [ "$status" -eq 2 ]
  run tmuxkeep send
  [ "$status" -eq 2 ]
  run tmuxkeep send 'zz~api~1' hi
  [ "$status" -eq 2 ]
  run tmuxkeep send nosuch hi
  [ "$status" -eq 5 ]
  no_lease
  run tmuxkeep send api hi
  [ "$status" -eq 4 ]
}

# ---- go ----
@test "go: a missing session is 5 even without a terminal" {
  run tmuxkeep go api
  [ "$status" -eq 5 ]
}

@test "go without a terminal is 4 once the session is found" {
  mk_session api
  run --separate-stderr tmuxkeep go api
  [ "$status" -eq 4 ]
  [[ "$stderr" == *terminal* ]]
}

@test "go rejects tombstone names (2)" {
  mk_session 'zz~api~1'
  run tmuxkeep go 'zz~api~1'
  [ "$status" -eq 2 ]
}

_only_client_other_than() {
  local c
  c=$(tm list-clients -t "=$1:" -F '#{client_tty}' 2>/dev/null)
  [ -n "$c" ] && [ "$(printf '%s\n' "$c" | wc -l)" -eq 1 ] && [ "$c" != "$2" ]
}

@test "go attaches with a terminal and detaches older clients (-d)" {
  mk_session api
  local cmd second tty1
  printf -v cmd '%q ' bash "$TMUXKEEP_BIN" --key t go api
  { sleep 8; } | script -qec "$cmd" /dev/null >/dev/null 2>&1 3>&- &
  wait_for_clients api 1
  tty1=$(tm list-clients -t '=api:' -F '#{client_tty}')
  { sleep 8; } | script -qec "$cmd" /dev/null >/dev/null 2>&1 3>&- &
  second=$!
  _poll 5 _only_client_other_than api "$tty1"
  [ "$(audit_field verb)" = go ]
  [ "$(audit_field detail)" = attached ]
  tm detach-client -s '=api:'
  wait "$second"
}

@test "ls shows * for an attached session" {
  mk_session api
  mk_session web
  local cmd attached
  printf -v cmd '%q ' bash "$TMUXKEEP_BIN" --key t go api
  { sleep 8; } | script -qec "$cmd" /dev/null >/dev/null 2>&1 3>&- &
  attached=$!
  wait_for_clients api 1
  run tmuxkeep ls
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^api +live +\* ' || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qE '^web +live +[0-9]' || { echo "$output"; return 1; }
  tm detach-client -s '=api:'
  wait "$attached"
}

# tmux ends a command at an argument that ends in ";", so send escapes a final ";".
@test "send delivers text ending in a semicolon intact" {
  mk_session api
  run tmuxkeep $(b64cmd send api 'echo trail;')
  [ "$status" -eq 0 ]
  [ "$output" = "sent 11 bytes to api" ]
  wait_for_pane_contains api 'echo trail;'
  run tmuxkeep $(b64cmd send api 'echo done\;')
  [ "$status" -eq 0 ]
  wait_for_pane_contains api 'echo done\;'
  wait_for_pane_line api 'done;'
  run tmuxkeep $(b64cmd send api ';')
  [ "$status" -eq 0 ]
  [ "$output" = "sent 1 bytes to api" ]
  wait_for_pane_contains api 'unexpected token'
}

# ---- sessions get a normal environment, not the broker's umask 077 and LC_ALL ----
_probe_ready() { [ -s "$BATS_TEST_TMPDIR/um" ] && [ -s "$BATS_TEST_TMPDIR/lc" ]; }

# Types a probe into the session's shell and waits for both answers.
_probe_session_env() {
  tm send-keys -t "=$1:" "umask > $BATS_TEST_TMPDIR/um; echo \"\${LC_ALL-unset}\" > $BATS_TEST_TMPDIR/lc" Enter
  _poll 5 _probe_ready
}

@test "new: the session shell has umask 022, 755 directories and no forced LC_ALL" {
  run tmuxkeep new api
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$TMUXKEEP_WORK/api")" = 755 ]
  _probe_session_env api
  [ "$(cat "$BATS_TEST_TMPDIR/um")" = 0022 ]
  [ "$(cat "$BATS_TEST_TMPDIR/lc")" = unset ]
}

@test "resume (recreate path): the session shell has umask 022 and no forced LC_ALL" {
  mkdir -p "$TMUXKEEP_WORK/api"
  run tmuxkeep resume api
  [ "$status" -eq 0 ]
  [ "$output" = "recreated api" ]
  _probe_session_env api
  [ "$(cat "$BATS_TEST_TMPDIR/um")" = 0022 ]
  [ "$(cat "$BATS_TEST_TMPDIR/lc")" = unset ]
}
