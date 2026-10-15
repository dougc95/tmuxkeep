# tmuxkeep

Long-running command-line sessions on your own VPS, driven from your laptop through one restricted SSH key.

## Overview

tmuxkeep keeps your sessions in tmux on a VPS and gives the laptop a small `tmuxkeep` command over them.

- **Sessions in tmux on your VPS.** Each session is a tmux session in its own work directory, so it survives dropped SSH connections, laptop sleep and closed terminals. A VPS reboot ends the tmux server, but the work directories survive and `tmuxkeep resume` recreates the session.
- **One SSH round trip per command.** `tmuxkeep new`, `ls`, `peek`, `go`, `send`, `rename`, `lock`, `unlock`, `rm`, `restore`, `resume`, `log`, `auth` and `status` each make one `ssh` call. You never handle tmux by hand.
- **A local dashboard.** `tmuxkeep ui` opens a page on the laptop with every session, a live preview of its last lines and buttons for the everyday verbs, over the same key and the same gate (see "Dashboard").
- **Soft delete.** `tmuxkeep rm` renames the session to a tombstone and leaves it running; `tmuxkeep restore` brings it back.
- **A TOTP gate.** Anything that changes a session needs a six-digit code from your authenticator app. A good code opens a lease, so the next few commands do not ask again.
- **An append-only audit log.** Every call, accepted or refused, is appended to `/var/log/tmuxkeep/audit.log`, a file the session user can append to but cannot rewrite.
- **An hourly reaper.** A systemd user timer kills tombstones that are older than `TOMBSTONE_TTL`.

**Security model, in one paragraph.** A restricted SSH key (the session key) is forced into one bash program on the VPS, the broker (`/usr/local/bin/tmuxkeep`). The broker validates every request, never passes your words through a shell, asks for a TOTP code before anything that changes a session, and appends every call to a log that the session user cannot rewrite. Root on the VPS is reached only through a second key, protected by a passphrase and used for deploys. The security is deliberately soft: the gate protects against someone who holds your laptop or a copy of its keys, not against code that already runs as the session user on the VPS. Read "Security model and residual risks" before relying on it.

**Platforms.** On the laptop: Windows PowerShell 5.1 (`powershell.exe`; not `pwsh`), or bash 3.2 or later on macOS and Linux (WSL included). On the VPS: Debian or Ubuntu with systemd, and root access for the install.

**Two SSH identities** reach the same host, and they are never mixed:

| Alias | Key | Runs as | Use |
|---|---|---|---|
| `tmuxkeep` | the session key (`KEY`, no passphrase) | `USER` (default `claude`), through the forced command `/usr/local/bin/tmuxkeep --key laptop` | all day-to-day session work |
| `tmuxkeep-admin` | the admin key (`ADMIN_KEY`, with a passphrase) | `root`, a normal shell | deploys and emergencies only |

It was built for Claude Code, and its default session commands start it, but any long-running command-line tool works.

Licence: MIT, see `LICENSE`.

## Install on Windows

Everything in this section is done by the operator, in a real terminal, because it needs passphrases. Examples use `203.0.113.10` as the VPS address and `C:\Users\you` as the laptop home directory.

**Prerequisites.**

- Windows PowerShell 5.1 (`powershell.exe`). The scripts are not written for `pwsh`, and `deploy.ps1` refuses to run under it.
- The Windows OpenSSH client (`ssh`, `scp`, `ssh-keygen`) on the PATH.
- `git` on the PATH, and this repository as a git checkout. Deploy stamps the broker with the git short hash and refuses to run outside a checkout.
- An authenticator app on your phone.
- A Debian or Ubuntu VPS with systemd, and root on it (the root password or your provider's console, once, for step 2).

Docker Desktop and Pester are only needed for the tests.

### 1. Initialise: config, session key and ssh aliases

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 -Init
```

On the first run it asks one question, `VPS address (hostname or IP)`, checks the answer and writes `C:\Users\you\.tmuxkeep\config` with every key present, the defaults filled in and a one-line comment above each key (see "Configuration"). It then creates the session key `C:\Users\you\.ssh\id_tmuxkeep_ed25519` if it is missing (no passphrase: the TOTP code is the second factor) and writes both `Host` blocks, `tmuxkeep` and `tmuxkeep-admin`, into `C:\Users\you\.ssh\config`. Then it stops: it prints `deploy: init done: config, laptop key and ssh config are ready.` followed by the admin-key steps below. `-Init` contacts no server, and you can run it again at any time; it never replaces an existing key.

### 2. The admin key

Deploys run as root over the alias `tmuxkeep-admin`, with a key that has a passphrase. Create it and install it with one password login. These are the three steps as `-Init` prints them (the key path, `HOST` and `PORT` come from your config):

```
1. ssh-keygen -t ed25519 -f C:\Users\you\.ssh\id_tmuxkeep_admin_ed25519 -C tmuxkeep-admin        (set a passphrase)
2. Install it on the VPS with one password login:
   ssh root@203.0.113.10 -p 22 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && echo <contents of ~/.ssh/id_tmuxkeep_admin_ed25519.pub> >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true

Never ssh-add the admin key and never set AddKeysToAgent for it.
```

- The passphrase is required (do not leave it empty): it is what keeps a thief of the laptop away from root.
- Deploy refuses to continue (`deploy: your ssh config loads keys into an agent for tmuxkeep-admin; ...`) if your ssh configuration would load the admin key into an agent or the keychain. Its own block says `AddKeysToAgent no` for `tmuxkeep-admin` and sits first in the file, so if you see the message the likeliest cause is an older block: a block that an earlier deploy appended at the end of the file is replaced where it is and never moved, so delete that block (everything from `# >>> tmuxkeep` to `# <<< tmuxkeep`) and deploy again, and the new one is written at the top. Another cause is an `Include` or a hand edit that sets the option earlier. Either way the fix is `AddKeysToAgent no` under `Host tmuxkeep-admin`, before any `Host *` block.
- Step 2 shows the first line of the `.pub` file when the file exists. At `-Init` time it does not exist yet, so you see the placeholder `<contents of ~/.ssh/id_tmuxkeep_admin_ed25519.pub>`: run `-Init` again after step 1 and it fills the line in, or paste the line yourself. Use the command as printed. Piping the key with `Get-Content` makes Windows PowerShell 5.1 add a trailing CR and, on a UTF-8 console, a byte-order mark, and sshd then ignores the key line (see Troubleshooting).
- The first connection asks you to accept the host key of the VPS. Compare the fingerprint with your provider's console if you can.
- Step 3 must ask for the passphrase and exit 0. Do not continue until it does.

The same text is printed again if the first deploy cannot use the admin key.

### 3. Check the VPS (facts script, recommended)

From the repository root, run the read-only facts script over the admin path. It writes nothing on the VPS and prints no keys or secrets. The output file is git-ignored, so it never reaches the repository.

```powershell
Get-Content .\vps\vps-facts.sh | ssh tmuxkeep-admin 'bash -s' | Out-File -Encoding utf8 docs\vps-facts.md
```

For a `USER` other than `claude`, report on that account instead: `ssh tmuxkeep-admin 'bash -s -- --user <name>'`.

You may see one line such as `bash: line 1: $'\357\273\277#!/bin/bash\r': No such file or directory`. That is PowerShell's byte-order mark hitting line 1 of the script and it is harmless: the script is built to survive PowerShell's BOM and CRLF piping. Any other error line is worth a look. Skim `docs\vps-facts.md` for what the installer will insist on:

- Debian or Ubuntu with apt and systemd, and tmux 3.0 or newer available.
- `KillUserProcesses` not `yes` (otherwise tmux dies when a login ends).
- `/etc/ssh/sshd_config` has an `Include` for `sshd_config.d`; sshd has `pubkeyauthentication yes`; there is no `AllowUsers`, or one that includes `USER`. The installer does not check `DenyUsers`, `AllowGroups` or `DenyGroups`, and the facts script does not print them, so look yourself (no output means none is set):

  ```powershell
  ssh tmuxkeep-admin "/usr/sbin/sshd -T | grep -E '^(denyusers|allowgroups|denygroups)'"
  ```
- No sshd drop-in that sorts before `tmuxkeep.conf` and sets `PermitRootLogin` (it would make `-HardenRoot` abort).
- The clock is synchronized with NTP; `chattr` works on `/var/log`; the `C.UTF-8` locale exists; outbound HTTPS works (for `--repo` clones, and for the tool install when `INSTALL_CLAUDE_CODE=yes`).
- Existing root tmux sessions and `claude` processes running as root: these feed "Migrating work from root".

### 4. Choose your settings (optional)

The defaults start `claude` in every new session. Edit `C:\Users\you\.tmuxkeep\config` before the first deploy if you want something else. The most common edits:

- `INSTALL_CLAUDE_CODE=yes` makes the installer install the `claude` command for `USER`. With `no` (the default) it installs nothing, so the default `LAUNCH_CMD=claude` would find no command.
- `LAUNCH_CMD` and `RESUME_CMD` are what a new and a resumed session type. Set them to your own tool (for example `LAUNCH_CMD=htop`), or leave them empty to get a plain shell.
- `USER` is the VPS account that owns the sessions. Choose it now: changing it later is a manual procedure (see "Changing the VPS user").

Use an editor that keeps LF line endings and saves UTF-8 without a BOM (or plain ASCII). Deploy rejects a file with a CR or a BOM and names the problem. Every key is described in "Configuration".

### 5. First deploy

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1
```

It asks for the admin-key passphrase twice, once for `scp` and once for `ssh`. Both use `PreferredAuthentications=publickey`, so a missing or wrong admin key stops at the `scp` step with the admin-key instructions instead of falling back to the root password. In order, deploy:

1. Reads the config, creates the session key if it is missing, and writes the `# >>> tmuxkeep` block with the two `Host` entries into `C:\Users\you\.ssh\config` (replacing the block in place if it is already there).
2. Stages the VPS files (LF line endings, the broker stamped with the git short hash, plus `-dirty` if the tree has changes), your session public key as `laptop.pub` and `deploy.conf` in `%TEMP%\tmuxkeep-stage-<timestamp>`, copies them to `/root/tmuxkeep-deploy-<timestamp>` on the VPS, and runs `tmuxkeep-setup` there. The VPS directory is removed after setup runs, even if setup fails, and the local staging folder is removed on every exit path.
3. Copies `laptop\tmuxkeep.ps1` to `C:\Users\you\scripts\tmuxkeep.ps1` and writes `laptop\profile-snippet.ps1` (the `tmuxkeep` function and its tab completer) into your `$PROFILE` between `# >>> tmuxkeep` and `# <<< tmuxkeep` markers, replacing the block in place if it is already there. `$PROFILE` is the one of the console that ran deploy (`powershell.exe`); the ISE and editors use other profile files. It also replaces `C:\Users\you\scripts\tmuxkeep-dashboard` with a copy of the repository's `dashboard\` folder (without `test\`): the local dashboard that `tmuxkeep ui` starts.
4. Runs `ssh -o BatchMode=yes tmuxkeep ls` as proof of life and prints `deploy: proof of life exit N` (0 means the session key works), then `dashboard: installed at C:\Users\you\scripts\tmuxkeep-dashboard (run: tmuxkeep ui)` and `deploy: done. Open a new PowerShell window to load the tmuxkeep function.`

Open a new PowerShell window afterwards so the profile loads the `tmuxkeep` function. Windows' default execution policy (`Restricted`) blocks profiles and scripts, so if the new window prints `running scripts is disabled on this system`, or `tmuxkeep` is not recognized, allow local scripts once and open a new window again:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**The first run prints the TOTP secret** as an `otpauth://` URL and a QR code, once. Scan the QR code into your authenticator app (if your terminal garbles it, type the `secret=` value in by hand). Never paste, log or screenshot that output, and never hand it to an agent or a chat. Later runs print `TOTP secret: kept` and show nothing. If you lose it, use `-RotateTotp` (step 8).

**What `tmuxkeep-setup` installs on the VPS.** The packages `tmux oathtool jq qrencode e2fsprogs git curl util-linux`; the `USER` account (created with `useradd -m -s /bin/bash` when it does not exist, password disabled, added to the `docker` group if that group exists); the sudoers allowlist `/etc/sudoers.d/tmuxkeep`; the broker `/usr/local/bin/tmuxkeep`; `/etc/tmuxkeep/tmux.conf`, `/etc/tmuxkeep/tmuxkeep.conf` and the root-owned `/etc/tmuxkeep/authorized_keys`; the sshd drop-in `/etc/ssh/sshd_config.d/tmuxkeep.conf`; state in `<USER_HOME>/.tmuxkeep` and work directories in `<USER_HOME>/work`; the append-only audit log `/var/log/tmuxkeep/audit.log`; linger plus the hourly `tmuxkeep-reaper` user timer; a PATH block in the `.profile` and `.bashrc` of `USER`; and the `claude` command for `USER`, only when `INSTALL_CLAUDE_CODE=yes` (otherwise it prints `Claude Code: not installed (INSTALL_CLAUDE_CODE=no)`). It is idempotent. Re-running deploy is how you update the broker and the configs after a `git pull`; the summary at the end shows the broker version, a `reaper timer:` line that should read `active`, and whether root hardening is on.

Deploy always installs your session key under the key id `laptop`, so one laptop works per VPS: deploying from a second machine replaces the first machine's key.

### 6. First-run checklist

`tmuxkeep-setup` prints this list at the end of every run (`<USER_HOME>` is the real home directory, `/home/claude` by default):

```
First run:
  1. Scan the QR code into an authenticator app.
  2. On the laptop: tmuxkeep new scratch, then tmuxkeep go scratch to check the session, detach with Ctrl-b d.
  3. Move any existing projects from /root to <USER_HOME>/work/ and stop any root tmux sessions (README section "Migrating work from root").
  4. Once tmuxkeep-admin logs in with the admin key, run deploy again with --harden-root (-HardenRoot on Windows).
```

With `INSTALL_CLAUDE_CODE=yes`, step 2 also tells you to finish the tool's own login inside the session. The first gated command prompts `TOTP: `; type the six digits (they are not echoed):

```powershell
tmuxkeep new scratch
tmuxkeep go scratch
```

Detach with `Ctrl-b d`; the session keeps running. Optionally run the end-to-end smoke test (see "Development and tests") once the first session works.

### 7. Harden root login

Only after `ssh -o PasswordAuthentication=no tmuxkeep-admin true` works with the admin key, and ideally with an admin session still open in another window:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 -HardenRoot
```

This sets `PermitRootLogin prohibit-password` in the sshd drop-in, so root can no longer log in with a password. Check that a password login is now refused. sshd still asks for a password under `prohibit-password`, so type the real root password: it must be refused (`Permission denied`).

```powershell
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no tmuxkeep-admin true
```

Hardening is sticky: once the installed drop-in has the uncommented line, every later plain deploy keeps it, and setup's summary shows `root hardening:  on`. There is no off switch. To undo it (or to get past the `refusing --harden-root` refusal described in Troubleshooting), comment the `PermitRootLogin prohibit-password` line out of `/etc/ssh/sshd_config.d/tmuxkeep.conf` over the admin path, then run `sshd -t` and `systemctl reload ssh`; the next plain deploy then leaves it commented. The installer refuses to harden if root login is already `no` or `forced-commands-only` (it would loosen it), and aborts and restores the previous drop-in if root's effective sshd settings change in any way other than `permitrootlogin` (see the Troubleshooting table).

### 8. Rotate the TOTP secret, clear a lockout

Both are deploy switches. They combine with each other and with `-HardenRoot`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 -RotateTotp
powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 -UnlockOtp
```

- `-RotateTotp` writes a new secret, resets the replay guard, deletes every lease, and prints a new `otpauth://` URL and QR code (scan it again; the old entry in your app stops working). Use it after losing the phone, after the secret was exposed, or when the installer says `totp.secret is malformed; re-run with --rotate-totp`.
- `-UnlockOtp` removes the hard-lock marker and truncates the failure list, which also ends any cooldown. See "TOTP, leases and lockout".

## Install on macOS and Linux

The steps are the same as on Windows (see "Install on Windows" for what each one does), with the bash deploy script. Everything here is done by the operator, in a real terminal. Examples use `203.0.113.10` as the VPS address and `/Users/you` (macOS) or `/home/you` (Linux) as the laptop home directory. WSL counts as Linux: run these steps inside WSL, where the keys and the config live in the WSL home.

**Prerequisites.**

- bash 3.2 or later (macOS ships 3.2 as `/bin/bash`; the scripts are written for it) and the usual POSIX tools.
- The OpenSSH client (`ssh`, `scp`, `ssh-keygen`) and `git`, and this repository as a git checkout.
- An authenticator app on your phone, and a Debian or Ubuntu VPS with systemd and root on it.
- Not supported: fish and `pwsh`.

**1. Initialise.**

```bash
bash laptop/deploy.sh --init
```

It asks `VPS address (hostname or IP): `, writes `~/.tmuxkeep/config`, creates `~/.ssh/id_tmuxkeep_ed25519` (no passphrase) if it is missing, writes both `Host` blocks into `~/.ssh/config` (a symlinked file is written through and stays a symlink), prints `deploy: init done: config, laptop key and ssh config are ready.` and then the admin-key steps. It contacts no server and can be repeated.

**2. The admin key.** The same three steps, as the bash deploy prints them:

```
1. ssh-keygen -t ed25519 -f /Users/you/.ssh/id_tmuxkeep_admin_ed25519 -C tmuxkeep-admin        (set a passphrase)
2. Install it on the VPS with one password login:
   ssh root@203.0.113.10 -p 22 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && echo <contents of ~/.ssh/id_tmuxkeep_admin_ed25519.pub> >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true

Never ssh-add the admin key and never set AddKeysToAgent for it.
```

Set a passphrase in step 1. As on Windows, step 2 shows the first line of the `.pub` file once it exists (run `--init` again after step 1), and step 3 must ask for the passphrase and exit 0. Accept the host key of the VPS the first time you connect. Deploy refuses to continue (`deploy: your ssh config loads keys into an agent for tmuxkeep-admin; ...`) if your ssh configuration would load the admin key into an agent or the macOS keychain. Its own block says `AddKeysToAgent no` for `tmuxkeep-admin` and sits first in `~/.ssh/config`, so if you see the message the likeliest cause is an older block: a block that an earlier deploy appended at the end of the file is replaced where it is and never moved, so delete that block (everything from `# >>> tmuxkeep` to `# <<< tmuxkeep`) and deploy again, and the new one is written at the top. Another cause is an `Include` or a hand edit that sets the option earlier. Either way the fix is `AddKeysToAgent no` under `Host tmuxkeep-admin`, before any `Host *` block. On macOS the block does not pin `UseKeychain` (an OpenSSH that does not know that option rejects the whole file): if the deploy refuses because your config has `UseKeychain yes` globally, add `UseKeychain no` under a `Host tmuxkeep-admin` section placed above your `Host *` block.

**3. Check the VPS (recommended).**

```bash
ssh tmuxkeep-admin 'bash -s' < vps/vps-facts.sh > docs/vps-facts.md
```

For a `USER` other than `claude`: `ssh tmuxkeep-admin 'bash -s -- --user <name>' < vps/vps-facts.sh > docs/vps-facts.md`. The file is git-ignored. Read it for the same things as on Windows (the list in step 3 there), and check the three sshd settings the installer does not check: `ssh tmuxkeep-admin "/usr/sbin/sshd -T | grep -E '^(denyusers|allowgroups|denygroups)'"` must print nothing, or nothing that excludes `USER`.

**4. Choose your settings (optional).** Edit `~/.tmuxkeep/config` before the first deploy, for example `INSTALL_CLAUDE_CODE=yes`, your own `LAUNCH_CMD` and `RESUME_CMD`, or a different `USER` (see "Configuration").

**5. First deploy.**

```bash
bash laptop/deploy.sh
```

It asks for the admin-key passphrase twice (scp, ssh), prints the TOTP secret and QR code once on the first run (scan it; never paste, log or screenshot it, never give it to an agent or a chat), and runs the same installer as the Windows deploy. On the laptop it installs:

- the wrapper as `~/.local/bin/tmuxkeep` (mode 0755),
- the completion script as `~/.tmuxkeep/completion.bash`,
- the dashboard as `~/.local/share/tmuxkeep/dashboard` (the repository's `dashboard/` without `test/`, replaced on every deploy; the last lines of deploy say `dashboard: installed at ... (run: tmuxkeep ui)`),
- a marked block in `~/.zshrc` when `$SHELL` ends in `zsh`, otherwise in `~/.bashrc`, replaced in place when it is already there.

The block, in full:

```bash
# >>> tmuxkeep
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
[ -n "$ZSH_VERSION" ] && { whence compdef >/dev/null || { autoload -U +X compinit && compinit -i; }; } && autoload -U +X bashcompinit && bashcompinit
[ -f "$HOME/.tmuxkeep/completion.bash" ] && . "$HOME/.tmuxkeep/completion.bash"
# <<< tmuxkeep
```

It puts `~/.local/bin` on the PATH once, and in zsh it loads `compinit` itself when `compdef` is missing (a fresh macOS account never ran it) before `bashcompinit`, so completion registers without an error at every shell start. Deploy ends with `deploy: done. Open a new terminal, or run: . ~/.zshrc` (or `~/.bashrc`). Setup also prints the first-run checklist (see step 6 on Windows).

**macOS and bash.** Terminal starts login shells, and a login bash reads `~/.bash_profile` (or `~/.profile`), not `~/.bashrc`. If you use bash on macOS, make `~/.bash_profile` source `~/.bashrc`, or the block never loads:

```bash
[ -f ~/.bashrc ] && . ~/.bashrc
```

**6. First session.** `tmuxkeep new scratch`, then `tmuxkeep go scratch`; the first gated command prompts `TOTP: `. Detach with `Ctrl-b d`.

**7. Harden root login.** Only after `ssh -o PasswordAuthentication=no tmuxkeep-admin true` works:

```bash
bash laptop/deploy.sh --harden-root
```

It is sticky, verified and undone exactly as on Windows (step 7 there): the check is `ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no tmuxkeep-admin true`, which must be refused.

**8. Rotate the TOTP secret, clear a lockout.**

```bash
bash laptop/deploy.sh --rotate-totp
bash laptop/deploy.sh --unlock-otp
```

The flags combine with each other and with `--harden-root`, and do what `-RotateTotp` and `-UnlockOtp` do on Windows. `--config <path>` uses another config file.

## Configuration

Two files carry the configuration, and the laptop file is the only one you edit.

### The laptop file, `~/.tmuxkeep/config`

On Windows `~` is your home directory (`C:\Users\you\.tmuxkeep\config`); on macOS and Linux it is `~/.tmuxkeep/config`. The first deploy or `-Init` / `--init` writes it with every key and a comment above each; edit it by hand and run deploy again to apply a change. Only `HOST` is required; any other missing key takes its default.

| Key | Default | Valid values | What it does |
|---|---|---|---|
| `HOST` | none, required | a hostname, an IPv4 address or an IPv6 address; `host:port` is rejected (put the port in `PORT`); an IPv6 address must not start with `:` (write `::1` as `0:0:0:0:0:0:0:1`) | The VPS address, written to both `Host` blocks as `HostName` |
| `PORT` | `22` | integer 1-65535 | SSH port of the VPS |
| `USER` | `claude` | `^[a-z_][a-z0-9_-]{0,31}$` | The VPS account that owns the tmux sessions; the installer creates it if it does not exist. Changing it after the first deploy is manual: see "Changing the VPS user" |
| `KEY` | `~/.ssh/id_tmuxkeep_ed25519` | a non-empty path without double quotes; `~` is your home directory | The session key, no passphrase. Deploy creates it (`ssh-keygen -t ed25519 -C tmuxkeep-laptop`) when it is missing |
| `ADMIN_KEY` | `~/.ssh/id_tmuxkeep_admin_ed25519` | as `KEY` | The admin key for root, with a passphrase, which you create yourself. Never add it to ssh-agent |
| `LAUNCH_CMD` | `claude` | 0-200 printable ASCII characters; empty means a shell only | Typed, then Enter, into every new session |
| `RESUME_CMD` | `claude --continue` | as `LAUNCH_CMD` | Typed by `resume` |
| `INSTALL_CLAUDE_CODE` | `no` | `yes` or `no` | `yes` installs Claude Code for `USER` on the next deploy (skipped when `claude` is already on `USER`'s login PATH) |
| `LEASE_SECS` | `1800` | integer 60-86400 | Seconds one TOTP code keeps the gated verbs open |
| `TOMBSTONE_TTL` | `86400` | integer 3600-2592000 | Seconds a removed session survives as a tombstone |
| `OTP_FAIL_MAX` | `3` | integer 1-20 | Wrong codes within `OTP_FAIL_WINDOW` that start a cooldown |
| `OTP_FAIL_WINDOW` | `600` | integer 60-86400 | Seconds over which wrong codes are counted |
| `OTP_COOLDOWN` | `300` | integer 10-86400 | Seconds of cooldown after the newest of those wrong codes |
| `OTP_HARD_MAX` | `10` | integer from `OTP_FAIL_MAX` to 100 | Wrong codes since the last good one that lock the gate until root (or `-UnlockOtp`) clears it |
| `OTP_READ_TIMEOUT` | `60` | integer 10-600 | Seconds the VPS waits at the `TOTP: ` prompt |
| `SEND_MAX_BYTES` | `8000` | integer 1-65536 | Largest text that `send` accepts, in bytes |
| `DASHBOARD_PORT` | `7707` | integer 1024-65535 | Loopback port of `tmuxkeep ui`; `--port` overrides it for one run. Laptop only: deploy never sends it to the VPS |
| `TERMINAL_CMD` | empty | at most 200 printable ASCII characters | Program that opens a terminal for **Attach** and **Authenticate** in the dashboard, split on single spaces with the wrapper command appended (for example `alacritty -e` or `wezterm start --`); empty picks the platform default (see "Dashboard"). A path with spaces is not supported. Laptop only |

**File rules.** One `KEY=value` per line; lines are trimmed; blank lines and lines that start with `#` are ignored. The key is everything before the first `=`, the value everything after it. No quotes, no escapes, no variable expansion. Keys are uppercase; an unknown key is an error that names the line, so a typo cannot silently fall back to a default. A key given twice: the last one wins. Values must be printable ASCII (0x20-0x7E); any other byte, including non-ASCII text, is an error. LF line endings only (a CR is an error) and no byte-order mark. Integers are 1 to 7 digits and range-checked. A bad file stops deploy with `deploy: config <path>: <reason>` before anything is touched.

`-Config <path>` (Windows) and `--config <path>` (macOS and Linux) make deploy use another file instead of `~/.tmuxkeep/config`. An explicitly empty `-Config ''` is an error, not a request for the default: deploy prints `deploy: -Config needs a path` and exits 2. In the bash deploy a `--config` that is missing its value, has an empty one, or is followed by something that starts with `--` (the next flag) prints the usage line and exits 2.

### The two ssh aliases

The aliases are fixed and not configurable: `tmuxkeep` reaches the broker as `USER`, `tmuxkeep-admin` reaches `root`. Deploy writes them into `~/.ssh/config` between markers (CRLF line endings from PowerShell, LF from bash); the values come from your config, and `KEY` and `ADMIN_KEY` are written as configured (double-quoted when the path contains a space):

```
# >>> tmuxkeep
Host tmuxkeep
    HostName 203.0.113.10
    Port 22
    User claude
    IdentityFile ~/.ssh/id_tmuxkeep_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 4
Host tmuxkeep-admin
    HostName 203.0.113.10
    Port 22
    User root
    IdentityFile ~/.ssh/id_tmuxkeep_admin_ed25519
    IdentitiesOnly yes
    AddKeysToAgent no
Host *
# <<< tmuxkeep
```

`AddKeysToAgent no` keeps the admin key out of any agent whatever the rest of your ssh configuration says. ssh uses the first value it finds for an option, which is why a new ssh block is written at the top of the file (see below) and why deploy checks the result with `ssh -G tmuxkeep-admin` before it connects to anything. The closing `Host *` line matters too: it ends the `tmuxkeep-admin` section, so that your own global lines (and any `Include`) that follow the block are global again instead of being swallowed by that host. The block has no `UseKeychain` line on purpose: OpenSSH checks every keyword in every section, so an OpenSSH that does not know the macOS option would reject your whole `~/.ssh/config`. On macOS, the check with `ssh -G` is the safeguard instead (see "The admin key" above).

**Write-or-replace.** Every deploy rewrites the `# >>> tmuxkeep` block in `~/.ssh/config` (and, for a full deploy rather than `-Init` / `--init`, in your PowerShell profile on Windows or in `~/.zshrc` / `~/.bashrc` on macOS and Linux), in place. A block that is not there yet is placed differently by file. In `~/.ssh/config` it is written at the top (after a leading UTF-8 byte-order mark, which stays first), followed by one empty line and then your previous text unchanged. In the PowerShell profile and the rc file it is appended at the end, after a blank line: a profile may start with `using` statements that nothing may precede, and an rc block above a later `compinit` would lose zsh completion. A block that is already there is replaced where it is and never moved. A changed `HOST` or `PORT` therefore takes effect on the next deploy, and a changed profile snippet or rc block does too. Text outside the markers is never touched. Deploy stops with a message instead of guessing if a file has more than one `# >>> tmuxkeep` line, or one without its `# <<< tmuxkeep` line; fix the file by hand.

### What crosses to the VPS: `deploy.conf`

Deploy never passes config values on the remote command line. It writes `deploy.conf` into the staging folder, with `USER`, `LAUNCH_CMD`, `RESUME_CMD`, `INSTALL_CLAUDE_CODE` and the eight tunables (`LEASE_SECS` through `SEND_MAX_BYTES`), copied from your config. It has no `HOST`, no `PORT`, no key path and no secret. The installer reads it with `--conf` and validates every key again with the same rules, because the staging folder crossed the network; a bad file stops it before any step with `tmuxkeep-setup: deploy.conf invalid: <path>: <reason>` (exit 2).

### The VPS file, `/etc/tmuxkeep/tmuxkeep.conf`

The installer writes this file on every deploy, owner `root:root`, mode `0644`: the `deploy.conf` values except `INSTALL_CLAUDE_CODE` (that one only matters to the installer itself), plus `USER_HOME` (from `getent passwd`, after the account exists), `STATE_DIR` (`<USER_HOME>/.tmuxkeep`), `WORK_DIR` (`<USER_HOME>/work`) and `AUDIT_LOG` (`/var/log/tmuxkeep/audit.log`). The laptop file is the single source of truth, so **edit the laptop file, not this one**: a hand edit on the VPS is overwritten by the next deploy.

- Before the file is moved into place, the installer checks a temporary copy with the new broker from the staging folder, run as `bash tmuxkeep --check-conf <file>` (a local, root-run mode of the broker: exit 0 for a valid file, 1 with `tmuxkeep: config invalid: <reason>` otherwise). This happens before the installed broker is replaced, so a rejected configuration leaves the old broker and the old file untouched (`tmuxkeep-setup: the broker rejected the new configuration; /etc/tmuxkeep/tmuxkeep.conf was not installed`).
- The broker reads the file with its own strict parser on every call, and never sources it. A missing or invalid file makes it refuse every call with `tmuxkeep: config invalid: <path>: <reason>` (exit 1, no audit line, since the audit path itself comes from the file). Fix it by deploying again.
- The hourly reaper reads it too, so `TOMBSTONE_TTL` applies to it.
- Because root owns the file, a compromised `USER` cannot loosen the gate or redirect the audit log.

### A different command for one session: `--cmd` and `--shell`

`new <name>` and `resume <name>` accept an override for that one session. `--cmd <text>` types `<text>` (up to 200 printable ASCII characters) instead of `LAUNCH_CMD` or `RESUME_CMD`. `--shell` types no command and leaves the shell. `--shell` and `--cmd` together are a usage error (`--shell and --cmd cannot be combined`, exit 2), and a `--cmd` value of only spaces also means a shell only (the wrappers cannot send an empty word). The verbs are gated, and the audit line gains a `cmd` field with the text (empty for a shell only), so this is an audited, gated form of what `send` already allows.

```powershell
tmuxkeep new api --cmd 'npm run dev'
tmuxkeep new notes --shell
tmuxkeep resume api --shell
```

### Changing the VPS user

The installer does not move a deployment from one `USER` to another. It stops before it changes anything:

- if `USER` differs from the one in the installed `/etc/tmuxkeep/tmuxkeep.conf`: `tmuxkeep-setup: USER changed from <old> to <new> since the last deploy; see README "Changing the VPS user"`;
- if that file exists but names no `USER`, or the audit log belongs to another account: `tmuxkeep-setup: /etc/tmuxkeep/tmuxkeep.conf exists but names no USER; ...` and `tmuxkeep-setup: /var/log/tmuxkeep/audit.log is owned by <owner>, not <new>; ...`;
- if `USER` is an existing system account, with a uid outside 1000-59999 (`root`, `daemon`, `nobody`): `tmuxkeep-setup: refusing USER=<u>: uid <n> is a system account; choose a dedicated user name`.

The installer refuses system accounts, but an existing ordinary account such as `ubuntu` is accepted and gets its password disabled and its `authorized_keys` replaced by the forced-command file (sshd reads `/etc/tmuxkeep/authorized_keys` for it instead of its own), so choose a dedicated user name. It is also given the sudoers allowlist and, if the group exists, `docker` membership (see "Security model and residual risks").

To move from one user to another, work as root over `ssh tmuxkeep-admin`:

1. Disable the old user's reaper timer (find its uid with `id -u <old>`):

   ```
   runuser -u <old> -- env XDG_RUNTIME_DIR=/run/user/<old uid> systemctl --user disable --now tmuxkeep-reaper.timer
   ```
2. End (or finish with) the old user's tmux sessions. The new broker uses the new user's tmux server, so the old sessions are invisible to it. Leave the project directories where they are for now: `<new home>/work` is created by the deploy in step 5, and step 6 moves the projects into it.
3. Make sure the new account exists (`useradd -m -s /bin/bash <new>` if it does not; the installer would do the same), then give it the audit log. The log is append-only, so the flag comes off for the change and back on:

   ```
   chattr -a /var/log/tmuxkeep/audit.log && chown <new>:<new> /var/log/tmuxkeep/audit.log && chattr +a /var/log/tmuxkeep/audit.log
   ```
4. Remove the installed VPS config: `rm /etc/tmuxkeep/tmuxkeep.conf`. Until the next step finishes, the broker refuses every call because its config is missing.
5. Set the new `USER` in your laptop config and deploy again. The deploy creates `<new home>/work`. The new user has its own state folder, so the deploy also generates a new TOTP secret and prints it once, like a first install: scan the new QR code into your authenticator (the old secret does not work for the new user).
6. Move the project directories from `<old home>/work` into `<new home>/work` and `chown -R` them to the new user.

The installer never deletes accounts. It rewrites the sudoers file and the sshd drop-in for the new user only, so the old account loses both, but it keeps its home and its other group memberships; remove it yourself (`userdel -r <old>` also deletes its home) when you no longer need what is in it.

## Everyday use

The deploy puts the `tmuxkeep` command on your PATH: a PowerShell profile function on Windows (it runs `C:\Users\you\scripts\tmuxkeep.ps1`), `~/.local/bin/tmuxkeep` on macOS and Linux. `tmuxkeep <verb> [args]` runs `ssh tmuxkeep b64 <args>` (every word base64-encoded, so nothing is ever interpreted by a remote shell) with `-o BatchMode=yes -o ConnectTimeout=5`, adding `-t` for the verbs that can prompt for a code. A typical day:

```
tmuxkeep new api
tmuxkeep go api
tmuxkeep send api 'run the tests'
tmuxkeep peek api -n 60
tmuxkeep rm api
tmuxkeep restore api
```

| Verb | Arguments | Gated | What it does | Example |
|---|---|---|---|---|
| `new` | `<name> [--repo <https-url>] [--cmd <text>] [--shell]` | yes | Makes `<WORK_DIR>/<name>` (default `/home/claude/work/<name>`; clones the repo if given and the directory is new), starts a tmux session there and types `LAUNCH_CMD`. `--cmd` types `<text>` instead for this session; `--shell` types nothing and leaves the shell. Options may come before or after the name | `tmuxkeep new api --repo https://github.com/you/api.git` |
| `ls` | `[--names \| --tombstones]` | no | Table of sessions; the two flags print bare names for completion (not audited) | `tmuxkeep ls` |
| `peek` | `<name or tombstone> [-n N]` | no | Last N lines (default 40, 0-9999) of the pane, trailing blank lines dropped | `tmuxkeep peek api -n 100` |
| `go` | `<name>` | yes | Attaches your terminal; other clients are detached (`attach -d`); needs a real terminal | `tmuxkeep go api` |
| `send` | `<name> [text...]` | yes | Types the text literally into the pane, then Enter; at most `SEND_MAX_BYTES` (default 8000) bytes, no control characters | `tmuxkeep send api 'fix the build; then run tests'` |
| `rename` | `<old> <new>` | yes | Renames the session; the work directory stays where it is | `tmuxkeep rename api backend` |
| `lock` | `<name>` | no | Marks the session so `rm` refuses it | `tmuxkeep lock api` |
| `unlock` | `<name>` | yes | Clears the mark | `tmuxkeep unlock api` |
| `rm` | `<name> [--now --confirm <name>]` | yes | Soft delete (tombstone); with `--now`, kills the session | `tmuxkeep rm api` or `tmuxkeep rm api --now` |
| `restore` | `<name>` | no | Renames the newest tombstone of `<name>` back | `tmuxkeep restore api` |
| `resume` | `<name> [--cmd <text>] [--shell]` | yes | Types `RESUME_CMD` (default `claude --continue`) into an idle shell, or recreates a missing session from its work directory first. `--cmd` and `--shell` as for `new` | `tmuxkeep resume api` |
| `log` | `[-n N]` | no | Last N audit lines (default 50, 0-9999) | `tmuxkeep log -n 20` |
| `status` | `[--follow] [--lines N]` | no | One line of JSON: the lease and OTP state for this key and address, and every session with its last N pane lines (default 12, 0-40). Not audited. With `--follow` it writes one audit line, then a new line every 2 seconds until the connection closes. The dashboard uses it | `tmuxkeep status --lines 5` |
| `auth` | `[--end]` | yes (`--end` asks no code) | Always asks for a code and starts a lease. `--end` ends the lease of this key and address at once, without a code | `tmuxkeep auth --end` |
| `ui` | `[--port N] [--no-open]` | local | Starts the dashboard on this laptop (see "Dashboard"); never sent to the VPS | `tmuxkeep ui` |

There is also a `reap` verb that only runs locally on the VPS (the hourly timer runs `tmuxkeep --key reaper reap`); over SSH it is refused with `reap is local only`. The gated verbs are the eight marked "yes"; both laptop wrappers and the broker each carry that list, and a test keeps them equal.

`tmuxkeep ls` prints one row per session:

```
NAME               STATE      ATTACHED  AGE    IDLE   TITLE
api                live       *         3h     2m     Fix the failing build
docs               locked               2d     5h     Update the README
zz~old~1760000000  tombstone            1d     20h    Refactor parser
```

STATE is `live`, `locked` or `tombstone`; `*` means a client is attached; AGE and IDLE are time since creation and since the last activity; TITLE is the pane title that the program in the pane sets (40 columns at most, control characters removed).

Order of checks: the arguments are validated first (a typo never costs a TOTP prompt), then the gate asks for a code if there is no lease, then existence and state checks run. So `tmuxkeep go nosuch` prompts for a code before it says `no such session: nosuch`.

**Tab completion.** Both platforms complete the verbs, then session names after the verbs that take one (`peek go send rename lock unlock rm resume`), and the base names that have a tombstone after `restore`. Names come from `ssh tmuxkeep ls --names` (or `--tombstones`) and are cached for 60 seconds: in `%TEMP%\tmuxkeep-names.txt` and `%TEMP%\tmuxkeep-tombstones.txt` on Windows, in `${TMPDIR:-/tmp}/tmuxkeep-names-<uid>.txt` and `tmuxkeep-tombstones-<uid>.txt` on macOS and Linux. A failed fetch (offline, VPS down) is cached as an empty list for the same 60 seconds, by design, so an offline Tab waits at most about 5 seconds once (the ssh connect timeout) and then returns at once.

### Exit codes

`tmuxkeep` exits with the broker's code. Every broker failure prints one line `tmuxkeep: <message>` on stderr and writes one audit line, with three exceptions: `audit log not writable` (there is nothing to write the line to), a bad or missing VPS config (`tmuxkeep: config invalid: ...`, which cannot be audited either) and the wrapper's own local errors (printed on the laptop, never sent, never audited).

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | anything else: tmux error, `git clone` failed, audit log not writable, TOTP not configured, VPS config invalid |
| 2 | usage: unknown verb, bad name, missing or undecodable argument, control characters in text, `--shell` together with `--cmd`; also the wrapper's own local errors |
| 3 | refused: locked session, duplicate name, tombstone exists, directory in use, pane busy, hard OTP lockout |
| 4 | auth: wrong code, cooldown, no terminal for the prompt (also `go` without a terminal) |
| 5 | not found: no such session, no tombstone to restore, nothing to resume |
| 255 | ssh itself failed; the wrapper prints a hint (see Troubleshooting) |

### Names

A session name matches `^[a-z][a-z0-9_-]{0,31}$`: lowercase, starts with a letter, at most 32 characters. They start with a letter so PowerShell never reads a name as a number (it turns `1kb` into 1024). The work directory is always `<WORK_DIR>/<name>`, `/home/claude/work/<name>` by default. Names beginning with `zz~` belong to tombstones and are rejected by every verb except `peek` and `rm --now`.

### Soft delete, tombstones, locking

- `tmuxkeep rm api` does not kill anything. It renames the session to a tombstone `zz~api~<epoch>` and the program inside keeps running, unaware. `tmuxkeep ls` shows it with STATE `tombstone`; `tmuxkeep peek zz~api~1760000000` still reads it. The confirmation line says how long the tombstone lives, taken from `TOMBSTONE_TTL`: `reaped after 24h` for the default, `reaped after Nh` for any other whole number of hours, and `reaped after <TTL>s` when the value is not a multiple of 3600.
- `tmuxkeep restore api` renames the newest tombstone of `api` back (exit 3 if a live `api` exists, 5 if there is no tombstone). It needs no code.
- The hourly reaper (a systemd user timer for `USER`) kills tombstones strictly older than `TOMBSTONE_TTL` (default 24 hours). The timer runs hourly with up to 5 minutes of random delay, so a tombstone can live for up to about an hour and five minutes past `TOMBSTONE_TTL`.
- `tmuxkeep new api` is refused while a tombstone of `api` exists (exit 3; restore it or discard it first).
- `tmuxkeep rm api --now` kills the live `api` or, if there is none, the newest tombstone of `api`. The wrapper asks you to type the session name to confirm (`Type the session name to confirm:`); to script it, pass `--confirm api` yourself. The name must match exactly.
- `lock` is open on purpose (a quick safety catch), and `unlock` needs a code. A locked session cannot be removed (`rm` and `rm --now` exit 3 with `session api is locked`). A lock does not stop `go`, `send` or `rename`.
- `go` attaches with `tmux attach -d`, so it detaches clients left behind by dropped connections. Detach yourself with `Ctrl-b d`; the session keeps running. A program may ask something the first time it runs in a new directory (for example whether to trust it): `tmuxkeep go` into the session and answer.
- A VPS reboot kills tmux and with it every session, but the work directories survive. `tmuxkeep resume <name>` recreates the session in `<WORK_DIR>/<name>` and types `RESUME_CMD` (by default `claude --continue`, which finds the earlier conversation because the path is unchanged). If the session exists and sits at a shell prompt, `resume` types the command into it; if something else is running it refuses with `pane busy (<command>)`. A renamed session comes back only under its original name: `rename` leaves the work directory where it was and `resume` looks for `<WORK_DIR>/<name>`, so after a reboot run `tmuxkeep resume <old name>`; `tmuxkeep resume <new name>` finds no directory and says `nothing to resume`.

Without the wrapper (another terminal, a script) the plain form works for the open verbs, and gated ones need `-t`:

```
ssh tmuxkeep ls
ssh -t tmuxkeep go api
```

## Dashboard

`tmuxkeep ui` starts a small web server on the laptop and opens a page that shows every session with a live preview of its last lines, and buttons for the everyday verbs. It changes nothing about how tmuxkeep is secured: the page runs the same verbs over the same session key, the gate and the audit log still decide, and a TOTP code is only ever typed into a real terminal (see "The dashboard" under "Security model and residual risks").

**Requirements.** Node.js 20 or newer on the laptop (`node --version`) and nothing else: the dashboard has no packages to install and no build step. A laptop without Node loses only `tmuxkeep ui`. The VPS needs the broker from the same checkout, so deploy once after `git pull`.

**Install.** Deploy copies the repository's `dashboard/` folder, without its tests, next to the wrapper: `C:\Users\you\scripts\tmuxkeep-dashboard` on Windows, `~/.local/share/tmuxkeep/dashboard` on macOS and Linux. The folder is replaced on every deploy, and the last lines of deploy say where it is: `dashboard: installed at <dir> (run: tmuxkeep ui)`.

**Start and stop.**

```
tmuxkeep ui
tmuxkeep ui --port 8080 --no-open
```

It prints `tmuxkeep ui: http://127.0.0.1:7707/<token>/  (Ctrl-C stops)` and opens that address in your browser (`--no-open` skips that; open the printed address yourself). The server listens on `127.0.0.1` only and stays in the foreground; `Ctrl-C` stops it. `<token>` is 32 random hexadecimal characters, new on every start, so an address from an earlier run gets an empty `404` page. The port is `DASHBOARD_PORT` from `~/.tmuxkeep/config` (default `7707`); `--port N` overrides it for one run.

**The page.**

- The header shows the broker version; a dot for the connection to the VPS; the lease (`lease 23:10` counting down, `no lease`, `cooldown 4:59`, or `LOCKED`); and two buttons: **End lease** runs `tmuxkeep auth --end`, **Authenticate** opens a terminal that runs `tmuxkeep auth`.
- The dot is green while the page has a live connection to the VPS and a snapshot arrived within the last 10 seconds. Otherwise it is grey, and hovering over it shows why: `connecting`, the error of the connection, `no update for N s` (the connection is up but the broker has sent nothing for 10 seconds or more, as with a hung broker behind a live ssh), or that the local server is not running. A red banner, `not connected to the VPS: <reason>`, appears when the dot has been grey for 10 seconds, and at once for `no update for N s`.
- The sessions table: name, state, attached, age, idle time and title, as `tmuxkeep ls` shows them. Tombstones are in a collapsed group. Click a row to select it.
- The selected session shows its last 12 lines, updated every 2 seconds, and the buttons **Attach** (opens a terminal that runs `tmuxkeep go <name>`), **Lock** or **Unlock**, **Resume**, **More lines** (`peek -n 200`), **Remove** (soft delete: a tombstone) and **Send** (the text box; `Ctrl-Enter` sends). **Rename** takes the new name. **Remove now** kills the session and needs its name typed first, as the wrapper's prompt does. A tombstone has **Restore**, **More lines** and **Remove now**.
- **New session**: a name, an optional `https://` repository and an optional command, or **Shell only** (`new` with `--repo`, `--cmd`, `--shell`).
- **Show the last 100 audit lines** runs `log -n 100`; failures are marked.
- An action that fails shows the broker's own message and exit code; an exit 255 shows the wrapper's `ssh to host 'tmuxkeep' failed` line.

**When a verb needs a code.** If an action needs the TOTP gate and there is no lease, the page keeps the action, opens a terminal that runs `tmuxkeep auth` and says `type the code in the terminal that opened`. Type the code there. As soon as the page sees the new lease it sends the action once more by itself. Any other action, or 3 minutes without a lease, drops the waiting action. The code is never typed into the page.

**End lease.** A lease lets every gated verb through for `LEASE_SECS` (30 minutes by default) from your address, and the page can use it too. When you are done, press **End lease** (or run `tmuxkeep auth --end`): your lease ends at once, with no code, and the next gated action asks again. A shorter `LEASE_SECS` narrows the window further.

**What it costs.** While a page is open the server keeps one ssh connection running `tmuxkeep status --follow`, which writes one audit line when it starts and then sends a new snapshot every 2 seconds; if the connection drops it reconnects after 2, 4, 8 and 16 seconds and then every 30 seconds. When no page has asked for an update for 2 minutes (the tab was closed) it closes that connection, and the next page load opens it again. Each button is one ssh call, exactly like the same command typed in a terminal, and is audited like it; one action runs at a time.

**Terminals.** **Attach** and **Authenticate** open a terminal that runs the wrapper: on Windows a new Windows Terminal tab when `wt.exe` is installed, otherwise (or when `wt.exe` is found but fails to start) a new PowerShell console window, opened through `cmd.exe /c start`; on macOS a Terminal window; on Linux `x-terminal-emulator`, or `$TERMINAL` when that is not installed. `cmd.exe` expands `%` even inside quotes, so the console-window path refuses a home folder path that contains `"` or `%`, with `tmuxkeep ui: the home folder path contains " or %; set TERMINAL_CMD to open terminals another way`. To use another program, or to get past that refusal, set `TERMINAL_CMD` in `~/.tmuxkeep/config`: it is split on single spaces and the wrapper command is appended, so `TERMINAL_CMD=alacritty -e` runs `alacritty -e ~/.local/bin/tmuxkeep go api`. A program path with spaces is not supported there.

**Limits.** One VPS per dashboard; no terminal inside the page; no HTTPS and no login on the page (it is reachable from this laptop only); no mobile layout; and the server is not a background service: it runs while `tmuxkeep ui` runs. Text with line breaks or tabs cannot be sent, because the broker refuses control characters: send one line at a time.

## Quoting rules

Both wrappers send each word base64-encoded, so nothing after the laptop's own shell needs quoting. What matters is what your shell does to the words first.

### PowerShell 5.1

The words you type go through the PowerShell parser before `tmuxkeep` sees them.

- Single-quote inline text. Unquoted, PowerShell treats `;` as the end of the command, `#` as a comment, and `$`, `(`, `)`, `@`, `|`, `&`, `<`, `>` specially. Inside single quotes a literal single quote is written twice.

  ```powershell
  tmuxkeep send api 'fix the build; then run tests'
  tmuxkeep send api 'it''s done'
  tmuxkeep new api --cmd 'npm run dev'
  ```

  Without the quotes, `tmuxkeep send api fix the build; then run tests` sends `fix the build` and then tries to run a command called `then`. Do not use double quotes for text: they expand `$variables`.
- `tmuxkeep send api` with no text prompts locally (`Text to send:`) and sends exactly what you type. The prompt bypasses the PowerShell parser entirely, so it is the safest form for anything with punctuation, and the form to use for long text. An empty answer exits 2 with `tmuxkeep: nothing to send`.
- A comma makes an array: `tmuxkeep send api a, b` is one array argument. The wrapper flattens arrays and joins the words with single spaces, so the text sent is `a b` and the comma is lost. Quote the text if you want the comma.
- PowerShell drops a bare `--` before the wrapper sees it, so you cannot use `--` to end options (a quoted `'--'` does arrive). The wrapper rejects empty arguments (`''`) with `tmuxkeep: empty argument` and exit 2, and dictionary-like arguments (hashtables, XML nodes) with `tmuxkeep: unsupported argument type`.
- `-n` works (`tmuxkeep peek api -n 100`, `tmuxkeep log -n 20`) because the wrapper script has no `param` block and no `[CmdletBinding()]`: PowerShell therefore hands every word through verbatim instead of binding `-n` or `-d` to a common parameter. Do not add either to `tmuxkeep.ps1`.
- Text longer than `SEND_MAX_BYTES` bytes, or containing control characters, is refused (exit 2). Separate words are joined with single spaces, so a run of spaces between words collapses; one quoted word is sent exactly as typed.

### bash and zsh

- Normal shell quoting applies. Quote any text that contains characters your shell treats specially (`;`, `&`, `|`, `<`, `>`, `$`, `(`, `)`, `*`, `?`, backticks, quotes, and `#` in bash). Single quotes keep everything literal; a literal single quote inside them is written `'\''`. In zsh an unquoted word with `*` or `?` that matches no file is an error before `tmuxkeep` runs.

  ```bash
  tmuxkeep send api 'fix the build; then run tests'
  tmuxkeep send api 'it'\''s done'
  tmuxkeep new api --cmd 'npm run dev'
  ```
- `tmuxkeep send api` with no text prompts on the terminal (`Text to send: `, read from `/dev/tty`) and sends exactly what you type. An empty answer exits 2 with `tmuxkeep: nothing to send`. `tmuxkeep rm api --now` without `--confirm` prompts the same way (`Type the session name to confirm: `).
- `--` is passed through and sent like any word: `tmuxkeep send api -- text` types `-- text`. An empty argument (`''`) is rejected with `tmuxkeep: empty argument` and exit 2.
- `-n` works as it is: `tmuxkeep peek api -n 100`.
- Text longer than `SEND_MAX_BYTES` bytes, or containing control characters, is refused (exit 2). Separate words are joined with single spaces; one quoted word is sent exactly as typed.

## TOTP, leases and lockout

Anything that changes a session needs a TOTP code from the authenticator app (the code is always on the phone; nothing on the laptop can generate it). The gated verbs are `new go send rename unlock rm resume auth`. `ls`, `peek`, `log`, `lock` and `restore` never ask.

- `tmuxkeep auth` always prompts for a code, even while a lease is running, then prints `authenticated; lease valid for 30m` (the length follows `LEASE_SECS`). Run it first thing in a terminal session; it makes the next gated commands prompt-free.
- A successful code starts a lease of `LEASE_SECS` (default 1800 seconds, 30 minutes), kept per key id and client address. The lease is not extended by use. If your public address changes (VPN, hotspot), the next gated command prompts again.
- Without a lease, a gated command prompts `TOTP: ` on the VPS side of the terminal, with echo off and a timeout of `OTP_READ_TIMEOUT` seconds (default 60). The code is read on the VPS terminal, so it never appears in a command line, a process list or the audit log. The code for the previous, current and next 30-second step is accepted, and each code works once: a code that has just been used (or any earlier one) is refused, so wait for the next code. Phone and VPS clocks must be accurate (setup refuses to run without NTP on the VPS).
- `Ctrl+C` is ignored at the `TOTP:` prompt, on purpose: an abandoned prompt must still count. To give up, press Enter on an empty line (one failure) or wait for the timeout (also one failure).
- Every prompted attempt is counted before the code is checked. A wrong code, a malformed code, a timeout, an abandoned prompt and a dropped connection all count as failures. Refusals that happen before the prompt (no terminal, cooldown, missing secret, bad arguments) do not.
- `OTP_FAIL_MAX` failures (default 3) within `OTP_FAIL_WINDOW` seconds (default 600) start a cooldown: `cooldown, retry in <n>s` (exit 4) until `OTP_COOLDOWN` seconds (default 300) after the newest failure. A valid lease still lets other gated commands through during a cooldown, but `auth` does not.
- `OTP_HARD_MAX` failures (default 10) since the last successful code, however far apart, set a hard lock: `OTP locked after repeated failures; root must remove <USER_HOME>/.tmuxkeep/otp-locked` (exit 3). The lock overrides a valid lease for every gated verb. The open verbs keep working, so you can still `tmuxkeep ls` and `tmuxkeep log` to see what happened. A success clears the failure counters.
- Recover from a hard lock with either of these. From the repository root on the laptop:

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 -UnlockOtp
  ```

  ```bash
  bash laptop/deploy.sh --unlock-otp
  ```

  or, as root over the admin path (`ssh tmuxkeep-admin`):

  ```
  rm <USER_HOME>/.tmuxkeep/otp-locked
  ```

  The `rm` leaves the failure list as it was, so the very next attempt creates the lock again unless the code is correct (a correct code clears it). `-UnlockOtp` and `--unlock-otp` also truncate the failure list.
- Before you unlock, look at `tmuxkeep log -n 100` for the `otp-fail` lines and their `ip` field. An address you do not recognize is a warning sign and a reason to treat the session key as stolen (see "Security model and residual risks"). The log is a hint, not proof: it records broker calls only, and code running as `USER` can append lines of its own, so a clean-looking log does not clear the key.
- One prompt is handled at a time: while someone is typing a code, other gated calls wait for the prompt to finish (up to `OTP_READ_TIMEOUT` seconds).

## Migrating work from root

Do this over the admin path (`ssh tmuxkeep-admin`) when it suits you. Nothing in tmuxkeep touches `/root`. `<USER>` is the account from your config (default `claude`) and `<WORK_DIR>` is `<USER_HOME>/work` (default `/home/claude/work`).

1. List the root tmux sessions and any `claude` processes that run as root:

   ```
   tmux ls
   pgrep -u root -x claude
   ```
2. Finish or save the work in each one, then kill the session. Use the exact name; the leading `=` stops tmux from matching a prefix.

   ```
   tmux kill-session -t '=<name>'
   ```
3. Move the project into the work directory under a valid tmuxkeep name (the directory name is the session name), and give it to `<USER>`:

   ```
   mv /root/<project> <WORK_DIR>/<name>
   chown -R <USER>:<USER> <WORK_DIR>/<name>
   ```
4. On the laptop, recreate the session there:

   ```
   tmuxkeep resume <name>
   ```

   `resume` finds no running session, sees the directory, creates the session in it and types `RESUME_CMD`. With the default `claude --continue` that finds no earlier conversation, because the tool keys its history by path (and `/root/.claude` is not the history of `<USER>`), so it will not continue the old chat. Attach and start fresh with `tmuxkeep go <name>`; if the program is not already running there, type it at the prompt.
5. Check that no `claude` process is left running as root: `pgrep -u root -x claude` prints nothing. With `INSTALL_CLAUDE_CODE=yes`, deploy's report (setup's step 9) also warns `WARNING: claude is running as root` until none is left, and says `no tmux sessions owned by root` when the sessions are gone.

## Audit log and rotation

The log is `/var/log/tmuxkeep/audit.log` on the VPS: one JSON object per line, ASCII only (anything else is `\u`-escaped), with the keys `ts`, `key`, `ip`, `verb`, `session`, `ok`, `detail`, and an extra `cmd` key on `new` and `resume` when `--cmd` or `--shell` was used (the text typed, empty for a shell only).

```
{"ts":"2026-10-09T17:03:12Z","key":"laptop","ip":"198.51.100.7","verb":"rm","session":"api","ok":true,"detail":"tombstoned"}
{"ts":"2026-10-09T17:05:40Z","key":"laptop","ip":"198.51.100.7","verb":"new","session":"web","ok":true,"detail":"created dir=/home/claude/work/web","cmd":"npm run dev"}
```

- `ts` is UTC. `key` is the key id (`laptop`), `reaper` for the timer, or `local` for local calls. `ip` is the client address, `-` for local calls. `ok` is false for every refused or failed call, including bad names, wrong codes, cooldowns and lockouts.
- `detail` is a short fixed word or the error message: `created dir=<dir>` (plus ` repo=<url with credentials replaced by ***>`), `len:<bytes>` for `send` (the text itself is never logged), `tombstoned`, `killed <session>`, `restored from <tombstone>`, `to <new name>` (rename), `locked`, `unlocked`, `resumed`, `recreated`, `authenticated`, `attached`, `reaped`, `reap failed`, `listed`, `lines=<N>`, and for gate failures `otp-fail`, `cooldown`, `otp-locked`, `no-tty`. `go` logs `attached` just before it hands the terminal to tmux, so a failed attach is also logged as attached.
- `ls --names` and `ls --tombstones` are not logged. The reaper logs only when it kills something.
- Read it from the laptop with `tmuxkeep log -n 50` (the default), or filter the failures:

  ```powershell
  tmuxkeep log -n 500 | Select-String '"ok":false'
  ```

  ```bash
  tmuxkeep log -n 500 | grep '"ok":false'
  ```
- The directory is `root:root 0755`. The file belongs to `USER` and is marked append-only with `chattr +a`, so `USER` can append but cannot edit, truncate, rename or delete it. Root can.
- What the log does and does not prove: it records calls that went through the broker, nothing else. Anything running as `USER` (every session included) can append forged lines with any key, ip or verb, and can drive tmux directly, which leaves no audit line at all. Read it as a record of what the broker was asked to do, not as proof of what the key, or `USER`, did.

There is no automatic rotation. Rotate by hand as root over the admin path, now and then (check the size with `ls -lh /var/log/tmuxkeep`). Set `u` to your `USER`, then paste the whole block at once:

```
u=claude
a=/var/log/tmuxkeep/audit.log.$(date -u +%Y%m%d-%H%M%S)
chattr -a /var/log/tmuxkeep/audit.log && mv /var/log/tmuxkeep/audit.log "$a" && chown root:root "$a" && chmod 0600 "$a" && chattr +a "$a" && install -o "$u" -g "$u" -m 0640 /dev/null /var/log/tmuxkeep/audit.log && chattr +a /var/log/tmuxkeep/audit.log || echo 'ROTATION FAILED: re-run deploy (it restores +a on an existing log or recreates a missing one), then check ls -l /var/log/tmuxkeep'
```

It is one `&&` chain, so it stops at the first step that fails and prints `ROTATION FAILED`; in that case re-run deploy, which puts the append-only flag back on an existing live log or recreates a missing one with the right owner and `+a`. The archive ends up root-owned, mode 0600 and append-only. `mv` keeps the owner, so without the `chown` and `chmod` the archive would still belong to `USER`, which could then edit history in it; the append-only guarantee holds only for files that are root-owned or still flagged, and the chain gives the archive both. Archives keep `+a` by default, so run `chattr -a` on one before you compress, move or delete it. Keep any later copy or compressed version root-owned too.

Between the first `chattr -a` and the final `chattr +a`, the live log is briefly not append-only, which is why the block should run in one go. Between the `mv` and the `install`, audited commands fail closed with `audit log not writable`; nothing is lost.

## Security model and residual risks

What tmuxkeep is for, in priority order: stop the operator clobbering the wrong session; limit what a command run inside a session can do to the box by not running it as root; stop someone with the unlocked laptop or a copy of its keys from driving sessions or reaching root; and leave a record of what happened. It is not multi-tenant isolation, and it does not protect against root on the VPS being compromised or an attacker who already holds a live attached session.

What does hold:

- The session key is bound to one forced command (`restrict,pty,command="/usr/local/bin/tmuxkeep --key laptop"`). It cannot run anything else, forward ports or agents, or open a shell. `/etc/tmuxkeep/authorized_keys` and the broker are root-owned, `PermitUserRC no` and `DisableForwarding yes` apply to `USER`, and password login is off for `USER`.
- Changing anything needs a TOTP code, the broker never passes your words through a shell, tmux targets are matched by exact name, and `send` types text literally.
- The admin key has a passphrase and is kept out of any ssh agent, so the passphrase gates every deploy and every root login. The mechanism: deploy writes the `Host tmuxkeep-admin` block at the top of `~/.ssh/config`, where ssh finds it before any `Host *` block of yours, and the block pins `AddKeysToAgent no`; then it asks `ssh -G tmuxkeep-admin` (which reads the configuration and connects to nothing) and refuses to continue if the answer still loads keys into an agent or, on macOS, the keychain. With hardening (`-HardenRoot`, `--harden-root`), root cannot log in with a password at all.
- The VPS config `/etc/tmuxkeep/tmuxkeep.conf` is root-owned, so `USER` cannot loosen the gate tunables, redirect the audit log or change the session commands, and the broker fails closed (it refuses every call) when the file is missing or malformed.
- The existing audit log cannot be edited, truncated or replaced by `USER`, and the `TMUXKEEP_*` test overrides are ignored on remote calls. (It can still be appended to, see the limits below.)
- The sudoers and sshd templates substitute only the user name, which is validated against `^[a-z_][a-z0-9_-]{0,31}$`. The sudoers file is validated (`visudo -cf`) before it is installed. The sshd drop-in is written, checked (`sshd -t` and an effective-configuration comparison) and rolled back if any check fails, and sshd is never reloaded with an invalid file.
- Nothing secret is in the repository or in `deploy.conf`: keys, the TOTP secret and `docs/vps-facts.md` never enter it.
- Session commands are audited and readable, not secret: the text of a `--cmd` is written to the audit log, `tmuxkeep log` prints the log to anyone who holds the session key, and `LAUNCH_CMD` and `RESUME_CMD` sit in the world-readable `/etc/tmuxkeep/tmuxkeep.conf`. Never put a secret in any of them.

Residual risks, stated plainly:

- **The gate does not hold against code running as `USER`.** That includes every program you run in a session. Such code can read `totp.secret`, forge a lease, edit `.bashrc` (it is sourced before the forced command), and drive tmux directly. The TOTP gate protects against the holder of the laptop keys, not against anything already inside. A later version could split the SSH-facing user from the tmux-owning user.
- **Sessions share one tmux server and one user.** Any session can run `tmux kill-server`, or `send-keys` into another session and type into it.
- **`docker` group membership is root-equivalent.** If a `docker` group exists, `USER` is added to it; anyone who can run `docker` can mount the host and become root.
- **The sudoers allowlist is also effectively root-equivalent.** `USER` may run `apt-get update`, `apt-get install *`, `systemctl restart|reload|status *` and `journalctl *` as root without a password. The sure path to root is `apt-get install *`: it accepts `-o DPkg::Pre-Invoke::=<command>` and similar `-o` hook options that run a command as root, and it will install a local `.deb` whose maintainer scripts run as root. On older systemd (before 247), `systemctl status` and `journalctl` also open a pager as root, from which `!sh` gives a root shell; newer systemd runs the pager in secure mode when started through sudo, which blocks that escape. `systemctl restart|reload *` can also restart any unit. So running a session as `USER` instead of root reduces the damage a runaway command can do, it does not remove it. To drop the allowlist, edit `vps/sudoers.tmpl` and deploy again (setup reinstalls the file every run).
- **The lease is shared by everyone who uses the key from the same public address.** It is kept per key id and client address, not per person or terminal, so for `LEASE_SECS` after you authenticate anyone holding the session key who connects from the same public address (a shared NAT, a VPN exit, a public Wi-Fi) passes the gate without a code.
- **A key thief gets about three guesses per ten minutes** with the defaults (the cooldown) until the hard lock after ten failures. The same lock is a nuisance lever: someone with the key can lock you out until you run `-UnlockOtp` or `--unlock-otp`.
- **The audit log records broker calls only.** Anything running as `USER` can append forged lines with any key, ip or verb (the file is append-only, not append-restricted), and can drive tmux directly with no audit line at all. The log cannot be rewritten, but what is in it is not proof of what happened.
- **The open verbs need no code, so the key alone is enough to read.** Without the phone, someone holding the session key can `tmuxkeep ls`, read the scrollback of every pane with `tmuxkeep peek <name> -n 9999` (that includes anything a program printed, such as file contents and tokens), read the audit log with `tmuxkeep log`, and `tmuxkeep lock` your sessions. Only changing things is gated.
- **`.bashrc` is sourced before the forced command**, so anything that can write `<USER_HOME>/.bashrc` runs on every broker call. That again needs code running as `USER`.
- **`--cmd` and `LAUNCH_CMD` type text into a pane.** `--cmd` is an audited, gated form of what `send` already allows, and adds no capability. Whoever can edit `~/.tmuxkeep/config` on the laptop decides what the next deploy installs, `LAUNCH_CMD` included. That is the laptop's own trust level, and the admin passphrase still gates every deploy.
- **`git clone --repo` credentials leak locally.** A URL like `https://user:token@host/repo.git` is visible in the VPS process list during the clone and persists in the clone's `.git/config`. The audit log redacts the userinfo, but a raw `/` inside the userinfo defeats the redaction, so percent-encode any `/`, `@` or `:` in a token. Prefer URLs without credentials (public repositories, or a git credential helper configured for `USER`), and strip a stored one afterwards with `git remote set-url origin <url without credentials>`.
- Tombstoned sessions keep running (and keep working) for up to `TOMBSTONE_TTL`; `rm` is not a stop button.
- sshd settings the installer does not check can still lock `USER` out after a successful deploy: `DenyUsers`, `AllowGroups`, `DenyGroups` (only `AllowUsers` is checked). See Troubleshooting.

**How the installer treats sshd, so a mistake cannot lock you out.** The drop-in `/etc/ssh/sshd_config.d/tmuxkeep.conf` carries a `Match User <USER>` block (own `AuthorizedKeysFile`, `PasswordAuthentication no`, `DisableForwarding yes`, `PermitUserRC no`, keepalives) and ends with `Match all`. That final line is defensive; on OpenSSH 9.2 a Match block does not actually leak past the end of an included file, so it is not required there. The real guard is the installer's own check. It validates with `sshd -t`, then compares `sshd -T -C user=root,host=localhost,addr=127.0.0.1` before and after installing the drop-in. The only permitted difference is `permitrootlogin` (and only with hardening on); anything else aborts and restores the previous drop-in, or removes the new one. It also confirms that `<USER>` gets `authorizedkeysfile /etc/tmuxkeep/authorized_keys` and `passwordauthentication no`. Only then does it run `systemctl reload ssh`. Setup also refuses to run if any path it writes under `<USER_HOME>` is a symlink (see Troubleshooting).

**If the laptop or its session key is lost or stolen,** work over the admin path (`ssh tmuxkeep-admin`) in this order.

1. Delete the key's line from the root-owned file (sshd rereads it at the next login):

   ```
   sed -i '/ tmuxkeep-laptop$/d' /etc/tmuxkeep/authorized_keys
   ```
2. Deleting the line does not end a connection that is already open. List the sshd processes of `<USER>`, find the thief's connection by its peer address, and kill that session's sshd process (the root-owned `sshd: <USER> [priv]` line is the one that ends it):

   ```
   ps -eo pid,user,args | grep -E '[s]shd(-session)?: <USER>'
   ss -tnp | grep sshd
   kill <pid>
   ```

   OpenSSH 9.8 and newer name these processes `sshd-session` instead of `sshd`, which is why the pattern accepts both.

   Do not use `loginctl terminate-user <USER>` for this: it would also kill the tmux server and with it every session.
3. Look at `/var/log/tmuxkeep/audit.log` for the calls the key made. It is only a hint (see "The audit log records broker calls only" above): it cannot show tmux activity or forged lines.
4. If the stolen laptop also held the admin key (`ADMIN_KEY`), replace that too, because its passphrase is then the only thing between the thief and root. On a clean machine create a new admin key with a distinct comment, for example `ssh-keygen -t ed25519 -f ~/.ssh/id_tmuxkeep_admin_ed25519 -C tmuxkeep-admin-2`, and install it as in step 2 of the install (with root password login off, use the provider's console to append the new `.pub` line to `/root/.ssh/authorized_keys`). Then, over the new key, delete the old admin key's line. The distinct comment is what lets one `sed` pick out the old line only:

   ```
   sed -i '/ tmuxkeep-admin$/d' /root/.ssh/authorized_keys
   grep -c ' tmuxkeep-admin-2$' /root/.ssh/authorized_keys
   ```

   The second command must print 1: the new key is still there. Use the same comment you gave the new key.
5. On a clean laptop, move `id_tmuxkeep_ed25519*` aside and deploy with `-RotateTotp` (`--rotate-totp`), which makes a new key pair, replaces the `laptop` entry and starts a new TOTP secret.

The admin key is separate and passphrase-protected, but a stolen laptop gives the thief unlimited offline guesses at that passphrase, so step 4 is not optional when the admin key was on it.

### The dashboard

- The dashboard adds one trust boundary, the browser, and nothing else: it holds no key, no secret and no code, and only runs ssh calls that the wrapper could run, encoded exactly as the wrapper encodes them, so the gate, the lease, the audit line and the exit codes stay the broker's.
- Against another web page in the same browser: the server listens on `127.0.0.1` only; every address needs the per-run token; the `Host` header must be `127.0.0.1:<port>` or `localhost:<port>` (a DNS-rebinding guard); every action is a `POST` of `application/json` whose `Origin` and `Sec-Fetch-Site`, when the browser sends them, must be this page's; no CORS header is ever sent; and a strict Content Security Policy allows only the page's own script and stylesheet. A request that fails these checks gets an empty `404` or `403`.
- Against hostile session output: everything that comes from the VPS (names, titles, pane lines, log lines, error text) is shown as plain text, never as HTML, never in an attribute or a URL; the policy forbids inline script; the VPS strips non-printable characters and cuts each line to 400 characters before it leaves.
- Worst case if the page is driven by an attacker: whatever the session key with a live lease allows, including `send` into a shell, which is command execution as `USER`. That is the same ceiling as a compromised laptop today, and it lasts until the lease ends. **End lease** closes it at once; a shorter `LEASE_SECS` narrows it.
- What stays unaudited: one-shot `tmuxkeep status`, like `ls --names`. Every `status --follow` connection leaves one audit line, so a stolen key cannot watch sessions without a trace; `auth --end` is audited.
- The token appears in your browser history and on the screen; it changes on every `tmuxkeep ui`. On a Linux machine shared with other users it is also visible to them in the process list, as part of the command line of the browser opener, while the opener starts; on such a machine run `tmuxkeep ui --no-open` and open the printed address yourself.
- The local server writes nothing to disk: no log, no cache, no state.

## Development and tests

**Layout.**

```
LICENSE
README.md
.gitattributes              LF line endings for vps/, tests/, dashboard/, laptop/*.sh, laptop/completion.bash, .github/
.gitignore                  .claude/, .superpowers/, docs/vps-facts.md
.github/workflows/ci.yml    the four CI jobs
docs/superpowers/           design specs and implementation plans
laptop/tmuxkeep.ps1         PowerShell wrapper (installed as ~\scripts\tmuxkeep.ps1)
laptop/profile-snippet.ps1  the tmuxkeep function and its tab completer (written into $PROFILE)
laptop/deploy.ps1           PowerShell deploy
laptop/tmuxkeep.sh          bash wrapper (installed as ~/.local/bin/tmuxkeep)
laptop/completion.bash      bash and zsh tab completion
laptop/deploy.sh            bash deploy
dashboard/server.js         tmuxkeep ui, the local dashboard server (installed next to the wrapper)
dashboard/lib/              protocol, validation, config, ssh, follow, terminal and HTTP modules
dashboard/public/           the page: index.html, app.js, style.css
dashboard/test/             node:test suites and the stand-in ssh (stub-ssh.js); not installed
vps/tmuxkeep                the broker (the forced command)
vps/tmuxkeep-setup          the root installer
vps/vps-facts.sh            read-only facts script
vps/sshd.conf.tmpl          sshd drop-in template (Match User __USER__)
vps/sudoers.tmpl            sudoers allowlist template (__USER__)
vps/tmux.conf               tmux settings for the broker's server
vps/systemd/                tmuxkeep-reaper.service and .timer
tests/run-bats.ps1          bats runner for Windows (Docker Desktop)
tests/run-bats.sh           bats runner for macOS, Linux and Git Bash
tests/docker/Dockerfile     the test image
tests/bats/                 bats suites, helpers.bash, laptop-helpers.bash
tests/bats/stubs/           oathtool, ssh, scp and ssh-keygen stand-ins
tests/pester/               Pester suites for the PowerShell files
tests/fixtures/             the bytes the writers must produce
tests/smoke.ps1             operator smoke test, Windows
tests/smoke.sh              operator smoke test, bash
```

The two v1 documents in `docs/superpowers/` record the first version's design; where they differ from this README, the README is right.

**Bats (broker, installer, configs, bash laptop side), in Docker.** Docker must be running. The first run builds the test image (a few minutes). On Windows (Docker Desktop):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-gate.bats
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Filter 'replay'
```

On macOS, Linux and Git Bash:

```bash
bash tests/run-bats.sh
bash tests/run-bats.sh tests/bats/broker-gate.bats
bash tests/run-bats.sh tests/bats 'replay'
```

The exit code is bats' own (0 means every test passed; bats prints TAP `ok` lines when not on a terminal), or 2 if Docker is unavailable, the path is wrong or the image does not build. The suites also run shellcheck over every shell file.

**Pester (PowerShell files).** Windows ships Pester 3.4; install a newer one once. `-MinimumVersion 5.5` installs the newest Pester available, which may be 6.x.

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
```

Run from a PowerShell prompt, with the checkout path filled in (use `$c.Run.Path = 'tests\pester\tmuxkeep.Tests.ps1'` for one file):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command {
  Set-Location -LiteralPath 'C:\path\to\tmuxkeep'
  Import-Module Pester -MinimumVersion 5.5
  $c = New-PesterConfiguration
  $c.Run.Path = 'tests\pester'
  $c.Run.Exit = $true
  $c.Output.Verbosity = 'Detailed'
  Invoke-Pester -Configuration $c
}
```

Success ends with `Tests Passed: N, Failed: 0`. The Pester suites fake `ssh`, `scp` and `ssh-keygen` with stand-ins first on the PATH; neither test suite ever contacts a VPS.

**Node (the dashboard).** Node 20 or newer; no packages. From the repository root:

```
node --test "dashboard/test/*.test.js"
```

Keep the quotes: Node expands the pattern itself on every platform (Node 21 and newer; `node --test dashboard/test` does not work, because Node then looks for a file of that name). The suites run the real modules against `dashboard/test/stub-ssh.js`, a stand-in for ssh that `TMUXKEEP_SSH` points to and a JSON script named in `TMUXKEEP_STUB_SCRIPT` drives; `TMUXKEEP_TERMINAL_DRYRUN=1` makes every terminal and browser launch return its command instead of starting it. Nothing contacts a VPS, opens a window, or listens anywhere but `127.0.0.1`. Success ends with `fail 0`; on Windows two tests (the SIGTERM one and the SIGINT one) are reported as skipped.

**CI.** `.github/workflows/ci.yml` runs on every push and pull request, in four jobs, with a read-only token (`permissions: contents: read` at the top of the workflow):

| Job | Runner | What it proves |
|---|---|---|
| `bats` | `ubuntu-latest` | Builds the test image from `tests/docker/Dockerfile` and runs every bats suite through `bash tests/run-bats.sh` (shellcheck runs inside): the broker, the installer and its templates, the config parsers, the bash laptop side, the parity checks and the static lints, on Linux |
| `pester` | `windows-latest` | Proves that `powershell.exe` is Windows PowerShell 5.1, installs Pester for the current user and runs `tests\pester` under `powershell.exe -NoProfile`: the PowerShell wrapper, completer and deploy on the real 5.1 |
| `macos` | `macos-latest` | Installs bats-core and shellcheck with Homebrew, proves that `/bin/bash` is 3.2, runs the laptop bats suites (`laptop-wrapper`, `completion`, `laptop-config`, `laptop-blocks`, `laptop-deploy`, `parity`, `smoke`, `lint-laptop`) under it and shellchecks the laptop files: the bash side on bash 3.2 and BSD tools |
| `dashboard` | `ubuntu-latest` and `windows-latest` | Installs Node 22 with `actions/setup-node` and runs `node --test "dashboard/test/*.test.js"`: the dashboard's modules, its HTTP checks and the page's helpers, on Linux and on Windows |

**How to add a test.**

- *Bats, broker and installer.* Start the file with `load helpers`. These suites run in the Docker image with the repo mounted read-only at `/src`; `setup_local` gives each test a private state directory, audit log, work directory, tmux socket, fixed clock and a stand-in `oathtool`, with a config copied from `tests/fixtures/tmuxkeep.conf`.
- *Bats, laptop side.* Start the file with `load laptop-helpers`. These suites must also pass under macOS `/bin/bash` 3.2: call scripts with `"$BASH"`, never a bare `bash`; `laptop_setup` gives a private `HOME` and `TMPDIR` with stand-in `ssh`, `scp` and `ssh-keygen` first on the PATH; `mk_repo_copy` makes a throwaway one-commit git copy to run `deploy.sh` from. Add a new laptop suite to the `macos` job's command in `.github/workflows/ci.yml` too.
- *Pester.* Wrap the file's tests in a top-level `Describe` (Pester 6 rejects a file-level `BeforeEach`), and never put angle brackets in a `Describe` or `It` name, because Pester reads them as a template (the deliberate `-ForEach` templates are the exception). A file that dot-sources `laptop\deploy.ps1` gets its functions only, but the script's parameters are set as variables, so do not name your own variables `$Config`, `$Init`, `$HardenRoot`, `$RotateTotp`, `$UnlockOtp`, `$HomeDir` or `$ProfilePath`.
- *Node.* Name the file `dashboard/test/<name>.test.js` (only `*.test.js` files run; `helpers.js` and `stub-ssh.js` are not tests) and use `node:test` and `node:assert/strict` only. Listen on `127.0.0.1` only, script ssh with `stubPlan` from `helpers.js`, and set `TMUXKEEP_TERMINAL_DRYRUN=1` or pass a `spawnFn` wherever a terminal or a browser could open. Every file under `dashboard/` must stay ASCII with LF line endings (`static.test.js` checks).
- *Fixtures.* `tests/fixtures/` holds the bytes both deploys and the installer must write for the default config and `HOST=203.0.113.10`: `laptop-config`, `ssh-block`, `deploy.conf` and `tmuxkeep.conf`. Change a writer and its fixture together. `b64-words` holds the encoding cases that the dashboard and both wrappers must agree on, bit for bit.

**The bash 3.2 and PowerShell 5.1 rules, in short.**

- The laptop bash files (`laptop/tmuxkeep.sh`, `laptop/deploy.sh`, `laptop/completion.bash`, the laptop helpers, stubs and `tests/smoke.sh`) must run on macOS `/bin/bash` 3.2 and BSD tools: no associative arrays, `mapfile`, `${v,,}`, `read -i` or `|&`; no `set -u`; no GNU-only tools or flags (`sed -i`, `grep -P`, `readlink -f`, `date -d`, `base64 -w`, `realpath`, `timeout`). Every laptop shell file passes `shellcheck --shell=bash -S warning` with no exclusions and no `shellcheck disable` directive. In `vps/` two inline directives exist and nothing else is excluded: SC2034 on the `TMUXKEEP_VERSION` line of `vps/tmuxkeep` (the value is rewritten by deploy and read by `tmuxkeep-setup`) and SC2016 in `ensure_path_snippet` of `vps/tmuxkeep-setup` (the PATH block is written literally and expands at login). `tests/bats/lint-laptop.bats` enforces the laptop rules statically.
- Every `.ps1` file is ASCII only, because Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI. `laptop/tmuxkeep.ps1` has no `param` block and no `[CmdletBinding()]`. Product code never writes a file with `>`, `Out-File`, `Set-Content` or `Tee-Object` (use `[IO.File]` with UTF-8 without BOM), and never redirects a native command's stderr, with one exception: the tab completer in `laptop/profile-snippet.ps1` runs its `ssh` with a single `2>$null`, so a warning from ssh never lands in the prompt. The broker's `GATED_VERBS` line must equal both wrappers' lists (tests check).

**Line endings (`.gitattributes`).** `vps/**`, `tests/**`, `dashboard/**`, `laptop/*.sh`, `laptop/completion.bash` and `.github/**` are forced to `eol=lf`. A single CR in a bash script breaks it on the VPS (`$'\r': command not found`) and in the Docker test image, and a Windows git with `core.autocrlf=true` would otherwise check files out with CRLF into the tree Docker mounts. Deploy also normalizes every staged file to LF, and setup refuses staged files that contain a CR. To check a working tree from Git Bash (the `-U` is required, or Git for Windows' grep strips the CR and the check passes silently), this must print nothing:

```
grep -rlIU "$(printf '\r')" vps tests dashboard laptop/*.sh laptop/completion.bash
```

**Smoke test (operator only).** `tests\smoke.ps1` (Windows) and `bash tests/smoke.sh` (macOS, Linux) drive the real wrapper against the real VPS through a 14-step lifecycle: `auth`, `new`, `ls`, `status` (its JSON must name the session; `smoke.ps1` parses it, and `smoke.sh` checks it with `jq` when `jq` is installed, otherwise as text), `peek`, `send /help`, `lock`, a refused `rm`, `unlock`, `rm`, `ls` (tombstone), `restore`, `rm --now --confirm`, and a final `log -n 20` check that the audit lines are there. Run it yourself from a terminal; step 1 asks for a code. Neither suite above ever runs it against a real server.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1
```

```bash
bash tests/smoke.sh
```

Both take a wrapper path (`-Wrapper <path>` and `--wrapper <path>`) and end with `smoke: all steps passed`. On a mismatch they print `FAIL <step>: <reason>` and how to clean up by hand (`tmuxkeep rm smoke-xxxxxx --now --confirm smoke-xxxxxx`; if that is refused as locked, `tmuxkeep restore` only if `tmuxkeep ls` shows a `zz~smoke-...` row, then `tmuxkeep unlock`, then the `rm` again). Things to know:

- Each run leaves a work directory `<WORK_DIR>/smoke-xxxxxx` behind, because no verb deletes work directories. Remove them over the admin path if you care. List them first, because the glob would also match a real session's directory that happens to be named `smoke-...`:

  ```
  ls -d /home/claude/work/smoke-*
  rm -rf /home/claude/work/smoke-xxxxxx
  ```
- If a step seems to hang for about a minute, a hidden `TOTP:` prompt is waiting inside a captured step (the lease expired or your address changed). That also counts as a failed attempt. Run `tmuxkeep auth` and start again.
- The final step reads the last 20 audit lines, so heavy other traffic during the run can push the run's own lines out and fail it; just run it again.
- `send /help` is typed into the new session, whatever `LAUNCH_CMD` started there. If a start-up prompt (for example a folder-trust dialog) is showing, the keys are ignored; answer it in the throwaway directory.

## Troubleshooting

Broker failures print `tmuxkeep: <message>` on stderr and exit with the code shown, and each is also written to the audit log, except `audit log not writable` and `config invalid` (nothing can be logged then) and the wrapper's own local errors (printed on the laptop, never audited).

### Connection, wrapper and profile

| Symptom | Meaning and fix |
|---|---|
| `tmuxkeep: ssh to host 'tmuxkeep' failed (unreachable, key rejected, or remote killed by signal)` (exit 255); both wrappers print this same line | ssh itself failed. Run `ssh -v -o BatchMode=yes tmuxkeep ls` to see why. Usual causes: no network or VPS down; the session key missing or not the one deploy installed (`KEY`); the `Host tmuxkeep` block missing or wrong; a host key not in `known_hosts` yet (run `ssh tmuxkeep ls` once, without BatchMode, and accept it; a changed host key is a warning to investigate, not to accept); or sshd refusing `USER` even though deploy succeeded, see the next row. |
| Deploy succeeded but `USER` cannot log in | sshd `DenyUsers`, `AllowGroups` or `DenyGroups` can exclude `USER`; setup checks only `AllowUsers`. Over the admin path: `sshd -T -C user=<USER>,host=localhost,addr=127.0.0.1` and look at those lines and at `authorizedkeysfile`; then `journalctl -u ssh -n 50` for the refusal. Fix the sshd setting, `sshd -t`, `systemctl reload ssh`. |
| `tmuxkeep: empty argument`, `tmuxkeep: unsupported argument type` (PowerShell), `tmuxkeep: nothing to send`, `tmuxkeep: confirmation required` (exit 2) | Local wrapper errors: an empty word, a hashtable or XML argument, an empty answer at the `Text to send:` prompt, an empty answer at the `Type the session name to confirm:` prompt. Nothing was sent. |
| `tmuxkeep` is not recognized, or `running scripts is disabled on this system` (Windows) | Open a new PowerShell window after deploy. If scripts are blocked, allow local scripts (`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`). Check that `$PROFILE` (the profile of the console that ran deploy) contains the whole `# >>> tmuxkeep` block. Deploy replaces the block in place when both markers are present exactly once; otherwise it refuses (see the marker row below) and you fix the file by hand. So running deploy again repairs a damaged block between intact markers. |
| `command not found` for `tmuxkeep` (macOS, Linux) | Open a new terminal, or run `. ~/.zshrc` (or `. ~/.bashrc`). Check that the `# >>> tmuxkeep` block is in the file for your shell (`~/.zshrc` when `$SHELL` ends in `zsh`, otherwise `~/.bashrc`) and that `~/.local/bin/tmuxkeep` exists. On macOS with bash, `~/.bash_profile` must source `~/.bashrc`. |
| `complete:13: command not found: compdef` (zsh) | An rc block written by hand without the `compinit` part. Deploy again: the block it writes loads `compinit` itself when `compdef` is missing. |
| Tab shows nothing, or a stale list | Completion caches names for 60 seconds (see "Everyday use") and a failed fetch (offline, VPS down) is cached as an empty list for the same 60 seconds, by design, so an offline Tab does not hang. Wait a minute, or delete the two cache files. |
| The admin key is installed but `ssh -o PasswordAuthentication=no tmuxkeep-admin true` still fails | A key line piped in from Windows PowerShell 5.1 can carry a byte-order mark and a CR, and sshd then ignores the line. From a root shell on the VPS (a password login or the provider's console): `sed -i -e 's/^\xEF\xBB\xBF//' -e 's/\r$//' ~/.ssh/authorized_keys`, then `grep -c $'\r' ~/.ssh/authorized_keys` must print 0. |

### Dashboard

| Symptom | Meaning and fix |
|---|---|
| `tmuxkeep: node not found; install Node 20 or newer to use the dashboard` (exit 2) | `node` is not on your PATH. Install Node.js 20 or newer and open a new terminal. |
| `tmuxkeep ui: Node 20 or newer is required (found vX)` (exit 2) | Your Node is too old. Upgrade it. |
| `tmuxkeep: dashboard not installed at <dir>; run deploy again` (exit 2) | The dashboard folder is missing (a deploy from before the dashboard, or one that stopped early). Deploy again. |
| `tmuxkeep ui: port 7707 is in use; set DASHBOARD_PORT or pass --port` (exit 1) | Another program, often another `tmuxkeep ui`, has the port. Stop it, run `tmuxkeep ui --port 7708`, or set `DASHBOARD_PORT`. |
| `tmuxkeep ui: config <path>: DASHBOARD_PORT: must be an integer from 1024 to 65535` (or a `TERMINAL_CMD` reason; exit 2) | Fix that value in `~/.tmuxkeep/config`. |
| The page is blank or says `404` | The address is from an earlier run (the token changes every time) or was mistyped. Use the address `tmuxkeep ui` printed this time. |
| The dot stays grey and the banner says `tmuxkeep: unknown verb: status` | The VPS still runs a broker from before the dashboard. Deploy again. |
| The banner says `ssh exited 255: VPS unreachable`, or shows another `ssh` or `tmuxkeep:` line | The follow connection failed for the reason shown; it retries after 2, 4, 8 and 16 seconds, then every 30 seconds. Check `tmuxkeep ls` in a terminal (see the rows above). |
| The dot turns grey and the banner says `no update for N s` | The connection to the VPS is open but the broker has sent no snapshot for 10 seconds or more, as when the broker hangs behind a live ssh. The dot turns green again if snapshots resume. If they do not, check `tmuxkeep ls` in a terminal, then stop `tmuxkeep ui` with `Ctrl-C` and start it again to open a fresh connection. A connection whose network path died is closed by ssh's keepalive after about two minutes, and the server then reconnects. |
| The banner says `the local server is not running (tmuxkeep ui was stopped)` | The page cannot reach `tmuxkeep ui`: it was stopped (`Ctrl-C`, a closed terminal) or it crashed. Run `tmuxkeep ui` again and open the new address it prints; the token changed, so the old address no longer works. |
| `cannot run ssh: ENOENT` in the banner, or `tmuxkeep ui: cannot run ssh: ...` after an action | The server could not start `ssh`: it is not on the PATH of the terminal that ran `tmuxkeep ui`, or (Windows) a `send` text is too long for one command line, which needs `SEND_MAX_BYTES` above about 24000. |
| **Attach** or **Authenticate** says `no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config` | Linux without `x-terminal-emulator` and without `$TERMINAL`. Set `TERMINAL_CMD`, for example `TERMINAL_CMD=gnome-terminal --`. |
| `cannot start <program>: <reason>` after **Attach** or **Authenticate** (on Windows also `cannot start wt.exe: <reason>; cannot start cmd.exe: <reason>`) | The terminal program could not start. Check `TERMINAL_CMD`, or empty it to use the platform default. |
| `tmuxkeep ui: the home folder path contains " or %; set TERMINAL_CMD to open terminals another way` after **Attach** or **Authenticate** (Windows) | Without Windows Terminal, or when it fails to start, the dashboard opens a PowerShell console window through `cmd.exe /c start`, and `cmd.exe` expands a `%` in your user folder path even inside quotes, so the dashboard refuses to build that command. Set `TERMINAL_CMD` in `~/.tmuxkeep/config` to open terminals another way. When Windows Terminal failed to start first, the message follows `cannot start wt.exe: <reason>; `. |
| `text contains control characters (line breaks and tabs cannot be sent; send one line at a time)` | The broker types text literally and refuses control characters. Send each line on its own. |
| `another action is still running; try again in a moment` | One action runs at a time and the earlier one has not answered yet (after 30 seconds it is stopped and reported as exit 124). |
| `exit 124: tmuxkeep ui: no answer within 30 seconds; ssh was stopped` | The VPS did not answer within 30 seconds. Check the connection, or run the same verb in a terminal to see more. |
| The page keeps saying `type the code in the terminal that opened` | The new lease has not shown up: the code was not accepted, or the terminal's connection came from another address than the dashboard's (a VPN that covers one and not the other). After 3 minutes the waiting action is dropped; run it again. |

### Broker messages

| Message | Exit | Meaning and fix |
|---|---|---|
| `TOTP required: run with a terminal or run 'tmuxkeep auth' first` | 4 | A code is needed but there is no terminal to ask on (a script, a pipe, a scheduled task). Run `tmuxkeep auth` in an interactive terminal; the lease then lets scripted gated calls through from the same address. Not counted as a failure. |
| `wrong code` | 4 | Counted as a failure. Check the phone clock, type the current code, and remember a code works only once. |
| `cooldown, retry in <n>s` | 4 | `OTP_FAIL_MAX` failures within `OTP_FAIL_WINDOW`. Wait the stated seconds (the cooldown ends `OTP_COOLDOWN` seconds after the newest failure), or run deploy with `-UnlockOtp` (`--unlock-otp`) to clear the failure list. |
| `OTP locked after repeated failures; root must remove <USER_HOME>/.tmuxkeep/otp-locked` | 3 | `OTP_HARD_MAX` failures. Run deploy with `-UnlockOtp` (`--unlock-otp`), or as root `rm <USER_HOME>/.tmuxkeep/otp-locked` (the next wrong code locks again; see "TOTP, leases and lockout"). Check `tmuxkeep log` first. |
| `audit log not writable` | 1 | The broker refuses to act without its audit trail. The file is missing, not append-writable by `USER`, or the disk is full. As root: `ls -l /var/log/tmuxkeep`, `lsattr /var/log/tmuxkeep/audit.log`, `df -h /var/log`. Re-run deploy to recreate a missing log, or `install -o <USER> -g <USER> -m 0640 /dev/null /var/log/tmuxkeep/audit.log` then `chattr +a` on it. `ls --names` and `ls --tombstones` still work (they are not audited). `tmuxkeep: audit write failed` means a write failed after the verb ran: check disk space. |
| `tmuxkeep: config invalid: <path>: <reason>` | 1 | `/etc/tmuxkeep/tmuxkeep.conf` is missing, unreadable or invalid, so the broker refuses every call (and cannot audit it). Nothing is wrong with your session. Deploy again: it rewrites the file and checks it with `tmuxkeep --check-conf` first. Do not edit the file by hand. |
| `TOTP not configured; run tmuxkeep-setup` | 1 | `totp.secret` is missing or empty. Run deploy: it creates a missing secret, and for an empty or damaged one setup says `totp.secret is malformed; re-run with --rotate-totp`, so use `-RotateTotp` (`--rotate-totp`). |
| `go needs a terminal` | 4 | Run `tmuxkeep go` from a real terminal (Windows Terminal or a console window on Windows), not a pipe, a redirect or an embedded console. |
| `X already exists`; `a tombstone of X exists; use tmuxkeep restore X` (`new`); `a tombstone of X exists` (`rename`, X being the new name); `tombstone of X exists; use tmuxkeep restore X` (`resume`); `directory <dir> already in use by session <name>` | 3 | `tmuxkeep ls` shows the owner. Restore or `rm --now` the tombstone, rename or remove the session that uses the directory, or pick another name. |
| `session X is locked` | 3 | `tmuxkeep unlock X`, then retry. |
| `pane busy (<command>)` | 3 | `resume` only types into an idle shell. Something is running in the pane (probably the program you started): `tmuxkeep go X`. |
| `no such session: X`; `no tombstone for X`; `nothing to resume for X` | 5 | Check `tmuxkeep ls`. A tombstone shows as `zz~X~<epoch>`; `tmuxkeep restore X`. After a reboot `tmuxkeep resume X` recreates a session if `<WORK_DIR>/X` exists. |
| `--shell and --cmd cannot be combined` | 2 | `--shell` means "type no command" and `--cmd` means "type this command"; use one of them. A `--cmd` of only spaces is the same as `--shell`. |
| `invalid session name`, `missing session name`, `unknown verb`, `usage: ...`, `nothing to send`, `text contains control characters`, `text longer than N bytes` (N is `SEND_MAX_BYTES`), `-n must be 0-9999`, `--lines must be 0-40`, `--repo must be an https:// URL`, `--cmd must be at most 200 printable ASCII characters`, `--confirm must equal X`, `--confirm needs --now`, `reap is local only`, `bad encoded argument`, `control characters in command` | 2 | Argument errors; the message says what is wrong. Nothing ran and no code was asked for. |
| `git clone failed: <last line of git's error>` | 1 | Wrong URL, a private repository without credentials in the URL (git never prompts here), or no network. See the credential warning in the security section. |
| `tmux: <message>`, `tmux: send-keys failed` | 1 | tmux refused. `tmuxkeep ls` to check the session still exists; a dead server means a reboot or crash took the sessions (`tmuxkeep resume`, `tmuxkeep new`). |
| `cannot create state directory`, `cannot open the gate lock`, `cannot take the gate lock`, `cannot record failure`, `cannot record authentication`, `cannot read otp-fails`, `cannot create otp-locked`, `cannot end lease` | 1 | `<USER_HOME>/.tmuxkeep` is not writable by `USER` (full disk, wrong owner). Re-run deploy, which repairs ownership. |
| `cannot create <WORK_DIR>` or `cannot create <WORK_DIR>/<name>` | 1 | `new` could not make the work directory: full disk, or a plain file or wrong owner at that path. Check `ls -ld <WORK_DIR>` over the admin path. |
| `cannot read audit log`; `cannot read pane` | 1 | `log` could not read `/var/log/tmuxkeep/audit.log`, or `peek` could not read the pane. Check the file's permissions (`USER` must be able to read it), and that the session still exists. |
| `not authorized`, `internal: verb returned` | 4, 1 | Fail-closed backstops that should never fire. Report them with the audit line. |
| Any other `tmuxkeep: ...` line | usually 1 | The message names the failing step (a `cannot ...` or `tmux: ...` line). Look at `tmuxkeep log -n 20` for the audit line, check `USER`'s disk and permissions over the admin path, and re-run deploy to repair ownership and the installed files. |
| A gated command seems to hang for up to a minute | - | Another connection is at its `TOTP:` prompt and holds the gate lock; yours waits for it. Finish or abandon that prompt. |

### Known issue: an empty `tmuxkeep ls`

`ls` and `reap` treat any tmux error as "no sessions" instead of reporting it, so an empty `tmuxkeep ls` is not proof that nothing is running. If `ls` is empty when it should not be, run `tmuxkeep new <name>`: it asks tmux for a new session and prints `tmuxkeep: tmux: <message>` if tmux is really broken. You can also look at the socket over the admin path:

```
ls -l /run/user/$(id -u <USER>)/tmuxkeep.sock
runuser -u <USER> -- tmux -S /run/user/$(id -u <USER>)/tmuxkeep.sock ls
```

### Installer and deploy messages

Setup lines start with `tmuxkeep-setup:` and are streamed by deploy, which then prints `deploy: tmuxkeep-setup failed with exit N`. Preflight failures stop before anything changes; later failures stop at the failed step; every one is safe to fix and re-run. A line such as `tmuxkeep-setup: cannot ...` or `... failed` that is not listed (full disk, read-only filesystem, permissions) means exactly what it says: fix that and re-run.

| Message | Fix |
|---|---|
| `tmuxkeep-setup: deploy.conf invalid: <path>: <reason>` | The staged copy of the config was rejected before any step ran (exit 2). The reason names the key. Fix `~/.tmuxkeep/config` and deploy again. |
| `tmuxkeep-setup: refusing USER=<u>: uid <n> is a system account; choose a dedicated user name` | `USER` names an existing account with a uid outside 1000-59999 (`root`, `daemon`, `nobody`). Choose another name; see "Changing the VPS user". |
| `tmuxkeep-setup: USER changed from <old> to <new> since the last deploy; see README "Changing the VPS user"` | You changed `USER` after a deploy. Put the old value back, or follow "Changing the VPS user" to move to the new one. |
| `tmuxkeep-setup: /etc/tmuxkeep/tmuxkeep.conf exists but names no USER; see README "Changing the VPS user"` | The installed VPS config is damaged or hand-edited, so the installer cannot show it belongs to the same `USER`. Follow "Changing the VPS user" (its step 4 removes the file). |
| `tmuxkeep-setup: /var/log/tmuxkeep/audit.log is owned by <owner>, not <USER>; see README "Changing the VPS user"` | The append-only audit log belongs to another account and the new broker could not write to it. Follow "Changing the VPS user" (its step 3 hands the log over). |
| `tmuxkeep-setup: the broker rejected the new configuration; /etc/tmuxkeep/tmuxkeep.conf was not installed` | `tmuxkeep --check-conf` refused the rendered VPS config; the line before it names the reason. Fix the value in `~/.tmuxkeep/config` and deploy again. The installed file is unchanged. |
| `KillUserProcesses=yes would kill the tmux server when a session ends...` | Put `[Login]` and `KillUserProcesses=no` in a file under `/etc/systemd/logind.conf.d/` whose name ends in `.conf` (systemd ignores other names), for example `/etc/systemd/logind.conf.d/tmuxkeep.conf`; then `systemctl restart systemd-logind` (or reboot) so the running value changes, and re-run. |
| `/etc/ssh/sshd_config has no Include for sshd_config.d` | Add `Include /etc/ssh/sshd_config.d/*.conf` as the first line of `/etc/ssh/sshd_config`. |
| `sshd does not have PubkeyAuthentication yes`; `sshd -T failed` | Enable public-key auth in the sshd config; make `sshd -T` run cleanly. |
| `sshd AllowUsers does not admit <USER>; add <USER> to it and re-run` | Add `USER` to `AllowUsers`. |
| `the clock is not NTP synchronized...` | `timedatectl set-ntp true`, wait for `System clock synchronized: yes`, re-run. If `set-ntp` says NTP is not supported, there is no time service yet: `apt-get install systemd-timesyncd`, then `timedatectl set-ntp true` again. |
| `chattr missing: ...`; `chattr +a does not work under /var/log...`; `chattr -a failed on the scratch file ...` | Install `e2fsprogs`; `/var/log` must be on a filesystem that supports `chattr +a` (ext4, xfs, btrfs). For the last one, remove the named scratch file with `chattr -a` then `rm`. |
| `C.UTF-8 locale missing; install the locales package` | `apt-get install locales` until `locale -a` lists `C.UTF-8`. |
| `required command missing: visudo` | `apt-get install sudo`, then re-run. `visudo` comes with the `sudo` package, which a minimal image may lack; setup checks for it before it changes anything. |
| `required command missing: X` (any other command); `systemd is not running`; `loginctl list-users failed`; `apt-get update failed`; `apt-get install failed` | The VPS lacks a prerequisite or apt is failing (network, held lock). Fix and re-run. |
| `tmux is older than 3.0`; `oathtool does not accept - as the key argument` | The distribution's packages are too old; upgrade the OS or use backports. |
| `public key file ...`, `staged files missing from ...`, `carriage returns in staged file ...` | The key pair or the staging folder is damaged: move `id_tmuxkeep_ed25519*` aside so deploy makes a new pair, and run deploy again from a clean checkout. |
| `refusing to follow symlink: <path>` | A path under `<USER_HOME>` that setup writes to is a symlink. Look at it with `ls -l`: code running as `USER` may have planted it. Remove it and re-run. |
| `home directory of <USER> is missing or not a plain absolute path: <home>` | An existing account whose home is not a plain absolute path (letters, digits, `.`, `_`, `-` and `/`, at most 255 bytes); fix the account or choose another `USER`. |
| `... failed visudo -cf ...` | The sudoers file did not validate and was not installed; do not hand-edit around it, check `vps/sudoers.tmpl`. |
| `refusing --harden-root: root login is already no` (or `forced-commands-only`) | Root login is already `no` (or `forced-commands-only`) in the effective sshd configuration, from a setting that sorts ahead of the drop-in or sits above the `Include` in `/etc/ssh/sshd_config`. The stricter setting already covers root, so hardening is not needed, but because hardening is sticky the refusal repeats on every deploy once the installed drop-in has the uncommented line, and dropping `-HardenRoot` does not help. Over the admin path, comment out the `PermitRootLogin prohibit-password` line in `/etc/ssh/sshd_config.d/tmuxkeep.conf` (as in "Harden root login" in the install section), run `sshd -t` and `systemctl reload ssh`, then deploy again without it. |
| `root's effective sshd configuration would change (< before, > after):` with the differing lines | The drop-in would alter root's sshd settings (another directive interacts with it). The previous drop-in is restored; resolve the listed lines and re-run. |
| `permitrootlogin is still yes: an earlier drop-in or the main config overrides it` | sshd takes the first value it reads, so a file that sorts before `tmuxkeep.conf` (for example `50-cloud-init.conf`) wins. Edit that file over the admin path, then run the hardening deploy again. |
| `sshd does not use /etc/tmuxkeep/authorized_keys alone for user <USER>`; `sshd allows password authentication for user <USER>`; `sshd -t rejects the configuration with the new drop-in`; `the sshd drop-in was rejected; sshd was not reloaded` | The drop-in did not take effect or sshd rejected it, and was rolled back; sshd was not reloaded. Another sshd setting overrides it; read the lines before this one. |
| `CRITICAL: could not remove the unvalidated /etc/ssh/sshd_config.d/tmuxkeep.conf` or `FAILED to restore the previous ...` | Rollback itself failed. As root: delete the new `tmuxkeep.conf` (or restore the saved copy named in the message) and run `sshd -t` before any reload. |
| `systemctl reload ssh failed` | Check `systemctl status ssh` (the unit name on Debian and Ubuntu is `ssh`). |
| `totp.secret is malformed; re-run with --rotate-totp` | Run deploy with `-RotateTotp` (`--rotate-totp`) and rescan the QR code. |
| `user manager XDG_RUNTIME_DIR is not /run/user/<uid>...`; `cannot start user@<uid>.service`; `daemon-reload failed in the user manager`; `cannot enable tmuxkeep-reaper.timer`; `cannot read the user manager environment` | The reaper timer step failed. The reaper would otherwise use a different tmux socket than your logins. Setup reaches the user manager of `USER` through its private socket in `/run/user/<uid>`, so it needs no D-Bus user bus and no particular systemd version. Over the admin path check `systemctl status user@<uid>.service` (it must be active; `systemctl start user@<uid>.service` starts it), `loginctl show-user <USER> -p Linger` (must say `Linger=yes`), and that the directory `/run/user/<uid>` exists. Fix what is missing and re-run. |
| `the Claude Code install failed; re-run after fixing the network`; `Claude Code installed but claude is not on the PATH of <USER>` | Only with INSTALL_CLAUDE_CODE=yes. The VPS needs outbound HTTPS to `claude.ai`. For the second message the installer ran but `claude` is not on the login PATH of `USER`: check that `<USER_HOME>/.local/bin/claude` exists and that `.profile` and `.bashrc` contain the `# >>> tmuxkeep path` block, then re-run. |
| `WARNING: claude is running as root (PIDs: ...)` | Informational (printed with INSTALL_CLAUDE_CODE=yes): see "Migrating work from root". |

| Deploy message | Fix |
|---|---|
| `deploy: the admin key was not accepted, or tmuxkeep-admin is unreachable...` (followed by the admin-key steps) | Do step 2 of the install again; check `ssh -o PasswordAuthentication=no tmuxkeep-admin true`. If you only mistyped the passphrase, run deploy again. |
| `deploy: scp failed with exit N` | Not an auth failure (that is 255): check the VPS disk and `/root`. |
| `deploy: ssh to tmuxkeep-admin failed (exit 255): wrong passphrase or the connection was lost...` | The `ssh` that runs `tmuxkeep-setup` failed itself (`tmuxkeep-setup` only exits 0, 1 or 2, so 255 is never its own code). Usual causes: a mistyped admin-key passphrase (ssh gives up after three tries), or a dropped connection. Setup may not have run, or may have stopped partway, and `/root/tmuxkeep-deploy-<timestamp>` may be left on the VPS (remove it over the admin path if you like). Running deploy again is safe. If the first run printed the TOTP secret before the drop and you did not scan it, the next run prints `TOTP secret: kept`, so use `-RotateTotp` (`--rotate-totp`). |
| `deploy: config ... HOST: looks like host:port; put the port in PORT` | `HOST` holds `203.0.113.10:2222`. Put the address in `HOST` and the number in `PORT`. |
| `deploy: config <path>: <reason>` (in general; exit 2, nothing was touched) | The laptop config was rejected. The reason names the problem: `HOST: required`; `HOST: not a hostname, IPv4 or IPv6 address` (for example `you@host`, or an IPv6 address that starts with `:`, which you write in long form); `line N: unknown key KEY` (a typo); `line N: expected KEY=value`; `KEY: must be an integer from LO to HI`; `carriage return found (use LF line endings)` or `byte order mark found (save without BOM)` (re-save the file as LF, UTF-8 without BOM); `non-printable or non-ASCII character in KEY`. Fix the file and deploy again. A rejected first-run answer writes no file. |
| `deploy: missing required tools: ...`; `deploy: not a git checkout: <dir>` | Exit 2. Install `ssh`, `scp`, `ssh-keygen` and `git` (they must be on the PATH), and run deploy from a git checkout of this repository. |
| `deploy: run this with Windows PowerShell 5.1 (powershell.exe), not pwsh` | Run deploy with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1`. Under `pwsh` 7.3 or newer the empty passphrase for the session key would be passed to `ssh-keygen` as two literal quote characters. |
| `deploy: tmuxkeep-setup failed with exit N` | Read the `tmuxkeep-setup:` lines above it and use the table above. |
| `deploy: proof of life exit N` with N not 0 | Setup worked but the session key cannot run `ls`: see the first two rows of "Connection, wrapper and profile". |
| `deploy: ssh-keygen failed with exit N`; `deploy: <key>.pub is missing...` | Fix the folder of `KEY`, or move the session key aside and run deploy again to make a new pair. |
| `... is UTF-16; convert it to UTF-8 or ASCII first` | `~\.ssh\config` or your `$PROFILE` was saved as UTF-16; deploy refuses to write to it. Re-save it as UTF-8 or ASCII. |
| `... has more than one '# >>> tmuxkeep' line; remove the extra block by hand`; `... has '# >>> tmuxkeep' without '# <<< tmuxkeep'; fix it by hand` | The ssh config, profile or rc file has a damaged or duplicated tmuxkeep block. Deploy will not guess which text is yours: edit the file so exactly one complete block remains (or none), then deploy again. |
| `deploy: your ssh config loads keys into an agent for tmuxkeep-admin; ...`; `deploy: your ssh config stores passphrases in the keychain for tmuxkeep-admin; ...`; `deploy: ssh -G tmuxkeep-admin failed with exit N` | `ssh -G tmuxkeep-admin` (which connects to nothing) shows that your ssh configuration would put the admin key into an agent or the keychain, so deploy stops before it connects. Deploy's own block pins `AddKeysToAgent no` and sits first in the file, so something earlier is overriding it. The likeliest cause on a machine you upgraded is an old block that an earlier deploy appended at the end of the file: it is replaced where it is and never moved, so delete that block (from `# >>> tmuxkeep` to `# <<< tmuxkeep`) and deploy again. Otherwise an `Include` or a hand edit sets the option first: add `AddKeysToAgent no` under `Host tmuxkeep-admin`, before any `Host *` block. For the keychain message (macOS) add `UseKeychain no` under a `Host tmuxkeep-admin` section above your `Host *` block; deploy never writes that option itself. If `ssh -G` itself fails, run `ssh -G tmuxkeep-admin` yourself to see the configuration error. |
| `deploy: <file>: not writable`; `deploy: <file>: is a directory` (bash) | The ssh config or rc file cannot be written. Fix the permissions or the path. |
| `git rev-parse failed in <dir>` (PowerShell) or `deploy: git failed in <dir>` (bash); `version '...' is not a git short hash` | Run deploy from a git checkout with `git` on the PATH. |
