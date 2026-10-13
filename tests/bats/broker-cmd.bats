#!/usr/bin/env bats
# Session commands (spec 7.1, plan Q2): LAUNCH_CMD for new, RESUME_CMD for resume, the one-shot
# --cmd override, --shell (types no command, spec 16), their validation and the audit field.
# A valid lease exists unless a test removes it.
load helpers
setup() { setup_local; mk_lease t -; }
teardown() { teardown_local; }

# pane_lines NAME: how many non-blank lines NAME's pane shows.
pane_lines() { tm capture-pane -p -J -S - -t "=$1:" | grep -c '[^[:space:]]'; }
# settled NAME: wait for the shell prompt, then give anything typed one second to appear.
settled() {
  _poll 5 bash -c "tmux -S '$TMUXKEEP_TMUX_SOCKET' capture-pane -p -t '=$1:' | grep -q '[^[:space:]]'"
  sleep 1
}

# ---- new ----
@test "new types LAUNCH_CMD from the config, then Enter, and audits no cmd key" {
  conf_set LAUNCH_CMD 'echo launched-ok'
  run tmuxkeep new api
  [ "$status" -eq 0 ]
  wait_for_pane_line api launched-ok
  run jq -e 'has("cmd") | not' <<<"$(audit_last)"
  [ "$status" -eq 0 ]
}

@test "an empty LAUNCH_CMD types nothing: the pane shows only the prompt" {
  conf_set LAUNCH_CMD ''
  run tmuxkeep new api
  [ "$status" -eq 0 ]
  settled api
  [ "$(pane_lines api)" -eq 1 ]
}

@test "--cmd overrides LAUNCH_CMD for that session and is audited" {
  conf_set LAUNCH_CMD 'echo from-config'
  run tmuxkeep new api --cmd 'echo override-ok'
  [ "$status" -eq 0 ]
  wait_for_pane_line api override-ok
  run ! _pane_contains api from-config
  [ "$(audit_field cmd)" = 'echo override-ok' ]
  [ "$(audit_field detail)" = "created dir=$TMUXKEEP_WORK/api" ]
}

@test "an empty --cmd opens a shell only and is audited as an empty cmd" {
  run tmuxkeep new api --cmd ''
  [ "$status" -eq 0 ]
  settled api
  [ "$(pane_lines api)" -eq 1 ]
  run jq -e '.cmd == ""' <<<"$(audit_last)"
  [ "$status" -eq 0 ]
}

@test "a --cmd made only of spaces types nothing and is audited as an empty cmd (plan Q2, spec 16)" {
  run tmuxkeep new api --cmd '   '
  [ "$status" -eq 0 ]
  settled api
  [ "$(pane_lines api)" -eq 1 ]
  run jq -e '.cmd == ""' <<<"$(audit_last)"
  [ "$status" -eq 0 ]
}

@test "--cmd may come before the name and together with --repo" {
  mkdir -p "$TMUXKEEP_WORK/api"
  run tmuxkeep new --cmd 'echo order-ok' api --repo https://127.0.0.1:9/x.git
  [ "$status" -eq 0 ]
  wait_for_pane_line api order-ok
}

@test "a --cmd ending in ; is typed literally" {
  run tmuxkeep new api --cmd 'echo semi-ok;'
  [ "$status" -eq 0 ]
  wait_for_pane_contains api 'echo semi-ok;'
  wait_for_pane_line api semi-ok
}

@test "--cmd over 200 characters, with a control character or non-ASCII is usage (2), creates nothing, audits no cmd" {
  local v
  for v in "$(printf 'x%.0s' $(seq 1 201))" "$(printf 'a\tb')" "$(printf 'a\033b')" "$(printf 'caf\xc3\xa9')"; do
    run --separate-stderr tmuxkeep new api --cmd "$v"
    [ "$status" -eq 2 ] || { echo "status $status"; return 1; }
    [ "$stderr" = 'tmuxkeep: --cmd must be at most 200 printable ASCII characters' ] || { echo "$stderr"; return 1; }
    [ "$(audit_field ok)" = false ] || return 1
    run jq -e 'has("cmd") | not' <<<"$(audit_last)"
    [ "$status" -eq 0 ] || return 1
  done
  [ -z "$(session_names)" ]
  run tmuxkeep new api --cmd "$(printf 'x%.0s' $(seq 1 200))"
  [ "$status" -eq 0 ]
}

@test "--cmd without a value, or given twice, is usage (2)" {
  run tmuxkeep new api --cmd
  [ "$status" -eq 2 ]
  run tmuxkeep new api --cmd a --cmd b
  [ "$status" -eq 2 ]
  [ -z "$(session_names)" ]
}

@test "without a lease or a TTY, new --cmd is 4 and the audit line carries the cmd" {
  rm -f "$TMUXKEEP_HOME"/leases/*
  run tmuxkeep new api --cmd 'echo x'
  [ "$status" -eq 4 ]
  [ "$(audit_field cmd)" = 'echo x' ]
  [ -z "$(session_names)" ]
}

# ---- new --shell (spec 16): the laptop wrappers cannot send an empty word, so --shell is the
# option that means "type no command into the new pane" ----
@test "new --shell types nothing even when LAUNCH_CMD is set, and audits an empty cmd" {
  conf_set LAUNCH_CMD 'echo should-not-run'
  run tmuxkeep new api --shell
  [ "$status" -eq 0 ]
  [ "$output" = "created api in $TMUXKEEP_WORK/api" ]
  settled api
  [ "$(pane_lines api)" -eq 1 ]
  run jq -e '.cmd == ""' <<<"$(audit_last)"
  [ "$status" -eq 0 ]
  [ "$(audit_field detail)" = "created dir=$TMUXKEEP_WORK/api" ]
}

@test "new --shell may come before the name and together with --repo" {
  mkdir -p "$TMUXKEEP_WORK/api"
  run tmuxkeep new --shell api --repo https://127.0.0.1:9/x.git
  [ "$status" -eq 0 ]
  settled api
  [ "$(pane_lines api)" -eq 1 ]
}

@test "new with --shell and --cmd, in either order, is usage (2), creates nothing, audits ok false" {
  run --separate-stderr tmuxkeep new api --shell --cmd x
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: --shell and --cmd cannot be combined' ]
  [ "$(audit_field ok)" = false ]
  run --separate-stderr tmuxkeep new api --cmd x --shell
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: --shell and --cmd cannot be combined' ]
  [ "$(audit_field ok)" = false ]
  [ -z "$(session_names)" ]
}

@test "new --shell given twice is usage (2) and the usage line lists --shell" {
  run --separate-stderr tmuxkeep new api --shell --shell
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: usage: tmuxkeep new <name> [--repo <https-url>] [--cmd <text>] [--shell]' ]
  [ "$(audit_field ok)" = false ]
  [ -z "$(session_names)" ]
}

# ---- resume ----
@test "resume types RESUME_CMD from the config into an idle shell" {
  conf_set RESUME_CMD 'echo resumed-ok'
  mk_session api
  wait_for_cmd api bash
  run tmuxkeep resume api
  [ "$status" -eq 0 ]
  [ "$output" = 'resumed api' ]
  wait_for_pane_line api resumed-ok
}

@test "resume recreates a missing session and types RESUME_CMD" {
  conf_set RESUME_CMD 'echo recreated-ok'
  mkdir -p "$TMUXKEEP_WORK/api"
  run tmuxkeep resume api
  [ "$status" -eq 0 ]
  [ "$output" = 'recreated api' ]
  wait_for_pane_line api recreated-ok
}

@test "resume --cmd overrides RESUME_CMD and is audited" {
  mk_session api
  wait_for_cmd api bash
  run tmuxkeep resume --cmd 'echo resume-override' api
  [ "$status" -eq 0 ]
  wait_for_pane_line api resume-override
  [ "$(audit_field cmd)" = 'echo resume-override' ]
  [ "$(audit_field detail)" = resumed ]
}

@test "an empty RESUME_CMD types nothing and still reports resumed" {
  conf_set RESUME_CMD ''
  mk_session api
  wait_for_cmd api bash
  settled api
  run tmuxkeep resume api
  [ "$status" -eq 0 ]
  [ "$output" = 'resumed api' ]
  sleep 1
  [ "$(pane_lines api)" -eq 1 ]
}

@test "resume usage: no name, two names, --cmd without a value, an invalid --cmd, an unknown option (2)" {
  run tmuxkeep resume
  [ "$status" -eq 2 ]
  run tmuxkeep resume api web
  [ "$status" -eq 2 ]
  run tmuxkeep resume api --cmd
  [ "$status" -eq 2 ]
  run tmuxkeep resume api --cmd "$(printf 'a\tb')"
  [ "$status" -eq 2 ]
  run tmuxkeep resume api --frob
  [ "$status" -eq 2 ]
}

# ---- resume --shell (spec 16) ----
@test "resume --shell types nothing even when RESUME_CMD is set, and audits an empty cmd" {
  conf_set RESUME_CMD 'echo should-not-run'
  mk_session api
  wait_for_cmd api bash
  settled api
  run tmuxkeep resume api --shell
  [ "$status" -eq 0 ]
  [ "$output" = 'resumed api' ]
  sleep 1
  [ "$(pane_lines api)" -eq 1 ]
  run jq -e '.cmd == ""' <<<"$(audit_last)"
  [ "$status" -eq 0 ]
  [ "$(audit_field detail)" = resumed ]
}

@test "resume --shell recreates a missing session and types nothing" {
  conf_set RESUME_CMD 'echo should-not-run'
  mkdir -p "$TMUXKEEP_WORK/api"
  run tmuxkeep resume --shell api
  [ "$status" -eq 0 ]
  [ "$output" = 'recreated api' ]
  settled api
  [ "$(pane_lines api)" -eq 1 ]
  run jq -e '.cmd == ""' <<<"$(audit_last)"
  [ "$status" -eq 0 ]
  [ "$(audit_field detail)" = recreated ]
}

@test "resume with --shell and --cmd, in either order, is usage (2) and audits ok false" {
  mk_session api
  wait_for_cmd api bash
  run --separate-stderr tmuxkeep resume api --shell --cmd x
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: --shell and --cmd cannot be combined' ]
  [ "$(audit_field ok)" = false ]
  run --separate-stderr tmuxkeep resume api --cmd x --shell
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: --shell and --cmd cannot be combined' ]
  [ "$(audit_field ok)" = false ]
}

@test "resume --shell given twice is usage (2) and the usage line lists --shell" {
  mk_session api
  wait_for_cmd api bash
  run --separate-stderr tmuxkeep resume api --shell --shell
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: usage: tmuxkeep resume <name> [--cmd <text>] [--shell]' ]
  [ "$(audit_field ok)" = false ]
}

# ---- source checks ----
@test "type_line is the only typing helper; type_continue and the literal claude are gone" {
  run grep -c 'type_continue' "$TMUXKEEP_BIN"
  [ "$output" = 0 ]
  run grep -c '^type_line() {' "$TMUXKEEP_BIN"
  [ "$output" = 1 ]
  run grep -cE "send-keys -l -- (claude|'claude --continue')" "$TMUXKEEP_BIN"
  [ "$output" = 0 ]
}
