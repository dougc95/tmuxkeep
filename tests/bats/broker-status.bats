#!/usr/bin/env bats
# status (dashboard spec 4.1): the JSON snapshot, its bounds and its silence in the audit log.
load helpers
setup() { setup_local; }
teardown() { teardown_local; }

# status_of ARGS...: runs status and fails the test unless it printed exactly one valid JSON line.
status_of() {
  run --separate-stderr tmuxkeep status "$@"
  [ "$status" -eq 0 ] || { echo "exit $status: $stderr"; return 1; }
  [ "${#lines[@]}" -eq 1 ] || { echo "$output"; return 1; }
  jq -e . >/dev/null <<<"$output"
}

@test "status with no tmux server: one JSON line with no sessions, exit 0, no audit line, no server started" {
  status_of
  [ "$output" = "{\"version\":\"dev\",\"now\":\"$(date -u -d "@$FIXED_NOW" +%Y-%m-%dT%H:%M:%SZ)\",\"user\":\"claude\",\"lease_secs_left\":0,\"lease_secs\":1800,\"otp\":{\"locked\":false,\"fails\":0,\"cooldown_secs_left\":0},\"lines\":12,\"sessions\":[]}" ]
  [ -z "$stderr" ]
  [ "$(audit_count)" -eq 0 ]
  [ ! -e "$TMUXKEEP_TMUX_SOCKET" ]
  [ ! -e "$TMUXKEEP_HOME/gate.lock" ]
}

@test "status keys come in the spec order, for the snapshot and for each session" {
  mk_session api
  status_of
  [ "$(jq -c 'keys_unsorted' <<<"$output")" = '["version","now","user","lease_secs_left","lease_secs","otp","lines","sessions"]' ]
  [ "$(jq -c '.otp | keys_unsorted' <<<"$output")" = '["locked","fails","cooldown_secs_left"]' ]
  [ "$(jq -c '.sessions[0] | keys_unsorted' <<<"$output")" = '["name","state","tombstone_of","attached","age_secs","idle_secs","title","dir_exists","lines"]' ]
}

@test "status describes a live, a locked and a tombstone session in tmux order" {
  # +30s of slack, as in the ls table test, so a second boundary cannot change the hour.
  export TMUXKEEP_NOW=$(( $(date +%s) + 7230 ))
  mkdir -p "$TMUXKEEP_WORK/api" "$TMUXKEEP_WORK/old"
  mk_session api
  mk_session web
  mk_session 'zz~old~1789990000'
  tm set-option -t '=web:' @tmuxkeep_locked 1
  tm select-pane -t '=api:' -T 'Fix: the build: now'
  status_of
  [ "$(jq -r '[.sessions[].name] | join(" ")' <<<"$output")" = "$(session_names | tr '\n' ' ' | sed 's/ $//')" ]
  [ "$(jq -c '.sessions[] | select(.name == "api") | [.state, .tombstone_of, .attached, .title, .dir_exists]' <<<"$output")" = '["live",null,false,"Fix: the build: now",true]' ]
  [ "$(jq -c '.sessions[] | select(.name == "web") | [.state, .tombstone_of, .dir_exists]' <<<"$output")" = '["locked",null,false]' ]
  [ "$(jq -c '.sessions[] | select(.name == "zz~old~1789990000") | [.state, .tombstone_of, .dir_exists]' <<<"$output")" = '["tombstone","old",true]' ]
  jq -e '.sessions[] | select(.name == "api") | .age_secs >= 7200 and .age_secs < 7300 and .idle_secs >= 7200 and .idle_secs < 7300' <<<"$output"
  jq -e '[.sessions[].attached | type] | unique == ["boolean"]' <<<"$output"
}

@test "status lines are the pane's last N lines, trailing blank lines dropped, exactly as peek" {
  mk_session_cmd api 'printf "l%s\n" 1 2 3 4 5; exec sleep 300'
  wait_for_pane_line api l5
  status_of --lines 2
  [ "$(jq -c '[.lines, .sessions[0].lines]' <<<"$output")" = '[2,["l4","l5"]]' ]
  [ "$(jq -r '.sessions[0].lines | join(",")' <<<"$output")" = "$(tmuxkeep peek api -n 2 | paste -sd, -)" ]
  status_of
  [ "$(jq -c '.sessions[0].lines' <<<"$output")" = '["l1","l2","l3","l4","l5"]' ]
  status_of --lines 0
  [ "$(jq -c '[.lines, .sessions[0].lines]' <<<"$output")" = '[0,[]]' ]
}

@test "status --lines takes 0 to 40; anything else is a usage error, and usage errors are audited" {
  status_of --lines 40
  status_of --lines 007
  [ "$(jq .lines <<<"$output")" = 7 ]
  [ "$(audit_count)" -eq 0 ]
  local line
  local -a args
  while IFS= read -r line; do
    read -r -a args <<<"$line"
    run --separate-stderr tmuxkeep status "${args[@]}"
    [ "$status" -eq 2 ] || { echo "status $line gave $status"; return 1; }
  done <<'EOF'
--lines 41
--lines -1
--lines abc
--lines 12345
--lines
--lines 2 --lines 3
extra
--frob
EOF
  run --separate-stderr tmuxkeep status --lines 41
  [ "$stderr" = 'tmuxkeep: --lines must be 0-40' ]
  run --separate-stderr tmuxkeep status --frob
  [ "$stderr" = 'tmuxkeep: usage: tmuxkeep status [--follow] [--lines N]' ]
  [ "$(audit_count)" -eq 10 ]
  [ "$(audit_field verb)" = status ]
  [ "$(audit_field ok)" = false ]
}

@test "status reports this key id's lease and the OTP state with the gate's own arithmetic" {
  mk_lease t - $(( TMUXKEEP_NOW - 100 ))
  mk_lease other - $(( TMUXKEEP_NOW - 1 ))
  printf '%s\n' $(( TMUXKEEP_NOW - 100 )) $(( TMUXKEEP_NOW - 50 )) $(( TMUXKEEP_NOW - 10 )) junk $(( TMUXKEEP_NOW + 5 )) $(( TMUXKEEP_NOW - 9999 )) > "$TMUXKEEP_HOME/otp-fails"
  status_of
  [ "$(jq -c '[.lease_secs_left, .lease_secs, .otp]' <<<"$output")" = '[1700,1800,{"locked":false,"fails":3,"cooldown_secs_left":290}]' ]
  # The gate says the same: a cooldown of 290 seconds.
  run --separate-stderr tmuxkeep auth
  [ "$stderr" = 'tmuxkeep: cooldown, retry in 290s' ]
  : > "$TMUXKEEP_HOME/otp-locked"
  status_of
  [ "$(jq -c '.otp.locked' <<<"$output")" = true ]
  mk_lease t - $(( TMUXKEEP_NOW - 1800 ))
  status_of
  [ "$(jq '.lease_secs_left' <<<"$output")" = 0 ]
}

@test "status works with an unwritable audit log, because it writes none" {
  export TMUXKEEP_AUDIT=/nonexistent-dir/audit.log
  status_of
  [ -z "$stderr" ]
}

# Review Focus 3: whatever a program prints, the snapshot stays one valid JSON line, or the dashboard
# would drop every snapshot while that pane shows it.
@test "pane bytes that are not text, escape sequences and a 450-character line still give valid JSON, cut to 400" {
  mk_session_cmd api "printf 'bad \\377\\376 bytes\\n\\033[31mred\\033[0m\\001\\n%s\\n' \"\$(printf 'x%.0s' \$(seq 1 450))\"; exec sleep 300"
  wait_for_pane_contains api xxxxxxxxxx
  tm select-pane -t '=api:' -T "$(printf 'evil\033]0;pwned\007title')"
  status_of --lines 3
  jq -e '.sessions[0].lines | length == 3' <<<"$output"
  jq -e '.sessions[0].lines[0] | (startswith("bad") and endswith("bytes"))' <<<"$output"
  jq -e '.sessions[0].lines[2] == ("x" * 400)' <<<"$output"
  jq -e '[.sessions[0].lines[], .sessions[0].title] | all(explode | all(. >= 32 and . != 127 and (. < 128 or . > 159)))' <<<"$output"
  [ "$(LC_ALL=C tr -d '\000-\177' <<<"$output" | wc -c)" -eq 0 ]
}

@test "a session name no verb accepts and a title full of colons keep their fields" {
  export TMUXKEEP_NOW=$(( $(date +%s) + 7230 ))
  mk_session 'a|b'
  mk_session Bad
  tm select-pane -t '=a|b:' -T 'one: two: three'
  status_of
  [ "$(jq -c '.sessions[] | select(.name == "a|b") | [.state, .title]' <<<"$output")" = '["live","one: two: three"]' ]
  jq -e '.sessions[] | select(.name == "a|b") | .age_secs >= 7200' <<<"$output"
  jq -e 'any(.sessions[]; .name == "Bad")' <<<"$output"
}

@test "lease_left, otp_scan and otp_cooldown_left are the one copy of the gate arithmetic" {
  export LC_ALL=C.UTF-8
  source "$TMUXKEEP_BIN"
  NOW=1000000 LEASE_SECS=1800 OTP_FAIL_MAX=3 OTP_FAIL_WINDOW=600 OTP_COOLDOWN=300
  printf '%s\n' 999000 > "$BATS_TEST_TMPDIR/lease"
  lease_left "$BATS_TEST_TMPDIR/lease"
  [ "$LEASE_LEFT" -eq 800 ]
  printf '%s\n' 998200 > "$BATS_TEST_TMPDIR/lease"
  run lease_left "$BATS_TEST_TMPDIR/lease"
  [ "$status" -eq 1 ]
  printf '%s\n' 999700 999800 999900 1000100 > "$BATS_TEST_TMPDIR/fails"
  otp_scan "$BATS_TEST_TMPDIR/fails" 1000000
  [ "$OTP_COUNT" -eq 3 ]
  [ "$OTP_NEWEST" -eq 999900 ]
  otp_cooldown_left 1000000
  [ "$COOLDOWN_LEFT" -eq 200 ]
  otp_scan "$BATS_TEST_TMPDIR/missing" 1000000
  otp_cooldown_left 1000000
  [ "$OTP_COUNT" -eq 0 ]
  [ "$COOLDOWN_LEFT" -eq 0 ]
  [ "$(grep -c 'OTP_FAIL_WINDOW )); then continue' "$TMUXKEEP_BIN")" -eq 1 ]
  [ "$(grep -c 'age < LEASE_SECS' "$TMUXKEEP_BIN")" -eq 1 ]
}

# follow_lines N ARGS...: the first N lines of "status --follow ARGS...", read through head. The
# producer never ends on its own, so timeout bounds the whole pipeline (the CI hang lesson); exit
# 124 would mean the broker did not stop when head went away.
follow_lines() {
  local n=$1
  shift
  timeout 30 bash -c 'n=$1; shift; bash "$@" </dev/null | head -n "$n"' _ "$n" "$TMUXKEEP_BIN" --key t status --follow "$@"
}

@test "status --follow writes one audit line first, then one valid JSON object per line" {
  mk_session api
  run follow_lines 2 --lines 5
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  local l
  for l in "${lines[@]}"; do
    [ "$(jq -c '[.lines, (.sessions | length)]' <<<"$l")" = '[5,1]' ] || { echo "$l"; return 1; }
  done
  [ "$(audit_count)" -eq 1 ]
  [ "$(audit_field verb)" = status ]
  [ "$(audit_field ok)" = true ]
  [ "$(audit_field session)" = '' ]
  [ "$(audit_field detail)" = 'follow lines=5' ]
}

@test "status --follow ends when the reader goes away: SIGPIPE by default, the failed write when SIGPIPE is ignored" {
  run timeout 30 bash -c 'bash "$1" --key t status --follow </dev/null | head -n 1 >/dev/null; echo "broker=${PIPESTATUS[0]}"' _ "$TMUXKEEP_BIN"
  [ "$status" -eq 0 ]
  [ "$output" = 'broker=141' ]
  run timeout 30 bash -c 'trap "" PIPE; bash "$1" --key t status --follow </dev/null | head -n 1 >/dev/null; echo "broker=${PIPESTATUS[0]}"' _ "$TMUXKEEP_BIN"
  [ "$status" -eq 0 ]
  [ "$output" = 'broker=0' ]
  [ "$(audit_count)" -eq 2 ]
}

@test "status --follow reads the clock again for every snapshot" {
  unset TMUXKEEP_NOW
  run follow_lines 2
  [ "$status" -eq 0 ]
  [ "$(jq -r .now <<<"${lines[0]}")" != "$(jq -r .now <<<"${lines[1]}")" ]
}

@test "status --follow with an unwritable audit log warns once on stderr and still streams" {
  export TMUXKEEP_AUDIT=/nonexistent-dir/audit.log
  run --separate-stderr follow_lines 2
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: audit write failed' ]
}

@test "status --follow given twice is a usage error, audited" {
  run --separate-stderr tmuxkeep status --follow --follow
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: usage: tmuxkeep status [--follow] [--lines N]' ]
  [ "$(audit_field ok)" = false ]
}
