#!/usr/bin/env bash
# deploy.sh - operator deploy for tmuxkeep from macOS or Linux (bash 3.2 and later). Spec 6.1, 6.4.
#
#   bash laptop/deploy.sh [--config <path>] [--init] [--harden-root] [--rotate-totp] [--unlock-otp]
#
# Agents never run this script themselves. The bats tests source it (functions only) and run it as
# a child process from a temporary git copy, with stub ssh, scp and ssh-keygen first on PATH and
# HOME in a temp directory. bash 3.2 rules: no bash 4 features, no set -u, no GNU-only tools.

TK_CONF_KEYS="HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES DASHBOARD_PORT TERMINAL_CMD"
# The eight files staged from vps/, in this order (spec 6.1 step 4). One line on purpose: a parity test reads it.
TK_VPS_FILES="tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer"

# ---- laptop config (spec 4.1, 4.2, 4.3; plan Q5, Q14) ----
# The same rules and messages as Read-TmuxkeepConfig in laptop/deploy.ps1, parse_conf in vps/tmuxkeep
# and read_deploy_conf in vps/tmuxkeep-setup: keep the four in step.

# tk_conf_defaults: every TKC_* at its default; HOST has none and stays empty.
tk_conf_defaults() {
  TKC_HOST=''
  TKC_PORT=22
  TKC_USER=claude
  TKC_KEY=\~/.ssh/id_tmuxkeep_ed25519
  TKC_ADMIN_KEY=\~/.ssh/id_tmuxkeep_admin_ed25519
  TKC_LAUNCH_CMD=claude
  TKC_RESUME_CMD='claude --continue'
  TKC_INSTALL_CLAUDE_CODE=no
  TKC_LEASE_SECS=1800
  TKC_TOMBSTONE_TTL=86400
  TKC_OTP_FAIL_MAX=3
  TKC_OTP_FAIL_WINDOW=600
  TKC_OTP_COOLDOWN=300
  TKC_OTP_HARD_MAX=10
  TKC_OTP_READ_TIMEOUT=60
  TKC_SEND_MAX_BYTES=8000
  TKC_DASHBOARD_PORT=7707
  TKC_TERMINAL_CMD=''
}

# tk_trim STRING: sets TK_TRIMMED to STRING without leading and trailing spaces and tabs. The C
# locale keeps [:blank:] to exactly those two; in C.UTF-8 it also matches U+3000 and the like.
tk_trim() {
  local LC_ALL=C
  local s=$1
  s=${s#"${s%%[![:blank:]]*}"}
  s=${s%"${s##*[![:blank:]]}"}
  TK_TRIMMED=$s
}

# tk_printable STRING: status 0 when every byte is 0x20-0x7E (the empty string passes).
tk_printable() {
  local rest
  rest=$(printf '%s' "$1" | LC_ALL=C tr -d ' -~'; printf x)
  [ "$rest" = x ]
}

# tk_is_conf_key KEY: status 0 when KEY is one of TK_CONF_KEYS.
tk_is_conf_key() {
  case " $TK_CONF_KEYS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# tk_check_int KEY VALUE LO HI: 1-7 decimal digits within LO..HI, else TK_ERR and status 1.
tk_check_int() {
  local re='^[0-9]{1,7}$'
  if [[ $2 =~ $re ]] && [ $(( 10#$2 )) -ge "$3" ] && [ $(( 10#$2 )) -le "$4" ]; then return 0; fi
  TK_ERR="$1: must be an integer from $3 to $4"
  return 1
}

# tk_conf_validate: checks the TKC_* values in key-list order. Status 1 with TK_ERR set to the bare
# reason (no file name) on the first failure. The C locale (tk_check_int inherits it) keeps the
# character ranges and lengths to plain ASCII bytes, whatever locale the operator's shell has.
tk_conf_validate() {
  local LC_ALL=C
  local re colons
  if [ -z "$TKC_HOST" ]; then TK_ERR='HOST: required'; return 1; fi
  # Exactly one colon is host:port; an IPv6 literal has two or more.
  colons=${TKC_HOST//[!:]/}
  if [ "${#colons}" -eq 1 ]; then TK_ERR='HOST: looks like host:port; put the port in PORT'; return 1; fi
  re='^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$'
  if ! [[ $TKC_HOST =~ $re ]]; then TK_ERR='HOST: not a hostname, IPv4 or IPv6 address'; return 1; fi
  tk_check_int PORT "$TKC_PORT" 1 65535 || return 1
  re='^[a-z_][a-z0-9_-]{0,31}$'
  if ! [[ $TKC_USER =~ $re ]]; then TK_ERR='USER: must match ^[a-z_][a-z0-9_-]{0,31}$'; return 1; fi
  if [ -z "$TKC_KEY" ] || [[ $TKC_KEY == *'"'* ]]; then
    TK_ERR='KEY: must be a non-empty path without double quotes'; return 1
  fi
  if [ -z "$TKC_ADMIN_KEY" ] || [[ $TKC_ADMIN_KEY == *'"'* ]]; then
    TK_ERR='ADMIN_KEY: must be a non-empty path without double quotes'; return 1
  fi
  if [ "${#TKC_LAUNCH_CMD}" -gt 200 ]; then TK_ERR='LAUNCH_CMD: at most 200 characters'; return 1; fi
  if [ "${#TKC_RESUME_CMD}" -gt 200 ]; then TK_ERR='RESUME_CMD: at most 200 characters'; return 1; fi
  case $TKC_INSTALL_CLAUDE_CODE in
    yes|no) ;;
    *) TK_ERR='INSTALL_CLAUDE_CODE: must be yes or no'; return 1 ;;
  esac
  tk_check_int LEASE_SECS "$TKC_LEASE_SECS" 60 86400 || return 1
  tk_check_int TOMBSTONE_TTL "$TKC_TOMBSTONE_TTL" 3600 2592000 || return 1
  tk_check_int OTP_FAIL_MAX "$TKC_OTP_FAIL_MAX" 1 20 || return 1
  tk_check_int OTP_FAIL_WINDOW "$TKC_OTP_FAIL_WINDOW" 60 86400 || return 1
  tk_check_int OTP_COOLDOWN "$TKC_OTP_COOLDOWN" 10 86400 || return 1
  # OTP_FAIL_MAX passed tk_check_int above, so it is 1-7 digits and safe for 10#.
  tk_check_int OTP_HARD_MAX "$TKC_OTP_HARD_MAX" $(( 10#$TKC_OTP_FAIL_MAX )) 100 || return 1
  tk_check_int OTP_READ_TIMEOUT "$TKC_OTP_READ_TIMEOUT" 10 600 || return 1
  tk_check_int SEND_MAX_BYTES "$TKC_SEND_MAX_BYTES" 1 65536 || return 1
  tk_check_int DASHBOARD_PORT "$TKC_DASHBOARD_PORT" 1024 65535 || return 1
  if [ "${#TKC_TERMINAL_CMD}" -gt 200 ]; then TK_ERR='TERMINAL_CMD: at most 200 characters'; return 1; fi
  return 0
}

# tk_conf_read FILE: sets every TKC_* from FILE over the defaults (spec 4.1; HOST required, other
# missing keys default, plan Q5) and returns 0, or sets TK_ERR to "<FILE>: <reason>" and returns 1.
# FILE is read through redirects, never as an argument, so a name such as -x.conf is not an option.
# File-level checks come first, in this order: BOM, CR, NUL; then each line; then the values.
tk_conf_read() {
  local LC_ALL=C
  local file=$1 line key val n=0 size stripped re_key='^[A-Z_]+$' re_name='^[A-Za-z0-9_]{1,64}$'
  TK_ERR=''
  tk_conf_defaults
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then TK_ERR="$file: cannot read"; return 1; fi
  if [ "$(head -c 3 < "$file" | od -An -tx1 | tr -d ' \n')" = efbbbf ]; then
    TK_ERR="$file: byte order mark found (save without BOM)"; return 1
  fi
  if [ "$(LC_ALL=C tr -cd '\r' < "$file" | wc -c | tr -d ' ')" != 0 ]; then
    TK_ERR="$file: carriage return found (use LF line endings)"; return 1
  fi
  # read -r silently drops NUL bytes, so look for them in the whole file before reading it. macOS
  # wc pads its count with spaces, hence the arithmetic expansion.
  size=$(( $(wc -c < "$file") ))
  stripped=$(( $(LC_ALL=C tr -d '\0' < "$file" | wc -c) ))
  if [ "$size" -ne "$stripped" ]; then
    TK_ERR="$file: NUL byte found"; return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$(( n + 1 ))
    tk_trim "$line"
    line=$TK_TRIMMED
    case $line in ''|'#'*) continue ;; esac
    case $line in *=*) ;; *) TK_ERR="$file: line $n: expected KEY=value"; return 1 ;; esac
    tk_trim "${line%%=*}"
    key=$TK_TRIMMED
    tk_trim "${line#*=}"
    val=$TK_TRIMMED
    if ! [[ $key =~ $re_key ]] || ! tk_is_conf_key "$key"; then
      if [[ $key =~ $re_name ]]; then TK_ERR="$file: line $n: unknown key $key"; else TK_ERR="$file: line $n: unknown key"; fi
      return 1
    fi
    if ! tk_printable "$val"; then TK_ERR="$file: line $n: non-printable or non-ASCII character in $key"; return 1; fi
    printf -v "TKC_$key" '%s' "$val"
  done < "$file"
  if ! tk_conf_validate; then TK_ERR="$file: $TK_ERR"; return 1; fi
}

# tk_conf_text: prints the laptop config file for the current TKC_* values: two header lines, a blank
# line, then each key's comment line and KEY=value. tests/fixtures/laptop-config is exactly this
# output for the defaults and HOST=203.0.113.10.
tk_conf_text() {
  printf '%s\n' \
    '# tmuxkeep laptop configuration, written by the deploy script. Edit it by hand if you like:' \
    '# one KEY=value per line, no quotes. Run the deploy script again after a change.' \
    '' \
    '# VPS address: hostname, IPv4 or IPv6 literal.' \
    "HOST=$TKC_HOST" \
    '# SSH port of the VPS.' \
    "PORT=$TKC_PORT" \
    '# Account on the VPS that owns the tmux sessions; the installer creates it.' \
    "USER=$TKC_USER" \
    '# Session key, no passphrase. ~ is your home directory.' \
    "KEY=$TKC_KEY" \
    '# Admin key for root, with a passphrase. Never add it to ssh-agent.' \
    "ADMIN_KEY=$TKC_ADMIN_KEY" \
    '# Typed into every new session; empty opens a shell only.' \
    "LAUNCH_CMD=$TKC_LAUNCH_CMD" \
    '# Typed by resume; empty opens a shell only.' \
    "RESUME_CMD=$TKC_RESUME_CMD" \
    '# yes installs Claude Code for USER on the next deploy.' \
    "INSTALL_CLAUDE_CODE=$TKC_INSTALL_CLAUDE_CODE" \
    '# Seconds one TOTP code keeps the gated verbs open (60-86400).' \
    "LEASE_SECS=$TKC_LEASE_SECS" \
    '# Seconds a removed session survives as a tombstone (3600-2592000).' \
    "TOMBSTONE_TTL=$TKC_TOMBSTONE_TTL" \
    '# Wrong codes within OTP_FAIL_WINDOW that start a cooldown (1-20).' \
    "OTP_FAIL_MAX=$TKC_OTP_FAIL_MAX" \
    '# Seconds over which wrong codes are counted (60-86400).' \
    "OTP_FAIL_WINDOW=$TKC_OTP_FAIL_WINDOW" \
    '# Seconds of cooldown after OTP_FAIL_MAX wrong codes (10-86400).' \
    "OTP_COOLDOWN=$TKC_OTP_COOLDOWN" \
    '# Wrong codes since the last good one that lock the gate until root clears it (OTP_FAIL_MAX-100).' \
    "OTP_HARD_MAX=$TKC_OTP_HARD_MAX" \
    '# Seconds the VPS waits at the TOTP prompt (10-600).' \
    "OTP_READ_TIMEOUT=$TKC_OTP_READ_TIMEOUT" \
    '# Largest text that send accepts, in bytes (1-65536).' \
    "SEND_MAX_BYTES=$TKC_SEND_MAX_BYTES" \
    '# Loopback port for tmuxkeep ui (1024-65535).' \
    "DASHBOARD_PORT=$TKC_DASHBOARD_PORT" \
    '# Program that opens a terminal for go and auth; empty picks the platform default.' \
    "TERMINAL_CMD=$TKC_TERMINAL_CMD"
}

# tk_conf_write FILE: creates FILE's folder and writes tk_conf_text there; status 1 with TK_ERR on failure.
tk_conf_write() {
  if ! mkdir -p -- "$(dirname -- "$1")"; then TK_ERR="$1: cannot create its folder"; return 1; fi
  if ! tk_conf_text > "$1"; then TK_ERR="$1: cannot write"; return 1; fi
}

# tk_prompt LABEL: prints LABEL on the terminal, reads one line from it, prints that line.
# Deliberately a copy of the function in laptop/tmuxkeep.sh: the two are installed as independent
# single-file programs. It is the only function here that opens the terminal.
tk_prompt() {
  local answer=''
  printf '%s' "$1" > /dev/tty
  IFS= read -r answer < /dev/tty || answer=''
  printf '%s' "$answer"
}

# tk_conf_create FILE: first run (plan Q14). One question, then validate and write. Status 1 with
# TK_ERR="<FILE>: <reason>" for a bad answer, and nothing is written.
tk_conf_create() {
  local answer
  answer=$(tk_prompt 'VPS address (hostname or IP): ')
  tk_conf_defaults
  tk_trim "$answer"
  TKC_HOST=$TK_TRIMMED
  if ! tk_conf_validate; then TK_ERR="$1: $TK_ERR"; return 1; fi
  tk_conf_write "$1"
}

# tk_deploy_conf_text: prints the deploy.conf text (spec 4.3) that tmuxkeep-setup --conf reads: no
# HOST, PORT or keys. tests/fixtures/deploy.conf is exactly this output for the defaults.
tk_deploy_conf_text() {
  printf '%s\n' \
    '# Written by tmuxkeep deploy from the laptop config; read by tmuxkeep-setup --conf.' \
    "USER=$TKC_USER" \
    "LAUNCH_CMD=$TKC_LAUNCH_CMD" \
    "RESUME_CMD=$TKC_RESUME_CMD" \
    "INSTALL_CLAUDE_CODE=$TKC_INSTALL_CLAUDE_CODE" \
    "LEASE_SECS=$TKC_LEASE_SECS" \
    "TOMBSTONE_TTL=$TKC_TOMBSTONE_TTL" \
    "OTP_FAIL_MAX=$TKC_OTP_FAIL_MAX" \
    "OTP_FAIL_WINDOW=$TKC_OTP_FAIL_WINDOW" \
    "OTP_COOLDOWN=$TKC_OTP_COOLDOWN" \
    "OTP_HARD_MAX=$TKC_OTP_HARD_MAX" \
    "OTP_READ_TIMEOUT=$TKC_OTP_READ_TIMEOUT" \
    "SEND_MAX_BYTES=$TKC_SEND_MAX_BYTES"
}

# tk_expand_path PATH: prints PATH with a leading ~ (alone, or before /) replaced by $HOME; anything
# else is printed unchanged.
tk_expand_path() {
  case $1 in
    \~) printf '%s\n' "$HOME" ;;
    \~/*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# ---- ssh config and shell rc blocks (spec 6.1 step 3, 6.4, 12; plan Q3, Q10; Review Focus 3, 4) ----

# tk_ssh_value VALUE: prints VALUE, in double quotes when it contains a space (plan Q10). A leading ~
# is left as written; ssh expands it in IdentityFile.
tk_ssh_value() {
  case $1 in
    *' '*) printf '"%s"\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# tk_ssh_block: prints the ssh config block (18 lines, each ending in LF) for the current TKC_*
# values: Host tmuxkeep for the session key and Host tmuxkeep-admin for root. tests/fixtures/ssh-block
# is exactly this output for the defaults and HOST=203.0.113.10. Nothing here loads a key into
# ssh-agent, and the root host pins the agent option off: ssh takes the first value it finds for an
# option, so a user's own "Host *" block that loads keys into an agent must not reach the admin key.
# The block sits at the top of the file (tk_set_block ... top) so that line comes first. The last
# line, Host *, closes the admin section: whatever follows the block (the user's global lines, an
# Include) is global again instead of belonging to tmuxkeep-admin. There is no macOS keychain option
# here: an OpenSSH that does not know it rejects the whole file, in any section; tk_check_agent_options
# catches a keychain setting instead.
tk_ssh_block() {
  local key admin
  key=$(tk_ssh_value "$TKC_KEY")
  admin=$(tk_ssh_value "$TKC_ADMIN_KEY")
  printf '%s\n' \
    '# >>> tmuxkeep' \
    'Host tmuxkeep' \
    "    HostName $TKC_HOST" \
    "    Port $TKC_PORT" \
    "    User $TKC_USER" \
    "    IdentityFile $key" \
    '    IdentitiesOnly yes' \
    '    ServerAliveInterval 30' \
    '    ServerAliveCountMax 4' \
    'Host tmuxkeep-admin' \
    "    HostName $TKC_HOST" \
    "    Port $TKC_PORT" \
    '    User root' \
    "    IdentityFile $admin" \
    '    IdentitiesOnly yes' \
    '    AddKeysToAgent no' \
    'Host *' \
    '# <<< tmuxkeep'
}

# tk_rc_block: prints the shell rc block (plan Q3): ~/.local/bin on PATH once, bashcompinit in zsh
# (loading compinit first when compdef is missing, because a fresh macOS zsh never ran it), and the
# completion script when it is installed.
tk_rc_block() {
  printf '%s\n' \
    '# >>> tmuxkeep' \
    'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac' \
    '[ -n "$ZSH_VERSION" ] && { whence compdef >/dev/null || { autoload -U +X compinit && compinit -i; }; } && autoload -U +X bashcompinit && bashcompinit' \
    '[ -f "$HOME/.tmuxkeep/completion.bash" ] && . "$HOME/.tmuxkeep/completion.bash"' \
    '# <<< tmuxkeep'
}

# tk_rc_file: prints the rc file the block goes into: ~/.zshrc when SHELL ends in zsh, else ~/.bashrc.
tk_rc_file() {
  case ${SHELL-} in
    *zsh) printf '%s\n' "$HOME/.zshrc" ;;
    *) printf '%s\n' "$HOME/.bashrc" ;;
  esac
}

# tk_set_block FILE TEXT [top]: write-or-replace the marked block TEXT (its lines, without a final
# newline) in FILE (spec 6.1 step 3, 6.4). An existing block is replaced in place, an identical one
# is left alone, a missing one is appended after a blank line (the default: the rc file) or, with the
# third argument "top", written at the top: the block, one empty line, then the previous content
# unchanged (an empty or missing file becomes the block alone). Only the ssh config goes to the top,
# because ssh takes the first value it finds for an option: the option pinned in the ssh block must
# come before any "Host *" block of the user's own. The rc file stays appended: a block above a later
# compinit would lose zsh completion. A leading UTF-8 BOM stays at byte 0 in both placements (at the
# top the block follows it): a BOM in the middle of the file would turn the user's former first line
# into an unknown keyword, and OpenSSH would refuse the whole file. A marker right after the BOM is
# still our marker. The new text is written with "cat tmp > FILE", which follows a symlink and keeps
# FILE's mode and owner, so a dotfiles link stays a link (Review Focus 3).
# TEXT must start with the begin marker line and end with the end marker line, or nothing is written.
# FILE is only written after every read of it succeeded: a failed awk or cmp stops with TK_ERR set
# and FILE untouched, never with an empty or partial temporary file copied over it. A marker line
# that ends in CR (a file edited on Windows) is still our marker; the other lines keep their bytes
# and the new block is written with LF.
tk_set_block() {
  local file=$1 block=$2 place=${3-} dir tmp state first last same nl=$'\n' bom has_bom append=0
  TK_ERR=''
  bom=$(printf '\357\273\277')
  first=${block%%"$nl"*}
  last=${block##*"$nl"}
  if [ "$first" != '# >>> tmuxkeep' ] || [ "$last" != '# <<< tmuxkeep' ]; then
    TK_ERR="block text must start with '# >>> tmuxkeep' and end with '# <<< tmuxkeep'"; return 1
  fi
  if [ -d "$file" ]; then TK_ERR="$file: is a directory"; return 1; fi
  if [ -e "$file" ] && [ ! -w "$file" ]; then TK_ERR="$file: not writable"; return 1; fi
  if [ -e "$file" ] && [ ! -r "$file" ]; then TK_ERR="$file: not readable"; return 1; fi
  dir=$(dirname "$file")
  if ! mkdir -p "$dir"; then TK_ERR="$dir: cannot create"; return 1; fi
  if [ ! -e "$file" ] && ! : > "$file"; then TK_ERR="$file: cannot create"; return 1; fi
  state=$(LC_ALL=C TK_BOM=$bom awk 'BEGIN { bom = ENVIRON["TK_BOM"] }
               { line = $0; sub(/\r$/, "", line) }
               NR == 1 && index(line, bom) == 1 { line = substr(line, length(bom) + 1) }
               line == "# >>> tmuxkeep" { b++; open = 1; next }
               line == "# <<< tmuxkeep" && open { e++; open = 0 }
               END { if (b > 1) print "many"; else if (b == 1 && e == 0) print "open"; else if (b == 0) print "none"; else print "ok" }' "$file") ||
    { TK_ERR="$file: cannot read"; return 1; }
  case $state in
    many) TK_ERR="$file: more than one '# >>> tmuxkeep' line; remove the extra block by hand"; return 1 ;;
    open) TK_ERR="$file: '# >>> tmuxkeep' without '# <<< tmuxkeep'; fix it by hand"; return 1 ;;
  esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/tmuxkeep-block.XXXXXX") || { TK_ERR="$file: cannot create a temporary file"; return 1; }
  if [ "$state" = none ] && [ "$place" = top ]; then
    # No block yet, placed at the top: the new one first, one empty line, then the file as it was.
    # After a leading BOM the BOM stays first, and the "file as it was" is everything from byte 4 on.
    has_bom=0
    if [ "$(head -c 3 < "$file" | od -An -tx1 | tr -d ' \n')" = efbbbf ]; then has_bom=1; fi
    {
      if [ "$has_bom" -eq 1 ]; then printf '%s' "$bom"; fi
      printf '%s\n' "$block"
      if [ "$has_bom" -eq 1 ]; then
        if [ "$(( $(wc -c < "$file") ))" -gt 3 ]; then printf '\n'; tail -c +4 < "$file"; fi
      elif [ -s "$file" ]; then
        printf '\n'; cat "$file"
      fi
    } > "$tmp" || { rm -f "$tmp"; TK_ERR="$file: cannot read"; return 1; }
  else
    # Replace the block where it is; with no block yet (placement not top), append it after a blank
    # line. The BOM, if any, is the first thing of line 1 and stays there.
    if [ "$state" = none ]; then append=1; fi
    LC_ALL=C TK_BOM=$bom TK_BLOCK=$block TK_APPEND=$append awk '
      BEGIN { blk = ENVIRON["TK_BLOCK"]; bom = ENVIRON["TK_BOM"]; app = ENVIRON["TK_APPEND"] }
      { line = $0; sub(/\r$/, "", line); pre = "" }
      NR == 1 && index(line, bom) == 1 { pre = bom; line = substr(line, length(bom) + 1) }
      line == "# >>> tmuxkeep" { printf "%s", pre; print blk; skip = 1; next }
      skip == 1 { if (line == "# <<< tmuxkeep") skip = 0; next }
      { print }
      END { if (app == "1") { if (NR > 0) print ""; print blk } }
    ' "$file" > "$tmp" || { rm -f "$tmp"; TK_ERR="$file: cannot read"; return 1; }
  fi
  # cmp: 0 identical, 1 differs, 2 or more is an error, which must not count as "differs".
  same=0
  cmp -s "$tmp" "$file" || same=$?
  case $same in
    0) rm -f "$tmp"; return 0 ;;
    1) ;;
    *) rm -f "$tmp"; TK_ERR="$file: cannot read"; return 1 ;;
  esac
  if ! cat "$tmp" > "$file"; then rm -f "$tmp"; TK_ERR="$file: cannot write"; return 1; fi
  rm -f "$tmp"
}

# ---- usage, tools, staging, the remote command, the admin-key help (spec 6.1, 6.5; plan Q4, Q11) ----
# The same steps, messages and exit codes as laptop/deploy.ps1. Streams (plan F17): every line that
# begins "deploy:" goes to stderr; the admin-key help is instructions and goes to stdout.

tk_usage() {
  printf '%s\n' 'usage: bash laptop/deploy.sh [--config <path>] [--init] [--harden-root] [--rotate-totp] [--unlock-otp]' >&2
}

# tk_missing_tools: prints the required tools that are not on PATH, joined by single spaces; nothing
# when all of them exist.
tk_missing_tools() {
  local t out=''
  for t in ssh scp ssh-keygen git; do
    if ! command -v "$t" >/dev/null; then out=${out:+$out }$t; fi
  done
  if [ -n "$out" ]; then printf '%s\n' "$out"; fi
}

# tk_version REPO: prints the short hash of HEAD, plus -dirty when the work tree has any change.
# Status 1 when git fails or prints no hash. --no-optional-locks keeps git status from trying to
# write the index of a read-only checkout.
tk_version() {
  local hash changes
  hash=$(git -C "$1" rev-parse --short HEAD) || return 1
  if [ -z "$hash" ]; then return 1; fi
  changes=$(git -C "$1" --no-optional-locks status --porcelain) || return 1
  if [ -n "$changes" ]; then hash=$hash-dirty; fi
  printf '%s\n' "$hash"
}

# tk_stage REPO VERSION PUBKEY DEST: builds the folder that is copied to the VPS (spec 6.1 step 4).
# Nothing is written unless every input is good; status 1 with TK_ERR set otherwise. Every staged
# file is written with LF. VERSION goes into a bash file, so only a git hash is allowed.
tk_stage() {
  local LC_ALL=C
  local repo=$1 version=$2 pub=$3 dest=$4 re f n
  TK_ERR=''
  re='^[0-9a-f]{4,40}(-dirty)?$'
  if ! [[ $version =~ $re ]]; then TK_ERR="version '$version' is not a git short hash"; return 1; fi
  for f in $TK_VPS_FILES; do
    if [ ! -f "$repo/vps/$f" ]; then TK_ERR="missing $repo/vps/$f"; return 1; fi
  done
  n=$(tr -d '\r' < "$repo/vps/tmuxkeep" | awk '$0 == "TMUXKEEP_VERSION=dev" { c++ } END { print c + 0 }')
  if [ "$n" != 1 ]; then
    TK_ERR="$repo/vps/tmuxkeep must contain exactly one TMUXKEEP_VERSION=dev line"; return 1
  fi
  if [ ! -f "$pub" ]; then TK_ERR="missing $pub"; return 1; fi
  if ! mkdir -p "$dest/systemd"; then TK_ERR="cannot create $dest"; return 1; fi
  for f in $TK_VPS_FILES; do
    if ! tr -d '\r' < "$repo/vps/$f" > "$dest/$f"; then TK_ERR="cannot write $dest/$f"; return 1; fi
  done
  if ! TK_V=$version awk '$0 == "TMUXKEEP_VERSION=dev" { print "TMUXKEEP_VERSION=" ENVIRON["TK_V"]; next } { print }' \
       "$dest/tmuxkeep" > "$dest/tmuxkeep.new" || ! mv "$dest/tmuxkeep.new" "$dest/tmuxkeep"; then
    TK_ERR="cannot write $dest/tmuxkeep"; return 1
  fi
  if ! tr -d '\r' < "$pub" > "$dest/laptop.pub"; then TK_ERR="cannot write $dest/laptop.pub"; return 1; fi
  if ! tk_deploy_conf_text > "$dest/deploy.conf"; then TK_ERR="cannot write $dest/deploy.conf"; return 1; fi
  return 0
}

# tk_setup_command STAGE HARDEN ROTATE UNLOCK: prints the one remote command (plan Q4); each flag
# is 0 or 1. The format is single-quoted, so $? and $rc stay literal for the remote shell. STAGE is
# interpolated into rm -rf, so it must be tmuxkeep-deploy-<14 digits>.
tk_setup_command() {
  local LC_ALL=C
  local re='^tmuxkeep-deploy-[0-9]{14}$' flags=''
  TK_ERR=''
  if ! [[ $1 =~ $re ]]; then TK_ERR="stage name '$1' is not tmuxkeep-deploy-<14 digits>"; return 1; fi
  if [ "$2" = 1 ]; then flags="$flags --harden-root"; fi
  if [ "$3" = 1 ]; then flags="$flags --rotate-totp"; fi
  if [ "$4" = 1 ]; then flags="$flags --unlock-otp"; fi
  printf 'bash /root/%s/tmuxkeep-setup --pubkey-file /root/%s/laptop.pub --key-id laptop --conf /root/%s/deploy.conf%s; rc=$?; rm -rf /root/%s; exit $rc\n' "$1" "$1" "$1" "$flags" "$1"
}

# tk_admin_help: prints the six lines that set up the admin key (spec 6.5, plan Q11), built from
# TKC_HOST, TKC_PORT and TKC_ADMIN_KEY; nothing here is executed. The ssh-keygen path is expanded
# here and wrapped in double quotes when it has a space. The public key goes into step 2 only when
# the file exists and its first line is a plain ssh-ed25519 line.
tk_admin_help() {
  local LC_ALL=C
  local admin shown pub line='' re cr=$'\r'
  admin=$(tk_expand_path "$TKC_ADMIN_KEY")
  shown=$admin
  case $admin in
    *' '*) shown="\"$admin\"" ;;
  esac
  pub="<contents of $TKC_ADMIN_KEY.pub>"
  re='^ssh-ed25519 [A-Za-z0-9+/=]+( [A-Za-z0-9@._-]+)?$'
  if [ -f "$admin.pub" ] && [ -r "$admin.pub" ]; then
    IFS= read -r line < "$admin.pub" || true
    line=${line%"$cr"}
    if [[ $line =~ $re ]]; then pub=$line; fi
  fi
  printf '%s\n' \
    "1. ssh-keygen -t ed25519 -f $shown -C tmuxkeep-admin        (set a passphrase)" \
    '2. Install it on the VPS with one password login:' \
    "   ssh root@$TKC_HOST -p $TKC_PORT \"mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && echo $pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys\"" \
    '3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true' \
    '' \
    'Never ssh-add the admin key and never set AddKeysToAgent for it.'
}

# tk_check_agent_options: asks "ssh -G tmuxkeep-admin" what the ssh config says for the admin alias.
# -G prints the settings and makes no connection. The answer must not let the admin key reach an
# agent or the macOS keychain, or its passphrase stops gating root (I1). Prints one "deploy:" line on
# stderr per problem and returns 1; returns 0 when the answer is clean. This is the one ssh here whose
# output is captured: it is not the installer and carries no secret. The block that tk_ssh_block
# writes at the top of the file normally passes; the check guards against an Include or an edited file.
tk_check_agent_options() {
  local out rc line agent='' keychain='' bad=0 cr=$'\r'
  out=$(ssh -G tmuxkeep-admin) || {
    rc=$?
    printf 'deploy: ssh -G tmuxkeep-admin failed with exit %s\n' "$rc" >&2
    return 1
  }
  while IFS= read -r line; do
    line=${line%"$cr"}
    case $line in
      'addkeystoagent '*) tk_trim "${line#addkeystoagent }"; agent=$TK_TRIMMED ;;
      'usekeychain '*) tk_trim "${line#usekeychain }"; keychain=$TK_TRIMMED ;;
    esac
  done <<< "$out"
  case $agent in
    ''|false|no) ;;
    *)
      printf '%s\n' "deploy: your ssh config loads keys into an agent for tmuxkeep-admin; put 'AddKeysToAgent no' under 'Host tmuxkeep-admin' before any 'Host *' block" >&2
      bad=1 ;;
  esac
  case $keychain in
    ''|false|no) ;;
    *)
      printf '%s\n' "deploy: your ssh config stores passphrases in the keychain for tmuxkeep-admin; put 'UseKeychain no' under 'Host tmuxkeep-admin' before any 'Host *' block" >&2
      bad=1 ;;
  esac
  [ "$bad" -eq 0 ]
}

# tk_install_dashboard REPO DEST: removes DEST and copies REPO/dashboard there without its test/
# folder (spec 5.3). DEST must end in /tmuxkeep/dashboard, so a wrong argument cannot remove anything
# else, and it must be neither a symbolic link nor the same physical folder as the source (a link in
# the path above it can make it so): nothing is removed in those cases. Status 1 with TK_ERR set on
# any failure. cp -R SRC/. DEST/ works with BSD and GNU cp.
tk_install_dashboard() {
  local src=$1/dashboard dest=$2 src_phys dest_phys
  TK_ERR=''
  case $dest in
    */tmuxkeep/dashboard) ;;
    *) TK_ERR="refusing to replace $dest: the folder must be .../tmuxkeep/dashboard"; return 1 ;;
  esac
  if [ ! -f "$src/server.js" ]; then TK_ERR="missing $src/server.js"; return 1; fi
  if [ -L "$dest" ]; then TK_ERR="refusing to replace $dest: it is a symbolic link"; return 1; fi
  if [ -d "$dest" ]; then
    src_phys=$(cd -P "$src" && pwd)
    dest_phys=$(cd -P "$dest" && pwd)
    if [ -n "$dest_phys" ] && [ "$dest_phys" = "$src_phys" ]; then
      TK_ERR="refusing to replace $dest: it is the same folder as the source $src"; return 1
    fi
  fi
  if ! rm -rf "$dest" || ! mkdir -p "$dest"; then TK_ERR="cannot create $dest"; return 1; fi
  if ! cp -R "$src/." "$dest/" || ! rm -rf "$dest/test"; then TK_ERR="cannot copy the dashboard to $dest"; return 1; fi
  return 0
}

# ---- the main sequence (spec 6.1 steps 0-9) ----

# tk_deploy_remote REPO KEY STAGE HARDEN ROTATE UNLOCK: steps 4-8. Works inside $TK_PARENT.
tk_deploy_remote() {
  local repo=$1 key=$2 stage=$3 version remote rc rcfile
  # 4. Stage.
  if ! version=$(tk_version "$repo"); then printf 'deploy: git failed in %s\n' "$repo" >&2; return 1; fi
  if ! tk_stage "$repo" "$version" "$key.pub" "$TK_PARENT/$stage"; then printf 'deploy: %s\n' "$TK_ERR" >&2; return 1; fi
  # 5. Copy over the admin path. A relative source, so no part of a local path is read as a host.
  (cd "$TK_PARENT" && scp -o PreferredAuthentications=publickey -r "$stage" "tmuxkeep-admin:/root/$stage")
  rc=$?
  if [ "$rc" -eq 255 ]; then
    printf '%s\n' 'deploy: the admin key was not accepted, or tmuxkeep-admin is unreachable. Set up the admin path once, then run deploy again.' >&2
    printf '%s\n' 'If you only mistyped the passphrase, run deploy again.' ''
    tk_admin_help
    return 1
  fi
  if [ "$rc" -ne 0 ]; then printf 'deploy: scp failed with exit %s\n' "$rc" >&2; return "$rc"; fi
  # 6. Install. A plain command: its output (the TOTP secret, once) goes straight to the terminal.
  # tk_setup_command runs in a subshell here, so its TK_ERR is lost; the message names the cause.
  remote=$(tk_setup_command "$stage" "$4" "$5" "$6") || {
    printf 'deploy: stage name %s is not tmuxkeep-deploy-<14 digits>\n' "$stage" >&2; return 1
  }
  ssh -o PreferredAuthentications=publickey tmuxkeep-admin "$remote"
  rc=$?
  if [ "$rc" -eq 255 ]; then
    # 255 is ssh itself failing (tmuxkeep-setup exits 0, 1 or 2), so nothing says how far setup got.
    printf 'deploy: ssh to tmuxkeep-admin failed (exit 255): wrong passphrase or the connection was lost. tmuxkeep-setup may not have run or may have stopped partway, /root/%s may remain on the VPS, and running deploy again is safe.\n' "$stage" >&2
    return 255
  fi
  if [ "$rc" -ne 0 ]; then printf 'deploy: tmuxkeep-setup failed with exit %s\n' "$rc" >&2; return "$rc"; fi
  # 7. The wrapper, the completion, the dashboard and the rc block.
  if ! mkdir -p "$HOME/.local/bin" "$HOME/.tmuxkeep"; then
    printf 'deploy: cannot install into %s\n' "$HOME" >&2; return 1
  fi
  if ! cp "$repo/laptop/tmuxkeep.sh" "$HOME/.local/bin/tmuxkeep" || ! chmod 0755 "$HOME/.local/bin/tmuxkeep"; then
    printf 'deploy: cannot install %s\n' "$HOME/.local/bin/tmuxkeep" >&2; return 1
  fi
  if ! cp "$repo/laptop/completion.bash" "$HOME/.tmuxkeep/completion.bash" || ! chmod 0644 "$HOME/.tmuxkeep/completion.bash"; then
    printf 'deploy: cannot install %s\n' "$HOME/.tmuxkeep/completion.bash" >&2; return 1
  fi
  if ! tk_install_dashboard "$repo" "$HOME/.local/share/tmuxkeep/dashboard"; then
    printf 'deploy: %s\n' "$TK_ERR" >&2; return 1
  fi
  rcfile=$(tk_rc_file)
  if ! tk_set_block "$rcfile" "$(tk_rc_block)"; then printf 'deploy: %s\n' "$TK_ERR" >&2; return 1; fi
  # 8. Proof of life.
  ssh -o BatchMode=yes tmuxkeep ls
  printf 'deploy: proof of life exit %s\n' "$?" >&2
}

# tk_deploy_main ARGS...: the whole operator command. Returns the exit status.
tk_deploy_main() {
  local config='' init=0 harden=0 rotate=0 unlock=0 repo missing key rc rcfile ts stage parent
  set -o pipefail
  umask 077
  while [ "$#" -gt 0 ]; do
    case $1 in
      --config)
        # A missing, empty or "--..." value is a usage error, as in tmuxkeep-setup --conf: it is the
        # next flag, not a file name.
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then tk_usage; return 2; fi
        case $2 in --*) tk_usage; return 2 ;; esac
        config=$2
        shift 2 ;;
      --init) init=1; shift ;;
      --harden-root) harden=1; shift ;;
      --rotate-totp) rotate=1; shift ;;
      --unlock-otp) unlock=1; shift ;;
      *) tk_usage; return 2 ;;
    esac
  done
  if [ -z "$config" ]; then config=$HOME/.tmuxkeep/config; fi
  repo=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd) || {
    printf 'deploy: cannot find the repository root from %s\n' "${BASH_SOURCE[0]}" >&2; return 2
  }

  # 0. Preflight: the tools, a git checkout, and a config that parses if it exists.
  missing=$(tk_missing_tools)
  if [ -n "$missing" ]; then printf 'deploy: missing required tools: %s\n' "$missing" >&2; return 2; fi
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null; then
    printf 'deploy: not a git checkout: %s\n' "$repo" >&2; return 2
  fi
  tk_conf_defaults
  if [ -e "$config" ]; then
    if ! tk_conf_read "$config"; then printf 'deploy: config %s\n' "$TK_ERR" >&2; return 2; fi
  fi

  # 1. Config: the one first-run question (spec 4.2).
  if [ ! -e "$config" ]; then
    if ! tk_conf_create "$config"; then printf 'deploy: config %s\n' "$TK_ERR" >&2; return 2; fi
    printf 'deploy: wrote %s\n' "$config" >&2
  fi

  # 2. The laptop key (no passphrase: the broker's TOTP code is the second factor).
  key=$(tk_expand_path "$TKC_KEY")
  if [ ! -e "$key" ]; then
    if ! mkdir -p -- "$(dirname -- "$key")"; then printf 'deploy: cannot create the folder of %s\n' "$key" >&2; return 1; fi
    ssh-keygen -t ed25519 -f "$key" -C tmuxkeep-laptop -N ''
    rc=$?
    if [ "$rc" -ne 0 ]; then printf 'deploy: ssh-keygen failed with exit %s\n' "$rc" >&2; return "$rc"; fi
  fi
  if [ ! -e "$key.pub" ]; then
    printf 'deploy: %s.pub is missing. Move %s aside and run deploy again to make a new pair.\n' "$key" "$key" >&2
    return 1
  fi

  # 3. Both Host blocks in ~/.ssh/config, written or replaced; a new block goes to the top of the file.
  if ! tk_set_block "$HOME/.ssh/config" "$(tk_ssh_block)" top; then printf 'deploy: %s\n' "$TK_ERR" >&2; return 1; fi

  # 3b. What the ssh config now says about agents for the admin alias, before any connection (I1).
  if ! tk_check_agent_options; then return 1; fi

  if [ "$init" -eq 1 ]; then
    printf '%s\n' 'deploy: init done: config, laptop key and ssh config are ready.' >&2
    printf '%s\n' 'Next, set up the admin key once:' ''
    tk_admin_help
    return 0
  fi

  # 4-8 in tk_deploy_remote. The staging folder is removed on every path below (step 9).
  ts=$(date +%Y%m%d%H%M%S)
  stage=tmuxkeep-deploy-$ts
  parent=${TMPDIR:-/tmp}
  while [ "${parent%/}" != "$parent" ]; do parent=${parent%/}; done
  TK_PARENT=$parent/tmuxkeep-stage-$ts
  if ! mkdir "$TK_PARENT"; then printf 'deploy: cannot create %s\n' "$TK_PARENT" >&2; return 1; fi
  trap 'rm -rf "$TK_PARENT"; exit 130' INT TERM HUP
  tk_deploy_remote "$repo" "$key" "$stage" "$harden" "$rotate" "$unlock"
  rc=$?

  # 9. Remove the local staging folder.
  rm -rf "$TK_PARENT"
  trap - INT TERM HUP
  if [ "$rc" -eq 0 ]; then
    rcfile=$(tk_rc_file)
    printf 'dashboard: installed at %s (run: tmuxkeep ui)\n' "$HOME/.local/share/tmuxkeep/dashboard" >&2
    printf 'deploy: done. Open a new terminal, or run: . %s\n' "$rcfile" >&2
  fi
  return "$rc"
}

[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0
tk_deploy_main "$@"
exit $?
