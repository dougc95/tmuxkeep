#!/usr/bin/env bats
# Broker core: invocation, --key, argument decoding, audit, exit codes, log.
load helpers
setup() { setup_local; }
teardown() { teardown_local; }

@test "no arguments is usage (2), one stderr line, audited" {
  run --separate-stderr tmuxkeep
  [ "$status" -eq 2 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == "tmuxkeep: "* ]]
  [ "$(audit_count)" -eq 1 ]
  [ "$(audit_field ok)" = false ]
}

@test "unknown verb is usage (2) and the verb is audited" {
  run --separate-stderr tmuxkeep frobnicate
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown verb"* ]]
  [ "$(audit_field verb)" = frobnicate ]
  [ "$(audit_field ok)" = false ]
}

@test "verbs are case-sensitive" {
  run tmuxkeep LOG
  [ "$status" -eq 2 ]
}

@test "control characters in an unknown verb are not echoed raw" {
  run --separate-stderr tmuxkeep $'fro\ebnicate'
  [ "$status" -eq 2 ]
  [[ "$stderr" != *$'\e'* ]]
}

@test "invalid --key id is usage (2)" {
  run tmuxkeep_key BAD log
  [ "$status" -eq 2 ]
  run tmuxkeep_key 1abc log
  [ "$status" -eq 2 ]
  run tmuxkeep_key abcdefghijklmnopq log
  [ "$status" -eq 2 ]
}

@test "audit line has exactly the spec keys and values" {
  run tmuxkeep log
  [ "$status" -eq 0 ]
  run jq -e 'keys == ["detail","ip","key","ok","session","ts","verb"] and (.ok | type == "boolean")' <<<"$(audit_last)"
  [ "$status" -eq 0 ]
  [ "$(audit_field ts)" = "$(date -u -d "@$FIXED_NOW" +%Y-%m-%dT%H:%M:%SZ)" ]
  [ "$(audit_field key)" = t ]
  [ "$(audit_field ip)" = - ]
  [ "$(audit_field verb)" = log ]
  [ "$(audit_field ok)" = true ]
}

@test "without --key the audit key is local" {
  run tmuxkeep_nokey log
  [ "$status" -eq 0 ]
  [ "$(audit_field key)" = local ]
}

@test "log prints the last N lines, then audits itself" {
  local i
  for i in 1 2 3 4 5; do printf '{"n":%d}\n' "$i" >> "$TMUXKEEP_AUDIT"; done
  run tmuxkeep log -n 2
  [ "$status" -eq 0 ]
  [ "$output" = $'{"n":4}\n{"n":5}' ]
  [ "$(audit_field verb)" = log ]
  [ "$(audit_field detail)" = lines=2 ]
}

@test "log defaults to 50 lines" {
  local i
  for i in $(seq 1 60); do printf '{"n":%d}\n' "$i" >> "$TMUXKEEP_AUDIT"; done
  run tmuxkeep log
  [ "${#lines[@]}" -eq 50 ]
  [ "${lines[0]}" = '{"n":11}' ]
}

@test "log -n must be 0-9999 and log takes no other arguments" {
  run tmuxkeep log -n abc
  [ "$status" -eq 2 ]
  run tmuxkeep log -n 12345
  [ "$status" -eq 2 ]
  run tmuxkeep log -n
  [ "$status" -eq 2 ]
  run tmuxkeep log extra
  [ "$status" -eq 2 ]
  run tmuxkeep log -n 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unwritable audit log fails closed with exit 1" {
  export TMUXKEEP_AUDIT=/nonexistent-dir/audit.log
  run --separate-stderr tmuxkeep log
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"audit log not writable"* ]]
}

@test "b64 form decodes every argument" {
  printf '{"n":1}\n{"n":2}\n' >> "$TMUXKEEP_AUDIT"
  run tmuxkeep $(b64cmd log -n 1)
  [ "$status" -eq 0 ]
  [ "$output" = '{"n":2}' ]
}

@test "invalid b64 tokens are usage (2)" {
  run tmuxkeep b64 'bG9n!'
  [ "$status" -eq 2 ]
  run tmuxkeep b64 bG9
  [ "$status" -eq 2 ]
  run tmuxkeep b64 '===='
  [ "$status" -eq 2 ]
  run tmuxkeep b64
  [ "$status" -eq 2 ]
}

@test "a decoded argument containing NUL is usage (2)" {
  # YQBi is base64 of the three bytes a, NUL, b.
  run tmuxkeep b64 "$(b64 log)" YQBi
  [ "$status" -eq 2 ]
}

@test "a trailing newline inside an encoded argument is kept, not stripped" {
  # bG9nCg== is base64 of "log\n"; a decoder that stripped it would run 'log' and exit 0.
  run tmuxkeep b64 bG9nCg==
  [ "$status" -eq 2 ]
}

@test "TMUXKEEP_NOW that is not digits falls back to the real clock" {
  export TMUXKEEP_NOW=garbage
  run tmuxkeep log
  [ "$status" -eq 0 ]
  [ "$(audit_field ts)" != "$(date -u -d "@$FIXED_NOW" +%Y-%m-%dT%H:%M:%SZ)" ]
}

@test "the broker can be sourced without running main" {
  run bash -c "source '$TMUXKEEP_BIN'; declare -F main >/dev/null && echo sourced"
  [ "$status" -eq 0 ]
  [ "$output" = sourced ]
}

@test "a verb that returns without succeed or fail is caught by the dispatch backstop (1)" {
  run --separate-stderr bash -c "source '$TMUXKEEP_BIN'; verb_dummy() { :; }; main --key t dummy"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"internal: verb returned"* ]]
  [ "$(audit_field verb)" = dummy ]
  [ "$(audit_field ok)" = false ]
}

@test "the audit log is pure ASCII: non-ASCII input is escaped" {
  run --separate-stderr tmuxkeep $'fro\xc3\xa9bnicate'
  [ "$status" -eq 2 ]
  run grep -cP '[^\x00-\x7F]' "$TMUXKEEP_AUDIT"
  [ "$output" = 0 ]
  [ "$(audit_field verb)" = $'fro\xc3\xa9bnicate' ]
}

@test "an unwritable audit log on an early failure prints no bash redirect error" {
  export TMUXKEEP_AUDIT=/nonexistent-dir/audit.log
  run --separate-stderr tmuxkeep frobnicate
  [ "$status" -eq 2 ]
  [ "${#stderr_lines[@]}" -eq 2 ]
  [ "${stderr_lines[0]}" = "tmuxkeep: unknown verb: frobnicate" ]
  [ "${stderr_lines[1]}" = "tmuxkeep: audit write failed" ]
  [[ "$stderr" != *"No such file"* ]]
}

@test "authorize fails closed (4) when gate is missing or returns non-zero" {
  run bash -c "source '$TMUXKEEP_BIN'; verb_dummy() { authorize; echo RAN; succeed ran; }; GATED_VERBS='dummy'; main --key t dummy"
  [ "$status" -eq 4 ]
  [[ "$output" != *RAN* ]]
  [ "$(audit_field ok)" = false ]
}
