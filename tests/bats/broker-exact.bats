#!/usr/bin/env bats
# Cross-verb sweeps: exact targeting (spec 12.1), which verbs are gated (spec D3),
# and one audit line per exit class (spec 5.4, 7.3).
load helpers
setup() { setup_local; }
teardown() { teardown_local; }

@test "exact targeting: with api2 live and api absent, every verb on api is 5" {
  mk_lease t -
  mk_session_cmd api2 'echo marker2; exec sleep 300'
  wait_for_pane_line api2 marker2
  local line
  local -a cmd
  while IFS= read -r line; do
    read -r -a cmd <<<"$line"
    run tmuxkeep "${cmd[@]}"
    [ "$status" -eq 5 ] || { echo "tmuxkeep $line gave $status"; return 1; }
  done <<'EOF'
peek api
go api
send api hello
rename api other
lock api
unlock api
rm api
rm api --now --confirm api
restore api
resume api
EOF
  [ "$(session_names)" = api2 ]
  [ -z "$(locked_flag api2)" ]
  run tmuxkeep peek api2
  [ "$output" = marker2 ]
}

@test "exact targeting: a session named bash, not a window named bash elsewhere" {
  mk_lease t -
  mk_session other
  tm rename-window -t '=other:' bash
  mk_session bash
  wait_for_cmd bash bash
  run tmuxkeep send bash echo only-in-bash
  [ "$status" -eq 0 ]
  wait_for_pane_line bash only-in-bash
  run tm capture-pane -p -t '=other:'
  [[ "$output" != *only-in-bash* ]]
  run tmuxkeep peek bash
  [[ "$output" == *only-in-bash* ]]
  run tmuxkeep lock bash
  [ "$(locked_flag bash)" = 1 ]
  [ -z "$(locked_flag other)" ]
}

@test "exactly the GATED_VERBS need a lease (spec D3)" {
  mk_session api
  mk_session 'zz~old~1789990000'
  mkdir -p "$TMUXKEEP_WORK/api"
  local line
  local -a cmd
  while IFS= read -r line; do
    read -r -a cmd <<<"$line"
    run tmuxkeep "${cmd[@]}"
    [ "$status" -eq 4 ] || { echo "gated: tmuxkeep $line gave $status"; return 1; }
  done <<'EOF'
new fresh
go api
send api hi
rename api web
unlock api
rm api
resume api
auth
EOF
  while IFS= read -r line; do
    read -r -a cmd <<<"$line"
    run tmuxkeep "${cmd[@]}"
    [ "$status" -ne 4 ] || { echo "open: tmuxkeep $line was gated"; return 1; }
  done <<'EOF'
ls
peek api
log
lock api
restore old
EOF
}

@test "every exit class writes exactly one audit line with the right ok value" {
  mk_lease t -
  mk_session api
  tm set-option -t '=api:' @tmuxkeep_locked 1
  check() { # check STATUS OK ARGS...
    local want=$1 ok=$2 before
    shift 2
    before=$(audit_count)
    run tmuxkeep "$@"
    [ "$status" -eq "$want" ] || { echo "tmuxkeep $*: status $status, want $want"; return 1; }
    [ "$(audit_count)" -eq $((before + 1)) ] || { echo "tmuxkeep $*: audit line count"; return 1; }
    [ "$(audit_field ok)" = "$ok" ] || { echo "tmuxkeep $*: ok field"; return 1; }
  }
  check 0 true peek api
  check 2 false peek 1bad
  check 3 false rm api
  check 5 false peek nosuch
  check 1 false new web --repo https://127.0.0.1:9/nope.git
  rm -f "$TMUXKEEP_HOME"/leases/*
  check 4 false unlock api
}
