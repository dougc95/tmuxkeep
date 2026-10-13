#!/usr/bin/env bats
# vps/tmuxkeep-setup, spec 7.2 and 4.4: the __USER__ templates, the sudoers install, the sshd drop-in
# for another user, the VPS config file and its --check-conf gate (plan Q7). Sourced only.
load helpers

setup() {
  source /src/vps/tmuxkeep-setup
  conf_defaults
  cp /etc/ssh/sshd_config "$BATS_TEST_TMPDIR/sshd_config.orig"
  rm -rf /etc/ssh/sshd_config.d/tmuxkeep.conf /etc/sudoers.d/tmuxkeep /etc/sudoers.d/.tmuxkeep.new \
        /etc/tmuxkeep/tmuxkeep.conf /etc/tmuxkeep/.tmuxkeep.conf.new
  printf '#!/bin/bash\nexec bash /src/vps/tmuxkeep "$@"\n' > "$BATS_TEST_TMPDIR/broker"
  chmod +x "$BATS_TEST_TMPDIR/broker"
}
teardown() {
  # rm -rf: two tests below make the destination a directory to prove the rename refuses it.
  rm -rf /etc/ssh/sshd_config.d/tmuxkeep.conf /etc/sudoers.d/tmuxkeep /etc/sudoers.d/.tmuxkeep.new \
        /etc/tmuxkeep/tmuxkeep.conf /etc/tmuxkeep/.tmuxkeep.conf.new
  cp "$BATS_TEST_TMPDIR/sshd_config.orig" /etc/ssh/sshd_config
}

@test "render_template fills __USER__ in sudoers.tmpl for bob and keeps the final newline" {
  run render_template /src/vps/sudoers.tmpl bob
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    '# tmuxkeep: tmuxkeep-setup replaces the user placeholder and installs this as /etc/sudoers.d/tmuxkeep (0440) after visudo -cf.' \
    'bob ALL=(root) NOPASSWD: /usr/bin/apt-get update, /usr/bin/apt-get install *' \
    'bob ALL=(root) NOPASSWD: /usr/bin/systemctl restart *, /usr/bin/systemctl reload *, /usr/bin/systemctl status *' \
    'bob ALL=(root) NOPASSWD: /usr/bin/journalctl *')" ]
  [ "$(render_template /src/vps/sudoers.tmpl bob | tail -c 1 | od -An -tx1 | tr -d ' ')" = 0a ]
}

@test "render_template inserts the user text literally: an ampersand is not the matched placeholder" {
  printf 'x __USER__ y __USER__\n' > "$BATS_TEST_TMPDIR/amp.tmpl"
  run render_template "$BATS_TEST_TMPDIR/amp.tmpl" 'a&b\c'
  [ "$status" -eq 0 ]
  [ "$output" = 'x a&b\c y a&b\c' ]
}

@test "render_template fills __USER__ in sshd.conf.tmpl for bob" {
  run render_template /src/vps/sshd.conf.tmpl bob
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    '# tmuxkeep: tmuxkeep-setup replaces the user placeholder and installs this as /etc/ssh/sshd_config.d/tmuxkeep.conf. Do not edit on the VPS.' \
    '# PermitRootLogin prohibit-password      <- uncommented by setup --harden-root' \
    'Match User bob' \
    '    AuthorizedKeysFile /etc/tmuxkeep/authorized_keys' \
    '    PasswordAuthentication no' \
    '    DisableForwarding yes' \
    '    PermitUserRC no' \
    '    ClientAliveInterval 30' \
    '    ClientAliveCountMax 4' \
    'Match all')" ]
}

@test "render_dropin renders for TK_USER and hardens by replacing the whole PermitRootLogin line" {
  TK_USER=bob
  run render_dropin /src/vps/sshd.conf.tmpl 0
  [ "$output" = "$(render_template /src/vps/sshd.conf.tmpl bob)" ]
  run render_dropin /src/vps/sshd.conf.tmpl 1
  printf '%s\n' "$output" | grep -qx 'PermitRootLogin prohibit-password'
  printf '%s\n' "$output" | grep -qx 'Match User bob'
}

@test "install_sudoers installs the rendering for bob, root 0440, through the dot-named staging file" {
  TK_USER=bob
  run install_sudoers /src/vps/sudoers.tmpl
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a %U %G' /etc/sudoers.d/tmuxkeep)" = '440 root root' ]
  cmp /etc/sudoers.d/tmuxkeep <(render_template /src/vps/sudoers.tmpl bob)
  [ ! -e /etc/sudoers.d/.tmuxkeep.new ]
  run visudo -c
  [ "$status" -eq 0 ]
}

@test "install_sudoers leaves the installed file alone when the rendering fails visudo" {
  printf '# previous\n' > /etc/sudoers.d/tmuxkeep
  chmod 0440 /etc/sudoers.d/tmuxkeep
  printf '__USER__ ALL=(root) NOPASSWD: \n' > "$BATS_TEST_TMPDIR/bad.tmpl"
  TK_USER=bob
  run install_sudoers "$BATS_TEST_TMPDIR/bad.tmpl"
  [ "$status" -ne 0 ]
  [[ "$output" == *'failed visudo -cf'* ]]
  [ "$(cat /etc/sudoers.d/tmuxkeep)" = '# previous' ]
  [ ! -e /etc/sudoers.d/.tmuxkeep.new ]
}

@test "install_sudoers refuses to move the staged file into a directory that sits at the destination (mv -fT)" {
  mkdir /etc/sudoers.d/tmuxkeep
  TK_USER=bob
  run install_sudoers /src/vps/sudoers.tmpl
  [ "$status" -ne 0 ]
  [[ "$output" == *'cannot move the staged sudoers file'* ]]
  [ -d /etc/sudoers.d/tmuxkeep ]
  [ -z "$(ls -A /etc/sudoers.d/tmuxkeep)" ]
  [ ! -e /etc/sudoers.d/.tmuxkeep.new ]
}

@test "install_sshd_dropin for bob installs the rendering, and sshd applies it to bob only" {
  TK_USER=bob
  run install_sshd_dropin /src/vps/sshd.conf.tmpl 0
  [ "$status" -eq 0 ]
  cmp /etc/ssh/sshd_config.d/tmuxkeep.conf <(render_template /src/vps/sshd.conf.tmpl bob)
  run check_user_sshd
  [ "$status" -eq 0 ]
  run sshd_effective bob
  [[ "$output" == *'authorizedkeysfile /etc/tmuxkeep/authorized_keys'* ]]
  run sshd_effective claude
  [[ "$output" != *'authorizedkeysfile /etc/tmuxkeep/authorized_keys'* ]]
}

@test "render_vps_conf for claude with the defaults is the fixture, byte for byte" {
  TK_USER=claude
  TK_HOME=/home/claude
  cmp <(render_vps_conf) /src/tests/fixtures/tmuxkeep.conf
}

@test "render_vps_conf for bob carries the home, the derived paths and the deploy values" {
  TK_USER=bob
  TK_HOME=/srv/bob
  CONF_LAUNCH_CMD=htop
  CONF_RESUME_CMD=
  CONF_LEASE_SECS=600
  run render_vps_conf
  [ "$output" = "$(printf '%s\n' \
    '# Written by tmuxkeep-setup on every deploy; edits here are overwritten.' \
    '# Change ~/.tmuxkeep/config on the laptop and deploy again instead.' \
    'USER=bob' 'USER_HOME=/srv/bob' 'STATE_DIR=/srv/bob/.tmuxkeep' 'WORK_DIR=/srv/bob/work' \
    'AUDIT_LOG=/var/log/tmuxkeep/audit.log' 'LAUNCH_CMD=htop' 'RESUME_CMD=' 'LEASE_SECS=600' \
    'TOMBSTONE_TTL=86400' 'OTP_FAIL_MAX=3' 'OTP_FAIL_WINDOW=600' 'OTP_COOLDOWN=300' 'OTP_HARD_MAX=10' \
    'OTP_READ_TIMEOUT=60' 'SEND_MAX_BYTES=8000')" ]
}

@test "write_vps_conf installs a checked file, root 0644, through a temp file" {
  TK_USER=claude
  TK_HOME=/home/claude
  run write_vps_conf "$BATS_TEST_TMPDIR/broker"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a %U %G' /etc/tmuxkeep/tmuxkeep.conf)" = '644 root root' ]
  cmp /etc/tmuxkeep/tmuxkeep.conf /src/tests/fixtures/tmuxkeep.conf
  [ ! -e /etc/tmuxkeep/.tmuxkeep.conf.new ]
}

@test "write_vps_conf runs the check with bash, so a staged broker without the execute bit works (mode 0600)" {
  TK_USER=claude
  TK_HOME=/home/claude
  cp /src/vps/tmuxkeep "$BATS_TEST_TMPDIR/staged-broker"
  chmod 0600 "$BATS_TEST_TMPDIR/staged-broker"
  [ ! -x "$BATS_TEST_TMPDIR/staged-broker" ]
  run write_vps_conf "$BATS_TEST_TMPDIR/staged-broker"
  [ "$status" -eq 0 ]
  cmp /etc/tmuxkeep/tmuxkeep.conf /src/tests/fixtures/tmuxkeep.conf
  [ ! -e /etc/tmuxkeep/.tmuxkeep.conf.new ]
}

@test "write_vps_conf with a mode 0600 staged broker still refuses a configuration the broker rejects" {
  printf 'previous\n' > /etc/tmuxkeep/tmuxkeep.conf
  TK_USER=claude
  TK_HOME='/home/cl aude'
  cp /src/vps/tmuxkeep "$BATS_TEST_TMPDIR/staged-broker"
  chmod 0600 "$BATS_TEST_TMPDIR/staged-broker"
  run write_vps_conf "$BATS_TEST_TMPDIR/staged-broker"
  [ "$status" -ne 0 ]
  [[ "$output" == *'tmuxkeep: config invalid: /etc/tmuxkeep/.tmuxkeep.conf.new: USER_HOME: must be an absolute path'* ]]
  [ "$(cat /etc/tmuxkeep/tmuxkeep.conf)" = previous ]
  [ ! -e /etc/tmuxkeep/.tmuxkeep.conf.new ]
}

@test "write_vps_conf refuses to move the checked file into a directory that sits at the destination (mv -fT)" {
  mkdir /etc/tmuxkeep/tmuxkeep.conf
  TK_USER=claude
  TK_HOME=/home/claude
  run write_vps_conf "$BATS_TEST_TMPDIR/broker"
  [ "$status" -ne 0 ]
  [[ "$output" == *'cannot move /etc/tmuxkeep/.tmuxkeep.conf.new to /etc/tmuxkeep/tmuxkeep.conf'* ]]
  [ -z "$(ls -A /etc/tmuxkeep/tmuxkeep.conf)" ]
  [ ! -e /etc/tmuxkeep/.tmuxkeep.conf.new ]
}

@test "write_vps_conf fails and keeps the installed file when the broker rejects the new one (plan Q7)" {
  printf 'previous\n' > /etc/tmuxkeep/tmuxkeep.conf
  TK_USER=claude
  TK_HOME='/home/cl aude'
  run write_vps_conf "$BATS_TEST_TMPDIR/broker"
  [ "$status" -ne 0 ]
  [[ "$output" == *'tmuxkeep: config invalid: /etc/tmuxkeep/.tmuxkeep.conf.new: USER_HOME: must be an absolute path'* ]]
  [[ "$output" == *'/etc/tmuxkeep/tmuxkeep.conf was not installed'* ]]
  [ "$(cat /etc/tmuxkeep/tmuxkeep.conf)" = previous ]
  [ ! -e /etc/tmuxkeep/.tmuxkeep.conf.new ]
}

@test "STAGED_FILES lists the eight VPS files in the spec order" {
  [ "${STAGED_FILES[*]}" = 'tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer' ]
}

@test "main installs sudoers through install_sudoers and checks the new VPS config with the STAGED broker before the broker is replaced" {
  local body="$BATS_TEST_TMPDIR/main.body" d b a c
  sed -n '/^main() {/,/^}/p' /src/vps/tmuxkeep-setup > "$body"
  grep -qx '  install_sudoers "$STAGE_DIR/sudoers.tmpl" || die "sudoers was not installed; $SUDOERS_DEST is unchanged"' "$body"
  grep -qx '  write_vps_conf "$STAGE_DIR/tmuxkeep" || die "stopping: $VPS_CONF was not updated"' "$body"
  # A rejected configuration must never leave a new broker next to an old configuration, and the
  # check never runs the installed broker.
  run grep -c 'write_vps_conf "$BROKER_DEST"' "$body"
  [ "$output" = 0 ]
  d=$(grep -n 'install -d -o root -g root -m 0755 "$TMUXKEEP_ETC"' "$body" | cut -d: -f1)
  b=$(grep -n 'write_vps_conf "$STAGE_DIR/tmuxkeep"' "$body" | cut -d: -f1)
  a=$(grep -n 'install -o root -g root -m 0755 "$STAGE_DIR/tmuxkeep" "$BROKER_DEST"' "$body" | cut -d: -f1)
  c=$(grep -n 'install_sshd_dropin "$STAGE_DIR/sshd.conf.tmpl"' "$body" | cut -d: -f1)
  [ "$d" -lt "$b" ]
  [ "$b" -lt "$a" ]
  [ "$a" -lt "$c" ]
  run grep -c 'visudo -c' "$body"
  [ "$output" = 0 ]
}
