#!/usr/bin/env bats
# resume and reap (spec 6, 8, 11).
load helpers
setup() { setup_local; mk_lease t -; }
teardown() { teardown_local; }

no_lease() { rm -f "$TMUXKEEP_HOME"/leases/*; }

# ---- resume ----
@test "resume on an idle shell sends claude --continue" {
  mkdir -p "$TMUXKEEP_WORK/api"
  mk_session api "$TMUXKEEP_WORK/api"
  wait_for_cmd api bash
  run tmuxkeep resume api
  [ "$status" -eq 0 ]
  [ "$output" = "resumed api" ]
  wait_for_pane_contains api 'claude --continue'
  [ "$(audit_field detail)" = resumed ]
}

@test "resume refuses a busy pane (3) and names the command" {
  mk_session api
  wait_for_cmd api bash
  tm send-keys -t '=api:' 'sleep 30' Enter
  wait_for_cmd api sleep
  run --separate-stderr tmuxkeep resume api
  [ "$status" -eq 3 ]
  [ "$stderr" = "tmuxkeep: pane busy (sleep)" ]
}

@test "resume recreates a missing session from its work directory" {
  mkdir -p "$TMUXKEEP_WORK/api"
  run tmuxkeep resume api
  [ "$status" -eq 0 ]
  [ "$output" = "recreated api" ]
  [ "$(tm display-message -p -t '=api:' '#{session_path}')" = "$TMUXKEEP_WORK/api" ]
  wait_for_pane_contains api 'claude --continue'
  [ "$(audit_field detail)" = recreated ]
}

@test "resume will not recreate beside a tombstone of the same name (3, plan Q5)" {
  mkdir -p "$TMUXKEEP_WORK/api"
  mk_session 'zz~api~1789990000'
  run --separate-stderr tmuxkeep resume api
  [ "$status" -eq 3 ]
  [[ "$stderr" == *restore* ]]
  [ "$(session_names)" = 'zz~api~1789990000' ]
}

@test "resume will not recreate into a directory another session uses (3, plan Q5)" {
  mkdir -p "$TMUXKEEP_WORK/api"
  mk_session web "$TMUXKEEP_WORK/api"
  run tmuxkeep resume api
  [ "$status" -eq 3 ]
  [ "$(session_names)" = web ]
}

@test "resume: nothing to resume (5), tombstone name (2), no lease (4)" {
  run tmuxkeep resume api
  [ "$status" -eq 5 ]
  run tmuxkeep resume 'zz~api~1'
  [ "$status" -eq 2 ]
  mkdir -p "$TMUXKEEP_WORK/api"
  no_lease
  run tmuxkeep resume api
  [ "$status" -eq 4 ]
  [ -z "$(session_names)" ]
}

# ---- reap ----
@test "reap kills only tombstones strictly older than TOMBSTONE_TTL" {
  mk_session "zz~old~$((TMUXKEEP_NOW - 86401))"
  mk_session "zz~edge~$((TMUXKEEP_NOW - 86400))"
  mk_session "zz~new~$((TMUXKEEP_NOW - 100))"
  mk_session live
  mk_session zz-x
  run tmuxkeep_key reaper reap
  [ "$status" -eq 0 ]
  [ "$output" = "reaped zz~old~$((TMUXKEEP_NOW - 86401))" ]
  [ "$(session_names | sort | tr '\n' ' ')" = "live zz-x zz~edge~$((TMUXKEEP_NOW - 86400)) zz~new~$((TMUXKEEP_NOW - 100)) " ]
  [ "$(audit_count)" -eq 1 ]
  [ "$(audit_field verb)" = reap ]
  [ "$(audit_field key)" = reaper ]
  [ "$(audit_field session)" = "zz~old~$((TMUXKEEP_NOW - 86401))" ]
  [ "$(audit_field detail)" = reaped ]
}

@test "reap with no tmux server is a silent no-op (0)" {
  run tmuxkeep_key reaper reap
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(audit_count)" -eq 0 ]
}

@test "reap with nothing old writes no audit line" {
  mk_session "zz~new~$((TMUXKEEP_NOW - 100))"
  run tmuxkeep_key reaper reap
  [ "$status" -eq 0 ]
  [ "$(audit_count)" -eq 0 ]
}

@test "reap needs no lease and takes no arguments" {
  no_lease
  run tmuxkeep_key reaper reap
  [ "$status" -eq 0 ]
  run tmuxkeep_key reaper reap extra
  [ "$status" -eq 2 ]
}

@test "one failed kill does not stop the others; exit 1 and both audited" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/tmux" <<'EOF'
#!/bin/bash
case " $* " in *" kill-session "*"=zz~bad~"*) echo "stub: refusing" >&2; exit 1 ;; esac
exec /usr/bin/tmux "$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
  mk_session "zz~bad~$((TMUXKEEP_NOW - 90000))"
  mk_session "zz~good~$((TMUXKEEP_NOW - 90000))"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run tmuxkeep_key reaper reap
  [ "$status" -eq 1 ]
  [ "$(session_names)" = "zz~bad~$((TMUXKEEP_NOW - 90000))" ]
  [ "$(audit_count)" -eq 2 ]
  run jq -s -e 'map(.ok) | sort == [false, true]' "$TMUXKEEP_AUDIT"
  [ "$status" -eq 0 ]
}
