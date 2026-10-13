#!/usr/bin/env bats
# vps/tmuxkeep-setup: sourced for unit tests; the sshd functions run against the image's real sshd.
# main is never run here: it would install packages and create users.
load helpers

setup() {
  source /src/vps/tmuxkeep-setup
  cp /etc/ssh/sshd_config "$BATS_TEST_TMPDIR/sshd_config.orig"
  rm -f /etc/ssh/sshd_config.d/tmuxkeep.conf /etc/ssh/sshd_config.d/00-test.conf
}
teardown() {
  rm -f /etc/ssh/sshd_config.d/tmuxkeep.conf /etc/ssh/sshd_config.d/00-test.conf
  cp "$BATS_TEST_TMPDIR/sshd_config.orig" /etc/ssh/sshd_config
}

newkey() { # newkey NAME: prints the path of a fresh ed25519 public key
  ssh-keygen -q -t ed25519 -N '' -C tmuxkeep-laptop -f "$BATS_TEST_TMPDIR/$1" >/dev/null
  printf '%s' "$BATS_TEST_TMPDIR/$1.pub"
}

@test "sourcing defines the functions and runs nothing" {
  declare -F main install_sshd_dropin read_pubkey want_harden >/dev/null
}

@test "tmuxkeep-setup passes bash -n and shellcheck, and has no CR" {
  run bash -n /src/vps/tmuxkeep-setup
  [ "$status" -eq 0 ]
  run shellcheck -S warning /src/vps/tmuxkeep-setup
  [ "$status" -eq 0 ]
  run grep -c $'\r' /src/vps/tmuxkeep-setup
  [ "$output" = 0 ]
}

@test "bad arguments are usage (2) before anything happens" {
  run bash /src/vps/tmuxkeep-setup --key-id BAD --pubkey-file /nonexistent
  [ "$status" -eq 2 ]
  run bash /src/vps/tmuxkeep-setup --bogus
  [ "$status" -eq 2 ]
  run bash /src/vps/tmuxkeep-setup
  [ "$status" -eq 2 ]
  [[ "$output" == *--pubkey-file* ]]
}

@test "valid_key_id" {
  local k
  for k in laptop a a-b_c abcdefghijklmnop; do
    valid_key_id "$k" || { echo "rejected $k"; return 1; }
  done
  for k in Laptop 1a '' 'a b' abcdefghijklmnopq; do
    if valid_key_id "$k"; then echo "accepted '$k'"; return 1; fi
  done
}

@test "read_pubkey accepts one ssh-ed25519 line and drops the comment" {
  local pub
  pub=$(newkey k1)
  run read_pubkey "$pub"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cut -d' ' -f1,2 "$pub")" ]
}

@test "read_pubkey rejects two lines, other key types, options, CRLF and empty files" {
  local pub bad="$BATS_TEST_TMPDIR/bad.pub"
  pub=$(newkey k1)
  cat "$pub" "$pub" > "$bad"
  run read_pubkey "$bad"
  [ "$status" -ne 0 ]
  printf 'ssh-rsa AAAAB3NzaC1yc2E tmuxkeep-laptop\n' > "$bad"
  run read_pubkey "$bad"
  [ "$status" -ne 0 ]
  printf 'command="x" %s\n' "$(cat "$pub")" > "$bad"
  run read_pubkey "$bad"
  [ "$status" -ne 0 ]
  printf '%s\r\n' "$(cat "$pub")" > "$bad"
  run read_pubkey "$bad"
  [ "$status" -ne 0 ]
  : > "$bad"
  run read_pubkey "$bad"
  [ "$status" -ne 0 ]
}

@test "authorized_keys_line has restrict,pty, the forced command and comment tmuxkeep-<id>" {
  run authorized_keys_line laptop 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample'
  [ "$output" = 'restrict,pty,command="/usr/local/bin/tmuxkeep --key laptop" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample tmuxkeep-laptop' ]
}

@test "render_authorized_keys replaces only the line for the same key id (plan Q9)" {
  local f="$BATS_TEST_TMPDIR/ak"
  printf '%s\n' \
    'restrict,pty,command="/usr/local/bin/tmuxkeep --key laptop" ssh-ed25519 OLDKEY tmuxkeep-laptop' \
    'restrict,pty,command="/usr/local/bin/tmuxkeep --key desk" ssh-ed25519 DESKKEY tmuxkeep-desk' > "$f"
  run render_authorized_keys "$f" laptop 'ssh-ed25519 NEWKEY'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *'--key desk" ssh-ed25519 DESKKEY tmuxkeep-desk'* ]]
  [[ "$output" == *'--key laptop" ssh-ed25519 NEWKEY tmuxkeep-laptop'* ]]
  [[ "$output" != *OLDKEY* ]]
}

@test "render_authorized_keys on a missing file yields just the new line" {
  run render_authorized_keys "$BATS_TEST_TMPDIR/none" laptop 'ssh-ed25519 NEWKEY'
  [ "$output" = 'restrict,pty,command="/usr/local/bin/tmuxkeep --key laptop" ssh-ed25519 NEWKEY tmuxkeep-laptop' ]
}

@test "render_dropin keeps root's line commented unless hardening, then replaces it whole" {
  run render_dropin /src/vps/sshd.conf.tmpl 0
  [ "$output" = "$(render_template /src/vps/sshd.conf.tmpl claude)" ]
  run render_dropin /src/vps/sshd.conf.tmpl 1
  printf '%s\n' "$output" | grep -qx 'PermitRootLogin prohibit-password'
  [[ "$output" != *"<-"* ]]
  run dropin_is_hardened /src/vps/sshd.conf.tmpl
  [ "$status" -ne 0 ]
}

@test "sshd_diff_ok allows only a permitrootlogin change, and only when hardening" {
  local a="$BATS_TEST_TMPDIR/a" b="$BATS_TEST_TMPDIR/b"
  printf 'permitrootlogin yes\nx11forwarding yes\n' > "$a"
  cp "$a" "$b"
  run sshd_diff_ok "$a" "$b" 0
  [ "$status" -eq 0 ]
  printf 'permitrootlogin without-password\nx11forwarding yes\n' > "$b"
  run sshd_diff_ok "$a" "$b" 1
  [ "$status" -eq 0 ]
  run sshd_diff_ok "$a" "$b" 0
  [ "$status" -ne 0 ]
  printf 'permitrootlogin yes\nx11forwarding no\n' > "$b"
  run sshd_diff_ok "$a" "$b" 1
  [ "$status" -ne 0 ]
}

@test "install_sshd_dropin installs when root's config is unchanged" {
  run install_sshd_dropin /src/vps/sshd.conf.tmpl 0
  [ "$status" -eq 0 ]
  cmp /etc/ssh/sshd_config.d/tmuxkeep.conf <(render_template /src/vps/sshd.conf.tmpl claude)
  run check_user_sshd
  [ "$status" -eq 0 ]
}

@test "install_sshd_dropin with hardening changes only root's permitrootlogin" {
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  run install_sshd_dropin /src/vps/sshd.conf.tmpl 1
  [ "$status" -eq 0 ]
  run sshd_effective root
  [[ "$output" == *"permitrootlogin without-password"* || "$output" == *"permitrootlogin prohibit-password"* ]]
}

@test "hardening is sticky across a plain re-run (plan Q1)" {
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  install_sshd_dropin /src/vps/sshd.conf.tmpl 1
  [ "$(want_harden 0)" = 1 ]
  run install_sshd_dropin /src/vps/sshd.conf.tmpl "$(want_harden 0)"
  [ "$status" -eq 0 ]
  dropin_is_hardened /etc/ssh/sshd_config.d/tmuxkeep.conf
}

@test "install_sshd_dropin aborts and restores when root's config would change" {
  install_sshd_dropin /src/vps/sshd.conf.tmpl 0
  cp /etc/ssh/sshd_config.d/tmuxkeep.conf "$BATS_TEST_TMPDIR/good"
  { echo 'X11Forwarding no'; cat /src/vps/sshd.conf.tmpl; } > "$BATS_TEST_TMPDIR/bad.conf"
  run install_sshd_dropin "$BATS_TEST_TMPDIR/bad.conf" 0
  [ "$status" -ne 0 ]
  cmp /etc/ssh/sshd_config.d/tmuxkeep.conf "$BATS_TEST_TMPDIR/good"
}

@test "install_sshd_dropin removes its file when sshd -t fails and none existed before" {
  printf 'BogusDirective yes\n' > "$BATS_TEST_TMPDIR/bogus.conf"
  run install_sshd_dropin "$BATS_TEST_TMPDIR/bogus.conf" 0
  [ "$status" -ne 0 ]
  [ ! -e /etc/ssh/sshd_config.d/tmuxkeep.conf ]
}

@test "hardening that an earlier drop-in overrides is refused (plan Q1)" {
  printf 'PermitRootLogin yes\n' > /etc/ssh/sshd_config.d/00-test.conf
  run install_sshd_dropin /src/vps/sshd.conf.tmpl 1
  [ "$status" -ne 0 ]
  [[ "$output" == *permitrootlogin* ]]
  [ ! -e /etc/ssh/sshd_config.d/tmuxkeep.conf ]
}

@test "sshd_has_include" {
  run sshd_has_include /etc/ssh/sshd_config
  [ "$status" -eq 0 ]
  grep -v '^Include' /etc/ssh/sshd_config > "$BATS_TEST_TMPDIR/noinc"
  run sshd_has_include "$BATS_TEST_TMPDIR/noinc"
  [ "$status" -ne 0 ]
}

@test "allowusers_ok" {
  run allowusers_ok $'port 22\npubkeyauthentication yes'
  [ "$status" -eq 0 ]
  run allowusers_ok $'allowusers root\nallowusers claude'
  [ "$status" -eq 0 ]
  run allowusers_ok 'allowusers root'
  [ "$status" -ne 0 ]
}

@test "parse_kill_user_processes" {
  [ "$(parse_kill_user_processes 'b true')" = yes ]
  [ "$(parse_kill_user_processes 'b false')" = no ]
  [ "$(parse_kill_user_processes 'garbage')" = unknown ]
}

@test "tmux_version_ok" {
  tmux_version_ok 'tmux 3.3a'
  tmux_version_ok 'tmux 3.0'
  tmux_version_ok 'tmux next-3.4'
  run tmux_version_ok 'tmux 2.9a'
  [ "$status" -ne 0 ]
  run tmux_version_ok 'garbage'
  [ "$status" -ne 0 ]
}

@test "attr_has_append reads lsattr output" {
  attr_has_append '-----a--------e------- /var/log/tmuxkeep/audit.log'
  run attr_has_append '--------------e------- /var/log/tmuxkeep/audit.log'
  [ "$status" -ne 0 ]
}

@test "has_cr" {
  printf 'a\r\n' > "$BATS_TEST_TMPDIR/cr"
  printf 'a\n' > "$BATS_TEST_TMPDIR/lf"
  has_cr "$BATS_TEST_TMPDIR/cr"
  run has_cr "$BATS_TEST_TMPDIR/lf"
  [ "$status" -ne 0 ]
}

@test "ensure_path_snippet appends the PATH block once and it works" {
  local f="$BATS_TEST_TMPDIR/.bashrc"
  printf '# existing\n' > "$f"
  ensure_path_snippet "$f"
  ensure_path_snippet "$f"
  [ "$(grep -c '^# >>> tmuxkeep path' "$f")" -eq 1 ]
  run bash -c "PATH=/usr/bin; HOME=/home/x; source '$f' >/dev/null 2>&1; printf %s \"\$PATH\""
  [[ "$output" == /home/x/.local/bin:* ]]
}

@test "staged_files_ok names what is missing" {
  local d="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$d/systemd"
  touch "$d/tmuxkeep" "$d/tmux.conf"
  run staged_files_ok "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *sudoers.tmpl* ]]
}

# ---- orchestrator rulings added after the brief's 25 tests ----

@test "valid_totp_secret takes unpadded base32 of 16 to 64 characters that oathtool accepts" {
  valid_totp_secret JBSWY3DPEHPK3PXP
  valid_totp_secret JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP
  local s
  for s in '' jbswy3dpehpk3pxp JBSWY3DPEHPK3PX= JBSWY3DPEHPK3PX JBSWY3DPEHPK3PX1 $'JBSWY3DPEHPK3PXP\nJBSWY3DPEHPK3PXP' "$(printf 'A%.0s' {1..65})"; do
    if valid_totp_secret "$s"; then echo "accepted '$s'"; return 1; fi
  done
}

@test "totp_secret_file_ok wants exactly one valid line" {
  local f="$BATS_TEST_TMPDIR/secret"
  printf 'JBSWY3DPEHPK3PXP\n' > "$f"
  totp_secret_file_ok "$f"
  printf 'JBSWY3DPEHPK3PXP\nJBSWY3DPEHPK3PXP\n' > "$f"
  run totp_secret_file_ok "$f"
  [ "$status" -ne 0 ]
  printf 'JBSWY3DPEHPK3PXP\n\n' > "$f"
  run totp_secret_file_ok "$f"
  [ "$status" -ne 0 ]
  : > "$f"
  run totp_secret_file_ok "$f"
  [ "$status" -ne 0 ]
  run totp_secret_file_ok "$BATS_TEST_TMPDIR/none"
  [ "$status" -ne 0 ]
}

@test "runtime_dir_ok wants the exact XDG_RUNTIME_DIR line for the uid" {
  runtime_dir_ok $'PATH=/usr/bin\nXDG_RUNTIME_DIR=/run/user/1001' 1001
  run runtime_dir_ok $'PATH=/usr/bin\nXDG_RUNTIME_DIR=/run/user/1001' 1002
  [ "$status" -ne 0 ]
  run runtime_dir_ok 'XDG_RUNTIME_DIR=/run/user/1001/x' 1001
  [ "$status" -ne 0 ]
  run runtime_dir_ok 'PATH=/usr/bin' 1001
  [ "$status" -ne 0 ]
}

@test "has_c_utf8 reads locale -a output" {
  has_c_utf8 $'C\nC.utf8\nPOSIX'
  has_c_utf8 $'C\nC.UTF-8'
  run has_c_utf8 $'C\nPOSIX\nen_US.utf8'
  [ "$status" -ne 0 ]
  run has_c_utf8 ''
  [ "$status" -ne 0 ]
}

# ---- fix round 1: hardenings from review ----

@test "no_symlinks_in_home refuses a symlink on any path root writes to" {
  local h="$BATS_TEST_TMPDIR/home" rel
  mkhome() {
    rm -rf "$h"
    mkdir -p "$h/.tmuxkeep/leases" "$h/work" "$h/.config/systemd/user"
    touch "$h/.profile" "$h/.bashrc" "$h/.tmuxkeep/totp.secret"
  }
  mkhome
  run no_symlinks_in_home "$h"
  [ "$status" -eq 0 ]
  run no_symlinks_in_home "$h/"
  [ "$status" -eq 0 ]
  for rel in .tmuxkeep .tmuxkeep/leases .tmuxkeep/totp.secret .tmuxkeep/last-otp .tmuxkeep/otp-fails .tmuxkeep/otp-locked \
             work .profile .bashrc .config .config/systemd .config/systemd/user \
             .config/systemd/user/tmuxkeep-reaper.service .config/systemd/user/tmuxkeep-reaper.timer; do
    mkhome
    rm -rf "${h:?}/$rel"
    ln -s /etc "$h/$rel"
    run no_symlinks_in_home "$h"
    [ "$status" -ne 0 ] || { echo "accepted a symlink at $rel"; return 1; }
    [[ "$output" == *"refusing to follow symlink: $h/$rel"* ]] || { echo "bad message for $rel: $output"; return 1; }
  done
  mkhome
  rm -f "$h/.tmuxkeep/last-otp"
  ln -s /nonexistent/target "$h/.tmuxkeep/last-otp"
  run no_symlinks_in_home "$h"
  [ "$status" -ne 0 ]
  mkhome
  ln -s "$h" "$BATS_TEST_TMPDIR/homelink"
  run no_symlinks_in_home "$BATS_TEST_TMPDIR/homelink"
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to follow symlink: $BATS_TEST_TMPDIR/homelink"* ]]
}

@test "hardening is refused when root login is already no or forced-commands-only, and nothing changes" {
  local v
  for v in no forced-commands-only; do
    printf 'PermitRootLogin %s\n' "$v" > /etc/ssh/sshd_config.d/00-test.conf
    run install_sshd_dropin /src/vps/sshd.conf.tmpl 0
    [ "$status" -eq 0 ]
    cp /etc/ssh/sshd_config.d/tmuxkeep.conf "$BATS_TEST_TMPDIR/good"
    run install_sshd_dropin /src/vps/sshd.conf.tmpl 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing --harden-root: root login is already $v"* ]] || { echo "$output"; return 1; }
    cmp /etc/ssh/sshd_config.d/tmuxkeep.conf "$BATS_TEST_TMPDIR/good"
    run dropin_is_hardened /etc/ssh/sshd_config.d/tmuxkeep.conf
    [ "$status" -ne 0 ]
    rm -f /etc/ssh/sshd_config.d/tmuxkeep.conf
    run install_sshd_dropin /src/vps/sshd.conf.tmpl 1
    [ "$status" -ne 0 ]
    [ ! -e /etc/ssh/sshd_config.d/tmuxkeep.conf ]
  done
}

@test "a drop-in that cannot be restored is removed, never left unvalidated" {
  install_sshd_dropin /src/vps/sshd.conf.tmpl 0
  printf 'BogusDirective yes\n' > "$BATS_TEST_TMPDIR/bogus.conf"
  # Make the restore fail: cp onto the drop-in is refused, every other cp works.
  cp() { if [[ ${*: -1} == "$SSHD_DROPIN" ]]; then return 1; fi; command cp "$@"; }
  run install_sshd_dropin "$BATS_TEST_TMPDIR/bogus.conf" 0
  unset -f cp
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAILED to restore"* ]]
  [ ! -e /etc/ssh/sshd_config.d/tmuxkeep.conf ]
}

@test "_dropin_rollback: restore, remove-after-failed-restore, and a loud failure when removal fails" {
  local d="$BATS_TEST_TMPDIR"
  SSHD_DROPIN="$d/x.conf"
  printf 'old\n' > "$d/backup"
  printf 'new\n' > "$SSHD_DROPIN"
  run _dropin_rollback "$d" 1
  [ "$status" -eq 0 ]
  [ "$(cat "$SSHD_DROPIN")" = old ]
  rm -f "$d/backup"; mkdir "$d/backup"
  printf 'new\n' > "$SSHD_DROPIN"
  run _dropin_rollback "$d" 1
  [ "$status" -eq 1 ]
  [ ! -e "$SSHD_DROPIN" ]
  printf 'new\n' > "$SSHD_DROPIN"
  run _dropin_rollback "$d" 0
  [ "$status" -eq 0 ]
  [ ! -e "$SSHD_DROPIN" ]
  mkdir "$d/stuck"
  SSHD_DROPIN="$d/stuck"
  run _dropin_rollback "$d" 0
  [ "$status" -eq 2 ]
  [[ "$output" == *CRITICAL* ]]
}

@test "an option value that looks like another option is usage (2)" {
  run bash /src/vps/tmuxkeep-setup --pubkey-file --harden-root
  [ "$status" -eq 2 ]
  run bash /src/vps/tmuxkeep-setup --pubkey-file /x --key-id --rotate-totp
  [ "$status" -eq 2 ]
  [[ "$output" == *usage* ]]
  run bash /src/vps/tmuxkeep-setup --pubkey-file
  [ "$status" -eq 2 ]
}

@test "main keeps its guards: signals ignored, LC_ALL=C, apt lock timeout, staged sudoers, symlink checks" {
  local body="$BATS_TEST_TMPDIR/main.body" step1
  sed -n '/^main() {/,/^}/p' /src/vps/tmuxkeep-setup > "$body"
  grep -qx "  trap '' HUP PIPE" "$body"
  grep -qx '  export LC_ALL=C' "$body"
  [ "$(grep -c 'apt-get -o DPkg::Lock::Timeout=300 ' "$body")" -eq 2 ]
  grep -qF 'local src=$1 new=${SUDOERS_DEST%/*}/.tmuxkeep.new' /src/vps/tmuxkeep-setup
  [ "$(sed -n '/^install_sudoers() {/,/^}/p' /src/vps/tmuxkeep-setup | grep -c 'visudo -cf "$new"')" -eq 1 ]
  [ "$(grep -c 'no_symlinks_in_home "$TK_HOME" || exit 1' "$body")" -eq 4 ]
  # The user manager is reached through its private socket, never through the user's D-Bus bus.
  run ! grep -q -- '--user -M' /src/vps/tmuxkeep-setup
  [ "$(grep -c 'user_systemctl "$uid" ' "$body")" -eq 4 ]
  # The account guards run before step 1 changes anything.
  step1=$(grep -n 'say "step 1: packages"' "$body" | cut -d: -f1)
  [ "$(grep -n 'account_ok "$TK_USER" || exit 1' "$body" | cut -d: -f1)" -lt "$step1" ]
  [ "$(grep -n 'user_unchanged "$VPS_CONF" "$TK_USER" || exit 1' "$body" | cut -d: -f1)" -lt "$step1" ]
}

@test "user_systemctl runs systemctl --user as claude with XDG_RUNTIME_DIR, no D-Bus needed" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/runuser" <<'EOF'
#!/bin/sh
echo "$*"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/runuser"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run user_systemctl 1001 daemon-reload
  [ "$status" -eq 0 ]
  [ "$output" = '-u claude -- env XDG_RUNTIME_DIR=/run/user/1001 systemctl --user daemon-reload' ]
  run user_systemctl 1001 enable --now tmuxkeep-reaper.timer
  [ "$output" = '-u claude -- env XDG_RUNTIME_DIR=/run/user/1001 systemctl --user enable --now tmuxkeep-reaper.timer' ]
}
