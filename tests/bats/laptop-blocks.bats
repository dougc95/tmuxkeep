#!/usr/bin/env bats
# laptop/deploy.sh marked blocks (spec 6.1 step 3, 6.4, 12; plan Q3, Q10; Review Focus 3 and 4):
# ~/.ssh/config and the shell rc file, write-or-replace, symlinks kept, zsh without compinit.
load laptop-helpers

setup() {
  laptop_setup
  # shellcheck source=/dev/null
  source "$REPO/laptop/deploy.sh"
  tk_conf_defaults
  TKC_HOST=203.0.113.10
  F="$HOME/.ssh/config"
  mkdir -p "$HOME/.ssh"
  BLOCK3=$(printf '%s\n' '# >>> tmuxkeep' 'line one' '# <<< tmuxkeep')
}

teardown() {
  [ -z "${TK_PROBE_DIR-}" ] || rm -rf "$TK_PROBE_DIR"
}

# stub_tool NAME: a stub NAME first on PATH for the rest of the test; the script is read from stdin.
stub_tool() {
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  cat > "$BATS_TEST_TMPDIR/stubs/$1"
  chmod +x "$BATS_TEST_TMPDIR/stubs/$1"
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
}

# no_temp_left: the private TMPDIR holds no leftover temporary file.
no_temp_left() {
  [ -z "$(ls "$TMPDIR")" ]
}

@test "tk_ssh_block is the fixture for the default config" {
  tk_ssh_block > "$BATS_TEST_TMPDIR/b"
  cmp "$BATS_TEST_TMPDIR/b" "$REPO/tests/fixtures/ssh-block"
}

@test "tk_ssh_block takes HOST, PORT, USER and both keys from the config, quoting a path with a space (plan Q10)" {
  TKC_HOST=2001:db8::5
  TKC_PORT=2222
  TKC_USER=bob
  TKC_KEY='~/my keys/k'
  TKC_ADMIN_KEY=/keys/admin
  run tk_ssh_block
  [ "${#lines[@]}" -eq 18 ]
  [ "${lines[2]}" = '    HostName 2001:db8::5' ]
  [ "${lines[3]}" = '    Port 2222' ]
  [ "${lines[4]}" = '    User bob' ]
  [ "${lines[5]}" = '    IdentityFile "~/my keys/k"' ]
  [ "${lines[12]}" = '    User root' ]
  [ "${lines[13]}" = '    IdentityFile /keys/admin' ]
}

@test "tk_ssh_block pins AddKeysToAgent no under Host tmuxkeep-admin only, has no UseKeychain or IgnoreUnknown, and ends with Host * (I1)" {
  run tk_ssh_block
  [ "${lines[9]}" = 'Host tmuxkeep-admin' ]
  [ "${lines[14]}" = '    IdentitiesOnly yes' ]
  [ "${lines[15]}" = '    AddKeysToAgent no' ]
  # Host * hands global scope back to whatever follows the block; the options above still come first.
  [ "${lines[16]}" = 'Host *' ]
  [ "${lines[17]}" = '# <<< tmuxkeep' ]
  [ "$(printf '%s\n' "$output" | grep -c AddKeysToAgent)" -eq 1 ]
  # An OpenSSH without UseKeychain rejects the whole config for the keyword, in any section.
  [ "$(printf '%s\n' "$output" | grep -ci 'UseKeychain\|IgnoreUnknown')" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^Host ')" -eq 3 ]
}

@test "creates a missing file and its folder, with a final newline" {
  tk_set_block "$BATS_TEST_TMPDIR/new dir/f" "$BLOCK3"
  [ "$(cat "$BATS_TEST_TMPDIR/new dir/f")" = "$BLOCK3" ]
  [ "$(tail -c 1 "$BATS_TEST_TMPDIR/new dir/f" | od -An -tx1 | tr -d ' ')" = 0a ]
}

@test "appends after a blank line, adding a missing final newline first (the default: profile and rc files)" {
  printf 'Host x\n    HostName 198.51.100.20' > "$F"
  tk_set_block "$F" "$BLOCK3"
  [ "$(cat "$F")" = "$(printf 'Host x\n    HostName 198.51.100.20\n\n%s' "$BLOCK3")" ]
  # An unknown third argument is not "top".
  printf 'Host x\n' > "$F"
  tk_set_block "$F" "$BLOCK3" bottom
  [ "$(cat "$F")" = "$(printf 'Host x\n\n%s' "$BLOCK3")" ]
}

@test "a BOM-prefixed file keeps the BOM at byte 0 when a block is appended" {
  printf '\357\273\277Host x\n' > "$F"
  tk_set_block "$F" "$BLOCK3"
  printf '\357\273\277Host x\n\n# >>> tmuxkeep\nline one\n# <<< tmuxkeep\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  # The block sits at the end, so a second call replaces it there.
  tk_set_block "$F" "$BLOCK3"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
}

@test "top: a new block goes to the top: the block, one empty line, then the previous content byte for byte (I1)" {
  printf 'Host x\n    HostName 198.51.100.20' > "$F"
  tk_set_block "$F" "$BLOCK3" top
  printf '# >>> tmuxkeep\nline one\n# <<< tmuxkeep\n\nHost x\n    HostName 198.51.100.20' > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  # CRLF content, blank lines and a missing final newline all survive unchanged below the block.
  printf 'Host y\r\n\r\n    User z\r\n' > "$F"
  tk_set_block "$F" "$BLOCK3" top
  printf '# >>> tmuxkeep\nline one\n# <<< tmuxkeep\n\nHost y\r\n\r\n    User z\r\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
}

@test "top: a missing or empty file becomes the block alone, with no empty line after it" {
  : > "$F"
  tk_set_block "$F" "$BLOCK3" top
  printf '# >>> tmuxkeep\nline one\n# <<< tmuxkeep\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  rm -f "$F"
  tk_set_block "$F" "$BLOCK3" top
  cmp "$F" "$BATS_TEST_TMPDIR/want"
}

@test "top: a new block goes right after a leading UTF-8 BOM, never above it: BOM, block, one empty line, then the former first line" {
  # A BOM in the middle of the file would make the user's first line an unknown keyword to OpenSSH.
  printf '\357\273\277Host x' > "$F"
  tk_set_block "$F" "$BLOCK3" top
  printf '\357\273\277# >>> tmuxkeep\nline one\n# <<< tmuxkeep\n\nHost x' > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  # The marker after the BOM is recognised on the next run: nothing changes, and a changed block is
  # replaced in place with the BOM kept at byte 0.
  printf '\357\273\277Host x\n' > "$F"
  tk_set_block "$F" "$BLOCK3" top
  printf '\357\273\277# >>> tmuxkeep\nline one\n# <<< tmuxkeep\n\nHost x\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  tk_set_block "$F" "$BLOCK3" top
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  tk_set_block "$F" "$(printf '%s\n' '# >>> tmuxkeep' 'line two' '# <<< tmuxkeep')" top
  printf '\357\273\277# >>> tmuxkeep\nline two\n# <<< tmuxkeep\n\nHost x\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  # CRLF content after the BOM is kept byte for byte.
  printf '\357\273\277Host y\r\n    User z\r\n' > "$F"
  tk_set_block "$F" "$BLOCK3" top
  printf '\357\273\277# >>> tmuxkeep\nline one\n# <<< tmuxkeep\n\nHost y\r\n    User z\r\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  # A file that is only the BOM becomes BOM + block, with no empty line after it.
  printf '\357\273\277' > "$F"
  tk_set_block "$F" "$BLOCK3" top
  printf '\357\273\277# >>> tmuxkeep\nline one\n# <<< tmuxkeep\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
}

@test "a block that is already there is replaced where it is, whatever the placement" {
  printf 'first\n# >>> tmuxkeep\nold\n# <<< tmuxkeep\nlast\n' > "$F"
  tk_set_block "$F" "$BLOCK3" top
  printf 'first\n# >>> tmuxkeep\nline one\n# <<< tmuxkeep\nlast\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  # A second call with the same text changes nothing, with or without top.
  tk_set_block "$F" "$BLOCK3" top
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  tk_set_block "$F" "$BLOCK3"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
}

@test "top: a symlinked file gets the new block at the top and stays a symlink" {
  mkdir -p "$HOME/dotfiles"
  printf 'Host other\n' > "$HOME/dotfiles/ssh_config"
  ln -s "$HOME/dotfiles/ssh_config" "$F"
  tk_set_block "$F" "$BLOCK3" top
  [ -L "$F" ]
  printf '# >>> tmuxkeep\nline one\n# <<< tmuxkeep\n\nHost other\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$HOME/dotfiles/ssh_config" "$BATS_TEST_TMPDIR/want"
}

@test "replaces a changed block in place and keeps the lines around it" {
  printf 'top\n# >>> tmuxkeep\nold\n# <<< tmuxkeep\nbottom\n' > "$F"
  tk_set_block "$F" "$BLOCK3"
  [ "$(cat "$F")" = "$(printf 'top\n%s\nbottom' "$BLOCK3")" ]
}

@test "leaves a file with an identical block untouched" {
  printf 'x\n\n%s\n' "$BLOCK3" > "$F"
  touch -t 200101010000 "$F" "$BATS_TEST_TMPDIR/ref"
  tk_set_block "$F" "$BLOCK3"
  [ ! "$F" -nt "$BATS_TEST_TMPDIR/ref" ]
}

@test "refuses two begin markers, or a begin without an end, and leaves the file untouched" {
  printf '# >>> tmuxkeep\n1\n# <<< tmuxkeep\n# >>> tmuxkeep\n2\n# <<< tmuxkeep\n' > "$F"
  cp "$F" "$BATS_TEST_TMPDIR/before"
  run tk_set_block "$F" "$BLOCK3"
  [ "$status" -ne 0 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
  printf 'x\n# >>> tmuxkeep\nold\n' > "$F"
  cp "$F" "$BATS_TEST_TMPDIR/before"
  run tk_set_block "$F" "$BLOCK3"
  [ "$status" -ne 0 ]
  cmp "$F" "$BATS_TEST_TMPDIR/before"
}

@test "a longer marker such as the VPS PATH block is not taken for ours" {
  printf '# >>> tmuxkeep path\nx\n# <<< tmuxkeep path\n' > "$F"
  tk_set_block "$F" "$BLOCK3"
  [ "$(cat "$F")" = "$(printf '# >>> tmuxkeep path\nx\n# <<< tmuxkeep path\n\n%s' "$BLOCK3")" ]
  printf '# >>> tmuxkeep path\nx\n# <<< tmuxkeep path\n' > "$F"
  tk_set_block "$F" "$BLOCK3" top
  [ "$(cat "$F")" = "$(printf '%s\n\n# >>> tmuxkeep path\nx\n# <<< tmuxkeep path' "$BLOCK3")" ]
}

@test "a path that cannot be written stops with the path in the message (spec 12)" {
  mkdir -p "$BATS_TEST_TMPDIR/dir-not-file"
  if tk_set_block "$BATS_TEST_TMPDIR/dir-not-file" "$BLOCK3"; then return 1; fi
  [ "$TK_ERR" = "$BATS_TEST_TMPDIR/dir-not-file: is a directory" ]
}

@test "a symlinked ssh config or rc file is written through and stays a symlink (Review Focus 3)" {
  mkdir -p "$HOME/dotfiles"
  printf 'Host other\n' > "$HOME/dotfiles/ssh_config"
  ln -s "$HOME/dotfiles/ssh_config" "$F"
  tk_set_block "$F" "$(tk_ssh_block)" top
  [ -L "$F" ]
  grep -qx 'Host tmuxkeep' "$HOME/dotfiles/ssh_config"
  grep -qx 'Host other' "$HOME/dotfiles/ssh_config"
  printf '# mine\n' > "$HOME/dotfiles/bashrc"
  ln -s "$HOME/dotfiles/bashrc" "$HOME/.bashrc"
  tk_set_block "$(tk_rc_file)" "$(tk_rc_block)"
  [ -L "$HOME/.bashrc" ]
  grep -qx '# >>> tmuxkeep' "$HOME/dotfiles/bashrc"
  grep -qx '# mine' "$HOME/dotfiles/bashrc"
}

@test "the ssh config block goes first, so its agent options win, and is replaced in place when HOST changes" {
  printf 'Host other\n    HostName 198.51.100.7\n\nHost *\n    AddKeysToAgent yes\n    UseKeychain yes\n' > "$F"
  tk_set_block "$F" "$(tk_ssh_block)" top
  { cat "$REPO/tests/fixtures/ssh-block"; printf '\nHost other\n    HostName 198.51.100.7\n\nHost *\n    AddKeysToAgent yes\n    UseKeychain yes\n'; } > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  [ "$(sed -n 1p "$F")" = '# >>> tmuxkeep' ]
  TKC_HOST=198.51.100.20
  tk_set_block "$F" "$(tk_ssh_block)" top
  [ "$(grep -c '^# >>> tmuxkeep$' "$F")" -eq 1 ]
  [ "$(grep -c '^    HostName 198.51.100.20$' "$F")" -eq 2 ]
  [ "$(grep -c '203.0.113.10' "$F")" -eq 0 ]
  [ "$(sed -n 1p "$F")" = '# >>> tmuxkeep' ]
  [ "$(grep -c '^Host other$' "$F")" -eq 1 ]
}

@test "the rc block is appended after the user's text, not put above it (a later compinit keeps working)" {
  printf 'autoload -U compinit && compinit\nexport EXISTING=1\n' > "$HOME/.zshrc"
  tk_set_block "$HOME/.zshrc" "$(tk_rc_block)"
  [ "$(sed -n 1p "$HOME/.zshrc")" = 'autoload -U compinit && compinit' ]
  [ "$(sed -n 2p "$HOME/.zshrc")" = 'export EXISTING=1' ]
  [ "$(sed -n 3p "$HOME/.zshrc")" = '' ]
  [ "$(sed -n 4p "$HOME/.zshrc")" = '# >>> tmuxkeep' ]
  [ "$(tail -n 1 "$HOME/.zshrc")" = '# <<< tmuxkeep' ]
}

# The block must parse in a real OpenSSH. Stubs cannot catch an option a given ssh rejects or a
# section that swallows the user's own lines. ssh -G reads the configuration and connects to nothing.

# real_ssh: the ssh client that is not the stub (the stubs directory is first on PATH).
real_ssh() { PATH=${PATH//"$STUBS:"/} command -v ssh; }

# ssh_g FILE HOST: what a real "ssh -F FILE -G HOST" prints.
ssh_g() { "$REAL_SSH" -F "$1" -G "$2"; }

# out_has ERE: some line of $output matches the extended regular expression.
out_has() { printf '%s\n' "$output" | grep -qE "$1"; }
# out_lacks ERE: no line of $output matches (a plain function, so a failure stops the test).
out_lacks() { ! out_has "$1"; }

@test "the fixture block parses in a real OpenSSH for tmuxkeep, tmuxkeep-admin and another host (ssh -G)" {
  REAL_SSH=$(real_ssh) || { echo 'ssh is not installed in this environment'; return 1; }
  [ "$REAL_SSH" != "$STUBS/ssh" ]
  local h fx="$REPO/tests/fixtures/ssh-block"
  for h in tmuxkeep tmuxkeep-admin example.org; do
    run ssh_g "$fx" "$h"
    [ "$status" -eq 0 ] || { echo "$h: $status $output"; return 1; }
  done
  run ssh_g "$fx" tmuxkeep-admin
  out_has '^(addkeystoagent false|addkeystoagent no)$' || { echo "$output"; return 1; }
  out_has '^identitiesonly yes$'
  out_has '^identityfile .*id_tmuxkeep_admin_ed25519$'
  out_has '^user root$'
  run ssh_g "$fx" tmuxkeep
  out_has '^user claude$'
  out_has '^identityfile .*id_tmuxkeep_ed25519$'
  run ssh_g "$fx" example.org
  out_lacks 'id_tmuxkeep'
  out_lacks '203\.0\.113\.10'
}

@test "a user's global line after the block still applies to other hosts, and the admin host keeps its own agent option (ssh -G)" {
  REAL_SSH=$(real_ssh) || { echo 'ssh is not installed in this environment'; return 1; }
  local sc="$BATS_TEST_TMPDIR/ssh-scratch"
  { cat "$REPO/tests/fixtures/ssh-block"; printf 'IdentityFile ~/.ssh/other_key\nAddKeysToAgent yes\n'; } > "$sc"
  # The block's last section is Host *, so these two lines are global again: example.org gets them.
  run ssh_g "$sc" example.org
  [ "$status" -eq 0 ]
  out_has '^identityfile .*other_key$'
  out_has '^addkeystoagent true$'
  out_lacks 'id_tmuxkeep'
  # ssh keeps the first value of AddKeysToAgent, which is the block's, so the admin key stays out of the
  # agent. IdentityFile is cumulative, so the user's own key is offered to this host too (with
  # IdentitiesOnly yes ssh offers only the files named in the configuration), but the session key never is.
  run ssh_g "$sc" tmuxkeep-admin
  [ "$status" -eq 0 ]
  out_has '^(addkeystoagent false|addkeystoagent no)$' || { echo "$output"; return 1; }
  out_has '^identityfile .*id_tmuxkeep_admin_ed25519$'
  out_lacks 'id_tmuxkeep_ed25519'
  # Without the closing Host * the same line would be swallowed by Host tmuxkeep-admin.
  { grep -vx 'Host \*' "$REPO/tests/fixtures/ssh-block"; printf 'IdentityFile ~/.ssh/other_key\n'; } > "$sc"
  run ssh_g "$sc" example.org
  [ "$status" -eq 0 ]
  out_lacks 'other_key'
}

@test "tk_rc_block is the amended spec 6.4 block (plan Q3)" {
  run tk_rc_block
  [ "$output" = "$(printf '%s\n' \
    '# >>> tmuxkeep' \
    'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac' \
    '[ -n "$ZSH_VERSION" ] && { whence compdef >/dev/null || { autoload -U +X compinit && compinit -i; }; } && autoload -U +X bashcompinit && bashcompinit' \
    '[ -f "$HOME/.tmuxkeep/completion.bash" ] && . "$HOME/.tmuxkeep/completion.bash"' \
    '# <<< tmuxkeep')" ]
}

@test "the rc file is ~/.zshrc when SHELL ends in zsh, else ~/.bashrc" {
  SHELL=/bin/zsh
  [ "$(tk_rc_file)" = "$HOME/.zshrc" ]
  SHELL=/usr/local/bin/zsh
  [ "$(tk_rc_file)" = "$HOME/.zshrc" ]
  SHELL=/bin/bash
  [ "$(tk_rc_file)" = "$HOME/.bashrc" ]
  unset SHELL
  [ "$(tk_rc_file)" = "$HOME/.bashrc" ]
}

@test "bash: the rc block puts ~/.local/bin on PATH once and registers completion" {
  mkdir -p "$HOME/.tmuxkeep"
  cp "$REPO/laptop/completion.bash" "$HOME/.tmuxkeep/completion.bash"
  printf 'export EXISTING=1\n' > "$HOME/.bashrc"
  tk_set_block "$HOME/.bashrc" "$(tk_rc_block)"
  tk_set_block "$HOME/.bashrc" "$(tk_rc_block)"
  [ "$(grep -c '^# >>> tmuxkeep$' "$HOME/.bashrc")" -eq 1 ]
  run "$BASH" -c '. "$HOME/.bashrc"; . "$HOME/.bashrc"; complete -p tmuxkeep; printf "%s\n" "$PATH" | tr ":" "\n" | grep -cx "$HOME/.local/bin"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'complete -F _tmuxkeep tmuxkeep' ]
  [ "${lines[1]}" = 1 ]
}

@test "zsh without compinit: the rc block loads completion and prints no compdef error (Review Focus 4)" {
  command -v zsh >/dev/null || { echo 'zsh is missing from the test environment (Step 1)'; return 1; }
  mkdir -p "$HOME/.tmuxkeep"
  cp "$REPO/laptop/completion.bash" "$HOME/.tmuxkeep/completion.bash"
  tk_set_block "$HOME/.zshrc" "$(tk_rc_block)"
  run --separate-stderr zsh -f -c '. "$HOME/.zshrc"; print -r -- "${_comps[tmuxkeep]}"'
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [[ "$output" == *_tmuxkeep* ]]
  [[ "$stderr" != *compdef* ]]
  [[ "$stderr" != *'not found'* ]]
}

# Fix round 1 (task 13 review): exact refusal messages, fail-closed reads, CR markers, TEXT guard.

@test "the two marker refusals set the exact TK_ERR text and leave the file unchanged" {
  local before
  printf '# >>> tmuxkeep\n1\n# <<< tmuxkeep\n# >>> tmuxkeep\n2\n# <<< tmuxkeep\n' > "$F"
  before=$(cat "$F")
  if tk_set_block "$F" "$BLOCK3"; then return 1; fi
  [ "$TK_ERR" = "$F: more than one '# >>> tmuxkeep' line; remove the extra block by hand" ]
  [ "$(cat "$F")" = "$before" ]
  printf 'x\n# >>> tmuxkeep\nold\n' > "$F"
  before=$(cat "$F")
  if tk_set_block "$F" "$BLOCK3"; then return 1; fi
  [ "$TK_ERR" = "$F: '# >>> tmuxkeep' without '# <<< tmuxkeep'; fix it by hand" ]
  [ "$(cat "$F")" = "$before" ]
}

@test "an existing file that cannot be read is refused before anything is written" {
  # Docker runs as root: the file belongs to the claude user and the call runs as claude (runuser).
  # On macOS (and any non-root shell) there is no runuser or claude user and none is needed: mode
  # 200 already makes the file unreadable to the current user. Root without runuser cannot be made
  # to fail a read, so that case skips.
  local as_root=0
  if [ "$(id -u)" -eq 0 ]; then as_root=1; fi
  if [ "$as_root" -eq 1 ] && ! command -v runuser >/dev/null; then
    skip "needs runuser or a non-root user"
  fi
  TK_PROBE_DIR=$(mktemp -d /tmp/tk-probe.XXXXXX)
  chmod 755 "$TK_PROBE_DIR"
  printf 'keep me\n' > "$TK_PROBE_DIR/f"
  if [ "$as_root" -eq 1 ]; then
    chown claude "$TK_PROBE_DIR/f"
    chmod 200 "$TK_PROBE_DIR/f"
    run runuser -u claude -- "$BASH" -c 'source "$1"; if tk_set_block "$2" "$3"; then exit 1; fi; printf "%s\n" "$TK_ERR"' x "$REPO/laptop/deploy.sh" "$TK_PROBE_DIR/f" "$BLOCK3"
  else
    chmod 200 "$TK_PROBE_DIR/f"
    run "$BASH" -c 'source "$1"; if tk_set_block "$2" "$3"; then exit 1; fi; printf "%s\n" "$TK_ERR"' x "$REPO/laptop/deploy.sh" "$TK_PROBE_DIR/f" "$BLOCK3"
    chmod 600 "$TK_PROBE_DIR/f"   # the owner cannot read mode 200 either; restore the read for the content check below
  fi
  [ "$status" -eq 0 ]
  [ "$output" = "$TK_PROBE_DIR/f: not readable" ]
  [ "$(cat "$TK_PROBE_DIR/f")" = 'keep me' ]
}

@test "a failing awk on the marker scan stops with 'cannot read' and the file is untouched" {
  local before
  printf 'top\n# >>> tmuxkeep\nold\n# <<< tmuxkeep\nbottom\n' > "$F"
  before=$(cat "$F")
  stub_tool awk <<'EOS'
#!/bin/sh
exit 2
EOS
  if tk_set_block "$F" "$BLOCK3"; then return 1; fi
  [ "$TK_ERR" = "$F: cannot read" ]
  [ "$(cat "$F")" = "$before" ]
  no_temp_left
}

@test "a failing awk on the rewrite stops with 'cannot read', the file is untouched and no temp file is left" {
  local before
  printf 'top\n# >>> tmuxkeep\nold\n# <<< tmuxkeep\nbottom\n' > "$F"
  before=$(cat "$F")
  export AWK_REAL AWK_COUNT="$BATS_TEST_TMPDIR/awk-count"
  AWK_REAL=$(command -v awk)
  stub_tool awk <<'EOS'
#!/bin/sh
n=0
[ -f "$AWK_COUNT" ] && n=$(cat "$AWK_COUNT")
echo $((n + 1)) > "$AWK_COUNT"
if [ "$n" -ge 1 ]; then echo partial; exit 2; fi
exec "$AWK_REAL" "$@"
EOS
  if tk_set_block "$F" "$BLOCK3"; then return 1; fi
  [ "$(cat "$AWK_COUNT")" -eq 2 ]
  [ "$TK_ERR" = "$F: cannot read" ]
  [ "$(cat "$F")" = "$before" ]
  no_temp_left
}

@test "a cmp error is not taken for 'differs': the file is untouched" {
  local before
  printf 'top\n# >>> tmuxkeep\nold\n# <<< tmuxkeep\nbottom\n' > "$F"
  before=$(cat "$F")
  stub_tool cmp <<'EOS'
#!/bin/sh
exit 2
EOS
  if tk_set_block "$F" "$BLOCK3"; then return 1; fi
  [ "$TK_ERR" = "$F: cannot read" ]
  [ "$(cat "$F")" = "$before" ]
  no_temp_left
}

@test "marker lines that end in CR are ours: the block is replaced once, other lines keep their bytes" {
  printf 'top\r\n# >>> tmuxkeep\r\nold\r\n# <<< tmuxkeep\r\nbottom\r\n' > "$F"
  tk_set_block "$F" "$BLOCK3"
  printf 'top\r\n# >>> tmuxkeep\nline one\n# <<< tmuxkeep\nbottom\r\n' > "$BATS_TEST_TMPDIR/want"
  cmp "$F" "$BATS_TEST_TMPDIR/want"
  [ "$(grep -c '>>> tmuxkeep' "$F")" -eq 1 ]
  printf '# >>> tmuxkeep\r\n1\r\n# <<< tmuxkeep\r\n# >>> tmuxkeep\r\n2\r\n# <<< tmuxkeep\r\n' > "$F"
  if tk_set_block "$F" "$BLOCK3"; then return 1; fi
  [ "$TK_ERR" = "$F: more than one '# >>> tmuxkeep' line; remove the extra block by hand" ]
  printf 'x\r\n# >>> tmuxkeep\r\nold\r\n' > "$F"
  if tk_set_block "$F" "$BLOCK3"; then return 1; fi
  [ "$TK_ERR" = "$F: '# >>> tmuxkeep' without '# <<< tmuxkeep'; fix it by hand" ]
}

@test "text that does not start and end with the markers is refused and nothing is written" {
  local t want="block text must start with '# >>> tmuxkeep' and end with '# <<< tmuxkeep'"
  for t in '' 'plain' '# >>> tmuxkeep' '# <<< tmuxkeep' \
           "$(printf '%s\n' '# >>> tmuxkeep' 'x')" "$(printf '%s\n' 'x' '# <<< tmuxkeep')" \
           "$(printf '%s\n' ' # >>> tmuxkeep' 'x' '# <<< tmuxkeep')"; do
    if tk_set_block "$BATS_TEST_TMPDIR/guard dir/f" "$t"; then return 1; fi
    [ "$TK_ERR" = "$want" ]
  done
  [ ! -e "$BATS_TEST_TMPDIR/guard dir" ]
  printf 'keep\n' > "$F"
  if tk_set_block "$F" 'plain'; then return 1; fi
  [ "$TK_ERR" = "$want" ]
  [ "$(cat "$F")" = keep ]
}
