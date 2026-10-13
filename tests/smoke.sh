#!/usr/bin/env bash
# smoke.sh - operator end-to-end smoke test for tmuxkeep from macOS or Linux (bash 3.2 and later).
#
# Run it yourself, from a terminal, against the real VPS:
#   bash tests/smoke.sh [--wrapper <path>]
# The default wrapper is ~/.local/bin/tmuxkeep. Agents never run this against the real wrapper;
# tests/bats/smoke.bats drives it with a fake wrapper instead.
#
# It creates one throwaway session named smoke-<6 random characters>, walks it through the whole
# lifecycle (13 steps) and removes it again. Exit 0 when every step passes, 1 at the first mismatch:
# the script stops there and prints how to clean up by hand. The same hint is printed if the run is
# interrupted while a session may exist. Step 1 (auth) runs uncaptured so the "TOTP: " prompt
# reaches the terminal; every other step is captured, and the gated verbs reuse the lease.

TK_WRAPPER=$HOME/.local/bin/tmuxkeep
TK_N=''
TK_SESSION_MAY_EXIST=0
TK_HINT_PRINTED=0
TK_OUT=''

# tk_cleanup_hint: how to remove a leftover test session, at most once, only while one may exist.
tk_cleanup_hint() {
  if [ "$TK_SESSION_MAY_EXIST" != 1 ] || [ "$TK_HINT_PRINTED" = 1 ]; then return 0; fi
  TK_HINT_PRINTED=1
  printf 'A test session may be left behind. To clean it up: tmuxkeep rm %s --now --confirm %s\n' "$TK_N" "$TK_N"
  printf "If the rm is refused as locked: run 'tmuxkeep restore %s' only if 'tmuxkeep ls' shows a zz~%s~... row, then 'tmuxkeep unlock %s', then the rm again.\n" "$TK_N" "$TK_N" "$TK_N"
}

# tk_stop STEP REASON [OUTPUT]: print the failure and the cleanup hint, then exit 1.
tk_stop() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  if [ -n "${3:-}" ]; then printf '%s\n' '--- output ---' "$3" '--- end of output ---'; fi
  tk_cleanup_hint
  exit 1
}

# tk_check STEP CODE EXPECT OUTPUT PATTERN: compare the exit code and, when PATTERN is set, an ERE.
tk_check() {
  if [ "$2" != "$3" ]; then tk_stop "$1" "exit code $2, expected $3" "$4"; fi
  if [ -n "$5" ] && ! printf '%s\n' "$4" | grep -Eq -- "$5"; then tk_stop "$1" "output did not match /$5/" "$4"; fi
  printf 'PASS %s\n' "$1"
}

# tk_step STEP EXPECT PATTERN WORD...: run the wrapper with stdout and stderr captured, then check.
tk_step() {
  local step=$1 expect=$2 pattern=$3 code
  shift 3
  TK_OUT=$("$TK_WRAPPER" "$@" 2>&1)
  code=$?
  tk_check "$step" "$code" "$expect" "$TK_OUT" "$pattern"
}

tk_smoke_main() {
  local v code missing='' usage='usage: bash tests/smoke.sh [--wrapper <path>]'
  while [ "$#" -gt 0 ]; do
    case $1 in
      --wrapper)
        if [ "$#" -lt 2 ]; then echo "$usage"; return 2; fi
        TK_WRAPPER=$2
        shift 2 ;;
      *) echo "$usage"; return 2 ;;
    esac
  done
  if [ ! -x "$TK_WRAPPER" ]; then printf 'FAIL setup: wrapper not found or not executable: %s\n' "$TK_WRAPPER"; return 1; fi
  # Bounded read (-N3): a `tr < urandom | head` pipeline never ends where SIGPIPE is ignored
  # (GitHub Actions, Node-spawned shells) because BSD tr ignores write errors.
  TK_N="smoke-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  printf 'smoke: session name %s\n' "$TK_N"
  trap 'tk_cleanup_hint; exit 130' INT TERM

  # 1. auth, uncaptured, so the TOTP prompt reaches the terminal.
  echo 'Type the code from your phone at the TOTP prompt.'
  "$TK_WRAPPER" auth
  code=$?
  tk_check '1/13 auth' "$code" 0 '' ''

  # A session may exist from here on, even if new itself fails halfway.
  TK_SESSION_MAY_EXIST=1
  tk_step "2/13 new $TK_N" 0 "created $TK_N in " new "$TK_N"
  tk_step '3/13 ls (live row)' 0 "^${TK_N}[[:space:]]+live" ls
  tk_step "4/13 peek $TK_N" 0 '' peek "$TK_N"
  tk_step "5/13 send $TK_N /help" 0 "sent [0-9]+ bytes to $TK_N" send "$TK_N" /help
  tk_step "6/13 lock $TK_N" 0 "locked $TK_N" lock "$TK_N"
  tk_step "7/13 rm $TK_N (locked, must be refused with exit 3)" 3 '' rm "$TK_N"
  tk_step "8/13 unlock $TK_N" 0 '' unlock "$TK_N"
  tk_step "9/13 rm $TK_N (tombstone)" 0 "tombstoned $TK_N;" rm "$TK_N"
  tk_step '10/13 ls (tombstone row)' 0 "^zz~$TK_N~[0-9]+[[:space:]]+tombstone" ls
  tk_step "11/13 restore $TK_N" 0 "restored $TK_N" restore "$TK_N"
  tk_step "12/13 rm $TK_N --now --confirm $TK_N" 0 "killed $TK_N" rm "$TK_N" --now --confirm "$TK_N"
  # The session is gone now; a later failure has nothing to clean up.
  TK_SESSION_MAY_EXIST=0

  # 13. The audit log must show every verb used against this session. PASS only after that check.
  TK_OUT=$("$TK_WRAPPER" log -n 20 2>&1)
  code=$?
  if [ "$code" = 0 ]; then
    for v in new peek send lock rm unlock restore; do
      printf '%s\n' "$TK_OUT" | grep -F "\"verb\":\"$v\"" | grep -qF "\"session\":\"$TK_N\"" || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
      tk_stop '13/13 log -n 20 (audit lines for this session)' "no audit line for session $TK_N and verb:$missing" "$TK_OUT"
    fi
  fi
  tk_check '13/13 log -n 20 (audit lines for this session)' "$code" 0 "$TK_OUT" ''
  trap - INT TERM
  echo 'smoke: all steps passed'
  return 0
}

[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0
tk_smoke_main "$@"
exit $?
