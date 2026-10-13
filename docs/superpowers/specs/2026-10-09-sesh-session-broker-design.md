# sesh: Claude Code session broker for the VPS

> Historical design record for v1, which shipped under the name `sesh`. The tool is now
> `tmuxkeep`; paths, aliases and file names in this document are the v1 ones. Where
> this document and `README.md` differ, the README is right.

Date: 2026-10-09
Status: revised after independent review; awaiting final approval

## 1. Purpose

Claude Code runs on a single VPS (`203.0.113.10`, Debian-family, reached today as
root via the `vps` SSH alias). Sessions die when the SSH connection drops, so every
session lives in tmux. `sesh` gives the laptop a small CRUD command over those tmux
sessions and wraps it in a soft security layer.

Intended outcome: from a PowerShell prompt on the laptop, create, list, inspect,
nudge, attach to, rename, lock, soft-delete, restore and resume Claude Code sessions
on the VPS, without ever handling tmux by hand and without running Claude as root.

Success looks like:

- `sesh new api`, `sesh ls`, `sesh go api`, `sesh rm api`, `sesh restore api` all work
  from the laptop with one SSH round trip each.
- No Claude Code process on the VPS runs as root. Setup reports any that still do.
- A mistaken `rm` loses nothing for 24 hours.
- Any verb that changes a session requires a TOTP code at most once per 30 minutes
  from a given laptop key and network location.
- Every action is recorded in a log that the acting user cannot rewrite or replace.
- The root admin path cannot be used from an unlocked laptop without a passphrase.

## 2. Threat model (what "soft security" means here)

In scope, in priority order:

1. The operator kills or clobbers the wrong session.
2. A command run inside Claude Code damages the box because Claude runs as root.
3. Someone with the unlocked laptop, or a copy of its SSH keys, drives sessions or
   reaches root.
4. The operator cannot tell afterwards what happened and when.

Out of scope: multi-tenant isolation, network-exposed dashboards, kernel or
container hardening, protection against root on the VPS being compromised,
protection against an attacker who already holds a live attached session, and
protection against code already running as the `claude` user (see 2.1, D2).

### 2.1 Decisions taken after review

- **D1 Admin path.** A dedicated passphrase-protected admin key, never loaded into
  the Windows ssh-agent, replaces the current key on `Host vps`. Root password
  login is disabled once the key is verified.
- **D2 Gate scope.** Version one defends against the holder of the laptop keys,
  not against code running as `claude`. The cheap mitigations in 7.4 are applied;
  splitting the SSH-facing user from the tmux-owning user is deferred to version two.
- **D3 Gated verbs.** Everything that changes a session needs a lease: `new`,
  `go`, `send`, `rename`, `unlock`, `rm`, `resume`, `auth`. Open: `ls`, `peek`,
  `log`, `lock`, `restore`.
- **D4 Privileges for `claude`.** A sudoers allowlist for apt-get, systemctl and
  journalctl, plus membership of the `docker` group. Docker group membership is
  root-equivalent on that box; the operator accepts that threat 2 is reduced, not
  removed, while Docker is in use.
- **Defaults taken without asking:** lease bound to key id plus client IP; `go`
  detaches other clients; `rm` leaves Claude running inside the tombstone; `new`
  refuses while a tombstone of that name exists; `--repo` is https only; broker
  tests run in Docker Desktop on the laptop; a read-only facts script runs before
  any coding.

## 3. Architecture

Two SSH identities to the same host, never mixed:

| Path | Laptop side | VPS side | Use |
|---|---|---|---|
| Admin | `vps` alias, host `vps`, user root, passphrase key | root shell | setup, deploy, emergencies |
| Session | `sesh` command, host `sesh`, user `claude`, passphrase-less key | forced command `/usr/local/bin/sesh` | all day-to-day session work |

The session key's `authorized_keys` entry forces the broker. OpenSSH therefore
guarantees that this key can run exactly one program, with no port forwarding, no
agent forwarding and no X11, regardless of what the client asks for. The broker
reads the requested verb from `SSH_ORIGINAL_COMMAND`, validates it, and acts.

```
laptop                                     VPS
------                                     ---
sesh.ps1  --ssh sesh b64 <args>-->  sshd --forced cmd--> /usr/local/bin/sesh --key laptop
   |                                                      |  parse, validate, gate, audit
   |<------------ stdout / stderr / pty ------------------|  tmux -S /run/user/<uid>/sesh.sock
                                                          |
                                      systemd --user timer -> sesh reap (hourly)
```

Components:

- `vps/sesh` (bash): the broker. Root-owned, mode 0755, at `/usr/local/bin/sesh`.
- `vps/sesh-setup` (bash): idempotent root installer.
- `vps/vps-facts.sh` (bash): read-only facts script, run once by the operator (Task 0).
- `vps/sshd-sesh.conf`: sshd drop-in with the `Match User claude` block.
- `vps/sudoers-claude`: the sudoers allowlist.
- `vps/tmux.conf`: broker-owned tmux configuration.
- `vps/systemd/sesh-reaper.service`, `vps/systemd/sesh-reaper.timer`: user units for `claude`.
- `laptop/sesh.ps1` (Windows PowerShell 5.1): the wrapper, installed to `~\scripts\sesh.ps1`.
- `laptop/profile-snippet.ps1`: lines appended to the PowerShell profile.
- `laptop/deploy.ps1`: copies VPS files over the admin path and runs setup.
- `tests/bats/*.bats`, `tests/docker/Dockerfile`, `tests/run-bats.ps1`: broker tests.
- `tests/pester/*.Tests.ps1`: wrapper tests. `tests/smoke.ps1`: end to end, human-run.
- `.gitattributes`: forces LF on everything under `vps/` and `tests/`.

## 4. Accounts, keys, SSH configuration

### 4.1 VPS user `claude`

- Created by setup: `useradd -m -s /bin/bash claude`, then `usermod -p '*' claude`
  so the account is valid for key login but has no usable password.
- Groups: `docker` (D4). No other groups.
- Sudoers allowlist from `vps/sudoers-claude`, installed to `/etc/sudoers.d/claude`
  (0440) after `visudo -cf` passes:

  ```
  claude ALL=(root) NOPASSWD: /usr/bin/apt-get update, /usr/bin/apt-get install *
  claude ALL=(root) NOPASSWD: /usr/bin/systemctl restart *, /usr/bin/systemctl reload *, /usr/bin/systemctl status *
  claude ALL=(root) NOPASSWD: /usr/bin/journalctl *
  ```

- `loginctl enable-linger claude` so its user systemd instance, runtime directory
  and timer exist without a login session.
- Claude Code installed in `/home/claude/.local/bin` via
  `runuser -l claude -c 'curl -fsSL https://claude.ai/install.sh | bash'`.
  Both `.profile` and `.bashrc` put `~/.local/bin` on PATH.
- Owns the tmux server at `/run/user/<uid>/sesh.sock`. All sessions and all Claude
  Code processes belong to it.

### 4.2 sshd drop-in for `claude`

`vps/sshd-sesh.conf` is installed to `/etc/ssh/sshd_config.d/sesh.conf`:

```
# PermitRootLogin prohibit-password      <- uncommented by setup --harden-root
Match User claude
    AuthorizedKeysFile /etc/sesh/authorized_keys
    PasswordAuthentication no
    DisableForwarding yes
    PermitUserRC no
    ClientAliveInterval 30
    ClientAliveCountMax 4
Match all
```

The closing `Match all` matters. sshd keeps a Match block open across the end of
an included file, so without it every directive that follows the `Include` line in
the main `sshd_config` would become conditional on `User claude`. The global
`PermitRootLogin` line must stay above the first `Match`.

`/etc/sesh/` is root-owned 0755 and `/etc/sesh/authorized_keys` is root-owned 0644,
so the `claude` user cannot add keys or strip the forced command. Setup refuses to
install if the main config lacks an `Include` for `sshd_config.d`. It validates with
`sshd -t`, then compares `sshd -T -C user=root,host=localhost,addr=127.0.0.1`
before and after installing the drop-in: the only permitted difference is
`permitrootlogin` when `--harden-root` is given. Any other difference aborts and
restores the previous drop-in. It also checks that
`sshd -T -C user=claude,host=localhost,addr=127.0.0.1` shows the expected
`authorizedkeysfile` and `passwordauthentication no`. Only then does it reload sshd.

With `--harden-root`, setup uncomments the `PermitRootLogin prohibit-password`
line. Deploy passes that flag only when invoked as `deploy.ps1 -HardenRoot`, after
the operator has confirmed the admin key works.

### 4.3 Laptop keys and host entries

Two new keys. The existing `id_ed25519` is left alone and no longer used for the VPS.

Session key, no passphrase, generated by `deploy.ps1` if missing. In PowerShell 5.1
an empty argument is dropped, so the passphrase flag must be written `-N '""'`:

```
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_sesh_ed25519" -C sesh-laptop -N '""'
```

Admin key, with a passphrase, generated by the operator (section 4.5). It is never
passed to `ssh-add`, and no `AddKeysToAgent` option is set anywhere.

Final `~/.ssh/config` blocks. The `Host vps` block replaces the existing one; the
`Host sesh` block is appended by deploy, ASCII only, via `Add-Content -Encoding ascii`
after ensuring the file ends with a newline, guarded by a `# >>> sesh` marker line:

```
Host vps
    HostName 203.0.113.10
    User root
    IdentityFile ~/.ssh/id_vps_admin_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 4

# >>> sesh
Host sesh
    HostName 203.0.113.10
    User claude
    IdentityFile ~/.ssh/id_sesh_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 4
# <<< sesh
```

### 4.4 authorized_keys line for `claude`

Written by setup to `/etc/sesh/authorized_keys`, replacing any line whose comment
matches the same key id:

```
restrict,pty,command="/usr/local/bin/sesh --key laptop" ssh-ed25519 AAAA... sesh-laptop
```

`restrict` disables every forwarding, pty and `~/.ssh/rc`; `pty` re-enables only the
terminal, which `go` and the TOTP prompt need. `--key laptop` is the key id that
appears in the audit log. A second laptop gets its own line and its own id.

### 4.5 Admin path prerequisite (operator-only, before deploy)

Run in PowerShell. Step 1 prompts for a passphrase: choose one and do not leave it
empty. Step 2 prompts for the root password once.

```
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_vps_admin_ed25519" -C vps-admin
Get-Content "$env:USERPROFILE\.ssh\id_vps_admin_ed25519.pub" | ssh vps 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

The remote command is single-quoted on purpose: inside double quotes PowerShell
would expand `$`-prefixed text. The `tail | read` test adds a newline only when the
existing file lacks a trailing one.

Then replace the `Host vps` block in `~/.ssh/config` with the one in 4.3. Verify with
`ssh -o PasswordAuthentication=no vps true`: it must prompt for the passphrase and
exit 0. Deploy re-runs that check and stops with these instructions if it fails.

## 5. Broker: invocation and argument protocol

### 5.1 Invocation and local-versus-remote rule

- A call is **remote** when `SSH_ORIGINAL_COMMAND` is set and argv after
  `--key <id>` is empty. The argument list comes from `SSH_ORIGINAL_COMMAND`.
- Otherwise the call is **local** and the argument list is argv after `--key <id>`.
- `reap` is accepted only from a local call.
- The `SESH_*` test overrides in 12.1 are honoured only on local calls.
- Before starting a tmux server the broker runs tmux through
  `env -u SSH_ORIGINAL_COMMAND -u SSH_CLIENT -u SSH_CONNECTION -u SSH_TTY LANG=C.UTF-8`
  so no SSH variable leaks into the server environment or into Claude panes.

### 5.2 Argument encoding

The client's words are joined by spaces into one string before the broker sees
them. Two forms are accepted:

- Plain form: split on whitespace with `read -r -a` under `set -f`, so nothing globs.
  For humans typing `ssh sesh ls` by hand.
- Encoded form: first token is `b64`, every following token is one argument encoded
  as standard base64 of its UTF-8 bytes. The wrapper always uses this form. A token
  that fails to decode is usage (2).

The broker never passes any argument through `eval` or a shell. Every tmux call uses
an argument array.

### 5.3 Name rules and exact targeting

Session names must match `^[a-z][a-z0-9_-]{0,31}$`. Starting with a letter keeps
PowerShell from turning `1kb` into `1024` on the way in.

Tombstones have the form `zz~<name>~<epoch>` and are only ever created by the
broker. Only `peek` and `rm --now` accept a tombstone name as input; every other
verb rejects a name that starts with `zz~` as usage (2). `restore` takes the base
name and finds the tombstone itself.

tmux resolves `-t name` by exact match, then prefix, then pattern, and resolves
window and pane targets against the current session first. The broker therefore:

- uses one helper for every tmux call that takes a target, passing `-t "=$name:"`;
- checks existence only by exact string comparison against
  `tmux list-sessions -F '#{session_name}'`, never with `has-session`;
- finds tombstones with an anchored regex over that same list.

Every verb that takes a name returns not found (5) when there is no exact match.

### 5.4 Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 2 | usage: unknown verb, bad name, missing or undecodable argument, control characters in text |
| 3 | refused: locked session, duplicate name, directory already in use, pane busy, hard OTP lockout |
| 4 | auth: TOTP wrong, cooldown active, no TTY available for the prompt |
| 5 | not found: no such session, no tombstone to restore |
| 1 | anything else (tmux error, git clone failed) |

Every failure writes one line to stderr and an audit line before exiting.

## 6. Verbs

Gated verbs require a valid lease (7.1). Everything runs as `claude`. Work
directories live under `/home/claude/work/`.

### `new <name> [--repo <https-url>]` (gated)

1. Validate name. Refuse (3) if a live session or a tombstone of that name exists.
2. Target directory is `/home/claude/work/<name>`. Refuse (3) if any existing
   session's `#{session_path}` equals it, so a renamed session and a new one never
   share a directory.
3. If `--repo` is given and the directory does not exist, run
   `GIT_TERMINAL_PROMPT=0 git clone -- <url> <dir>`; the URL must start with
   `https://`. If the directory already exists, skip the clone and print a note.
   Otherwise `mkdir -p`.
4. `tmux new-session -d -s <name> -c <dir>`, then send `claude` plus Enter.
5. Audit `new` (repo URL with any credentials redacted). Print `created <name> in <dir>`.

### `ls [--names | --tombstones]`

- Lists every session from `tmux list-sessions` with fields: name, created epoch,
  activity epoch, attached count, the `@sesh_locked` option and `#{pane_title}` of
  the active pane.
- STATE is `tombstone`, else `locked`, else `live`. A separate ATTACHED column shows
  `*` when attached.
- Default output is an aligned table: NAME, STATE, ATTACHED, AGE, IDLE, TITLE. AGE and
  IDLE are humanised (`3h`, `2d`). TITLE is the pane title, which Claude Code sets to
  its current task, truncated to 40 columns.
- `--names`: every non-tombstone name, one per line, for completion.
- `--tombstones`: base names that have a tombstone, one per line, for `restore`
  completion.
- No tmux server is an empty list, exit 0.
- `--names` and `--tombstones` are not audited; the completer calls them often.

### `peek <name|tombstone> [-n N]`

Capture the pane with `tmux capture-pane -p -J -S -`, drop trailing blank lines,
then print the last N lines. N defaults to 40 and must match `^[0-9]{1,4}$`.

### `go <name>` (gated)

Requires a TTY (4 otherwise). `exec tmux attach-session -d -t "=<name>:"`. The
`-d` detaches clients left behind by dropped connections. No picker; tab
completion on the laptop covers choosing.

### `send <name> [text...]` (gated)

- Text is every argument after the name, joined by single spaces. Missing text is
  usage (2); the wrapper prompts locally for it instead (9.1).
- Reject (2) any C0 control character or DEL in the text, and any text over 8000
  bytes. Literal mode stops key-name lookup only; raw control bytes would still
  reach Claude as keystrokes, so they are refused rather than passed.
- `tmux send-keys -l -- <text>`, sleep `SEND_ENTER_DELAY`, then `send-keys Enter`.
  The delay keeps Claude Code's paste detection from swallowing the Enter.
- Audit records the byte length of the text, never the text.

### `rename <old> <new>` (gated)

Validate both. Refuse (3) if `<new>` exists as a live session or has a tombstone.
`tmux rename-session`. The work directory is not moved: Claude Code keys its
history by path.

### `lock <name>` / `unlock <name>` (`unlock` gated)

`tmux set-option -t "=<name>:" @sesh_locked 1`, or `-u` to clear.

### `rm <name> [--now --confirm <name>]` (gated)

- Refuse (3) if `@sesh_locked` is set on the target.
- Without `--now`: `tmux rename-session` to `zz~<name>~<epoch>`. Nothing inside the
  session is touched; Claude keeps working. Print
  `tombstoned <name>; still running, reaped in 24h; restore with: sesh restore <name>`.
- With `--now`: `--confirm` must equal `<name>` exactly, else usage (2). If a live
  session `<name>` exists, kill it. Otherwise, if `<name>` is a base name with a
  tombstone, kill the newest tombstone. Otherwise, if `<name>` is itself a tombstone
  name, kill it. Otherwise not found (5).

### `restore <name>`

Find tombstones `zz~<name>~*`, pick the greatest epoch. Not found (5) if none.
Refuse (3) if a live `<name>` exists. Rename back. Print `restored <name>`.

### `resume <name>` (gated)

- If the session exists: read `#{pane_current_command}` of the active pane. If it
  is one of `bash`, `sh`, `zsh`, `dash`, send `claude --continue` plus Enter and
  print `resumed <name>`. Otherwise refuse (3) with `pane busy (<command>)`.
- If the session does not exist but `/home/claude/work/<name>` does (for example
  after a reboot): create the session there, send `claude --continue` plus Enter,
  print `recreated <name>`.
- Otherwise not found (5).

### `log [-n N]`

Print the last N (default 50) lines of the audit log. Not gated.

### `auth`

Always prompts for a code, even while a lease is valid, and renews the lease.

### `reap` (local only)

Usage (2) if called remotely. No tmux server is a no-op, exit 0. Kills every
session whose name matches `^zz~[a-z][a-z0-9_-]*~([0-9]+)$` and whose epoch is older
than `TOMBSTONE_TTL`. One failure does not stop the others. Audits each as `reaped`.

## 7. Security mechanics

Constants, each defined once at the top of the broker:

| Constant | Value |
|---|---|
| `LEASE_SECS` | 1800 |
| `TOMBSTONE_TTL` | 86400 |
| `OTP_STEP` | 30 |
| `OTP_FAIL_MAX` | 3 |
| `OTP_FAIL_WINDOW` | 600 |
| `OTP_COOLDOWN` | 300 |
| `OTP_HARD_MAX` | 10 |
| `OTP_READ_TIMEOUT` | 60 |
| `SEND_ENTER_DELAY` | 0.3 |
| `SEND_MAX_BYTES` | 8000 |
| `GATED_VERBS` | `new go send rename unlock rm resume auth` |

The broker defines `GATED_VERBS=` on a single line so the wrapper's Pester test can
parse it and assert the two sides agree (12.2).

### 7.1 TOTP gate and lease

State lives in `/home/claude/.sesh/` (0700): `totp.secret` (0600), `last-otp`,
`otp-fails`, `otp-locked`, `gate.lock`, and `leases/<keyid>@<ip>` where `<ip>` is
the first field of `SSH_CLIENT`. The whole gate runs under `flock` on `gate.lock`
so two concurrent connections cannot both spend one code.

1. If `otp-locked` exists, refuse (3) with `OTP locked after repeated failures;
   root must remove /home/claude/.sesh/otp-locked`.
2. If `leases/<keyid>@<ip>` exists and its epoch is younger than `LEASE_SECS`, the
   verb proceeds without a prompt (except `auth`, which always prompts).
3. If `otp-fails` holds `OTP_FAIL_MAX` or more timestamps within the last
   `OTP_FAIL_WINDOW` seconds and the newest is younger than `OTP_COOLDOWN`, fail (4)
   with `cooldown, retry in <n>s`.
4. The broker needs a TTY. If stdin is not a terminal, fail (4) with
   `TOTP required: run with a terminal or run 'sesh auth' first`.
5. Prompt `TOTP: ` on `/dev/tty` with echo off and `read -t OTP_READ_TIMEOUT`.
   Anything that is not exactly six digits counts as a failure.
6. Compute step `now / OTP_STEP`. For each of step minus one, step, step plus one,
   run `oathtool --totp -b -N @<epoch> -` with the base32 secret on stdin, and
   compare. The secret never appears on a command line.
7. Replay guard: the matched step must be strictly greater than the integer in
   `last-otp`. On success write the matched step to `last-otp`, the current epoch
   to the lease file, and truncate `otp-fails`.
8. On failure append the epoch to `otp-fails`, audit `otp-fail`, exit 4. If
   `otp-fails` now holds `OTP_HARD_MAX` or more entries, create `otp-locked`.

The code is read from the terminal on the VPS side, so it never appears in a
command line, a process list, or the audit log.

### 7.2 Soft delete

Delete is a rename. Claude Code keeps running inside the tombstone with no signal
sent to it. Only the reaper, after `TOMBSTONE_TTL`, and `rm --now`, with the name
typed back, ever kill a session. Locked sessions cannot be tombstoned or killed
until unlocked, and `unlock` is gated.

### 7.3 Audit log

Path `/var/log/sesh/audit.log`. The directory is `root:root 0755`; the file is
owned by `claude` and marked append-only with `chattr +a`. Because the parent is
root-owned, `claude` cannot rename the directory out from under the file, and
because of `+a` it cannot truncate, edit, delete or rename the file. It can only
append.

One JSON object per line, built with `jq -cn`:

```
{"ts":"2026-10-09T17:03:12Z","key":"laptop","ip":"203.0.113.9","verb":"rm","session":"api","ok":true,"detail":"tombstoned"}
```

- `ts` is UTC ISO 8601. `key` is the `--key` id or `local`. `ip` is the first field
  of `SSH_CLIENT`, or `-` when local.
- Rejected verbs, name validation failures, TOTP failures, cooldowns and lockouts
  are logged with `ok:false`.
- `send` logs `len:<bytes>` in detail, never the text. `new` redacts credentials
  from repo URLs. `ls --names` and `ls --tombstones` are not logged.
- No rotation in version one. The README documents the root procedure:
  `chattr -a`, rotate, `chattr +a`.

### 7.4 What the gate does and does not protect

The forced command, root-owned `authorized_keys`, `restrict`, `PermitUserRC no`
and the TOTP lease together mean that someone holding the laptop's session key
can run only the broker's verbs, and can change nothing without a code from the
phone. The passphrase on the admin key means the same person cannot reach root.

The gate does **not** hold against code already running as `claude`, which
includes every Claude Code session. That code can read `totp.secret`, forge a
lease, edit `.bashrc` (sourced before the forced command on Debian), and drive
tmux directly. This is accepted for version one (D2). Mitigations that cost
nothing are still applied: the broker is root-owned, `authorized_keys` is
root-owned, the audit log cannot be rewritten, and the `SESH_*` overrides are
ignored on remote calls. Version two would split the SSH-facing user from the
tmux-owning user.

Other residual risks, documented in the README: any session can run
`tmux kill-server` or `send-keys` into another session because they share a
user; `docker` group membership is root-equivalent (D4); a key thief gets
roughly three guesses per ten minutes until the hard lockout.

## 8. tmux server and reaper

Broker-owned configuration `vps/tmux.conf` is installed to `/etc/sesh/tmux.conf`
(root-owned) and passed with `-f` whenever the broker starts the server:

```
set -g default-terminal tmux-256color
set -s escape-time 10
set -g history-limit 50000
set -g set-titles off
```

The socket is `$XDG_RUNTIME_DIR/sesh.sock`, falling back to `/run/user/<uid>/sesh.sock`,
and is passed with `-S` on every call. `/run/user/<uid>` exists because linger is
enabled and is not subject to the `/tmp` cleaner. The broker always invokes tmux
with `-u` so attaches from Windows, which sends no `LANG`, render UTF-8.

User-level systemd units installed to `/home/claude/.config/systemd/user/`:

- `sesh-reaper.service`: `Type=oneshot`, `ExecStart=/usr/local/bin/sesh --key reaper reap`.
- `sesh-reaper.timer`: `OnCalendar=hourly`, `RandomizedDelaySec=5min`, `Persistent=true`.

Enabled by setup in this order: `loginctl enable-linger claude`,
`systemctl start user@<uid>.service`, `systemctl --user -M claude@ daemon-reload`,
`systemctl --user -M claude@ enable --now sesh-reaper.timer`.

## 9. Laptop wrapper

### 9.1 `sesh.ps1`

Written for Windows PowerShell 5.1. No `param()` block and no `[CmdletBinding()]`,
so `-n` and `-d` are not captured as Verbose or Debug. It:

- Takes `$args` verbatim, flattens any array elements (PowerShell turns `a, b` into
  one array argument), stringifies every element, and rejects empty strings (2).
- Prompts locally when `send <name>` has no text: `Read-Host "Text to send"`. This
  sidesteps the PowerShell parser, which otherwise treats `;`, `#`, `$`, `(`, `@`
  and `,` specially. The README says to single-quote text given inline.
- Prompts locally for `rm --now` without `--confirm`: `Type the session name to confirm:`,
  then appends `--confirm <answer>`.
- Encodes every argument as base64 of UTF-8 and runs bare `ssh` (so Pester can mock
  it) with `-o BatchMode=yes -o ConnectTimeout=5 [-t] sesh b64 <tokens...>`.
- Adds `-t` for the verbs in its own `$GatedVerbs` list, which must equal the
  broker's `GATED_VERBS`.
- Never redirects ssh's stderr; 5.1 would wrap it in error records.
- Exit code is ssh's. On 255 it prints one hint:
  `ssh to host 'sesh' failed (unreachable, key rejected, or remote killed by signal)`.

### 9.2 Profile snippet

Appended once to the existing profile, ASCII only, via `Add-Content -Encoding ascii`
between `# >>> sesh` and `# <<< sesh` markers:

- `function sesh { & "$HOME\scripts\sesh.ps1" @args }`
- `Register-ArgumentCompleter -Native -CommandName sesh -ScriptBlock { param($wordToComplete, $commandAst, $cursorPosition) ... }`
  completing the verb table for the first word, `sesh ls --names` for session
  arguments, and `sesh ls --tombstones` after `restore`. Results are cached in
  `$env:TEMP\sesh-names.txt` for 60 seconds; a failed fetch is cached as empty for
  the same 60 seconds so an offline Tab does not hang repeatedly.

The `vps` alias and `connect-vps.ps1` are not modified.

### 9.3 `deploy.ps1`

Every run needs the admin passphrase, typed twice (once for `scp`, once for `ssh`),
so deploy is always run by the operator. Agents never run it.

1. Generate `id_sesh_ed25519` if missing (4.3); append the `Host sesh` block if the
   `# >>> sesh` marker is absent.
2. Build a local staging folder under `$env:TEMP` containing: a copy of `vps/sesh`
   with the `SESH_VERSION=dev` line replaced by the git short hash, suffixed
   `-dirty` when the tree is dirty, written with `[IO.File]::WriteAllText` using
   UTF-8 without BOM and LF endings; `sesh-setup`; `vps-facts.sh`;
   `sshd-sesh.conf`; `sudoers-claude`; `tmux.conf`; the systemd units; and
   `id_sesh_ed25519.pub`.
3. `scp -r <staging> vps:/root/sesh-deploy-<yyyymmddHHMMSS>`. `/root` is 0700, so
   the `claude` user cannot pre-create or tamper with that path. If scp fails with
   255, stop and print section 4.5.
4. `ssh vps 'bash /root/sesh-deploy-<ts>/sesh-setup --pubkey-file /root/sesh-deploy-<ts>/id_sesh_ed25519.pub --key-id laptop [--harden-root]; rc=$?; rm -rf /root/sesh-deploy-<ts>; exit $rc'`
   and stream its output. No `-t`: setup needs no terminal, and the QR code is
   printed with `-t ANSI`, which Windows Terminal renders from a plain pipe.
5. Copy `sesh.ps1` to `~\scripts\`; append the profile snippet if the marker is absent.
6. Run `ssh -o BatchMode=yes sesh ls` and print the result as proof of life.

The first run additionally displays the TOTP secret and QR code. Its output must
never be read into an agent transcript.

## 10. Setup script `sesh-setup`

Run as root from the staging directory. Idempotent: safe to re-run after every deploy.

Arguments: `--pubkey-file <path>` (required), `--key-id <id>` (default `laptop`,
must match `^[a-z][a-z0-9_-]{0,15}$`), `--rotate-totp`, `--harden-root`,
`--unlock-otp`.

Preflight, each failing with a one-line reason before any change:

- `apt-get` present.
- systemd present; `loginctl` works; the effective logind configuration, including
  `logind.conf.d` drop-ins, does not set `KillUserProcesses=yes`.
- `/etc/ssh/sshd_config` includes `sshd_config.d`; `sshd -T` shows
  `pubkeyauthentication yes` and either no `AllowUsers` or one that includes `claude`.
- `timedatectl show -p NTPSynchronized` reports `yes`.
- `chattr +a` works on a test file under `/var/log`.
- The broker file contains no carriage returns.
- The public key file holds exactly one `ssh-ed25519` line.

Steps:

1. `DEBIAN_FRONTEND=noninteractive apt-get update` then install `tmux oathtool jq
   qrencode e2fsprogs git curl util-linux`. Stop if tmux is older than 3.0 or if
   `oathtool` rejects `-` as the key argument.
2. Create user `claude` if missing; set password field to `*`; add to `docker` if
   that group exists; install the sudoers file after `visudo -cf`.
3. Install `/usr/local/bin/sesh`, `/etc/sesh/tmux.conf` and `/etc/sesh/authorized_keys`
   (root-owned). Install the sshd drop-in with the validation and before/after
   `sshd -T` comparison described in 4.2, then `systemctl reload ssh`.
4. Create `/home/claude/.sesh` (0700, owner claude) and `/home/claude/work`.
   `--unlock-otp` removes `otp-locked` and truncates `otp-fails`.
5. TOTP secret: if missing or `--rotate-totp`, write 20 random bytes as base32 to
   `totp.secret` (0600, owner claude), reset `last-otp` to 0, delete every lease,
   and print the `otpauth://totp/sesh@vps?secret=...&issuer=sesh` URL plus
   `qrencode -t ANSI`.
6. Audit log: create `/var/log/sesh` (root, 0755). If `audit.log` is missing, create
   it owned by `claude` and apply `chattr +a`. If it exists, check with `lsattr` and
   only apply `+a` when absent; never chown or chmod an existing `+a` file (that
   returns EPERM even for root).
7. Linger, user manager, units and timer, in the order given in section 8.
8. Install Claude Code for `claude` if `runuser -l claude -c 'command -v claude'` fails.
9. Report: any process named `claude` running as root (`pgrep -u root -x claude`),
   any root tmux sessions (`tmux ls` as root), and whether the TOTP secret was
   created or kept. Print a summary with user, broker version and timer status.

First-run checklist printed at the end:

1. Scan the QR code into an authenticator app.
2. On the laptop: `sesh new scratch`, then `sesh go scratch`, complete the Claude
   Code login inside it, detach with `Ctrl-b d`.
3. Move any existing projects from `/root` to `/home/claude/work/` and stop any
   root tmux sessions (README section "Migrating from root").
4. Once `vps` logs in with the admin key, run `deploy.ps1 -HardenRoot`.

## 11. Error handling

- Broker: validate before acting, audit before exiting, one line on stderr, exit
  code from 5.4. tmux errors are passed through on stderr with exit 1.
- Wrapper: passes broker stderr through unchanged; adds only the 255 hint.
- Setup: preflight failures stop before any change; later failures stop at the
  failed step and the script is safe to re-run.
- Reaper: a failure on one session does not stop the others; each is audited.

## 12. Testing

### 12.1 Broker (bats in Docker Desktop)

`tests/docker/Dockerfile` builds `debian:bookworm` with tmux, bats, oathtool, jq,
util-linux and git. `tests/run-bats.ps1` builds it and runs
`docker run --rm -v <repo>:/src:ro ... bats /src/tests/bats`.

Test hooks, honoured only on local calls: `SESH_HOME` (the `.sesh` directory),
`SESH_AUDIT` (audit file), `SESH_WORK` (work directory), `SESH_TMUX_SOCKET`,
`SESH_NOW` (fake epoch), `SESH_OATHTOOL` (path to a stub). The broker does not
reset `PATH`.

Cases: name validation including names starting with a digit and `zz~` names per
verb; each verb's happy path; duplicate name refusal; directory-in-use refusal
after a rename; `rm` on locked refused; `rm` then `restore` round trip; `rm --now`
without matching `--confirm` is usage; `rm --now <base>` kills the newest
tombstone; `resume` on running, idle and missing-after-reboot cases; TOTP accepted
at step minus one, step, step plus one; replay of the same step rejected; lease
skips prompt; lease is per key id and IP; three failures trigger cooldown; ten
trigger lockout; success truncates `otp-fails`; `auth` prompts even with a lease;
`reap` kills only tombstones older than TTL; `reap` over SSH refused; `reap` with
no server exits 0; audit line written for success and for each failure class;
`send` rejects control characters and oversize text; plain and `b64` forms give
identical results; **exact targeting**: with `api2` live and `api` absent, every
verb on `api` returns 5 and `api2` is untouched; a session named `bash` beside a
window named `bash` in another session is targeted correctly.

### 12.2 Wrapper (Pester 5, on the laptop)

Pester 5 is not installed by default on Windows (3.4.0 ships). Install once with
`Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck`.
Tests run under `powershell.exe`.

Mock `ssh`. Assert for each verb the exact argument array: `-o BatchMode=yes`,
`-o ConnectTimeout=5`, presence or absence of `-t`, host `sesh`, `b64` marker and
correct base64 for a multi-word `send`. Assert `send <name>` with no text prompts.
Assert `rm --now` prompts and appends `--confirm`. Assert empty arguments and
nested arrays are handled. Assert the 255 hint. Assert the completer returns cached
names and caches failures. Assert `$GatedVerbs` equals the `GATED_VERBS=` line
parsed from `vps/sesh`.

### 12.3 Smoke (`tests/smoke.ps1`, real VPS, operator-only)

Needs a phone code at the first gated verb. `sesh auth`, `sesh new smoke-<rand>`,
`sesh ls` contains it, `sesh peek`, `sesh send` a harmless line, `sesh lock`,
`sesh rm` refused, `sesh unlock`, `sesh rm`, `sesh ls` shows the tombstone,
`sesh restore`, `sesh rm --now --confirm`, `sesh log -n 20` shows every step.
Exit non-zero on the first mismatch.

## 13. Task 0: VPS facts (operator-only, before any coding)

`vps/vps-facts.sh` is read-only. The operator runs it once with the root password:

```
Get-Content .\vps\vps-facts.sh | ssh vps 'bash -s' | Out-File -Encoding utf8 docs\vps-facts.md
```

`Out-File -Encoding utf8` is used because 5.1's default for `>` and `Tee-Object`
is UTF-16. The script prints nothing secret, so the file is safe to commit and
for agents to read.

It reports: distro and version; tmux, OpenSSH, oathtool and bash versions; the
`sshd -T` values for AllowUsers, UsePAM, PubkeyAuthentication, AuthorizedKeysFile
and the Include line; effective `KillUserProcesses`; NTP sync state; locale
defaults; whether `chattr` works on `/var/log`; the `/tmp` cleanup policy;
existing root tmux sessions, `claude` processes and the location of root's
`~/.claude`; free disk; whether a `docker` group exists. The committed
`docs/vps-facts.md` is the ground truth for the implementation plan and replaces
section 14's assumptions.

## 14. Assumptions to verify in Task 0

- Debian or Ubuntu with apt.
- tmux 3.0 or newer available from apt.
- systemd with logind and `KillUserProcesses` not set to yes.
- sshd config includes `sshd_config.d`.
- oathtool version accepts `-` to read the key from stdin.
- Outbound HTTPS allowed for the Claude Code installer and git clones.

## 15. Repository layout

```
Code/sesh/
  .gitattributes                 vps/** and tests/** text eol=lf
  README.md                      usage, quoting rules, migrating from root, residual risks, log rotation
  docs/superpowers/specs/2026-10-09-sesh-session-broker-design.md
  docs/vps-facts.md              output of Task 0
  vps/sesh
  vps/sesh-setup
  vps/vps-facts.sh
  vps/sshd-sesh.conf
  vps/sudoers-claude
  vps/tmux.conf
  vps/systemd/sesh-reaper.service
  vps/systemd/sesh-reaper.timer
  laptop/sesh.ps1
  laptop/profile-snippet.ps1
  laptop/deploy.ps1
  tests/bats/*.bats
  tests/docker/Dockerfile
  tests/run-bats.ps1
  tests/pester/*.Tests.ps1
  tests/smoke.ps1
```

## 16. Operator-only steps (never delegated to an agent)

1. Section 4.5: create the admin key with a passphrase and install it with one
   password login.
2. Task 0: run `vps-facts.sh` with the root password.
3. Every `deploy.ps1` run: it needs the admin passphrase, and the first run also
   prints the TOTP secret and QR code.
4. Claude Code login inside the first session.
5. `tests/smoke.ps1`: needs a phone code.
6. `deploy.ps1 -HardenRoot` once the admin key is confirmed working.

Agents verify their work with the Docker bats suite and the Pester suite only.
They do not touch the VPS.

## 17. Non-goals for version one

- Multiple VPS hosts or multiple operators.
- Audit log rotation.
- Separate SSH-facing and tmux-owning users (D2).
- Any network listener other than sshd.
- Windows-side TOTP generation; the code always comes from the phone.
- A session picker on the VPS; completion on the laptop covers it.
