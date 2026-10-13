#!/usr/bin/env bats
# tmux layer, name rules, exact targeting for ls, peek and lock.
load helpers
setup() { setup_local; }
teardown() { teardown_local; }

@test "humanise boundaries" {
  source "$TMUXKEEP_BIN"
  [ "$(humanise 0)" = 0s ]
  [ "$(humanise 59)" = 59s ]
  [ "$(humanise 60)" = 1m ]
  [ "$(humanise 3599)" = 59m ]
  [ "$(humanise 3600)" = 1h ]
  [ "$(humanise 86399)" = 23h ]
  [ "$(humanise 86400)" = 1d ]
  [ "$(humanise 200000)" = 2d ]
  [ "$(humanise -5)" = 0s ]
}

@test "ls with no tmux server: empty lists, header-only table, exit 0" {
  run tmuxkeep ls --names
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tmuxkeep ls --tombstones
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tmuxkeep ls
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" =~ ^NAME\ +STATE\ +ATTACHED\ +AGE\ +IDLE\ +TITLE$ ]]
}

@test "ls --names lists live and locked sessions, not tombstones" {
  mk_session api
  mk_session web
  mk_session 'zz~old~1789990000'
  tm set-option -t '=web:' @tmuxkeep_locked 1
  run tmuxkeep ls --names
  [ "$status" -eq 0 ]
  [ "$output" = $'api\nweb' ]
}

@test "ls --tombstones lists each base name once, sorted" {
  mk_session 'zz~old~1789990000'
  mk_session 'zz~old~1789990500'
  mk_session 'zz~gone~1'
  mk_session live
  run tmuxkeep ls --tombstones
  [ "$output" = $'gone\nold' ]
}

@test "ls --names and --tombstones are not audited; plain ls is" {
  mk_session api
  tmuxkeep ls --names
  tmuxkeep ls --tombstones
  [ "$(audit_count)" -eq 0 ]
  tmuxkeep ls
  [ "$(audit_count)" -eq 1 ]
  [ "$(audit_field verb)" = ls ]
}

@test "ls rejects unknown or combined flags (2)" {
  run tmuxkeep ls --bogus
  [ "$status" -eq 2 ]
  run tmuxkeep ls --names --tombstones
  [ "$status" -eq 2 ]
}

@test "ls table: state, humanised age and idle, title" {
  # +30s of slack so a second boundary between here and session creation cannot yield 1h.
  export TMUXKEEP_NOW=$(( $(date +%s) + 7230 ))
  mk_session api
  mk_session web
  mk_session 'zz~old~1'
  tm set-option -t '=web:' @tmuxkeep_locked 1
  tm select-pane -t '=api:' -T 'Refactoring the parser'
  run tmuxkeep ls
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^NAME\ +STATE\ +ATTACHED\ +AGE\ +IDLE\ +TITLE$ ]]
  local api web old
  api=$(printf '%s\n' "${lines[@]}" | grep '^api ')
  web=$(printf '%s\n' "${lines[@]}" | grep '^web ')
  old=$(printf '%s\n' "${lines[@]}" | grep '^zz~old~1 ')
  [[ "$api" =~ ^api\ +live\ +2h\ +2h\ +Refactoring\ the\ parser$ ]]
  [[ "$web" =~ ^web\ +locked\  ]]
  [[ "$old" =~ ^zz~old~1\ +tombstone\  ]]
}

@test "ls truncates titles to 40 columns and strips control characters (Review Focus 1)" {
  mk_session api
  tm select-pane -t '=api:' -T "$(printf 'A%.0s' $(seq 1 50))"
  run tmuxkeep ls
  local row
  row=$(printf '%s\n' "${lines[@]}" | grep '^api ')
  [[ "$row" == *" $(printf 'A%.0s' $(seq 1 40))" ]]
  [[ "$row" != *"$(printf 'A%.0s' $(seq 1 41))"* ]]
  tm select-pane -t '=api:' -T $'evil\e]0;pwned\atitle'
  run tmuxkeep ls
  [[ "$output" != *$'\e'* ]]
  [[ "$output" != *$'\a'* ]]
}

@test "peek prints the last N non-blank lines" {
  mk_session_cmd api 'printf "l%s\n" 1 2 3 4 5; exec sleep 300'
  wait_for_pane_line api l5
  run tmuxkeep peek api -n 2
  [ "$status" -eq 0 ]
  [ "$output" = $'l4\nl5' ]
  run tmuxkeep peek api
  [ "$output" = $'l1\nl2\nl3\nl4\nl5' ]
  [ "$(audit_field detail)" = lines=40 ]
}

@test "peek -n validation" {
  mk_session api
  run tmuxkeep peek api -n abc
  [ "$status" -eq 2 ]
  run tmuxkeep peek api -n 12345
  [ "$status" -eq 2 ]
  run tmuxkeep peek api -n 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "peek accepts a tombstone name" {
  mk_session_cmd 'zz~api~1789990000' 'echo tomb; exec sleep 300'
  wait_for_pane_line 'zz~api~1789990000' tomb
  run tmuxkeep peek 'zz~api~1789990000'
  [ "$status" -eq 0 ]
  [ "$output" = tomb ]
}

@test "peek on a missing session is not found (5); a prefix is not a match" {
  mk_session api2
  run tmuxkeep peek api
  [ "$status" -eq 5 ]
}

@test "lock sets @tmuxkeep_locked on exactly that session, without a lease" {
  mk_session api
  mk_session api2
  run tmuxkeep lock api
  [ "$status" -eq 0 ]
  [ "$output" = "locked api" ]
  [ "$(locked_flag api)" = 1 ]
  [ -z "$(locked_flag api2)" ]
}

@test "lock rejects tombstone names (2) and missing sessions (5)" {
  mk_session 'zz~api~1'
  mk_session api2
  run tmuxkeep lock 'zz~api~1'
  [ "$status" -eq 2 ]
  run tmuxkeep lock api
  [ "$status" -eq 5 ]
  [ -z "$(locked_flag api2)" ]
}

@test "name rules: digit start, uppercase, punctuation, too long, dash start are usage (2)" {
  local n
  for n in 1kb Api a.b a:b 'a b' -x "$(printf 'a%.0s' $(seq 1 33))"; do
    run tmuxkeep lock "$n"
    [ "$status" -eq 2 ] || { echo "name '$n' gave $status"; return 1; }
  done
  run tmuxkeep lock "$(printf 'a%.0s' $(seq 1 32))"
  [ "$status" -eq 5 ]
}

@test "a session named bash is targeted, not a window named bash in another session" {
  mk_session other
  tm rename-window -t '=other:' bash
  mk_session bash
  run tmuxkeep lock bash
  [ "$status" -eq 0 ]
  [ "$(locked_flag bash)" = 1 ]
  [ -z "$(locked_flag other)" ]
}

# ---- fix round 1 ----

@test "clean_title removes C0, DEL and UTF-8 C1 controls and keeps printable text" {
  export LC_ALL=C.UTF-8   # main exports this; sourcing the broker skips main
  source "$TMUXKEEP_BIN"
  [ "$(clean_title $'a\eb')" = ab ]
  [ "$(clean_title $'a\x7fb')" = ab ]
  [ "$(clean_title $'a\xc2\x9bb')" = ab ]
  [ "$(clean_title 'plain title')" = 'plain title' ]
}

@test "ls usage errors are audited even with --names or --tombstones" {
  run tmuxkeep ls --names extra
  [ "$status" -eq 2 ]
  [ "$(audit_count)" -eq 1 ]
  [ "$(audit_field verb)" = ls ]
  [ "$(audit_field ok)" = false ]
  run tmuxkeep ls --names --tombstones
  [ "$status" -eq 2 ]
  [ "$(audit_count)" -eq 2 ]
  [ "$(audit_field ok)" = false ]
}

@test "ls --names omits names no verb can use; a | in a session name does not shift the table fields" {
  export TMUXKEEP_NOW=$(( $(date +%s) + 7230 ))
  mk_session api
  mk_session Bad
  mk_session 'a|b'
  run tmuxkeep ls --names
  [ "$status" -eq 0 ]
  [ "$output" = api ]
  run tmuxkeep ls
  [ "$status" -eq 0 ]
  local row
  row=$(printf '%s\n' "${lines[@]}" | grep '^a|b ')
  [[ "$row" =~ ^a\|b\ +live\ +2h\ +2h ]]
}

@test "peek -n 0 prints nothing and succeeds every time (no SIGPIPE flake)" {
  mk_session_cmd api 'seq 1 3000; exec sleep 300'
  wait_for_pane_line api 3000
  local i
  for i in $(seq 1 30); do
    run tmuxkeep peek api -n 0
    [ "$status" -eq 0 ] || { echo "run $i gave $status"; return 1; }
    [ -z "$output" ]
  done
  [ "$(audit_field detail)" = lines=0 ]
  run tmuxkeep peek api -n 00
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run tmuxkeep peek api -n 0003
  [ "$status" -eq 0 ]
  [ "$output" = $'2998\n2999\n3000' ]
}

@test "session_locked fails closed on a tmux error (1) or a vanished session (5), never reads as unlocked" {
  mk_session api
  # tmux error: no server listening on this socket
  run bash -c 'source "$1"; TMUX_SOCK=$2/none.sock TMUX_CONF=/nonexistent AUDIT_ENABLED=0 VERB=t; session_locked api; echo reached' _ "$TMUXKEEP_BIN" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tmuxkeep: tmux:"* ]]
  [[ "$output" != *reached* ]]
  # live server, no such session: display-message itself exits 0 with empty fields
  run bash -c 'source "$1"; TMUX_SOCK=$2 TMUX_CONF=/nonexistent AUDIT_ENABLED=0 VERB=t; session_locked ap; echo reached' _ "$TMUXKEEP_BIN" "$TMUXKEEP_TMUX_SOCKET"
  [ "$status" -eq 5 ]
  [[ "$output" == *"no such session: ap"* ]]
  [[ "$output" != *reached* ]]
  run bash -c 'source "$1"; TMUX_SOCK=$2 TMUX_CONF=/nonexistent AUDIT_ENABLED=0 VERB=t; if session_locked api; then echo locked; else echo unlocked; fi' _ "$TMUXKEEP_BIN" "$TMUXKEEP_TMUX_SOCKET"
  [ "$output" = unlocked ]
  tm set-option -t '=api:' @tmuxkeep_locked 1
  run bash -c 'source "$1"; TMUX_SOCK=$2 TMUX_CONF=/nonexistent AUDIT_ENABLED=0 VERB=t; if session_locked api; then echo locked; else echo unlocked; fi' _ "$TMUXKEEP_BIN" "$TMUXKEEP_TMUX_SOCKET"
  [ "$output" = locked ]
}
