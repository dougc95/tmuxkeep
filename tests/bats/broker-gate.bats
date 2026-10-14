#!/usr/bin/env bats
# TOTP gate and lease (spec 7.1), auth and unlock. Stub code for step S is S mod 1e6.
load helpers
setup() {
  setup_local
  mk_session api
  tm set-option -t '=api:' @tmuxkeep_locked 1
}
teardown() { teardown_local; }

fails_file() { printf '%s' "$TMUXKEEP_HOME/otp-fails"; }

@test "auth accepts the codes for step-1, step and step+1" {
  local s d
  s=$(now_step)
  for d in -1 0 1; do
    printf '0\n' > "$TMUXKEEP_HOME/last-otp"
    run with_tty "$(code_for_step $((s + d)))" --key t auth
    [ "$status" -eq 0 ] || { echo "offset $d: $output"; return 1; }
    [[ "$(strip_cr "$output")" == *"authenticated; lease valid for 30m"* ]]
  done
}

@test "auth rejects step-2 and step+2 (4)" {
  local s
  s=$(now_step)
  run with_tty "$(code_for_step $((s - 2)))" --key t auth
  [ "$status" -eq 4 ]
  run with_tty "$(code_for_step $((s + 2)))" --key t auth
  [ "$status" -eq 4 ]
}

@test "the prompt is 'TOTP: ' on the terminal" {
  run with_tty "$(code_for_step "$(now_step)")" --key t auth
  [[ "$(strip_cr "$output")" == *"TOTP: "* ]]
}

@test "success writes last-otp and the lease, and truncates otp-fails" {
  local s
  s=$(now_step)
  printf '%s\n' $((TMUXKEEP_NOW - 5000)) $((TMUXKEEP_NOW - 4000)) > "$(fails_file)"
  run with_tty "$(code_for_step "$s")" --key t auth
  [ "$status" -eq 0 ]
  [ "$(cat "$TMUXKEEP_HOME/last-otp")" = "$s" ]
  [ "$(cat "$TMUXKEEP_HOME/leases/t@-")" = "$TMUXKEEP_NOW" ]
  [ ! -s "$(fails_file)" ]
  [ "$(audit_field verb)" = auth ]
  [ "$(audit_field detail)" = authenticated ]
}

@test "the gate's own files stay private: lease and last-otp are mode 600" {
  rm -f "$TMUXKEEP_HOME/last-otp"
  run with_tty "$(code_for_step "$(now_step)")" --key t auth
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$TMUXKEEP_HOME/leases/t@-")" = 600 ]
  [ "$(stat -c %a "$TMUXKEEP_HOME/last-otp")" = 600 ]
}

@test "a replayed step is rejected; a later step is accepted" {
  local s
  s=$(now_step)
  printf '%s\n' "$s" > "$TMUXKEEP_HOME/last-otp"
  run with_tty "$(code_for_step "$s")" --key t auth
  [ "$status" -eq 4 ]
  run with_tty "$(code_for_step $((s + 1)))" --key t auth
  [ "$status" -eq 0 ]
  [ "$(cat "$TMUXKEEP_HOME/last-otp")" = $((s + 1)) ]
}

@test "input that is not six digits counts as a failure, audited as otp-fail" {
  run with_tty 12345a --key t auth
  [ "$status" -eq 4 ]
  [ "$(wc -l < "$(fails_file)")" -eq 1 ]
  [ "$(audit_field ok)" = false ]
  [ "$(audit_field detail)" = otp-fail ]
  run with_tty '' --key t auth
  [ "$status" -eq 4 ]
  [ "$(wc -l < "$(fails_file)")" -eq 2 ]
}

@test "no TTY and no lease fails (4) with the spec message and changes nothing" {
  run --separate-stderr tmuxkeep unlock api
  [ "$status" -eq 4 ]
  [ "$stderr" = "tmuxkeep: TOTP required: run with a terminal or run 'tmuxkeep auth' first" ]
  [ "$(locked_flag api)" = 1 ]
  [ "$(audit_field detail)" = no-tty ]
}

@test "a lease younger than LEASE_SECS skips the prompt" {
  mk_lease t - $((TMUXKEEP_NOW - 1799))
  run tmuxkeep unlock api
  [ "$status" -eq 0 ]
  [ "$output" = "unlocked api" ]
  [ -z "$(locked_flag api)" ]
}

@test "a lease exactly LEASE_SECS old has expired" {
  mk_lease t - $((TMUXKEEP_NOW - 1800))
  run tmuxkeep unlock api
  [ "$status" -eq 4 ]
}

@test "a lease from the future is ignored" {
  mk_lease t - $((TMUXKEEP_NOW + 60))
  run tmuxkeep unlock api
  [ "$status" -eq 4 ]
}

@test "a lease belongs to one key id" {
  mk_lease other -
  run tmuxkeep unlock api
  [ "$status" -eq 4 ]
  run tmuxkeep_key other unlock api
  [ "$status" -eq 0 ]
}

@test "auth prompts even with a valid lease" {
  mk_lease t -
  run tmuxkeep auth
  [ "$status" -eq 4 ]
  run with_tty "$(code_for_step "$(now_step)")" --key t auth
  [ "$status" -eq 0 ]
}

@test "three failures trigger the cooldown, without prompting" {
  local i
  for i in 1 2 3; do
    run with_tty 000001 --key t auth
    [ "$status" -eq 4 ]
  done
  run --separate-stderr tmuxkeep auth
  [ "$status" -eq 4 ]
  [ "$stderr" = "tmuxkeep: cooldown, retry in 300s" ]
  [ "$(audit_field detail)" = cooldown ]
}

@test "cooldown ends once the newest failure is OTP_COOLDOWN old" {
  printf '%s\n' $((TMUXKEEP_NOW - 400)) $((TMUXKEEP_NOW - 350)) $((TMUXKEEP_NOW - 300)) > "$(fails_file)"
  run --separate-stderr tmuxkeep auth
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"TOTP required"* ]]
}

@test "cooldown counts only failures inside OTP_FAIL_WINDOW" {
  printf '%s\n' $((TMUXKEEP_NOW - 700)) $((TMUXKEEP_NOW - 650)) $((TMUXKEEP_NOW - 10)) > "$(fails_file)"
  run --separate-stderr tmuxkeep auth
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"TOTP required"* ]]
}

@test "the tenth failure creates otp-locked, which blocks even a valid lease (3)" {
  local i
  for i in $(seq 1 9); do printf '%s\n' $((TMUXKEEP_NOW - 5000 - i)) >> "$(fails_file)"; done
  run with_tty 000001 --key t auth
  [ "$status" -eq 4 ]
  [ -e "$TMUXKEEP_HOME/otp-locked" ]
  mk_lease t -
  run --separate-stderr tmuxkeep unlock api
  [ "$status" -eq 3 ]
  [ "$stderr" = "tmuxkeep: OTP locked after repeated failures; root must remove $TMUXKEEP_HOME/otp-locked" ]
  [ "$(locked_flag api)" = 1 ]
  [ "$(audit_field detail)" = otp-locked ]
}

@test "the secret never appears on oathtool's command line" {
  run with_tty "$(code_for_step "$(now_step)")" --key t auth
  [ "$status" -eq 0 ]
  run grep -c JBSWY3DPEHPK3PXP "$OATH_STUB_LOG"
  [ "$output" = 0 ]
  grep -q -- '--totp -b -N @' "$OATH_STUB_LOG"
}

@test "missing totp.secret is exit 1 and not counted as a failure" {
  rm "$TMUXKEEP_HOME/totp.secret"
  run with_tty 666666 --key t auth
  [ "$status" -eq 1 ]
  [[ "$(strip_cr "$output")" == *"TOTP not configured"* ]]
  [ ! -s "$(fails_file)" ]
}

@test "the gate lock is released after a failure" {
  run with_tty 000001 --key t auth
  [ "$status" -eq 4 ]
  run flock -n "$TMUXKEEP_HOME/gate.lock" true
  [ "$status" -eq 0 ]
}

@test "concurrent gated calls serialise on gate.lock" {
  mk_lease t -
  ( flock "$TMUXKEEP_HOME/gate.lock" sleep 2 ) 3>&- &
  # Wait until the background holder really has the lock before timing the gated call.
  _poll 5 bash -c "! flock -n '$TMUXKEEP_HOME/gate.lock' true"
  local t0 t1
  t0=$(date +%s%N)
  run tmuxkeep unlock api
  t1=$(date +%s%N)
  wait
  [ "$status" -eq 0 ]
  [ $(( (t1 - t0) / 1000000 )) -ge 1400 ]
}

@test "unlock: missing session (5), tombstone name (2), already unlocked is fine (0)" {
  mk_lease t -
  run tmuxkeep unlock nosuch
  [ "$status" -eq 5 ]
  run tmuxkeep unlock 'zz~api~1'
  [ "$status" -eq 2 ]
  tm set-option -t '=api:' -u @tmuxkeep_locked
  run tmuxkeep unlock api
  [ "$status" -eq 0 ]
}

@test "manual recovery: root removes otp-locked, then a correct code clears the failures and the lock" {
  local i
  for i in $(seq 1 10); do printf '%s\n' $((TMUXKEEP_NOW - 5000 - i)) >> "$(fails_file)"; done
  : > "$TMUXKEEP_HOME/otp-locked"
  run with_tty "$(code_for_step "$(now_step)")" --key t auth
  [ "$status" -eq 3 ]
  [ "$(audit_field detail)" = otp-locked ]
  rm "$TMUXKEEP_HOME/otp-locked"
  run with_tty "$(code_for_step "$(now_step)")" --key t auth
  [ "$status" -eq 0 ]
  [ ! -e "$TMUXKEEP_HOME/otp-locked" ]
  [ ! -s "$(fails_file)" ]
  [ "$(audit_field detail)" = authenticated ]
}

@test "after manual recovery a wrong code re-locks: the attempt is the eleventh recorded failure" {
  local i
  for i in $(seq 1 10); do printf '%s\n' $((TMUXKEEP_NOW - 5000 - i)) >> "$(fails_file)"; done
  run with_tty 000001 --key t auth
  [ "$status" -eq 4 ]
  [ -e "$TMUXKEEP_HOME/otp-locked" ]
  [ "$(wc -l < "$(fails_file)")" -eq 11 ]
  [ "$(audit_field detail)" = otp-fail ]
}

@test "an attempt is recorded before the prompt: an empty answer leaves exactly one failure" {
  run with_tty '' --key t auth
  [ "$status" -eq 4 ]
  [ "$(wc -l < "$(fails_file)")" -eq 1 ]
  [ "$(audit_field detail)" = otp-fail ]
}

# Done once the broker has written its audit line, or is gone.
_attempt_finished() { [ -s "$TMUXKEEP_AUDIT" ] || ! kill -0 "$1" 2>/dev/null; }

@test "an attempt killed mid-verification is still counted and audited" {
  # The stub oathtool says when verification has started, then stalls a second per step, which
  # leaves a window to hang the terminal up. A wrong code makes the broker walk all three steps.
  local stub="$BATS_TEST_TMPDIR/oathtool-slow" cmd pid
  cat > "$stub" <<'STUB'
#!/bin/bash
cat > /dev/null
echo started >> "${OATH_STUB_LOG}.started"
sleep 1
echo 999999
STUB
  chmod +x "$stub"
  export TMUXKEEP_OATHTOOL="$stub"
  printf -v cmd '%q ' bash "$TMUXKEEP_BIN" --key t auth
  # The feeder keeps the pty open until the broker is done. fd 3 is closed so bats is not held.
  ( { printf '%s\n' 000001; sleep 6; } | script -qec "$cmd" /dev/null >/dev/null 2>&1 ) 3>&- &
  _poll 10 test -s "${OATH_STUB_LOG}.started"
  pid=$(pgrep -o -f "^bash $TMUXKEEP_BIN --key t auth")
  [ -n "$pid" ]
  kill -HUP "$pid"
  _poll 15 _attempt_finished "$pid"
  wait
  [ "$(wc -l < "$(fails_file)")" -eq 1 ]
  [ "$(audit_field ok)" = false ]
  [ "$(audit_field detail)" = otp-fail ]
}

@test "auth --end removes this key id's lease without a code, prints lease ended and audits lease-ended" {
  mk_lease t -
  mk_lease other -
  run --separate-stderr tmuxkeep auth --end
  [ "$status" -eq 0 ]
  [ "$output" = 'lease ended' ]
  [ -z "$stderr" ]
  [ ! -e "$TMUXKEEP_HOME/leases/t@-" ]
  [ -e "$TMUXKEEP_HOME/leases/other@-" ]
  [ "$(audit_field verb)" = auth ]
  [ "$(audit_field ok)" = true ]
  [ "$(audit_field detail)" = lease-ended ]
  [ ! -s "$OATH_STUB_LOG" ]
}

@test "auth --end succeeds when there is no lease, and needs no terminal" {
  run tmuxkeep auth --end
  [ "$status" -eq 0 ]
  [ "$output" = 'lease ended' ]
}

@test "after auth --end a gated verb asks for a code again" {
  mk_lease t -
  run tmuxkeep auth --end
  [ "$status" -eq 0 ]
  run --separate-stderr tmuxkeep unlock api
  [ "$status" -eq 4 ]
  [[ "$stderr" == *'TOTP required'* ]]
  [ "$(locked_flag api)" = 1 ]
}

@test "auth --end does not take the gate: it works during a cooldown and a hard lock" {
  mk_lease t -
  printf '%s\n' $(( TMUXKEEP_NOW - 3 )) $(( TMUXKEEP_NOW - 2 )) $(( TMUXKEEP_NOW - 1 )) > "$(fails_file)"
  : > "$TMUXKEEP_HOME/otp-locked"
  run tmuxkeep auth --end
  [ "$status" -eq 0 ]
  [ ! -e "$TMUXKEEP_HOME/leases/t@-" ]
  [ ! -e "$TMUXKEEP_HOME/gate.lock" ]
}

@test "auth with any argument other than exactly --end is a usage error, audited" {
  local a
  for a in --frob --END end; do
    run --separate-stderr tmuxkeep auth "$a"
    [ "$status" -eq 2 ] || { echo "auth $a gave $status"; return 1; }
    [ "$stderr" = 'tmuxkeep: usage: tmuxkeep auth [--end]' ]
  done
  run tmuxkeep auth --end --end
  [ "$status" -eq 2 ]
  run tmuxkeep auth --end extra
  [ "$status" -eq 2 ]
  [ "$(audit_field ok)" = false ]
  [ "$(audit_field verb)" = auth ]
}
