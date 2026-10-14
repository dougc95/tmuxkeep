#!/usr/bin/env bats
# laptop/deploy.sh main sequence (spec 6.1, 6.4, 6.5, 9.2, 12; plan Q4, Q11, Q12). It runs as a
# child process from a temporary git copy of laptop/ and vps/, with stub ssh, scp and ssh-keygen
# first on PATH and HOME in a temp directory. Never against a real host.
# Streams (plan F17): every line that begins "deploy:" is on stderr; the admin-key help is
# instructions and is on stdout.
load laptop-helpers

setup() {
  laptop_setup
  R=$(mk_repo_copy)
  CFG="$HOME/.tmuxkeep/config"
  mkdir -p "$HOME/.tmuxkeep" "$BATS_TEST_TMPDIR/scp"
  cp "$REPO/tests/fixtures/laptop-config" "$CFG"
  export TK_STUB_SCP_DEST="$BATS_TEST_TMPDIR/scp"
}

deploy() { "$BASH" "$R/laptop/deploy.sh" "$@"; }
stage_dirs() { find "$TMPDIR" -maxdepth 1 -name 'tmuxkeep-stage-*'; }

@test "an unknown flag is usage (2) and runs nothing" {
  run --separate-stderr deploy --frob
  [ "$status" -eq 2 ]
  [ "$stderr" = 'usage: bash laptop/deploy.sh [--config <path>] [--init] [--harden-root] [--rotate-totp] [--unlock-otp]' ]
  [ -z "$output" ]
  [ ! -s "$TK_STUB_LOG" ]
  # --config without its value is usage too, and so is an empty value.
  run --separate-stderr deploy --config
  [ "$status" -eq 2 ]
  [[ "$stderr" == 'usage: bash laptop/deploy.sh '* ]]
  run --separate-stderr deploy --config ''
  [ "$status" -eq 2 ]
  [[ "$stderr" == 'usage: bash laptop/deploy.sh '* ]]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "a --config value that starts with -- is a usage error (2), as in the installer, and runs nothing" {
  local v
  for v in --init --harden-root --rotate-totp --unlock-otp --config --frob; do
    run --separate-stderr deploy --config "$v"
    [ "$status" -eq 2 ] || { echo "$v: $status"; return 1; }
    [ "$stderr" = 'usage: bash laptop/deploy.sh [--config <path>] [--init] [--harden-root] [--rotate-totp] [--unlock-otp]' ] || { echo "$v: $stderr"; return 1; }
    [ -z "$output" ]
  done
  # Not even at the end of the line after another flag.
  run --separate-stderr deploy --init --config --harden-root
  [ "$status" -eq 2 ]
  [[ "$stderr" == 'usage: bash laptop/deploy.sh '* ]]
  [ ! -s "$TK_STUB_LOG" ]
  [ ! -e "$HOME/.ssh/config" ]
}

@test "a --config value with one leading dash, or a path, is still a file name" {
  cp "$CFG" "$BATS_TEST_TMPDIR/-x.conf"
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr deploy --config -x.conf --init
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  run --separate-stderr deploy --config "$CFG" --init
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
}

@test "full run: keygen, ssh -G, scp, the setup ssh and the proof of life, in order, with the exact arguments" {
  local scp stage
  run --separate-stderr deploy
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(stub_calls | grep -c .)" -eq 5 ]
  [ "$(stub_calls | sed -n 1p)" = "ssh-keygen [-t] [ed25519] [-f] [$HOME/.ssh/id_tmuxkeep_ed25519] [-C] [tmuxkeep-laptop] [-N] []" ]
  [ "$(stub_calls | sed -n 2p)" = 'ssh [-G] [tmuxkeep-admin]' ]
  scp=$(stub_calls | sed -n 3p)
  stage=$(printf '%s\n' "$scp" | sed -n 's/^scp \[-o\] \[PreferredAuthentications=publickey\] \[-r\] \[\(tmuxkeep-deploy-[0-9]\{14\}\)\] \[tmuxkeep-admin:\/root\/tmuxkeep-deploy-[0-9]\{14\}\]$/\1/p')
  [ -n "$stage" ] || { echo "$scp"; return 1; }
  [ "$(stub_calls | sed -n 4p)" = "ssh [-o] [PreferredAuthentications=publickey] [tmuxkeep-admin] [bash /root/$stage/tmuxkeep-setup --pubkey-file /root/$stage/laptop.pub --key-id laptop --conf /root/$stage/deploy.conf; rc=\$?; rm -rf /root/$stage; exit \$rc]" ]
  [ "$(stub_calls | sed -n 5p)" = 'ssh [-o] [BatchMode=yes] [tmuxkeep] [ls]' ]
  [[ "$stderr" == *'deploy: proof of life exit 0'* ]]
  [[ "$stderr" == *'deploy: done.'* ]]
  [[ "$output" != *'deploy:'* ]]
}

@test "stages the eight VPS files, laptop.pub and deploy.conf with LF, then removes the staging folder" {
  local d
  run deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  d=$(find "$BATS_TEST_TMPDIR/scp" -mindepth 1 -maxdepth 1 -type d -name 'tmuxkeep-deploy-*')
  [ -n "$d" ]
  [ "$(cd "$d" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')" = 'deploy.conf laptop.pub sshd.conf.tmpl sudoers.tmpl systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer tmux.conf tmuxkeep tmuxkeep-setup vps-facts.sh ' ]
  cmp "$d/deploy.conf" "$REPO/tests/fixtures/deploy.conf"
  cmp "$d/laptop.pub" "$HOME/.ssh/id_tmuxkeep_ed25519.pub"
  grep -qx "TMUXKEEP_VERSION=$(git -C "$R" rev-parse --short HEAD)" "$d/tmuxkeep"
  [ "$(cat "$d"/* "$d"/systemd/* | tr -cd '\r' | wc -c | tr -d ' ')" = 0 ]
  [ -z "$(stage_dirs)" ]
}

@test "installs the wrapper, the completion and the rc block, and writes the ssh config block" {
  run deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cmp "$HOME/.local/bin/tmuxkeep" "$REPO/laptop/tmuxkeep.sh"
  [ -x "$HOME/.local/bin/tmuxkeep" ]
  cmp "$HOME/.tmuxkeep/completion.bash" "$REPO/laptop/completion.bash"
  grep -qx '# >>> tmuxkeep' "$HOME/.bashrc"
  cmp "$HOME/.ssh/config" "$REPO/tests/fixtures/ssh-block"
  cmp "$HOME/.local/share/tmuxkeep/dashboard/server.js" "$REPO/dashboard/server.js"
  [ -f "$HOME/.local/share/tmuxkeep/dashboard/public/app.js" ]
  [ ! -e "$HOME/.local/share/tmuxkeep/dashboard/test" ]
}

@test "an existing ssh config gets the block at the top, an existing rc file gets it at the end, and a second deploy replaces both in place" {
  mkdir -p "$HOME/.ssh"
  printf 'Host old\n    User me\n' > "$HOME/.ssh/config"
  printf 'export EXISTING=1\n' > "$HOME/.bashrc"
  run deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sed -n 1p "$HOME/.ssh/config")" = '# >>> tmuxkeep' ]
  [ "$(tail -n 2 "$HOME/.ssh/config" | sed -n 1p)" = 'Host old' ]
  [ "$(tail -n 1 "$HOME/.ssh/config")" = '    User me' ]
  [ "$(sed -n 1p "$HOME/.bashrc")" = 'export EXISTING=1' ]
  [ "$(tail -n 1 "$HOME/.bashrc")" = '# <<< tmuxkeep' ]
  cp "$HOME/.ssh/config" "$BATS_TEST_TMPDIR/ssh-config.1"
  cp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc.1"
  run deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  cmp "$HOME/.ssh/config" "$BATS_TEST_TMPDIR/ssh-config.1"
  cmp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc.1"
}

@test "with SHELL ending in zsh the rc block goes into ~/.zshrc" {
  export SHELL=/bin/zsh
  run deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx '# >>> tmuxkeep' "$HOME/.zshrc"
  [ ! -e "$HOME/.bashrc" ]
}

@test "--init stops after step 3 and prints the admin-key steps; no scp and no ssh except the ssh -G check" {
  run --separate-stderr deploy --init
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(stub_calls | grep -c .)" -eq 2 ]
  [[ "$(stub_calls | sed -n 1p)" == 'ssh-keygen '* ]]
  [ "$(stub_calls | sed -n 2p)" = 'ssh [-G] [tmuxkeep-admin]' ]
  cmp "$HOME/.ssh/config" "$REPO/tests/fixtures/ssh-block"
  [ ! -e "$HOME/.local/bin/tmuxkeep" ]
  [ "$stderr" = 'deploy: init done: config, laptop key and ssh config are ready.' ]
  [[ "$output" == 'Next, set up the admin key once:'* ]]
  [[ "$output" == *'3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true'* ]]
  [[ "$output" != *'deploy:'* ]]
}

@test "an existing laptop key is not generated again" {
  mkdir -p "$HOME/.ssh"
  printf 'k\n' > "$HOME/.ssh/id_tmuxkeep_ed25519"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExisting tmuxkeep-laptop\n' > "$HOME/.ssh/id_tmuxkeep_ed25519.pub"
  run deploy --init
  [ "$status" -eq 0 ]
  [ "$(stub_calls)" = 'ssh [-G] [tmuxkeep-admin]' ]
}

@test "--config selects the file; a missing one with no terminal stops at the prompt with HOST required" {
  run --separate-stderr deploy --config "$BATS_TEST_TMPDIR/none/config" --init
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"deploy: config $BATS_TEST_TMPDIR/none/config: HOST: required"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/none/config" ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "the flags reach the installer in a fixed order" {
  run deploy --unlock-otp --harden-root --rotate-totp
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$(stub_calls | sed -n 4p)" == *'/deploy.conf --harden-root --rotate-totp --unlock-otp; rc='* ]]
}

@test "scp exit 255 prints the admin-key help built from the config and stops with exit 1" {
  export TK_STUB_SCP_RC=255
  run --separate-stderr deploy
  [ "$status" -eq 1 ]
  # The deploy: line is on stderr; the instructions are on stdout.
  [ "$stderr" = 'deploy: the admin key was not accepted, or tmuxkeep-admin is unreachable. Set up the admin path once, then run deploy again.' ]
  [[ "$output" == *'If you only mistyped the passphrase, run deploy again.'* ]]
  [[ "$output" == *'ssh root@203.0.113.10 -p 22 "mkdir -p ~/.ssh'* ]]
  [[ "$output" == *'Never ssh-add the admin key and never set AddKeysToAgent for it.' ]]
  [[ "$output" != *'deploy:'* ]]
  [ "$(stub_calls | grep -c '^ssh ')" -eq 1 ]
  [ "$(stub_calls | grep '^ssh ')" = 'ssh [-G] [tmuxkeep-admin]' ]
  [ -z "$(stage_dirs)" ]
}

@test "another scp failure is reported with its code" {
  export TK_STUB_SCP_RC=1
  run --separate-stderr deploy
  [ "$status" -eq 1 ]
  [ "$stderr" = 'deploy: scp failed with exit 1' ]
}

@test "a failing installer stops before the wrapper is installed" {
  export TK_STUB_SSH_RC=3
  run --separate-stderr deploy
  [ "$status" -eq 3 ]
  [ "$stderr" = 'deploy: tmuxkeep-setup failed with exit 3' ]
  [ ! -e "$HOME/.local/bin/tmuxkeep" ]
  [ -z "$(stage_dirs)" ]
}

@test "an ssh exit 255 from the setup step explains itself and exits 255" {
  export TK_STUB_SSH_RC=255
  run --separate-stderr deploy
  [ "$status" -eq 255 ]
  [[ "$stderr" == 'deploy: ssh to tmuxkeep-admin failed (exit 255)'* ]]
}

@test "an invalid config stops with exit 2, naming the key, before any tool runs" {
  printf 'PORT=0\n' >> "$CFG"
  run --separate-stderr deploy
  [ "$status" -eq 2 ]
  [ "$stderr" = "deploy: config $CFG: PORT: must be an integer from 1 to 65535" ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "preflight: missing tools are named, and a copy without .git is not a checkout (2)" {
  run env PATH="$BATS_TEST_TMPDIR/empty" "$BASH" -c ". '$R/laptop/deploy.sh'; tk_missing_tools"
  [ "$output" = 'ssh scp ssh-keygen git' ]
  rm -rf "$R/.git"
  run --separate-stderr deploy
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"deploy: not a git checkout: $R"* ]]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "the setup ssh is a plain command, never captured, and nothing calls ssh-add (G3)" {
  [ "$(grep -c 'tmuxkeep-admin "$remote"' "$REPO/laptop/deploy.sh")" -eq 1 ]
  grep -qx '  ssh -o PreferredAuthentications=publickey tmuxkeep-admin "$remote"' "$REPO/laptop/deploy.sh"
  grep -qx '  ssh -o BatchMode=yes tmuxkeep ls' "$REPO/laptop/deploy.sh"
  run grep -nE '^[[:space:]]*ssh-add([[:space:]]|$)' "$REPO/laptop/deploy.sh" "$REPO/laptop/tmuxkeep.sh"
  [ "$status" -eq 1 ]
  # AddKeysToAgent appears in exactly three lines: the help sentence, the block line, the refusal.
  local a
  a=$(grep AddKeysToAgent "$REPO/laptop/deploy.sh")
  [ "$(printf '%s\n' "$a" | grep -c .)" -eq 3 ]
  [ "$(printf '%s\n' "$a" | grep -cF "'Never ssh-add the admin key and never set AddKeysToAgent for it.'")" -eq 1 ]
  [ "$(printf '%s\n' "$a" | grep -cxF "    '    AddKeysToAgent no' \\")" -eq 1 ]
  [ "$(printf '%s\n' "$a" | grep -cF "put 'AddKeysToAgent no' under 'Host tmuxkeep-admin' before any 'Host *' block")" -eq 1 ]
  # The ssh -G check is the one captured ssh; the setup and proof-of-life ssh stay plain (above).
  [ "$(grep -cE '^  out=\$\(ssh -G tmuxkeep-admin\) \|\| ' "$REPO/laptop/deploy.sh")" -eq 1 ]
  # No stderr redirection of any kind in the script (G23).
  [ "$(grep -c '2>' "$REPO/laptop/deploy.sh")" -eq 0 ]
}

@test "the admin help (spec 6.5) is built from the config" {
  # shellcheck source=/dev/null
  source "$REPO/laptop/deploy.sh"
  tk_conf_defaults
  TKC_HOST=198.51.100.20
  TKC_PORT=2222
  run tk_admin_help
  [ "$output" = "$(printf '%s\n' \
    "1. ssh-keygen -t ed25519 -f $HOME/.ssh/id_tmuxkeep_admin_ed25519 -C tmuxkeep-admin        (set a passphrase)" \
    '2. Install it on the VPS with one password login:' \
    '   ssh root@198.51.100.20 -p 2222 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && echo <contents of ~/.ssh/id_tmuxkeep_admin_ed25519.pub> >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"' \
    '3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true' \
    '' \
    'Never ssh-add the admin key and never set AddKeysToAgent for it.')" ]
  [[ "$output" != *203.0.113.10* ]]
  mkdir -p "$HOME/.ssh"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdmin tmuxkeep-admin\n' > "$HOME/.ssh/id_tmuxkeep_admin_ed25519.pub"
  run tk_admin_help
  [[ "$output" == *'&& echo ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdmin tmuxkeep-admin >> ~/.ssh/authorized_keys'* ]]
  printf 'ssh-ed25519 AAAA $(reboot)\n' > "$HOME/.ssh/id_tmuxkeep_admin_ed25519.pub"
  run tk_admin_help
  [[ "$output" == *'echo <contents of ~/.ssh/id_tmuxkeep_admin_ed25519.pub> >>'* ]]
  HOME="$BATS_TEST_TMPDIR/my home"
  run tk_admin_help
  [[ "${lines[0]}" == "1. ssh-keygen -t ed25519 -f \"$BATS_TEST_TMPDIR/my home/.ssh/id_tmuxkeep_admin_ed25519\" -C tmuxkeep-admin"* ]]
}

@test "tk_setup_command builds the spec 6.1 command (plan Q4) and refuses a bad stage name" {
  # shellcheck source=/dev/null
  source "$REPO/laptop/deploy.sh"
  [ "$(tk_setup_command tmuxkeep-deploy-20261012120000 0 0 0)" = 'bash /root/tmuxkeep-deploy-20261012120000/tmuxkeep-setup --pubkey-file /root/tmuxkeep-deploy-20261012120000/laptop.pub --key-id laptop --conf /root/tmuxkeep-deploy-20261012120000/deploy.conf; rc=$?; rm -rf /root/tmuxkeep-deploy-20261012120000; exit $rc' ]
  [[ "$(tk_setup_command tmuxkeep-deploy-20261012120000 1 1 1)" == *'/deploy.conf --harden-root --rotate-totp --unlock-otp; rc='* ]]
  run tk_setup_command 'x; rm -rf /' 0 0 0
  [ "$status" -ne 0 ]
  run tk_setup_command tmuxkeep-deploy-123 0 0 0
  [ "$status" -ne 0 ]
}

@test "tk_stage writes nothing for a bad version or a broker without exactly one version line" {
  # shellcheck source=/dev/null
  source "$REPO/laptop/deploy.sh"
  tk_conf_defaults
  TKC_HOST=203.0.113.10
  printf 'ssh-ed25519 AAAA x\n' > "$BATS_TEST_TMPDIR/k.pub"
  run tk_stage "$R" 'abc; rm -rf /' "$BATS_TEST_TMPDIR/k.pub" "$BATS_TEST_TMPDIR/s1"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/s1" ]
  sed 's/^TMUXKEEP_VERSION=dev$/TMUXKEEP_VERSION=other/' "$R/vps/tmuxkeep" > "$BATS_TEST_TMPDIR/b"
  cat "$BATS_TEST_TMPDIR/b" > "$R/vps/tmuxkeep"
  run tk_stage "$R" abc1234 "$BATS_TEST_TMPDIR/k.pub" "$BATS_TEST_TMPDIR/s2"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/s2" ]
}

@test "the staged file list is the one agreed line" {
  grep -qx 'TK_VPS_FILES="tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer"' "$REPO/laptop/deploy.sh"
}

# I1: whatever the user's own ssh config says, the admin key must not reach an agent. Deploy asks
# "ssh -G tmuxkeep-admin" (it reads the config and connects to nothing; the stub answers it) after it
# has written the block and before it connects anywhere.

MSG_AGENT="deploy: your ssh config loads keys into an agent for tmuxkeep-admin; put 'AddKeysToAgent no' under 'Host tmuxkeep-admin' before any 'Host *' block"
MSG_KEYCHAIN="deploy: your ssh config stores passphrases in the keychain for tmuxkeep-admin; put 'UseKeychain no' under 'Host tmuxkeep-admin' before any 'Host *' block"

# g_answer LINE...: the text the stub answers to ssh -G, one LINE per argument.
g_answer() {
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/ssh-g"
  export TK_STUB_SSH_G="$BATS_TEST_TMPDIR/ssh-g"
}

@test "ssh -G answering addkeystoagent false (or no) and usekeychain no passes: the run goes on to the VPS" {
  g_answer 'host tmuxkeep-admin' 'hostname 203.0.113.10' 'addkeystoagent false' 'usekeychain no' 'identitiesonly true'
  run --separate-stderr deploy
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(stub_calls | grep -c '^scp ')" -eq 1 ]
  g_answer 'addkeystoagent no'
  run --separate-stderr deploy
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
}

@test "ssh -G answering addkeystoagent yes (or true, ask, confirm) is refused with exit 1 before any connection" {
  local v
  for v in yes true ask confirm; do
    : > "$TK_STUB_LOG"
    g_answer 'host tmuxkeep-admin' "addkeystoagent $v" 'usekeychain no'
    run --separate-stderr deploy
    [ "$status" -eq 1 ] || { echo "$v: $status $stderr"; return 1; }
    [ "$stderr" = "$MSG_AGENT" ] || { echo "$v: $stderr"; return 1; }
    [ -z "$output" ]
    [ "$(stub_calls | grep -c '^scp ')" -eq 0 ]
    [ "$(stub_calls | grep -c '^ssh ')" -eq 1 ]
    [ ! -e "$HOME/.local/bin/tmuxkeep" ]
    [ -z "$(stage_dirs)" ]
  done
}

@test "ssh -G answering usekeychain yes is refused with exit 1 before any connection" {
  g_answer 'host tmuxkeep-admin' 'addkeystoagent false' 'usekeychain yes'
  run --separate-stderr deploy
  [ "$status" -eq 1 ]
  [ "$stderr" = "$MSG_KEYCHAIN" ]
  [ -z "$output" ]
  [ "$(stub_calls | grep -c '^scp ')" -eq 0 ]
  [ "$(stub_calls | grep -c '^ssh ')" -eq 1 ]
  [ ! -e "$HOME/.local/bin/tmuxkeep" ]
}

@test "both problems are named, one deploy: line each" {
  g_answer 'addkeystoagent yes' 'usekeychain yes'
  run --separate-stderr deploy
  [ "$status" -eq 1 ]
  [ "$stderr" = "$MSG_AGENT
$MSG_KEYCHAIN" ]
}

@test "--init is refused too: the check comes before --init returns" {
  g_answer 'addkeystoagent yes'
  run --separate-stderr deploy --init
  [ "$status" -eq 1 ]
  [ "$stderr" = "$MSG_AGENT" ]
  [ -z "$output" ]
}

@test "an ssh -G that fails stops the deploy and names its exit code" {
  export TK_STUB_SSH_G_RC=255
  run --separate-stderr deploy
  [ "$status" -eq 1 ]
  [ "$stderr" = 'deploy: ssh -G tmuxkeep-admin failed with exit 255' ]
  [ "$(stub_calls | grep -c '^scp ')" -eq 0 ]
}

@test "the agent check reads only the addkeystoagent and usekeychain lines, whatever else ssh -G prints" {
  g_answer 'identityfile ~/.ssh/addkeystoagent yes' 'hostname usekeychain' 'xaddkeystoagent yes' 'addkeystoagent false' 'usekeychain no'
  run --separate-stderr deploy --init
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
}

@test "a CR at the end of the ssh -G lines is ignored" {
  printf 'addkeystoagent false\r\nusekeychain no\r\n' > "$BATS_TEST_TMPDIR/ssh-g"
  export TK_STUB_SSH_G="$BATS_TEST_TMPDIR/ssh-g"
  run --separate-stderr deploy --init
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
}

@test "the dashboard is replaced on every deploy, its place is printed, and a failing installer leaves it alone" {
  local dash="$HOME/.local/share/tmuxkeep/dashboard"
  mkdir -p "$dash"
  printf 'old\n' > "$dash/stale.js"
  export TK_STUB_SSH_RC=3
  run --separate-stderr deploy
  [ "$status" -eq 3 ]
  [ -f "$dash/stale.js" ]
  [[ "$stderr" != *'dashboard: installed'* ]]
  unset TK_STUB_SSH_RC
  run --separate-stderr deploy
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ ! -e "$dash/stale.js" ]
  [ -f "$dash/server.js" ]
  [[ "$stderr" == *"dashboard: installed at $dash (run: tmuxkeep ui)"* ]]
  [[ "$output" != *'dashboard:'* ]]
}

@test "tk_install_dashboard refuses a folder that is not .../tmuxkeep/dashboard and touches nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/precious"
  printf 'keep\n' > "$BATS_TEST_TMPDIR/precious/keep.txt"
  run "$BASH" -c '. "$1"; tk_install_dashboard "$2" "$3" || { printf "%s\n" "$TK_ERR"; exit 1; }' _ "$R/laptop/deploy.sh" "$R" "$BATS_TEST_TMPDIR/precious"
  [ "$status" -eq 1 ]
  [ "$output" = "refusing to replace $BATS_TEST_TMPDIR/precious: the folder must be .../tmuxkeep/dashboard" ]
  [ -f "$BATS_TEST_TMPDIR/precious/keep.txt" ]
}
