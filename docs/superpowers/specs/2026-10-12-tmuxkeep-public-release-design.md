# tmuxkeep: public release of the session broker (v1.1)

Date: 2026-10-12
Status: draft for Doug's review
Builds on: `docs/superpowers/specs/2026-10-09-sesh-session-broker-design.md` (the v1 spec,
called "v1 spec" below). Everything the v1 spec says still holds unless this document
changes it. Section numbers written as "v1 §N" refer to that file.

## 1. Purpose

v1 is a working, tested session broker that only Doug can install: the VPS address, the
`vps` admin alias, the `claude` user and every path are constants in the scripts, and
the laptop side runs only on Windows PowerShell 5.1. v1.1 turns it into a tool anyone
can install on their own Debian or Ubuntu VPS from a Windows, macOS or Linux laptop, and
publishes it under the name `tmuxkeep`.

Intended outcome: a stranger clones the public repository, runs one deploy script for
their platform, answers one question (the VPS address), and ends up with the same
broker, gate, audit log and reaper that v1 gives Doug. Doug installs the renamed tool
once, after this release, instead of installing `sesh` and migrating later.

Success looks like:

- `tmuxkeep new api`, `tmuxkeep ls`, `tmuxkeep go api`, `tmuxkeep rm api` work from
  PowerShell 5.1 on Windows and from bash or zsh on macOS and Linux, with identical
  behaviour and exit codes.
- No value specific to Doug's laptop or VPS remains in the repository or its history.
- A fresh clone passes the whole test suite in CI on Ubuntu, Windows and macOS.
- The README is enough for someone who has never seen the v1 spec.

## 2. Decisions taken during design (2026-10-12)

These extend the v1 decisions D1-D4 and are settled.

- **D5 Platforms.** Laptop side supports Windows PowerShell 5.1 (existing) and
  bash on macOS and Linux (new). pwsh 7 and fish are not targets.
- **D6 Audience.** Generic host for any long-running CLI tool. The VPS user name stays
  `claude` by default but is a config value. The Claude Code install step runs only
  when asked. The commands typed into a new or resumed session are config values with
  Claude Code defaults.
- **D7 License.** MIT, copyright holder "Douglas Rojas" (the name on Doug's GitHub
  profile).
- **D8 Design docs.** The v1 spec and v1 plan are published, scrubbed of the VPS
  address and personal paths, with a header note that they are the historical design
  record under the old name and that the README wins where they differ. They are not
  renamed internally.
- **D9 Name.** `tmuxkeep`. Checked clean on GitHub, npm, PyPI and crates.io on
  2026-10-12. `sesh` collides with joshmedeski/sesh, a tmux session manager in
  Homebrew; `berth`, `cleat`, `moor`, `mooring`, `belay`, `hawser`, `sessh` and
  `sshmux` all collide too.
- **D10 History.** The public repository starts from one squashed commit. The full v1
  history stays in a local branch that is never pushed.
- **D11 Admin user.** Deploys run as `root` on the VPS over the admin key, as in v1. A
  non-root sudo admin user is a non-goal for v1.1.

## 3. Scope

In scope: configuration layer on both sides, the rename, the bash laptop side, the
installer and broker changes that make the user name and session commands
configurable, test and CI coverage for all of it, license, README rewrite, scrub, and
the history reset. Doug's own deployment happens after this release, following the
operator steps in §13.

Out of scope: see §15.

## 4. Configuration model

### 4.1 File format (both sides)

Plain text, one `KEY=value` per line. Rules, identical for the PowerShell parser, the
bash parser and the broker's parser:

- Lines are trimmed. Blank lines and lines whose first character is `#` are ignored.
- The key is everything before the first `=`, the value everything after it, both
  trimmed. No quotes, no escapes, no variable expansion.
- Keys are uppercase ASCII with `_`. An unknown key is an error, not a warning, so a
  typo cannot silently fall back to a default.
- A key given twice: the last one wins.
- Values are ASCII printable characters only (0x20-0x7E). Any other byte is an error.
- The file must have no CR characters and no BOM. The parsers reject both with a
  message naming the file.

### 4.2 Laptop config: `~/.tmuxkeep/config`

Owned and written by the deploy scripts, editable by hand afterwards. On Windows `~` is
`$HOME` (`C:\Users\<you>`). The deploy scripts accept `--config <path>` to use another
file; the Pester and bats tests use that flag.

| Key | Default | Validation |
|---|---|---|
| `HOST` | none, required | `^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$` (hostname, IPv4 or IPv6 literal) |
| `PORT` | `22` | integer 1-65535 |
| `USER` | `claude` | `^[a-z_][a-z0-9_-]{0,31}$` |
| `KEY` | `~/.ssh/id_tmuxkeep_ed25519` | path; `~` expands to home |
| `ADMIN_KEY` | `~/.ssh/id_tmuxkeep_admin_ed25519` | path; `~` expands to home |
| `LAUNCH_CMD` | `claude` | 0-200 printable ASCII characters; empty means "open a shell only" |
| `RESUME_CMD` | `claude --continue` | same as `LAUNCH_CMD` |
| `INSTALL_CLAUDE_CODE` | `no` | `yes` or `no` |
| `LEASE_SECS` | `1800` | integer 60-86400 |
| `TOMBSTONE_TTL` | `86400` | integer 3600-2592000 |
| `OTP_FAIL_MAX` | `3` | integer 1-20 |
| `OTP_FAIL_WINDOW` | `600` | integer 60-86400 |
| `OTP_COOLDOWN` | `300` | integer 10-86400 |
| `OTP_HARD_MAX` | `10` | integer `OTP_FAIL_MAX`-100 |
| `OTP_READ_TIMEOUT` | `60` | integer 10-600 |
| `SEND_MAX_BYTES` | `8000` | integer 1-65536 |

First run: when the file does not exist, deploy asks one question, `VPS address
(hostname or IP):`, validates it as `HOST`, and writes the file with every key present,
the defaults filled in, and a one-line comment above each key. Later runs never prompt;
a missing or invalid file is an error that names the key.

The two ssh aliases are fixed and not configurable: `tmuxkeep` reaches the broker as
`USER`, `tmuxkeep-admin` reaches `root`. Fixing them keeps the wrapper config-free and
the README unambiguous.

### 4.3 Deploy-to-installer handoff: `deploy.conf`

Deploy never passes config values on the remote command line, because `LAUNCH_CMD`
contains spaces and a remote shell parses that line. Instead deploy writes
`deploy.conf` into the staging directory with these keys, copied from the laptop
config: `USER`, `LAUNCH_CMD`, `RESUME_CMD`, `INSTALL_CLAUDE_CODE` and the eight
tunables. The installer reads it with `--conf <file>` and validates every key again
with the same rules, because the staging directory crossed the network. `deploy.conf`
contains no secret.

### 4.4 VPS config: `/etc/tmuxkeep/tmuxkeep.conf`

Written by the installer on every run (atomic: temp file in `/etc/tmuxkeep`, then
`mv`), owner `root:root`, mode `0644`. The laptop config is the single source of truth,
so hand edits on the VPS are overwritten by the next deploy; the README says so.

| Key | Value |
|---|---|
| `USER` | from `deploy.conf` |
| `USER_HOME` | `getent passwd USER` after the account exists |
| `STATE_DIR` | `USER_HOME/.tmuxkeep` |
| `WORK_DIR` | `USER_HOME/work` |
| `AUDIT_LOG` | `/var/log/tmuxkeep/audit.log` |
| `LAUNCH_CMD`, `RESUME_CMD` | from `deploy.conf` |
| the eight tunables | from `deploy.conf` |

`OTP_STEP` stays a constant (30) in the broker; it is a property of the authenticator
app, not a site preference. `SEND_ENTER_DELAY` stays a constant.

The broker reads this file with its own strict parser (§4.1 rules plus a key
whitelist), never with `source`. In remote mode a missing, unreadable or invalid file
is exit 1 with the message `tmuxkeep: config invalid: <reason>` on stderr and an audit
line is not attempted (the audit path itself comes from the file). Root owns the file,
so a compromised `USER` account cannot loosen the gate or redirect the audit log.

### 4.5 Precedence and test overrides

Laptop: `--config <path>` chooses the file; nothing else overrides it. There is no
environment override on the laptop side.

VPS broker, local mode only (the `SSH_ORIGINAL_COMMAND` rule of v1 §5.1 is unchanged):
`TMUXKEEP_CONF` selects the config file; when unset, built-in defaults equal to the
table in §4.4 with `USER=claude` apply, so unit tests that do not care about config
still run. `TMUXKEEP_HOME`, `TMUXKEEP_AUDIT`, `TMUXKEEP_WORK`, `TMUXKEEP_TMUX_SOCKET`,
`TMUXKEEP_OATHTOOL` and `TMUXKEEP_NOW` replace the `SESH_*` overrides of v1 with the
same semantics and the same guard. In remote mode every `TMUXKEEP_*` variable is
ignored, exactly as today.

Installer: flags only. `--conf` is optional; without it the defaults of §4.2 apply.

## 5. Rename map

Mechanical and complete. A grep for `sesh` (case-insensitive) over the repository,
excluding `docs/superpowers/`, must return nothing.

| v1 | v1.1 |
|---|---|
| `/usr/local/bin/sesh` | `/usr/local/bin/tmuxkeep` |
| `/etc/sesh/` (`authorized_keys`, `tmux.conf`) | `/etc/tmuxkeep/` plus `tmuxkeep.conf` |
| `/var/log/sesh/audit.log` | `/var/log/tmuxkeep/audit.log` |
| `/home/claude/.sesh` | `HOME/.tmuxkeep` |
| `/etc/ssh/sshd_config.d/sesh.conf` | `/etc/ssh/sshd_config.d/tmuxkeep.conf` |
| `/etc/sudoers.d/claude` | `/etc/sudoers.d/tmuxkeep` |
| `sesh-reaper.service`, `.timer` | `tmuxkeep-reaper.service`, `.timer` |
| `$XDG_RUNTIME_DIR/sesh.sock` | `$XDG_RUNTIME_DIR/tmuxkeep.sock` |
| forced command `sesh --key laptop` | `tmuxkeep --key laptop` |
| `SESH_VERSION`, `SESH_*` env | `TMUXKEEP_VERSION`, `TMUXKEEP_*` |
| ssh alias `sesh` | `tmuxkeep` |
| ssh alias `vps` (admin) | `tmuxkeep-admin` |
| `id_sesh_ed25519` | `id_tmuxkeep_ed25519` |
| `id_vps_admin_ed25519` | `id_tmuxkeep_admin_ed25519` |
| `~\scripts\sesh.ps1`, function `sesh` | `~\scripts\tmuxkeep.ps1`, function `tmuxkeep` |
| markers `# >>> sesh` / `# <<< sesh` | `# >>> tmuxkeep` / `# <<< tmuxkeep` |
| `$env:TEMP\sesh-names.txt` | `$env:TEMP\tmuxkeep-names.txt` |
| staged `sesh-stage-<ts>/sesh-deploy-<ts>` | `tmuxkeep-stage-<ts>/tmuxkeep-deploy-<ts>` |
| messages `sesh: ...`, `sesh-setup: ...` | `tmuxkeep: ...`, `tmuxkeep-setup: ...` |
| `tests/run-bats.ps1`, image `sesh-bats` | `tests/run-bats.ps1`, image `tmuxkeep-bats` |

Unchanged: the `b64` wire protocol, the verbs, exit codes 0/2/3/4/5/1, session name
rules, the `zz~<name>~<epoch>` tombstone format, the key id `laptop`, the audit JSON
field names, the work directory layout `HOME/work/<name>`.

## 6. Laptop side

### 6.1 Shared behaviour (both platforms)

Both wrappers send `ssh -o BatchMode=yes -o ConnectTimeout=5 [-t] tmuxkeep b64
<token>...`, add `-t` only when the first word is a gated verb, perform the same local
checks (unsupported argument, empty word, `send` with no text prompts for it, `rm
--now` without `--confirm` prompts for the name), and map exit codes the same way
(ssh's own code; 255 prints the hint naming the alias `tmuxkeep`). The gated verb list
is `new go send rename unlock rm resume auth` in both wrappers and in the broker.

Both deploys perform the same steps in the same order:

0. Preflight: required tools present (`ssh`, `scp`, `ssh-keygen`, `git`), running from
   a git checkout, the config file parses (or does not exist yet).
1. Config: create `~/.tmuxkeep/config` after the one prompt (§4.2), or load it.
2. Laptop key: create `KEY` with no passphrase if missing (`ssh-keygen -t ed25519 -C
   tmuxkeep-laptop`).
3. ssh config: write the marked block below into `~/.ssh/config`. Write-or-replace:
   if the block exists and differs, it is replaced in place; v1 appended once and never
   touched it again, which would strand a changed `HOST`.
4. Stage: temp directory holding the VPS files (§11), the public key as `laptop.pub`,
   `deploy.conf`, and the broker stamped with the git short hash.
5. Copy: `scp -r <stage> tmuxkeep-admin:/root/<stage>`. Exit 255 prints the admin-key
   help (§6.5).
6. Install: `ssh tmuxkeep-admin bash /root/<stage>/tmuxkeep-setup --pubkey-file
   /root/<stage>/laptop.pub --key-id laptop --conf /root/<stage>/deploy.conf [flags]`.
   The remote command line contains only fixed words and the stage name
   (`tmuxkeep-deploy-<digits>`), so no quoting problem exists.
7. Wrapper: install the wrapper and the shell integration (platform-specific below).
8. Proof of life: `ssh -o BatchMode=yes tmuxkeep ls`.
9. Remove the local staging directory.

Flags on both deploys: `--config <path>`, `--init` (run steps 0-3 only, then stop; this
is how the operator gets the `tmuxkeep-admin` alias before the facts script and before
the admin key is installed), `--harden-root`, `--rotate-totp`, `--unlock-otp`. The
PowerShell deploy keeps its switch spelling (`-Init`, `-HardenRoot`, `-RotateTotp`,
`-UnlockOtp`, `-Config`).

Marked block written to `~/.ssh/config`, with the platform's native line endings
(CRLF from PowerShell as v1 did, LF from bash):

```
# >>> tmuxkeep
Host tmuxkeep
    HostName <HOST>
    Port <PORT>
    User <USER>
    IdentityFile <KEY>
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 4
Host tmuxkeep-admin
    HostName <HOST>
    Port <PORT>
    User root
    IdentityFile <ADMIN_KEY>
    IdentitiesOnly yes
# <<< tmuxkeep
```

No `AddKeysToAgent` on either host, for the reason in v1 §4.3.

### 6.2 PowerShell wrapper and profile snippet

`laptop/tmuxkeep.ps1` is `laptop/sesh.ps1` renamed, with the strings of §5 replaced.
It reads no config. `laptop/profile-snippet.ps1` is renamed the same way; the function
is `global:tmuxkeep`, the completer is registered for `tmuxkeep`, the cache files are
`tmuxkeep-names.txt` and `tmuxkeep-tombstones.txt`. All the 5.1 rules of v1 §9.1 still
apply.

### 6.3 PowerShell deploy

`laptop/deploy.ps1` keeps its structure (functions first, dot-source guard, main
sequence) and gains: the config parser and writer (`Read-TmuxkeepConfig`,
`Write-TmuxkeepConfig`, `New-TmuxkeepConfigInteractive`), the `deploy.conf` writer,
the two-host marked block with write-or-replace (`Set-TmuxkeepMarkedBlock` replaces
`Add-SeshMarkedBlock`), `laptop.pub` staging, and the `-Init` and `-Config` switches.
Step 7 installs `~\scripts\tmuxkeep.ps1` and appends the profile snippet between
markers as today. The admin help (§6.5) is built from the config, not from literals.

### 6.4 Bash wrapper, deploy and completion

New files, all written for bash 3.2 because that is `/bin/bash` on macOS: no
associative arrays, no `mapfile`, no `${var,,}`, no `read -i`, no `|&`, no `;&`.
`[[ ]]`, arrays, `printf -v` and `${var//a/b}` are fine. Every file passes shellcheck
with `--shell=bash` and no exclusions.

`laptop/tmuxkeep.sh` (installed as `~/.local/bin/tmuxkeep`, mode 0755):

- Encodes each word with `printf '%s' "$w" | base64 | tr -d '\n'`. The `tr` matters:
  GNU `base64` wraps at 76 columns, BSD `base64` does not.
- Empty word: `tmuxkeep: empty argument`, exit 2. `send <name>` with no text: reads one
  line from `/dev/tty` after the prompt `Text to send: `; empty is exit 2. `rm --now`
  without `--confirm`: reads the name from `/dev/tty` after `Type the session name to
  confirm: ` and appends `--confirm <answer>`. Both prompts go through one function,
  `tk_prompt <label>`, which is the only place the wrapper opens `/dev/tty`; the bats
  tests source the wrapper and redefine `tk_prompt` before calling the main function.
- Runs `ssh` in the foreground with the terminal attached, no capture. Exit code is
  ssh's; 255 prints `tmuxkeep: ssh to host 'tmuxkeep' failed (unreachable, key
  rejected, or remote killed by signal)` on stderr.
- A guard at the top returns instead of running when the file is sourced
  (`[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0`), so the bats tests can source it and
  test its functions, mirroring the PowerShell dot-source pattern.

`laptop/deploy.sh` (run from the checkout as `bash laptop/deploy.sh [flags]`): the
nine steps of §6.1 with the same source guard. Step 7 copies `laptop/tmuxkeep.sh` to
`~/.local/bin/tmuxkeep`, copies `laptop/completion.bash` to
`~/.tmuxkeep/completion.bash`, and writes this marked block (write-or-replace) into
`~/.zshrc` when `$SHELL` ends in `zsh`, otherwise into `~/.bashrc`:

```
# >>> tmuxkeep
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
[ -n "$ZSH_VERSION" ] && autoload -U +X bashcompinit && bashcompinit
[ -f "$HOME/.tmuxkeep/completion.bash" ] && . "$HOME/.tmuxkeep/completion.bash"
# <<< tmuxkeep
```

`laptop/completion.bash`: `complete -F _tmuxkeep tmuxkeep`. First word completes the
thirteen verbs (`new ls peek go send rename lock unlock rm restore resume log auth`);
second word completes session names for `peek go send rename lock unlock rm resume`
and tombstone base names for `restore`. Names come from `ssh -n -o BatchMode=yes -o
ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 tmuxkeep ls
--names` (or `--tombstones`), cached for 60 seconds in
`${TMPDIR:-/tmp}/tmuxkeep-<kind>-<uid>.txt`; a failed fetch caches an empty file so an
offline laptop does not wait on every Tab. stderr of that ssh is discarded, and nothing
else in the bash side discards stderr.

Tests force the real interpreter: on macOS CI the suites run with `/bin/bash` so that
a Homebrew bash 5 on the PATH cannot mask a 3.2 incompatibility.

### 6.5 Admin key prerequisite (operator-only)

Replaces v1 §4.5. The text printed on scp exit 255 and the README say, with the values
from the config substituted:

```
1. ssh-keygen -t ed25519 -f <ADMIN_KEY> -C tmuxkeep-admin        (set a passphrase)
2. Install it on the VPS with one password login:
   ssh root@<HOST> -p <PORT> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && echo <pubkey> >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true
```

Never `ssh-add` the admin key and never set `AddKeysToAgent` for it.

## 7. VPS side

### 7.1 Broker `vps/tmuxkeep`

v1 §5-§8 unchanged except:

- Startup reads `/etc/tmuxkeep/tmuxkeep.conf` (§4.4, §4.5). `DEFAULT_STATE_DIR`,
  `DEFAULT_AUDIT`, `DEFAULT_WORK` and the tunable constants become the parsed values.
- `new` types `LAUNCH_CMD` into the fresh pane (followed by Enter) instead of the
  literal `claude`; an empty `LAUNCH_CMD` types nothing and leaves the shell. `resume`
  does the same with `RESUME_CMD`. The `--repo` behaviour of v1 §6 is unchanged.
- `new <name> [--repo <url>] [--cmd <text>]` and `resume <name> [--cmd <text>]` accept
  an override for that session only. `<text>` follows the `LAUNCH_CMD` rules (0-200
  printable ASCII; an empty override is allowed and means "shell only"). The audit
  entry for the verb gains `"cmd": "<text>"` when the override is present. This adds
  no new capability beyond `send`, which already types arbitrary text into a pane; it
  is gated because `new` and `resume` are.
- `ls` and `reap` still treat any tmux error as "no sessions" (known v1 limitation,
  unchanged).
- Messages say `tmuxkeep:`. The comment header no longer mentions Claude Code except
  as the default command.

### 7.2 Installer `vps/tmuxkeep-setup`

```
bash tmuxkeep-setup --pubkey-file <path> [--key-id <id>] [--conf <file>] [--rotate-totp] [--harden-root] [--unlock-otp]
```

v1 §10 unchanged except:

- `--conf <file>`: parsed with the §4.1 rules and the §4.3 key whitelist before any
  step runs; an invalid file is exit 2 with the key named. Without `--conf`, defaults.
- `CLAUDE_USER` and `CLAUDE_HOME` become `TK_USER` and `TK_HOME`, set from the config.
  `TK_HOME` comes from `getent passwd` after the account exists, never from a literal.
- The account is created with `useradd -m -s /bin/bash "$TK_USER"` when absent. The
  docker group membership and the sudoers rules stay as decided in D4.
- Templates: the staged `sudoers.tmpl` and `sshd.conf.tmpl` contain the literal
  `__USER__`. The installer renders each with `${content//__USER__/$TK_USER}` (safe
  because `TK_USER` matched the §4.2 regex) into a temp file, validates it (`visudo
  -cf` for sudoers; the before/after `sshd -T` diff and `sshd -T -C user=$TK_USER`
  checks of v1 §10 for the drop-in), then moves it into place. Names: `/etc/sudoers.d/
  tmuxkeep` (temp `/etc/sudoers.d/.tmuxkeep.new`) and `/etc/ssh/sshd_config.d/
  tmuxkeep.conf`.
- Writes `/etc/tmuxkeep/tmuxkeep.conf` (§4.4) on every run, then runs `tmuxkeep
  --check-conf /etc/tmuxkeep/tmuxkeep.conf` as root (a new local-mode-only flag that
  parses and exits 0 or 1) before continuing, so a file the broker would reject never
  gets installed silently.
- The Claude Code install step and the "a `claude` process runs as root" warning run
  only when `INSTALL_CLAUDE_CODE=yes`. The install command is unchanged.
- The first-deploy TOTP output (secret and QR, printed once) is unchanged.
- Messages say `tmuxkeep-setup:`. The final "next steps" text names `WORK_DIR` from
  the config.

### 7.3 Facts script

`vps/vps-facts.sh` takes `--user <name>` (default `claude`) and reports on that
account. Its first-line CR guard and everything else stay. Its output file
`docs/vps-facts.md` is git-ignored (§10.4).

### 7.4 tmux config and systemd units

Rename only (§5). The reaper timer and service keep `OnCalendar=hourly`,
`Persistent=true`, and call `/usr/local/bin/tmuxkeep reap`.

## 8. Security model deltas

v1 §2 and §7 hold. Additions:

- `/etc/tmuxkeep/tmuxkeep.conf` is root-owned. The gate tunables, the audit path and
  the session commands therefore have the same trust level as the broker binary. The
  broker fails closed when the file is missing or malformed.
- Whoever can edit `~/.tmuxkeep/config` on the laptop decides what the next deploy
  installs, including `LAUNCH_CMD`. That is the same trust as the laptop itself and the
  admin key's passphrase still gates every deploy.
- `--cmd` is an audited, gated way to do what `send` already allows.
- Template rendering cannot inject sshd or sudoers directives: the only substituted
  value matches `^[a-z_][a-z0-9_-]{0,31}$`, and both rendered files are validated by
  their own tools before installation.
- `deploy.conf` crosses the network over the admin path and contains no secret.
- Publishing the repository exposes no secret: keys, the TOTP secret and
  `docs/vps-facts.md` never enter it, and the history reset (§10.6) removes the VPS
  address from every commit.

## 9. Testing

### 9.1 Broker and installer (bats in Docker, unchanged mechanics)

- Every existing test is renamed. `helpers.bash` `setup_local` writes a temp config
  and exports `TMUXKEEP_CONF`; the remote-mode container tests keep the real paths
  under `/home/claude` because the container is built with the default user.
- New config tests: valid file; unknown key; CR in file; non-ASCII value; each tunable
  at and outside its bounds; missing file in remote mode is exit 1 with the message of
  §4.4; `TMUXKEEP_CONF` ignored in remote mode; `--check-conf` exit codes.
- New `new`/`resume` tests: `LAUNCH_CMD` typed; empty `LAUNCH_CMD` types nothing;
  `--cmd` override typed and audited; `--cmd` too long or with a control character is
  exit 2.
- New installer tests: `--conf` parsing (valid, unknown key, bad `USER`, bad yes/no,
  tunable out of range); rendering of both templates for `bob` compared against
  expected strings; the written `/etc/tmuxkeep/tmuxkeep.conf` contents and mode;
  `INSTALL_CLAUDE_CODE=no` skips the install function; the `--check-conf` gate fails
  the step when the file is bad. The byte-for-byte `cmp` tests of v1 for the sshd and
  sudoers files become tests of the rendered output.

### 9.2 Laptop bash side (bats, run in Docker and on macOS)

New suites `tests/bats/laptop-wrapper.bats`, `tests/bats/laptop-deploy.bats` and
`tests/bats/completion.bats`. `ssh`, `scp` and `ssh-keygen` are stub scripts on a
test PATH that log their arguments and return a configured exit code; prompts are
tested by redefining `tk_prompt` after sourcing (§6.4). `HOME` and `--config` point
at temp directories, so no real rc file or ssh config is touched. Coverage mirrors the Pester
wrapper and deploy suites of v1 §12.2: argument encoding, gated `-t`, exit mapping,
every local check, config create/load/validate, marked-block write and replace in
both rc files, `--init` stops after step 3, step order and the exact remote command
line, admin help on 255, staging contents including `deploy.conf` and `laptop.pub`.

### 9.3 Parity tests

`tests/bats/parity.bats` extracts, with `grep`/`sed`, and compares:

- the gated verb list from the broker, both wrappers;
- the staged file list from both deploys and the installer's `STAGED_FILES`;
- the completer verb lists (PowerShell snippet and `completion.bash`) against the
  broker's `verb_*` functions.

`tests/pester/tmuxkeep.Tests.ps1` keeps its own gated-verb parity assertion.

### 9.4 PowerShell (Pester 5+, unchanged mechanics)

Renamed suites plus: config read, write, interactive create with `Read-Host` mocked,
validation failures by key; marked block write-or-replace with the two hosts; admin
help built from config and containing no literal address; `deploy.conf` and
`laptop.pub` in the staging folder; `-Init` stops after step 3; the remote command
line is exactly the §6.1 form.

### 9.5 Static checks

shellcheck, no exclusions, over `vps/tmuxkeep`, `vps/tmuxkeep-setup`,
`vps/vps-facts.sh`, `laptop/tmuxkeep.sh`, `laptop/deploy.sh`,
`laptop/completion.bash`, `tests/bats/stubs/*` and every `.bash` helper. The static
Pester suite keeps its CR/BOM/ASCII checks and adds `laptop/*.sh` to the LF set.
`.gitattributes` adds `laptop/*.sh text eol=lf` and `laptop/completion.bash text
eol=lf`.

### 9.6 CI

`.github/workflows/ci.yml`, on push and pull request:

| Job | Runner | Steps |
|---|---|---|
| `bats` | `ubuntu-latest` | build `tests/docker/Dockerfile`, run every bats suite, run shellcheck |
| `pester` | `windows-latest` | `powershell.exe -NoProfile` (Windows PowerShell 5.1), install Pester 5 for the current user, run `tests/pester` |
| `macos` | `macos-latest` | `brew install bats-core shellcheck`, run the laptop suites with `/bin/bash` (3.2), shellcheck the laptop files |

A `tests/run-bats.sh` for macOS and Linux developers mirrors `tests/run-bats.ps1`.

### 9.7 Smoke (operator-only)

`tests/smoke.ps1` renamed; a `tests/smoke.sh` twin for bash with the same steps
against a real VPS. Agents never run either.

## 10. Repository hygiene and release

### 10.1 License

`LICENSE` at the root: the MIT text, `Copyright (c) 2026 Douglas Rojas`.

### 10.2 README

Rewritten for a reader who has never seen this repository. Sections, in order:
Overview (what it does, the one-paragraph security model, platforms), Install on
Windows, Install on macOS and Linux, Configuration (both files, every key, the
write-or-replace rule), Everyday use, Quoting rules, TOTP leases and lockout,
Migrating work from root, Audit log and rotation, Security model and residual risks,
Development and tests (local runners, CI, how to add a test), Troubleshooting.
Examples use `203.0.113.10` as the address and `you` as the laptop user. The
"Claude Code" mentions are limited to: the default commands, the
`INSTALL_CLAUDE_CODE` key, and one sentence in Overview saying it was built for it.

### 10.3 Scrub

Exact replacements, repository-wide, before the history reset:

| Find | Replace with |
|---|---|
| the real VPS address | `203.0.113.10` |
| the Windows profile path of the author | the same path with the user name replaced by `<you>` |
| the macOS home path, the user name and the handles of the author (any remaining) | `<you>` |
| the `vps` admin alias in docs and code | `tmuxkeep-admin` (code, README) or left as-is inside the two v1 design documents |

The two v1 design documents get this header, inserted after their title line:

> Historical design record for v1, which shipped under the name `sesh`. The tool is now
> `tmuxkeep`; paths, aliases and file names in this document are the v1 ones. Where
> this document and `README.md` differ, the README is right.

A final grep for the real address, the author user name and both handles over the tree must be
empty.

### 10.4 Ignore rules

`.gitignore` becomes `.claude/`, `.superpowers/`, `docs/vps-facts.md`.

### 10.5 Versioning

The broker keeps the git short hash stamp. The first public commit is tagged `v0.1.0`.
No changelog file in v1.1; release notes live on the tag.

### 10.6 History reset (orchestrator, after the merge to `main`, with Doug's go)

1. After the feature branch is merged to `main` and its worktree removed, confirm on
   `main` that the scrub grep of §10.3 is empty and the suites are green.
2. `git branch v1-history main` keeps the full history locally. It is never pushed.
3. `git checkout --orphan public`, `git add -A`, one commit
   `tmuxkeep 0.1.0: initial public release`.
4. `git branch -D main && git branch -m public main`, then `git tag v0.1.0`.
5. Verify: `git log --oneline` on `main` shows one commit; a `git grep` for the real address on it is
   empty; `git branch` lists `main` and `v1-history`.

Step 4 is the one irreversible-looking action (the old `main` survives as
`v1-history`); it runs only after Doug says go at that point.

### 10.7 Publishing (operator-only)

`gh repo create <you>/tmuxkeep --public --source . --remote origin --push`, then
`git push origin v0.1.0`. No agent runs these.

## 11. Repository layout after v1.1

```
LICENSE
README.md
.gitattributes            vps/**, tests/**, laptop/*.sh, laptop/completion.bash: LF
.gitignore                .claude/ .superpowers/ docs/vps-facts.md
.github/workflows/ci.yml
docs/superpowers/specs/   v1 spec (scrubbed, header note), this spec
docs/superpowers/plans/   v1 plan (scrubbed, header note), v1.1 plan
laptop/tmuxkeep.ps1       PowerShell wrapper
laptop/profile-snippet.ps1
laptop/deploy.ps1
laptop/tmuxkeep.sh        bash wrapper
laptop/completion.bash
laptop/deploy.sh
vps/tmuxkeep              broker
vps/tmuxkeep-setup        installer
vps/vps-facts.sh
vps/sshd.conf.tmpl        Match User __USER__ drop-in
vps/sudoers.tmpl          __USER__ ALL=(root) NOPASSWD: ... (rules unchanged from v1)
vps/tmux.conf
vps/systemd/tmuxkeep-reaper.service
vps/systemd/tmuxkeep-reaper.timer
tests/run-bats.ps1  tests/run-bats.sh
tests/docker/Dockerfile
tests/bats/               existing suites renamed + config, laptop-wrapper, laptop-deploy, completion, parity
tests/bats/stubs/         oathtool, ssh, scp, ssh-keygen
tests/pester/             existing suites renamed + config cases
tests/smoke.ps1  tests/smoke.sh
```

Staged to the VPS by both deploys: `tmuxkeep`, `tmuxkeep-setup`, `vps-facts.sh`,
`sshd.conf.tmpl`, `sudoers.tmpl`, `tmux.conf`, `systemd/tmuxkeep-reaper.service`,
`systemd/tmuxkeep-reaper.timer`, plus the generated `laptop.pub` and `deploy.conf`.

## 12. Error handling

v1 §11 holds. New cases, all fail closed with a message naming the key or file:

- laptop config missing on a non-first run, unknown key, bad value, CR or BOM;
- `deploy.conf` rejected by the installer (exit 2 before any step);
- VPS config rejected by `--check-conf` (installer step fails, nothing else changes);
- broker in remote mode with a bad or missing VPS config (exit 1, no audit line);
- `--cmd` text too long or non-printable (exit 2, audit line as for any usage error);
- rc file or `~/.ssh/config` not writable (deploy stops at that step with the path).

## 13. Operator-only steps after the release (replaces v1 O1-O7 for Doug)

1. Create the admin key `~/.ssh/id_tmuxkeep_admin_ed25519` with a passphrase.
2. Run `laptop\deploy.ps1 -Init`: answers the VPS address, writes the config, the
   laptop key and both `Host` blocks.
3. Install the admin public key on the VPS with one root password login (§6.5), then
   `ssh -o PasswordAuthentication=no tmuxkeep-admin true`.
4. Facts: `Get-Content .\vps\vps-facts.sh | ssh tmuxkeep-admin 'bash -s' | Out-File
   -Encoding utf8 docs\vps-facts.md`, hand it to the orchestrator for the G1 review.
5. Set `INSTALL_CLAUDE_CODE=yes` in `~/.tmuxkeep/config`, run `laptop\deploy.ps1`
   (passphrase twice, TOTP QR shown once, never pasted into an agent conversation).
6. `tmuxkeep new scratch`, `tmuxkeep go scratch`, log Claude Code in, detach.
7. Migrate work out of `/root` (README section).
8. `tests\smoke.ps1`.
9. `laptop\deploy.ps1 -HardenRoot`.
10. Publish (§10.7).

Steps 1-9 are unchanged in substance from v1; only names and the `-Init` step are new.

## 14. Assumptions to verify during planning

- GitHub-hosted `windows-latest` runners ship Windows PowerShell 5.1 as
  `powershell.exe` alongside pwsh (true as of 2026; the plan's first CI task confirms
  it with `$PSVersionTable`).
- GitHub-hosted `macos-latest` runners have `/bin/bash` 3.2 and Homebrew.
- `bats-core` from Homebrew runs under `/bin/bash` 3.2 (bats-core supports bash 3.2).
- `docs/vps-facts.md` does not exist yet in the checkout (true at the time of writing,
  so adding it to `.gitignore` orphans nothing).

## 15. Non-goals for v1.1

- pwsh 7 or fish support on the laptop; Windows via WSL is covered by the bash side.
- A non-root admin user or sudo-based deploys (D11).
- Configurable ssh alias names, key id, or tombstone prefix.
- Per-session persistent command settings beyond the one-shot `--cmd`.
- Multiple VPS hosts from one laptop config.
- Packaging (Homebrew, apt, winget). Install is the clone-and-deploy path only.
- The v2 user split that would protect against code running as `USER` (v1 D2).
- Distinguishing "no tmux server" from other tmux errors in `ls` and `reap`.

## 16. Amendments from planning (2026-10-12)

Rulings on the plan's "Questions for the orchestrator". Where these differ from the
sections above, these win.

- **§4.5, local mode config (plan Q1).** Local mode reads `TMUXKEEP_CONF` when set,
  else `/etc/tmuxkeep/tmuxkeep.conf` when it exists, else the built-in defaults. A
  present but invalid system file is exit 1. Otherwise the hourly reaper would ignore
  a configured `TOMBSTONE_TTL`.
- **§7.1, shell-only sessions (plan Q2, changed).** Neither wrapper can send an empty
  word, so `new` and `resume` gain a `--shell` flag meaning "type no command". `--cmd`
  with a blank value (empty or spaces only) means the same. `--shell` and `--cmd`
  together are a usage error (exit 2). The audit entry records `"cmd": ""` for both.
- **§6.4, zsh rc block (plan Q3).** The second line of the block loads `compinit` when
  `compdef` is missing, before `bashcompinit`, so a fresh macOS account does not print
  an error at every shell start.
- **§6.1 step 6, remote cleanup (plan Q4).** The setup command keeps v1's suffix
  `; rc=$?; rm -rf /root/<stage>; exit $rc`, fixed words only.
- **§4.1-§4.4, required keys (plan Q5).** `deploy.conf` and the VPS config require
  every key. The laptop config requires only `HOST`; other missing keys take defaults.
- **§10.3, scrub (plan Q6).** The GitHub and e-mail handles are replaced with `<you>`,
  and the lines of this spec that quote the scrub patterns are rewritten to describe
  them.
- **§7.2, config check (plan Q7).** The installer renders the VPS config to a
  dot-prefixed temp file, runs `--check-conf` on that file, and only then moves it over
  the old one.
- **§7.3, facts arguments (plan Q8).** Line 2 becomes
  `case "$0" in *vps-facts.sh) ;; *) tr -d '\r' | bash -s -- "$@"; exit $? ;; esac #`
  and the operator runs `ssh tmuxkeep-admin 'bash -s -- --user <name>'`.
- **§6.3, profile snippet (plan Q9).** The profile block is write-or-replace too.
- **§6.1, key paths in `~/.ssh/config` (plan Q10).** Written as configured, double-
  quoted when the path contains a space; a value containing `"` is rejected.
- **§6.5, admin help (plan Q11).** The help substitutes the first line of the admin
  public key when it exists, else a placeholder, and `--init`/`-Init` prints the help
  when it finishes.
- **§9.2, §9.4, test seams (plan Q12).** `deploy.ps1` gains `-HomeDir` and
  `-ProfilePath` (defaults `$HOME`, `$PROFILE`) and its tests run it as a child
  process with stub executables first on `PATH`; `deploy.sh` tests run it from a
  temporary one-commit git copy.
- **§7.2, account guards (plan Q13).** The installer refuses an existing account whose
  uid is outside 1000-59999, and a `USER` that differs from the one in the installed
  VPS config, both before any change. The README documents the manual steps for
  changing the user.
- **§4.2, `HOST` (plan Q14).** A value with exactly one `:` is rejected with
  `HOST: looks like host:port; put the port in PORT`.
- **§6.4, completion cache (plan Q15).** File age uses `stat -c %Y` on Linux and
  `stat -f %m` elsewhere, chosen by `uname -s`; a symlinked or foreign-owned cache
  file is neither read nor written.
- **§9.6, CI (plan Q16).** The Windows job uses `shell: cmd` and calls
  `powershell.exe -NoProfile`; the macOS job puts `/bin` first on `PATH`. A private
  dry-run push before the history reset is optional and Doug's call at that time.
- **§10.6, commit author (plan Q17).** Doug keeps his normal git identity on the
  public commit.
- **§6.2, §6.4, message streams (plan Q18).** Unchanged: `Write-Host` in the PowerShell
  wrapper, stderr in the bash wrapper.
