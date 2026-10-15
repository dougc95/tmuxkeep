#!/usr/bin/env bats
# Remote-mode behaviour: sshd sets SSH_ORIGINAL_COMMAND and the broker ignores TMUXKEEP_*.
# These tests use the broker's real default paths inside the container (plan Q11).
load helpers
setup() { setup_remote; }
teardown() { teardown_remote; }

@test "remote: plain and b64 forms give identical results" {
  run --separate-stderr remote 203.0.113.9 laptop 'frobnicate x'
  local s1=$status e1=$stderr
  run --separate-stderr remote 203.0.113.9 laptop "$(b64cmd frobnicate x)"
  [ "$status" -eq "$s1" ]
  [ "$stderr" = "$e1" ]
  [ "$s1" -eq 2 ]
}

@test "remote: audit records the key id and the client IP" {
  run remote 203.0.113.9 laptop 'log -n 1'
  [ "$status" -eq 0 ]
  local line
  line=$(remote_audit_last)
  [ "$(jq -r .key <<<"$line")" = laptop ]
  [ "$(jq -r .ip <<<"$line")" = 203.0.113.9 ]
}

@test "remote: TMUXKEEP_* overrides are ignored" {
  export TMUXKEEP_AUDIT="$BATS_TEST_TMPDIR/override.log"
  : > "$TMUXKEEP_AUDIT"
  run remote 203.0.113.9 laptop 'log -n 1'
  [ "$status" -eq 0 ]
  [ ! -s "$TMUXKEEP_AUDIT" ]
  [ "$(wc -l < /var/log/tmuxkeep/audit.log)" -eq 1 ]
}

@test "remote: reap is refused (2) and audited" {
  run --separate-stderr remote 203.0.113.9 laptop reap
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"local only"* ]]
  [ "$(jq -r .ok <<<"$(remote_audit_last)")" = false ]
}

@test "remote: control characters in the command are usage (2)" {
  run remote 203.0.113.9 laptop $'log\n-n 1'
  [ "$status" -eq 2 ]
}

@test "remote: words are never glob-expanded" {
  mkdir -p "$BATS_TEST_TMPDIR/g"
  touch "$BATS_TEST_TMPDIR/g/log"
  cd "$BATS_TEST_TMPDIR/g"
  run --separate-stderr remote 203.0.113.9 laptop '*'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown verb"* ]]
}

@test "ssh with no command is a local call with no verb (2)" {
  run env SSH_CLIENT='203.0.113.9 50000 22' bash "$TMUXKEEP_BIN" --key laptop </dev/null
  [ "$status" -eq 2 ]
}

@test "argv after --key makes the call local even with SSH_ORIGINAL_COMMAND set" {
  run env SSH_ORIGINAL_COMMAND=frobnicate bash "$TMUXKEEP_BIN" --key laptop log -n 1 </dev/null
  [ "$status" -eq 0 ]
}

@test "remote: a lease is bound to key id and client IP" {
  rtm new-session -d -s api
  rtm set-option -t '=api:' @tmuxkeep_locked 1
  printf '%s\n' "$(date +%s)" > /home/claude/.tmuxkeep/leases/laptop@203.0.113.9
  run remote 198.51.100.7 laptop 'unlock api'
  [ "$status" -eq 4 ]
  run remote 203.0.113.9 other 'unlock api'
  [ "$status" -eq 4 ]
  run remote 203.0.113.9 laptop 'unlock api'
  [ "$status" -eq 0 ]
  [ -z "$(rtm display-message -p -t '=api:' '#{@tmuxkeep_locked}')" ]
}

@test "remote: plain and b64 give identical ls --names and peek output" {
  rtm new-session -d -s alpha 'printf "a\nb\nc\n"; exec sleep 300'
  rtm new-session -d -s beta
  _poll 5 bash -c "tmux -S '$XDG_RUNTIME_DIR/tmuxkeep.sock' capture-pane -p -t '=alpha:' | grep -qx c"
  run remote 203.0.113.9 laptop 'ls --names'
  local plain=$output
  run remote 203.0.113.9 laptop "$(b64cmd ls --names)"
  [ "$output" = "$plain" ]
  [ "$plain" = $'alpha\nbeta' ]
  run remote 203.0.113.9 laptop 'peek alpha -n 2'
  plain=$output
  run remote 203.0.113.9 laptop "$(b64cmd peek alpha -n 2)"
  [ "$output" = "$plain" ]
  [ "$plain" = $'b\nc' ]
}

# ---- configuration (spec 4.4, 4.5) ----
@test "remote: a missing /etc/tmuxkeep/tmuxkeep.conf is 1 with config invalid, and nothing is audited" {
  rm -f /etc/tmuxkeep/tmuxkeep.conf
  run --separate-stderr remote 203.0.113.9 laptop 'log -n 1'
  [ "$status" -eq 1 ]
  [ "$stderr" = "tmuxkeep: config invalid: /etc/tmuxkeep/tmuxkeep.conf: cannot read" ]
  [ ! -s /var/log/tmuxkeep/audit.log ]
}

@test "remote: an invalid config is 1 and nothing is audited" {
  printf 'LEASE_SECS=5\n' >> /etc/tmuxkeep/tmuxkeep.conf
  run --separate-stderr remote 203.0.113.9 laptop 'log -n 1'
  [ "$status" -eq 1 ]
  [ "$stderr" = "tmuxkeep: config invalid: /etc/tmuxkeep/tmuxkeep.conf: LEASE_SECS: must be an integer from 60 to 86400" ]
  [ ! -s /var/log/tmuxkeep/audit.log ]
}

@test "remote: TMUXKEEP_CONF is ignored" {
  local f="$BATS_TEST_TMPDIR/other.conf"
  cp /etc/tmuxkeep/tmuxkeep.conf "$f"
  conf_set_in "$f" AUDIT_LOG "$BATS_TEST_TMPDIR/other.log"
  export TMUXKEEP_CONF=$f
  run remote 203.0.113.9 laptop 'log -n 1'
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/other.log" ]
  [ "$(wc -l < /var/log/tmuxkeep/audit.log)" -eq 1 ]
}

@test "remote: SEND_MAX_BYTES from /etc/tmuxkeep/tmuxkeep.conf applies" {
  conf_set_in /etc/tmuxkeep/tmuxkeep.conf SEND_MAX_BYTES 3
  rtm new-session -d -s api
  run --separate-stderr remote 203.0.113.9 laptop "$(b64cmd send api abcd)"
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep: text longer than 3 bytes" ]
}

@test "remote: status is not gated, leaves one audit line per call, and reports the lease of this key id and client IP" {
  rtm new-session -d -s api
  printf '%s\n' "$(date +%s)" > /home/claude/.tmuxkeep/leases/laptop@203.0.113.9
  run remote 203.0.113.9 laptop status
  [ "$status" -eq 0 ]
  jq -e '.lease_secs_left > 1790 and .lease_secs_left <= 1800 and ([.sessions[].name] == ["api"]) and .user == "claude"' <<<"$output"
  [ "$(wc -l < /var/log/tmuxkeep/audit.log)" -eq 1 ]
  [ "$(jq -r '[.verb, .ok, .detail, .ip, .key] | join(" ")' <<<"$(remote_audit_last)")" = 'status true lines=12 203.0.113.9 laptop' ]
  run remote 198.51.100.7 laptop "$(b64cmd status --lines 0)"
  [ "$status" -eq 0 ]
  jq -e '.lease_secs_left == 0 and .lines == 0 and .sessions[0].lines == []' <<<"$output"
  [ "$(wc -l < /var/log/tmuxkeep/audit.log)" -eq 2 ]
  [ "$(jq -r '[.verb, .ok, .detail, .ip, .key] | join(" ")' <<<"$(remote_audit_last)")" = 'status true lines=0 198.51.100.7 laptop' ]
}

@test "remote: auth --end removes only the lease of this key id and client IP" {
  local now
  now=$(date +%s)
  printf '%s\n' "$now" > /home/claude/.tmuxkeep/leases/laptop@203.0.113.9
  printf '%s\n' "$now" > /home/claude/.tmuxkeep/leases/laptop@198.51.100.7
  run remote 203.0.113.9 laptop "$(b64cmd auth --end)"
  [ "$status" -eq 0 ]
  [ "$output" = 'lease ended' ]
  [ ! -e /home/claude/.tmuxkeep/leases/laptop@203.0.113.9 ]
  [ -e /home/claude/.tmuxkeep/leases/laptop@198.51.100.7 ]
  [ "$(jq -r .detail <<<"$(remote_audit_last)")" = lease-ended ]
  [ "$(jq -r .ip <<<"$(remote_audit_last)")" = 203.0.113.9 ]
}
