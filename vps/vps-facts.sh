#!/bin/bash
case "$0" in *vps-facts.sh) ;; *) tr -d '\r' | bash -s -- "$@"; exit $? ;; esac #
export LC_ALL=C
# vps-facts.sh: read-only fact collection for tmuxkeep (spec 13). Prints Markdown.
#
# Run it from the laptop:
#   Get-Content .\vps\vps-facts.sh | ssh tmuxkeep-admin 'bash -s -- --user claude' | Out-File -Encoding utf8 docs\vps-facts.md
# --user NAME (default claude) is the account whose passwd entry is probed; it must match
# ^[a-z_][a-z0-9_-]{0,31}$. Bad usage exits 2, the only way this script exits non-zero.
#
# Lines 1 and 2 are deliberate. PowerShell 5.1 pipes this file with a UTF-8 BOM and CRLF
# line endings. Line 1 absorbs the BOM (at worst one harmless stderr line). When this
# script arrives on stdin, $0 is "bash", so line 2 hands the rest of stdin to a fresh
# 'bash -s -- "$@"' with every CR removed, so the arguments survive; the trailing " #"
# turns line 2's own CR into a comment. When run as a file, line 2 does nothing. Do not
# simplify them.
#
# Rules (plan Q6): strictly read-only. No files written, nothing installed. No set -e:
# every probe must survive a missing tool. Every probe runs with stderr merged into
# stdout, stdin closed and a 20 second limit. Nothing here prints environment variables,
# history, key material, or anything from the broker's private state directory.

PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

# run_probe LABEL TOOL CMD [ARG...]: run CMD; a missing TOOL or a failure yields an
# "(unavailable: ...)" line inside the fence instead of noise on stderr.
run_probe() {
  local label=$1 tool=$2 rc
  shift 2
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '(unavailable: %s exit 127)\n' "$label"
    return 0
  fi
  timeout 20 "$@" 2>&1 </dev/null
  rc=$?
  [ "$rc" -eq 0 ] || printf '(unavailable: %s exit %s)\n' "$label" "$rc"
  return 0
}

# probe CMD [ARG...]: one simple command, no shell involved.
probe() { run_probe "$*" "$1" "$@"; }

# probe_sh 'PIPELINE': a fixed pipeline; it fails if any stage fails.
probe_sh() { run_probe "$1" "${1%% *}" bash -c "set -o pipefail; $1"; }

section() { printf '\n%s\n\n```\n' "$1"; }
end_section() { printf '```\n'; }

main() {
  printf '# VPS facts\nGenerated: %s\nUser: %s\n' "$(date -u 2>&1)" "$target_user"

  section '## Distro'
  probe grep -E '^(PRETTY_NAME|ID|ID_LIKE|VERSION_ID)=' /etc/os-release
  probe uname -r
  end_section

  section '## Versions'
  probe tmux -V
  probe ssh -V
  probe dpkg-query -W -f='${Package} ${Version}\n' openssh-server tmux oathtool jq qrencode git curl e2fsprogs
  probe_sh 'oathtool --version | sed -n 1p'
  probe_sh 'bash --version | sed -n 1p'
  probe_sh 'systemctl --version | sed -n 1p'
  probe_sh 'command -v visudo'
  probe_sh 'command -v sudo'
  probe dpkg-query -W -f='${Package} ${Version}\n' sudo systemd-timesyncd dbus-user-session
  end_section

  section '## Package candidates'
  probe apt-cache --no-generate policy tmux oathtool jq qrencode
  end_section

  section '## oathtool stdin key'
  if command -v oathtool >/dev/null 2>&1; then
    # JBSWY3DPEHPK3PXP is the public RFC test key, not a secret.
    via_stdin=$(printf JBSWY3DPEHPK3PXP | timeout 20 oathtool --totp -b -N @0 - 2>&1)
    via_argv=$(timeout 20 oathtool --totp -b -N @0 JBSWY3DPEHPK3PXP 2>&1 </dev/null)
    printf 'stdin: %s\n' "$via_stdin"
    printf 'argv: %s\n' "$via_argv"
    if [ "$via_stdin" = "$via_argv" ] && [[ $via_argv =~ ^[0-9]{6}$ ]]; then
      echo MATCH
    else
      echo MISMATCH
    fi
  else
    echo 'oathtool not installed'
  fi
  end_section

  section '## sshd'
  probe grep -nE '^[[:space:]]*(Include|Match|PermitRootLogin|AllowUsers|PasswordAuthentication|UsePAM)' /etc/ssh/sshd_config
  probe ls -la /etc/ssh/sshd_config.d/
  probe_sh "grep -nHE '^[[:space:]]*(Include|Match|PermitRootLogin|AllowUsers|PasswordAuthentication|UsePAM)' /etc/ssh/sshd_config.d/*.conf"
  probe_sh "/usr/sbin/sshd -T -C user=root,host=localhost,addr=127.0.0.1 | grep -E '^(allowusers|usepam|pubkeyauthentication|authorizedkeysfile|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|clientaliveinterval|clientalivecountmax)'"
  end_section

  section '## logind'
  probe busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager KillUserProcesses
  probe_sh 'systemd-analyze cat-config systemd/logind.conf | grep -n KillUserProcesses'
  probe loginctl --no-pager list-users
  end_section

  section '## Time sync'
  probe timedatectl show -p NTPSynchronized -p Timezone
  end_section

  section '## Locale'
  probe locale
  probe cat /etc/default/locale
  probe_sh "locale -a | grep -iE '^(c\.utf-?8|en_us\.utf-?8)\$'"
  end_section

  section '## chattr and /var/log'
  probe findmnt -no FSTYPE,OPTIONS -T /var/log
  probe_sh 'command -v chattr'
  probe_sh 'command -v lsattr'
  probe lsattr -d /var/log
  end_section

  section '## /tmp cleanup'
  probe findmnt -no FSTYPE -T /tmp
  probe systemctl is-enabled tmp.mount systemd-tmpfiles-clean.timer
  probe_sh "systemd-tmpfiles --cat-config | grep -E '^[^#]*[[:space:]]/tmp([[:space:]]|\$)'"
  end_section

  section '## Root tmux sessions'
  probe ls -la /tmp/tmux-0/
  local s
  for s in /tmp/tmux-0/*; do
    [ -S "$s" ] || continue
    printf 'socket %s:\n' "$s"
    probe tmux -S "$s" ls
  done
  end_section

  section '## claude processes'
  probe_sh "ps -eo user,pid,etime,comm | awk 'NR==1 || \$4==\"claude\"'"
  end_section

  section '## Root Claude Code state'
  probe ls -ld /root/.claude /root/.local/bin/claude
  probe du -sh /root/.claude
  end_section

  section '## Disk'
  probe df -h / /home /var/log
  end_section

  section '## Users and groups'
  probe getent group docker
  probe getent passwd "$target_user"
  probe id
  end_section

  section '## Outbound HTTPS'
  local url
  for url in https://claude.ai/install.sh https://github.com; do
    printf '%s -> ' "$url"
    probe curl -fsS -o /dev/null -w '%{http_code}\n' --max-time 10 "$url"
  done
  end_section
}

# Arguments are parsed here, at top level, not inside the "main | tr" pipeline below (the
# pipeline's exit status is tr's). Usage errors exit 2; an unknown argument is never echoed.
target_user=claude
while [ "$#" -gt 0 ]; do
  case $1 in
    --user)
      if [ "$#" -lt 2 ]; then
        echo 'vps-facts: --user needs a value' >&2
        exit 2
      fi
      target_user=$2
      shift 2
      ;;
    *)
      echo 'vps-facts: unknown argument' >&2
      exit 2
      ;;
  esac
done
if ! [[ $target_user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo 'vps-facts: --user must match ^[a-z_][a-z0-9_-]{0,31}$' >&2
  exit 2
fi

# Whatever a tool prints, only printable ASCII, tab and newline leave this script
# (PowerShell decodes ssh output with the console code page).
main | tr -c '\11\12\40-\176' '?'
exit 0
