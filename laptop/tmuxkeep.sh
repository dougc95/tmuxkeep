#!/usr/bin/env bash
# tmuxkeep.sh - laptop wrapper for the tmuxkeep session broker (bash 3.2 and later; macOS, Linux).
# Installed by laptop/deploy.sh as ~/.local/bin/tmuxkeep (mode 0755).
#
#   tmuxkeep <verb> [args...]
#
# Every word is base64-encoded and sent as:
#   ssh -o BatchMode=yes -o ConnectTimeout=5 [-t] tmuxkeep b64 <token>...
# The VPS side is a forced command, so quoting never reaches a remote shell. Exit code: ssh's own,
# or 2 for a local usage error. Written for /bin/bash 3.2 on macOS: no bash 4 features and no
# set -u (3.2 treats an empty array as unset). The bats tests source this file (the guard at the
# end stops before tk_main runs) and redefine tk_prompt, the only function that opens the terminal.

TK_GATED_VERBS="new go send rename unlock rm resume auth"
TK_HINT="tmuxkeep: ssh to host 'tmuxkeep' failed (unreachable, key rejected, or remote killed by signal)"

# tk_encode WORD: base64 of WORD's bytes on one line. GNU base64 wraps at 76 columns, BSD does not.
tk_encode() { printf '%s' "$1" | base64 | tr -d '\n'; }

# tk_is_gated VERB: status 0 when VERB is exactly one word of TK_GATED_VERBS (case-sensitive).
tk_is_gated() {
  local v
  for v in $TK_GATED_VERBS; do
    if [ "$v" = "$1" ]; then return 0; fi
  done
  return 1
}

# tk_ssh_args WORD...: sets the array TK_SSH_ARGS to the full ssh argument list for WORD...
tk_ssh_args() {
  local w
  TK_SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=5)
  if [ "$#" -gt 0 ] && tk_is_gated "$1"; then TK_SSH_ARGS+=(-t); fi
  TK_SSH_ARGS+=(tmuxkeep b64)
  for w in "$@"; do TK_SSH_ARGS+=("$(tk_encode "$w")"); done
}

# tk_prompt LABEL: prints LABEL on the terminal, reads one line from it, prints that line.
tk_prompt() {
  local answer=''
  printf '%s' "$1" > /dev/tty
  IFS= read -r answer < /dev/tty || answer=''
  printf '%s' "$answer"
}

# tk_ui WORD...: the local ui verb (spec 5.1). Runs node on the dashboard that deploy.sh installs in
# ~/.local/share/tmuxkeep/dashboard, in the foreground, and returns node's exit code. Never calls ssh.
tk_ui() {
  local dir="$HOME/.local/share/tmuxkeep/dashboard"
  if ! command -v node >/dev/null; then
    printf 'tmuxkeep: node not found; install Node 20 or newer to use the dashboard\n' >&2
    return 2
  fi
  if [ ! -f "$dir/server.js" ]; then
    printf 'tmuxkeep: dashboard not installed at %s; run deploy again\n' "$dir" >&2
    return 2
  fi
  node "$dir/server.js" "$@"
}

# tk_main WORD...: the wrapper; returns ssh's exit code, or 2 for a local usage error.
tk_main() {
  local w text answer has_now=0 has_confirm=0 rc
  local -a words
  words=("$@")
  for w in "$@"; do
    if [ -z "$w" ]; then printf 'tmuxkeep: empty argument\n' >&2; return 2; fi
  done
  # "ui" never reaches the broker: it starts the local dashboard server.
  if [ "$#" -gt 0 ] && [ "$1" = ui ]; then
    shift
    tk_ui "$@"
    return
  fi
  # "send <name>" with no text: ask for it locally and send it as one word.
  if [ "$#" -eq 2 ] && [ "$1" = send ]; then
    text=$(tk_prompt 'Text to send: ')
    if [ -z "$text" ]; then printf 'tmuxkeep: nothing to send\n' >&2; return 2; fi
    words+=("$text")
  fi
  # "rm ... --now" without --confirm: ask for the session name locally.
  if [ "$#" -gt 0 ] && [ "$1" = rm ]; then
    for w in "$@"; do
      case $w in
        --now) has_now=1 ;;
        --confirm) has_confirm=1 ;;
      esac
    done
    if [ "$has_now" = 1 ] && [ "$has_confirm" = 0 ]; then
      answer=$(tk_prompt 'Type the session name to confirm: ')
      if [ -z "$answer" ]; then printf 'tmuxkeep: confirmation required\n' >&2; return 2; fi
      words+=(--confirm "$answer")
    fi
  fi
  tk_ssh_args "${words[@]}"
  # A plain command with the terminal attached: no capture, no redirection (go, the TOTP prompt).
  ssh "${TK_SSH_ARGS[@]}"
  rc=$?
  if [ "$rc" -eq 255 ]; then printf '%s\n' "$TK_HINT" >&2; fi
  return "$rc"
}

[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0
tk_main "$@"
exit $?
