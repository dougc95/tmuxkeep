#!/usr/bin/env bats
# laptop/tmuxkeep.sh (spec 6.1, 6.4, 9.2): encoding, gated -t, exit codes, local checks. ssh is a
# stub; prompts are tested by redefining tk_prompt after sourcing the wrapper.
load laptop-helpers

setup() {
  laptop_setup
  # shellcheck source=/dev/null
  source "$WRAPPER"
  PROMPTS="$BATS_TEST_TMPDIR/prompts"
  : > "$PROMPTS"
}

# line_for TTY WORD...: the stub log line the wrapper must produce (TTY is 1 for a gated verb).
line_for() {
  local tty=$1 w out='ssh [-o] [BatchMode=yes] [-o] [ConnectTimeout=5]'
  shift
  if [ "$tty" = 1 ]; then out="$out [-t]"; fi
  out="$out [tmuxkeep] [b64]"
  for w in "$@"; do out="$out [$(b64 "$w")]"; done
  printf '%s' "$out"
}

# answer TEXT: from now on tk_prompt records its label in $PROMPTS and answers TEXT.
answer() {
  TK_ANSWER=$1
  tk_prompt() { printf '%s\n' "$1" >> "$PROMPTS"; printf '%s' "$TK_ANSWER"; }
}

@test "sourcing defines the functions and runs nothing" {
  declare -F tk_main tk_prompt tk_encode tk_ssh_args tk_is_gated >/dev/null
  [ ! -s "$TK_STUB_LOG" ]
}

@test "the gated verb list is the one agreed line" {
  [ "$(grep -c '^TK_GATED_VERBS=' "$WRAPPER")" -eq 1 ]
  grep -qx 'TK_GATED_VERBS="new go send rename unlock rm resume auth"' "$WRAPPER"
}

@test "gated verbs get -t, open verbs do not" {
  local v
  for v in new go rename unlock rm resume; do
    : > "$TK_STUB_LOG"
    run tk_main "$v" api
    [ "$(stub_calls)" = "$(line_for 1 "$v" api)" ] || { echo "verb $v: $(stub_calls)"; return 1; }
  done
  : > "$TK_STUB_LOG"
  run tk_main send api hi
  [ "$(stub_calls)" = "$(line_for 1 send api hi)" ]
  : > "$TK_STUB_LOG"
  run tk_main auth
  [ "$(stub_calls)" = "$(line_for 1 auth)" ]
  for v in peek lock restore; do
    : > "$TK_STUB_LOG"
    run tk_main "$v" api
    [ "$(stub_calls)" = "$(line_for 0 "$v" api)" ] || { echo "verb $v: $(stub_calls)"; return 1; }
  done
  for v in ls log; do
    : > "$TK_STUB_LOG"
    run tk_main "$v"
    [ "$(stub_calls)" = "$(line_for 0 "$v")" ] || { echo "verb $v: $(stub_calls)"; return 1; }
  done
}

@test "tk_is_gated is an exact match: a first word holding spaces is not gated" {
  local w
  for w in 'new go' 'go send' 'rm resume' 'new ' ' go'; do
    run tk_is_gated "$w"
    [ "$status" -eq 1 ] || { echo "gated: [$w]"; return 1; }
    tk_ssh_args "$w" x
    [ "${TK_SSH_ARGS[*]}" = "-o BatchMode=yes -o ConnectTimeout=5 tmuxkeep b64 $(b64 "$w") $(b64 x)" ] \
      || { echo "args for [$w]: ${TK_SSH_ARGS[*]}"; return 1; }
  done
  run tk_is_gated go
  [ "$status" -eq 0 ]
  tk_ssh_args new api
  [ "${TK_SSH_ARGS[*]}" = "-o BatchMode=yes -o ConnectTimeout=5 -t tmuxkeep b64 $(b64 new) $(b64 api)" ]
}

@test "each word of a multi-word send is encoded separately, spaces and specials kept" {
  run tk_main send api 'echo hi; ls *' there
  [ "$status" -eq 0 ]
  [ "$(stub_calls)" = "$(line_for 1 send api 'echo hi; ls *' there)" ]
}

@test "non-ASCII text is sent as base64 of its UTF-8 bytes" {
  local cafe
  cafe=$(printf 'caf\303\251')
  run tk_main send api "$cafe"
  [ "$(stub_calls)" = "$(line_for 1 send api "$cafe")" ]
  [ "$(b64 "$cafe")" = Y2Fmw6k= ]
}

@test "a long word stays one token: GNU base64 line wrapping is removed" {
  local long
  long=$(printf 'x%.0s' $(seq 1 120))
  run tk_main send api "$long"
  [ "$status" -eq 0 ]
  [ "$(stub_calls)" = "$(line_for 1 send api "$long")" ]
  [ "$(stub_calls | grep -c .)" -eq 1 ]
}

@test "an empty argument is exit 2 with no ssh call" {
  run --separate-stderr tk_main send api ''
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: empty argument' ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "send with no text prompts once and sends the answer as one word" {
  answer 'a; b # $c (d) @e, f'
  run tk_main send api
  [ "$status" -eq 0 ]
  [ "$(cat "$PROMPTS")" = 'Text to send: ' ]
  [ "$(stub_calls)" = "$(line_for 1 send api 'a; b # $c (d) @e, f')" ]
}

@test "an empty prompted text is exit 2 with no ssh call" {
  answer ''
  run --separate-stderr tk_main send api
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: nothing to send' ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "rm --now prompts for the name and appends --confirm" {
  answer api
  run tk_main rm api --now
  [ "$status" -eq 0 ]
  [ "$(cat "$PROMPTS")" = 'Type the session name to confirm: ' ]
  [ "$(stub_calls)" = "$(line_for 1 rm api --now --confirm api)" ]
}

@test "rm --now --confirm, plain rm and an upper-case RM do not prompt" {
  answer unused
  run tk_main rm api --now --confirm api
  [ "$(stub_calls)" = "$(line_for 1 rm api --now --confirm api)" ]
  : > "$TK_STUB_LOG"
  run tk_main rm api
  [ "$(stub_calls)" = "$(line_for 1 rm api)" ]
  : > "$TK_STUB_LOG"
  run tk_main RM api --now
  [ "$(stub_calls)" = "$(line_for 0 RM api --now)" ]
  [ ! -s "$PROMPTS" ]
}

@test "an empty confirmation is exit 2 with no ssh call" {
  answer ''
  run --separate-stderr tk_main rm api --now
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: confirmation required' ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "a bare -- is sent encoded, never raw" {
  run tk_main send api -- x
  [ "$(stub_calls)" = "$(line_for 1 send api -- x)" ]
  [[ "$(stub_calls)" != *'[--]'* ]]
}

@test "the exit code is ssh's own" {
  export TK_STUB_SSH_RC=3
  run tk_main rm api
  [ "$status" -eq 3 ]
}

@test "exit 255 prints the hint exactly once, on stderr" {
  export TK_STUB_SSH_RC=255
  run --separate-stderr tk_main ls
  [ "$status" -eq 255 ]
  [ "$stderr" = "tmuxkeep: ssh to host 'tmuxkeep' failed (unreachable, key rejected, or remote killed by signal)" ]
  [ -z "$output" ]
}

@test "other failures print no hint; ssh's own stdout and stderr pass through" {
  printf 'broker says hi\n' > "$BATS_TEST_TMPDIR/out"
  export TK_STUB_SSH_OUT="$BATS_TEST_TMPDIR/out" TK_STUB_SSH_ERR='tmuxkeep: no such session: nosuch' TK_STUB_SSH_RC=5
  run --separate-stderr tk_main peek nosuch
  [ "$status" -eq 5 ]
  [ "$output" = 'broker says hi' ]
  [ "$stderr" = 'tmuxkeep: no such session: nosuch' ]
}

@test "run as a program, the wrapper calls ssh and exits with its code" {
  export TK_STUB_SSH_RC=4
  run "$BASH" "$WRAPPER" auth
  [ "$status" -eq 4 ]
  [ "$(stub_calls)" = "$(line_for 1 auth)" ]
}

@test "with no arguments the wrapper still asks the broker, which answers with its usage" {
  run tk_main
  [ "$(stub_calls)" = 'ssh [-o] [BatchMode=yes] [-o] [ConnectTimeout=5] [tmuxkeep] [b64]' ]
}

@test "tk_prompt is the only code that opens /dev/tty" {
  [ "$(grep -vE '^[[:space:]]*#' "$WRAPPER" | grep -c '/dev/tty')" -eq 2 ]
  [ "$(sed -n '/^tk_prompt() {/,/^}/p' "$WRAPPER" | grep -c '/dev/tty')" -eq 2 ]
}

@test "the interpreter is the expected one (TK_EXPECT_BASH_MAJOR is set by the macOS CI job)" {
  if [ -z "${TK_EXPECT_BASH_MAJOR:-}" ]; then skip "TK_EXPECT_BASH_MAJOR not set"; fi
  [ "${BASH_VERSINFO[0]}" = "$TK_EXPECT_BASH_MAJOR" ] || { echo "bash $BASH_VERSION"; return 1; }
}

# fake_node: a stub node first on PATH; it logs its arguments like the other stubs and exits 7.
fake_node() {
  mkdir -p "$BATS_TEST_TMPDIR/nodebin"
  printf '#!/usr/bin/env bash\n{ printf node; printf " [%%s]" "$@"; printf "\n"; } >> "$TK_STUB_LOG"\nexit 7\n' > "$BATS_TEST_TMPDIR/nodebin/node"
  chmod +x "$BATS_TEST_TMPDIR/nodebin/node"
  PATH="$BATS_TEST_TMPDIR/nodebin:$PATH"
}

# install_dashboard: the file deploy.sh would install, under the current HOME.
install_dashboard() {
  mkdir -p "$HOME/.local/share/tmuxkeep/dashboard"
  : > "$HOME/.local/share/tmuxkeep/dashboard/server.js"
}

@test "ui runs node on the installed dashboard with the other words, returns its code and never calls ssh" {
  # Review Focus 2: a home directory with a space in its path.
  export HOME="$BATS_TEST_TMPDIR/home dir"
  fake_node
  install_dashboard
  run tk_main ui --port 8080 --no-open
  [ "$status" -eq 7 ]
  [ "$(stub_calls)" = "node [$HOME/.local/share/tmuxkeep/dashboard/server.js] [--port] [8080] [--no-open]" ]
}

@test "run as a program, ui exits with node's code" {
  fake_node
  install_dashboard
  run "$BASH" "$WRAPPER" ui
  [ "$status" -eq 7 ]
  [ "$(stub_calls)" = "node [$HOME/.local/share/tmuxkeep/dashboard/server.js]" ]
}

@test "ui without node on PATH says so, exits 2 and never calls ssh" {
  local p="$STUBS:/usr/bin:/bin"
  if ( PATH=$p; command -v node >/dev/null ); then skip 'a node is installed in /usr/bin or /bin'; fi
  install_dashboard
  PATH=$p
  run --separate-stderr tk_main ui
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: node not found; install Node 20 or newer to use the dashboard' ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "ui without an installed dashboard says where it looked and exits 2" {
  fake_node
  run --separate-stderr tk_main ui
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep: dashboard not installed at $HOME/.local/share/tmuxkeep/dashboard; run deploy again" ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "ui is matched case-sensitively: UI goes to the broker like any other word" {
  fake_node
  install_dashboard
  run tk_main UI
  [ "$(stub_calls)" = "$(line_for 0 UI)" ]
}

# hex_word HEX: the bytes HEX spells, two hex digits per byte (printf %b with \0NNN works in bash 3.2).
hex_word() {
  local h=$1 esc=''
  while [ -n "$h" ]; do
    esc="$esc\0$(printf '%03o' "0x${h%"${h#??}"}")"
    h=${h#??}
  done
  printf '%b' "$esc"
}

@test "every shared b64 case in tests/fixtures/b64-words encodes to its token" {
  local label hex token n=0
  while read -r label hex token; do
    case $label in ''|'#'*) continue ;; esac
    [ "$(tk_encode "$(hex_word "$hex")")" = "$token" ] || { echo "case $label"; return 1; }
    n=$((n + 1))
  done < "$REPO/tests/fixtures/b64-words"
  [ "$n" -eq 15 ]
}
