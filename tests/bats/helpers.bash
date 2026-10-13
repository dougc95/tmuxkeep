# tests/bats/helpers.bash: shared helpers for every bats file. Load with: load helpers
# The repo is mounted read-only at /src. Write only under $BATS_TEST_TMPDIR or the
# container paths /home/claude, /var/log/tmuxkeep, /etc/tmuxkeep and /etc/ssh.
# Do not run bats with --jobs: remote-mode tests share the real default paths.
bats_require_minimum_version 1.5.0

TMUXKEEP_BIN=/src/vps/tmuxkeep
FIXED_NOW=1790000000   # TOTP step 59666666; the stub's code for that step is 666666

# ---- local mode: TMUXKEEP_* overrides are honoured ----
setup_local() {
  export TMUXKEEP_HOME="$BATS_TEST_TMPDIR/home/.tmuxkeep"
  export TMUXKEEP_AUDIT="$BATS_TEST_TMPDIR/audit.log"
  export TMUXKEEP_WORK="$BATS_TEST_TMPDIR/work"
  export TMUXKEEP_TMUX_SOCKET="$BATS_TEST_TMPDIR/tmux.sock"
  export TMUXKEEP_NOW="$FIXED_NOW"
  export OATH_STUB_LOG="$BATS_TEST_TMPDIR/oathtool.args"
  mkdir -p "$TMUXKEEP_HOME/leases" "$TMUXKEEP_WORK"
  chmod 700 "$TMUXKEEP_HOME"
  printf 'JBSWY3DPEHPK3PXP\n' > "$TMUXKEEP_HOME/totp.secret"
  printf '0\n' > "$TMUXKEEP_HOME/last-otp"
  : > "$TMUXKEEP_AUDIT"
  install -m 0755 /src/tests/bats/stubs/oathtool "$BATS_TEST_TMPDIR/oathtool"
  export TMUXKEEP_OATHTOOL="$BATS_TEST_TMPDIR/oathtool"
  cp /src/tests/fixtures/tmuxkeep.conf "$BATS_TEST_TMPDIR/tmuxkeep.conf"
  export TMUXKEEP_CONF="$BATS_TEST_TMPDIR/tmuxkeep.conf"
  export SHELL=/bin/bash TERM=xterm-256color
  unset SSH_ORIGINAL_COMMAND SSH_CLIENT SSH_CONNECTION SSH_TTY TMUX XDG_RUNTIME_DIR
}
teardown_local() {
  [ -n "${TMUXKEEP_TMUX_SOCKET:-}" ] && tmux -S "$TMUXKEEP_TMUX_SOCKET" kill-server 2>/dev/null
  return 0
}

tmuxkeep()       { bash "$TMUXKEEP_BIN" --key t "$@" </dev/null; }
tmuxkeep_key()   { local k=$1; shift; bash "$TMUXKEEP_BIN" --key "$k" "$@" </dev/null; }
tmuxkeep_nokey() { bash "$TMUXKEEP_BIN" "$@" </dev/null; }

tm()             { tmux -S "$TMUXKEEP_TMUX_SOCKET" "$@"; }
mk_session()     { tm new-session -d -s "$1" -c "${2:-/tmp}"; }
mk_session_cmd() { tm new-session -d -s "$1" -c /tmp "$2"; }
session_names()  { tm list-sessions -F '#{session_name}' 2>/dev/null; }
locked_flag()    { tm display-message -p -t "=$1:" '#{@tmuxkeep_locked}'; }

mk_lease()      { printf '%s\n' "${3:-$TMUXKEEP_NOW}" > "$TMUXKEEP_HOME/leases/$1@$2"; }
now_step()      { echo $(( TMUXKEEP_NOW / 30 )); }
code_for_step() { printf '%06d' $(( $1 % 1000000 )); }

audit_last()  { tail -n 1 "$TMUXKEEP_AUDIT"; }
audit_field() { audit_last | jq -r ".$1"; }
audit_count() { wc -l < "$TMUXKEEP_AUDIT"; }

strip_cr() { printf '%s' "$1" | tr -d '\r'; }
b64()      { printf '%s' "$1" | base64 -w0; }
b64cmd()   { local out=b64 a; for a in "$@"; do out+=" $(b64 "$a")"; done; printf '%s' "$out"; }

# Run the broker on a pseudo-terminal; INPUT is typed at the TOTP prompt. The sleep keeps
# the pty open until the broker has read its line. Output contains \r: use strip_cr.
with_tty() {
  local input=$1; shift
  local cmd
  printf -v cmd '%q ' bash "$TMUXKEEP_BIN" "$@"
  { printf '%s\n' "$input"; sleep 1; } | script -qec "$cmd" /dev/null
}

_poll() { # _poll SECONDS COMMAND...: retry every 0.1s until COMMAND succeeds
  local deadline=$(( $(date +%s) + $1 )); shift
  until "$@"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}
_pane_has_line() { tm capture-pane -p -J -S - -t "=$1:" | grep -qxF -- "$2"; }
_pane_contains() { tm capture-pane -p -J -S - -t "=$1:" | grep -qF -- "$2"; }
_pane_cmd_is()   { [ "$(tm display-message -p -t "=$1:" '#{pane_current_command}')" = "$2" ]; }
_clients_are()   { [ "$(tm list-clients -t "=$1:" 2>/dev/null | wc -l)" -eq "$2" ]; }
wait_for_pane_line()     { _poll "${3:-5}" _pane_has_line "$1" "$2"; }
wait_for_pane_contains() { _poll "${3:-5}" _pane_contains "$1" "$2"; }
wait_for_cmd()           { _poll "${3:-5}" _pane_cmd_is "$1" "$2"; }
wait_for_clients()       { _poll "${3:-5}" _clients_are "$1" "$2"; }

# ---- remote mode: TMUXKEEP_* overrides are ignored, so these use the real default paths ----
setup_remote() {
  unset TMUXKEEP_CONF TMUXKEEP_HOME TMUXKEEP_AUDIT TMUXKEEP_WORK TMUXKEEP_TMUX_SOCKET TMUXKEEP_NOW TMUXKEEP_OATHTOOL
  install -m 0644 /src/tests/fixtures/tmuxkeep.conf /etc/tmuxkeep/tmuxkeep.conf
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
  rm -rf /home/claude/.tmuxkeep /home/claude/work
  mkdir -p /home/claude/.tmuxkeep/leases /home/claude/work /var/log/tmuxkeep
  chmod 700 /home/claude/.tmuxkeep
  printf 'JBSWY3DPEHPK3PXP\n' > /home/claude/.tmuxkeep/totp.secret
  printf '0\n' > /home/claude/.tmuxkeep/last-otp
  : > /var/log/tmuxkeep/audit.log
  export SHELL=/bin/bash TERM=xterm-256color
  unset SSH_ORIGINAL_COMMAND SSH_CLIENT SSH_CONNECTION SSH_TTY TMUX
}
teardown_remote() {
  tmux -S "$XDG_RUNTIME_DIR/tmuxkeep.sock" kill-server 2>/dev/null
  rm -f /etc/tmuxkeep/tmuxkeep.conf
  return 0
}
rtm() { tmux -S "$XDG_RUNTIME_DIR/tmuxkeep.sock" "$@"; }
# remote IP KEY "COMMAND STRING": what sshd does for the forced command
remote() {
  SSH_ORIGINAL_COMMAND="$3" SSH_CLIENT="$1 50000 22" SSH_CONNECTION="$1 50000 172.17.0.2 22" \
    bash "$TMUXKEEP_BIN" --key "$2" </dev/null
}
remote_audit_last() { tail -n 1 /var/log/tmuxkeep/audit.log; }

# ---- config files ----
# conf_set_in FILE KEY VALUE: replace FILE's KEY= line. ENVIRON, not -v, so backslashes survive.
conf_set_in() {
  TK_K=$2 TK_V=$3 awk 'BEGIN { k = ENVIRON["TK_K"]; v = ENVIRON["TK_V"] }
    index($0, k "=") == 1 { print k "=" v; next } { print }' "$1" > "$1.new" &&
    cat "$1.new" > "$1" && rm -f "$1.new"
}
conf_set() { conf_set_in "$TMUXKEEP_CONF" "$1" "$2"; }
