#!/usr/bin/env bats
# VPS configuration files checked against real sshd, visudo and tmux in the test image. The two
# templates are rendered the way tmuxkeep-setup renders them (__USER__ becomes the user name).
load helpers

setup() {
  cp /etc/ssh/sshd_config "$BATS_TEST_TMPDIR/sshd_config.orig"
  rm -f /etc/ssh/sshd_config.d/tmuxkeep.conf
}
teardown() {
  rm -f /etc/ssh/sshd_config.d/tmuxkeep.conf /etc/tmuxkeep/tmux.conf
  cp "$BATS_TEST_TMPDIR/sshd_config.orig" /etc/ssh/sshd_config
  teardown_local
}

effective() { /usr/sbin/sshd -T -C "user=$1,host=localhost,addr=127.0.0.1"; }
render() { sed "s/__USER__/$2/g" "$1"; }   # render TEMPLATE USER

@test "sudoers.tmpl holds the three spec rules for __USER__, and every rendering passes visudo -cf" {
  grep -qxF '__USER__ ALL=(root) NOPASSWD: /usr/bin/apt-get update, /usr/bin/apt-get install *' /src/vps/sudoers.tmpl
  grep -qxF '__USER__ ALL=(root) NOPASSWD: /usr/bin/systemctl restart *, /usr/bin/systemctl reload *, /usr/bin/systemctl status *' /src/vps/sudoers.tmpl
  grep -qxF '__USER__ ALL=(root) NOPASSWD: /usr/bin/journalctl *' /src/vps/sudoers.tmpl
  [ "$(grep -c '^[^#]' /src/vps/sudoers.tmpl)" -eq 3 ]
  local u
  for u in claude bob _svc a-b; do
    render /src/vps/sudoers.tmpl "$u" > "$BATS_TEST_TMPDIR/s"
    run visudo -cf "$BATS_TEST_TMPDIR/s"
    [ "$status" -eq 0 ] || { echo "visudo rejected the rendering for $u"; return 1; }
  done
}

@test "the templates name the user only through __USER__" {
  run grep -n claude /src/vps/sudoers.tmpl /src/vps/sshd.conf.tmpl
  [ "$status" -eq 1 ]
  grep -qx 'Match User __USER__' /src/vps/sshd.conf.tmpl
  [ "$(grep -c __USER__ /src/vps/sshd.conf.tmpl)" -eq 1 ]
  [ "$(grep -c __USER__ /src/vps/sudoers.tmpl)" -eq 3 ]
}

@test "the rendered drop-in parses and applies its settings to the user (claude and bob)" {
  grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config
  local u
  for u in claude bob; do
    render /src/vps/sshd.conf.tmpl "$u" > /etc/ssh/sshd_config.d/tmuxkeep.conf
    run /usr/sbin/sshd -t
    [ "$status" -eq 0 ]
    run effective "$u"
    [ "$status" -eq 0 ]
    [[ "$output" == *"authorizedkeysfile /etc/tmuxkeep/authorized_keys"* ]]
    [[ "$output" == *"passwordauthentication no"* ]]
    [[ "$output" == *"disableforwarding yes"* ]]
    [[ "$output" == *"permituserrc no"* ]]
    [[ "$output" == *"clientaliveinterval 30"* ]]
    [[ "$output" == *"clientalivecountmax 4"* ]]
  done
}

@test "root's effective sshd config is unchanged by the drop-in" {
  run effective root
  local before=$output
  render /src/vps/sshd.conf.tmpl claude > /etc/ssh/sshd_config.d/tmuxkeep.conf
  run effective root
  [ "$output" = "$before" ]
}

@test "the drop-in with Match all keeps later main-config directives global for root" {
  # Debian's sshd_config sets X11Forwarding yes after its Include line.
  grep -q '^X11Forwarding yes' /etc/ssh/sshd_config
  render /src/vps/sshd.conf.tmpl claude > /etc/ssh/sshd_config.d/tmuxkeep.conf
  run effective root
  [[ "$output" == *"x11forwarding yes"* ]]
}

@test "uncommenting the whole PermitRootLogin line hardens root over a later 'yes'" {
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  render /src/vps/sshd.conf.tmpl claude > /etc/ssh/sshd_config.d/tmuxkeep.conf
  run effective root
  [[ "$output" == *"permitrootlogin yes"* ]]
  render /src/vps/sshd.conf.tmpl claude \
    | sed -E 's/^#[[:space:]]*PermitRootLogin prohibit-password.*/PermitRootLogin prohibit-password/' \
    > /etc/ssh/sshd_config.d/tmuxkeep.conf
  run /usr/sbin/sshd -t
  [ "$status" -eq 0 ]
  run effective root
  [[ "$output" == *"permitrootlogin without-password"* || "$output" == *"permitrootlogin prohibit-password"* ]]
}

@test "systemd units carry the spec values" {
  grep -qx 'Type=oneshot' /src/vps/systemd/tmuxkeep-reaper.service
  grep -qx 'ExecStart=/usr/local/bin/tmuxkeep --key reaper reap' /src/vps/systemd/tmuxkeep-reaper.service
  grep -qx 'OnCalendar=hourly' /src/vps/systemd/tmuxkeep-reaper.timer
  grep -qx 'RandomizedDelaySec=5min' /src/vps/systemd/tmuxkeep-reaper.timer
  grep -qx 'Persistent=true' /src/vps/systemd/tmuxkeep-reaper.timer
  grep -qx 'WantedBy=timers.target' /src/vps/systemd/tmuxkeep-reaper.timer
}

@test "the broker applies /etc/tmuxkeep/tmux.conf when it starts the server" {
  setup_local
  cp /src/vps/tmux.conf /etc/tmuxkeep/tmux.conf
  mk_lease t -
  run tmuxkeep new cfgtest
  [ "$status" -eq 0 ]
  [ "$(tm show-options -gv history-limit)" = 50000 ]
  [ "$(tm show-options -sv escape-time)" = 10 ]
  [ "$(tm show-options -gv default-terminal)" = tmux-256color ]
  [ "$(tm show-options -gv set-titles)" = off ]
}

@test "config files have no carriage returns" {
  run grep -l $'\r' /src/vps/tmux.conf /src/vps/sudoers.tmpl /src/vps/sshd.conf.tmpl \
    /src/vps/systemd/tmuxkeep-reaper.service /src/vps/systemd/tmuxkeep-reaper.timer
  [ "$status" -eq 1 ]
}
