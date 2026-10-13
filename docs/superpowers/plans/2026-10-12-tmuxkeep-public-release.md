# tmuxkeep v1.1 Public Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the working v1 session broker into `tmuxkeep`, a tool anyone can install on their own Debian or Ubuntu VPS from Windows PowerShell 5.1 or from bash on macOS and Linux, with every site value in a config file, the same broker, gate, audit log and reaper as v1, CI on three platforms, and a repository that holds nothing specific to its author.

**Architecture:** A mechanical rename comes first so every later diff is small. The broker gains a strict, root-owned config file (`/etc/tmuxkeep/tmuxkeep.conf`) and configurable session commands; the installer gains `--conf`, a configurable user and `__USER__` templates, and writes the broker's config. The laptop side gets one config file (`~/.tmuxkeep/config`) read by two deploy scripts (PowerShell, bash) that write identical bytes, checked against shared fixtures under `tests/fixtures/`. A bash wrapper and completion join the PowerShell ones; parity tests, a CI workflow, the README rewrite and the scrub close the release.

**Tech Stack:** bash 5 on the VPS (broker, installer), bash 3.2 and BSD userland on the laptop (macOS `/bin/bash`), Windows PowerShell 5.1; tmux >= 3.0, oathtool, jq, OpenSSH, systemd user units; tests: bats 1.8 in Docker (`debian:bookworm`, shellcheck inside), Pester >= 5.5 (6.2.0 installed) under `powershell.exe`, bats-core under `/bin/bash` on macOS CI; GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-12-tmuxkeep-public-release-design.md` (approved; its decisions D5-D11 are settled). It builds on `docs/superpowers/specs/2026-10-09-sesh-session-broker-design.md` (the v1 spec), which remains the authority for everything the new spec does not change. Section numbers written "spec 4.2" refer to the new spec, "v1 spec 7.1" to the old one. Where this plan departs from the spec text, the departure is listed under "Questions for the orchestrator" at the end with its recommended answer, and the plan is written against that recommendation.

**How much code this plan contains:** tests are given in full; they are the contract. Fixtures, templates, short scripts and every line another file parses are given verbatim. For longer product code the plan gives exact interfaces, behaviour, messages and the load-bearing fragments; the implementer writes the rest.

## Global Constraints

Every task's requirements include this section. A task repeats what it needs; if the two ever disagree, stop and report.

**Safety**

- **G1.** Never connect to any remote host. No `ssh` or `scp` to `tmuxkeep`, `tmuxkeep-admin` or any address. The only network access allowed is the image build that `tests/run-bats.ps1` (or `tests/run-bats.sh`) performs.
- **G2.** Never run `laptop/deploy.ps1` or `laptop/deploy.sh` yourself. The test suites run them only as child processes with stub `ssh`, `scp` and `ssh-keygen` first on `PATH` and every home path inside a temp directory. Never run the `main` of `vps/tmuxkeep-setup` except with arguments that make it exit 2 before any step; the bats suites `source` it to test its functions. Never run `tests/smoke.ps1` or `tests/smoke.sh` yourself; only `tests/pester/smoke.Tests.ps1` and `tests/bats/smoke.bats` run them, with a fake wrapper.
- **G3.** The TOTP secret and any first-deploy output never enter an agent transcript. Deploy never captures the installer's stdout: the `ssh` that runs `tmuxkeep-setup` is a plain statement (PowerShell) or a plain command (bash), with no `$(...)`, no assignment, no pipe and no redirection. The admin key is never added to the ssh-agent: no `ssh-add` call anywhere, and no `AddKeysToAgent` written anywhere (the only allowed occurrence is the help sentence `Never ssh-add the admin key and never set AddKeysToAgent for it.`).
- **G4.** Edit `docs/superpowers/**` only in Task 20. Never write a real address or a personal path anywhere: examples use `203.0.113.10`, `198.51.100.20` and the user name `you`.

**Verification**

- **G5.** Bats: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/<file>.bats`; with no `-Path` it runs the whole `tests/bats` directory. It rebuilds the image every run (`tmuxkeep-bats:latest` from Task 1 on). Bats prints TAP because there is no TTY: **pass means every result line is `ok N ...`, there is no `not ok` line, and the exit code is 0.** Exit 2 means Docker is unavailable or the path is wrong.
- **G6.** Pester: run this from the PowerShell tool, with `$c.Run.Path` set to the file the task names, or `'tests\pester'` for the whole folder. **Pass means `Tests Passed: N, Failed: 0` and exit 0.**

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command {
    Set-Location -LiteralPath (git rev-parse --show-toplevel)
    Import-Module Pester -MinimumVersion 5.5
    $c = New-PesterConfiguration
    $c.Run.Path = 'tests\pester'
    $c.Run.Exit = $true
    $c.Output.Verbosity = 'Detailed'
    Invoke-Pester -Configuration $c
  }
  ```

- **G7.** shellcheck runs only inside the Docker image (through bats) and on macOS CI, always as `shellcheck --shell=bash -S warning <file>`, with no `-e`/`--exclude`, no `SHELLCHECK_OPTS`, and no new `# shellcheck disable` directive. The two that exist stay: SC2034 on the version line of `vps/tmuxkeep`, SC2016 in `ensure_path_snippet` of `vps/tmuxkeep-setup`.
- **G8.** Before every commit run the whole bats directory and the whole Pester folder; both pass. No task leaves either suite red.

**Files and line endings**

- **G9.** `.gitattributes` forces LF for `vps/**`, `tests/**` and, from Task 10 on, `laptop/*.sh` and `laptop/completion.bash`. The laptop's git has `core.autocrlf=true`. Check in Git Bash, which must print nothing (leave out a glob that matches no file yet): `grep -rlIU "$(printf '\r')" vps tests laptop/*.sh laptop/completion.bash`. The `-U` is required: without it Git for Windows' grep strips the CR and the check passes silently. Fix an offender with `sed -i 's/\r$//' <file>` (Git Bash). Never rely on `$'\r'` in the Bash tool.
- **G10.** `core.fileMode=false`, so record exec bits with `git add --chmod=+x <file>` for `vps/tmuxkeep`, `vps/tmuxkeep-setup`, `vps/vps-facts.sh`, every file in `tests/bats/stubs/`, `laptop/tmuxkeep.sh`, `laptop/deploy.sh`, `tests/run-bats.sh`, `tests/smoke.sh`.
- **G11.** Every file this plan creates or edits is ASCII only. Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI, so a `.ps1` file must never contain a byte above 127; build non-ASCII test strings with `[char]0x00E9`.
- **G12.** From Task 1 on, `git grep -n -i sesh -- . ':!docs/superpowers'` prints nothing. Keep it that way.

**Windows PowerShell 5.1 (every `.ps1`)**

- **G13.** `laptop/tmuxkeep.ps1` has no `param()` block and no `[CmdletBinding()]` at the top; they would capture `-n` and `-d`. Helper functions may declare param blocks.
- **G14.** PowerShell drops empty arguments and a bare `--` when it calls a native program, turns `a, b` into one array argument and numbers into Int32. The wrapper flattens, stringifies and rejects empty words.
- **G15.** ssh-keygen's empty passphrase is written `-N '""'`. That works only in 5.1, which is why `deploy.ps1` refuses any edition other than `Desktop` before its first `ssh-keygen`.
- **G16.** Never write a file with `>`, `Out-File`, `Set-Content` or `Tee-Object` in product code. Use `[IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding $false))` for UTF-8 without BOM and `[IO.File]::WriteAllBytes` for byte-exact rewrites. Tests may use `Set-Content -Encoding ascii` / `Add-Content -Encoding ascii`. Use `-LiteralPath` for every path. Inside double-quoted strings write `${Path}:` (never `$Path:`), because `$Path:` parses as a scope-qualified variable.
- **G17.** Never redirect a native command's stderr (`2>`, `2>&1`, `*>`) in product scripts: 5.1 wraps each line in an error record. The completer's `2>$null` is the one exception. ssh runs as a plain statement so the console stays attached (TOTP prompt, `go`, the QR code).
- **G18.** Pester 6: no file-level `BeforeEach` (wrap each test file in one top-level `Describe`); never put angle brackets in an `It` or `Describe` name, because Pester reads `<x>` as a template (the deliberate `-ForEach` templates such as `'<Name> ...'` are the exception). `[Console]::Error.WriteLine` bypasses the PowerShell error stream, so stderr handling is tested with a real native child (`cmd.exe /c 'echo x 1>&2'`). The completer is registered with `Register-ArgumentCompleter -Native`. A test file that dot-sources `laptop/deploy.ps1` must not use the variable names `$Config`, `$Init`, `$HardenRoot`, `$RotateTotp`, `$UnlockOtp`, `$HomeDir` or `$ProfilePath`: dot-sourcing sets them from the script's param block.

**bash on the laptop: 3.2 (macOS `/bin/bash`) and BSD userland**

These rules apply to `laptop/tmuxkeep.sh`, `laptop/deploy.sh`, `laptop/completion.bash`, `tests/bats/laptop-helpers.bash`, `tests/bats/stubs/ssh`, `tests/bats/stubs/scp`, `tests/bats/stubs/ssh-keygen`, `tests/smoke.sh`, `tests/run-bats.sh`, and every bats file that loads `laptop-helpers`.

- **G19.** None of: associative arrays (`declare -A`), `declare -n`/`-g`, `mapfile`/`readarray`, case modification `${v,,}` `${v^^}`, `read -i`, `|&`, `;&`, `;;&`, `coproc`, `[[ -v`, `${v@Q}`, negative subscripts `${a[-1]}`, `printf '%(...)T'`, `EPOCHSECONDS`, `BASHPID`, `wait -n`, `&>>`, `shopt -s globstar|lastpipe`. Fine: `[[ ]]`, indexed arrays, `+=`, `printf -v`, `${v//a/b}`, `${!name}`, here-strings, here-documents, process substitution.
- **G20.** No `set -u` (bash 3.2 treats an empty array as unset). `set -o pipefail` only inside a main function.
- **G21.** No GNU-only tools or flags: no `sed -i`, `grep -P`, `readlink -f`, `date -d`, `base64 -w`/`-d`, `realpath`, `timeout`, `mktemp --suffix`; `stat` only inside the `uname -s` branch of `completion.bash`. `wc -c` and `wc -l` pad with spaces on macOS: compare `$(( $(wc -l < f) ))`. awk is BWK-compatible (no `gensub`, no `length(array)`); pass text that may contain backslashes or newlines to awk through `ENVIRON`, never `-v`.
- **G22.** Tests run scripts with `"$BASH"` (the interpreter that runs bats), never a bare `bash`, so the macOS job really exercises `/bin/bash` 3.2.
- **G23.** In `laptop/` product files, the completer's ssh is the only command whose stderr is discarded (`2>/dev/null`).

**Broker rules carried from v1 (`vps/tmuxkeep`)**

- **G24.** `fail` and `succeed` exit the shell: never call them inside `$(...)`, a pipeline segment or `cmd | while read`. Every verb calls `authorize` once, after validating its arguments and before touching tmux; `authorize` fails closed (`gate || fail 4 ...`). Every tmux call goes through `tmx`, targets through `tmux_on` (`-t "=$name:"`); the one exception is the `exec ... tmux attach-session` in `verb_go`. Arithmetic on any value read from a file or an argument uses `10#`. `umask 022` comes right after `authorize` in `new` and `resume`. Audit lines are built with `jq -acn ... 2>/dev/null >> "$AUDIT_FILE"`. `TMUXKEEP_*` overrides are honoured only in local mode. No `eval`, no `has-session`.
- **G25.** Exit codes: 0 ok, 2 usage, 3 refused, 4 auth, 5 not found, 1 anything else. Every failure prints one stderr line `tmuxkeep: <message>` and writes one audit line. Exceptions: `audit log not writable`, and config errors, which print `tmuxkeep: config invalid: <path>: <reason>`, exit 1 and audit nothing (the audit path comes from the config).

**Installer rules carried from v1 (`vps/tmuxkeep-setup`)**

- **G26.** The sudoers file is staged under a dot-prefixed name in `/etc/sudoers.d` (sudo ignores names containing a dot), validated with `visudo -cf` on that exact file, then `mv`'d into place. The sshd drop-in is installed only after `sshd -t` and a before/after comparison of `sshd -T -C user=root,host=localhost,addr=127.0.0.1` (only `permitrootlogin` may differ, and only when hardening), with rollback on any failure; then `sshd -T -C user=<USER>,host=localhost,addr=127.0.0.1` must show the expected `authorizedkeysfile` and `passwordauthentication no`. An existing `chattr +a` audit log is never `chown`ed or `chmod`ed. The user manager is reached as `runuser -u <USER> -- env XDG_RUNTIME_DIR=/run/user/<uid> systemctl --user ...`, never with `systemctl --user -M`. `set -u -o pipefail` only inside `main`, so tests can `source` the file. Functions print a message and return non-zero; only `die` and `main` exit.

**Names fixed by the spec**

- **G27.** ssh aliases `tmuxkeep` (the broker, as USER) and `tmuxkeep-admin` (root). Key id `laptop`. Laptop keys `~/.ssh/id_tmuxkeep_ed25519` (comment `tmuxkeep-laptop`, no passphrase) and `~/.ssh/id_tmuxkeep_admin_ed25519` (comment `tmuxkeep-admin`, with a passphrase). Markers `# >>> tmuxkeep` and `# <<< tmuxkeep`. Local staging parent `tmuxkeep-stage-<14 digits>`, copied folder `tmuxkeep-deploy-<14 digits>` in `/root/`. VPS paths: `/usr/local/bin/tmuxkeep`; `/etc/tmuxkeep/authorized_keys`, `/etc/tmuxkeep/tmux.conf`, `/etc/tmuxkeep/tmuxkeep.conf`; `/var/log/tmuxkeep/audit.log`; `/etc/ssh/sshd_config.d/tmuxkeep.conf`; `/etc/sudoers.d/tmuxkeep`; `<USER_HOME>/.tmuxkeep`; `<USER_HOME>/work`; user units `tmuxkeep-reaper.service` and `tmuxkeep-reaper.timer`; socket `$XDG_RUNTIME_DIR/tmuxkeep.sock`.
- **G28.** Gated verbs, everywhere: `new go send rename unlock rm resume auth`. Completion verbs: `new ls peek go send rename lock unlock rm restore resume log auth`. Name-completing verbs: `peek go send rename lock unlock rm resume`. `restore` completes tombstone base names.
- **G29.** Staged VPS files, in this order everywhere: `tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer`. The deploys add the generated `laptop.pub` and `deploy.conf`.

**Config rules (spec 4.1), shared by the four parsers: broker, installer, PowerShell deploy, bash deploy**

- **G30. Parsing.**
  1. A file whose first three bytes are `EF BB BF` fails with `byte order mark found (save without BOM)`. A file containing any byte `0D` fails with `carriage return found (use LF line endings)`.
  2. Split on LF; trim spaces and tabs from each line. Skip empty lines and lines that start with `#`.
  3. A line without `=` fails with `line <n>: expected KEY=value` (n counts every line, from 1).
  4. Key is the text before the first `=`, value the text after it, both trimmed. A key that is not `^[A-Z_]+$` or not in that file's key list fails with `line <n>: unknown key <KEY>`; write just `line <n>: unknown key` when the key does not match `^[A-Za-z0-9_]{1,64}$`.
  5. A value with any character outside `0x20-0x7E` fails with `line <n>: non-printable or non-ASCII character in <KEY>`.
  6. A key given twice: the last one wins.
  7. After the last line: a missing required key fails with `<KEY>: required`; then the keys are validated in list order and the first failure is reported.
  8. The parser's error text is `<path>: <reason>`. Consumers prefix it: broker `tmuxkeep: config invalid: <path>: <reason>` (exit 1); installer `tmuxkeep-setup: deploy.conf invalid: <path>: <reason>` (exit 2); both deploys `deploy: config <path>: <reason>` (exit 2).
- **G31. Key lists.**
  - Laptop config `~/.tmuxkeep/config`: `HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES`. `HOST` is required (missing or empty); every other missing key takes its default (plan Q5).
  - `deploy.conf`: `USER LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES`. Every key required (plan Q5).
  - VPS config `/etc/tmuxkeep/tmuxkeep.conf`: `USER USER_HOME STATE_DIR WORK_DIR AUDIT_LOG LAUNCH_CMD RESUME_CMD LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES`. Every key required (plan Q5).
- **G32. Validation.** An integer is `^[0-9]{1,7}$` read as base 10 (leading zeros allowed), then range-checked; its message is `<KEY>: must be an integer from <lo> to <hi>`.

  | Key | Default | Valid when | Message |
  |---|---|---|---|
  | `HOST` | none | non-empty; does not contain exactly one `:`; matches `^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$` | `HOST: required` / `HOST: looks like host:port; put the port in PORT` / `HOST: not a hostname, IPv4 or IPv6 address` (checked in that order) |
  | `PORT` | `22` | integer 1-65535 | `PORT: must be an integer from 1 to 65535` |
  | `USER` | `claude` | `^[a-z_][a-z0-9_-]{0,31}$` | `USER: must match ^[a-z_][a-z0-9_-]{0,31}$` |
  | `KEY` | `~/.ssh/id_tmuxkeep_ed25519` | non-empty, no `"` | `KEY: must be a non-empty path without double quotes` |
  | `ADMIN_KEY` | `~/.ssh/id_tmuxkeep_admin_ed25519` | non-empty, no `"` | `ADMIN_KEY: must be a non-empty path without double quotes` |
  | `USER_HOME`, `STATE_DIR`, `WORK_DIR`, `AUDIT_LOG` (VPS only) | `/home/claude`, `/home/claude/.tmuxkeep`, `/home/claude/work`, `/var/log/tmuxkeep/audit.log` | at most 255 bytes, `^(/[A-Za-z0-9._-]+)+$`, no `.` or `..` component | `<KEY>: must be an absolute path made of letters, digits, dot, underscore, hyphen and slash` |
  | `LAUNCH_CMD` | `claude` | 0-200 characters | `LAUNCH_CMD: at most 200 characters` |
  | `RESUME_CMD` | `claude --continue` | 0-200 characters | `RESUME_CMD: at most 200 characters` |
  | `INSTALL_CLAUDE_CODE` | `no` | `yes` or `no` | `INSTALL_CLAUDE_CODE: must be yes or no` |
  | `LEASE_SECS` | `1800` | 60-86400 | integer message |
  | `TOMBSTONE_TTL` | `86400` | 3600-2592000 | integer message |
  | `OTP_FAIL_MAX` | `3` | 1-20 | integer message |
  | `OTP_FAIL_WINDOW` | `600` | 60-86400 | integer message |
  | `OTP_COOLDOWN` | `300` | 10-86400 | integer message |
  | `OTP_HARD_MAX` | `10` | `OTP_FAIL_MAX`-100 | `OTP_HARD_MAX: must be an integer from <the OTP_FAIL_MAX value> to 100` |
  | `OTP_READ_TIMEOUT` | `60` | 10-600 | integer message |
  | `SEND_MAX_BYTES` | `8000` | 1-65536 | integer message |

- **G33. Fixtures.** `tests/fixtures/tmuxkeep.conf` (Task 2), `tests/fixtures/deploy.conf` (Task 5), `tests/fixtures/laptop-config` (Task 7) and `tests/fixtures/ssh-block` (Task 8) hold the exact bytes the writers must produce for the default config with `HOST=203.0.113.10`. Every consumer task repeats the content it needs.

**Process**

- **G34. Models.** Each task names a suggested model. Haiku tasks contain every exact string to change; if a Haiku task's verification fails, Haiku stops and reports the output instead of improvising a fix.
- **G35.** Stop and report, do not guess, on any design question, ambiguity, missing tool, or a test that cannot pass without weakening it.
- **G36.** One commit per task on the branch you were given, with the subject the task gives, ending with the attribution trailer your harness specifies. Never amend, never push.

## Review Focus

These are the inputs the spec implies but does not test, most likely first. Each has a test in the owning task.

1. **`USER` names an existing system account** (`root`, `daemon`, `nobody`). A reasonable person expects the installer to refuse before it hands that account sudo rules, a disabled password and a forced command; with `root` it would also replace root's `AuthorizedKeysFile` and lock the admin out. The installer stops at preflight with exit 1 and `refusing USER=<u>: uid <n> is a system account; choose a dedicated user name` for any existing uid outside 1000-59999. *Test in Task 5.*
2. **The first-run answer is `203.0.113.10:2222`, ` 203.0.113.10 ` or `you@203.0.113.10`.** Surrounding spaces are trimmed; a single colon is rejected with `HOST: looks like host:port; put the port in PORT` (the spec regex alone would accept it and write a broken `HostName`); `you@...` is rejected as not a hostname; nothing is written. An IPv6 literal such as `2001:db8::1` is accepted. *Tests in Task 7 (PowerShell) and Task 12 (bash).*
3. **`~/.bashrc`, `~/.zshrc` or `~/.ssh/config` is a symlink** (dotfiles managers such as stow). The block is written through the link and the link stays a link. *Test in Task 13.*
4. **A zsh user whose `.zshrc` never runs `compinit`** (a fresh macOS account). bashcompinit's `complete` calls `compdef`, so the spec's block would print `complete:13: command not found: compdef` at every shell start. The rc block loads `compinit` when `compdef` is missing (plan Q3), and completion registers. *Test in Task 13.*
5. **`USER` changed after a first deploy** (`claude` to `bob`). The audit log stays owned by `claude` with `chattr +a`, so the new broker could not write it and every call would fail. The installer stops at preflight with exit 1 and points to the README section "Changing the VPS user". *Test in Task 5; README text in Task 19.*

---

## Execution notes

- **Roles.** The orchestrator briefs each task to a fresh subagent with the suggested model and reviews the diff. Ask Opus to review Tasks 2, 5, 6, 9 and 14 (config parsing, root installer, admin path and the never-capture rule). The history reset and publishing are not tasks; see "After the merge" near the end.
- **Working directory.** Commands assume the repository root (or the worktree you were given). Git Bash commands are marked; everything else runs from the PowerShell tool.
- **Bats on macOS.** Agents cannot run the macOS job. The laptop suites run in Docker with bash 5; bash 3.2 compliance is enforced statically by `tests/bats/lint-laptop.bats` (Task 10) and dynamically only in CI (Task 18).
- **Test counts.** Each task states how many tests its new or changed file adds. The whole-suite rule is G8.

## File map

| Path | Responsibility | Task |
|---|---|---|
| everything named `sesh` | renamed to `tmuxkeep` | 1 |
| `vps/tmuxkeep` | broker: config file, `--check-conf`, session commands, `--cmd` | 1, 2, 3 |
| `tests/fixtures/tmuxkeep.conf` | VPS config for the defaults | 2 |
| `tests/bats/helpers.bash` | broker helpers; temp config, `/etc/tmuxkeep/tmuxkeep.conf` for remote tests | 1, 2 |
| `tests/bats/broker-config.bats`, `tests/bats/broker-remote.bats` | config tests | 2 |
| `tests/bats/broker-cmd.bats` | `LAUNCH_CMD`, `RESUME_CMD`, `--cmd` | 3 |
| `vps/vps-facts.sh`, `tests/bats/facts.bats` | `--user` | 4 |
| `vps/tmuxkeep-setup` | installer: `--conf`, user, guards, opt-in install, templates, VPS config | 5, 6 |
| `tests/fixtures/deploy.conf` | deploy-to-installer handoff for the defaults | 5 |
| `tests/bats/setup-conf.bats`, `tests/bats/setup-render.bats`, `tests/bats/setup.bats`, `tests/bats/config.bats` | installer tests | 5, 6 |
| `vps/sshd.conf.tmpl`, `vps/sudoers.tmpl` | `__USER__` templates | 1 (rename), 6 |
| `laptop/deploy.ps1` | PowerShell deploy | 7, 8, 9 |
| `tests/fixtures/laptop-config`, `tests/fixtures/ssh-block` | laptop config and marked block for the defaults | 7, 8 |
| `tests/pester/config.Tests.ps1`, `tests/pester/deploy.Tests.ps1` | PowerShell deploy tests | 7, 8, 9 |
| `laptop/tmuxkeep.sh`, `tests/bats/stubs/{ssh,scp,ssh-keygen}`, `tests/bats/laptop-helpers.bash`, `tests/bats/laptop-wrapper.bats`, `tests/bats/lint-laptop.bats` | bash wrapper and laptop test harness | 10 |
| `laptop/completion.bash`, `tests/bats/completion.bats` | bash completion | 11 |
| `laptop/deploy.sh`, `tests/bats/laptop-config.bats`, `tests/bats/laptop-blocks.bats`, `tests/bats/laptop-deploy.bats` | bash deploy | 12, 13, 14 |
| `tests/bats/parity.bats` | cross-file lists | 15 |
| `tests/smoke.sh`, `tests/bats/smoke.bats` | bash smoke test | 16 |
| `tests/run-bats.sh`, `tests/bats/lint.bats`, `tests/bats/00-env.bats`, `tests/pester/static.Tests.ps1` | runners and static checks | 17 |
| `.github/workflows/ci.yml`, `tests/bats/ci.bats` | CI | 18 |
| `README.md` | rewrite | 19 |
| `LICENSE`, `.gitignore`, v1 docs, scrub | release hygiene | 20 |

## Task overview

| # | Task | Suggested model | Depends on |
|---|---|---|---|
| 1 | Rename `sesh` to `tmuxkeep` | haiku | none |
| 2 | Broker: config file, `--check-conf`, local and remote loading | sonnet | 1 |
| 3 | Broker: `LAUNCH_CMD`, `RESUME_CMD`, `--cmd` | sonnet | 2 |
| 4 | Facts script: `--user` | sonnet | 1 |
| 5 | Installer: `--conf`, configurable user, account guards, Claude Code opt-in | sonnet | 2 |
| 6 | Installer: `__USER__` templates, VPS config file, `--check-conf` gate | sonnet | 5 |
| 7 | PowerShell deploy: laptop config functions | sonnet | 5 |
| 8 | PowerShell deploy: write-or-replace marked blocks | sonnet | 7 |
| 9 | PowerShell deploy: staging, setup command, admin help, main sequence | sonnet | 6, 8 |
| 10 | Bash wrapper, stubs, laptop helpers and laptop lint | sonnet | 1 |
| 11 | Bash completion | sonnet | 10 |
| 12 | Bash deploy: laptop config functions | sonnet | 7, 10 |
| 13 | Bash deploy: ssh config and rc blocks (symlinks, zsh) | sonnet | 8, 11, 12 |
| 14 | Bash deploy: staging, setup command, admin help, main sequence | sonnet | 6, 13 |
| 15 | Parity tests | sonnet | 9, 14 |
| 16 | `tests/smoke.sh` | sonnet | 10 |
| 17 | Static checks and `tests/run-bats.sh` | sonnet | 14, 16 |
| 18 | CI workflow | sonnet | 17 |
| 19 | README rewrite | sonnet | 18 |
| 20 | LICENSE, `.gitignore`, v1 document headers, scrub | haiku | 19 |
| 21 | Full verification report | haiku | 20 |

Tasks 4, 7-9 and 10-11 touch disjoint files and may run in parallel lanes once their dependencies are met; everything else is sequential.

---

### Task 1: Rename `sesh` to `tmuxkeep`

Suggested model: haiku. Justification: every command, every exact string and every expected result is written below; nothing calls for judgment. If any check fails, stop and report its output.

**Files:**
- Rename (with `git mv`): `vps/sesh` to `vps/tmuxkeep`; `vps/sesh-setup` to `vps/tmuxkeep-setup`; `vps/sshd-sesh.conf` to `vps/sshd.conf.tmpl`; `vps/sudoers-claude` to `vps/sudoers.tmpl`; `vps/systemd/sesh-reaper.service` to `vps/systemd/tmuxkeep-reaper.service`; `vps/systemd/sesh-reaper.timer` to `vps/systemd/tmuxkeep-reaper.timer`; `laptop/sesh.ps1` to `laptop/tmuxkeep.ps1`; `tests/pester/sesh.Tests.ps1` to `tests/pester/tmuxkeep.Tests.ps1`.
- Modify: every tracked file outside `docs/superpowers/` that mentions `sesh` in any case, plus the exact `vps`-alias lines listed in Step 4 and the five completer test lines in Step 5.

**Interfaces:**
- Consumes: the repository at HEAD (v1, clean tree).
- Produces, for every later task: the file names above; broker variable and env names `TMUXKEEP_VERSION=dev` (one line), `TMUXKEEP_HOME`, `TMUXKEEP_AUDIT`, `TMUXKEEP_WORK`, `TMUXKEEP_TMUX_SOCKET`, `TMUXKEEP_OATHTOOL`, `TMUXKEEP_NOW`; messages prefixed `tmuxkeep:` and `tmuxkeep-setup:`; tmux option `@tmuxkeep_locked`; socket `tmuxkeep.sock`; state directory `.tmuxkeep`; VPS paths `/usr/local/bin/tmuxkeep`, `/etc/tmuxkeep`, `/var/log/tmuxkeep`, `/etc/ssh/sshd_config.d/tmuxkeep.conf`, `/etc/sudoers.d/tmuxkeep` (staged as `/etc/sudoers.d/.tmuxkeep.new`); installer variables `TMUXKEEP_ETC`, `SUDOERS_DEST`, and (unchanged until Task 5) `CLAUDE_USER`, `CLAUDE_HOME`; installer `STAGED_FILES=(tmuxkeep sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer)`; bats helpers `TMUXKEEP_BIN=/src/vps/tmuxkeep`, functions `tmuxkeep`, `tmuxkeep_key`, `tmuxkeep_nokey`; image `tmuxkeep-bats:latest`; PowerShell functions `ConvertTo-TmuxkeepWords`, `ConvertTo-TmuxkeepToken`, `Get-TmuxkeepSshArgs`, `global:tmuxkeep`, `global:Get-TmuxkeepCompletionList`, `ConvertTo-TmuxkeepLf`, `Write-TmuxkeepLfFile`, `Get-TmuxkeepVersion`, `New-TmuxkeepStaging`, `Add-TmuxkeepMarkedBlock`, `Add-TmuxkeepHostBlock`, `Add-TmuxkeepProfileSnippet`, `Get-TmuxkeepSetupCommand`, `Show-TmuxkeepAdminHelp`; ssh aliases `tmuxkeep` and `tmuxkeep-admin`; key files `id_tmuxkeep_ed25519` and `id_tmuxkeep_admin_ed25519`; markers `# >>> tmuxkeep` / `# <<< tmuxkeep`; completer caches `tmuxkeep-names.txt` and `tmuxkeep-tombstones.txt`.
- Unchanged on purpose: the `b64` wire protocol, the verbs, exit codes, name rules, the `zz~<name>~<epoch>` tombstone format, the key id `laptop`, the audit field names, the `claude` user (Task 5 makes it configurable), the VPS address in `laptop/deploy.ps1` (Task 9 removes it).

- [ ] **Step 1: Preflight and baseline**

Run (Git Bash):

```bash
git status --porcelain
docker info --format '{{.ServerVersion}}'
```

Expected: no output from the first command; a version string from the second. If `docker info` fails, stop and report `BLOCKED: Docker Desktop is not running`.

Record the baseline: run the whole bats directory (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1`) and note the number of `ok` lines (204 at the start of this plan); run the whole Pester folder with the G6 command and note `Tests Passed: N`. Both must be fully green before you change anything.

- [ ] **Step 2: Move the files**

Run (Git Bash):

```bash
git mv vps/sesh vps/tmuxkeep
git mv vps/sesh-setup vps/tmuxkeep-setup
git mv vps/sshd-sesh.conf vps/sshd.conf.tmpl
git mv vps/sudoers-claude vps/sudoers.tmpl
git mv vps/systemd/sesh-reaper.service vps/systemd/tmuxkeep-reaper.service
git mv vps/systemd/sesh-reaper.timer vps/systemd/tmuxkeep-reaper.timer
git mv laptop/sesh.ps1 laptop/tmuxkeep.ps1
git mv tests/pester/sesh.Tests.ps1 tests/pester/tmuxkeep.Tests.ps1
```

- [ ] **Step 3: Replace the name everywhere outside `docs/superpowers/`**

Run (Git Bash), exactly as written. The order of the `-e` expressions matters: the two file names that do not simply swap `sesh` for `tmuxkeep` go first.

```bash
git grep -l -i -E 'sesh|sudoers-claude|sudoers\.d/claude|\.claude\.new' -- . ':!docs/superpowers' \
  | xargs sed -i \
      -e 's/sshd-sesh\.conf/sshd.conf.tmpl/g' \
      -e 's/sudoers-claude/sudoers.tmpl/g' \
      -e 's#/etc/sudoers\.d/claude#/etc/sudoers.d/tmuxkeep#g' \
      -e 's#/\.claude\.new#/.tmuxkeep.new#g' \
      -e 's/sesh/tmuxkeep/g' \
      -e 's/Sesh/Tmuxkeep/g' \
      -e 's/SESH/TMUXKEEP/g'
```

- [ ] **Step 4: Replace the `vps` admin alias in deploy, its test and the README line the test reads**

Run (Git Bash):

```bash
sed -i \
  -e 's/or vps is unreachable/or tmuxkeep-admin is unreachable/' \
  -e 's/id_vps_admin_ed25519/id_tmuxkeep_admin_ed25519/g' \
  -e 's/-C vps-admin/-C tmuxkeep-admin/' \
  -e 's/     ssh vps "mkdir/     ssh tmuxkeep-admin "mkdir/' \
  -e 's/the Host vps block must read/the Host tmuxkeep-admin block must read/' \
  -e "s/'     Host vps'/'     Host tmuxkeep-admin'/" \
  -e 's/PasswordAuthentication=no vps true/PasswordAuthentication=no tmuxkeep-admin true/' \
  -e 's#"vps:/root/\$stage"#"tmuxkeep-admin:/root/$stage"#' \
  -e 's/PreferredAuthentications=publickey vps (/PreferredAuthentications=publickey tmuxkeep-admin (/' \
  -e 's/ssh to vps failed (exit 255)/ssh to tmuxkeep-admin failed (exit 255)/' \
  laptop/deploy.ps1
sed -i -e 's/ssh to vps failed (exit 255)/ssh to tmuxkeep-admin failed (exit 255)/' tests/pester/deploy.Tests.ps1 README.md
```

The rest of the README is rewritten in Task 19; leave its other `vps` mentions alone.

- [ ] **Step 5: Fix the completer tests' cursor columns (the command name grew by four characters)**

Run (Git Bash):

```bash
sed -i \
  -e "s/'tmuxkeep re' -cursorColumn 7/'tmuxkeep re' -cursorColumn 11/" \
  -e "s/'tmuxkeep go a' -cursorColumn 9/'tmuxkeep go a' -cursorColumn 13/" \
  -e "s/'tmuxkeep restore ' -cursorColumn 13/'tmuxkeep restore ' -cursorColumn 17/" \
  -e "s/'tmuxkeep new ' -cursorColumn 9/'tmuxkeep new ' -cursorColumn 13/" \
  -e "s/'tmuxkeep go a\[' -cursorColumn 10/'tmuxkeep go a[' -cursorColumn 14/" \
  tests/pester/completer.Tests.ps1
grep -n 'cursorColumn' tests/pester/completer.Tests.ps1
```

Expected: five lines, with columns 11, 13, 17, 13 and 14.

- [ ] **Step 6: Check the result**

Run (Git Bash):

```bash
git grep -n -i sesh -- . ':!docs/superpowers'
grep -n -w vps laptop/deploy.ps1
grep -c 'tmuxkeep-admin' laptop/deploy.ps1
git grep -n -E 'sudoers-claude|sudoers\.d/claude|\.claude\.new' -- . ':!docs/superpowers'
grep -rlIU "$(printf '\r')" vps tests
```

Expected:
- first command: no output;
- second: exactly two lines, the one holding `'vps-facts.sh'` in `New-TmuxkeepStaging`'s list and the one holding `('vps\' +`;
- third: a number of at least 9;
- fourth and fifth: no output.

- [ ] **Step 7: Run the whole bats directory**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1`
Expected: the image builds as `tmuxkeep-bats:latest`; the same number of `ok` lines as the baseline, no `not ok`, exit 0.

- [ ] **Step 8: Run the whole Pester folder**

Run the G6 command with `$c.Run.Path = 'tests\pester'`.
Expected: the baseline `Tests Passed` count, `Failed: 0`.

- [ ] **Step 9: Commit**

```bash
git add -A
git status --short
git commit -m "rename: sesh -> tmuxkeep across code, tests and README"
```

`git status --short` before the commit must show eight `R` lines (the moves, some as `RM`) and `M` lines only for files under `vps/`, `laptop/`, `tests/` and `README.md`.

---

### Task 2: Broker: config file, `--check-conf`, local and remote loading

Suggested model: sonnet.

**Files:**
- Create: `tests/fixtures/tmuxkeep.conf`
- Create: `tests/bats/broker-config.bats`
- Modify: `vps/tmuxkeep` (new config section, `main`)
- Modify: `tests/bats/helpers.bash` (`setup_local`, `setup_remote`, `teardown_remote`, two new helpers)
- Modify: `tests/bats/broker-remote.bats` (append four tests)
- Modify: `tests/bats/lint.bats` (append one test)

**Interfaces:**
- Consumes: the renamed broker and helpers from Task 1 (`TMUXKEEP_BIN`, `setup_local`, `setup_remote`, `tmuxkeep`, `tm`, `mk_session`, `mk_lease`, `session_names`, `audit_count`, `audit_last`, `audit_field`, `remote`, `rtm`, `b64cmd`, `FIXED_NOW`).
- Produces:
  - Broker functions: `trim_ws STRING` (sets `TRIMMED`), `printable_ascii STRING` (status), `valid_abs_path STRING` (status), `check_int KEY VALUE LO HI` (status; sets `CONF_ERR` on failure), `conf_defaults` (sets every `CF_*`), `parse_conf FILE` (sets every `CF_*` or `CONF_ERR="<FILE>: <reason>"`), `validate_conf` (status; `CONF_ERR="<reason>"`), `apply_conf` (copies `CF_*` into the runtime globals). Globals `CF_USER CF_USER_HOME CF_STATE_DIR CF_WORK_DIR CF_AUDIT_LOG CF_LAUNCH_CMD CF_RESUME_CMD CF_LEASE_SECS CF_TOMBSTONE_TTL CF_OTP_FAIL_MAX CF_OTP_FAIL_WINDOW CF_OTP_COOLDOWN CF_OTP_HARD_MAX CF_OTP_READ_TIMEOUT CF_SEND_MAX_BYTES`, `CONF_ERR`, `DEFAULT_CONF=/etc/tmuxkeep/tmuxkeep.conf`, `CONF_KEYS`.
  - Command line: `tmuxkeep --check-conf <file>` exits 0 silently, 1 with `tmuxkeep: config invalid: <file>: <reason>`, or 2 with `tmuxkeep: usage: tmuxkeep --check-conf <file>`. Never audits.
  - Test helpers: `conf_set_in FILE KEY VALUE`, `conf_set KEY VALUE` (edits `$TMUXKEEP_CONF`). `setup_local` exports `TMUXKEEP_CONF` (a copy of the fixture); `setup_remote` installs the fixture as `/etc/tmuxkeep/tmuxkeep.conf`; `teardown_remote` removes it.
  - Fixture `tests/fixtures/tmuxkeep.conf` (Task 6's installer must render exactly these bytes for `USER=claude`).

**Behaviour (spec 4.1, 4.4, 4.5; plan Q1, Q5):**
- The ten constants at the top of `vps/tmuxkeep` (`LEASE_SECS=1800` ... `SEND_MAX_BYTES=8000`, `GATED_VERBS=...`) stay exactly as they are: they are now the built-in defaults, and `tests/bats/lint.bats` still checks them. `OTP_STEP` and `SEND_ENTER_DELAY` stay constants (spec 4.4).
- Rules G30-G32 apply to the VPS key list: `USER USER_HOME STATE_DIR WORK_DIR AUDIT_LOG LAUNCH_CMD RESUME_CMD LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES`, every key required.
- The file is never `source`d.
- Loading, in `main`, right after `MODE` is known and before anything can call `fail`:
  - remote mode: always `/etc/tmuxkeep/tmuxkeep.conf`; every `TMUXKEEP_*` variable is ignored, including `TMUXKEEP_CONF`;
  - local mode: `TMUXKEEP_CONF` when it is set and non-empty; otherwise `/etc/tmuxkeep/tmuxkeep.conf` when that path exists (plan Q1: the hourly reaper runs in local mode and must see the configured `TOMBSTONE_TTL`); otherwise the built-in defaults;
  - a file that fails to parse ends the call: print `tmuxkeep: config invalid: <CONF_ERR>` on stderr and `exit 1`, with no audit line (the audit path comes from the file);
  - then `apply_conf`; then, in local mode only, `TMUXKEEP_HOME`, `TMUXKEEP_AUDIT`, `TMUXKEEP_WORK`, `TMUXKEEP_TMUX_SOCKET`, `TMUXKEEP_OATHTOOL` and `TMUXKEEP_NOW` override as before.
- `--check-conf` is handled first thing in `main`, before `--key`. A forced command always starts with `--key`, so it is unreachable over ssh.
- `LAUNCH_CMD` and `RESUME_CMD` are parsed and validated here but used only from Task 3. Do not create the globals `LAUNCH_CMD` or `RESUME_CMD` in this task: shellcheck would flag them as unused (SC2034 is a warning).
- Every `CF_*` must be assigned literally in `conf_defaults` and read directly (not through `${!name}`) somewhere, or shellcheck reports SC2034/SC2154.

Load-bearing code. Put this section in `vps/tmuxkeep` after the `# ---- defaults and patterns ----` block and before `# ---- string helpers ----`:

```bash
# ---- configuration (spec 4.1, 4.4, 4.5) ----
# The root-owned /etc/tmuxkeep/tmuxkeep.conf, read with the parser below, never sourced. In
# local mode TMUXKEEP_CONF selects another file, and with neither file the defaults apply.
DEFAULT_CONF=/etc/tmuxkeep/tmuxkeep.conf
CONF_KEYS='USER USER_HOME STATE_DIR WORK_DIR AUDIT_LOG LAUNCH_CMD RESUME_CMD LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES'

# trim_ws STRING: sets TRIMMED to STRING without leading and trailing spaces and tabs.
trim_ws() {
  local s=$1
  s=${s#"${s%%[![:blank:]]*}"}
  s=${s%"${s##*[![:blank:]]}"}
  TRIMMED=$s
}

# printable_ascii STRING: status 0 when every byte is 0x20-0x7E. The empty string passes.
printable_ascii() {
  local rest
  rest=$(printf '%s' "$1" | LC_ALL=C tr -d ' -~'; printf x)
  [[ $rest == x ]]
}

# valid_abs_path STRING: absolute, at most 255 bytes, letters digits . _ - and /, no . or .. part.
valid_abs_path() {
  (( ${#1} <= 255 )) && [[ $1 =~ ^(/[A-Za-z0-9._-]+)+$ && /$1/ != */./* && /$1/ != */../* ]]
}

# check_int KEY VALUE LO HI: 1-7 decimal digits within LO..HI, else CONF_ERR and status 1.
check_int() {
  if [[ $2 =~ ^[0-9]{1,7}$ ]] && (( 10#$2 >= $3 && 10#$2 <= $4 )); then return 0; fi
  CONF_ERR="$1: must be an integer from $3 to $4"
  return 1
}

# conf_defaults: the built-in values; equal to what tmuxkeep-setup writes for USER=claude.
conf_defaults() {
  CF_USER=claude
  CF_USER_HOME=/home/claude
  CF_STATE_DIR=$DEFAULT_STATE_DIR
  CF_WORK_DIR=$DEFAULT_WORK
  CF_AUDIT_LOG=$DEFAULT_AUDIT
  CF_LAUNCH_CMD=claude
  CF_RESUME_CMD='claude --continue'
  CF_LEASE_SECS=$LEASE_SECS
  CF_TOMBSTONE_TTL=$TOMBSTONE_TTL
  CF_OTP_FAIL_MAX=$OTP_FAIL_MAX
  CF_OTP_FAIL_WINDOW=$OTP_FAIL_WINDOW
  CF_OTP_COOLDOWN=$OTP_COOLDOWN
  CF_OTP_HARD_MAX=$OTP_HARD_MAX
  CF_OTP_READ_TIMEOUT=$OTP_READ_TIMEOUT
  CF_SEND_MAX_BYTES=$SEND_MAX_BYTES
}
```

Then write `validate_conf`, `parse_conf` and `apply_conf` to these contracts:
- `validate_conf` checks, in this order, with the G32 messages and nothing else: `CF_USER` against `^[a-z_][a-z0-9_-]{0,31}$`; `CF_USER_HOME`, `CF_STATE_DIR`, `CF_WORK_DIR`, `CF_AUDIT_LOG` with `valid_abs_path`; the length of `CF_LAUNCH_CMD` and `CF_RESUME_CMD` (`${#v} <= 200`); then `check_int` for `LEASE_SECS 60 86400`, `TOMBSTONE_TTL 3600 2592000`, `OTP_FAIL_MAX 1 20`, `OTP_FAIL_WINDOW 60 86400`, `OTP_COOLDOWN 10 86400`, `OTP_HARD_MAX $(( 10#$CF_OTP_FAIL_MAX )) 100`, `OTP_READ_TIMEOUT 10 600`, `SEND_MAX_BYTES 1 65536`. Name each `CF_*` explicitly in the code.
- `parse_conf FILE` calls `conf_defaults` first, then: unreadable or not a regular file gives `cannot read`; a first line starting with the bytes `EF BB BF` (test with `head -c 3 "$file" | LC_ALL=C grep -q $'^\xef\xbb\xbf'`) gives the BOM message; any CR (`LC_ALL=C grep -q $'\r' "$file"`) gives the CR message; then it reads the file with `while IFS= read -r line || [[ -n $line ]]; do ... done < "$file"`, counting lines, and applies G30 steps 2-6, assigning with `printf -v "CF_$key" '%s' "$val"` and recording seen keys; then G30 step 7 (`<KEY>: required` in `CONF_KEYS` order), then `validate_conf`. Every failure sets `CONF_ERR="$file: <reason>"` and returns 1. The key test is `[[ $key =~ ^[A-Z_]+$ && " $CONF_KEYS " == *" $key "* ]]`; the anchored regex is what stops a key such as `USER USER_HOME` from matching the space-separated list.
- `apply_conf` sets `STATE_DIR=$CF_STATE_DIR`, `AUDIT_FILE=$CF_AUDIT_LOG`, `WORK_DIR=$CF_WORK_DIR`, and each of the eight tunables from its `CF_*` with `10#` (for example `LEASE_SECS=$(( 10#$CF_LEASE_SECS ))`).

`main` changes. Insert as the first block after `export LC_ALL=C.UTF-8`:

```bash
  # tmuxkeep --check-conf FILE: local only (a forced command always starts with --key), never
  # audited. tmuxkeep-setup runs it before installing a new /etc/tmuxkeep/tmuxkeep.conf.
  if [[ ${1:-} == --check-conf ]]; then
    if (( $# != 2 )); then
      printf 'tmuxkeep: usage: tmuxkeep --check-conf <file>\n' >&2
      exit 2
    fi
    if parse_conf "$2"; then exit 0; fi
    printf 'tmuxkeep: config invalid: %s\n' "$CONF_ERR" >&2
    exit 1
  fi
```

Replace the three lines `STATE_DIR=$DEFAULT_STATE_DIR`, `AUDIT_FILE=$DEFAULT_AUDIT`, `WORK_DIR=$DEFAULT_WORK` with:

```bash
  # Configuration (spec 4.4, 4.5, plan Q1). Remote: always the root-owned file. Local: TMUXKEEP_CONF,
  # else the system file when it exists, else the built-in defaults. A bad file ends the call
  # before anything is audited, because the audit path comes from it.
  local conf=$DEFAULT_CONF
  if [[ $MODE == local ]]; then
    if [[ -n ${TMUXKEEP_CONF:-} ]]; then
      conf=$TMUXKEEP_CONF
    elif [[ ! -e $DEFAULT_CONF && ! -L $DEFAULT_CONF ]]; then
      conf=
    fi
  fi
  if [[ -n $conf ]]; then
    if ! parse_conf "$conf"; then
      printf 'tmuxkeep: config invalid: %s\n' "$CONF_ERR" >&2
      exit 1
    fi
  else
    conf_defaults
  fi
  apply_conf
```

The local-mode `TMUXKEEP_*` override block that follows stays as it is.

- [ ] **Step 1: Create the fixture `tests/fixtures/tmuxkeep.conf` with exactly this content (17 lines, LF, final newline)**

```
# Written by tmuxkeep-setup on every deploy; edits here are overwritten.
# Change ~/.tmuxkeep/config on the laptop and deploy again instead.
USER=claude
USER_HOME=/home/claude
STATE_DIR=/home/claude/.tmuxkeep
WORK_DIR=/home/claude/work
AUDIT_LOG=/var/log/tmuxkeep/audit.log
LAUNCH_CMD=claude
RESUME_CMD=claude --continue
LEASE_SECS=1800
TOMBSTONE_TTL=86400
OTP_FAIL_MAX=3
OTP_FAIL_WINDOW=600
OTP_COOLDOWN=300
OTP_HARD_MAX=10
OTP_READ_TIMEOUT=60
SEND_MAX_BYTES=8000
```

- [ ] **Step 2: Update `tests/bats/helpers.bash`**

In `setup_local`, directly after the line `export TMUXKEEP_OATHTOOL="$BATS_TEST_TMPDIR/oathtool"`, add:

```bash
  cp /src/tests/fixtures/tmuxkeep.conf "$BATS_TEST_TMPDIR/tmuxkeep.conf"
  export TMUXKEEP_CONF="$BATS_TEST_TMPDIR/tmuxkeep.conf"
```

In `setup_remote`, replace the line `unset TMUXKEEP_HOME TMUXKEEP_AUDIT TMUXKEEP_WORK TMUXKEEP_TMUX_SOCKET TMUXKEEP_NOW TMUXKEEP_OATHTOOL` with:

```bash
  unset TMUXKEEP_CONF TMUXKEEP_HOME TMUXKEEP_AUDIT TMUXKEEP_WORK TMUXKEEP_TMUX_SOCKET TMUXKEEP_NOW TMUXKEEP_OATHTOOL
  install -m 0644 /src/tests/fixtures/tmuxkeep.conf /etc/tmuxkeep/tmuxkeep.conf
```

In `teardown_remote`, add `rm -f /etc/tmuxkeep/tmuxkeep.conf` before `return 0`.

Append at the end of the file:

```bash

# ---- config files ----
# conf_set_in FILE KEY VALUE: replace FILE's KEY= line. ENVIRON, not -v, so backslashes survive.
conf_set_in() {
  TK_K=$2 TK_V=$3 awk 'BEGIN { k = ENVIRON["TK_K"]; v = ENVIRON["TK_V"] }
    index($0, k "=") == 1 { print k "=" v; next } { print }' "$1" > "$1.new" &&
    cat "$1.new" > "$1" && rm -f "$1.new"
}
conf_set() { conf_set_in "$TMUXKEEP_CONF" "$1" "$2"; }
```

Also change the second comment line of the file to: `# container paths /home/claude, /var/log/tmuxkeep, /etc/tmuxkeep and /etc/ssh.`

- [ ] **Step 3: Write the failing test `tests/bats/broker-config.bats`**

```bash
#!/usr/bin/env bats
# Broker configuration (spec 4.1, 4.4, 4.5, plan Q1, Q5): --check-conf, the parser rules,
# local-mode loading and the values taking effect. Remote-mode cases are in broker-remote.bats.
load helpers

FIX=/src/tests/fixtures/tmuxkeep.conf

setup() {
  setup_local
  C="$BATS_TEST_TMPDIR/c"
}
teardown() {
  teardown_local
  rm -f /etc/tmuxkeep/tmuxkeep.conf
}

check() { bash "$TMUXKEEP_BIN" --check-conf "$@" </dev/null; }
fresh() { cp "$FIX" "$C"; }

# rejects FILE SUFFIX: --check-conf exits 1 and stderr is "tmuxkeep: config invalid: FILE: ...SUFFIX".
rejects() {
  run --separate-stderr check "$1"
  [ "$status" -eq 1 ] || { echo "status $status, wanted 1, for: $2"; return 1; }
  [[ "$stderr" == "tmuxkeep: config invalid: $1: "*"$2" ]] || { echo "stderr: $stderr"; echo "wanted suffix: $2"; return 1; }
}

# accepts FILE: --check-conf exits 0 and prints nothing.
accepts() {
  run --separate-stderr check "$1"
  [ "$status" -eq 0 ] || { echo "rejected: $stderr"; return 1; }
  [ -z "$output" ] && [ -z "$stderr" ]
}

@test "the fixture passes --check-conf silently" {
  accepts "$FIX"
}

@test "--check-conf needs exactly one argument (2)" {
  run check
  [ "$status" -eq 2 ]
  run check "$FIX" extra
  [ "$status" -eq 2 ]
}

@test "a missing file is 1 with 'cannot read'" {
  run --separate-stderr check "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 1 ]
  [ "$stderr" = "tmuxkeep: config invalid: $BATS_TEST_TMPDIR/none: cannot read" ]
}

@test "blank lines, comments, padding and a repeated key (the last wins) are accepted" {
  { printf '\n# a comment\n \t \n'
    sed 's/^\([A-Z_]*\)=\(.*\)$/  \1 =\t\2 \t/' "$FIX"
    printf 'SEND_MAX_BYTES=1\nSEND_MAX_BYTES=5\n'
  } > "$C"
  accepts "$C"
  export TMUXKEEP_CONF=$C
  mk_session api
  mk_lease t -
  run --separate-stderr tmuxkeep send api 123456
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep: text longer than 5 bytes" ]
}

@test "a BOM, a CR, a line without =, an unknown key and a non-printable value are rejected (1)" {
  local n=$(( $(wc -l < "$FIX") + 1 ))
  { printf '\xef\xbb\xbf'; cat "$FIX"; } > "$C"
  rejects "$C" 'byte order mark found (save without BOM)'
  sed 's/$/\r/' "$FIX" > "$C"
  rejects "$C" 'carriage return found (use LF line endings)'
  { cat "$FIX"; printf 'just words\n'; } > "$C"
  rejects "$C" "line $n: expected KEY=value"
  { cat "$FIX"; printf 'FROB=1\n'; } > "$C"
  rejects "$C" "line $n: unknown key FROB"
  { cat "$FIX"; printf 'user=claude\n'; } > "$C"
  rejects "$C" "line $n: unknown key user"
  { cat "$FIX"; printf 'B@D=1\n'; } > "$C"
  rejects "$C" "line $n: unknown key"
  fresh; conf_set_in "$C" LAUNCH_CMD "$(printf 'caf\xc3\xa9')"
  rejects "$C" 'non-printable or non-ASCII character in LAUNCH_CMD'
  fresh; conf_set_in "$C" LAUNCH_CMD "$(printf 'a\tb')"
  rejects "$C" 'non-printable or non-ASCII character in LAUNCH_CMD'
}

@test "every key is required" {
  local k
  for k in USER USER_HOME STATE_DIR WORK_DIR AUDIT_LOG LAUNCH_CMD RESUME_CMD LEASE_SECS TOMBSTONE_TTL \
           OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES; do
    grep -v "^$k=" "$FIX" > "$C"
    rejects "$C" "$k: required" || return 1
  done
}

@test "each tunable is accepted at its bounds and rejected just outside them" {
  local row k lo hi
  for row in LEASE_SECS:60:86400 TOMBSTONE_TTL:3600:2592000 OTP_FAIL_WINDOW:60:86400 OTP_COOLDOWN:10:86400 \
             OTP_READ_TIMEOUT:10:600 SEND_MAX_BYTES:1:65536 OTP_HARD_MAX:3:100; do
    IFS=: read -r k lo hi <<< "$row"
    fresh; conf_set_in "$C" "$k" "$lo"; accepts "$C" || { echo "$k=$lo"; return 1; }
    fresh; conf_set_in "$C" "$k" "$hi"; accepts "$C" || { echo "$k=$hi"; return 1; }
    fresh; conf_set_in "$C" "$k" "$(( lo - 1 ))"; rejects "$C" "$k: must be an integer from $lo to $hi" || return 1
    fresh; conf_set_in "$C" "$k" "$(( hi + 1 ))"; rejects "$C" "$k: must be an integer from $lo to $hi" || return 1
  done
}

@test "OTP_FAIL_MAX is 1-20 and OTP_HARD_MAX may not be below it" {
  fresh
  conf_set_in "$C" OTP_HARD_MAX 100
  conf_set_in "$C" OTP_FAIL_MAX 1; accepts "$C"
  conf_set_in "$C" OTP_FAIL_MAX 20; accepts "$C"
  conf_set_in "$C" OTP_FAIL_MAX 0; rejects "$C" 'OTP_FAIL_MAX: must be an integer from 1 to 20'
  conf_set_in "$C" OTP_FAIL_MAX 21; rejects "$C" 'OTP_FAIL_MAX: must be an integer from 1 to 20'
  conf_set_in "$C" OTP_FAIL_MAX 12
  conf_set_in "$C" OTP_HARD_MAX 11
  rejects "$C" 'OTP_HARD_MAX: must be an integer from 12 to 100'
}

@test "integers are 1-7 decimal digits; signs, inner spaces and other text are rejected" {
  local v
  fresh; conf_set_in "$C" LEASE_SECS 0060; accepts "$C"
  fresh; conf_set_in "$C" LEASE_SECS 0000099; accepts "$C"
  for v in '' abc -60 +60 '6 0' 1e3 12345678 0x40; do
    fresh; conf_set_in "$C" LEASE_SECS "$v"
    rejects "$C" 'LEASE_SECS: must be an integer from 60 to 86400' || { echo "value '$v'"; return 1; }
  done
}

@test "USER, the four paths and the two commands are validated" {
  local v k
  for v in claude _svc a-b x "$(printf 'a%.0s' $(seq 1 32))"; do
    fresh; conf_set_in "$C" USER "$v"; accepts "$C" || { echo "USER=$v"; return 1; }
  done
  for v in '' Bob 1abc -x 'a b' "$(printf 'a%.0s' $(seq 1 33))"; do
    fresh; conf_set_in "$C" USER "$v"
    rejects "$C" 'USER: must match ^[a-z_][a-z0-9_-]{0,31}$' || { echo "USER=$v"; return 1; }
  done
  for k in USER_HOME STATE_DIR WORK_DIR AUDIT_LOG; do
    for v in '' home/claude / /home/../etc /home/./x '/home/cl aude' /home/x//y "/$(printf 'a%.0s' $(seq 1 255))"; do
      fresh; conf_set_in "$C" "$k" "$v"
      rejects "$C" "$k: must be an absolute path made of letters, digits, dot, underscore, hyphen and slash" || { echo "$k=$v"; return 1; }
    done
    fresh; conf_set_in "$C" "$k" /srv/tk-1/x_y.z; accepts "$C" || { echo "$k"; return 1; }
  done
  for k in LAUNCH_CMD RESUME_CMD; do
    fresh; conf_set_in "$C" "$k" ''; accepts "$C" || return 1
    fresh; conf_set_in "$C" "$k" "$(printf 'x%.0s' $(seq 1 200))"; accepts "$C" || return 1
    fresh; conf_set_in "$C" "$k" "$(printf 'x%.0s' $(seq 1 201))"
    rejects "$C" "$k: at most 200 characters" || return 1
  done
}

@test "SEND_MAX_BYTES, LEASE_SECS and TOMBSTONE_TTL from TMUXKEEP_CONF take effect" {
  conf_set SEND_MAX_BYTES 5
  conf_set LEASE_SECS 60
  conf_set TOMBSTONE_TTL 3600
  mk_session api
  mk_lease t - $(( FIXED_NOW - 59 ))
  run tmuxkeep send api 12345
  [ "$status" -eq 0 ]
  run --separate-stderr tmuxkeep send api 123456
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep: text longer than 5 bytes" ]
  mk_lease t - $(( FIXED_NOW - 61 ))
  run tmuxkeep send api 12345
  [ "$status" -eq 4 ]
  mk_session "zz~old~$(( FIXED_NOW - 3601 ))"
  mk_session "zz~new~$(( FIXED_NOW - 3599 ))"
  run tmuxkeep reap
  [ "$status" -eq 0 ]
  run session_names
  [[ "$output" == *"zz~new~$(( FIXED_NOW - 3599 ))"* ]]
  [[ "$output" != *zz~old~* ]]
}

@test "AUDIT_LOG, STATE_DIR and WORK_DIR come from the config when no TMUXKEEP_* override is set" {
  local d="$BATS_TEST_TMPDIR/cfgpaths"
  mkdir -p "$d/state/leases" "$d/work"
  cp "$TMUXKEEP_HOME/totp.secret" "$TMUXKEEP_HOME/last-otp" "$d/state/"
  printf '%s\n' "$FIXED_NOW" > "$d/state/leases/t@-"
  conf_set AUDIT_LOG "$d/audit.log"
  conf_set STATE_DIR "$d/state"
  conf_set WORK_DIR "$d/work"
  unset TMUXKEEP_AUDIT TMUXKEEP_HOME TMUXKEEP_WORK
  run tmuxkeep new api
  [ "$status" -eq 0 ]
  [ "$output" = "created api in $d/work/api" ]
  [ "$(wc -l < "$d/audit.log")" -eq 1 ]
}

@test "local mode without TMUXKEEP_CONF reads /etc/tmuxkeep/tmuxkeep.conf when it exists (plan Q1)" {
  cp "$FIX" /etc/tmuxkeep/tmuxkeep.conf
  conf_set_in /etc/tmuxkeep/tmuxkeep.conf AUDIT_LOG "$BATS_TEST_TMPDIR/sys.log"
  unset TMUXKEEP_CONF TMUXKEEP_AUDIT
  run tmuxkeep log
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/sys.log")" -eq 1 ]
}

@test "local mode with no config file at all uses the built-in defaults" {
  rm -f /etc/tmuxkeep/tmuxkeep.conf
  unset TMUXKEEP_CONF TMUXKEEP_AUDIT
  mkdir -p /var/log/tmuxkeep
  : > /var/log/tmuxkeep/audit.log
  run tmuxkeep log
  [ "$status" -eq 0 ]
  [ "$(wc -l < /var/log/tmuxkeep/audit.log)" -eq 1 ]
  : > /var/log/tmuxkeep/audit.log
}

@test "local mode: an invalid TMUXKEEP_CONF or system file is 1 and writes no audit line" {
  printf 'FROB=1\n' > "$TMUXKEEP_CONF"
  run --separate-stderr tmuxkeep log
  [ "$status" -eq 1 ]
  [ "$stderr" = "tmuxkeep: config invalid: $TMUXKEEP_CONF: line 1: unknown key FROB" ]
  [ "$(audit_count)" -eq 0 ]
  printf 'FROB=1\n' > /etc/tmuxkeep/tmuxkeep.conf
  unset TMUXKEEP_CONF
  run --separate-stderr tmuxkeep log
  [ "$status" -eq 1 ]
  [ "$stderr" = "tmuxkeep: config invalid: /etc/tmuxkeep/tmuxkeep.conf: line 1: unknown key FROB" ]
  [ "$(audit_count)" -eq 0 ]
}

@test "an empty TMUXKEEP_CONF counts as unset" {
  rm -f /etc/tmuxkeep/tmuxkeep.conf
  export TMUXKEEP_CONF=
  run tmuxkeep log
  [ "$status" -eq 0 ]
  [ "$(audit_count)" -eq 1 ]
}

@test "--check-conf never writes an audit line" {
  run check "$FIX"
  printf 'FROB=1\n' > "$C"
  run check "$C"
  [ "$(audit_count)" -eq 0 ]
}
```

- [ ] **Step 4: Append to `tests/bats/broker-remote.bats`**

```bash

# ---- configuration (spec 4.4, 4.5) ----
@test "remote: a missing /etc/tmuxkeep/tmuxkeep.conf is 1 with config invalid, and nothing is audited" {
  rm -f /etc/tmuxkeep/tmuxkeep.conf
  run --separate-stderr remote 203.0.113.9 laptop 'log -n 1'
  [ "$status" -eq 1 ]
  [ "$stderr" = "tmuxkeep: config invalid: /etc/tmuxkeep/tmuxkeep.conf: cannot read" ]
  [ ! -s /var/log/tmuxkeep/audit.log ]
}

@test "remote: an invalid config is 1 and nothing is audited" {
  printf 'LEASE_SECS=5\n' >> /etc/tmuxkeep/tmuxkeep.conf
  run --separate-stderr remote 203.0.113.9 laptop 'log -n 1'
  [ "$status" -eq 1 ]
  [ "$stderr" = "tmuxkeep: config invalid: /etc/tmuxkeep/tmuxkeep.conf: LEASE_SECS: must be an integer from 60 to 86400" ]
  [ ! -s /var/log/tmuxkeep/audit.log ]
}

@test "remote: TMUXKEEP_CONF is ignored" {
  local f="$BATS_TEST_TMPDIR/other.conf"
  cp /etc/tmuxkeep/tmuxkeep.conf "$f"
  conf_set_in "$f" AUDIT_LOG "$BATS_TEST_TMPDIR/other.log"
  export TMUXKEEP_CONF=$f
  run remote 203.0.113.9 laptop 'log -n 1'
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/other.log" ]
  [ "$(wc -l < /var/log/tmuxkeep/audit.log)" -eq 1 ]
}

@test "remote: SEND_MAX_BYTES from /etc/tmuxkeep/tmuxkeep.conf applies" {
  conf_set_in /etc/tmuxkeep/tmuxkeep.conf SEND_MAX_BYTES 3
  rtm new-session -d -s api
  run --separate-stderr remote 203.0.113.9 laptop "$(b64cmd send api abcd)"
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep: text longer than 3 bytes" ]
}
```

- [ ] **Step 5: Append to `tests/bats/lint.bats`**

```bash

@test "the broker never sources a file" {
  run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "$TMUXKEEP_BIN"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 6: Run the new tests to see them fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-config.bats`
Expected: `not ok` lines (for example "the fixture passes --check-conf silently" fails with status 2, an unknown verb).

- [ ] **Step 7: Implement the behaviour above in `vps/tmuxkeep`**

- [ ] **Step 8: Run until green**

Run, in order:
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-config.bats`: 17 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-remote.bats`: 14 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/lint.bats`: 7 tests, all `ok`.
- the whole directory (no `-Path`) and the whole Pester folder (G6): all green (G8).

- [ ] **Step 9: Line endings, commit**

```bash
grep -rlIU "$(printf '\r')" vps tests     # Git Bash; must print nothing
git add vps/tmuxkeep tests/fixtures/tmuxkeep.conf tests/bats/helpers.bash tests/bats/broker-config.bats tests/bats/broker-remote.bats tests/bats/lint.bats
git commit -m "broker: strict root-owned config file, --check-conf, local and remote loading"
```

---

### Task 3: Broker: `LAUNCH_CMD`, `RESUME_CMD`, `--cmd`

Suggested model: sonnet.

**Files:**
- Modify: `vps/tmuxkeep` (header comment, `apply_conf`, `audit`, `main` initialisation, `verb_new`, `verb_resume`; replace `type_continue` with `type_line`)
- Create: `tests/bats/broker-cmd.bats`

**Interfaces:**
- Consumes (Task 2): `CF_LAUNCH_CMD`, `CF_RESUME_CMD`, `apply_conf`, `printable_ascii STRING`, `conf_set KEY VALUE` (test helper). From v1: `tmux_on`, `tmx`, `fail`, `succeed`, `authorize`, `require_name`, `SEND_ENTER_DELAY`, helpers `wait_for_pane_line`, `wait_for_pane_contains`, `wait_for_cmd`, `_pane_contains`, `_poll`, `mk_session`, `mk_lease`, `session_names`, `audit_last`, `audit_field`.
- Produces:
  - Globals `LAUNCH_CMD` and `RESUME_CMD` (set by `apply_conf`), `AUDIT_CMD` and `AUDIT_HAS_CMD` (set to empty and 0 in `main`).
  - `type_line NAME TEXT`: types TEXT into NAME's pane, waits `SEND_ENTER_DELAY`, presses Enter; types nothing when TEXT is empty or only spaces (plan Q2).
  - `valid_cmd TEXT`: status 0 when TEXT is at most 200 characters, all printable ASCII.
  - Verbs: `new <name> [--repo <https-url>] [--cmd <text>]` and `resume <name> [--cmd <text>]`, options in any order.
  - Audit: when `--cmd` was given and valid, the line gains a last key `"cmd":"<text>"`. Without `--cmd` the key set is exactly v1's.

**Behaviour (spec 7.1, 8; plan Q2):**
- Header comment, lines 2-3 of `vps/tmuxkeep`, becomes:

  ```bash
  # tmuxkeep: tmux session broker, the forced command for the session key of the configured user.
  # New sessions run LAUNCH_CMD and resume runs RESUME_CMD; the defaults start Claude Code.
  # Spec: docs/superpowers/specs/2026-10-12-tmuxkeep-public-release-design.md (builds on the v1 spec)
  ```

- `apply_conf` also sets `LAUNCH_CMD=$CF_LAUNCH_CMD` and `RESUME_CMD=$CF_RESUME_CMD`.
- In `main`, next to `VERB=`, `SESSION=`, `AUDIT_ENABLED=1`, add `AUDIT_CMD=` and `AUDIT_HAS_CMD=0`.
- `audit` uses a second jq filter when `AUDIT_HAS_CMD` is 1:

  ```bash
  audit() { # audit true|false DETAIL
    (( AUDIT_ENABLED )) || return 0
    local ts filter='{ts:$ts,key:$key,ip:$ip,verb:$verb,session:$session,ok:$ok,detail:$detail}'
    if (( AUDIT_HAS_CMD )); then
      filter='{ts:$ts,key:$key,ip:$ip,verb:$verb,session:$session,ok:$ok,detail:$detail,cmd:$cmd}'
    fi
    ts=$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)
    jq -acn --arg ts "$ts" --arg key "${KEY_ID:0:32}" --arg ip "$CLIENT_IP" \
           --arg verb "${VERB:0:32}" --arg session "${SESSION:0:64}" \
           --argjson ok "$1" --arg detail "$2" --arg cmd "${AUDIT_CMD:-}" \
       "$filter" 2>/dev/null >> "$AUDIT_FILE" || printf 'tmuxkeep: audit write failed\n' >&2
  }
  ```

- Replace `type_continue` with:

  ```bash
  # type_line NAME TEXT: types TEXT literally into NAME's active pane, waits SEND_ENTER_DELAY so the
  # program's paste detection cannot swallow the Enter, then presses Enter. TEXT that is empty or
  # only spaces types nothing at all (plan Q2). A trailing ";" gets the same escape as in send.
  # Call it in the main shell, never inside $(...), so that fail can exit.
  type_line() {
    local keys=$2 err
    [[ $keys == *[!\ ]* ]] || return 0
    if [[ $keys == *';' ]]; then keys="${keys%;}\\;"; fi
    err=$(tmux_on "$1" send-keys -l -- "$keys" 2>&1) || fail 1 "tmux: ${err%%$'\n'*}"
    sleep "$SEND_ENTER_DELAY"
    err=$(tmux_on "$1" send-keys Enter 2>&1) || fail 1 "tmux: ${err%%$'\n'*}"
  }

  # valid_cmd TEXT: at most 200 characters, every one printable ASCII (spec 7.1).
  valid_cmd() { (( ${#1} <= 200 )) && printable_ascii "$1"; }
  ```

- `verb_new`: usage string `usage: tmuxkeep new <name> [--repo <https-url>] [--cmd <text>]`. The option loop gains

  ```bash
      --cmd)
        (( have_cmd == 0 && $# >= 2 )) || fail 2 "$usage"
        cmd=$2
        have_cmd=1
        shift 2 ;;
  ```

  with `local cmd=$LAUNCH_CMD have_cmd=0`. After `require_name` and the `--repo` check, and before `authorize`:

  ```bash
    if (( have_cmd )); then
      valid_cmd "$cmd" || fail 2 "--cmd must be at most 200 printable ASCII characters"
      AUDIT_CMD=$cmd
      AUDIT_HAS_CMD=1
    fi
  ```

  The three lines after `tmx new-session` that typed `claude` and Enter become `type_line "$SESSION" "$cmd"`. Nothing else in `verb_new` changes; the text is never put in a message.
- `verb_resume`: usage `usage: tmuxkeep resume <name> [--cmd <text>]`. Parse like `verb_new`: `--cmd` (once, needs a value), any other word starting with `--` is usage (2), exactly one positional name. `local cmd=$RESUME_CMD have_cmd=0`. Same `valid_cmd` block before `authorize`. Both `type_continue "$SESSION"` calls become `type_line "$SESSION" "$cmd"`. Output and audit details (`resumed`, `recreated`) are unchanged.
- `ls` and `reap` are untouched (spec 7.1: tmux errors still read as "no sessions").

- [ ] **Step 1: Write the failing test `tests/bats/broker-cmd.bats`**

```bash
#!/usr/bin/env bats
# Session commands (spec 7.1, plan Q2): LAUNCH_CMD for new, RESUME_CMD for resume, the one-shot
# --cmd override, its validation and its audit field. A valid lease exists unless a test removes it.
load helpers
setup() { setup_local; mk_lease t -; }
teardown() { teardown_local; }

# pane_lines NAME: how many non-blank lines NAME's pane shows.
pane_lines() { tm capture-pane -p -J -S - -t "=$1:" | grep -c '[^[:space:]]'; }
# settled NAME: wait for the shell prompt, then give anything typed one second to appear.
settled() {
  _poll 5 bash -c "tmux -S '$TMUXKEEP_TMUX_SOCKET' capture-pane -p -t '=$1:' | grep -q '[^[:space:]]'"
  sleep 1
}

# ---- new ----
@test "new types LAUNCH_CMD from the config, then Enter, and audits no cmd key" {
  conf_set LAUNCH_CMD 'echo launched-ok'
  run tmuxkeep new api
  [ "$status" -eq 0 ]
  wait_for_pane_line api launched-ok
  run jq -e 'has("cmd") | not' <<<"$(audit_last)"
  [ "$status" -eq 0 ]
}

@test "an empty LAUNCH_CMD types nothing: the pane shows only the prompt" {
  conf_set LAUNCH_CMD ''
  run tmuxkeep new api
  [ "$status" -eq 0 ]
  settled api
  [ "$(pane_lines api)" -eq 1 ]
}

@test "--cmd overrides LAUNCH_CMD for that session and is audited" {
  conf_set LAUNCH_CMD 'echo from-config'
  run tmuxkeep new api --cmd 'echo override-ok'
  [ "$status" -eq 0 ]
  wait_for_pane_line api override-ok
  run ! _pane_contains api from-config
  [ "$(audit_field cmd)" = 'echo override-ok' ]
  [ "$(audit_field detail)" = "created dir=$TMUXKEEP_WORK/api" ]
}

@test "an empty --cmd opens a shell only and is audited as an empty cmd" {
  run tmuxkeep new api --cmd ''
  [ "$status" -eq 0 ]
  settled api
  [ "$(pane_lines api)" -eq 1 ]
  run jq -e '.cmd == ""' <<<"$(audit_last)"
  [ "$status" -eq 0 ]
}

@test "a --cmd made only of spaces types nothing (plan Q2)" {
  run tmuxkeep new api --cmd '   '
  [ "$status" -eq 0 ]
  settled api
  [ "$(pane_lines api)" -eq 1 ]
  [ "$(audit_field cmd)" = '   ' ]
}

@test "--cmd may come before the name and together with --repo" {
  mkdir -p "$TMUXKEEP_WORK/api"
  run tmuxkeep new --cmd 'echo order-ok' api --repo https://127.0.0.1:9/x.git
  [ "$status" -eq 0 ]
  wait_for_pane_line api order-ok
}

@test "a --cmd ending in ; is typed literally" {
  run tmuxkeep new api --cmd 'echo semi-ok;'
  [ "$status" -eq 0 ]
  wait_for_pane_contains api 'echo semi-ok;'
  wait_for_pane_line api semi-ok
}

@test "--cmd over 200 characters, with a control character or non-ASCII is usage (2), creates nothing, audits no cmd" {
  local v
  for v in "$(printf 'x%.0s' $(seq 1 201))" "$(printf 'a\tb')" "$(printf 'a\033b')" "$(printf 'caf\xc3\xa9')"; do
    run --separate-stderr tmuxkeep new api --cmd "$v"
    [ "$status" -eq 2 ] || { echo "status $status"; return 1; }
    [ "$stderr" = 'tmuxkeep: --cmd must be at most 200 printable ASCII characters' ] || { echo "$stderr"; return 1; }
    [ "$(audit_field ok)" = false ] || return 1
    run jq -e 'has("cmd") | not' <<<"$(audit_last)"
    [ "$status" -eq 0 ] || return 1
  done
  [ -z "$(session_names)" ]
  run tmuxkeep new api --cmd "$(printf 'x%.0s' $(seq 1 200))"
  [ "$status" -eq 0 ]
}

@test "--cmd without a value, or given twice, is usage (2)" {
  run tmuxkeep new api --cmd
  [ "$status" -eq 2 ]
  run tmuxkeep new api --cmd a --cmd b
  [ "$status" -eq 2 ]
  [ -z "$(session_names)" ]
}

@test "without a lease or a TTY, new --cmd is 4 and the audit line carries the cmd" {
  rm -f "$TMUXKEEP_HOME"/leases/*
  run tmuxkeep new api --cmd 'echo x'
  [ "$status" -eq 4 ]
  [ "$(audit_field cmd)" = 'echo x' ]
  [ -z "$(session_names)" ]
}

# ---- resume ----
@test "resume types RESUME_CMD from the config into an idle shell" {
  conf_set RESUME_CMD 'echo resumed-ok'
  mk_session api
  wait_for_cmd api bash
  run tmuxkeep resume api
  [ "$status" -eq 0 ]
  [ "$output" = 'resumed api' ]
  wait_for_pane_line api resumed-ok
}

@test "resume recreates a missing session and types RESUME_CMD" {
  conf_set RESUME_CMD 'echo recreated-ok'
  mkdir -p "$TMUXKEEP_WORK/api"
  run tmuxkeep resume api
  [ "$status" -eq 0 ]
  [ "$output" = 'recreated api' ]
  wait_for_pane_line api recreated-ok
}

@test "resume --cmd overrides RESUME_CMD and is audited" {
  mk_session api
  wait_for_cmd api bash
  run tmuxkeep resume --cmd 'echo resume-override' api
  [ "$status" -eq 0 ]
  wait_for_pane_line api resume-override
  [ "$(audit_field cmd)" = 'echo resume-override' ]
  [ "$(audit_field detail)" = resumed ]
}

@test "an empty RESUME_CMD types nothing and still reports resumed" {
  conf_set RESUME_CMD ''
  mk_session api
  wait_for_cmd api bash
  settled api
  run tmuxkeep resume api
  [ "$status" -eq 0 ]
  [ "$output" = 'resumed api' ]
  sleep 1
  [ "$(pane_lines api)" -eq 1 ]
}

@test "resume usage: no name, two names, --cmd without a value, an invalid --cmd, an unknown option (2)" {
  run tmuxkeep resume
  [ "$status" -eq 2 ]
  run tmuxkeep resume api web
  [ "$status" -eq 2 ]
  run tmuxkeep resume api --cmd
  [ "$status" -eq 2 ]
  run tmuxkeep resume api --cmd "$(printf 'a\tb')"
  [ "$status" -eq 2 ]
  run tmuxkeep resume api --frob
  [ "$status" -eq 2 ]
}

@test "type_line is the only typing helper; type_continue and the literal claude are gone" {
  run grep -c 'type_continue' "$TMUXKEEP_BIN"
  [ "$output" = 0 ]
  run grep -c '^type_line() {' "$TMUXKEEP_BIN"
  [ "$output" = 1 ]
  run grep -cE "send-keys -l -- (claude|'claude --continue')" "$TMUXKEEP_BIN"
  [ "$output" = 0 ]
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-cmd.bats`
Expected: `not ok` lines (the broker still types `claude` and rejects `--cmd` as a second name).

- [ ] **Step 3: Implement the behaviour above**

- [ ] **Step 4: Run until green**

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-cmd.bats`: 16 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-new-send-go.bats` and `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-resume-reap.bats`: all `ok` (the v1 tests still see `claude` and `claude --continue`, the fixture defaults).
- the whole bats directory and the whole Pester folder (G8).

- [ ] **Step 5: Line endings, commit**

```bash
grep -rlIU "$(printf '\r')" vps tests     # Git Bash; must print nothing
git add vps/tmuxkeep tests/bats/broker-cmd.bats
git commit -m "broker: LAUNCH_CMD and RESUME_CMD from the config, audited one-shot --cmd"
```

---

### Task 4: Facts script: `--user`

Suggested model: sonnet (the line-2 guard is subtle).

**Files:**
- Modify: `vps/vps-facts.sh`
- Modify: `tests/bats/facts.bats`

**Interfaces:**
- Consumes: Task 1's renamed facts script and `tests/bats/facts.bats` (helpers `assert_sections`, `FACTS=/src/vps/vps-facts.sh`, the `SECTIONS` array).
- Produces: `bash vps-facts.sh [--user <name>]`, and the piped form the operator runs: `Get-Content .\vps\vps-facts.sh | ssh tmuxkeep-admin 'bash -s -- --user <name>'` (or `'bash -s'` for the default `claude`). Output gains a third line `User: <name>`.

**Behaviour (spec 7.3, plan Q8):**
- Line 2 must forward the arguments to the inner shell, so it becomes exactly:

  ```bash
  case "$0" in *vps-facts.sh) ;; *) tr -d '\r' | bash -s -- "$@"; exit $? ;; esac #
  ```

  Everything else about lines 1-3 stays (the trailing ` #` still turns line 2's own CR into a comment when PowerShell pipes the file with CRLF).
- Before `main` runs, parse the arguments at top level (not inside the `main | tr` pipeline, whose exit status is `tr`'s):
  - `--user <name>` sets the user (default `claude`); `--user` without a value prints `vps-facts: --user needs a value` on stderr and exits 2;
  - the name must match `^[a-z_][a-z0-9_-]{0,31}$`, else `vps-facts: --user must match ^[a-z_][a-z0-9_-]{0,31}$` on stderr and exit 2;
  - any other argument prints `vps-facts: unknown argument` on stderr and exits 2 (do not echo the argument).
- `main` prints `User: <name>` right after the `Generated:` line, and the `## Users and groups` section probes `getent passwd "<name>"` instead of `getent passwd claude`. Nothing else changes: still read-only, ASCII only, exit 0 when probes fail, the `## claude processes` section still looks for processes named `claude` (the program, not the user).
- Update the comment block (lines 4-8) so its usage line reads `Get-Content .\vps\vps-facts.sh | ssh tmuxkeep-admin 'bash -s -- --user claude' | Out-File -Encoding utf8 docs\vps-facts.md`.

- [ ] **Step 1: Change the tests in `tests/bats/facts.bats`**

Replace the body of the test `"lines 1 and 2 are the BOM/CRLF guard"` so its `want` heredoc holds the new line 2:

```bash
@test "lines 1 and 2 are the BOM/CRLF guard, and line 2 forwards the arguments" {
  local want
  want=$(cat <<'EOF'
case "$0" in *vps-facts.sh) ;; *) tr -d '\r' | bash -s -- "$@"; exit $? ;; esac #
EOF
)
  [ "$(sed -n 1p "$FACTS")" = '#!/bin/bash' ]
  [ "$(sed -n 2p "$FACTS")" = "$want" ]
}
```

Append these tests at the end of the file:

```bash

@test "--user is reported and probed when run as a file" {
  run --separate-stderr bash "$FACTS" --user nobody
  [ "$status" -eq 0 ]
  assert_sections
  printf '%s\n' "$output" | grep -qx 'User: nobody'
  printf '%s\n' "$output" | grep -q '^nobody:x:65534:'
  [ -z "$stderr" ]
}

@test "--user is forwarded through the PowerShell-style piped form (BOM and CRLF)" {
  run --separate-stderr bash -c "{ printf '\xef\xbb\xbf'; sed 's/\$/\r/' '$FACTS'; } | bash -s -- --user nobody"
  [ "$status" -eq 0 ]
  assert_sections
  printf '%s\n' "$output" | grep -qx 'User: nobody'
  printf '%s\n' "$output" | grep -q '^nobody:x:65534:'
  [ "${#stderr_lines[@]}" -le 1 ]
}

@test "the default user is claude" {
  run bash "$FACTS"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'User: claude'
  printf '%s\n' "$output" | grep -q '^claude:x:1000:'
}

@test "a bad --user, a missing value and an unknown argument are usage (2)" {
  run --separate-stderr bash "$FACTS" --user Bob
  [ "$status" -eq 2 ]
  [ "$stderr" = 'vps-facts: --user must match ^[a-z_][a-z0-9_-]{0,31}$' ]
  run --separate-stderr bash "$FACTS" --user
  [ "$status" -eq 2 ]
  [ "$stderr" = 'vps-facts: --user needs a value' ]
  run --separate-stderr bash "$FACTS" --frob
  [ "$status" -eq 2 ]
  [ "$stderr" = 'vps-facts: unknown argument' ]
}
```

- [ ] **Step 2: Run to see them fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/facts.bats`
Expected: `not ok` for the line-2 test and the four new tests.

- [ ] **Step 3: Implement the behaviour above in `vps/vps-facts.sh`**

- [ ] **Step 4: Run until green**

`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/facts.bats`: 15 tests, all `ok`. Then the whole bats directory and the whole Pester folder (G8).

- [ ] **Step 5: Line endings, commit**

```bash
grep -lU "$(printf '\r')" vps/vps-facts.sh tests/bats/facts.bats    # Git Bash; must print nothing
git add vps/vps-facts.sh tests/bats/facts.bats
git commit -m "vps-facts: --user <name>, forwarded through the piped form"
```

---

### Task 5: Installer: `--conf`, configurable user, account guards, Claude Code opt-in

Suggested model: sonnet. Root installer; the orchestrator should have Opus review the diff.

**Files:**
- Create: `tests/fixtures/deploy.conf`
- Create: `tests/bats/setup-conf.bats`
- Modify: `vps/tmuxkeep-setup`
- Modify: `tests/bats/setup.bats` (two edits)

**Interfaces:**
- Consumes: Task 1's installer (`say`, `warn`, `die`, `usage`, `allowusers_ok`, `check_claude_sshd`, `user_systemctl`, `no_symlinks_in_home`, `ensure_path_snippet`, `CLAUDE_USER`, `CLAUDE_HOME`, `TMUXKEEP_ETC`, `SUDOERS_DEST`, `AUDIT_DIR`); Task 2's fixture `tests/fixtures/tmuxkeep.conf` and test helper `conf_set_in FILE KEY VALUE`.
- Produces, for Task 6 and the deploys:
  - Command line: `bash tmuxkeep-setup --pubkey-file <path> [--key-id <id>] [--conf <file>] [--rotate-totp] [--harden-root] [--unlock-otp]`.
  - Globals: `TK_USER` (default `claude`, then `CONF_USER`), `TK_HOME` (empty until read from `getent`), `VPS_CONF=/etc/tmuxkeep/tmuxkeep.conf`, `DEPLOY_CONF_KEYS`, and `CONF_USER CONF_LAUNCH_CMD CONF_RESUME_CMD CONF_INSTALL_CLAUDE_CODE CONF_LEASE_SECS CONF_TOMBSTONE_TTL CONF_OTP_FAIL_MAX CONF_OTP_FAIL_WINDOW CONF_OTP_COOLDOWN CONF_OTP_HARD_MAX CONF_OTP_READ_TIMEOUT CONF_SEND_MAX_BYTES`, `CONF_ERR`.
  - Functions: `trim_ws`, `printable_ascii`, `valid_abs_path`, `check_int` (same code as the broker's, Task 2); `conf_defaults`; `validate_deploy_conf`; `read_deploy_conf FILE`; `account_ok USER`; `user_unchanged FILE USER`; `home_of USER` (prints the home); `check_user_sshd` (was `check_claude_sshd`); `step_claude_code`; `install_claude_code`; `report_root_claude`; `print_next_steps WORK_DIR INSTALL_CLAUDE_CODE`.
  - Fixture `tests/fixtures/deploy.conf`: the bytes both deploys must write for the default config (Tasks 7, 9, 12, 14).

**Behaviour (spec 4.3, 7.2, 12; plan Q5, Q13; Review Focus 1 and 5):**
- Header comment: the usage line becomes the command line above; the second paragraph says the staging directory holds `tmuxkeep`, `sshd.conf.tmpl`, `sudoers.tmpl`, `tmux.conf`, `systemd/`, `laptop.pub` and `deploy.conf`.
- `usage()` prints `usage: tmuxkeep-setup --pubkey-file <path> [--key-id <id>] [--conf <file>] [--rotate-totp] [--harden-root] [--unlock-otp]`.
- Replace the globals `CLAUDE_USER=claude` and `CLAUDE_HOME=/home/claude` with:

  ```bash
  TK_USER=claude
  TK_HOME=
  VPS_CONF=/etc/tmuxkeep/tmuxkeep.conf
  DEPLOY_CONF_KEYS='USER LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES'
  ```

  and replace every `$CLAUDE_USER` with `$TK_USER` and every `$CLAUDE_HOME` with `$TK_HOME` in the file. Rename `check_claude_sshd` to `check_user_sshd` (it calls `sshd_effective "$TK_USER"` and its messages say `user $TK_USER`). `allowusers_ok` accepts `"$TK_USER" | '*' | "$TK_USER"@*` and says `sshd AllowUsers does not admit $TK_USER; add $TK_USER to it and re-run`. `user_systemctl` runs `runuser -u "$TK_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user "$@"`. After this task `grep -nE 'CLAUDE_USER|CLAUDE_HOME|/home/claude' vps/tmuxkeep-setup` prints nothing.
- Copy `trim_ws`, `printable_ascii`, `valid_abs_path` and `check_int` from `vps/tmuxkeep` (Task 2) verbatim into a new `# ---- deploy.conf (spec 4.3) ----` section.
- `conf_defaults` assigns, literally: `CONF_USER=claude`, `CONF_LAUNCH_CMD=claude`, `CONF_RESUME_CMD='claude --continue'`, `CONF_INSTALL_CLAUDE_CODE=no`, `CONF_LEASE_SECS=1800`, `CONF_TOMBSTONE_TTL=86400`, `CONF_OTP_FAIL_MAX=3`, `CONF_OTP_FAIL_WINDOW=600`, `CONF_OTP_COOLDOWN=300`, `CONF_OTP_HARD_MAX=10`, `CONF_OTP_READ_TIMEOUT=60`, `CONF_SEND_MAX_BYTES=8000`.
- `validate_deploy_conf` checks, in this order, naming each `CONF_*` directly (no `${!name}`, or shellcheck reports SC2034): `CONF_USER` against `^[a-z_][a-z0-9_-]{0,31}$` (put the regex in a local variable `re` and test `[[ $CONF_USER =~ $re ]]`); `${#CONF_LAUNCH_CMD} <= 200`; `${#CONF_RESUME_CMD} <= 200`; `CONF_INSTALL_CLAUDE_CODE` is `yes` or `no`; then `check_int` for `LEASE_SECS 60 86400`, `TOMBSTONE_TTL 3600 2592000`, `OTP_FAIL_MAX 1 20`, `OTP_FAIL_WINDOW 60 86400`, `OTP_COOLDOWN 10 86400`, `OTP_HARD_MAX $(( 10#$CONF_OTP_FAIL_MAX )) 100`, `OTP_READ_TIMEOUT 10 600`, `SEND_MAX_BYTES 1 65536`. Messages exactly as G32; `CONF_ERR` holds the reason only.
- `read_deploy_conf FILE` is the G30 parser for `DEPLOY_CONF_KEYS`, every key required:

  ```bash
  # read_deploy_conf FILE: sets every CONF_* from FILE (spec 4.1 rules, the spec 4.3 keys, every key
  # required, plan Q5) and returns 0, or sets CONF_ERR to "<FILE>: <reason>" and returns 1. The file
  # crossed the network, so it is checked again even though deploy validated the laptop config.
  read_deploy_conf() {
    local file=$1 line key val n=0 seen=' ' k
    CONF_ERR=
    if [[ ! -f $file || ! -r $file ]]; then CONF_ERR="$file: cannot read"; return 1; fi
    if head -c 3 "$file" | LC_ALL=C grep -q $'^\xef\xbb\xbf'; then
      CONF_ERR="$file: byte order mark found (save without BOM)"; return 1
    fi
    if LC_ALL=C grep -q $'\r' "$file"; then
      CONF_ERR="$file: carriage return found (use LF line endings)"; return 1
    fi
    while IFS= read -r line || [[ -n $line ]]; do
      n=$(( n + 1 ))
      trim_ws "$line"; line=$TRIMMED
      if [[ -z $line || $line == '#'* ]]; then continue; fi
      if [[ $line != *=* ]]; then CONF_ERR="$file: line $n: expected KEY=value"; return 1; fi
      trim_ws "${line%%=*}"; key=$TRIMMED
      trim_ws "${line#*=}"; val=$TRIMMED
      if ! [[ $key =~ ^[A-Z_]+$ && " $DEPLOY_CONF_KEYS " == *" $key "* ]]; then
        if [[ $key =~ ^[A-Za-z0-9_]{1,64}$ ]]; then CONF_ERR="$file: line $n: unknown key $key"
        else CONF_ERR="$file: line $n: unknown key"; fi
        return 1
      fi
      if ! printable_ascii "$val"; then
        CONF_ERR="$file: line $n: non-printable or non-ASCII character in $key"; return 1
      fi
      printf -v "CONF_$key" '%s' "$val"
      seen+="$key "
    done < "$file"
    for k in $DEPLOY_CONF_KEYS; do
      if [[ $seen != *" $k "* ]]; then CONF_ERR="$file: $k: required"; return 1; fi
    done
    if ! validate_deploy_conf; then CONF_ERR="$file: $CONF_ERR"; return 1; fi
  }
  ```

- Account guards:

  ```bash
  # account_ok USER: an existing USER must be a regular account, uid 1000-59999 (Review Focus 1).
  # A system account (root, daemon, nobody) would get the sudoers rules, a disabled password and
  # the forced command; root would also lose its own authorized_keys to the drop-in.
  account_ok() {
    local uid
    uid=$(id -u "$1" 2>/dev/null) || return 0
    if (( uid < 1000 || uid > 59999 )); then
      warn "refusing USER=$1: uid $uid is a system account; choose a dedicated user name"
      return 1
    fi
  }

  # user_unchanged FILE USER: the installed tmuxkeep.conf, if any, names the same USER (Review
  # Focus 5). The audit log and the old user's timer stay behind on a change, so it is manual.
  user_unchanged() {
    local prev
    [[ -f $1 ]] || return 0
    prev=$(sed -n 's/^[[:blank:]]*USER[[:blank:]]*=[[:blank:]]*//p' "$1" | tail -n 1)
    prev=${prev%"${prev##*[![:blank:]]}"}
    if [[ -n $prev && $prev != "$2" ]]; then
      warn "USER changed from $prev to $2 since the last deploy; see README \"Changing the VPS user\""
      return 1
    fi
  }

  # home_of USER: prints USER's home directory from getent; 1 when the account is missing or the
  # home is not a plain absolute path (the broker would reject it in tmuxkeep.conf).
  home_of() {
    local h
    h=$(getent passwd "$1" | cut -d: -f6)
    if [[ -z $h ]] || ! valid_abs_path "$h"; then
      warn "home directory of $1 is missing or not a plain absolute path: ${h:-none}"
      return 1
    fi
    printf '%s\n' "$h"
  }
  ```

- Claude Code opt-in (spec 7.2) and the report:

  ```bash
  # step_claude_code: installs Claude Code for TK_USER only when INSTALL_CLAUDE_CODE=yes.
  step_claude_code() {
    if [[ $CONF_INSTALL_CLAUDE_CODE != yes ]]; then
      say "Claude Code: not installed (INSTALL_CLAUDE_CODE=no)"
      return 0
    fi
    install_claude_code
  }
  ```

  `install_claude_code` is v1's step-8 block turned into a function that returns 1 after `warn` instead of calling `die`: return 0 at once if `runuser -l "$TK_USER" -c 'command -v claude'` succeeds; otherwise run `runuser -l "$TK_USER" -c 'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash'` (on failure `warn "the Claude Code install failed; re-run after fixing the network"`, return 1), then check `command -v claude` again (on failure `warn "Claude Code installed but claude is not on the PATH of $TK_USER"`, return 1). `report_root_claude` is v1's `pgrep -u root -x claude` block: it prints `WARNING: claude is running as root (PIDs: <pids separated by single spaces>); stop it and move its work to $TK_HOME/work` and nothing when there are none.
- `print_next_steps WORK_DIR INSTALL` replaces the `cat <<'EOF'` block at the end of `main`. Its output is exactly (with `<WORK_DIR>` substituted):

  ```
  First run:
    1. Scan the QR code into an authenticator app.
    2. On the laptop: tmuxkeep new scratch, then tmuxkeep go scratch, complete the Claude Code login inside it, detach with Ctrl-b d.
    3. Move any existing projects from /root to <WORK_DIR>/ and stop any root tmux sessions (README section "Migrating work from root").
    4. Once tmuxkeep-admin logs in with the admin key, run deploy again with --harden-root (-HardenRoot on Windows).
  ```

  When INSTALL is not `yes`, line 2 is instead `  2. On the laptop: tmuxkeep new scratch, then tmuxkeep go scratch to check the session, detach with Ctrl-b d.`
- `main`, in order. Unchanged parts stay as they are.
  1. Argument loop: add `--conf` with the same "value must not start with `--`" rule as `--pubkey-file`; add `CONF_FILE=''` to the first `local` line; drop `pids` from the locals.
  2. Directly after the argument checks, before the root check:

     ```bash
     # 2. The deploy configuration (spec 4.3), checked again here because it crossed the network.
     conf_defaults
     if [[ -n $CONF_FILE ]] && ! read_deploy_conf "$CONF_FILE"; then
       warn "deploy.conf invalid: $CONF_ERR"
       exit 2
     fi
     TK_USER=$CONF_USER
     ```

     Renumber the following comments (root check becomes 3, preflight 4).
  3. Preflight: replace the line `no_symlinks_in_home "$CLAUDE_HOME" || exit 1` (after `KEYLINE=...`) with:

     ```bash
     account_ok "$TK_USER" || exit 1
     user_unchanged "$VPS_CONF" "$TK_USER" || exit 1
     if getent passwd "$TK_USER" >/dev/null 2>&1; then
       TK_HOME=$(home_of "$TK_USER") || exit 1
       no_symlinks_in_home "$TK_HOME" || exit 1
     fi
     ```

  4. Step 2: after the `useradd` block, replace the "does not have home" check with:

     ```bash
     TK_HOME=$(home_of "$TK_USER") || exit 1
     no_symlinks_in_home "$TK_HOME" || exit 1
     ```

     The step's `say` text becomes `say "step 2: user and sudoers"` (unchanged); its comment says "The account and its sudoers allowlist."
  5. Steps 3-7: only the `CLAUDE_*` to `TK_*` replacement.
  6. Step 8: keep the PATH-snippet loop; replace the Claude Code block with `step_claude_code || exit 1`. Comment: `# Step 8. PATH for the user, and Claude Code only when asked (spec 7.2).`
  7. Step 9: replace the `pids=...` block with `if [[ $CONF_INSTALL_CLAUDE_CODE == yes ]]; then report_root_claude; fi`; the summary line becomes `say "  user:            $TK_USER (uid $uid)"`; replace the final heredoc with `print_next_steps "$TK_HOME/work" "$CONF_INSTALL_CLAUDE_CODE"`.

- [ ] **Step 1: Create the fixture `tests/fixtures/deploy.conf` with exactly this content (13 lines, LF, final newline)**

```
# Written by tmuxkeep deploy from the laptop config; read by tmuxkeep-setup --conf.
USER=claude
LAUNCH_CMD=claude
RESUME_CMD=claude --continue
INSTALL_CLAUDE_CODE=no
LEASE_SECS=1800
TOMBSTONE_TTL=86400
OTP_FAIL_MAX=3
OTP_FAIL_WINDOW=600
OTP_COOLDOWN=300
OTP_HARD_MAX=10
OTP_READ_TIMEOUT=60
SEND_MAX_BYTES=8000
```

- [ ] **Step 2: Write the failing test `tests/bats/setup-conf.bats`**

```bash
#!/usr/bin/env bats
# vps/tmuxkeep-setup, spec 4.3 and 7.2: --conf parsing, the configurable user, the account guards
# (Review Focus 1 and 5), the Claude Code opt-in and the next-steps text. The file is sourced;
# main runs only with arguments that make it exit 2 before any step.
load helpers

FIX=/src/tests/fixtures/deploy.conf

setup() {
  source /src/vps/tmuxkeep-setup
  C="$BATS_TEST_TMPDIR/deploy.conf"
}
teardown() {
  rm -f /etc/tmuxkeep/tmuxkeep.conf
}

fresh() { cp "$FIX" "$C"; }

# rejects FILE SUFFIX: read_deploy_conf fails and CONF_ERR is "FILE: ...SUFFIX".
rejects() {
  conf_defaults
  if read_deploy_conf "$1"; then echo "accepted, wanted: $2"; return 1; fi
  [[ "$CONF_ERR" == "$1: "*"$2" ]] || { echo "CONF_ERR: $CONF_ERR"; echo "wanted suffix: $2"; return 1; }
}

@test "sourcing defines the new functions and runs nothing" {
  declare -F conf_defaults read_deploy_conf validate_deploy_conf account_ok user_unchanged home_of \
    check_user_sshd step_claude_code install_claude_code report_root_claude print_next_steps >/dev/null
  [ "$TK_USER" = claude ]
  [ -z "$TK_HOME" ]
}

@test "read_deploy_conf accepts the fixture and sets every CONF_* value" {
  conf_defaults
  CONF_USER=x
  CONF_LEASE_SECS=1
  read_deploy_conf "$FIX"
  [ "$CONF_USER" = claude ]
  [ "$CONF_LAUNCH_CMD" = claude ]
  [ "$CONF_RESUME_CMD" = 'claude --continue' ]
  [ "$CONF_INSTALL_CLAUDE_CODE" = no ]
  [ "$CONF_LEASE_SECS" = 1800 ]
  [ "$CONF_TOMBSTONE_TTL" = 86400 ]
  [ "$CONF_OTP_FAIL_MAX" = 3 ]
  [ "$CONF_OTP_FAIL_WINDOW" = 600 ]
  [ "$CONF_OTP_COOLDOWN" = 300 ]
  [ "$CONF_OTP_HARD_MAX" = 10 ]
  [ "$CONF_OTP_READ_TIMEOUT" = 60 ]
  [ "$CONF_SEND_MAX_BYTES" = 8000 ]
}

@test "an unknown key, a bad USER, a bad yes/no and out-of-range values are rejected with the key named" {
  local n=$(( $(wc -l < "$FIX") + 1 )) v
  { cat "$FIX"; printf 'HOST=203.0.113.10\n'; } > "$C"
  rejects "$C" "line $n: unknown key HOST"
  for v in Bob 1abc '' 'a b' "$(printf 'a%.0s' $(seq 1 33))"; do
    fresh; conf_set_in "$C" USER "$v"
    rejects "$C" 'USER: must match ^[a-z_][a-z0-9_-]{0,31}$' || { echo "USER=$v"; return 1; }
  done
  for v in yes no; do
    fresh; conf_set_in "$C" INSTALL_CLAUDE_CODE "$v"; conf_defaults; read_deploy_conf "$C"
  done
  for v in Yes YES true 1 ''; do
    fresh; conf_set_in "$C" INSTALL_CLAUDE_CODE "$v"
    rejects "$C" 'INSTALL_CLAUDE_CODE: must be yes or no' || { echo "INSTALL_CLAUDE_CODE=$v"; return 1; }
  done
  fresh; conf_set_in "$C" LEASE_SECS 59
  rejects "$C" 'LEASE_SECS: must be an integer from 60 to 86400'
  fresh; conf_set_in "$C" OTP_HARD_MAX 2
  rejects "$C" 'OTP_HARD_MAX: must be an integer from 3 to 100'
  fresh; conf_set_in "$C" LAUNCH_CMD "$(printf 'x%.0s' $(seq 1 201))"
  rejects "$C" 'LAUNCH_CMD: at most 200 characters'
}

@test "a missing key, a CR, a BOM and a non-ASCII value are rejected" {
  local k
  for k in USER LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX \
           OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES; do
    grep -v "^$k=" "$FIX" > "$C"
    rejects "$C" "$k: required" || return 1
  done
  sed 's/$/\r/' "$FIX" > "$C"
  rejects "$C" 'carriage return found (use LF line endings)'
  { printf '\xef\xbb\xbf'; cat "$FIX"; } > "$C"
  rejects "$C" 'byte order mark found (save without BOM)'
  fresh; conf_set_in "$C" RESUME_CMD "$(printf 'caf\xc3\xa9')"
  rejects "$C" 'non-printable or non-ASCII character in RESUME_CMD'
}

@test "main: an invalid or unreadable --conf is exit 2 before any step, with the key named" {
  { cat "$FIX"; printf 'LEASE_SECS=5\n'; } > "$C"
  run --separate-stderr bash /src/vps/tmuxkeep-setup --pubkey-file /nonexistent --conf "$C"
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep-setup: deploy.conf invalid: $C: LEASE_SECS: must be an integer from 60 to 86400" ]
  run --separate-stderr bash /src/vps/tmuxkeep-setup --pubkey-file /nonexistent --conf "$BATS_TEST_TMPDIR/none"
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep-setup: deploy.conf invalid: $BATS_TEST_TMPDIR/none: cannot read" ]
}

@test "main: --conf without a value, or with an option as its value, is usage (2)" {
  run bash /src/vps/tmuxkeep-setup --pubkey-file /x --conf
  [ "$status" -eq 2 ]
  run bash /src/vps/tmuxkeep-setup --pubkey-file /x --conf --harden-root
  [ "$status" -eq 2 ]
  [[ "$output" == *'[--conf <file>]'* ]]
}

@test "account_ok refuses a system account (Review Focus 1) and accepts a regular or absent one" {
  local u
  for u in root daemon nobody; do
    run account_ok "$u"
    [ "$status" -ne 0 ] || { echo "accepted $u"; return 1; }
    [[ "$output" == "tmuxkeep-setup: refusing USER=$u: uid "*" is a system account; choose a dedicated user name" ]] || { echo "$output"; return 1; }
  done
  run account_ok claude
  [ "$status" -eq 0 ]
  run account_ok tk-no-such-user
  [ "$status" -eq 0 ]
}

@test "user_unchanged refuses a USER change against the installed tmuxkeep.conf (Review Focus 5)" {
  run user_unchanged /etc/tmuxkeep/tmuxkeep.conf bob
  [ "$status" -eq 0 ]
  cp /src/tests/fixtures/tmuxkeep.conf /etc/tmuxkeep/tmuxkeep.conf
  run user_unchanged /etc/tmuxkeep/tmuxkeep.conf claude
  [ "$status" -eq 0 ]
  run user_unchanged /etc/tmuxkeep/tmuxkeep.conf bob
  [ "$status" -ne 0 ]
  [ "$output" = 'tmuxkeep-setup: USER changed from claude to bob since the last deploy; see README "Changing the VPS user"' ]
}

@test "home_of reads the home from getent and refuses one the broker would reject" {
  run home_of claude
  [ "$status" -eq 0 ]
  [ "$output" = /home/claude ]
  run home_of tk-no-such-user
  [ "$status" -ne 0 ]
  useradd -M -d '/srv/a b' tk-bad-home
  run home_of tk-bad-home
  userdel tk-bad-home
  [ "$status" -ne 0 ]
  [[ "$output" == *'not a plain absolute path: /srv/a b'* ]]
}

@test "allowusers_ok and user_systemctl use TK_USER" {
  TK_USER=bob
  run allowusers_ok 'allowusers root bob'
  [ "$status" -eq 0 ]
  run allowusers_ok 'allowusers root claude'
  [ "$status" -ne 0 ]
  [[ "$output" == *'does not admit bob'* ]]
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "$*"\n' > "$BATS_TEST_TMPDIR/bin/runuser"
  chmod +x "$BATS_TEST_TMPDIR/bin/runuser"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run user_systemctl 1001 daemon-reload
  [ "$output" = '-u bob -- env XDG_RUNTIME_DIR=/run/user/1001 systemctl --user daemon-reload' ]
}

@test "step_claude_code installs only when INSTALL_CLAUDE_CODE=yes" {
  install_claude_code() { echo INSTALL-CALLED; }
  CONF_INSTALL_CLAUDE_CODE=no
  run step_claude_code
  [ "$status" -eq 0 ]
  [ "$output" = 'Claude Code: not installed (INSTALL_CLAUDE_CODE=no)' ]
  CONF_INSTALL_CLAUDE_CODE=yes
  run step_claude_code
  [ "$output" = INSTALL-CALLED ]
}

@test "report_root_claude names the PIDs and the work directory, and is silent when there are none" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nprintf "123\\n456\\n"\n' > "$BATS_TEST_TMPDIR/bin/pgrep"
  chmod +x "$BATS_TEST_TMPDIR/bin/pgrep"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  TK_HOME=/home/bob
  run report_root_claude
  [ "$output" = 'WARNING: claude is running as root (PIDs: 123 456); stop it and move its work to /home/bob/work' ]
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/pgrep"
  run report_root_claude
  [ -z "$output" ]
}

@test "main runs the Claude Code install and the root warning only through the opt-in functions" {
  local body="$BATS_TEST_TMPDIR/main.body"
  sed -n '/^main() {/,/^}/p' /src/vps/tmuxkeep-setup > "$body"
  grep -qx '  step_claude_code || exit 1' "$body"
  grep -qx '  if [[ $CONF_INSTALL_CLAUDE_CODE == yes ]]; then report_root_claude; fi' "$body"
  run grep -c 'install.sh' "$body"
  [ "$output" = 0 ]
  run grep -c 'pgrep' "$body"
  [ "$output" = 0 ]
}

@test "print_next_steps names the work directory, with and without Claude Code" {
  run print_next_steps /home/bob/work yes
  [ "$output" = "$(printf '%s\n' \
    'First run:' \
    '  1. Scan the QR code into an authenticator app.' \
    '  2. On the laptop: tmuxkeep new scratch, then tmuxkeep go scratch, complete the Claude Code login inside it, detach with Ctrl-b d.' \
    '  3. Move any existing projects from /root to /home/bob/work/ and stop any root tmux sessions (README section "Migrating work from root").' \
    '  4. Once tmuxkeep-admin logs in with the admin key, run deploy again with --harden-root (-HardenRoot on Windows).')" ]
  run print_next_steps /home/bob/work no
  [ "${lines[2]}" = '  2. On the laptop: tmuxkeep new scratch, then tmuxkeep go scratch to check the session, detach with Ctrl-b d.' ]
  [ "${lines[3]}" = '  3. Move any existing projects from /root to /home/bob/work/ and stop any root tmux sessions (README section "Migrating work from root").' ]
}

@test "no literal claude account remains in the installer" {
  run grep -nE 'CLAUDE_USER|CLAUDE_HOME|/home/claude' /src/vps/tmuxkeep-setup
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 3: Edit `tests/bats/setup.bats`**

(a) In the test `"install_sshd_dropin installs when root's config is unchanged"`, change `run check_claude_sshd` to `run check_user_sshd`.

(b) Replace the whole test `"main keeps its guards: signals ignored, LC_ALL=C, apt lock timeout, staged sudoers, symlink checks"` with:

```bash
@test "main keeps its guards: signals ignored, LC_ALL=C, apt lock timeout, staged sudoers, symlink checks" {
  local body="$BATS_TEST_TMPDIR/main.body" step1
  sed -n '/^main() {/,/^}/p' /src/vps/tmuxkeep-setup > "$body"
  grep -qx "  trap '' HUP PIPE" "$body"
  grep -qx '  export LC_ALL=C' "$body"
  [ "$(grep -c 'apt-get -o DPkg::Lock::Timeout=300 ' "$body")" -eq 2 ]
  grep -qF 'sudoers_new=${SUDOERS_DEST%/*}/.tmuxkeep.new' "$body"
  [ "$(grep -Ec '^  (if ! )?visudo -cf ' "$body")" -eq 2 ]
  [ "$(grep -c 'no_symlinks_in_home "$TK_HOME" || exit 1' "$body")" -eq 4 ]
  # The user manager is reached through its private socket, never through the user's D-Bus bus.
  run ! grep -q -- '--user -M' /src/vps/tmuxkeep-setup
  [ "$(grep -c 'user_systemctl "$uid" ' "$body")" -eq 4 ]
  # The account guards run before step 1 changes anything.
  step1=$(grep -n 'say "step 1: packages"' "$body" | cut -d: -f1)
  [ "$(grep -n 'account_ok "$TK_USER" || exit 1' "$body" | cut -d: -f1)" -lt "$step1" ]
  [ "$(grep -n 'user_unchanged "$VPS_CONF" "$TK_USER" || exit 1' "$body" | cut -d: -f1)" -lt "$step1" ]
}
```

- [ ] **Step 4: Run to see the new tests fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/setup-conf.bats`
Expected: `not ok` lines (the functions do not exist yet).

- [ ] **Step 5: Implement the behaviour above. Never run `main` with arguments that get past the conf check.**

- [ ] **Step 6: Run until green**

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/setup-conf.bats`: 15 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/setup.bats`: 36 tests, all `ok`.
- the whole bats directory and the whole Pester folder (G8).

- [ ] **Step 7: Line endings, commit**

```bash
grep -rlIU "$(printf '\r')" vps tests     # Git Bash; must print nothing
git add vps/tmuxkeep-setup tests/fixtures/deploy.conf tests/bats/setup-conf.bats tests/bats/setup.bats
git commit -m "tmuxkeep-setup: --conf, configurable user with system-account and user-change guards, Claude Code opt-in"
```

---

### Task 6: Installer: `__USER__` templates, VPS config file, `--check-conf` gate

Suggested model: sonnet. Root installer and sudoers; the orchestrator should have Opus review the diff.

**Files:**
- Modify: `vps/sshd.conf.tmpl`, `vps/sudoers.tmpl` (new content below)
- Modify: `vps/tmuxkeep-setup`
- Create: `tests/bats/setup-render.bats`
- Modify: `tests/bats/setup.bats` (three edits)
- Replace: `tests/bats/config.bats` (full new content below)

**Interfaces:**
- Consumes: Task 5's installer (`TK_USER`, `TK_HOME`, `VPS_CONF`, `CONF_*`, `conf_defaults`, `check_user_sshd`, `sshd_effective`, `install_sshd_dropin`, `_dropin_apply`, `render_dropin`, `dropin_is_hardened`, `SUDOERS_DEST`, `TMUXKEEP_ETC`, `AUDIT_DIR`, `BROKER_DEST`, `STAGE_DIR` in `main`); Task 2's `tmuxkeep --check-conf <file>` and fixture `tests/fixtures/tmuxkeep.conf`; helpers `setup_local`, `teardown_local`, `tm`, `mk_lease`, `tmuxkeep`.
- Produces:
  - Templates with the literal `__USER__` (spec 7.2): `vps/sshd.conf.tmpl` (one occurrence, in `Match User __USER__`) and `vps/sudoers.tmpl` (three rule lines).
  - `render_template FILE USER`: prints FILE with every `__USER__` replaced by USER, final newline kept.
  - `render_dropin SRC HARDEN`: as before, but renders SRC for `TK_USER` first.
  - `install_sudoers SRC`: renders for `TK_USER` into `/etc/sudoers.d/.tmuxkeep.new` (root 0440), `visudo -cf` on that file, `mv` to `SUDOERS_DEST`; on failure removes the temp file, leaves `SUDOERS_DEST` untouched, returns 1.
  - `render_vps_conf`: prints the `/etc/tmuxkeep/tmuxkeep.conf` text (spec 4.4) from `TK_USER`, `TK_HOME`, `AUDIT_DIR` and the `CONF_*` values.
  - `write_vps_conf BROKER`: writes the rendering to `$TMUXKEEP_ETC/.tmuxkeep.conf.new` (root 0644), runs `BROKER --check-conf` on it, and only then renames it to `VPS_CONF` (plan Q7); on failure removes the temp file, leaves `VPS_CONF` untouched, returns 1.
  - `STAGED_FILES=(tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer)` on one line (Task 15 parses it).

**Behaviour (spec 4.4, 7.2, 8, 12; plan Q7):**
- `vps/sshd.conf.tmpl`, exactly (10 lines):

  ```
  # tmuxkeep: tmuxkeep-setup replaces the user placeholder and installs this as /etc/ssh/sshd_config.d/tmuxkeep.conf. Do not edit on the VPS.
  # PermitRootLogin prohibit-password      <- uncommented by setup --harden-root
  Match User __USER__
      AuthorizedKeysFile /etc/tmuxkeep/authorized_keys
      PasswordAuthentication no
      DisableForwarding yes
      PermitUserRC no
      ClientAliveInterval 30
      ClientAliveCountMax 4
  Match all
  ```

- `vps/sudoers.tmpl`, exactly (4 lines; the rules are v1's):

  ```
  # tmuxkeep: tmuxkeep-setup replaces the user placeholder and installs this as /etc/sudoers.d/tmuxkeep (0440) after visudo -cf.
  __USER__ ALL=(root) NOPASSWD: /usr/bin/apt-get update, /usr/bin/apt-get install *
  __USER__ ALL=(root) NOPASSWD: /usr/bin/systemctl restart *, /usr/bin/systemctl reload *, /usr/bin/systemctl status *
  __USER__ ALL=(root) NOPASSWD: /usr/bin/journalctl *
  ```

- Code:

  ```bash
  # render_template FILE USER: FILE with every __USER__ replaced by USER (spec 7.2). Safe because
  # USER matched ^[a-z_][a-z0-9_-]{0,31}$, and each rendering is validated by its own tool before
  # it is installed. The x keeps the final newline that $(...) would strip.
  render_template() {
    local text
    text=$(cat -- "$1" && printf x) || return 1
    text=${text%x}
    printf '%s' "${text//__USER__/$2}"
  }
  ```

  `render_dropin` keeps its signature; its two branches become `render_template "$src" "$TK_USER" | sed -E '<v1 expression>'` and `render_template "$src" "$TK_USER"`.

  ```bash
  # install_sudoers SRC: render SRC for TK_USER under a name sudo ignores (it contains a dot),
  # validate exactly that file, then rename it into place, so sudo never reads a partial or
  # unvalidated file (spec 7.2, G26). On failure SUDOERS_DEST is unchanged.
  install_sudoers() {
    local src=$1 new=${SUDOERS_DEST%/*}/.tmuxkeep.new
    if ! install -o root -g root -m 0440 /dev/null "$new" || ! render_template "$src" "$TK_USER" > "$new"; then
      rm -f -- "$new"
      warn "cannot stage $new"
      return 1
    fi
    if ! visudo -cf "$new" >/dev/null; then
      rm -f -- "$new"
      warn "the rendered sudoers file failed visudo -cf; $SUDOERS_DEST was not changed"
      return 1
    fi
    if ! mv -f -- "$new" "$SUDOERS_DEST"; then
      rm -f -- "$new"
      warn "cannot move the staged sudoers file to $SUDOERS_DEST"
      return 1
    fi
  }

  # render_vps_conf: the /etc/tmuxkeep/tmuxkeep.conf text (spec 4.4). For USER=claude and the
  # defaults it is tests/fixtures/tmuxkeep.conf byte for byte.
  render_vps_conf() {
    printf '%s\n' \
      '# Written by tmuxkeep-setup on every deploy; edits here are overwritten.' \
      '# Change ~/.tmuxkeep/config on the laptop and deploy again instead.' \
      "USER=$TK_USER" \
      "USER_HOME=$TK_HOME" \
      "STATE_DIR=$TK_HOME/.tmuxkeep" \
      "WORK_DIR=$TK_HOME/work" \
      "AUDIT_LOG=$AUDIT_DIR/audit.log" \
      "LAUNCH_CMD=$CONF_LAUNCH_CMD" \
      "RESUME_CMD=$CONF_RESUME_CMD" \
      "LEASE_SECS=$CONF_LEASE_SECS" \
      "TOMBSTONE_TTL=$CONF_TOMBSTONE_TTL" \
      "OTP_FAIL_MAX=$CONF_OTP_FAIL_MAX" \
      "OTP_FAIL_WINDOW=$CONF_OTP_FAIL_WINDOW" \
      "OTP_COOLDOWN=$CONF_OTP_COOLDOWN" \
      "OTP_HARD_MAX=$CONF_OTP_HARD_MAX" \
      "OTP_READ_TIMEOUT=$CONF_OTP_READ_TIMEOUT" \
      "SEND_MAX_BYTES=$CONF_SEND_MAX_BYTES"
  }

  # write_vps_conf BROKER: write the rendering next to VPS_CONF, let BROKER --check-conf it, and
  # only then rename it over VPS_CONF (plan Q7), so a file the broker would reject is never
  # installed. On failure VPS_CONF is unchanged and the temp file is gone.
  write_vps_conf() {
    local broker=$1 tmp=$TMUXKEEP_ETC/.tmuxkeep.conf.new
    if ! install -o root -g root -m 0644 /dev/null "$tmp" || ! render_vps_conf > "$tmp"; then
      rm -f -- "$tmp"
      warn "cannot write $tmp"
      return 1
    fi
    if ! "$broker" --check-conf "$tmp"; then
      rm -f -- "$tmp"
      warn "the broker rejected the new configuration; $VPS_CONF was not installed"
      return 1
    fi
    if ! mv -f -- "$tmp" "$VPS_CONF"; then
      rm -f -- "$tmp"
      warn "cannot move $tmp to $VPS_CONF"
      return 1
    fi
  }
  ```

- `STAGED_FILES` becomes the eight-entry line in Interfaces.
- `main`:
  - Step 2: delete the line `visudo -cf "$STAGE_DIR/sudoers.tmpl" >/dev/null || die ...` and the whole `sudoers_new=...` block down to and including its `mv` failure branch; put in their place `  install_sudoers "$STAGE_DIR/sudoers.tmpl" || die "sudoers was not installed; $SUDOERS_DEST is unchanged"`. Remove `sudoers_new` from the `local` list.
  - Step 3: directly after the line that installs `$STAGE_DIR/tmux.conf`, add `  write_vps_conf "$BROKER_DEST" || die "stopping: $VPS_CONF was not updated"`. This comes after the broker install and before `render_authorized_keys` and `install_sshd_dropin`, so a rejected config stops the run before the sshd drop-in changes.
  - The `install_sshd_dropin "$STAGE_DIR/sshd.conf.tmpl" "$HARDEN"` call stays as it is; it now renders for `TK_USER` through `render_dropin`.

- [ ] **Step 1: Write the failing test `tests/bats/setup-render.bats`**

```bash
#!/usr/bin/env bats
# vps/tmuxkeep-setup, spec 7.2 and 4.4: the __USER__ templates, the sudoers install, the sshd drop-in
# for another user, the VPS config file and its --check-conf gate (plan Q7). Sourced only.
load helpers

setup() {
  source /src/vps/tmuxkeep-setup
  conf_defaults
  cp /etc/ssh/sshd_config "$BATS_TEST_TMPDIR/sshd_config.orig"
  rm -f /etc/ssh/sshd_config.d/tmuxkeep.conf /etc/sudoers.d/tmuxkeep /etc/sudoers.d/.tmuxkeep.new \
        /etc/tmuxkeep/tmuxkeep.conf /etc/tmuxkeep/.tmuxkeep.conf.new
  printf '#!/bin/bash\nexec bash /src/vps/tmuxkeep "$@"\n' > "$BATS_TEST_TMPDIR/broker"
  chmod +x "$BATS_TEST_TMPDIR/broker"
}
teardown() {
  rm -f /etc/ssh/sshd_config.d/tmuxkeep.conf /etc/sudoers.d/tmuxkeep /etc/sudoers.d/.tmuxkeep.new \
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

@test "main installs sudoers through install_sudoers and writes the VPS config before the drop-in" {
  local body="$BATS_TEST_TMPDIR/main.body" a b c
  sed -n '/^main() {/,/^}/p' /src/vps/tmuxkeep-setup > "$body"
  grep -qx '  install_sudoers "$STAGE_DIR/sudoers.tmpl" || die "sudoers was not installed; $SUDOERS_DEST is unchanged"' "$body"
  grep -qx '  write_vps_conf "$BROKER_DEST" || die "stopping: $VPS_CONF was not updated"' "$body"
  a=$(grep -n 'install -o root -g root -m 0755 "$STAGE_DIR/tmuxkeep" "$BROKER_DEST"' "$body" | cut -d: -f1)
  b=$(grep -n 'write_vps_conf "$BROKER_DEST"' "$body" | cut -d: -f1)
  c=$(grep -n 'install_sshd_dropin "$STAGE_DIR/sshd.conf.tmpl"' "$body" | cut -d: -f1)
  [ "$a" -lt "$b" ]
  [ "$b" -lt "$c" ]
  run grep -c 'visudo' "$body"
  [ "$output" = 0 ]
}
```

- [ ] **Step 2: Edit `tests/bats/setup.bats`**

(a) Replace the whole test `"render_dropin keeps root's line commented unless hardening, then replaces it whole"` with:

```bash
@test "render_dropin keeps root's line commented unless hardening, then replaces it whole" {
  run render_dropin /src/vps/sshd.conf.tmpl 0
  [ "$output" = "$(render_template /src/vps/sshd.conf.tmpl claude)" ]
  run render_dropin /src/vps/sshd.conf.tmpl 1
  printf '%s\n' "$output" | grep -qx 'PermitRootLogin prohibit-password'
  [[ "$output" != *"<-"* ]]
  run dropin_is_hardened /src/vps/sshd.conf.tmpl
  [ "$status" -ne 0 ]
}
```

(b) In the test `"install_sshd_dropin installs when root's config is unchanged"`, replace the line `cmp /etc/ssh/sshd_config.d/tmuxkeep.conf /src/vps/sshd.conf.tmpl` with `cmp /etc/ssh/sshd_config.d/tmuxkeep.conf <(render_template /src/vps/sshd.conf.tmpl claude)`.

(c) In the test `"main keeps its guards: ..."` (rewritten in Task 5), replace the two lines

```bash
  grep -qF 'sudoers_new=${SUDOERS_DEST%/*}/.tmuxkeep.new' "$body"
  [ "$(grep -Ec '^  (if ! )?visudo -cf ' "$body")" -eq 2 ]
```

with

```bash
  grep -qF 'local src=$1 new=${SUDOERS_DEST%/*}/.tmuxkeep.new' /src/vps/tmuxkeep-setup
  [ "$(sed -n '/^install_sudoers() {/,/^}/p' /src/vps/tmuxkeep-setup | grep -c 'visudo -cf "$new"')" -eq 1 ]
```

- [ ] **Step 3: Replace `tests/bats/config.bats` with exactly this content**

```bash
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
```

- [ ] **Step 4: Run to see the new tests fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/setup-render.bats`
Expected: `not ok` lines (no `render_template`, no `__USER__` yet).

- [ ] **Step 5: Write the two templates and implement the installer changes above**

- [ ] **Step 6: Run until green**

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/setup-render.bats`: 12 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/setup.bats`: 36 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/config.bats`: 9 tests, all `ok`.
- the whole bats directory and the whole Pester folder (G8). The Pester suite is unaffected: `laptop/deploy.ps1` keeps its own staging list until Task 9, and every file on it still exists.

- [ ] **Step 7: Line endings, commit**

```bash
grep -rlIU "$(printf '\r')" vps tests     # Git Bash; must print nothing
git add vps/sshd.conf.tmpl vps/sudoers.tmpl vps/tmuxkeep-setup tests/bats/setup-render.bats tests/bats/setup.bats tests/bats/config.bats
git commit -m "tmuxkeep-setup: __USER__ templates, checked /etc/tmuxkeep/tmuxkeep.conf, eight staged files"
```

---

### Task 7: PowerShell deploy: laptop config functions

Suggested model: sonnet.

**Files:**
- Create: `tests/fixtures/laptop-config`
- Create: `tests/pester/config.Tests.ps1`
- Modify: `laptop/deploy.ps1` (new functions only; the main sequence is untouched until Task 9)

**Interfaces:**
- Consumes: Task 1's `laptop/deploy.ps1` (dot-source guard `if ($MyInvocation.InvocationName -eq '.') { return }`); Task 5's fixture `tests/fixtures/deploy.conf`, whose exact content is:

  ```
  # Written by tmuxkeep deploy from the laptop config; read by tmuxkeep-setup --conf.
  USER=claude
  LAUNCH_CMD=claude
  RESUME_CMD=claude --continue
  INSTALL_CLAUDE_CODE=no
  LEASE_SECS=1800
  TOMBSTONE_TTL=86400
  OTP_FAIL_MAX=3
  OTP_FAIL_WINDOW=600
  OTP_COOLDOWN=300
  OTP_HARD_MAX=10
  OTP_READ_TIMEOUT=60
  SEND_MAX_BYTES=8000
  ```

- Produces (all in `laptop/deploy.ps1`, before the dot-source guard; Tasks 8, 9 and 15 rely on these names):
  - `Get-TmuxkeepConfigKeys`: the sixteen laptop keys in file order. Written as one line exactly `function Get-TmuxkeepConfigKeys { @('HOST', 'PORT', 'USER', 'KEY', 'ADMIN_KEY', 'LAUNCH_CMD', 'RESUME_CMD', 'INSTALL_CLAUDE_CODE', 'LEASE_SECS', 'TOMBSTONE_TTL', 'OTP_FAIL_MAX', 'OTP_FAIL_WINDOW', 'OTP_COOLDOWN', 'OTP_HARD_MAX', 'OTP_READ_TIMEOUT', 'SEND_MAX_BYTES') }`.
  - `Get-TmuxkeepConfigDefaults`: a new `[ordered]` dictionary of the sixteen keys with the G32 defaults as strings (`HOST` is `''`). A dictionary is not unrolled by the pipeline, so `return $d` hands back the object.
  - `Test-TmuxkeepConfigValues -Values <IDictionary>`: throws the bare G32 reason (for example `PORT: must be an integer from 1 to 65535`) for the first invalid key in list order; returns nothing when all are valid.
  - `Read-TmuxkeepConfig -Path <string>`: returns the ordered dictionary; throws `config <Path>: <reason>` (G30, G31: `HOST` required, other keys default).
  - `ConvertTo-TmuxkeepConfigText -Values <IDictionary>`: the full file text, LF line endings.
  - `Write-TmuxkeepConfig -Path <string> -Values <IDictionary>`: writes that text as UTF-8 without BOM, creating the folder.
  - `New-TmuxkeepConfigInteractive -Path <string>`: one `Read-Host 'VPS address (hostname or IP)'`, trims spaces and tabs, validates, writes, returns the dictionary; throws `config <Path>: <reason>` and writes nothing on an invalid answer.
  - `ConvertTo-TmuxkeepDeployConf -Values <IDictionary>`: the `deploy.conf` text (spec 4.3), LF line endings.
  - `Expand-TmuxkeepPath -Path <string> -HomeDir <string>`: `~` alone becomes HomeDir; a leading `~/` or `~\` becomes HomeDir joined with the rest (slashes turned into backslashes) via `[IO.Path]::Combine` (not `Join-Path`, which fails on a drive that does not exist); anything else is returned unchanged.
  - Fixture `tests/fixtures/laptop-config`.

**Behaviour (spec 4.1, 4.2, 4.3; G30-G32; plan Q5, Q14; Review Focus 2):**
- Reading: `[IO.File]::ReadAllBytes`; BOM (`EF BB BF`) and any byte 13 are rejected first; then decode with Latin-1 (`[Text.Encoding]::GetEncoding(28591)`), which maps each byte to one char, split on `[char]10`, and apply G30 steps 2-7. Trim with `.Trim([char]32, [char]9)`. A value fails G30 step 5 when `$value -cmatch '[^\x20-\x7E]'`. Keys match case-sensitively (`-cnotcontains`, `-cnotmatch '^[A-Z_]+\z'`).
- Validation (G32), in list order, inside `Test-TmuxkeepConfigValues`:
  - `HOST`: empty gives `HOST: required`; exactly one `:` gives `HOST: looks like host:port; put the port in PORT`; not matching `^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}\z` (with `-cnotmatch`) gives `HOST: not a hostname, IPv4 or IPv6 address`;
  - integers through one helper `Assert-TmuxkeepInt -Key -Value -Lo -Hi`: value must match `^[0-9]{1,7}\z`, then `[int]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)` must be in range, else throw `<Key>: must be an integer from <Lo> to <Hi>`;
  - `OTP_HARD_MAX` uses `Lo` = the parsed `OTP_FAIL_MAX`.
- Messages built with the format operator or `${Path}:` (G16); a plain `"$Path: x"` would parse `$Path:` as a scope-qualified name.
- The file text written by `ConvertTo-TmuxkeepConfigText` is exactly the fixture below for `HOST=203.0.113.10` and the defaults: two header lines, one blank line, then for each key in order its comment line and `KEY=value`. The comment for each key is the line directly above it in the fixture.
- `ConvertTo-TmuxkeepDeployConf` writes the header line `# Written by tmuxkeep deploy from the laptop config; read by tmuxkeep-setup --conf.` then `KEY=value` for `USER LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES`, each line ending in LF.
- ASCII only (G11). No change to the main sequence.

- [ ] **Step 1: Create the fixture `tests/fixtures/laptop-config` with exactly this content (35 lines, LF, final newline)**

```
# tmuxkeep laptop configuration, written by the deploy script. Edit it by hand if you like:
# one KEY=value per line, no quotes. Run the deploy script again after a change.

# VPS address: hostname, IPv4 or IPv6 literal.
HOST=203.0.113.10
# SSH port of the VPS.
PORT=22
# Account on the VPS that owns the tmux sessions; the installer creates it.
USER=claude
# Session key, no passphrase. ~ is your home directory.
KEY=~/.ssh/id_tmuxkeep_ed25519
# Admin key for root, with a passphrase. Never add it to ssh-agent.
ADMIN_KEY=~/.ssh/id_tmuxkeep_admin_ed25519
# Typed into every new session; empty opens a shell only.
LAUNCH_CMD=claude
# Typed by resume; empty opens a shell only.
RESUME_CMD=claude --continue
# yes installs Claude Code for USER on the next deploy.
INSTALL_CLAUDE_CODE=no
# Seconds one TOTP code keeps the gated verbs open (60-86400).
LEASE_SECS=1800
# Seconds a removed session survives as a tombstone (3600-2592000).
TOMBSTONE_TTL=86400
# Wrong codes within OTP_FAIL_WINDOW that start a cooldown (1-20).
OTP_FAIL_MAX=3
# Seconds over which wrong codes are counted (60-86400).
OTP_FAIL_WINDOW=600
# Seconds of cooldown after OTP_FAIL_MAX wrong codes (10-86400).
OTP_COOLDOWN=300
# Wrong codes since the last good one that lock the gate until root clears it (OTP_FAIL_MAX-100).
OTP_HARD_MAX=10
# Seconds the VPS waits at the TOTP prompt (10-600).
OTP_READ_TIMEOUT=60
# Largest text that send accepts, in bytes (1-65536).
SEND_MAX_BYTES=8000
```

- [ ] **Step 2: Write the failing test `tests/pester/config.Tests.ps1`**

```powershell
# Pester tests for the laptop config functions in laptop/deploy.ps1 (spec 4.1, 4.2, 4.3; plan Q5,
# Q14; Review Focus 2). The script is dot-sourced, so only its functions are defined; main never runs.
Describe 'laptop config' {
    BeforeAll {
        $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        # Safety net first: fake external tools on PATH, and throwing mocks, before dot-sourcing.
        $script:FakeBin = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $FakeBin | Out-Null
        foreach ($n in 'ssh', 'scp', 'ssh-keygen') {
            Set-Content -LiteralPath (Join-Path $FakeBin "$n.cmd") -Value '@exit /b 99' -Encoding ascii
        }
        $script:OldPath = $env:PATH
        $env:PATH = "$FakeBin;$env:PATH"
        Mock ssh { throw 'ssh must not be called from tests' }
        Mock scp { throw 'scp must not be called from tests' }
        Mock ssh-keygen { throw 'ssh-keygen must not be called from tests' }
        . (Join-Path $Repo 'laptop\deploy.ps1')
        $script:FixturePath = Join-Path $Repo 'tests\fixtures\laptop-config'
        $script:Fixture = [IO.File]::ReadAllText($FixturePath)
        $script:DeployFixture = [IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\deploy.conf'))
        $script:Utf8 = New-Object System.Text.UTF8Encoding $false
        $script:AppendedLine = ([regex]::Matches($Fixture, "`n")).Count + 1

        function New-Cfg([string]$Text) {
            $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.cfg')
            [IO.File]::WriteAllText($p, $Text, $script:Utf8)
            return $p
        }
        function Set-Line([string]$Text, [string]$Key, [string]$Value) {
            $rx = '(?m)^' + [regex]::Escape($Key) + '=.*$'
            return [regex]::Replace($Text, $rx, ($Key + '=' + $Value).Replace('$', '$$'))
        }
        function Get-Reason([string]$Path) {
            try { Read-TmuxkeepConfig -Path $Path | Out-Null; return 'no error' }
            catch { return $_.Exception.Message }
        }
        function Get-InteractiveReason([string]$Path) {
            try { New-TmuxkeepConfigInteractive -Path $Path | Out-Null; return 'no error' }
            catch { return $_.Exception.Message }
        }
    }

    AfterAll { $env:PATH = $OldPath }

    It 'reads the fixture into the sixteen keys, in file order' {
        $v = Read-TmuxkeepConfig -Path (New-Cfg $Fixture)
        (@($v.Keys) -join ' ') | Should -BeExactly 'HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES'
        $v['HOST'] | Should -BeExactly '203.0.113.10'
        $v['PORT'] | Should -BeExactly '22'
        $v['KEY'] | Should -BeExactly '~/.ssh/id_tmuxkeep_ed25519'
        $v['RESUME_CMD'] | Should -BeExactly 'claude --continue'
    }

    It 'Write-TmuxkeepConfig reproduces the fixture byte for byte, creating the folder' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '203.0.113.10'
        $p = Join-Path $TestDrive 'new dir\.tmuxkeep\config'
        Write-TmuxkeepConfig -Path $p -Values $v
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly ([IO.File]::ReadAllBytes($FixturePath) -join ',')
    }

    It 'a missing key other than HOST takes its default; a missing HOST is required' {
        $v = Read-TmuxkeepConfig -Path (New-Cfg ([regex]::Replace($Fixture, '(?m)^PORT=.*\n', '')))
        $v['PORT'] | Should -BeExactly '22'
        $p = New-Cfg ([regex]::Replace($Fixture, '(?m)^HOST=.*\n', ''))
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': HOST: required')
    }

    It 'skips blank and comment lines, trims padding, and lets the last repeated key win' {
        $padded = [regex]::Replace($Fixture, '(?m)^([A-Z_]+)=(.*)$', ('  $1 =' + "`t" + '$2 ' + "`t"))
        $v = Read-TmuxkeepConfig -Path (New-Cfg ("`n# note`n  `t `n" + $padded + "PORT=2200`nPORT=2222`n"))
        $v['PORT'] | Should -BeExactly '2222'
        $v['HOST'] | Should -BeExactly '203.0.113.10'
        $v['RESUME_CMD'] | Should -BeExactly 'claude --continue'
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'an empty HOST';              Key = 'HOST';                Value = '';                  Reason = 'HOST: required' }
        @{ Name = 'host:port';                  Key = 'HOST';                Value = '203.0.113.10:2222'; Reason = 'HOST: looks like host:port; put the port in PORT' }
        @{ Name = 'a user@host address';        Key = 'HOST';                Value = 'you@203.0.113.10';  Reason = 'HOST: not a hostname, IPv4 or IPv6 address' }
        @{ Name = 'a HOST starting with -';     Key = 'HOST';                Value = '-x.example';        Reason = 'HOST: not a hostname, IPv4 or IPv6 address' }
        @{ Name = 'PORT 0';                     Key = 'PORT';                Value = '0';                 Reason = 'PORT: must be an integer from 1 to 65535' }
        @{ Name = 'PORT 65536';                 Key = 'PORT';                Value = '65536';             Reason = 'PORT: must be an integer from 1 to 65535' }
        @{ Name = 'PORT ssh';                   Key = 'PORT';                Value = 'ssh';               Reason = 'PORT: must be an integer from 1 to 65535' }
        @{ Name = 'USER Bob';                   Key = 'USER';                Value = 'Bob';               Reason = 'USER: must match ^[a-z_][a-z0-9_-]{0,31}$' }
        @{ Name = 'an empty KEY';               Key = 'KEY';                 Value = '';                  Reason = 'KEY: must be a non-empty path without double quotes' }
        @{ Name = 'a KEY with a double quote';  Key = 'KEY';                 Value = 'a"b';               Reason = 'KEY: must be a non-empty path without double quotes' }
        @{ Name = 'an empty ADMIN_KEY';         Key = 'ADMIN_KEY';           Value = '';                  Reason = 'ADMIN_KEY: must be a non-empty path without double quotes' }
        @{ Name = 'a 201-character LAUNCH_CMD'; Key = 'LAUNCH_CMD';          Value = ('x' * 201);         Reason = 'LAUNCH_CMD: at most 200 characters' }
        @{ Name = 'a 201-character RESUME_CMD'; Key = 'RESUME_CMD';          Value = ('x' * 201);         Reason = 'RESUME_CMD: at most 200 characters' }
        @{ Name = 'INSTALL_CLAUDE_CODE Yes';    Key = 'INSTALL_CLAUDE_CODE'; Value = 'Yes';               Reason = 'INSTALL_CLAUDE_CODE: must be yes or no' }
        @{ Name = 'LEASE_SECS 59';              Key = 'LEASE_SECS';          Value = '59';                Reason = 'LEASE_SECS: must be an integer from 60 to 86400' }
        @{ Name = 'LEASE_SECS 86401';           Key = 'LEASE_SECS';          Value = '86401';             Reason = 'LEASE_SECS: must be an integer from 60 to 86400' }
        @{ Name = 'LEASE_SECS -60';             Key = 'LEASE_SECS';          Value = '-60';               Reason = 'LEASE_SECS: must be an integer from 60 to 86400' }
        @{ Name = 'LEASE_SECS of eight digits'; Key = 'LEASE_SECS';          Value = '00001800';          Reason = 'LEASE_SECS: must be an integer from 60 to 86400' }
        @{ Name = 'TOMBSTONE_TTL 3599';         Key = 'TOMBSTONE_TTL';       Value = '3599';              Reason = 'TOMBSTONE_TTL: must be an integer from 3600 to 2592000' }
        @{ Name = 'TOMBSTONE_TTL 2592001';      Key = 'TOMBSTONE_TTL';       Value = '2592001';           Reason = 'TOMBSTONE_TTL: must be an integer from 3600 to 2592000' }
        @{ Name = 'OTP_FAIL_MAX 0';             Key = 'OTP_FAIL_MAX';        Value = '0';                 Reason = 'OTP_FAIL_MAX: must be an integer from 1 to 20' }
        @{ Name = 'OTP_FAIL_MAX 21';            Key = 'OTP_FAIL_MAX';        Value = '21';                Reason = 'OTP_FAIL_MAX: must be an integer from 1 to 20' }
        @{ Name = 'OTP_FAIL_WINDOW 59';         Key = 'OTP_FAIL_WINDOW';     Value = '59';                Reason = 'OTP_FAIL_WINDOW: must be an integer from 60 to 86400' }
        @{ Name = 'OTP_COOLDOWN 9';             Key = 'OTP_COOLDOWN';        Value = '9';                 Reason = 'OTP_COOLDOWN: must be an integer from 10 to 86400' }
        @{ Name = 'OTP_HARD_MAX 2';             Key = 'OTP_HARD_MAX';        Value = '2';                 Reason = 'OTP_HARD_MAX: must be an integer from 3 to 100' }
        @{ Name = 'OTP_HARD_MAX 101';           Key = 'OTP_HARD_MAX';        Value = '101';               Reason = 'OTP_HARD_MAX: must be an integer from 3 to 100' }
        @{ Name = 'OTP_READ_TIMEOUT 601';       Key = 'OTP_READ_TIMEOUT';    Value = '601';               Reason = 'OTP_READ_TIMEOUT: must be an integer from 10 to 600' }
        @{ Name = 'SEND_MAX_BYTES 0';           Key = 'SEND_MAX_BYTES';      Value = '0';                 Reason = 'SEND_MAX_BYTES: must be an integer from 1 to 65536' }
        @{ Name = 'SEND_MAX_BYTES 65537';       Key = 'SEND_MAX_BYTES';      Value = '65537';             Reason = 'SEND_MAX_BYTES: must be an integer from 1 to 65536' }
    ) {
        $p = New-Cfg (Set-Line $Fixture $Key $Value)
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': ' + $Reason)
    }

    It 'accepts <Name>' -ForEach @(
        @{ Name = 'an IPv6 literal';        Key = 'HOST';           Value = '2001:db8::1' }
        @{ Name = 'a hostname';             Key = 'HOST';           Value = 'vps-1.example.org' }
        @{ Name = 'PORT 65535';             Key = 'PORT';           Value = '65535' }
        @{ Name = 'USER _svc';              Key = 'USER';           Value = '_svc' }
        @{ Name = 'a KEY with a space';     Key = 'KEY';            Value = '~/my keys/k' }
        @{ Name = 'an empty LAUNCH_CMD';    Key = 'LAUNCH_CMD';     Value = '' }
        @{ Name = 'LEASE_SECS 0060';        Key = 'LEASE_SECS';     Value = '0060' }
        @{ Name = 'TOMBSTONE_TTL 2592000';  Key = 'TOMBSTONE_TTL';  Value = '2592000' }
        @{ Name = 'OTP_HARD_MAX 3';         Key = 'OTP_HARD_MAX';   Value = '3' }
        @{ Name = 'SEND_MAX_BYTES 65536';   Key = 'SEND_MAX_BYTES'; Value = '65536' }
    ) {
        Get-Reason (New-Cfg (Set-Line $Fixture $Key $Value)) | Should -BeExactly 'no error'
    }

    It 'rejects a BOM, a CR, a line without =, an unknown key and non-printable values, naming the file' {
        $n = $AppendedLine
        $p = Join-Path $TestDrive 'bom.cfg'
        [IO.File]::WriteAllBytes($p, [byte[]](@(0xEF, 0xBB, 0xBF) + @([Text.Encoding]::ASCII.GetBytes($Fixture))))
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': byte order mark found (save without BOM)')
        $p = New-Cfg ($Fixture.Replace("`n", "`r`n"))
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': carriage return found (use LF line endings)')
        $p = New-Cfg ($Fixture + "just words`n")
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': line ' + $n + ': expected KEY=value')
        $p = New-Cfg ($Fixture + "FROB=1`n")
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': line ' + $n + ': unknown key FROB')
        $p = New-Cfg ($Fixture + "host=x`n")
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': line ' + $n + ': unknown key host')
        $p = New-Cfg ($Fixture + "B@D=1`n")
        Get-Reason $p | Should -BeExactly ('config ' + $p + ': line ' + $n + ': unknown key')
        $p = New-Cfg (Set-Line $Fixture 'LAUNCH_CMD' ('caf' + [char]0x00E9))
        Get-Reason $p | Should -Match ([regex]::Escape(': non-printable or non-ASCII character in LAUNCH_CMD') + '$')
        $p = New-Cfg (Set-Line $Fixture 'LAUNCH_CMD' ("a`tb"))
        Get-Reason $p | Should -Match ([regex]::Escape(': non-printable or non-ASCII character in LAUNCH_CMD') + '$')
    }

    It 'New-TmuxkeepConfigInteractive asks once, trims the answer and writes the fixture' {
        Mock Read-Host { ' 203.0.113.10 ' } -ParameterFilter { $Prompt -eq 'VPS address (hostname or IP)' }
        $p = Join-Path $TestDrive 'first run\config'
        $v = New-TmuxkeepConfigInteractive -Path $p
        Should -Invoke Read-Host -Times 1 -Exactly
        $v['HOST'] | Should -BeExactly '203.0.113.10'
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly ([IO.File]::ReadAllBytes($FixturePath) -join ',')
    }

    It 'New-TmuxkeepConfigInteractive rejects <Name> and writes nothing (Review Focus 2)' -ForEach @(
        @{ Name = 'host:port';       Answer = '203.0.113.10:2222'; Reason = 'HOST: looks like host:port; put the port in PORT' }
        @{ Name = 'user@host';       Answer = 'you@203.0.113.10';  Reason = 'HOST: not a hostname, IPv4 or IPv6 address' }
        @{ Name = 'an empty answer'; Answer = '';                  Reason = 'HOST: required' }
        @{ Name = 'only spaces';     Answer = '   ';               Reason = 'HOST: required' }
    ) {
        $script:NextAnswer = $Answer
        Mock Read-Host { $script:NextAnswer }
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '\config')
        Get-InteractiveReason $p | Should -BeExactly ('config ' + $p + ': ' + $Reason)
        Test-Path -LiteralPath $p | Should -BeFalse
    }

    It 'ConvertTo-TmuxkeepDeployConf on the defaults is the deploy.conf fixture' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '203.0.113.10'
        ConvertTo-TmuxkeepDeployConf -Values $v | Should -BeExactly $DeployFixture
    }

    It 'ConvertTo-TmuxkeepDeployConf carries the configured values and nothing laptop-only' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '198.51.100.20'
        $v['USER'] = 'bob'
        $v['LAUNCH_CMD'] = ''
        $v['LEASE_SECS'] = '600'
        $t = ConvertTo-TmuxkeepDeployConf -Values $v
        $t | Should -Match '(?m)^USER=bob$'
        $t | Should -Match '(?m)^LAUNCH_CMD=$'
        $t | Should -Match '(?m)^LEASE_SECS=600$'
        $t | Should -Not -Match 'HOST|PORT|KEY='
    }

    It 'Expand-TmuxkeepPath expands only a leading tilde' {
        Expand-TmuxkeepPath -Path '~/.ssh/k' -HomeDir 'C:\h' | Should -BeExactly 'C:\h\.ssh\k'
        Expand-TmuxkeepPath -Path '~\.ssh\k' -HomeDir 'C:\h' | Should -BeExactly 'C:\h\.ssh\k'
        Expand-TmuxkeepPath -Path '~' -HomeDir 'C:\h' | Should -BeExactly 'C:\h'
        Expand-TmuxkeepPath -Path 'D:\keys\k' -HomeDir 'C:\h' | Should -BeExactly 'D:\keys\k'
        Expand-TmuxkeepPath -Path 'a~/k' -HomeDir 'C:\h' | Should -BeExactly 'a~/k'
    }

    It 'the key list is one line the parity test can read' {
        @([IO.File]::ReadAllLines((Join-Path $Repo 'laptop\deploy.ps1')) | Where-Object { $_ -clike 'function Get-TmuxkeepConfigKeys *' }).Count | Should -Be 1
    }
}
```

- [ ] **Step 3: Run to see it fail**

Run the G6 command with `$c.Run.Path = 'tests\pester\config.Tests.ps1'`.
Expected: failures (the functions do not exist).

- [ ] **Step 4: Implement the functions in `laptop/deploy.ps1`**

- [ ] **Step 5: Run until green**

- `tests\pester\config.Tests.ps1`: 53 tests (13 `It` blocks, the `-ForEach` ones expanded), 0 failed.
- the whole Pester folder and the whole bats directory (G8). `tests\pester\static.Tests.ps1` now also covers the new test file (ASCII, parses).

- [ ] **Step 6: Line endings, commit**

```bash
grep -lU "$(printf '\r')" tests/fixtures/laptop-config tests/pester/config.Tests.ps1    # Git Bash; must print nothing
git add laptop/deploy.ps1 tests/fixtures/laptop-config tests/pester/config.Tests.ps1
git commit -m "deploy.ps1: laptop config read, write, first-run prompt and deploy.conf text"
```

---

### Task 8: PowerShell deploy: write-or-replace marked blocks

Suggested model: sonnet.

**Files:**
- Create: `tests/fixtures/ssh-block`
- Modify: `laptop/deploy.ps1` (new functions only; the v1 `Add-Tmuxkeep*` functions and the main sequence stay until Task 9)
- Modify: `tests/pester/deploy.Tests.ps1` (append four `Describe` blocks)

**Interfaces:**
- Consumes (Task 7): `Get-TmuxkeepConfigDefaults` (an `[ordered]` dictionary of string values, `HOST` empty). From v1: the file-level `BeforeAll` of `deploy.Tests.ps1` (`$script:Repo`, the fake `ssh`/`scp`/`ssh-keygen`, the dot-sourced script).
- Produces (Task 9 wires them into the main sequence; Task 13 mirrors them in bash):
  - `ConvertTo-TmuxkeepSshValue -Value <string>`: the value, wrapped in double quotes when it contains a space (plan Q10).
  - `Get-TmuxkeepSshBlock -Config <IDictionary>`: the 16 lines of the spec 6.1 block (no line endings).
  - `Set-TmuxkeepMarkedBlock -Path <string> -Lines <string[]>`: write-or-replace (spec 6.1 step 3) with CRLF line endings. Lines must start with `# >>> tmuxkeep` and end with `# <<< tmuxkeep`; `-Lines` carries `[AllowEmptyString()]` because the profile snippet has blank lines.
  - `Set-TmuxkeepHostBlock -ConfigPath <string> -Config <IDictionary>`.
  - `Set-TmuxkeepProfileSnippet -ProfilePath <string> -SnippetPath <string>` (write-or-replace too, plan Q9).
  - Fixture `tests/fixtures/ssh-block` (Task 13's bash block must equal it with LF).

**Behaviour (spec 6.1 step 3, 6.3; plan Q9, Q10):**
- `Get-TmuxkeepSshBlock` returns exactly these lines, with `<HOST>`, `<PORT>`, `<USER>` taken from the config and `<KEY>`, `<ADMIN_KEY>` passed through `ConvertTo-TmuxkeepSshValue` (written as configured, `~` not expanded, because ssh expands `~/` itself on every platform):

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

  No `AddKeysToAgent` on either host (G3).
- `Set-TmuxkeepMarkedBlock`:
  1. Throws unless `Lines[0]` is `# >>> tmuxkeep` and the last line is `# <<< tmuxkeep`, or if any line has a character above 127.
  2. If the file exists and starts with `FF FE` or `FE FF`, throws `<Path> is UTF-16; convert it to UTF-8 or ASCII first` and leaves it untouched.
  3. Reads the bytes and decodes them with Latin-1 (`[Text.Encoding]::GetEncoding(28591)`), which maps every byte to one char and back, so UTF-8 content, a BOM and any line endings outside the block survive byte for byte.
  4. Counts lines matching `(?m)^# >>> tmuxkeep\r?$`. More than one: throw `<Path> has more than one '# >>> tmuxkeep' line; remove the extra block by hand`. The exact-line match means a longer marker such as `# >>> tmuxkeep path` is not ours.
  5. Finds the block with `(?ms)^# >>> tmuxkeep\r?\n.*?^# <<< tmuxkeep\r?(\n|\z)`. A begin line without a matching block: throw `<Path> has '# >>> tmuxkeep' without '# <<< tmuxkeep'; fix it by hand`.
  6. New block text = the lines joined with CRLF plus a final CRLF. Found: replace the match in place. Not found: append; when the file is non-empty, first add CRLF if it does not end with LF, then one more CRLF (a blank line).
  7. If the new text equals the old text (case-sensitive), return without writing (the file's time stamp does not change).
  8. Creates the folder if needed and writes with `[IO.File]::WriteAllBytes($full, $latin1.GetBytes($new))`, which writes through a symlink.
- `Set-TmuxkeepHostBlock` is `Set-TmuxkeepMarkedBlock -Path $ConfigPath -Lines @(Get-TmuxkeepSshBlock -Config $Config)`. `Set-TmuxkeepProfileSnippet` reads the snippet with `@(Get-Content -LiteralPath $SnippetPath -ErrorAction Stop)` and passes those lines.
- ASCII only. Do not touch the main sequence or the `Add-Tmuxkeep*` functions in this task.

- [ ] **Step 1: Create the fixture `tests/fixtures/ssh-block` with exactly this content (16 lines, LF, final newline)**

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
# <<< tmuxkeep
```

- [ ] **Step 2: Append the failing tests to `tests/pester/deploy.Tests.ps1`** (after the last `Describe` block)

```powershell

Describe 'Set-TmuxkeepMarkedBlock' {
    BeforeAll {
        $script:Block = @('# >>> tmuxkeep', 'line one', '# <<< tmuxkeep')
        $script:BlockText = "# >>> tmuxkeep`r`nline one`r`n# <<< tmuxkeep`r`n"
    }

    It 'creates a missing file and its folder, with CRLF lines' {
        $p = Join-Path $TestDrive 'mb new dir\f'
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        [IO.File]::ReadAllText($p) | Should -BeExactly $BlockText
    }

    It 'appends after a blank line, adding a missing final newline first' {
        $p = Join-Path $TestDrive 'mb-append'
        [IO.File]::WriteAllText($p, "Host x`n    HostName 198.51.100.20")
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        [IO.File]::ReadAllText($p) | Should -BeExactly ("Host x`n    HostName 198.51.100.20`r`n`r`n" + $BlockText)
    }

    It 'replaces a changed block in place and keeps every byte around it' {
        $p = Join-Path $TestDrive 'mb-replace'
        $e = [string][char]0x00E9
        [IO.File]::WriteAllBytes($p, [Text.Encoding]::UTF8.GetBytes("top$e`r`n# >>> tmuxkeep`r`nold`r`n# <<< tmuxkeep`r`nbottom`n"))
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($p)) | Should -BeExactly ("top$e`r`n" + $BlockText + "bottom`n")
    }

    It 'replaces an LF-only block at the very end of a file without a final newline' {
        $p = Join-Path $TestDrive 'mb-lf'
        [IO.File]::WriteAllText($p, "a`n# >>> tmuxkeep`nold`n# <<< tmuxkeep")
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        [IO.File]::ReadAllText($p) | Should -BeExactly ("a`n" + $BlockText)
    }

    It 'leaves a file with an identical block untouched' {
        $p = Join-Path $TestDrive 'mb-same'
        [IO.File]::WriteAllText($p, "x`r`n`r`n" + $BlockText)
        (Get-Item -LiteralPath $p).LastWriteTimeUtc = [DateTime]::new(2001, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        (Get-Item -LiteralPath $p).LastWriteTimeUtc.Year | Should -Be 2001
    }

    It 'refuses <Name> and leaves the file untouched' -ForEach @(
        @{ Name = 'two begin markers';                    Text = "# >>> tmuxkeep`n1`n# <<< tmuxkeep`n# >>> tmuxkeep`n2`n# <<< tmuxkeep`n" }
        @{ Name = 'a begin marker without an end marker'; Text = "x`n# >>> tmuxkeep`nold`n" }
    ) {
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($p, $Text)
        $before = [IO.File]::ReadAllBytes($p) -join ','
        { Set-TmuxkeepMarkedBlock -Path $p -Lines $Block } | Should -Throw
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly $before
    }

    It 'refuses a UTF-16 file and a non-ASCII block line, writing nothing' {
        $p = Join-Path $TestDrive 'mb-utf16'
        [IO.File]::WriteAllText($p, "Host x`r`n", [Text.Encoding]::Unicode)
        $before = [IO.File]::ReadAllBytes($p) -join ','
        { Set-TmuxkeepMarkedBlock -Path $p -Lines $Block } | Should -Throw
        ([IO.File]::ReadAllBytes($p) -join ',') | Should -BeExactly $before
        $q = Join-Path $TestDrive 'mb-ascii'
        { Set-TmuxkeepMarkedBlock -Path $q -Lines @('# >>> tmuxkeep', ('caf' + [char]0x00E9), '# <<< tmuxkeep') } | Should -Throw
        Test-Path -LiteralPath $q | Should -BeFalse
    }

    It 'does not take a longer marker, such as the VPS PATH block, for its own' {
        $p = Join-Path $TestDrive 'mb-longer'
        [IO.File]::WriteAllText($p, "# >>> tmuxkeep path`nx`n# <<< tmuxkeep path`n")
        Set-TmuxkeepMarkedBlock -Path $p -Lines $Block
        [IO.File]::ReadAllText($p) | Should -BeExactly ("# >>> tmuxkeep path`nx`n# <<< tmuxkeep path`n`r`n" + $BlockText)
    }
}

Describe 'Get-TmuxkeepSshBlock' {
    It 'renders the fixture block for the default config' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '203.0.113.10'
        $expected = [IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\ssh-block')).TrimEnd("`n").Split([char]10)
        (@(Get-TmuxkeepSshBlock -Config $v) -join '|') | Should -BeExactly ($expected -join '|')
    }

    It 'takes HOST, PORT, USER and both keys from the config, quoting a key path with a space (plan Q10)' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '2001:db8::5'
        $v['PORT'] = '2222'
        $v['USER'] = 'bob'
        $v['KEY'] = '~/my keys/k'
        $v['ADMIN_KEY'] = 'C:\keys\admin'
        $b = @(Get-TmuxkeepSshBlock -Config $v)
        $b.Count | Should -Be 16
        $b[2] | Should -BeExactly '    HostName 2001:db8::5'
        $b[3] | Should -BeExactly '    Port 2222'
        $b[4] | Should -BeExactly '    User bob'
        $b[5] | Should -BeExactly '    IdentityFile "~/my keys/k"'
        $b[10] | Should -BeExactly '    HostName 2001:db8::5'
        $b[12] | Should -BeExactly '    User root'
        $b[13] | Should -BeExactly '    IdentityFile C:\keys\admin'
        ($b -join "`n") | Should -Not -Match 'AddKeysToAgent'
    }
}

Describe 'Set-TmuxkeepHostBlock' {
    It 'writes both hosts into ssh config, then replaces them in place when HOST changes (spec 6.1 step 3)' {
        $cfgPath = Join-Path $TestDrive 'hb home\.ssh\config'
        New-Item -ItemType Directory -Path (Split-Path $cfgPath) | Out-Null
        [IO.File]::WriteAllText($cfgPath, "Host other`n    HostName 198.51.100.7`n")
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '203.0.113.10'
        Set-TmuxkeepHostBlock -ConfigPath $cfgPath -Config $v
        $fixture = [IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\ssh-block')).Replace("`n", "`r`n")
        [IO.File]::ReadAllText($cfgPath) | Should -BeExactly ("Host other`n    HostName 198.51.100.7`n`r`n" + $fixture)
        $v['HOST'] = '198.51.100.20'
        Set-TmuxkeepHostBlock -ConfigPath $cfgPath -Config $v
        $text = [IO.File]::ReadAllText($cfgPath)
        ([regex]::Matches($text, '(?m)^# >>> tmuxkeep\r?$')).Count | Should -Be 1
        ([regex]::Matches($text, '(?m)^    HostName 198\.51\.100\.20\r?$')).Count | Should -Be 2
        $text | Should -Not -Match '203\.0\.113\.10'
        $text | Should -Match '^Host other\n'
    }
}

Describe 'Set-TmuxkeepProfileSnippet (a profile path with spaces, v1 Review Focus 5)' {
    It 'writes the snippet once to a profile path with spaces, creating folders' {
        $p = Join-Path $TestDrive 'Cloud Drive\My Docs\Docs\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
        $snippet = Join-Path $Repo 'laptop\profile-snippet.ps1'
        Set-TmuxkeepProfileSnippet -ProfilePath $p -SnippetPath $snippet
        Set-TmuxkeepProfileSnippet -ProfilePath $p -SnippetPath $snippet
        $text = [IO.File]::ReadAllText($p)
        ([regex]::Matches($text, '(?m)^# >>> tmuxkeep\r?$')).Count | Should -Be 1
        $text | Should -Match ([regex]::Escape('Register-ArgumentCompleter -Native -CommandName tmuxkeep'))
    }

    It 'replaces an older snippet in place and keeps the rest of the profile (plan Q9)' {
        $p = Join-Path $TestDrive 'prof2\a b.ps1'
        New-Item -ItemType Directory -Path (Split-Path $p) | Out-Null
        [IO.File]::WriteAllText($p, "Set-Alias ll Get-ChildItem`r`n# >>> tmuxkeep`r`nfunction global:tmuxkeep { 'old' }`r`n# <<< tmuxkeep`r`nSet-Alias gs git`r`n")
        Set-TmuxkeepProfileSnippet -ProfilePath $p -SnippetPath (Join-Path $Repo 'laptop\profile-snippet.ps1')
        $text = [IO.File]::ReadAllText($p)
        $text | Should -Match '^Set-Alias ll Get-ChildItem\r\n# >>> tmuxkeep\r\n'
        $text | Should -Match 'Set-Alias gs git\r\n$'
        $text | Should -Not -Match "'old'"
    }

    It 'refuses a UTF-16 profile' {
        $u = Join-Path $TestDrive 'prof3\u16.ps1'
        New-Item -ItemType Directory -Path (Split-Path $u) | Out-Null
        [IO.File]::WriteAllText($u, "# x`r`n", [Text.Encoding]::Unicode)
        { Set-TmuxkeepProfileSnippet -ProfilePath $u -SnippetPath (Join-Path $Repo 'laptop\profile-snippet.ps1') } | Should -Throw
    }
}
```

- [ ] **Step 3: Run to see them fail**

Run the G6 command with `$c.Run.Path = 'tests\pester\deploy.Tests.ps1'`.
Expected: the 15 new tests fail (the functions do not exist); the v1 tests still pass.

- [ ] **Step 4: Implement the five functions in `laptop/deploy.ps1`**

- [ ] **Step 5: Run until green**

- `tests\pester\deploy.Tests.ps1`: every test passes (the v1 ones and the 15 new ones).
- the whole Pester folder and the whole bats directory (G8).

- [ ] **Step 6: Line endings, commit**

```bash
grep -lU "$(printf '\r')" tests/fixtures/ssh-block tests/pester/deploy.Tests.ps1    # Git Bash; must print nothing
git add laptop/deploy.ps1 tests/fixtures/ssh-block tests/pester/deploy.Tests.ps1
git commit -m "deploy.ps1: write-or-replace marked blocks, two-host ssh block, profile snippet"
```

---

### Task 9: PowerShell deploy: staging, setup command, admin help, main sequence

Suggested model: sonnet. Admin path and the never-capture rule; the orchestrator should have Opus review the diff.

**Files:**
- Modify: `laptop/deploy.ps1` (param block, staging, setup command, admin help, main sequence; delete `Add-TmuxkeepMarkedBlock`, `Add-TmuxkeepHostBlock`, `Add-TmuxkeepProfileSnippet`, `Show-TmuxkeepAdminHelp`)
- Modify: `tests/pester/deploy.Tests.ps1` (replace six `Describe` blocks, add one)

**Interfaces:**
- Consumes: Task 7 (`Get-TmuxkeepConfigDefaults`, `Read-TmuxkeepConfig`, `New-TmuxkeepConfigInteractive`, `ConvertTo-TmuxkeepDeployConf`, `Expand-TmuxkeepPath`, fixtures `tests/fixtures/laptop-config` and `tests/fixtures/deploy.conf`); Task 8 (`Set-TmuxkeepHostBlock`, `Set-TmuxkeepProfileSnippet`, `Set-TmuxkeepMarkedBlock`, fixture `tests/fixtures/ssh-block`, whose 16 lines are listed in Task 8); Task 5/6 installer command line `tmuxkeep-setup --pubkey-file <path> --key-id laptop --conf <file> [--harden-root] [--rotate-totp] [--unlock-otp]`; v1 helpers `ConvertTo-TmuxkeepLf`, `Write-TmuxkeepLfFile`, `Get-TmuxkeepVersion`.
- Produces:
  - Operator command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 [-Config <path>] [-Init] [-HardenRoot] [-RotateTotp] [-UnlockOtp]`, plus two test seams, `-HomeDir <path>` (default `$HOME`) and `-ProfilePath <path>` (default `$PROFILE`) (plan Q12).
  - `Get-TmuxkeepVpsFiles`, written as one line exactly `function Get-TmuxkeepVpsFiles { @('tmuxkeep', 'tmuxkeep-setup', 'vps-facts.sh', 'sshd.conf.tmpl', 'sudoers.tmpl', 'tmux.conf', 'systemd/tmuxkeep-reaper.service', 'systemd/tmuxkeep-reaper.timer') }` (Task 15 parses it).
  - `New-TmuxkeepStaging -RepoRoot -Version -PubKeyPath -Config <IDictionary> -Destination`: writes the eight VPS files, `laptop.pub` and `deploy.conf`, all LF without BOM.
  - `Get-TmuxkeepSetupCommand -StageName [-HardenRoot] [-RotateTotp] [-UnlockOtp]`: returns the remote command (plan Q4).
  - `Get-TmuxkeepAdminHelp -Config <IDictionary> -HomeDir <string>`: returns the six help lines (spec 6.5, plan Q11).

**Behaviour (spec 6.1, 6.3, 6.5, 12; plan Q4, Q11, Q12):**
- File shape: comment header, `param(...)`, `function Get-TmuxkeepVpsFiles ...`, the other functions, the dot-source guard, the main sequence. Header comment:

  ```powershell
  # Operator deploy script for tmuxkeep (spec 6.1, 6.3). Windows PowerShell 5.1, ASCII only.
  #   powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 [-Config <path>] [-Init] [-HardenRoot] [-RotateTotp] [-UnlockOtp]
  # -HomeDir and -ProfilePath exist for the tests and default to $HOME and $PROFILE.
  # Agents never run this script themselves. The Pester tests dot-source it (functions only) and
  # run it in a child powershell.exe with stub ssh, scp and ssh-keygen first on PATH.
  param(
      [string]$Config = '',
      [switch]$Init,
      [switch]$HardenRoot,
      [switch]$RotateTotp,
      [switch]$UnlockOtp,
      [string]$HomeDir = $HOME,
      [string]$ProfilePath = $PROFILE
  )
  ```

- `New-TmuxkeepStaging` keeps v1's rules (version must match `^[0-9a-f]{4,40}(-dirty)?\z`; exactly one `(?m)^TMUXKEEP_VERSION=dev$` line in `vps/tmuxkeep`, replaced by `TMUXKEEP_VERSION=<Version>`; every file through `ConvertTo-TmuxkeepLf` and `Write-TmuxkeepLfFile`; nothing written unless every input is good), takes its list from `Get-TmuxkeepVpsFiles`, stages the public key as `laptop.pub`, and stages `ConvertTo-TmuxkeepDeployConf -Values $Config` as `deploy.conf`.
- `Get-TmuxkeepSetupCommand`: the stage name must match `^tmuxkeep-deploy-[0-9]{14}\z`, else throw; flags are appended in the fixed order ` --harden-root`, ` --rotate-totp`, ` --unlock-otp`; the string comes from a single-quoted format string, so `$?` and `$rc` stay literal for the remote shell and it contains no double quote:

  ```powershell
  'bash /root/{0}/tmuxkeep-setup --pubkey-file /root/{0}/laptop.pub --key-id laptop --conf /root/{0}/deploy.conf{1}; rc=$?; rm -rf /root/{0}; exit $rc' -f $StageName, $flags
  ```

- `Get-TmuxkeepAdminHelp` returns, in order (plan Q11):
  1. `1. ssh-keygen -t ed25519 -f <A> -C tmuxkeep-admin        (set a passphrase)` where `<A>` is `Expand-TmuxkeepPath -Path $Config['ADMIN_KEY'] -HomeDir $HomeDir`, wrapped in double quotes when it contains a space (PowerShell does not expand `~` for native programs);
  2. `2. Install it on the VPS with one password login:`;
  3. `   ssh root@<HOST> -p <PORT> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && echo <PUB> >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"`, where `<PUB>` is the first line of `<A>.pub` (trimmed) when that file exists and the line matches `^ssh-ed25519 [A-Za-z0-9+/=]+( [A-Za-z0-9@._-]+)?\z`, and otherwise the literal text `<contents of <ADMIN_KEY>.pub>` with the configured (unexpanded) `ADMIN_KEY`, for example `<contents of ~/.ssh/id_tmuxkeep_admin_ed25519.pub>`;
  4. `3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true`;
  5. an empty line;
  6. `Never ssh-add the admin key and never set AddKeysToAgent for it.`
- Main sequence, after the guard. Write it exactly in this order (spec 6.1 steps 0-9); every message goes through `Write-Host`; no native command is captured or has its stderr redirected (G3, G17):

  ```powershell
  # ---- Main (operator only) --------------------------------------------------------------
  # Only Windows PowerShell 5.1 passes the '""' passphrase below the way this script expects. From
  # pwsh 7.3 on, the same argument reaches ssh-keygen as a literal two-character passphrase.
  if ($PSVersionTable.PSEdition -ne 'Desktop') {
      Write-Host 'deploy: run this with Windows PowerShell 5.1 (powershell.exe), not pwsh'
      exit 2
  }
  $ErrorActionPreference = 'Stop'
  $repo = Split-Path -Parent $PSScriptRoot
  if (-not $Config) { $Config = Join-Path $HomeDir '.tmuxkeep\config' }

  # 0. Preflight: the tools, a git checkout, and a config that parses if it exists.
  $missing = @(foreach ($t in 'ssh', 'scp', 'ssh-keygen', 'git') { if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $t } })
  if ($missing.Count -gt 0) { Write-Host ('deploy: missing required tools: ' + ($missing -join ' ')); exit 2 }
  & git -C $repo rev-parse --is-inside-work-tree | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host "deploy: not a git checkout: $repo"; exit 2 }
  $cfg = $null
  if (Test-Path -LiteralPath $Config -PathType Leaf) {
      try { $cfg = Read-TmuxkeepConfig -Path $Config }
      catch { Write-Host ('deploy: ' + $_.Exception.Message); exit 2 }
  }

  # 1. Config: the one first-run question (spec 4.2).
  if ($null -eq $cfg) {
      try { $cfg = New-TmuxkeepConfigInteractive -Path $Config }
      catch { Write-Host ('deploy: ' + $_.Exception.Message); exit 2 }
      Write-Host "deploy: wrote $Config"
  }

  # 2. The laptop key (no passphrase: the broker's TOTP code is the second factor).
  $key = Expand-TmuxkeepPath -Path $cfg['KEY'] -HomeDir $HomeDir
  if (-not (Test-Path -LiteralPath $key)) {
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $key))
      # The '""' is required in 5.1: an empty argument is dropped, and the literal "" reaches
      # ssh-keygen as an empty passphrase.
      & ssh-keygen -t ed25519 -f $key -C tmuxkeep-laptop -N '""'
      if ($LASTEXITCODE -ne 0) { Write-Host "deploy: ssh-keygen failed with exit $LASTEXITCODE"; exit $LASTEXITCODE }
  }
  if (-not (Test-Path -LiteralPath "$key.pub")) {
      Write-Host "deploy: $key.pub is missing. Move $key aside and run deploy again to make a new pair."
      exit 1
  }

  # 3. Both Host blocks in ~/.ssh/config, written or replaced.
  try { Set-TmuxkeepHostBlock -ConfigPath (Join-Path $HomeDir '.ssh\config') -Config $cfg }
  catch { Write-Host ('deploy: ' + $_.Exception.Message); exit 1 }

  if ($Init) {
      Write-Host 'deploy: init done: config, laptop key and ssh config are ready.'
      Write-Host 'Next, set up the admin key once:'
      Write-Host ''
      foreach ($l in Get-TmuxkeepAdminHelp -Config $cfg -HomeDir $HomeDir) { Write-Host $l }
      exit 0
  }

  # 4. Stage. The folder is removed on every exit path below (step 9).
  $ts = (Get-Date).ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
  $stage = "tmuxkeep-deploy-$ts"
  $parent = Join-Path $env:TEMP "tmuxkeep-stage-$ts"
  try {
      New-TmuxkeepStaging -RepoRoot $repo -Version (Get-TmuxkeepVersion -RepoRoot $repo) -PubKeyPath "$key.pub" -Config $cfg -Destination (Join-Path $parent $stage)

      # 5. Copy over the admin path. A relative source keeps scp from reading 'C:' as a host.
      Push-Location -LiteralPath $parent
      try {
          & scp -o PreferredAuthentications=publickey -r $stage "tmuxkeep-admin:/root/$stage"
          $scpExit = $LASTEXITCODE
      }
      finally {
          Pop-Location
      }
      if ($scpExit -eq 255) {
          Write-Host 'deploy: the admin key was not accepted, or tmuxkeep-admin is unreachable. Set up the admin path once, then run deploy again.'
          Write-Host 'If you only mistyped the passphrase, run deploy again.'
          Write-Host ''
          foreach ($l in Get-TmuxkeepAdminHelp -Config $cfg -HomeDir $HomeDir) { Write-Host $l }
          exit 1
      }
      if ($scpExit -ne 0) { Write-Host "deploy: scp failed with exit $scpExit"; exit $scpExit }

      # 6. Install. No -t; the output (the TOTP secret, once) goes to the console and is never captured.
      & ssh -o PreferredAuthentications=publickey tmuxkeep-admin (Get-TmuxkeepSetupCommand -StageName $stage -HardenRoot:$HardenRoot -RotateTotp:$RotateTotp -UnlockOtp:$UnlockOtp)
      $setupExit = $LASTEXITCODE
      if ($setupExit -eq 255) {
          # 255 is ssh itself failing (tmuxkeep-setup exits 0, 1 or 2), so nothing says how far setup got.
          Write-Host "deploy: ssh to tmuxkeep-admin failed (exit 255): wrong passphrase or the connection was lost. tmuxkeep-setup may not have run or may have stopped partway, /root/$stage may remain on the VPS, and running deploy again is safe."
          exit 255
      }
      if ($setupExit -ne 0) {
          Write-Host "deploy: tmuxkeep-setup failed with exit $setupExit"
          exit $setupExit
      }

      # 7. The wrapper and the profile snippet.
      $scriptsDir = Join-Path $HomeDir 'scripts'
      [void][IO.Directory]::CreateDirectory($scriptsDir)
      Copy-Item -LiteralPath (Join-Path $repo 'laptop\tmuxkeep.ps1') -Destination (Join-Path $scriptsDir 'tmuxkeep.ps1') -Force
      Set-TmuxkeepProfileSnippet -ProfilePath $ProfilePath -SnippetPath (Join-Path $repo 'laptop\profile-snippet.ps1')

      # 8. Proof of life.
      & ssh -o BatchMode=yes tmuxkeep ls
      Write-Host "deploy: proof of life exit $LASTEXITCODE"
  }
  finally {
      # 9. Remove the local staging folder.
      Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Host 'deploy: done. Open a new PowerShell window to load the tmuxkeep function.'
  ```

- Delete `Add-TmuxkeepMarkedBlock`, `Add-TmuxkeepHostBlock`, `Add-TmuxkeepProfileSnippet` and `Show-TmuxkeepAdminHelp`. After this task `laptop/deploy.ps1` holds no IPv4 address.

- [ ] **Step 1: Rewrite the tests in `tests/pester/deploy.Tests.ps1`**

(a) Replace the `Describe 'dot-sourcing'` block with:

```powershell
Describe 'dot-sourcing' {
    It 'defines the deploy functions and no longer the v1 append-once ones' {
        foreach ($f in 'Get-TmuxkeepVersion', 'Get-TmuxkeepVpsFiles', 'New-TmuxkeepStaging', 'Set-TmuxkeepMarkedBlock',
                       'Get-TmuxkeepSshBlock', 'Set-TmuxkeepHostBlock', 'Set-TmuxkeepProfileSnippet', 'Get-TmuxkeepSetupCommand',
                       'Get-TmuxkeepAdminHelp', 'Read-TmuxkeepConfig', 'Write-TmuxkeepConfig', 'New-TmuxkeepConfigInteractive',
                       'ConvertTo-TmuxkeepDeployConf', 'Expand-TmuxkeepPath') {
            Get-Command $f -CommandType Function | Should -Not -BeNullOrEmpty
        }
        foreach ($f in 'Add-TmuxkeepMarkedBlock', 'Add-TmuxkeepHostBlock', 'Add-TmuxkeepProfileSnippet', 'Show-TmuxkeepAdminHelp') {
            Get-Command $f -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }
}
```

(b) Replace the `Describe 'New-TmuxkeepStaging'` block with:

```powershell
Describe 'New-TmuxkeepStaging' {
    BeforeAll {
        $script:Defaults = Get-TmuxkeepConfigDefaults
        $script:Defaults['HOST'] = '203.0.113.10'
    }

    It 'stages the VPS files, laptop.pub and deploy.conf with LF, no BOM and the version, under a path with spaces' {
        $dest = Join-Path $TestDrive 'stage dir\tmuxkeep-deploy-20261012120000'
        New-TmuxkeepStaging -RepoRoot $Repo -Version 'abc1234' -PubKeyPath $Pub -Config $Defaults -Destination $dest
        $names = [string[]]@(Get-ChildItem -LiteralPath $dest -Recurse -File | ForEach-Object { $_.FullName.Substring($dest.Length + 1).Replace('\', '/') })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        ($names -join ',') | Should -BeExactly 'deploy.conf,laptop.pub,sshd.conf.tmpl,sudoers.tmpl,systemd/tmuxkeep-reaper.service,systemd/tmuxkeep-reaper.timer,tmux.conf,tmuxkeep,tmuxkeep-setup,vps-facts.sh'
        foreach ($f in Get-ChildItem -LiteralPath $dest -Recurse -File) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            ($b -contains 13) | Should -BeFalse -Because "$($f.Name) must have LF endings"
            ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeFalse -Because "$($f.Name) must have no BOM"
        }
        $broker = [IO.File]::ReadAllText((Join-Path $dest 'tmuxkeep'))
        $broker | Should -Match '(?m)^TMUXKEEP_VERSION=abc1234$'
        $broker | Should -Not -Match '(?m)^TMUXKEEP_VERSION=dev$'
        [IO.File]::ReadAllText((Join-Path $dest 'deploy.conf')) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\deploy.conf')))
        [IO.File]::ReadAllText((Join-Path $dest 'laptop.pub')) | Should -BeExactly "ssh-ed25519 AAAATEST tmuxkeep-laptop`n"
    }

    It 'rejects a version string that is not a git hash' {
        { New-TmuxkeepStaging -RepoRoot $Repo -Version 'abc; rm -rf /' -PubKeyPath $Pub -Config $Defaults -Destination (Join-Path $TestDrive 's2') } |
            Should -Throw
    }

    It 'throws when vps/tmuxkeep lacks exactly one TMUXKEEP_VERSION=dev line' {
        $fake = Join-Path $TestDrive 'fakerepo'
        New-Item -ItemType Directory -Path $fake | Out-Null
        Copy-Item -LiteralPath (Join-Path $Repo 'vps') -Destination (Join-Path $fake 'vps') -Recurse
        $p = Join-Path $fake 'vps\tmuxkeep'
        [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) -replace '(?m)^TMUXKEEP_VERSION=dev\r?$', 'TMUXKEEP_VERSION=other'))
        { New-TmuxkeepStaging -RepoRoot $fake -Version 'abc1234' -PubKeyPath $Pub -Config $Defaults -Destination (Join-Path $TestDrive 's3') } |
            Should -Throw
    }

    It 'Get-TmuxkeepVpsFiles is the spec list, in order' {
        (@(Get-TmuxkeepVpsFiles) -join ' ') | Should -BeExactly 'tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer'
    }
}
```

(c) Delete the `Describe 'Add-TmuxkeepHostBlock'` and `Describe 'Add-TmuxkeepProfileSnippet (Review Focus 5)'` blocks.

(d) Replace the `Describe 'Get-TmuxkeepSetupCommand'` block with:

```powershell
Describe 'Get-TmuxkeepSetupCommand' {
    It 'builds the spec 6.1 command with --conf, then the cleanup and the exit code (plan Q4)' {
        Get-TmuxkeepSetupCommand -StageName 'tmuxkeep-deploy-20261012120000' |
            Should -BeExactly 'bash /root/tmuxkeep-deploy-20261012120000/tmuxkeep-setup --pubkey-file /root/tmuxkeep-deploy-20261012120000/laptop.pub --key-id laptop --conf /root/tmuxkeep-deploy-20261012120000/deploy.conf; rc=$?; rm -rf /root/tmuxkeep-deploy-20261012120000; exit $rc'
    }

    It 'appends the flags in a fixed order' {
        Get-TmuxkeepSetupCommand -StageName 'tmuxkeep-deploy-20261012120000' -UnlockOtp -HardenRoot -RotateTotp |
            Should -Match '/deploy\.conf --harden-root --rotate-totp --unlock-otp; rc='
    }

    It 'never contains a double quote' {
        Get-TmuxkeepSetupCommand -StageName 'tmuxkeep-deploy-20261012120000' -HardenRoot | Should -Not -Match '"'
    }

    It 'refuses a stage name that is not tmuxkeep-deploy- followed by 14 digits' {
        { Get-TmuxkeepSetupCommand -StageName 'x; rm -rf /' } | Should -Throw
        { Get-TmuxkeepSetupCommand -StageName 'tmuxkeep-deploy-123' } | Should -Throw
    }
}
```

(e) Replace the `Describe 'Show-TmuxkeepAdminHelp'` block with:

```powershell
Describe 'Get-TmuxkeepAdminHelp' {
    BeforeAll {
        $script:HelpHome = Join-Path $TestDrive 'help home'
        New-Item -ItemType Directory -Path (Join-Path $HelpHome '.ssh') -Force | Out-Null
    }

    It 'builds the spec 6.5 steps from the config, with no other address in them' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '198.51.100.20'
        $v['PORT'] = '2222'
        $h = @(Get-TmuxkeepAdminHelp -Config $v -HomeDir $HelpHome)
        $adminPath = Join-Path $HelpHome '.ssh\id_tmuxkeep_admin_ed25519'
        $h.Count | Should -Be 6
        $h[0] | Should -BeExactly ('1. ssh-keygen -t ed25519 -f "' + $adminPath + '" -C tmuxkeep-admin        (set a passphrase)')
        $h[1] | Should -BeExactly '2. Install it on the VPS with one password login:'
        $h[2] | Should -BeExactly '   ssh root@198.51.100.20 -p 2222 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && echo <contents of ~/.ssh/id_tmuxkeep_admin_ed25519.pub> >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"'
        $h[3] | Should -BeExactly '3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true'
        $h[4] | Should -BeExactly ''
        $h[5] | Should -BeExactly 'Never ssh-add the admin key and never set AddKeysToAgent for it.'
        ($h -join "`n") | Should -Not -Match '203\.0\.113\.10'
    }

    It 'puts the public key into step 2 once it exists, and only a plain ssh-ed25519 line' {
        $v = Get-TmuxkeepConfigDefaults
        $v['HOST'] = '198.51.100.20'
        $pubPath = Join-Path $HelpHome '.ssh\id_tmuxkeep_admin_ed25519.pub'
        [IO.File]::WriteAllText($pubPath, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdminAdminAdmin tmuxkeep-admin`r`n")
        $h = @(Get-TmuxkeepAdminHelp -Config $v -HomeDir $HelpHome)
        $h[2] | Should -Match ([regex]::Escape('&& echo ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdminAdminAdmin tmuxkeep-admin >> ~/.ssh/authorized_keys'))
        [IO.File]::WriteAllText($pubPath, "ssh-ed25519 AAAA `$(reboot)`n")
        $h = @(Get-TmuxkeepAdminHelp -Config $v -HomeDir $HelpHome)
        $h[2] | Should -Match ([regex]::Escape('echo <contents of ~/.ssh/id_tmuxkeep_admin_ed25519.pub> >>'))
        Remove-Item -LiteralPath $pubPath
    }
}
```

(f) Replace the `Describe 'deploy.ps1 main sequence'` block with:

```powershell
Describe 'deploy.ps1 main sequence' {
    BeforeAll {
        $script:DeployText = [IO.File]::ReadAllText((Join-Path $Repo 'laptop\deploy.ps1'))
        $script:DeployLines = @($DeployText -split "\r?\n")
    }

    It 'refuses to run outside Windows PowerShell before the first ssh-keygen call' {
        # Under pwsh 7.3+ the '""' passphrase would reach ssh-keygen as two literal characters.
        $edition = $DeployText.IndexOf('$PSVersionTable.PSEdition')
        $keygen = $DeployText.IndexOf('& ssh-keygen')
        ($edition -ge 0) | Should -BeTrue -Because 'the PSEdition check must exist'
        ($keygen -gt $edition) | Should -BeTrue -Because 'the check must come before the ssh-keygen call'
        ($DeployText -match "(?s)PSEdition -ne 'Desktop'\)\s*\{[^}]*not pwsh[^}]*exit 2") | Should -BeTrue -Because 'the check must say why and exit 2'
    }

    It 'explains an ssh exit of 255 from the setup step, and the README documents the same message' {
        $msg = 'ssh to tmuxkeep-admin failed (exit 255)'
        $DeployText.Contains($msg) | Should -BeTrue -Because 'deploy.ps1 must print the 255 message'
        ($DeployText -match '(?s)\$setupExit -eq 255.*?exit 255') | Should -BeTrue -Because 'step 6 must exit 255 on it'
        [IO.File]::ReadAllText((Join-Path $Repo 'README.md')).Contains($msg) | Should -BeTrue -Because 'the README must document the message'
    }

    It 'keeps the generic message for any other setup failure' {
        $DeployText.Contains('deploy: tmuxkeep-setup failed with exit $setupExit') | Should -BeTrue
    }

    It 'runs the installer ssh as a plain statement, never captured (G3)' {
        $l = @($DeployLines | Where-Object { $_ -match 'tmuxkeep-admin \(Get-TmuxkeepSetupCommand' })
        $l.Count | Should -Be 1
        $l[0].Trim() | Should -BeExactly '& ssh -o PreferredAuthentications=publickey tmuxkeep-admin (Get-TmuxkeepSetupCommand -StageName $stage -HardenRoot:$HardenRoot -RotateTotp:$RotateTotp -UnlockOtp:$UnlockOtp)'
    }

    It 'never calls ssh-add and mentions AddKeysToAgent only in the warning (G3)' {
        @($DeployLines | Where-Object { $_ -match '^\s*(&\s*)?ssh-add\b' }).Count | Should -Be 0
        $a = @($DeployLines | Where-Object { $_ -match 'AddKeysToAgent' })
        $a.Count | Should -Be 1
        $a[0] | Should -Match ([regex]::Escape('Never ssh-add the admin key and never set AddKeysToAgent for it.'))
    }

    It 'holds no IPv4 address' {
        $DeployText | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
    }
}
```

(g) Insert this new block before the `Describe '.gitignore'` block:

```powershell
Describe 'deploy.ps1 run in a child powershell.exe with stub ssh, scp and ssh-keygen' {
    BeforeAll {
        $script:Deploy = Join-Path $Repo 'laptop\deploy.ps1'
        $script:Stubs = Join-Path $TestDrive 'stubs'
        New-Item -ItemType Directory -Path $Stubs | Out-Null
        # PowerShell finds a .ps1 on PATH before ssh.exe further down PATH, and passes -o, -t and
        # -N to a script without a param block in $args. Each stub logs name|arg|arg... per call.
        Set-Content -LiteralPath (Join-Path $Stubs 'ssh.ps1') -Encoding ascii -Value @'
Add-Content -LiteralPath $env:TK_STUB_LOG -Value ('ssh|' + ($args -join '|')) -Encoding ascii
$rc = 0
if ($env:TK_STUB_SSH_RC) { $rc = [int]$env:TK_STUB_SSH_RC }
exit $rc
'@
        Set-Content -LiteralPath (Join-Path $Stubs 'scp.ps1') -Encoding ascii -Value @'
Add-Content -LiteralPath $env:TK_STUB_LOG -Value ('scp|' + ($args -join '|')) -Encoding ascii
if ($env:TK_STUB_SCP_DEST -and $args.Count -ge 2) {
    Copy-Item -LiteralPath ([string]$args[$args.Count - 2]) -Destination $env:TK_STUB_SCP_DEST -Recurse
}
$rc = 0
if ($env:TK_STUB_SCP_RC) { $rc = [int]$env:TK_STUB_SCP_RC }
exit $rc
'@
        Set-Content -LiteralPath (Join-Path $Stubs 'ssh-keygen.ps1') -Encoding ascii -Value @'
Add-Content -LiteralPath $env:TK_STUB_LOG -Value ('ssh-keygen|' + ($args -join '|')) -Encoding ascii
$f = $null
for ($i = 0; $i -lt $args.Count - 1; $i++) { if ([string]$args[$i] -ceq '-f') { $f = [string]$args[$i + 1] } }
if ($f) {
    [IO.File]::WriteAllText($f, "FAKE PRIVATE KEY`n")
    [IO.File]::WriteAllText("$f.pub", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubStubStubStubStubStubStub tmuxkeep-laptop`n")
}
exit 0
'@

        function Invoke-Deploy([string[]]$Extra) {
            $savedPath = $env:PATH
            $savedTemp = $env:TEMP
            try {
                $env:PATH = "$script:Stubs;$savedPath"
                $env:TEMP = $script:TempRoot
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Deploy -Config $script:Cfg -HomeDir $script:HomeRoot -ProfilePath $script:Prof @Extra | Out-String -Width 4096
                return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
            }
            finally {
                $env:PATH = $savedPath
                $env:TEMP = $savedTemp
            }
        }
        function Get-StubLog { @(Get-Content -LiteralPath $env:TK_STUB_LOG -ErrorAction SilentlyContinue) }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:HomeRoot = Join-Path $root 'home dir'
        $script:TempRoot = Join-Path $root 'temp'
        $script:Prof = Join-Path $script:HomeRoot 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
        $script:Cfg = Join-Path $script:HomeRoot '.tmuxkeep\config'
        foreach ($d in $script:HomeRoot, $script:TempRoot, (Split-Path $script:Cfg), (Join-Path $root 'scp')) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $Repo 'tests\fixtures\laptop-config') -Destination $script:Cfg
        $env:TK_STUB_LOG = Join-Path $root 'stub.log'
        $env:TK_STUB_SCP_DEST = Join-Path $root 'scp'
        Remove-Item Env:\TK_STUB_SSH_RC, Env:\TK_STUB_SCP_RC -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item Env:\TK_STUB_LOG, Env:\TK_STUB_SCP_DEST, Env:\TK_STUB_SSH_RC, Env:\TK_STUB_SCP_RC -ErrorAction SilentlyContinue
    }

    It 'runs keygen, scp, the setup ssh and the proof of life in that order, with the exact arguments' {
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
        $log = Get-StubLog
        $log.Count | Should -Be 4
        $log[0] | Should -BeExactly ('ssh-keygen|-t|ed25519|-f|' + (Join-Path $HomeRoot '.ssh\id_tmuxkeep_ed25519') + '|-C|tmuxkeep-laptop|-N|""')
        $log[1] | Should -Match '^scp\|-o\|PreferredAuthentications=publickey\|-r\|tmuxkeep-deploy-\d{14}\|tmuxkeep-admin:/root/tmuxkeep-deploy-\d{14}$'
        $stage = ($log[1] -split '\|')[4]
        $log[2] | Should -BeExactly ('ssh|-o|PreferredAuthentications=publickey|tmuxkeep-admin|' + (Get-TmuxkeepSetupCommand -StageName $stage))
        $log[3] | Should -BeExactly 'ssh|-o|BatchMode=yes|tmuxkeep|ls'
        $r.Out | Should -Match 'deploy: proof of life exit 0'
        $r.Out | Should -Match 'deploy: done\.'
    }

    It 'stages the eight VPS files, laptop.pub and deploy.conf, then removes the local staging folder' {
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
        $copied = @(Get-ChildItem -LiteralPath $env:TK_STUB_SCP_DEST -Directory)
        $copied.Count | Should -Be 1
        $dest = $copied[0].FullName
        $names = [string[]]@(Get-ChildItem -LiteralPath $dest -Recurse -File | ForEach-Object { $_.FullName.Substring($dest.Length + 1).Replace('\', '/') })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        ($names -join ',') | Should -BeExactly 'deploy.conf,laptop.pub,sshd.conf.tmpl,sudoers.tmpl,systemd/tmuxkeep-reaper.service,systemd/tmuxkeep-reaper.timer,tmux.conf,tmuxkeep,tmuxkeep-setup,vps-facts.sh'
        [IO.File]::ReadAllText((Join-Path $dest 'deploy.conf')) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\deploy.conf')))
        [IO.File]::ReadAllText((Join-Path $dest 'laptop.pub')) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $HomeRoot '.ssh\id_tmuxkeep_ed25519.pub')))
        [IO.File]::ReadAllText((Join-Path $dest 'tmuxkeep')) | Should -Match '(?m)^TMUXKEEP_VERSION=[0-9a-f]{4,40}(-dirty)?$'
        @(Get-ChildItem -LiteralPath $TempRoot -Filter 'tmuxkeep-stage-*').Count | Should -Be 0
    }

    It 'installs the wrapper, the profile block and the ssh config block' {
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
        ([IO.File]::ReadAllBytes((Join-Path $HomeRoot 'scripts\tmuxkeep.ps1')) -join ',') | Should -BeExactly ([IO.File]::ReadAllBytes((Join-Path $Repo 'laptop\tmuxkeep.ps1')) -join ',')
        [IO.File]::ReadAllText($Prof) | Should -Match ([regex]::Escape('Register-ArgumentCompleter -Native -CommandName tmuxkeep'))
        [IO.File]::ReadAllText((Join-Path $HomeRoot '.ssh\config')) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $Repo 'tests\fixtures\ssh-block')).Replace("`n", "`r`n"))
    }

    It '-Init stops after step 3 and prints the admin-key steps; no scp and no ssh' {
        $r = Invoke-Deploy @('-Init')
        $r.Code | Should -Be 0 -Because $r.Out
        $log = Get-StubLog
        $log.Count | Should -Be 1
        $log[0] | Should -Match '^ssh-keygen\|'
        Test-Path -LiteralPath (Join-Path $HomeRoot '.ssh\config') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $HomeRoot 'scripts\tmuxkeep.ps1') | Should -BeFalse
        $r.Out | Should -Match 'deploy: init done'
        $r.Out | Should -Match ([regex]::Escape('3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true'))
    }

    It 'passes -HardenRoot, -RotateTotp and -UnlockOtp to the installer in a fixed order' {
        $r = Invoke-Deploy @('-UnlockOtp', '-HardenRoot', '-RotateTotp')
        $r.Code | Should -Be 0 -Because $r.Out
        (Get-StubLog)[2] | Should -Match '/deploy\.conf --harden-root --rotate-totp --unlock-otp; rc='
    }

    It 'scp exit 255 prints the admin-key help built from the config and stops with exit 1' {
        $env:TK_STUB_SCP_RC = '255'
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'the admin key was not accepted'
        $r.Out | Should -Match ([regex]::Escape('ssh root@203.0.113.10 -p 22 "mkdir -p ~/.ssh'))
        @(Get-StubLog | Where-Object { $_ -like 'ssh|*' }).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $TempRoot -Filter 'tmuxkeep-stage-*').Count | Should -Be 0
    }

    It 'a failing installer stops before the wrapper is installed' {
        $env:TK_STUB_SSH_RC = '3'
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 3
        $r.Out | Should -Match 'deploy: tmuxkeep-setup failed with exit 3'
        Test-Path -LiteralPath (Join-Path $HomeRoot 'scripts\tmuxkeep.ps1') | Should -BeFalse
    }

    It 'an ssh exit 255 from the setup step explains itself and exits 255' {
        $env:TK_STUB_SSH_RC = '255'
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 255
        $r.Out | Should -Match ([regex]::Escape('deploy: ssh to tmuxkeep-admin failed (exit 255)'))
    }

    It 'an invalid config stops with exit 2, naming the key, before any tool runs' {
        [IO.File]::WriteAllText($Cfg, ([IO.File]::ReadAllText($Cfg) -replace '(?m)^PORT=22$', 'PORT=0'))
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 2
        $r.Out | Should -Match ([regex]::Escape('deploy: config ' + $Cfg + ': PORT: must be an integer from 1 to 65535'))
        @(Get-StubLog).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run to see them fail**

Run the G6 command with `$c.Run.Path = 'tests\pester\deploy.Tests.ps1'`.
Expected: failures in the rewritten and new blocks.

- [ ] **Step 3: Implement the behaviour above in `laptop/deploy.ps1`. Never run it yourself; only the child-process tests run it.**

- [ ] **Step 4: Run until green**

- `tests\pester\deploy.Tests.ps1`: 43 tests, 0 failed.
- the whole Pester folder and the whole bats directory (G8).

- [ ] **Step 5: Commit**

```bash
git add laptop/deploy.ps1 tests/pester/deploy.Tests.ps1
git commit -m "deploy.ps1: config-driven main sequence, -Init and -Config, laptop.pub and deploy.conf staging, admin help from config"
```

---

### Task 10: Bash wrapper, stubs, laptop helpers and laptop lint

Suggested model: sonnet.

**Files:**
- Modify: `.gitattributes`
- Create: `laptop/tmuxkeep.sh` (executable)
- Create: `tests/bats/stubs/ssh`, `tests/bats/stubs/scp`, `tests/bats/stubs/ssh-keygen` (executable)
- Create: `tests/bats/laptop-helpers.bash`
- Create: `tests/bats/laptop-wrapper.bats`
- Create: `tests/bats/lint-laptop.bats`

**Interfaces:**
- Consumes: Task 1's names (alias `tmuxkeep`, the gated verbs, the `b64` protocol of the broker).
- Produces:
  - `laptop/tmuxkeep.sh`, installed by Task 14 as `~/.local/bin/tmuxkeep`. Functions: `tk_encode WORD`, `tk_is_gated VERB`, `tk_ssh_args WORD...` (sets the array `TK_SSH_ARGS`), `tk_prompt LABEL` (prints the answer), `tk_main WORD...` (returns the exit code). One line exactly `TK_GATED_VERBS="new go send rename unlock rm resume auth"` (Task 15 parses it).
  - Stubs (bash 3.2), on `PATH` through `laptop_setup`: each appends one line per call to `$TK_STUB_LOG`, the tool name then every argument in brackets, for example `ssh [-o] [BatchMode=yes] [tmuxkeep] [ls]`. `ssh` copies the file `$TK_STUB_SSH_OUT` to stdout, prints `$TK_STUB_SSH_ERR` on stderr, exits `$TK_STUB_SSH_RC` (default 0). `scp` copies its next-to-last argument into the directory `$TK_STUB_SCP_DEST` when that is set, exits `$TK_STUB_SCP_RC`. `ssh-keygen` writes `FAKE PRIVATE KEY` to the `-f` path and `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubStubStubStubStubStubStub tmuxkeep-laptop` to `<path>.pub`, unless `$TK_STUB_KEYGEN_RC` is non-zero (then it exits with that code and writes nothing).
  - `tests/bats/laptop-helpers.bash`: `REPO`, `STUBS`, `WRAPPER`, `laptop_setup`, `stub_calls`, `b64 WORD`, `mk_repo_copy` (exact text below). Tasks 11-16 load it.
  - `tests/bats/lint-laptop.bats`: static checks over every laptop bash file that exists, including those Tasks 11-17 add.

**Behaviour (spec 6.1, 6.4, 9.2, 9.5; G19-G23):**
- The wrapper's behaviour matches `laptop/tmuxkeep.ps1`: same ssh options, same gated list, same local checks, same exit codes; messages go to stderr. A plain bash string cannot be a dictionary, so PowerShell's "unsupported argument type" check has no bash counterpart. Unlike PowerShell, bash passes a bare `--` through; it is encoded like any other word.
- New and changed scripts use `#!/usr/bin/env bash`; sourced files (`completion.bash`, `laptop-helpers.bash`) have no shebang.

- [ ] **Step 1: Replace `.gitattributes` with exactly this content**

```
# Force LF for everything that runs on Linux or macOS or in the Docker test image.
vps/** text eol=lf
tests/** text eol=lf
laptop/*.sh text eol=lf
laptop/completion.bash text eol=lf
```

Check: `git check-attr eol -- laptop/tmuxkeep.sh laptop/completion.bash laptop/deploy.ps1` prints `eol: lf` for the first two and `eol: unspecified` for the third.

- [ ] **Step 2: Create `tests/bats/laptop-helpers.bash` with exactly this content**

```bash
# tests/bats/laptop-helpers.bash: helpers for the laptop-side suites. Load with: load laptop-helpers
# Runs under /bin/bash 3.2 on macOS and bash 5 in Docker (plan G19-G22): no bash 4 features, no
# set -u, no GNU-only tools. The repo may be read-only (/src in Docker): write under BATS_TEST_TMPDIR.
bats_require_minimum_version 1.5.0

REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
STUBS=$REPO/tests/bats/stubs
WRAPPER=$REPO/laptop/tmuxkeep.sh

# laptop_setup: a private HOME, TMPDIR and stub log; the stub ssh, scp and ssh-keygen first on PATH.
laptop_setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$HOME" "$TMPDIR"
  export TK_STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : > "$TK_STUB_LOG"
  unset TK_STUB_SSH_RC TK_STUB_SCP_RC TK_STUB_KEYGEN_RC TK_STUB_SSH_OUT TK_STUB_SSH_ERR TK_STUB_SCP_DEST
  export PATH="$STUBS:$PATH"
  export SHELL=/bin/bash
}

# stub_calls: the stub log, one line per call: "<tool> [arg] [arg]...".
stub_calls() { cat "$TK_STUB_LOG"; }

# b64 WORD: the token the wrapper sends for WORD.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# mk_repo_copy: prints the path of a fresh one-commit git repository holding copies of laptop/ and
# vps/. deploy.sh runs from there, so no test depends on the real checkout's .git (a worktree's
# .git file points at a Windows path that does not exist inside Docker).
mk_repo_copy() {
  local r="$BATS_TEST_TMPDIR/repo"
  rm -rf "$r"
  mkdir -p "$r"
  cp -R "$REPO/laptop" "$REPO/vps" "$r/"
  git -c init.defaultBranch=main init -q "$r"
  git -C "$r" add -A
  git -C "$r" -c user.email=test@example.invalid -c user.name=test commit -q -m test
  printf '%s' "$r"
}
```

- [ ] **Step 3: Create the three stubs, exactly**

`tests/bats/stubs/ssh`:

```bash
#!/usr/bin/env bash
# Test stub for ssh (laptop suites). Appends one line per call to $TK_STUB_LOG: "ssh" and then each
# argument in brackets. Copies the file $TK_STUB_SSH_OUT to stdout, prints $TK_STUB_SSH_ERR on
# stderr, and exits with $TK_STUB_SSH_RC (default 0). bash 3.2.
{ printf 'ssh'; if [ "$#" -gt 0 ]; then printf ' [%s]' "$@"; fi; printf '\n'; } >> "${TK_STUB_LOG:-/dev/null}"
if [ -n "${TK_STUB_SSH_OUT:-}" ] && [ -f "$TK_STUB_SSH_OUT" ]; then cat "$TK_STUB_SSH_OUT"; fi
if [ -n "${TK_STUB_SSH_ERR:-}" ]; then printf '%s\n' "$TK_STUB_SSH_ERR" >&2; fi
exit "${TK_STUB_SSH_RC:-0}"
```

`tests/bats/stubs/scp`:

```bash
#!/usr/bin/env bash
# Test stub for scp (laptop suites). Logs like the ssh stub. When $TK_STUB_SCP_DEST is a directory,
# copies the source (the next-to-last argument) into it, so a test can look at what deploy staged
# after deploy has removed its own copy. Exits with $TK_STUB_SCP_RC (default 0). bash 3.2.
{ printf 'scp'; if [ "$#" -gt 0 ]; then printf ' [%s]' "$@"; fi; printf '\n'; } >> "${TK_STUB_LOG:-/dev/null}"
src=''
last=''
for a in "$@"; do src=$last; last=$a; done
if [ -n "${TK_STUB_SCP_DEST:-}" ] && [ -d "$TK_STUB_SCP_DEST" ] && [ -n "$src" ]; then
  cp -R "$src" "$TK_STUB_SCP_DEST/"
fi
exit "${TK_STUB_SCP_RC:-0}"
```

`tests/bats/stubs/ssh-keygen`:

```bash
#!/usr/bin/env bash
# Test stub for ssh-keygen (laptop suites). Logs like the ssh stub. Unless $TK_STUB_KEYGEN_RC is
# non-zero, writes a fake private key to the -f path and a fake ed25519 line to <path>.pub. bash 3.2.
{ printf 'ssh-keygen'; if [ "$#" -gt 0 ]; then printf ' [%s]' "$@"; fi; printf '\n'; } >> "${TK_STUB_LOG:-/dev/null}"
rc=${TK_STUB_KEYGEN_RC:-0}
if [ "$rc" != 0 ]; then exit "$rc"; fi
f=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = -f ] && [ "$#" -ge 2 ]; then f=$2; shift; fi
  shift
done
if [ -n "$f" ]; then
  printf 'FAKE PRIVATE KEY\n' > "$f"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubStubStubStubStubStubStub tmuxkeep-laptop\n' > "$f.pub"
fi
exit 0
```

- [ ] **Step 4: Write the failing test `tests/bats/laptop-wrapper.bats`**

```bash
#!/usr/bin/env bats
# laptop/tmuxkeep.sh (spec 6.1, 6.4, 9.2): encoding, gated -t, exit codes, local checks. ssh is a
# stub; prompts are tested by redefining tk_prompt after sourcing the wrapper.
load laptop-helpers

setup() {
  laptop_setup
  # shellcheck source=/dev/null
  source "$WRAPPER"
  PROMPTS="$BATS_TEST_TMPDIR/prompts"
  : > "$PROMPTS"
}

# line_for TTY WORD...: the stub log line the wrapper must produce (TTY is 1 for a gated verb).
line_for() {
  local tty=$1 w out='ssh [-o] [BatchMode=yes] [-o] [ConnectTimeout=5]'
  shift
  if [ "$tty" = 1 ]; then out="$out [-t]"; fi
  out="$out [tmuxkeep] [b64]"
  for w in "$@"; do out="$out [$(b64 "$w")]"; done
  printf '%s' "$out"
}

# answer TEXT: from now on tk_prompt records its label in $PROMPTS and answers TEXT.
answer() {
  TK_ANSWER=$1
  tk_prompt() { printf '%s\n' "$1" >> "$PROMPTS"; printf '%s' "$TK_ANSWER"; }
}

@test "sourcing defines the functions and runs nothing" {
  declare -F tk_main tk_prompt tk_encode tk_ssh_args tk_is_gated >/dev/null
  [ ! -s "$TK_STUB_LOG" ]
}

@test "the gated verb list is the one agreed line" {
  [ "$(grep -c '^TK_GATED_VERBS=' "$WRAPPER")" -eq 1 ]
  grep -qx 'TK_GATED_VERBS="new go send rename unlock rm resume auth"' "$WRAPPER"
}

@test "gated verbs get -t, open verbs do not" {
  local v
  for v in new go rename unlock rm resume; do
    : > "$TK_STUB_LOG"
    run tk_main "$v" api
    [ "$(stub_calls)" = "$(line_for 1 "$v" api)" ] || { echo "verb $v: $(stub_calls)"; return 1; }
  done
  : > "$TK_STUB_LOG"
  run tk_main send api hi
  [ "$(stub_calls)" = "$(line_for 1 send api hi)" ]
  : > "$TK_STUB_LOG"
  run tk_main auth
  [ "$(stub_calls)" = "$(line_for 1 auth)" ]
  for v in peek lock restore; do
    : > "$TK_STUB_LOG"
    run tk_main "$v" api
    [ "$(stub_calls)" = "$(line_for 0 "$v" api)" ] || { echo "verb $v: $(stub_calls)"; return 1; }
  done
  for v in ls log; do
    : > "$TK_STUB_LOG"
    run tk_main "$v"
    [ "$(stub_calls)" = "$(line_for 0 "$v")" ] || { echo "verb $v: $(stub_calls)"; return 1; }
  done
}

@test "each word of a multi-word send is encoded separately, spaces and specials kept" {
  run tk_main send api 'echo hi; ls *' there
  [ "$status" -eq 0 ]
  [ "$(stub_calls)" = "$(line_for 1 send api 'echo hi; ls *' there)" ]
}

@test "non-ASCII text is sent as base64 of its UTF-8 bytes" {
  local cafe
  cafe=$(printf 'caf\303\251')
  run tk_main send api "$cafe"
  [ "$(stub_calls)" = "$(line_for 1 send api "$cafe")" ]
  [ "$(b64 "$cafe")" = Y2Fmw6k= ]
}

@test "a long word stays one token: GNU base64 line wrapping is removed" {
  local long
  long=$(printf 'x%.0s' $(seq 1 120))
  run tk_main send api "$long"
  [ "$status" -eq 0 ]
  [ "$(stub_calls)" = "$(line_for 1 send api "$long")" ]
  [ "$(stub_calls | grep -c .)" -eq 1 ]
}

@test "an empty argument is exit 2 with no ssh call" {
  run --separate-stderr tk_main send api ''
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: empty argument' ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "send with no text prompts once and sends the answer as one word" {
  answer 'a; b # $c (d) @e, f'
  run tk_main send api
  [ "$status" -eq 0 ]
  [ "$(cat "$PROMPTS")" = 'Text to send: ' ]
  [ "$(stub_calls)" = "$(line_for 1 send api 'a; b # $c (d) @e, f')" ]
}

@test "an empty prompted text is exit 2 with no ssh call" {
  answer ''
  run --separate-stderr tk_main send api
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: nothing to send' ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "rm --now prompts for the name and appends --confirm" {
  answer api
  run tk_main rm api --now
  [ "$status" -eq 0 ]
  [ "$(cat "$PROMPTS")" = 'Type the session name to confirm: ' ]
  [ "$(stub_calls)" = "$(line_for 1 rm api --now --confirm api)" ]
}

@test "rm --now --confirm, plain rm and an upper-case RM do not prompt" {
  answer unused
  run tk_main rm api --now --confirm api
  [ "$(stub_calls)" = "$(line_for 1 rm api --now --confirm api)" ]
  : > "$TK_STUB_LOG"
  run tk_main rm api
  [ "$(stub_calls)" = "$(line_for 1 rm api)" ]
  : > "$TK_STUB_LOG"
  run tk_main RM api --now
  [ "$(stub_calls)" = "$(line_for 0 RM api --now)" ]
  [ ! -s "$PROMPTS" ]
}

@test "an empty confirmation is exit 2 with no ssh call" {
  answer ''
  run --separate-stderr tk_main rm api --now
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: confirmation required' ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "a bare -- is sent encoded, never raw" {
  run tk_main send api -- x
  [ "$(stub_calls)" = "$(line_for 1 send api -- x)" ]
  [[ "$(stub_calls)" != *'[--]'* ]]
}

@test "the exit code is ssh's own" {
  export TK_STUB_SSH_RC=3
  run tk_main rm api
  [ "$status" -eq 3 ]
}

@test "exit 255 prints the hint exactly once, on stderr" {
  export TK_STUB_SSH_RC=255
  run --separate-stderr tk_main ls
  [ "$status" -eq 255 ]
  [ "$stderr" = "tmuxkeep: ssh to host 'tmuxkeep' failed (unreachable, key rejected, or remote killed by signal)" ]
  [ -z "$output" ]
}

@test "other failures print no hint; ssh's own stdout and stderr pass through" {
  printf 'broker says hi\n' > "$BATS_TEST_TMPDIR/out"
  export TK_STUB_SSH_OUT="$BATS_TEST_TMPDIR/out" TK_STUB_SSH_ERR='tmuxkeep: no such session: nosuch' TK_STUB_SSH_RC=5
  run --separate-stderr tk_main peek nosuch
  [ "$status" -eq 5 ]
  [ "$output" = 'broker says hi' ]
  [ "$stderr" = 'tmuxkeep: no such session: nosuch' ]
}

@test "run as a program, the wrapper calls ssh and exits with its code" {
  export TK_STUB_SSH_RC=4
  run "$BASH" "$WRAPPER" auth
  [ "$status" -eq 4 ]
  [ "$(stub_calls)" = "$(line_for 1 auth)" ]
}

@test "with no arguments the wrapper still asks the broker, which answers with its usage" {
  run tk_main
  [ "$(stub_calls)" = 'ssh [-o] [BatchMode=yes] [-o] [ConnectTimeout=5] [tmuxkeep] [b64]' ]
}

@test "tk_prompt is the only code that opens /dev/tty" {
  [ "$(grep -vE '^[[:space:]]*#' "$WRAPPER" | grep -c '/dev/tty')" -eq 2 ]
  [ "$(sed -n '/^tk_prompt() {/,/^}/p' "$WRAPPER" | grep -c '/dev/tty')" -eq 2 ]
}

@test "the interpreter is the expected one (TK_EXPECT_BASH_MAJOR is set by the macOS CI job)" {
  if [ -n "${TK_EXPECT_BASH_MAJOR:-}" ]; then
    [ "${BASH_VERSINFO[0]}" = "$TK_EXPECT_BASH_MAJOR" ] || { echo "bash $BASH_VERSION"; return 1; }
  fi
  run "$BASH" -c 'echo "${BASH_VERSINFO[0]}"'
  [ "$output" = "${BASH_VERSINFO[0]}" ]
}
```

- [ ] **Step 5: Write the failing test `tests/bats/lint-laptop.bats`**

```bash
#!/usr/bin/env bats
# Static checks on every laptop-side bash file (plan G19-G23, spec 6.4, 9.5): shellcheck, bash 3.2
# constructs, GNU-only tools, set -u, LF and ASCII, shebangs. Files that do not exist yet are
# skipped by name, so this list already names the files later tasks add.
load laptop-helpers

LAPTOP_FILES='laptop/tmuxkeep.sh laptop/deploy.sh laptop/completion.bash tests/bats/laptop-helpers.bash tests/bats/stubs/ssh tests/bats/stubs/scp tests/bats/stubs/ssh-keygen tests/smoke.sh tests/run-bats.sh'

# each_file: the full path of every listed file that exists, one per line.
each_file() {
  local f
  for f in $LAPTOP_FILES; do
    if [ -f "$REPO/$f" ]; then printf '%s\n' "$REPO/$f"; fi
  done
  return 0
}

# code_hits PATTERN FILE: numbered lines of FILE matching the ERE, comment lines left out.
code_hits() { grep -nE -- "$1" "$2" | grep -vE '^[0-9]+:[[:space:]]*#' || true; }

@test "every existing laptop bash file passes shellcheck --shell=bash -S warning" {
  command -v shellcheck >/dev/null || { echo 'shellcheck is not installed'; return 1; }
  local f
  while IFS= read -r f; do
    run shellcheck --shell=bash -S warning "$f"
    [ "$status" -eq 0 ] || { echo "$f"; echo "$output"; return 1; }
  done < <(each_file)
}

@test "no bash 4 constructs (bash 3.2 is /bin/bash on macOS)" {
  local f p hits
  while IFS= read -r f; do
    for p in '(declare|local|typeset)[[:space:]]+-[a-zA-Z]*[Agn]' \
             '(^|[^a-zA-Z_])(mapfile|readarray|coproc)([^a-zA-Z_]|$)' \
             '\$\{[A-Za-z_][A-Za-z0-9_]*(,|\^)' \
             'read[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*i' \
             '\|&' ';&' '\[\[[[:space:]]+-v[[:space:]]' '\$\{[A-Za-z_][A-Za-z0-9_]*@' \
             '\[-[0-9]+\]' '%\(' 'EPOCHSECONDS|EPOCHREALTIME|BASHPID' 'wait[[:space:]]+-n' '&>>' \
             'shopt[[:space:]]+-s[[:space:]]+(globstar|lastpipe)'; do
      hits=$(code_hits "$p" "$f")
      [ -z "$hits" ] || { echo "$f matches $p:"; echo "$hits"; return 1; }
    done
  done < <(each_file)
}

@test "no set -u (bash 3.2 treats an empty array as unset)" {
  local f hits
  while IFS= read -r f; do
    hits=$(code_hits 'set[[:space:]]+-[a-zA-Z]*u|set[[:space:]]+-o[[:space:]]+nounset' "$f")
    [ -z "$hits" ] || { echo "$f:"; echo "$hits"; return 1; }
  done < <(each_file)
}

@test "no GNU-only tools or flags; stat only in completion.bash" {
  local f p hits
  while IFS= read -r f; do
    for p in 'sed[[:space:]]+-i' 'grep[[:space:]]+-[a-zA-Z]*P' 'readlink[[:space:]]+-f' 'date[[:space:]]+-d' \
             'base64[[:space:]]+-[wd]' '(^|[^a-zA-Z_])realpath([^a-zA-Z_]|$)' '--suffix' \
             '(^|[[:space:];&|(])timeout[[:space:]]'; do
      hits=$(code_hits "$p" "$f")
      [ -z "$hits" ] || { echo "$f matches $p:"; echo "$hits"; return 1; }
    done
    case $f in
      */laptop/completion.bash) ;;
      *) hits=$(code_hits '(^|[[:space:];&|(])stat[[:space:]]' "$f")
         [ -z "$hits" ] || { echo "$f uses stat:"; echo "$hits"; return 1; } ;;
    esac
  done < <(each_file)
}

@test "LF line endings and ASCII only" {
  local f
  while IFS= read -r f; do
    [ "$(tr -cd '\r' < "$f" | wc -c | tr -d ' ')" = 0 ] || { echo "CR in $f"; return 1; }
    [ "$(LC_ALL=C tr -d '\000-\177' < "$f" | wc -c | tr -d ' ')" = 0 ] || { echo "non-ASCII in $f"; return 1; }
  done < <(each_file)
}

@test "scripts start with #!/usr/bin/env bash; sourced files have no shebang" {
  local f
  for f in laptop/tmuxkeep.sh laptop/deploy.sh tests/bats/stubs/ssh tests/bats/stubs/scp tests/bats/stubs/ssh-keygen tests/smoke.sh tests/run-bats.sh; do
    if [ -f "$REPO/$f" ]; then
      [ "$(sed -n 1p "$REPO/$f")" = '#!/usr/bin/env bash' ] || { echo "$f"; return 1; }
    fi
  done
  for f in laptop/completion.bash tests/bats/laptop-helpers.bash; do
    if [ -f "$REPO/$f" ]; then
      case $(sed -n 1p "$REPO/$f") in '#!'*) echo "$f"; return 1 ;; esac
    fi
  done
}
```

- [ ] **Step 6: Run to see them fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/laptop-wrapper.bats`
Expected: `not ok` lines (`laptop/tmuxkeep.sh` does not exist).

- [ ] **Step 7: Create `laptop/tmuxkeep.sh` with exactly this content**

```bash
#!/usr/bin/env bash
# tmuxkeep.sh - laptop wrapper for the tmuxkeep session broker (bash 3.2 and later; macOS, Linux).
# Installed by laptop/deploy.sh as ~/.local/bin/tmuxkeep (mode 0755).
#
#   tmuxkeep <verb> [args...]
#
# Every word is base64-encoded and sent as:
#   ssh -o BatchMode=yes -o ConnectTimeout=5 [-t] tmuxkeep b64 <token>...
# The VPS side is a forced command, so quoting never reaches a remote shell. Exit code: ssh's own,
# or 2 for a local usage error. Written for /bin/bash 3.2 on macOS: no bash 4 features and no
# set -u (3.2 treats an empty array as unset). The bats tests source this file (the guard at the
# end stops before tk_main runs) and redefine tk_prompt, the only function that opens the terminal.

TK_GATED_VERBS="new go send rename unlock rm resume auth"
TK_HINT="tmuxkeep: ssh to host 'tmuxkeep' failed (unreachable, key rejected, or remote killed by signal)"

# tk_encode WORD: base64 of WORD's bytes on one line. GNU base64 wraps at 76 columns, BSD does not.
tk_encode() { printf '%s' "$1" | base64 | tr -d '\n'; }

# tk_is_gated VERB: status 0 when VERB is one of TK_GATED_VERBS (case-sensitive).
tk_is_gated() {
  case " $TK_GATED_VERBS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# tk_ssh_args WORD...: sets the array TK_SSH_ARGS to the full ssh argument list for WORD...
tk_ssh_args() {
  local w
  TK_SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=5)
  if [ "$#" -gt 0 ] && tk_is_gated "$1"; then TK_SSH_ARGS+=(-t); fi
  TK_SSH_ARGS+=(tmuxkeep b64)
  for w in "$@"; do TK_SSH_ARGS+=("$(tk_encode "$w")"); done
}

# tk_prompt LABEL: prints LABEL on the terminal, reads one line from it, prints that line.
tk_prompt() {
  local answer=''
  printf '%s' "$1" > /dev/tty
  IFS= read -r answer < /dev/tty || answer=''
  printf '%s' "$answer"
}

# tk_main WORD...: the wrapper; returns ssh's exit code, or 2 for a local usage error.
tk_main() {
  local w text answer has_now=0 has_confirm=0 rc
  local -a words
  words=("$@")
  for w in "$@"; do
    if [ -z "$w" ]; then printf 'tmuxkeep: empty argument\n' >&2; return 2; fi
  done
  # "send <name>" with no text: ask for it locally and send it as one word.
  if [ "$#" -eq 2 ] && [ "$1" = send ]; then
    text=$(tk_prompt 'Text to send: ')
    if [ -z "$text" ]; then printf 'tmuxkeep: nothing to send\n' >&2; return 2; fi
    words+=("$text")
  fi
  # "rm ... --now" without --confirm: ask for the session name locally.
  if [ "$#" -gt 0 ] && [ "$1" = rm ]; then
    for w in "$@"; do
      case $w in
        --now) has_now=1 ;;
        --confirm) has_confirm=1 ;;
      esac
    done
    if [ "$has_now" = 1 ] && [ "$has_confirm" = 0 ]; then
      answer=$(tk_prompt 'Type the session name to confirm: ')
      if [ -z "$answer" ]; then printf 'tmuxkeep: confirmation required\n' >&2; return 2; fi
      words+=(--confirm "$answer")
    fi
  fi
  tk_ssh_args "${words[@]}"
  # A plain command with the terminal attached: no capture, no redirection (go, the TOTP prompt).
  ssh "${TK_SSH_ARGS[@]}"
  rc=$?
  if [ "$rc" -eq 255 ]; then printf '%s\n' "$TK_HINT" >&2; fi
  return "$rc"
}

[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0
tk_main "$@"
exit $?
```

- [ ] **Step 8: Run until green**

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/laptop-wrapper.bats`: 20 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/lint-laptop.bats`: 6 tests, all `ok`.
- the whole bats directory and the whole Pester folder (G8).

- [ ] **Step 9: Line endings, exec bits, commit**

```bash
grep -rlIU "$(printf '\r')" vps tests laptop/*.sh    # Git Bash; must print nothing
git add .gitattributes tests/bats/laptop-helpers.bash tests/bats/laptop-wrapper.bats tests/bats/lint-laptop.bats
git add --chmod=+x laptop/tmuxkeep.sh tests/bats/stubs/ssh tests/bats/stubs/scp tests/bats/stubs/ssh-keygen
git commit -m "Add bash wrapper (bash 3.2), laptop test stubs and helpers, laptop lint"
```

---

### Task 11: Bash completion

Suggested model: sonnet.

**Files:**
- Create: `laptop/completion.bash` (sourced, no shebang, not executable)
- Create: `tests/bats/completion.bats`

**Interfaces:**
- Consumes (Task 10): `laptop_setup`, `stub_calls`, `REPO`, the stub `ssh` (`TK_STUB_SSH_OUT`, `TK_STUB_SSH_ERR`, `TK_STUB_SSH_RC`, `TK_STUB_LOG`).
- Produces: `complete -F _tmuxkeep tmuxkeep`; functions `_tmuxkeep`, `_tmuxkeep_names KIND`, `_tmuxkeep_mtime FILE`; two one-line lists that Task 15 parses, exactly `_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth"` and `_TK_NAME_VERBS="peek go send rename lock unlock rm resume"`. Task 13's rc block sources this file from `~/.tmuxkeep/completion.bash`, in bash and in zsh through `bashcompinit`.

**Behaviour (spec 6.4; plan Q15):**
- First word: the thirteen verbs. Second word: session names after a name verb, tombstone base names after `restore`, nothing otherwise. Third and later words: nothing.
- Names come from `ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 tmuxkeep ls --names` (or `--tombstones`), stderr discarded with `2>/dev/null` (the one stderr discard on the laptop's bash side, G23).
- Cache: `${TMPDIR:-/tmp}` with any trailing `/` removed, then `/tmuxkeep-<kind>-<uid>.txt`, where `<kind>` is `names` or `tombstones` and `<uid>` is `id -u`. Fresh when `0 <= now - mtime < 60`; a future-dated file is not fresh. The modification time comes from `stat -c %Y` when `uname -s` is `Linux` and `stat -f %m` otherwise (plan Q15: no stderr discard needed to pick the variant). A failed fetch writes an empty file, so an offline laptop does not wait at every Tab. A cache path that is a symlink, or exists and is not owned by the current user (`[ -O ]`), is neither read nor written (another user could plant one in a shared `/tmp`); the names are fetched each time instead.
- Matching is a literal prefix match (`case $w in "$cur"*)`), so `[`, `*` and `?` in the typed word are not patterns.
- Works when zsh sources it through `bashcompinit`: no bash-only syntax beyond `local`, `[ ]`, `case`, `COMPREPLY+=(...)` and a here-document; no `compgen`, no process substitution, no `$'...'`.
- bash 3.2 rules (G19-G21).

Write the file exactly as follows:

```bash
# completion.bash - tab completion for the tmuxkeep command (bash 3.2 and later; zsh through
# bashcompinit). Installed by laptop/deploy.sh as ~/.tmuxkeep/completion.bash and sourced from
# ~/.bashrc or ~/.zshrc. First word: the verbs. Second word: session names for the verbs that take
# one, tombstone base names after restore. Names come from "ssh tmuxkeep ls --names" (or
# --tombstones), cached for 60 seconds under ${TMPDIR:-/tmp}; a failed fetch caches an empty file so
# an offline laptop does not wait at every Tab. That ssh is the only place on the laptop's bash side
# that discards stderr.

_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth"
_TK_NAME_VERBS="peek go send rename lock unlock rm resume"

# _tmuxkeep_mtime FILE: modification time in epoch seconds (GNU stat on Linux, BSD stat elsewhere).
_tmuxkeep_mtime() {
  case $(uname -s) in
    Linux) stat -c %Y "$1" ;;
    *) stat -f %m "$1" ;;
  esac
}

# _tmuxkeep_names KIND: names or tombstones, one per line, from a cache younger than 60 seconds or
# from the broker. A cache path that is a symlink or belongs to another user is never used.
_tmuxkeep_names() {
  local kind=$1 file now mtime out trusted=1
  file=${TMPDIR:-/tmp}
  file="${file%/}/tmuxkeep-$kind-$(id -u).txt"
  if [ -L "$file" ] || { [ -e "$file" ] && [ ! -O "$file" ]; }; then trusted=0; fi
  if [ "$trusted" = 1 ] && [ -f "$file" ]; then
    now=$(date +%s)
    mtime=$(_tmuxkeep_mtime "$file")
    case $mtime in ''|*[!0-9]*) mtime=0 ;; esac
    if [ $(( now - mtime )) -ge 0 ] && [ $(( now - mtime )) -lt 60 ]; then
      cat "$file"
      return 0
    fi
  fi
  out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 tmuxkeep ls "--$kind" 2>/dev/null) || out=''
  if [ "$trusted" = 1 ]; then
    if [ -n "$out" ]; then printf '%s\n' "$out" > "$file"; else : > "$file"; fi
  fi
  if [ -n "$out" ]; then printf '%s\n' "$out"; fi
  return 0
}

_tmuxkeep() {
  local cur words w nl='
'
  COMPREPLY=()
  cur=${COMP_WORDS[COMP_CWORD]}
  if [ "$COMP_CWORD" -eq 1 ]; then
    words=${_TK_VERBS// /$nl}
  elif [ "$COMP_CWORD" -eq 2 ]; then
    case " $_TK_NAME_VERBS " in
      *" ${COMP_WORDS[1]} "*) words=$(_tmuxkeep_names names) ;;
      *)
        if [ "${COMP_WORDS[1]}" = restore ]; then
          words=$(_tmuxkeep_names tombstones)
        else
          return 0
        fi ;;
    esac
  else
    return 0
  fi
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    case $w in "$cur"*) COMPREPLY+=("$w") ;; esac
  done <<EOF
$words
EOF
}

complete -F _tmuxkeep tmuxkeep
```

- [ ] **Step 1: Write the failing test `tests/bats/completion.bats`**

```bash
#!/usr/bin/env bats
# laptop/completion.bash (spec 6.4, plan Q15): verbs, cached names and tombstones, failure caching,
# literal prefixes, symlinked caches. ssh is a stub.
load laptop-helpers

setup() {
  laptop_setup
  # shellcheck source=/dev/null
  source "$REPO/laptop/completion.bash"
  printf 'api\nweb\na[b\n' > "$BATS_TEST_TMPDIR/names.out"
  export TK_STUB_SSH_OUT="$BATS_TEST_TMPDIR/names.out"
  CACHE="$TMPDIR/tmuxkeep-names-$(id -u).txt"
  TOMB_CACHE="$TMPDIR/tmuxkeep-tombstones-$(id -u).txt"
}

# complete_words WORD...: runs _tmuxkeep with the cursor on the last word; prints COMPREPLY, one per line.
complete_words() {
  COMP_WORDS=("$@")
  COMP_CWORD=$(( $# - 1 ))
  _tmuxkeep
  if [ "${#COMPREPLY[@]}" -gt 0 ]; then printf '%s\n' "${COMPREPLY[@]}"; fi
}

@test "sourcing registers the completer and the two one-line lists" {
  run complete -p tmuxkeep
  [ "$output" = 'complete -F _tmuxkeep tmuxkeep' ]
  grep -qx '_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth"' "$REPO/laptop/completion.bash"
  grep -qx '_TK_NAME_VERBS="peek go send rename lock unlock rm resume"' "$REPO/laptop/completion.bash"
}

@test "the first word completes the verbs" {
  run complete_words tmuxkeep re
  [ "$output" = "$(printf '%s\n' rename restore resume)" ]
  run complete_words tmuxkeep ''
  [ "${#lines[@]}" -eq 13 ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "session names after a name verb, fetched with the exact ssh arguments" {
  run complete_words tmuxkeep go a
  [ "$output" = "$(printf '%s\n' api 'a[b')" ]
  [ "$(stub_calls)" = 'ssh [-n] [-o] [BatchMode=yes] [-o] [ConnectTimeout=5] [-o] [ServerAliveInterval=2] [-o] [ServerAliveCountMax=2] [tmuxkeep] [ls] [--names]' ]
  [ -f "$CACHE" ]
}

@test "a second Tab within 60 seconds is served from the cache" {
  run complete_words tmuxkeep peek ''
  run complete_words tmuxkeep send w
  [ "$output" = web ]
  [ "$(stub_calls | grep -c .)" -eq 1 ]
}

@test "restore completes tombstone base names from its own cache" {
  printf 'old\n' > "$BATS_TEST_TMPDIR/tombs.out"
  export TK_STUB_SSH_OUT="$BATS_TEST_TMPDIR/tombs.out"
  run complete_words tmuxkeep restore ''
  [ "$output" = old ]
  [[ "$(stub_calls)" == *'[ls] [--tombstones]' ]]
  [ -f "$TOMB_CACHE" ]
}

@test "a cache older than 60 seconds, or dated in the future, is fetched again" {
  printf 'stale\n' > "$CACHE"
  touch -t 200001010000 "$CACHE"
  run complete_words tmuxkeep go ''
  [[ "$output" == *api* ]]
  [[ "$output" != *stale* ]]
  printf 'stale\n' > "$CACHE"
  touch -t 209901010000 "$CACHE"
  run complete_words tmuxkeep go ''
  [[ "$output" != *stale* ]]
  [ "$(stub_calls | grep -c .)" -eq 2 ]
}

@test "a failed fetch is cached as an empty file for 60 seconds" {
  export TK_STUB_SSH_RC=255
  run complete_words tmuxkeep go ''
  [ -z "$output" ]
  [ -f "$CACHE" ]
  [ ! -s "$CACHE" ]
  run complete_words tmuxkeep go ''
  [ "$(stub_calls | grep -c .)" -eq 1 ]
}

@test "ssh's stderr is discarded" {
  export TK_STUB_SSH_ERR='Warning: Permanently added the host key'
  run --separate-stderr complete_words tmuxkeep go a
  [ -z "$stderr" ]
  [[ "$output" == *api* ]]
}

@test "no names after new, and nothing for a third word" {
  run complete_words tmuxkeep new ''
  [ -z "$output" ]
  run complete_words tmuxkeep go api ''
  [ -z "$output" ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "the typed prefix is matched literally, so a bracket is not a pattern" {
  run complete_words tmuxkeep go 'a['
  [ "$output" = 'a[b' ]
  run complete_words tmuxkeep go '*'
  [ -z "$output" ]
}

@test "a symlinked cache is neither read nor written through (plan Q15)" {
  printf 'planted\n' > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$CACHE"
  run complete_words tmuxkeep go ''
  [[ "$output" == *api* ]]
  [[ "$output" != *planted* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = planted ]
  [ -L "$CACHE" ]
}

@test "TMPDIR with a trailing slash still gives one cache path" {
  export TMPDIR="$TMPDIR/"
  run complete_words tmuxkeep go ''
  [ -f "$CACHE" ]
}
```

- [ ] **Step 2: Run to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/completion.bats`
Expected: `not ok` lines (the file does not exist).

- [ ] **Step 3: Create `laptop/completion.bash` with the content above**

- [ ] **Step 4: Run until green**

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/completion.bats`: 12 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/lint-laptop.bats`: 6 tests, all `ok` (it now covers `laptop/completion.bash`).
- the whole bats directory and the whole Pester folder (G8).

- [ ] **Step 5: Line endings, commit**

```bash
grep -lU "$(printf '\r')" laptop/completion.bash tests/bats/completion.bats    # Git Bash; must print nothing
git check-attr eol -- laptop/completion.bash                                    # must print: laptop/completion.bash: eol: lf
git add laptop/completion.bash tests/bats/completion.bats
git commit -m "Add bash completion: verbs, cached names and tombstones, symlink-safe cache"
```

---

### Task 12: Bash deploy: laptop config functions

Suggested model: sonnet.

**Files:**
- Create: `laptop/deploy.sh` (executable; functions only in this task, no main sequence and no source guard yet)
- Create: `tests/bats/laptop-config.bats`

**Interfaces:**
- Consumes: Task 10's `laptop-helpers.bash` (`laptop_setup`, `REPO`), the bash 3.2 rules G19-G23; Task 7's fixture `tests/fixtures/laptop-config` and Task 5's fixture `tests/fixtures/deploy.conf` (both listed in full below; the bash writers must reproduce them byte for byte, which is what keeps the two deploys identical).
- Produces (Tasks 13 and 14 add to the same file; the tests `source` it):
  - One line exactly `TK_CONF_KEYS="HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES"`.
  - Globals `TKC_HOST TKC_PORT TKC_USER TKC_KEY TKC_ADMIN_KEY TKC_LAUNCH_CMD TKC_RESUME_CMD TKC_INSTALL_CLAUDE_CODE TKC_LEASE_SECS TKC_TOMBSTONE_TTL TKC_OTP_FAIL_MAX TKC_OTP_FAIL_WINDOW TKC_OTP_COOLDOWN TKC_OTP_HARD_MAX TKC_OTP_READ_TIMEOUT TKC_SEND_MAX_BYTES`, `TK_ERR`, `TK_TRIMMED`.
  - Functions: `tk_conf_defaults`; `tk_trim STRING` (sets `TK_TRIMMED`); `tk_printable STRING`; `tk_is_conf_key KEY`; `tk_check_int KEY VALUE LO HI`; `tk_conf_validate` (sets `TK_ERR` to the bare reason); `tk_conf_read FILE` (sets `TK_ERR="<FILE>: <reason>"`); `tk_conf_text` (prints the file); `tk_conf_write FILE`; `tk_prompt LABEL` (the only function that opens `/dev/tty`); `tk_conf_create FILE`; `tk_deploy_conf_text` (prints `deploy.conf`); `tk_expand_path PATH` (prints).

**Behaviour (spec 4.1, 4.2, 4.3, 6.4; G19-G23, G30-G32; plan Q5, Q14; Review Focus 2):** the same rules and messages as Task 7's PowerShell functions.

- Header (first lines of the file):

  ```bash
  #!/usr/bin/env bash
  # deploy.sh - operator deploy for tmuxkeep from macOS or Linux (bash 3.2 and later). Spec 6.1, 6.4.
  #
  #   bash laptop/deploy.sh [--config <path>] [--init] [--harden-root] [--rotate-totp] [--unlock-otp]
  #
  # Agents never run this script themselves. The bats tests source it (functions only) and run it as
  # a child process from a temporary git copy, with stub ssh, scp and ssh-keygen first on PATH and
  # HOME in a temp directory. bash 3.2 rules: no bash 4 features, no set -u, no GNU-only tools.

  TK_CONF_KEYS="HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES"
  ```

- `tk_conf_defaults` assigns all sixteen `TKC_*` (G32 defaults, `TKC_HOST=''`). Write the two key paths with an escaped tilde, `TKC_KEY=\~/.ssh/id_tmuxkeep_ed25519` and `TKC_ADMIN_KEY=\~/.ssh/id_tmuxkeep_admin_ed25519`: a quoted `'~/...'` is shellcheck warning SC2088.
- Helpers:

  ```bash
  # tk_trim STRING: sets TK_TRIMMED to STRING without leading and trailing spaces and tabs.
  tk_trim() {
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
  ```

- `tk_conf_validate` checks in G32 order and sets `TK_ERR` to the bare message: empty `TKC_HOST` gives `HOST: required`; count colons with `colons=${TKC_HOST//[!:]/}` and exactly one gives the host:port message; then `re='^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$'`; `tk_check_int PORT ... 1 65535`; `USER` against `^[a-z_][a-z0-9_-]{0,31}$` (through a variable `re`); `KEY` and `ADMIN_KEY` non-empty and without `"` (`[[ $TKC_KEY == *'"'* ]]`); `${#TKC_LAUNCH_CMD}` and `${#TKC_RESUME_CMD}` at most 200; `INSTALL_CLAUDE_CODE` through `case ... in yes|no)`; then the eight `tk_check_int` calls, `OTP_HARD_MAX` with `LO=$(( 10#$TKC_OTP_FAIL_MAX ))`.
- `tk_conf_read FILE`:

  ```bash
  # tk_conf_read FILE: sets every TKC_* from FILE over the defaults (spec 4.1; HOST required, other
  # missing keys default, plan Q5) and returns 0, or sets TK_ERR to "<FILE>: <reason>" and returns 1.
  tk_conf_read() {
    local file=$1 line key val n=0 re_key='^[A-Z_]+$' re_name='^[A-Za-z0-9_]{1,64}$'
    TK_ERR=''
    tk_conf_defaults
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then TK_ERR="$file: cannot read"; return 1; fi
    if [ "$(head -c 3 "$file" | od -An -tx1 | tr -d ' \n')" = efbbbf ]; then
      TK_ERR="$file: byte order mark found (save without BOM)"; return 1
    fi
    if [ "$(tr -cd '\r' < "$file" | wc -c | tr -d ' ')" != 0 ]; then
      TK_ERR="$file: carriage return found (use LF line endings)"; return 1
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
  ```

- `tk_conf_text` prints exactly the fixture text with the current `TKC_*` values. Write it as one `printf '%s\n'` call whose arguments are the 35 lines, the fixed ones single-quoted and each `KEY=value` line as `"KEY=$TKC_KEYNAME"`. The fixture (35 lines, LF):

  ```
  # tmuxkeep laptop configuration, written by the deploy script. Edit it by hand if you like:
  # one KEY=value per line, no quotes. Run the deploy script again after a change.

  # VPS address: hostname, IPv4 or IPv6 literal.
  HOST=203.0.113.10
  # SSH port of the VPS.
  PORT=22
  # Account on the VPS that owns the tmux sessions; the installer creates it.
  USER=claude
  # Session key, no passphrase. ~ is your home directory.
  KEY=~/.ssh/id_tmuxkeep_ed25519
  # Admin key for root, with a passphrase. Never add it to ssh-agent.
  ADMIN_KEY=~/.ssh/id_tmuxkeep_admin_ed25519
  # Typed into every new session; empty opens a shell only.
  LAUNCH_CMD=claude
  # Typed by resume; empty opens a shell only.
  RESUME_CMD=claude --continue
  # yes installs Claude Code for USER on the next deploy.
  INSTALL_CLAUDE_CODE=no
  # Seconds one TOTP code keeps the gated verbs open (60-86400).
  LEASE_SECS=1800
  # Seconds a removed session survives as a tombstone (3600-2592000).
  TOMBSTONE_TTL=86400
  # Wrong codes within OTP_FAIL_WINDOW that start a cooldown (1-20).
  OTP_FAIL_MAX=3
  # Seconds over which wrong codes are counted (60-86400).
  OTP_FAIL_WINDOW=600
  # Seconds of cooldown after OTP_FAIL_MAX wrong codes (10-86400).
  OTP_COOLDOWN=300
  # Wrong codes since the last good one that lock the gate until root clears it (OTP_FAIL_MAX-100).
  OTP_HARD_MAX=10
  # Seconds the VPS waits at the TOTP prompt (10-600).
  OTP_READ_TIMEOUT=60
  # Largest text that send accepts, in bytes (1-65536).
  SEND_MAX_BYTES=8000
  ```

- `tk_deploy_conf_text` prints the header line `# Written by tmuxkeep deploy from the laptop config; read by tmuxkeep-setup --conf.` and then `USER=`, `LAUNCH_CMD=`, `RESUME_CMD=`, `INSTALL_CLAUDE_CODE=`, `LEASE_SECS=`, `TOMBSTONE_TTL=`, `OTP_FAIL_MAX=`, `OTP_FAIL_WINDOW=`, `OTP_COOLDOWN=`, `OTP_HARD_MAX=`, `OTP_READ_TIMEOUT=`, `SEND_MAX_BYTES=` lines with the `TKC_*` values. For the defaults it equals `tests/fixtures/deploy.conf`:

  ```
  # Written by tmuxkeep deploy from the laptop config; read by tmuxkeep-setup --conf.
  USER=claude
  LAUNCH_CMD=claude
  RESUME_CMD=claude --continue
  INSTALL_CLAUDE_CODE=no
  LEASE_SECS=1800
  TOMBSTONE_TTL=86400
  OTP_FAIL_MAX=3
  OTP_FAIL_WINDOW=600
  OTP_COOLDOWN=300
  OTP_HARD_MAX=10
  OTP_READ_TIMEOUT=60
  SEND_MAX_BYTES=8000
  ```

- `tk_conf_write FILE`: `mkdir -p "$(dirname "$1")"` (failure: `TK_ERR="$1: cannot create its folder"`, return 1), then `tk_conf_text > "$1"` (failure: `TK_ERR="$1: cannot write"`, return 1).
- `tk_prompt LABEL`: the same code as in `laptop/tmuxkeep.sh` (prints LABEL to `/dev/tty`, reads one line from `/dev/tty`, prints it; an unreadable terminal gives an empty answer).
- `tk_conf_create FILE`: `answer=$(tk_prompt 'VPS address (hostname or IP): ')`, `tk_conf_defaults`, trim the answer into `TKC_HOST`, `tk_conf_validate` (failure: `TK_ERR="$1: $TK_ERR"`, return 1, nothing written), then `tk_conf_write "$1"`.
- `tk_expand_path PATH`: `~` alone prints `$HOME`; `~/rest` prints `$HOME/rest`; anything else prints unchanged. Write the case patterns as `\~)` and `\~/*)` (SC2088), and strip with `${1#\~/}`.

- [ ] **Step 1: Write the failing test `tests/bats/laptop-config.bats`**

```bash
#!/usr/bin/env bats
# laptop/deploy.sh config functions (spec 4.1, 4.2, 4.3; plan Q5, Q14; Review Focus 2). The file is
# sourced, so only its functions run. Same table of cases as tests/pester/config.Tests.ps1.
load laptop-helpers

setup() {
  laptop_setup
  # shellcheck source=/dev/null
  source "$REPO/laptop/deploy.sh"
  FIX="$REPO/tests/fixtures/laptop-config"
  C="$BATS_TEST_TMPDIR/config"
}

# with_line KEY VALUE: the fixture with KEY's line replaced, written to $C.
with_line() {
  TK_K=$1 TK_V=$2 awk 'BEGIN { k = ENVIRON["TK_K"]; v = ENVIRON["TK_V"] }
    index($0, k "=") == 1 { print k "=" v; next } { print }' "$FIX" > "$C"
}

# reason FILE: what tk_conf_read reports for FILE, or "no error".
reason() {
  if tk_conf_read "$1"; then echo 'no error'; else printf '%s\n' "$TK_ERR"; fi
}

@test "reads the fixture" {
  tk_conf_read "$FIX"
  [ "$TKC_HOST" = 203.0.113.10 ]
  [ "$TKC_PORT" = 22 ]
  [ "$TKC_KEY" = '~/.ssh/id_tmuxkeep_ed25519' ]
  [ "$TKC_RESUME_CMD" = 'claude --continue' ]
  [ "$TKC_SEND_MAX_BYTES" = 8000 ]
}

@test "tk_conf_text for the defaults and HOST=203.0.113.10 is the fixture, byte for byte" {
  tk_conf_defaults
  TKC_HOST=203.0.113.10
  tk_conf_text > "$C"
  cmp "$C" "$FIX"
}

@test "tk_conf_write creates the folder and writes the same bytes" {
  tk_conf_defaults
  TKC_HOST=203.0.113.10
  tk_conf_write "$HOME/.tmuxkeep/config"
  cmp "$HOME/.tmuxkeep/config" "$FIX"
}

@test "a missing key other than HOST takes its default; a missing HOST is required" {
  grep -v '^PORT=' "$FIX" > "$C"
  TKC_PORT=999
  tk_conf_read "$C"
  [ "$TKC_PORT" = 22 ]
  grep -v '^HOST=' "$FIX" > "$C"
  [ "$(reason "$C")" = "$C: HOST: required" ]
}

@test "blank lines, comments, padding and a repeated key (the last wins)" {
  { printf '\n# note\n \t \n'
    sed 's/^\([A-Z_]*\)=\(.*\)$/  \1 = \2  /' "$FIX"
    printf 'PORT=2200\nPORT=2222\n'
  } > "$C"
  tk_conf_read "$C"
  [ "$TKC_PORT" = 2222 ]
  [ "$TKC_HOST" = 203.0.113.10 ]
  [ "$TKC_RESUME_CMD" = 'claude --continue' ]
}

@test "rejects each invalid value with the key named" {
  local k v want
  while IFS='|' read -r k v want; do
    with_line "$k" "$v"
    [ "$(reason "$C")" = "$C: $want" ] || { echo "$k=$v: $(reason "$C")"; return 1; }
  done <<'EOF'
HOST||HOST: required
HOST|203.0.113.10:2222|HOST: looks like host:port; put the port in PORT
HOST|you@203.0.113.10|HOST: not a hostname, IPv4 or IPv6 address
HOST|-x.example|HOST: not a hostname, IPv4 or IPv6 address
PORT|0|PORT: must be an integer from 1 to 65535
PORT|65536|PORT: must be an integer from 1 to 65535
PORT|ssh|PORT: must be an integer from 1 to 65535
USER|Bob|USER: must match ^[a-z_][a-z0-9_-]{0,31}$
KEY||KEY: must be a non-empty path without double quotes
KEY|a"b|KEY: must be a non-empty path without double quotes
ADMIN_KEY||ADMIN_KEY: must be a non-empty path without double quotes
INSTALL_CLAUDE_CODE|Yes|INSTALL_CLAUDE_CODE: must be yes or no
LEASE_SECS|59|LEASE_SECS: must be an integer from 60 to 86400
LEASE_SECS|86401|LEASE_SECS: must be an integer from 60 to 86400
LEASE_SECS|-60|LEASE_SECS: must be an integer from 60 to 86400
LEASE_SECS|00001800|LEASE_SECS: must be an integer from 60 to 86400
TOMBSTONE_TTL|3599|TOMBSTONE_TTL: must be an integer from 3600 to 2592000
TOMBSTONE_TTL|2592001|TOMBSTONE_TTL: must be an integer from 3600 to 2592000
OTP_FAIL_MAX|0|OTP_FAIL_MAX: must be an integer from 1 to 20
OTP_FAIL_MAX|21|OTP_FAIL_MAX: must be an integer from 1 to 20
OTP_FAIL_WINDOW|59|OTP_FAIL_WINDOW: must be an integer from 60 to 86400
OTP_COOLDOWN|9|OTP_COOLDOWN: must be an integer from 10 to 86400
OTP_HARD_MAX|2|OTP_HARD_MAX: must be an integer from 3 to 100
OTP_HARD_MAX|101|OTP_HARD_MAX: must be an integer from 3 to 100
OTP_READ_TIMEOUT|601|OTP_READ_TIMEOUT: must be an integer from 10 to 600
SEND_MAX_BYTES|0|SEND_MAX_BYTES: must be an integer from 1 to 65536
SEND_MAX_BYTES|65537|SEND_MAX_BYTES: must be an integer from 1 to 65536
EOF
  with_line LAUNCH_CMD "$(printf 'x%.0s' $(seq 1 201))"
  [ "$(reason "$C")" = "$C: LAUNCH_CMD: at most 200 characters" ]
  with_line RESUME_CMD "$(printf 'x%.0s' $(seq 1 201))"
  [ "$(reason "$C")" = "$C: RESUME_CMD: at most 200 characters" ]
}

@test "accepts the bounds and the edge values" {
  local k v
  while IFS='|' read -r k v; do
    with_line "$k" "$v"
    [ "$(reason "$C")" = 'no error' ] || { echo "$k=$v: $(reason "$C")"; return 1; }
  done <<'EOF'
HOST|2001:db8::1
HOST|vps-1.example.org
PORT|65535
USER|_svc
KEY|~/my keys/k
LAUNCH_CMD|
LEASE_SECS|0060
TOMBSTONE_TTL|2592000
OTP_HARD_MAX|3
SEND_MAX_BYTES|65536
EOF
}

@test "rejects a BOM, a CR, a line without =, an unknown key and non-printable values, naming the file" {
  local n=$(( $(wc -l < "$FIX") + 1 ))
  { printf '\357\273\277'; cat "$FIX"; } > "$C"
  [ "$(reason "$C")" = "$C: byte order mark found (save without BOM)" ]
  awk '{ printf "%s\r\n", $0 }' "$FIX" > "$C"
  [ "$(reason "$C")" = "$C: carriage return found (use LF line endings)" ]
  { cat "$FIX"; printf 'just words\n'; } > "$C"
  [ "$(reason "$C")" = "$C: line $n: expected KEY=value" ]
  { cat "$FIX"; printf 'FROB=1\n'; } > "$C"
  [ "$(reason "$C")" = "$C: line $n: unknown key FROB" ]
  { cat "$FIX"; printf 'host=x\n'; } > "$C"
  [ "$(reason "$C")" = "$C: line $n: unknown key host" ]
  { cat "$FIX"; printf 'B@D=1\n'; } > "$C"
  [ "$(reason "$C")" = "$C: line $n: unknown key" ]
  with_line LAUNCH_CMD "$(printf 'caf\303\251')"
  [[ "$(reason "$C")" == *': non-printable or non-ASCII character in LAUNCH_CMD' ]]
  with_line LAUNCH_CMD "$(printf 'a\tb')"
  [[ "$(reason "$C")" == *': non-printable or non-ASCII character in LAUNCH_CMD' ]]
}

@test "the first-run prompt asks once, trims the answer and writes the fixture" {
  tk_prompt() { printf '%s\n' "$1" >> "$BATS_TEST_TMPDIR/prompts"; printf '%s' ' 203.0.113.10 '; }
  tk_conf_create "$HOME/.tmuxkeep/config"
  [ "$(cat "$BATS_TEST_TMPDIR/prompts")" = 'VPS address (hostname or IP): ' ]
  [ "$TKC_HOST" = 203.0.113.10 ]
  cmp "$HOME/.tmuxkeep/config" "$FIX"
}

@test "the first-run prompt rejects host:port, user@host and blanks, and writes nothing (Review Focus 2)" {
  local a want
  while IFS='|' read -r a want; do
    TK_ANSWER=$a
    tk_prompt() { printf '%s' "$TK_ANSWER"; }
    rm -rf "$HOME/.tmuxkeep"
    if tk_conf_create "$HOME/.tmuxkeep/config"; then echo "accepted '$a'"; return 1; fi
    [ "$TK_ERR" = "$HOME/.tmuxkeep/config: $want" ] || { echo "$TK_ERR"; return 1; }
    [ ! -e "$HOME/.tmuxkeep/config" ] || { echo "wrote a config for '$a'"; return 1; }
  done <<'EOF'
203.0.113.10:2222|HOST: looks like host:port; put the port in PORT
you@203.0.113.10|HOST: not a hostname, IPv4 or IPv6 address
|HOST: required
   |HOST: required
EOF
}

@test "tk_deploy_conf_text on the defaults is the deploy.conf fixture, and carries the configured values" {
  tk_conf_defaults
  TKC_HOST=203.0.113.10
  tk_deploy_conf_text > "$C"
  cmp "$C" "$REPO/tests/fixtures/deploy.conf"
  TKC_USER=bob
  TKC_LAUNCH_CMD=''
  TKC_LEASE_SECS=600
  run tk_deploy_conf_text
  printf '%s\n' "$output" | grep -qx 'USER=bob'
  printf '%s\n' "$output" | grep -qx 'LAUNCH_CMD='
  printf '%s\n' "$output" | grep -qx 'LEASE_SECS=600'
  [ "$(printf '%s\n' "$output" | grep -cE 'HOST|PORT|KEY=')" = 0 ]
}

@test "tk_expand_path expands only a leading tilde" {
  [ "$(tk_expand_path '~/.ssh/k')" = "$HOME/.ssh/k" ]
  [ "$(tk_expand_path '~')" = "$HOME" ]
  [ "$(tk_expand_path /keys/k)" = /keys/k ]
  [ "$(tk_expand_path 'a~/k')" = 'a~/k' ]
}

@test "the key list is one line" {
  grep -qx 'TK_CONF_KEYS="HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES"' "$REPO/laptop/deploy.sh"
}
```

- [ ] **Step 2: Run to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/laptop-config.bats`
Expected: `not ok` lines (`laptop/deploy.sh` does not exist).

- [ ] **Step 3: Write `laptop/deploy.sh` with the header and the functions above. Do not add a main sequence or a source guard yet.**

- [ ] **Step 4: Run until green**

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/laptop-config.bats`: 13 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/lint-laptop.bats`: 6 tests, all `ok` (it now covers `laptop/deploy.sh`).
- the whole bats directory and the whole Pester folder (G8).

- [ ] **Step 5: Line endings, exec bit, commit**

```bash
grep -lU "$(printf '\r')" laptop/deploy.sh tests/bats/laptop-config.bats    # Git Bash; must print nothing
git add --chmod=+x laptop/deploy.sh
git add tests/bats/laptop-config.bats
git commit -m "deploy.sh: laptop config read, write, first-run prompt and deploy.conf text (bash 3.2)"
```

---

### Task 13: Bash deploy: ssh config and rc blocks (symlinks, zsh)

Suggested model: sonnet.

**Files:**
- Modify: `laptop/deploy.sh` (add functions; still no main sequence)
- Modify: `tests/docker/Dockerfile` (add `zsh`)
- Modify: `tests/bats/00-env.bats` (require `zsh`)
- Create: `tests/bats/laptop-blocks.bats`

**Interfaces:**
- Consumes: Task 12 (`tk_conf_defaults`, the `TKC_*` globals, `TK_ERR`); Task 11's `laptop/completion.bash`; Task 8's fixture `tests/fixtures/ssh-block` (16 lines: `# >>> tmuxkeep`, `Host tmuxkeep`, `    HostName 203.0.113.10`, `    Port 22`, `    User claude`, `    IdentityFile ~/.ssh/id_tmuxkeep_ed25519`, `    IdentitiesOnly yes`, `    ServerAliveInterval 30`, `    ServerAliveCountMax 4`, `Host tmuxkeep-admin`, `    HostName 203.0.113.10`, `    Port 22`, `    User root`, `    IdentityFile ~/.ssh/id_tmuxkeep_admin_ed25519`, `    IdentitiesOnly yes`, `# <<< tmuxkeep`; LF).
- Produces (Task 14 calls them):
  - `tk_ssh_value VALUE`: prints VALUE, in double quotes when it contains a space (plan Q10).
  - `tk_ssh_block`: prints the 16 block lines (each ending in LF) from `TKC_HOST`, `TKC_PORT`, `TKC_USER`, `TKC_KEY`, `TKC_ADMIN_KEY`; for the defaults with `TKC_HOST=203.0.113.10` it equals the fixture.
  - `tk_rc_block`: prints the 5-line rc block below.
  - `tk_rc_file`: prints `$HOME/.zshrc` when `$SHELL` ends in `zsh`, else `$HOME/.bashrc`.
  - `tk_set_block FILE TEXT`: write-or-replace; TEXT is the block's lines without a final newline (callers pass `"$(tk_ssh_block)"`); returns 1 with `TK_ERR="<path>: <reason>"`.
  - The test image gains `zsh`.

**Behaviour (spec 6.1 step 3, 6.4, 12; plan Q3, Q10; Review Focus 3, 4):**
- The rc block (plan Q3). The spec's second line runs `bashcompinit` only; bashcompinit's `complete` calls zsh's `compdef`, which exists only after `compinit`, and a fresh macOS account's zsh never runs `compinit`, so every new shell would print `complete:13: command not found: compdef`. The block loads `compinit` when `compdef` is missing. Exactly:

  ```
  # >>> tmuxkeep
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
  [ -n "$ZSH_VERSION" ] && { whence compdef >/dev/null || { autoload -U +X compinit && compinit -i; }; } && autoload -U +X bashcompinit && bashcompinit
  [ -f "$HOME/.tmuxkeep/completion.bash" ] && . "$HOME/.tmuxkeep/completion.bash"
  # <<< tmuxkeep
  ```

  Print it with single-quoted `printf '%s\n'` arguments (shellcheck reports SC2016 at info level only).
- `tk_set_block` (Review Focus 3: write through symlinks, keep mode and owner):

  ```bash
  # tk_set_block FILE TEXT: write-or-replace the marked block TEXT (its lines, without a final
  # newline) in FILE (spec 6.1 step 3, 6.4). An existing block is replaced in place, an identical one
  # is left alone, a missing one is appended after a blank line. The new text is written with
  # "cat tmp > FILE", which follows a symlink and keeps FILE's mode and owner, so a dotfiles link
  # stays a link (Review Focus 3).
  tk_set_block() {
    local file=$1 block=$2 dir tmp state
    TK_ERR=''
    if [ -d "$file" ]; then TK_ERR="$file: is a directory"; return 1; fi
    if [ -e "$file" ] && [ ! -w "$file" ]; then TK_ERR="$file: not writable"; return 1; fi
    dir=$(dirname "$file")
    if ! mkdir -p "$dir"; then TK_ERR="$dir: cannot create"; return 1; fi
    if [ ! -e "$file" ] && ! : > "$file"; then TK_ERR="$file: cannot create"; return 1; fi
    state=$(awk '$0 == "# >>> tmuxkeep" { b++; open = 1; next }
                 $0 == "# <<< tmuxkeep" && open { e++; open = 0 }
                 END { if (b > 1) print "many"; else if (b == 1 && e == 0) print "open"; else print "ok" }' "$file")
    case $state in
      many) TK_ERR="$file: more than one '# >>> tmuxkeep' line; remove the extra block by hand"; return 1 ;;
      open) TK_ERR="$file: '# >>> tmuxkeep' without '# <<< tmuxkeep'; fix it by hand"; return 1 ;;
    esac
    tmp=$(mktemp "${TMPDIR:-/tmp}/tmuxkeep-block.XXXXXX") || { TK_ERR="$file: cannot create a temporary file"; return 1; }
    TK_BLOCK=$block awk '
      BEGIN { blk = ENVIRON["TK_BLOCK"] }
      $0 == "# >>> tmuxkeep" { print blk; skip = 1; done = 1; next }
      skip == 1 { if ($0 == "# <<< tmuxkeep") skip = 0; next }
      { print }
      END { if (!done) { if (NR > 0) print ""; print blk } }
    ' "$file" > "$tmp"
    if cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 0; fi
    if ! cat "$tmp" > "$file"; then rm -f "$tmp"; TK_ERR="$file: cannot write"; return 1; fi
    rm -f "$tmp"
  }
  ```

  awk's `print` ends the block with a newline, and adds one to a last line that lacked it, so "append" also fixes a missing final newline. Matching is on whole lines, so a longer marker such as `# >>> tmuxkeep path` is not ours. No `AddKeysToAgent` anywhere (G3).

- [ ] **Step 1: Add `zsh` to the test image**

In `tests/docker/Dockerfile`, change the package line `      openssh-server sudo shellcheck procps \` to `      openssh-server sudo shellcheck procps zsh \`, and add a comment line above the `RUN apt-get update` line: `# zsh is for the laptop rc-block test (plan Review Focus 4).`

In `tests/bats/00-env.bats`, in the test `"required tools are present"`, change the loop list `for t in bash tmux bats oathtool jq script flock base64 base32 git visudo shellcheck timeout; do` to `for t in bash tmux bats oathtool jq script flock base64 base32 git visudo shellcheck timeout zsh; do`.

- [ ] **Step 2: Write the failing test `tests/bats/laptop-blocks.bats`**

```bash
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
  [ "${#lines[@]}" -eq 16 ]
  [ "${lines[2]}" = '    HostName 2001:db8::5' ]
  [ "${lines[3]}" = '    Port 2222' ]
  [ "${lines[4]}" = '    User bob' ]
  [ "${lines[5]}" = '    IdentityFile "~/my keys/k"' ]
  [ "${lines[12]}" = '    User root' ]
  [ "${lines[13]}" = '    IdentityFile /keys/admin' ]
  [[ "$output" != *AddKeysToAgent* ]]
}

@test "creates a missing file and its folder, with a final newline" {
  tk_set_block "$BATS_TEST_TMPDIR/new dir/f" "$BLOCK3"
  [ "$(cat "$BATS_TEST_TMPDIR/new dir/f")" = "$BLOCK3" ]
  [ "$(tail -c 1 "$BATS_TEST_TMPDIR/new dir/f" | od -An -tx1 | tr -d ' ')" = 0a ]
}

@test "appends after a blank line, adding a missing final newline first" {
  printf 'Host x\n    HostName 198.51.100.20' > "$F"
  tk_set_block "$F" "$BLOCK3"
  [ "$(cat "$F")" = "$(printf 'Host x\n    HostName 198.51.100.20\n\n%s' "$BLOCK3")" ]
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
  tk_set_block "$F" "$(tk_ssh_block)"
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

@test "the ssh config block is replaced in place when HOST changes" {
  printf 'Host other\n    HostName 198.51.100.7\n' > "$F"
  tk_set_block "$F" "$(tk_ssh_block)"
  [ "$(cat "$F")" = "$(printf 'Host other\n    HostName 198.51.100.7\n\n'; cat "$REPO/tests/fixtures/ssh-block")" ]
  TKC_HOST=198.51.100.20
  tk_set_block "$F" "$(tk_ssh_block)"
  [ "$(grep -c '^# >>> tmuxkeep$' "$F")" -eq 1 ]
  [ "$(grep -c '^    HostName 198.51.100.20$' "$F")" -eq 2 ]
  [ "$(grep -c '203.0.113.10' "$F")" -eq 0 ]
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
```

- [ ] **Step 3: Run to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/laptop-blocks.bats`
Expected: the image rebuilds with zsh; `not ok` lines (the functions do not exist).

- [ ] **Step 4: Add the functions to `laptop/deploy.sh`**

- [ ] **Step 5: Run until green**

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/laptop-blocks.bats`: 15 tests, all `ok`. If the zsh test cannot pass as written (for example zsh prints something else on stderr in the image), stop and report the output; do not weaken it (plan Q3).
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/00-env.bats`: 7 tests, all `ok`.
- the whole bats directory and the whole Pester folder (G8).

- [ ] **Step 6: Line endings, commit**

```bash
grep -rlIU "$(printf '\r')" tests laptop/*.sh laptop/completion.bash    # Git Bash; must print nothing
git add laptop/deploy.sh tests/docker/Dockerfile tests/bats/00-env.bats tests/bats/laptop-blocks.bats
git commit -m "deploy.sh: write-or-replace ssh config and rc blocks; symlinks kept; zsh loads compinit"
```

---

### Task 14: Bash deploy: staging, setup command, admin help, main sequence

Suggested model: sonnet. Admin path and the never-capture rule; the orchestrator should have Opus review the diff.

**Files:**
- Modify: `laptop/deploy.sh` (add the staging list, the remaining functions, the main sequence and the source guard)
- Create: `tests/bats/laptop-deploy.bats`

**Interfaces:**
- Consumes: Task 12 (`tk_conf_defaults`, `tk_conf_read`, `tk_conf_create`, `tk_deploy_conf_text`, `tk_expand_path`, `tk_prompt`, `TKC_*`, `TK_ERR`); Task 13 (`tk_ssh_block`, `tk_rc_block`, `tk_rc_file`, `tk_set_block`); Task 10 (`laptop_setup`, `stub_calls`, `mk_repo_copy`, stubs with `TK_STUB_SSH_RC`, `TK_STUB_SCP_RC`, `TK_STUB_SCP_DEST`); Task 5/6 installer command line; fixtures `tests/fixtures/laptop-config`, `tests/fixtures/deploy.conf`, `tests/fixtures/ssh-block` (contents in Tasks 12 and 13).
- Produces:
  - Operator command `bash laptop/deploy.sh [--config <path>] [--init] [--harden-root] [--rotate-totp] [--unlock-otp]`.
  - One line exactly `TK_VPS_FILES="tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer"` (Task 15 parses it).
  - Functions `tk_usage`, `tk_missing_tools` (prints the missing names separated by spaces), `tk_version REPO`, `tk_stage REPO VERSION PUBKEY DEST`, `tk_setup_command STAGE HARDEN ROTATE UNLOCK` (each flag 0 or 1), `tk_admin_help`, `tk_deploy_remote REPO KEY STAGE HARDEN ROTATE UNLOCK`, `tk_deploy_main ARGS...`.

**Behaviour (spec 6.1, 6.4, 6.5, 12; plan Q4, Q11, Q12; G3):** the same steps, order, messages and exit codes as `laptop/deploy.ps1` (Task 9); errors go to stderr, everything else to stdout.

- `tk_usage` prints to stderr: `usage: bash laptop/deploy.sh [--config <path>] [--init] [--harden-root] [--rotate-totp] [--unlock-otp]`.
- `tk_missing_tools`: for `ssh scp ssh-keygen git`, `command -v` each and print the missing ones joined by single spaces (nothing when all exist).
- `tk_version REPO`: `git -C "$1" rev-parse --short HEAD`, plus `-dirty` when `git -C "$1" --no-optional-locks status --porcelain` prints anything; status 1 when git fails or prints no hash. (`--no-optional-locks` keeps `git status` from trying to write the index of a read-only checkout.)
- `tk_stage REPO VERSION PUBKEY DEST`: nothing is written unless every input is good. VERSION must match `^[0-9a-f]{4,40}(-dirty)?$` (`TK_ERR="version '<v>' is not a git short hash"`); every `vps/<f>` of `TK_VPS_FILES` must exist (`TK_ERR="missing <path>"`); `vps/tmuxkeep` must contain exactly one line `TMUXKEEP_VERSION=dev` (`TK_ERR="<repo>/vps/tmuxkeep must contain exactly one TMUXKEEP_VERSION=dev line"`); PUBKEY must exist. Then `mkdir -p "$DEST/systemd"`, copy each file with `tr -d '\r' < src > dest`, replace the version line with awk (`TK_V=$version awk '$0 == "TMUXKEEP_VERSION=dev" { print "TMUXKEEP_VERSION=" ENVIRON["TK_V"]; next } { print }'` into a `.new` file, then `mv`), write `laptop.pub` with `tr -d '\r'`, write `deploy.conf` with `tk_deploy_conf_text`.
- `tk_setup_command STAGE HARDEN ROTATE UNLOCK`: STAGE must match `^tmuxkeep-deploy-[0-9]{14}$` (else `TK_ERR` and status 1); flags in the fixed order ` --harden-root`, ` --rotate-totp`, ` --unlock-otp` for each argument that is 1; print with a single-quoted format so `$?` and `$rc` stay literal:

  ```bash
  printf 'bash /root/%s/tmuxkeep-setup --pubkey-file /root/%s/laptop.pub --key-id laptop --conf /root/%s/deploy.conf%s; rc=$?; rm -rf /root/%s; exit $rc\n' "$1" "$1" "$1" "$flags" "$1"
  ```

- `tk_admin_help` prints the same six lines as `Get-TmuxkeepAdminHelp` (Task 9), from `TKC_HOST`, `TKC_PORT`, `TKC_ADMIN_KEY`:
  1. `1. ssh-keygen -t ed25519 -f <A> -C tmuxkeep-admin        (set a passphrase)` where `<A>` is `tk_expand_path "$TKC_ADMIN_KEY"`, wrapped in double quotes when it contains a space;
  2. `2. Install it on the VPS with one password login:`;
  3. `   ssh root@<HOST> -p <PORT> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && echo <PUB> >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"`, where `<PUB>` is the first line of `<A>.pub` (CR removed) when it exists and matches `^ssh-ed25519 [A-Za-z0-9+/=]+( [A-Za-z0-9@._-]+)?$` (through a variable `re`), else the literal `<contents of <TKC_ADMIN_KEY>.pub>`;
  4. `3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true`;
  5. an empty line;
  6. `Never ssh-add the admin key and never set AddKeysToAgent for it.`
- `tk_deploy_main` and `tk_deploy_remote`, then the guard. Write them in this shape; the comments name the spec 6.1 steps:

  ```bash
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
      printf '%s\n' 'deploy: the admin key was not accepted, or tmuxkeep-admin is unreachable. Set up the admin path once, then run deploy again.' \
        'If you only mistyped the passphrase, run deploy again.' ''
      tk_admin_help
      return 1
    fi
    if [ "$rc" -ne 0 ]; then printf 'deploy: scp failed with exit %s\n' "$rc" >&2; return "$rc"; fi
    # 6. Install. A plain command: its output (the TOTP secret, once) goes straight to the terminal.
    remote=$(tk_setup_command "$stage" "$4" "$5" "$6") || { printf 'deploy: %s\n' "$TK_ERR" >&2; return 1; }
    ssh -o PreferredAuthentications=publickey tmuxkeep-admin "$remote"
    rc=$?
    if [ "$rc" -eq 255 ]; then
      printf 'deploy: ssh to tmuxkeep-admin failed (exit 255): wrong passphrase or the connection was lost. tmuxkeep-setup may not have run or may have stopped partway, /root/%s may remain on the VPS, and running deploy again is safe.\n' "$stage" >&2
      return 255
    fi
    if [ "$rc" -ne 0 ]; then printf 'deploy: tmuxkeep-setup failed with exit %s\n' "$rc" >&2; return "$rc"; fi
    # 7. The wrapper, the completion and the rc block.
    if ! mkdir -p "$HOME/.local/bin" "$HOME/.tmuxkeep"; then
      printf 'deploy: cannot install into %s\n' "$HOME" >&2; return 1
    fi
    if ! cp "$repo/laptop/tmuxkeep.sh" "$HOME/.local/bin/tmuxkeep" || ! chmod 0755 "$HOME/.local/bin/tmuxkeep"; then
      printf 'deploy: cannot install %s\n' "$HOME/.local/bin/tmuxkeep" >&2; return 1
    fi
    if ! cp "$repo/laptop/completion.bash" "$HOME/.tmuxkeep/completion.bash" || ! chmod 0644 "$HOME/.tmuxkeep/completion.bash"; then
      printf 'deploy: cannot install %s\n' "$HOME/.tmuxkeep/completion.bash" >&2; return 1
    fi
    rcfile=$(tk_rc_file)
    if ! tk_set_block "$rcfile" "$(tk_rc_block)"; then printf 'deploy: %s\n' "$TK_ERR" >&2; return 1; fi
    # 8. Proof of life.
    ssh -o BatchMode=yes tmuxkeep ls
    printf 'deploy: proof of life exit %s\n' "$?"
  }
  ```

  `tk_deploy_main ARGS...`:
  1. `set -o pipefail`; `umask 077`. Parse `--config <path>` (a missing value is usage), `--init`, `--harden-root`, `--rotate-totp`, `--unlock-otp`; anything else: `tk_usage`, return 2. Default config `$HOME/.tmuxkeep/config`. `repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)`.
  2. Step 0: `tk_missing_tools` non-empty prints `deploy: missing required tools: <names>` (stderr), return 2; `git -C "$repo" rev-parse --is-inside-work-tree >/dev/null` failing prints `deploy: not a git checkout: <repo>` (stderr), return 2 (git's own error line stays visible); then `tk_conf_defaults` and, when the config path exists, `tk_conf_read` (failure: `deploy: config <TK_ERR>` on stderr, return 2).
  3. Step 1: when the config path does not exist, `tk_conf_create` (failure: `deploy: config <TK_ERR>` on stderr, return 2), then print `deploy: wrote <config>`.
  4. Step 2: `key=$(tk_expand_path "$TKC_KEY")`; if it does not exist: `mkdir -p "$(dirname "$key")"`, `ssh-keygen -t ed25519 -f "$key" -C tmuxkeep-laptop -N ''`, non-zero prints `deploy: ssh-keygen failed with exit <n>` (stderr) and returns n. A missing `$key.pub` prints `deploy: <key>.pub is missing. Move <key> aside and run deploy again to make a new pair.` (stderr), return 1.
  5. Step 3: `tk_set_block "$HOME/.ssh/config" "$(tk_ssh_block)"`; failure prints `deploy: <TK_ERR>` (stderr), return 1.
  6. `--init`: print `deploy: init done: config, laptop key and ssh config are ready.`, `Next, set up the admin key once:`, an empty line, then `tk_admin_help`; return 0.
  7. Steps 4-9: `ts=$(date +%Y%m%d%H%M%S)`, `stage=tmuxkeep-deploy-$ts`, `TK_PARENT="${TMPDIR:-/tmp}"` with any trailing `/` removed plus `/tmuxkeep-stage-$ts`; `mkdir "$TK_PARENT"` (failure: `deploy: cannot create <path>`, return 1); `trap 'rm -rf "$TK_PARENT"; exit 130' INT TERM HUP`; `tk_deploy_remote "$repo" "$key" "$stage" "$harden" "$rotate" "$unlock"`; keep its status; step 9: `rm -rf "$TK_PARENT"`, `trap - INT TERM HUP`; on status 0 print `deploy: done. Open a new terminal, or run: . <rcfile>`; return the status.

  End of file:

  ```bash
  [[ ${BASH_SOURCE[0]} != "$0" ]] && return 0
  tk_deploy_main "$@"
  exit $?
  ```

- The line `  ssh -o PreferredAuthentications=publickey tmuxkeep-admin "$remote"` appears exactly once and exactly like that (G3; the test greps it).

- [ ] **Step 1: Write the failing test `tests/bats/laptop-deploy.bats`**

```bash
#!/usr/bin/env bats
# laptop/deploy.sh main sequence (spec 6.1, 6.4, 6.5, 9.2, 12; plan Q4, Q11, Q12). It runs as a
# child process from a temporary git copy of laptop/ and vps/, with stub ssh, scp and ssh-keygen
# first on PATH and HOME in a temp directory. Never against a real host.
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
  [ ! -s "$TK_STUB_LOG" ]
}

@test "full run: keygen, scp, the setup ssh and the proof of life, in order, with the exact arguments" {
  local scp stage
  run deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(stub_calls | grep -c .)" -eq 4 ]
  [ "$(stub_calls | sed -n 1p)" = "ssh-keygen [-t] [ed25519] [-f] [$HOME/.ssh/id_tmuxkeep_ed25519] [-C] [tmuxkeep-laptop] [-N] []" ]
  scp=$(stub_calls | sed -n 2p)
  stage=$(printf '%s\n' "$scp" | sed -n 's/^scp \[-o\] \[PreferredAuthentications=publickey\] \[-r\] \[\(tmuxkeep-deploy-[0-9]\{14\}\)\] \[tmuxkeep-admin:\/root\/tmuxkeep-deploy-[0-9]\{14\}\]$/\1/p')
  [ -n "$stage" ] || { echo "$scp"; return 1; }
  [ "$(stub_calls | sed -n 3p)" = "ssh [-o] [PreferredAuthentications=publickey] [tmuxkeep-admin] [bash /root/$stage/tmuxkeep-setup --pubkey-file /root/$stage/laptop.pub --key-id laptop --conf /root/$stage/deploy.conf; rc=\$?; rm -rf /root/$stage; exit \$rc]" ]
  [ "$(stub_calls | sed -n 4p)" = 'ssh [-o] [BatchMode=yes] [tmuxkeep] [ls]' ]
  [[ "$output" == *'deploy: proof of life exit 0'* ]]
  [[ "$output" == *'deploy: done.'* ]]
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
}

@test "with SHELL ending in zsh the rc block goes into ~/.zshrc" {
  export SHELL=/bin/zsh
  run deploy
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx '# >>> tmuxkeep' "$HOME/.zshrc"
  [ ! -e "$HOME/.bashrc" ]
}

@test "--init stops after step 3 and prints the admin-key steps; no scp and no ssh" {
  run deploy --init
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(stub_calls | grep -c .)" -eq 1 ]
  [[ "$(stub_calls)" == 'ssh-keygen '* ]]
  cmp "$HOME/.ssh/config" "$REPO/tests/fixtures/ssh-block"
  [ ! -e "$HOME/.local/bin/tmuxkeep" ]
  [[ "$output" == *'deploy: init done'* ]]
  [[ "$output" == *'3. Check: ssh -o PasswordAuthentication=no tmuxkeep-admin true'* ]]
}

@test "an existing laptop key is not generated again" {
  mkdir -p "$HOME/.ssh"
  printf 'k\n' > "$HOME/.ssh/id_tmuxkeep_ed25519"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExisting tmuxkeep-laptop\n' > "$HOME/.ssh/id_tmuxkeep_ed25519.pub"
  run deploy --init
  [ "$status" -eq 0 ]
  [ ! -s "$TK_STUB_LOG" ]
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
  [[ "$(stub_calls | sed -n 3p)" == *'/deploy.conf --harden-root --rotate-totp --unlock-otp; rc='* ]]
}

@test "scp exit 255 prints the admin-key help built from the config and stops with exit 1" {
  export TK_STUB_SCP_RC=255
  run deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *'the admin key was not accepted'* ]]
  [[ "$output" == *'ssh root@203.0.113.10 -p 22 "mkdir -p ~/.ssh'* ]]
  [ "$(stub_calls | grep -c '^ssh ')" -eq 0 ]
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
  run grep -nE '^[[:space:]]*ssh-add([[:space:]]|$)' "$REPO/laptop/deploy.sh" "$REPO/laptop/tmuxkeep.sh"
  [ "$status" -eq 1 ]
  [ "$(grep -c AddKeysToAgent "$REPO/laptop/deploy.sh")" -eq 1 ]
  grep -q 'Never ssh-add the admin key and never set AddKeysToAgent for it.' "$REPO/laptop/deploy.sh"
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
```

- [ ] **Step 2: Run to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/laptop-deploy.bats`
Expected: `not ok` lines (no main sequence yet).

- [ ] **Step 3: Implement the behaviour above in `laptop/deploy.sh`. Never run it yourself; only the tests run it, from the temporary copy, with the stubs.**

- [ ] **Step 4: Run until green**

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/laptop-deploy.bats`: 20 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/laptop-config.bats` and `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/laptop-blocks.bats`: all `ok` (sourcing now stops at the guard).
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/lint-laptop.bats`: 6 tests, all `ok`.
- the whole bats directory and the whole Pester folder (G8).

- [ ] **Step 5: Line endings, commit**

```bash
grep -lU "$(printf '\r')" laptop/deploy.sh tests/bats/laptop-deploy.bats    # Git Bash; must print nothing
git add laptop/deploy.sh tests/bats/laptop-deploy.bats
git commit -m "deploy.sh: config-driven main sequence, --init and --config, staging, admin help from config"
```

---

### Task 15: Parity tests

Suggested model: sonnet.

**Files:**
- Create: `tests/bats/parity.bats`

**Interfaces:**
- Consumes these exact source lines (each produced by an earlier task and present exactly once):
  - `vps/tmuxkeep`: `GATED_VERBS="new go send rename unlock rm resume auth"` (v1) and the verb functions, each defined on a line starting `verb_<name>() {` (v1).
  - `laptop/tmuxkeep.ps1`: `$GatedVerbs = @('new', 'go', 'send', 'rename', 'unlock', 'rm', 'resume', 'auth')` (v1).
  - `laptop/tmuxkeep.sh`: `TK_GATED_VERBS="new go send rename unlock rm resume auth"` (Task 10).
  - `vps/tmuxkeep-setup`: `STAGED_FILES=(tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer)` (Task 6).
  - `laptop/deploy.ps1`: `function Get-TmuxkeepVpsFiles { @('tmuxkeep', 'tmuxkeep-setup', 'vps-facts.sh', 'sshd.conf.tmpl', 'sudoers.tmpl', 'tmux.conf', 'systemd/tmuxkeep-reaper.service', 'systemd/tmuxkeep-reaper.timer') }` (Task 9).
  - `laptop/deploy.sh`: `TK_VPS_FILES="tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer"` (Task 14).
  - `laptop/profile-snippet.ps1` (v1, renamed): the completer lines `        $candidates = @('new', 'ls', 'peek', 'go', 'send', 'rename', 'lock', 'unlock', 'rm', 'restore', 'resume', 'log', 'auth')` and `        if ($done[1] -cin @('peek', 'go', 'send', 'rename', 'lock', 'unlock', 'rm', 'resume')) {`.
  - `laptop/completion.bash`: `_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth"` and `_TK_NAME_VERBS="peek go send rename lock unlock rm resume"` (Task 11).
  - Helpers from Task 10: `REPO` (works in Docker and on macOS).
- Produces: the spec 9.3 parity suite. `tests/pester/tmuxkeep.Tests.ps1` keeps its own gated-verb assertion (v1, renamed in Task 1); nothing to change there.

**Behaviour (spec 9.3):**
- Every extraction is a `grep`/`sed`/`tr` pipeline. The PowerShell files may carry CRLF in a Windows checkout (they are not under `.gitattributes`' LF rule), so every PowerShell extraction strips CR first with `tr -d '\r'`.
- Each extraction must produce exactly one line; an extraction that finds nothing or finds two is a failure, not a silent pass.
- Lists that are sets (verbs) are compared sorted; the staged-file list is compared in order (G29).
- The file runs under bash 3.2 too (it loads `laptop-helpers`), so it follows G19-G22.

- [ ] **Step 1: Write `tests/bats/parity.bats` with exactly this content**

```bash
#!/usr/bin/env bats
# Parity (spec 9.3): lists that several files must agree on, extracted with grep and sed and then
# compared. PowerShell files may carry CRLF in a Windows checkout, so their extraction strips CR.
load laptop-helpers

# sorted_words: the words on stdin (separated by spaces or newlines), sorted, on one line.
sorted_words() { tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }
# ps_list: "'a', 'b', 'c'" on stdin becomes "a b c".
ps_list() { tr -d "' " | tr ',' ' '; }
# one_line LABEL TEXT: TEXT must be exactly one non-empty line.
one_line() {
  [ -n "$2" ] || { echo "$1: nothing extracted"; return 1; }
  [ "$(printf '%s\n' "$2" | grep -c .)" -eq 1 ] || { echo "$1: more than one line extracted"; return 1; }
}

gated_broker() { sed -n 's/^GATED_VERBS="\([^"]*\)"$/\1/p' "$REPO/vps/tmuxkeep"; }
gated_ps()     { tr -d '\r' < "$REPO/laptop/tmuxkeep.ps1" | sed -n 's/^\$GatedVerbs = @(\(.*\))$/\1/p' | ps_list; }
gated_bash()   { sed -n 's/^TK_GATED_VERBS="\([^"]*\)"$/\1/p' "$REPO/laptop/tmuxkeep.sh"; }

staged_setup() { sed -n 's/^STAGED_FILES=(\(.*\))$/\1/p' "$REPO/vps/tmuxkeep-setup"; }
staged_ps()    { tr -d '\r' < "$REPO/laptop/deploy.ps1" | sed -n 's/^function Get-TmuxkeepVpsFiles { @(\(.*\)) }$/\1/p' | ps_list; }
staged_bash()  { sed -n 's/^TK_VPS_FILES="\([^"]*\)"$/\1/p' "$REPO/laptop/deploy.sh"; }

broker_verbs()  { sed -n 's/^verb_\([a-z][a-z]*\)() {.*$/\1/p' "$REPO/vps/tmuxkeep" | grep -vx reap; }
ps_verbs()      { tr -d '\r' < "$REPO/laptop/profile-snippet.ps1" | sed -n 's/^ *\$candidates = @(\(.new.*\))$/\1/p' | ps_list; }
ps_name_verbs() { tr -d '\r' < "$REPO/laptop/profile-snippet.ps1" | sed -n 's/^.*-cin @(\(.*\))) {$/\1/p' | ps_list; }
bash_verbs()      { sed -n 's/^_TK_VERBS="\([^"]*\)"$/\1/p' "$REPO/laptop/completion.bash"; }
bash_name_verbs() { sed -n 's/^_TK_NAME_VERBS="\([^"]*\)"$/\1/p' "$REPO/laptop/completion.bash"; }

@test "the gated verb list is the same in the broker and both wrappers" {
  local want='auth go new rename resume rm send unlock' b p s
  b=$(gated_broker); one_line broker "$b"
  p=$(gated_ps); one_line 'PowerShell wrapper' "$p"
  s=$(gated_bash); one_line 'bash wrapper' "$s"
  [ "$(printf '%s' "$b" | sorted_words)" = "$want" ] || { echo "broker: $b"; return 1; }
  [ "$(printf '%s' "$p" | sorted_words)" = "$want" ] || { echo "PowerShell wrapper: $p"; return 1; }
  [ "$(printf '%s' "$s" | sorted_words)" = "$want" ] || { echo "bash wrapper: $s"; return 1; }
}

@test "the staged file list is the same, in the same order, in both deploys and the installer" {
  local want='tmuxkeep tmuxkeep-setup vps-facts.sh sshd.conf.tmpl sudoers.tmpl tmux.conf systemd/tmuxkeep-reaper.service systemd/tmuxkeep-reaper.timer' i p s
  i=$(staged_setup); one_line installer "$i"
  p=$(staged_ps); one_line 'PowerShell deploy' "$p"
  s=$(staged_bash); one_line 'bash deploy' "$s"
  [ "$i" = "$want" ] || { echo "installer: $i"; return 1; }
  [ "$p" = "$want" ] || { echo "PowerShell deploy: $p"; return 1; }
  [ "$s" = "$want" ] || { echo "bash deploy: $s"; return 1; }
}

@test "every staged file exists under vps/, and every file under vps/ is staged" {
  local f listed
  listed=" $(staged_setup) "
  for f in $(staged_setup); do
    [ -f "$REPO/vps/$f" ] || { echo "missing vps/$f"; return 1; }
  done
  while IFS= read -r f; do
    f=${f#"$REPO/vps/"}
    case $listed in
      *" $f "*) ;;
      *) echo "not staged: vps/$f"; return 1 ;;
    esac
  done < <(find "$REPO/vps" -type f ! -name '.*')
}

@test "the completer verb lists match the broker's verbs (reap excluded) and each other" {
  local want b p s
  want='auth go lock log ls new peek rename restore resume rm send unlock'
  b=$(broker_verbs | sorted_words)
  [ "$b" = "$want" ] || { echo "broker verb_ functions: $b"; return 1; }
  p=$(ps_verbs); one_line 'PowerShell completer verbs' "$p"
  s=$(bash_verbs); one_line 'bash completer verbs' "$s"
  [ "$(printf '%s' "$p" | sorted_words)" = "$want" ] || { echo "PowerShell completer: $p"; return 1; }
  [ "$(printf '%s' "$s" | sorted_words)" = "$want" ] || { echo "bash completer: $s"; return 1; }
}

@test "the name-completing verb lists agree, and are the broker verbs that take a session name" {
  local want='go lock peek rename resume rm send unlock' p s
  p=$(ps_name_verbs); one_line 'PowerShell name verbs' "$p"
  s=$(bash_name_verbs); one_line 'bash name verbs' "$s"
  [ "$(printf '%s' "$p" | sorted_words)" = "$want" ] || { echo "PowerShell: $p"; return 1; }
  [ "$(printf '%s' "$s" | sorted_words)" = "$want" ] || { echo "bash: $s"; return 1; }
}

@test "the four deploy fixtures exist and end with a newline" {
  local f
  for f in laptop-config deploy.conf tmuxkeep.conf ssh-block; do
    [ -f "$REPO/tests/fixtures/$f" ] || { echo "missing tests/fixtures/$f"; return 1; }
    [ "$(tail -c 1 "$REPO/tests/fixtures/$f" | od -An -tx1 | tr -d ' ')" = 0a ] || { echo "$f"; return 1; }
  done
}
```

- [ ] **Step 2: Run it**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/parity.bats`
Expected: 6 tests, all `ok`. If one fails, the failing extraction or comparison is printed. A failure here is a real disagreement between files (or an extraction line that an earlier task wrote differently from its Interfaces): stop and report it with the printed output; do not edit the other files to make the test pass.

- [ ] **Step 3: Prove the tests can fail**

Temporarily change `laptop/completion.bash`'s `_TK_NAME_VERBS` line to drop `resume`, run the suite and see the last-but-one test fail with `bash: ...`; restore the line with `git checkout -- laptop/completion.bash` and run again (all `ok`).

- [ ] **Step 4: Full suites, commit**

Run the whole bats directory and the whole Pester folder (G8).

```bash
grep -lU "$(printf '\r')" tests/bats/parity.bats    # Git Bash; must print nothing
git add tests/bats/parity.bats
git commit -m "Add parity tests: gated verbs, staged files, completer verbs across broker, wrappers and deploys"
```

---

### Task 16: `tests/smoke.sh`

Suggested model: sonnet.

**Files:**
- Create: `tests/smoke.sh` (executable)
- Create: `tests/bats/smoke.bats`

**Interfaces:**
- Consumes: the wrapper interface (`<wrapper> <words...>`, exit code = the broker's) and the broker output strings: `created <n> in `, `sent <bytes> bytes to <n>`, `locked <n>`, `tombstoned <n>;`, `restored <n>`, `killed <n>`; `ls` rows starting `<n>  live` and `zz~<n>~<epoch>  tombstone`; audit JSON lines containing `"verb":"<v>"` and `"session":"<n>"`. Task 10's `laptop-helpers` (`laptop_setup`, `REPO`).
- Produces: `bash tests/smoke.sh [--wrapper <path>]` (default `~/.local/bin/tmuxkeep`), the bash twin of `tests/smoke.ps1` (spec 9.7). Exit 0 when all 13 steps pass, 1 at the first mismatch, 2 for a bad argument. Operator only: agents never run it against a real wrapper (G2).

**Behaviour:** the same 13 steps, messages and cleanup hint as `tests/smoke.ps1`, with `tmuxkeep` in the hint. Write the file exactly as follows (bash 3.2, G19-G22):

```bash
#!/usr/bin/env bash
# smoke.sh - operator end-to-end smoke test for tmuxkeep from macOS or Linux (bash 3.2 and later).
#
# Run it yourself, from a terminal, against the real VPS:
#   bash tests/smoke.sh [--wrapper <path>]
# The default wrapper is ~/.local/bin/tmuxkeep. Agents never run this against the real wrapper;
# tests/bats/smoke.bats drives it with a fake wrapper instead.
#
# It creates one throwaway session named smoke-<6 random characters>, walks it through the whole
# lifecycle (13 steps) and removes it again. Exit 0 when every step passes, 1 at the first mismatch:
# the script stops there and prints how to clean up by hand. The same hint is printed if the run is
# interrupted while a session may exist. Step 1 (auth) runs uncaptured so the "TOTP: " prompt
# reaches the terminal; every other step is captured, and the gated verbs reuse the lease.

TK_WRAPPER=$HOME/.local/bin/tmuxkeep
TK_N=''
TK_SESSION_MAY_EXIST=0
TK_HINT_PRINTED=0
TK_OUT=''

# tk_cleanup_hint: how to remove a leftover test session, at most once, only while one may exist.
tk_cleanup_hint() {
  if [ "$TK_SESSION_MAY_EXIST" != 1 ] || [ "$TK_HINT_PRINTED" = 1 ]; then return 0; fi
  TK_HINT_PRINTED=1
  printf 'A test session may be left behind. To clean it up: tmuxkeep rm %s --now --confirm %s\n' "$TK_N" "$TK_N"
  printf "If the rm is refused as locked: run 'tmuxkeep restore %s' only if 'tmuxkeep ls' shows a zz~%s~... row, then 'tmuxkeep unlock %s', then the rm again.\n" "$TK_N" "$TK_N" "$TK_N"
}

# tk_stop STEP REASON [OUTPUT]: print the failure and the cleanup hint, then exit 1.
tk_stop() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  if [ -n "${3:-}" ]; then printf '%s\n' '--- output ---' "$3" '--- end of output ---'; fi
  tk_cleanup_hint
  exit 1
}

# tk_check STEP CODE EXPECT OUTPUT PATTERN: compare the exit code and, when PATTERN is set, an ERE.
tk_check() {
  if [ "$2" != "$3" ]; then tk_stop "$1" "exit code $2, expected $3" "$4"; fi
  if [ -n "$5" ] && ! printf '%s\n' "$4" | grep -Eq -- "$5"; then tk_stop "$1" "output did not match /$5/" "$4"; fi
  printf 'PASS %s\n' "$1"
}

# tk_step STEP EXPECT PATTERN WORD...: run the wrapper with stdout and stderr captured, then check.
tk_step() {
  local step=$1 expect=$2 pattern=$3 code
  shift 3
  TK_OUT=$("$TK_WRAPPER" "$@" 2>&1)
  code=$?
  tk_check "$step" "$code" "$expect" "$TK_OUT" "$pattern"
}

tk_smoke_main() {
  local v code missing='' usage='usage: bash tests/smoke.sh [--wrapper <path>]'
  while [ "$#" -gt 0 ]; do
    case $1 in
      --wrapper)
        if [ "$#" -lt 2 ]; then echo "$usage"; return 2; fi
        TK_WRAPPER=$2
        shift 2 ;;
      *) echo "$usage"; return 2 ;;
    esac
  done
  if [ ! -x "$TK_WRAPPER" ]; then printf 'FAIL setup: wrapper not found or not executable: %s\n' "$TK_WRAPPER"; return 1; fi
  TK_N="smoke-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)"
  printf 'smoke: session name %s\n' "$TK_N"
  trap 'tk_cleanup_hint; exit 130' INT TERM

  # 1. auth, uncaptured, so the TOTP prompt reaches the terminal.
  echo 'Type the code from your phone at the TOTP prompt.'
  "$TK_WRAPPER" auth
  code=$?
  tk_check '1/13 auth' "$code" 0 '' ''

  # A session may exist from here on, even if new itself fails halfway.
  TK_SESSION_MAY_EXIST=1
  tk_step "2/13 new $TK_N" 0 "created $TK_N in " new "$TK_N"
  tk_step '3/13 ls (live row)' 0 "^$TK_N[[:space:]]+live" ls
  tk_step "4/13 peek $TK_N" 0 '' peek "$TK_N"
  tk_step "5/13 send $TK_N /help" 0 "sent [0-9]+ bytes to $TK_N" send "$TK_N" /help
  tk_step "6/13 lock $TK_N" 0 "locked $TK_N" lock "$TK_N"
  tk_step "7/13 rm $TK_N (locked, must be refused with exit 3)" 3 '' rm "$TK_N"
  tk_step "8/13 unlock $TK_N" 0 '' unlock "$TK_N"
  tk_step "9/13 rm $TK_N (tombstone)" 0 "tombstoned $TK_N;" rm "$TK_N"
  tk_step '10/13 ls (tombstone row)' 0 "^zz~$TK_N~[0-9]+[[:space:]]+tombstone" ls
  tk_step "11/13 restore $TK_N" 0 "restored $TK_N" restore "$TK_N"
  tk_step "12/13 rm $TK_N --now --confirm $TK_N" 0 "killed $TK_N" rm "$TK_N" --now --confirm "$TK_N"
  # The session is gone now; a later failure has nothing to clean up.
  TK_SESSION_MAY_EXIST=0

  # 13. The audit log must show every verb used against this session. PASS only after that check.
  TK_OUT=$("$TK_WRAPPER" log -n 20 2>&1)
  code=$?
  if [ "$code" = 0 ]; then
    for v in new peek send lock rm unlock restore; do
      printf '%s\n' "$TK_OUT" | grep -F "\"verb\":\"$v\"" | grep -qF "\"session\":\"$TK_N\"" || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
      tk_stop '13/13 log -n 20 (audit lines for this session)' "no audit line for session $TK_N and verb:$missing" "$TK_OUT"
    fi
  fi
  tk_check '13/13 log -n 20 (audit lines for this session)' "$code" 0 "$TK_OUT" ''
  trap - INT TERM
  echo 'smoke: all steps passed'
  return 0
}

[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0
tk_smoke_main "$@"
exit $?
```

- [ ] **Step 1: Write the failing test `tests/bats/smoke.bats`**

```bash
#!/usr/bin/env bats
# tests/smoke.sh driven by a fake wrapper that simulates the broker (spec 9.7). Never the real one.
load laptop-helpers

setup() {
  laptop_setup
  export TK_FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$TK_FAKE_DIR"
  unset TK_FAKE_IGNORE_LOCK TK_FAKE_RM_NOW_LOCKED
  SMOKE="$REPO/tests/smoke.sh"
  FAKE="$BATS_TEST_TMPDIR/fake-tmuxkeep"
  cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
# Fake wrapper: simulates the broker for smoke.sh tests. State lives in $TK_FAKE_DIR.
dir=$TK_FAKE_DIR
printf '%s\n' "$*" >> "$dir/calls.log"
verb=${1:-}
name=${2:-}
state=''
n=''
if [ -f "$dir/state" ]; then state=$(cat "$dir/state"); fi
if [ -f "$dir/name" ]; then n=$(cat "$dir/name"); fi
case $verb in
  auth) exit 0 ;;
  new) printf '%s\n' "$name" > "$dir/name"; echo live > "$dir/state"
       echo "created $name in /home/claude/work/$name"; exit 0 ;;
  ls) echo 'NAME  STATE  ATTACHED  AGE  IDLE  TITLE'
      if [ "$state" = live ]; then echo "$n  live    1m  1m  x"; fi
      if [ "$state" = tombstone ]; then echo "zz~$n~1790000000  tombstone    1m  1m  x"; fi
      exit 0 ;;
  peek) echo 'some pane text'; exit 0 ;;
  send) echo "sent 5 bytes to $name"; exit 0 ;;
  lock) echo 1 > "$dir/locked"; echo "locked $name"; exit 0 ;;
  unlock) rm -f "$dir/locked"; echo "unlocked $name"; exit 0 ;;
  rm) if [ -f "$dir/locked" ] && [ -z "${TK_FAKE_IGNORE_LOCK:-}" ]; then exit 3; fi
      case " $* " in
        *' --now '*)
          if [ -n "${TK_FAKE_RM_NOW_LOCKED:-}" ]; then exit 3; fi
          echo gone > "$dir/state"; echo "killed $name"; exit 0 ;;
      esac
      echo tombstone > "$dir/state"
      echo "tombstoned $name; still running, reaped in 24h; restore with: tmuxkeep restore $name"; exit 0 ;;
  restore) echo live > "$dir/state"; echo "restored $name"; exit 0 ;;
  log) while IFS= read -r c; do
         v=${c%% *}
         s=''
         case $c in *' '*) s=${c#* }; s=${s%% *} ;; esac
         printf '{"verb":"%s","session":"%s"}\n' "$v" "$s"
       done < "$dir/calls.log"
       exit 0 ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$FAKE"
}

calls() { cat "$TK_FAKE_DIR/calls.log"; }

@test "passes against a broker that behaves" {
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'smoke: all steps passed'* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^PASS ')" -eq 13 ]
}

@test "runs auth first and uses a fresh smoke- name of 6 characters" {
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$(calls | sed -n 1p)" = auth ]
  calls | sed -n 2p | grep -Eqx 'new smoke-[a-z0-9]{6}'
}

@test "fails with exit 1 when rm is not refused on a locked session, and stops there" {
  export TK_FAKE_IGNORE_LOCK=1
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 1 ]
  [[ "$output" == *FAIL* ]]
  [[ "$output" != *'smoke: all steps passed'* ]]
  calls | tail -n 1 | grep -Eqx 'rm smoke-[a-z0-9]{6}'
}

@test "prints the cleanup hint once, restore before unlock, when rm --now is refused as locked" {
  export TK_FAKE_RM_NOW_LOCKED=1
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL 12/13'* ]]
  printf '%s\n' "$output" | grep -Eq 'tmuxkeep rm smoke-[a-z0-9]{6} --now --confirm smoke-[a-z0-9]{6}'
  printf '%s\n' "$output" | grep -Eq "restore smoke-[a-z0-9]{6}'.*'tmuxkeep unlock smoke-"
  [ "$(printf '%s\n' "$output" | grep -c 'To clean it up')" -eq 1 ]
}

@test "a missing wrapper and an unknown argument stop at once" {
  run "$BASH" "$SMOKE" --wrapper "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 1 ]
  [[ "$output" == 'FAIL setup: wrapper not found or not executable: '* ]]
  run "$BASH" "$SMOKE" --frob
  [ "$status" -eq 2 ]
  [ ! -e "$TK_FAKE_DIR/calls.log" ]
}

@test "the default wrapper is ~/.local/bin/tmuxkeep" {
  grep -qx 'TK_WRAPPER=$HOME/.local/bin/tmuxkeep' "$SMOKE"
}
```

- [ ] **Step 2: Run to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/smoke.bats`
Expected: `not ok` lines (`tests/smoke.sh` does not exist).

- [ ] **Step 3: Create `tests/smoke.sh` with the content above**

- [ ] **Step 4: Run until green**

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/smoke.bats`: 6 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/lint-laptop.bats`: 6 tests, all `ok` (it now covers `tests/smoke.sh`).
- the whole bats directory and the whole Pester folder (G8).

- [ ] **Step 5: Line endings, exec bit, commit**

```bash
grep -lU "$(printf '\r')" tests/smoke.sh tests/bats/smoke.bats    # Git Bash; must print nothing
git add --chmod=+x tests/smoke.sh
git add tests/bats/smoke.bats
git commit -m "Add smoke.sh, the bash twin of smoke.ps1, with a fake-broker bats test"
```

---

### Task 17: Static checks and `tests/run-bats.sh`

Suggested model: sonnet.

**Files:**
- Create: `tests/run-bats.sh` (executable)
- Modify: `tests/bats/lint.bats` (append one test)
- Modify: `tests/bats/00-env.bats` (replace one test)
- Modify: `tests/pester/static.Tests.ps1` (append two `Describe` blocks)

**Interfaces:**
- Consumes: every shell file created so far (spec 9.5 list) and `.gitattributes` from Task 10; `tests/run-bats.ps1` (v1, renamed) as the model for `run-bats.sh`.
- Produces: `bash tests/run-bats.sh [path-in-repo] [filter-regex]` (exit code bats' own, 2 when Docker is unavailable, the path is wrong or the build fails), used by CI (Task 18) and by macOS and Linux developers. It also works from Git Bash on Windows.

**Behaviour (spec 9.5, 9.6):**
- `tests/run-bats.sh`, exactly:

  ```bash
  #!/usr/bin/env bash
  # run-bats.sh - build the tmuxkeep test image and run bats in Docker (macOS, Linux; Git Bash works too).
  # Usage: bash tests/run-bats.sh [path-in-repo] [filter-regex]     (default path: tests/bats)
  # Exit code: bats' own; 2 when Docker is unavailable, the path is wrong, or the build fails.
  # Mirrors tests/run-bats.ps1. bash 3.2.
  rel=${1:-tests/bats}
  filter=${2:-}
  repo=$(cd "$(dirname "$0")/.." && pwd) || exit 2
  image=tmuxkeep-bats:latest

  if ! docker info --format '{{.ServerVersion}}' >/dev/null; then
    echo 'run-bats: Docker is not available. Start Docker and retry.'
    exit 2
  fi
  rel=${rel#./}
  if [ ! -e "$repo/$rel" ]; then
    echo "run-bats: no such path in the repo: $rel"
    exit 2
  fi
  if ! docker build --quiet --tag "$image" "$repo/tests/docker" >/dev/null; then
    echo 'run-bats: docker build failed'
    exit 2
  fi
  src=$repo
  case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*) src=$(cd "$repo" && pwd -W); export MSYS_NO_PATHCONV=1 ;;
  esac
  set -- bats
  if [ -n "$filter" ]; then set -- "$@" --filter "$filter"; fi
  docker run --rm --mount "type=bind,source=$src,target=/src,readonly" "$image" "$@" "/src/$rel"
  exit $?
  ```

- shellcheck (G7) over the whole spec 9.5 list from inside the image, in one test that fails on a missing file.
- The CR check of `00-env.bats` also covers the laptop bash files.
- `static.Tests.ps1` adds the CR/BOM/ASCII checks for the LF set (`laptop/*.sh`, `laptop/completion.bash`, every file under `vps/` and `tests/fixtures/`) and checks `.gitattributes` with `git check-attr`.

- [ ] **Step 1: Append to `tests/bats/lint.bats`**

```bash

@test "every shell file of spec 9.5 passes shellcheck --shell=bash -S warning" {
  local f
  for f in vps/tmuxkeep vps/tmuxkeep-setup vps/vps-facts.sh laptop/tmuxkeep.sh laptop/deploy.sh \
           laptop/completion.bash tests/bats/stubs/oathtool tests/bats/stubs/ssh tests/bats/stubs/scp \
           tests/bats/stubs/ssh-keygen tests/bats/helpers.bash tests/bats/laptop-helpers.bash \
           tests/smoke.sh tests/run-bats.sh; do
    [ -f "/src/$f" ] || { echo "missing: $f"; return 1; }
    run shellcheck --shell=bash -S warning "/src/$f"
    [ "$status" -eq 0 ] || { echo "$f:"; echo "$output"; return 1; }
  done
  [ "$(ls /src/tests/bats/stubs | LC_ALL=C sort | tr '\n' ' ')" = 'oathtool scp ssh ssh-keygen ' ]
}
```

- [ ] **Step 2: In `tests/bats/00-env.bats`, replace the test `"no carriage returns under vps/ or tests/"` with**

```bash
@test "no carriage returns under vps/, tests/ or in the laptop bash files" {
  run grep -rlI $'\r' /src/vps /src/tests /src/laptop/tmuxkeep.sh /src/laptop/deploy.sh /src/laptop/completion.bash
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 3: Append to `tests/pester/static.Tests.ps1`**

```powershell

Describe 'LF-only files (spec 9.5)' {
    BeforeDiscovery {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:LfFiles = @(
            @(Get-ChildItem -Path (Join-Path $repo 'laptop') -Filter '*.sh' -File) +
            @(Get-Item -LiteralPath (Join-Path $repo 'laptop\completion.bash')) +
            @(Get-ChildItem -Path (Join-Path $repo 'vps') -Recurse -File) +
            @(Get-ChildItem -Path (Join-Path $repo 'tests\fixtures') -File) |
                ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repo.Length + 1) } })
    }

    It '<Name> has no CR, no BOM and only ASCII' -ForEach $LfFiles {
        $b = [IO.File]::ReadAllBytes($Path)
        ($b -contains 13) | Should -BeFalse -Because 'bash and the VPS need LF line endings'
        ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeFalse
        @($b | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe '.gitattributes' {
    It 'forces LF on the laptop bash files, vps and tests, and leaves the PowerShell files alone' {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        foreach ($p in 'laptop/tmuxkeep.sh', 'laptop/deploy.sh', 'laptop/completion.bash', 'vps/tmuxkeep', 'tests/smoke.sh') {
            ((& git -C $repo check-attr eol -- $p) -join '') | Should -BeExactly ($p + ': eol: lf')
        }
        ((& git -C $repo check-attr eol -- 'laptop/deploy.ps1') -join '') | Should -BeExactly 'laptop/deploy.ps1: eol: unspecified'
    }
}
```

- [ ] **Step 4: Create `tests/run-bats.sh` with the content above, then run the new and changed tests**

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/lint.bats`: 8 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/00-env.bats`: 7 tests, all `ok`.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/lint-laptop.bats`: 6 tests, all `ok` (it now covers `tests/run-bats.sh`).
- The G6 command with `$c.Run.Path = 'tests\pester\static.Tests.ps1'`: 0 failed.

- [ ] **Step 5: Exercise `tests/run-bats.sh` from Git Bash**

```bash
bash tests/run-bats.sh tests/bats/00-env.bats; echo "exit=$?"
bash tests/run-bats.sh tests/bats/nope.bats; echo "exit=$?"
```

Expected: the first prints 7 `ok` lines and `exit=0`; the second prints `run-bats: no such path in the repo: tests/bats/nope.bats` and `exit=2`.

- [ ] **Step 6: Full suites, line endings, exec bit, commit**

Run the whole bats directory and the whole Pester folder (G8).

```bash
grep -rlIU "$(printf '\r')" vps tests laptop/*.sh laptop/completion.bash    # Git Bash; must print nothing
git add --chmod=+x tests/run-bats.sh
git add tests/bats/lint.bats tests/bats/00-env.bats tests/pester/static.Tests.ps1
git commit -m "Static checks: shellcheck over every shell file, LF set in Pester, run-bats.sh for macOS and Linux"
```

---

### Task 18: CI workflow

Suggested model: sonnet.

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `tests/bats/ci.bats`

**Interfaces:**
- Consumes: `tests/run-bats.sh` (Task 17), the Pester command (G6), the laptop suites (`laptop-wrapper`, `completion`, `laptop-config`, `laptop-blocks`, `laptop-deploy`, `parity`, `smoke`, `lint-laptop`), `TK_EXPECT_BASH_MAJOR` (read by the interpreter test in `laptop-wrapper.bats`, Task 10).
- Produces: the three spec 9.6 jobs. The workflow first runs on GitHub after publishing (or on a private dry-run push, plan Q16); an agent can only check it statically.

**Behaviour (spec 9.6, 14; plan Q16):**
- `bats` on `ubuntu-latest`: `bash tests/run-bats.sh` (builds `tests/docker/Dockerfile`, runs every bats suite; shellcheck runs inside, through `lint.bats` and `lint-laptop.bats`).
- `pester` on `windows-latest`: every step uses `shell: cmd` and calls `powershell.exe -NoProfile ...` explicitly, so the job runs Windows PowerShell 5.1 with no profile (GitHub's `shell: powershell` adds no `-NoProfile`). The first step prints `$PSVersionTable.PSVersion` and fails unless the edition is `Desktop` and the major version is 5 (spec 14). Pester is installed for the current user after bootstrapping the NuGet provider, which `Install-Module` would otherwise prompt for.
- `macos` on `macos-latest`: Homebrew `bats-core` and `shellcheck`; a step prints `/bin/bash --version` and fails unless the major version is 3 (spec 14); the laptop suites run with `PATH` starting `/bin:/usr/bin`, so every `#!/usr/bin/env bash` (bats itself, the stubs, the scripts) resolves to `/bin/bash` 3.2, and with `TK_EXPECT_BASH_MAJOR=3`, so the suite fails if it ever ran under another bash; then shellcheck over the laptop files.

Write `.github/workflows/ci.yml` exactly:

```yaml
# CI for tmuxkeep (spec 9.6): bats and shellcheck in Docker on Linux, Pester under Windows
# PowerShell 5.1, and the laptop suites under macOS /bin/bash 3.2.
name: ci

on:
  push:
  pull_request:

jobs:
  bats:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build the test image and run every bats suite (shellcheck runs inside)
        run: |
          bash tests/run-bats.sh

  pester:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - name: Prove Windows PowerShell 5.1
        shell: cmd
        run: |
          powershell.exe -NoProfile -Command "$PSVersionTable.PSVersion.ToString(); if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) { exit 1 }"
      - name: Install Pester for the current user
        shell: cmd
        run: |
          powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null; Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck"
      - name: Run the Pester suites
        shell: cmd
        run: |
          powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.5; $c = New-PesterConfiguration; $c.Run.Path = 'tests\pester'; $c.Run.Exit = $true; $c.Output.Verbosity = 'Detailed'; Invoke-Pester -Configuration $c"

  macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install bats-core and shellcheck
        run: |
          brew install bats-core shellcheck
      - name: Prove /bin/bash is 3.2
        run: |
          /bin/bash --version | head -n 1
          /bin/bash -c '[ "${BASH_VERSINFO[0]}" = 3 ]'
      - name: Run the laptop suites under /bin/bash
        run: |
          env PATH="/bin:/usr/bin:$(brew --prefix)/bin" TK_EXPECT_BASH_MAJOR=3 "$(brew --prefix)/bin/bats" tests/bats/laptop-wrapper.bats tests/bats/completion.bats tests/bats/laptop-config.bats tests/bats/laptop-blocks.bats tests/bats/laptop-deploy.bats tests/bats/parity.bats tests/bats/smoke.bats tests/bats/lint-laptop.bats
      - name: shellcheck the laptop files
        run: |
          shellcheck --shell=bash -S warning laptop/tmuxkeep.sh laptop/deploy.sh laptop/completion.bash tests/bats/laptop-helpers.bash tests/bats/stubs/ssh tests/bats/stubs/scp tests/bats/stubs/ssh-keygen tests/smoke.sh tests/run-bats.sh
```

- [ ] **Step 1: Write the failing test `tests/bats/ci.bats`**

```bash
#!/usr/bin/env bats
# Static checks on .github/workflows/ci.yml (spec 9.6, 14). The workflow itself first runs on GitHub;
# these checks keep its required parts from drifting.
load laptop-helpers

setup() { CI_FILE="$REPO/.github/workflows/ci.yml"; }

@test "runs on push and pull_request" {
  grep -qx 'on:' "$CI_FILE"
  grep -qx '  push:' "$CI_FILE"
  grep -qx '  pull_request:' "$CI_FILE"
}

@test "has the three jobs on the three runners" {
  grep -qx '  bats:' "$CI_FILE"
  grep -qx '    runs-on: ubuntu-latest' "$CI_FILE"
  grep -qx '  pester:' "$CI_FILE"
  grep -qx '    runs-on: windows-latest' "$CI_FILE"
  grep -qx '  macos:' "$CI_FILE"
  grep -qx '    runs-on: macos-latest' "$CI_FILE"
}

@test "the bats job runs every suite through tests/run-bats.sh" {
  grep -qx '          bash tests/run-bats.sh' "$CI_FILE"
}

@test "the pester job proves Windows PowerShell 5.1 and runs Pester under powershell.exe -NoProfile" {
  [ "$(grep -c '        shell: cmd' "$CI_FILE")" -eq 3 ]
  grep -qF "PSEdition -ne 'Desktop' -or \$PSVersionTable.PSVersion.Major -ne 5" "$CI_FILE"
  grep -qF 'Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser' "$CI_FILE"
  grep -qF "\$c.Run.Path = 'tests\pester'" "$CI_FILE"
  [ "$(grep -c 'powershell.exe -NoProfile' "$CI_FILE")" -eq 3 ]
}

@test "the macos job proves /bin/bash 3.2 and runs every laptop suite under it" {
  grep -qF "/bin/bash -c '[ \"\${BASH_VERSINFO[0]}\" = 3 ]'" "$CI_FILE"
  grep -qF 'env PATH="/bin:/usr/bin:$(brew --prefix)/bin" TK_EXPECT_BASH_MAJOR=3' "$CI_FILE"
  local f
  for f in laptop-wrapper completion laptop-config laptop-blocks laptop-deploy parity smoke lint-laptop; do
    grep -qF "tests/bats/$f.bats" "$CI_FILE" || { echo "missing tests/bats/$f.bats"; return 1; }
  done
}

@test "the workflow is ASCII, uses spaces only, and has LF line endings" {
  [ "$(LC_ALL=C tr -d '\000-\177' < "$CI_FILE" | wc -c | tr -d ' ')" = 0 ]
  [ "$(tr -cd '\t\r' < "$CI_FILE" | wc -c | tr -d ' ')" = 0 ]
}
```

- [ ] **Step 2: Run to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/ci.bats`
Expected: `not ok` lines (no workflow yet).

- [ ] **Step 3: Create `.github/workflows/ci.yml` with the content above**

`.github/` is not under the `.gitattributes` LF rules; the Windows checkout may write it with CRLF. Make sure the working-tree file has LF (fix with `sed -i 's/\r$//' .github/workflows/ci.yml` in Git Bash) and add the line `.github/** text eol=lf` to `.gitattributes`, so the test above holds on every checkout.

- [ ] **Step 4: Run until green**

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/ci.bats`: 6 tests, all `ok`.
- the whole bats directory and the whole Pester folder (G8). `tests/pester/static.Tests.ps1`'s `.gitattributes` test still passes (it checks other paths).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml .gitattributes tests/bats/ci.bats
git commit -m "Add CI: bats in Docker on Linux, Pester under Windows PowerShell 5.1, laptop suites under macOS /bin/bash 3.2"
```

---

### Task 19: README rewrite

Suggested model: sonnet (documentation with judgment).

**Files:**
- Replace: `README.md`

**Interfaces:**
- Consumes: the whole plan's behaviour and messages, in particular G27-G32, the Review Focus items, Tasks 2-18, and plan Q2, Q3, Q4, Q13. The current `README.md` (v1, renamed in Task 1) is good source material for the sections that did not change (TOTP, migration, audit rotation, residual risks, troubleshooting); rewrite it, do not patch it.
- Produces: the operator manual for a reader who has never seen this repository (spec 10.2). `tests/pester/deploy.Tests.ps1` requires the exact text `ssh to tmuxkeep-admin failed (exit 255)` in it.

**Rules (spec 10.2):**
- Examples use `203.0.113.10` as the VPS address, `198.51.100.x` for any other address, and `you` as the laptop user (`C:\Users\you`, `/Users/you`). No real address, no personal path (G4).
- "Claude Code" appears only in: the default commands (`LAUNCH_CMD=claude`, `RESUME_CMD=claude --continue`), the `INSTALL_CLAUDE_CODE` key, and one sentence in Overview saying the tool was built for it. Every line that contains `Claude Code` must also contain `LAUNCH_CMD`, `RESUME_CMD`, `INSTALL_CLAUDE_CODE` or `built for`.
- ASCII only; no mention of the old name (G12).
- Use exactly these headings, in this order (the checks grep for them):

  1. `# tmuxkeep`
  2. `## Overview`: what it does (sessions in tmux on your VPS, one ssh round trip per command, soft delete, TOTP gate, append-only audit log, hourly reaper); one paragraph on the security model; the platforms (Windows PowerShell 5.1; bash 3.2 or later on macOS and Linux, WSL included; Debian or Ubuntu VPS with systemd and root access); the two ssh identities as a table (`tmuxkeep`: the session key, no passphrase, forced command `/usr/local/bin/tmuxkeep --key laptop` as `USER`; `tmuxkeep-admin`: the admin key with a passphrase, root, for deploys only); one sentence: "It was built for Claude Code, and its default session commands start it, but any long-running command-line tool works."; one line: MIT licence, see `LICENSE`.
  3. `## Install on Windows`: prerequisites (Windows PowerShell 5.1 `powershell.exe`, the Windows OpenSSH client, `git`, a git checkout of this repository, an authenticator app, root on the VPS). Steps in order: (1) `powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 -Init`, which asks `VPS address (hostname or IP)`, writes `~\.tmuxkeep\config`, creates the session key and writes both Host blocks, then prints the admin-key steps; (2) the admin key: the three spec 6.5 steps as `Get-TmuxkeepAdminHelp` prints them (passphrase required; never `ssh-add` it; never `AddKeysToAgent`); (3) optional facts: `Get-Content .\vps\vps-facts.sh | ssh tmuxkeep-admin 'bash -s' | Out-File -Encoding utf8 docs\vps-facts.md` (use `'bash -s -- --user <name>'` for another USER; the one harmless BOM line; the file is git-ignored; what to look for); (4) optionally set `INSTALL_CLAUDE_CODE=yes` and other keys; (5) the first deploy, `powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1`: the passphrase is asked twice (scp, ssh); the first run prints the TOTP secret and QR code once: scan it, never paste or screenshot it, never give it to an agent or a chat; what the installer sets up; the execution-policy note (`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`); open a new window; (6) the first-run checklist the installer prints; (7) `-HardenRoot` (sticky, how to verify, how to undo); (8) `-RotateTotp` and `-UnlockOtp`.
  4. `## Install on macOS and Linux`: prerequisites (bash 3.2 or later, OpenSSH client, git, the checkout); the same steps with `bash laptop/deploy.sh --init`, the bash form of the admin-key steps, `ssh tmuxkeep-admin 'bash -s' < vps/vps-facts.sh > docs/vps-facts.md`, `bash laptop/deploy.sh`, and `--harden-root`, `--rotate-totp`, `--unlock-otp`; where things go (`~/.local/bin/tmuxkeep`, `~/.tmuxkeep/completion.bash`, the rc block in `~/.zshrc` when `$SHELL` ends in `zsh`, else `~/.bashrc`); macOS bash users: Terminal starts login shells, so `~/.bash_profile` must source `~/.bashrc`; zsh: the block loads `compinit` itself when it has not run (plan Q3).
  5. `## Configuration`: the laptop file `~/.tmuxkeep/config` with a table of all sixteen keys (key, default, valid values, what it does), the file rules of spec 4.1 (KEY=value, no quotes, unknown keys and non-ASCII are errors, LF only, no BOM, last repeat wins), `-Config`/`--config`; the two ssh aliases are fixed; write-or-replace: the next deploy rewrites the `# >>> tmuxkeep` blocks in `~/.ssh/config`, the PowerShell profile and the rc file in place, so a changed `HOST` or `PORT` takes effect, while text outside the markers is never touched; `deploy.conf` (what crosses to the VPS; no secret); the VPS file `/etc/tmuxkeep/tmuxkeep.conf` (root-owned 0644, rewritten on every deploy, so edit the laptop file instead; checked with `tmuxkeep --check-conf` before it is installed; a bad or missing file makes the broker refuse every call); `--cmd` for one session, and `--cmd ' '` for a shell only from the wrappers (plan Q2). A subsection `### Changing the VPS user`: the installer refuses a USER different from the installed one and any system account (uid outside 1000-59999); to move from one user to another, as root over `tmuxkeep-admin`: disable the old user's timer (`runuser -u <old> -- env XDG_RUNTIME_DIR=/run/user/<old uid> systemctl --user disable --now tmuxkeep-reaper.timer`), move or end its tmux sessions and work, `chattr -a /var/log/tmuxkeep/audit.log && chown <new>:<new> /var/log/tmuxkeep/audit.log && chattr +a /var/log/tmuxkeep/audit.log`, `rm /etc/tmuxkeep/tmuxkeep.conf`, then deploy with the new `USER`.
  6. `## Everyday use`: the verb table (every verb, its arguments including `--repo` and `--cmd`, gated or not, an example), `reap` is local only, the exit-code table, names, tombstones and the reaper (`TOMBSTONE_TTL`), the `ls` columns, the order of checks (a typo never costs a TOTP prompt), tab completion on both platforms (cached 60 seconds; offline Tab is quick).
  7. `## Quoting rules`: PowerShell 5.1 (single-quote inline text; `send <name>` with no text prompts locally; `,` makes an array; empty arguments and `--` are dropped by PowerShell; `-n` works) and bash/zsh (normal shell quoting; `send <name>` with no text prompts on the terminal; `--` is passed through and sent like any word).
  8. `## TOTP, leases and lockout`: `tmuxkeep auth`; the lease per key id and client address, `LEASE_SECS`; `OTP_FAIL_MAX` in `OTP_FAIL_WINDOW` gives `OTP_COOLDOWN`; `OTP_HARD_MAX` locks until `-UnlockOtp`/`--unlock-otp` or root removes `<USER_HOME>/.tmuxkeep/otp-locked`; the code is read on the VPS terminal and never logged.
  9. `## Migrating work from root`: the v1 steps with `<USER>` and `<WORK_DIR>` (the default `/home/claude/work`).
  10. `## Audit log and rotation`: `/var/log/tmuxkeep/audit.log`, the JSON fields (and the extra `cmd` field when `--cmd` was used), `tmuxkeep log -n 50`, the root rotation procedure (`chattr -a`, rotate, `chattr +a`).
  11. `## Security model and residual risks`: v1 spec 2 and 7.4 stated plainly (the gate does not hold against code running as USER; sessions can reach each other; `docker` group and the sudoers allowlist are effectively root-equivalent; about three guesses per ten minutes until the hard lock; `.bashrc` runs before the forced command), plus spec 8: the VPS config is root-owned and the broker fails closed; whoever can edit `~/.tmuxkeep/config` decides what the next deploy installs, which is the laptop's own trust level, and the admin passphrase still gates every deploy; `--cmd` is an audited, gated form of what `send` allows; the templates substitute only a validated user name; nothing secret is in the repository or in `deploy.conf`.
  12. `## Development and tests`: the layout (spec 11); `tests/run-bats.ps1` (Windows, Docker Desktop) and `tests/run-bats.sh` (macOS, Linux, Git Bash); installing Pester (`Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck`) and the G6 run command; CI (the three jobs and what each proves); how to add a test (bats: `load helpers` for broker and installer suites run in Docker, `load laptop-helpers` for laptop suites that must also pass under macOS `/bin/bash` 3.2; Pester: one top-level `Describe`, no angle brackets in names; fixtures in `tests/fixtures/` hold the bytes both deploys must write); the bash 3.2 and PowerShell 5.1 rules in short; `.gitattributes` and why LF matters, with the Git Bash check `grep -rlIU "$(printf '\r')" vps tests laptop/*.sh laptop/completion.bash`; the smoke tests `tests\smoke.ps1` and `bash tests/smoke.sh` are run by the operator against the real VPS only.
  13. `## Troubleshooting`: a table of message and what to do, with at least these messages: the wrapper's 255 hint (`ssh to host 'tmuxkeep' failed`); `deploy: the admin key was not accepted, or tmuxkeep-admin is unreachable`; `deploy: ssh to tmuxkeep-admin failed (exit 255)`; `deploy: config ... HOST: looks like host:port; put the port in PORT`; `deploy: config ...` in general; `tmuxkeep-setup: deploy.conf invalid`; `tmuxkeep-setup: refusing USER=`; `tmuxkeep-setup: USER changed from`; `the broker rejected the new configuration`; `tmuxkeep: config invalid`; `TOTP required`; `cooldown`; `OTP locked`; `audit log not writable`; `complete:13: command not found: compdef` (an rc block written by hand without the compinit part: deploy again); completion showing nothing offline for up to 60 seconds (by design).

- [ ] **Step 1: Write `README.md`**

- [ ] **Step 2: Check the headings, the required strings and the rules**

Run (Git Bash):

```bash
for h in '# tmuxkeep' '## Overview' '## Install on Windows' '## Install on macOS and Linux' '## Configuration' '### Changing the VPS user' '## Everyday use' '## Quoting rules' '## TOTP, leases and lockout' '## Migrating work from root' '## Audit log and rotation' '## Security model and residual risks' '## Development and tests' '## Troubleshooting'; do grep -qxF "$h" README.md || echo "missing heading: $h"; done
prev=0; for h in '# tmuxkeep' '## Overview' '## Install on Windows' '## Install on macOS and Linux' '## Configuration' '## Everyday use' '## Quoting rules' '## TOTP, leases and lockout' '## Migrating work from root' '## Audit log and rotation' '## Security model and residual risks' '## Development and tests' '## Troubleshooting'; do n=$(grep -nxF "$h" README.md | head -n 1 | cut -d: -f1); if [ -z "$n" ] || [ "$n" -le "$prev" ]; then echo "out of order: $h"; fi; prev=${n:-$prev}; done
for k in HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES; do grep -q "\`$k\`" README.md || echo "key not documented: $k"; done
for s in 'ssh to tmuxkeep-admin failed (exit 255)' 'tmuxkeep-admin' '--check-conf' 'chattr -a' 'root-equivalent' '-UnlockOtp' '--unlock-otp' '-Init' '--init' 'compinit' 'LICENSE' 'run-bats.sh'; do grep -qF -- "$s" README.md || echo "missing text: $s"; done
grep -n 'Claude Code' README.md | grep -vE 'LAUNCH_CMD|RESUME_CMD|INSTALL_CLAUDE_CODE|built for'
grep -oE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' README.md | grep -vE '^(192\.0\.2|198\.51\.100|203\.0\.113)\.[0-9]+$|^127\.0\.0\.1$'
grep -n -i sesh README.md
[ "$(LC_ALL=C tr -d '\r\n\t -~' < README.md | wc -c | tr -d ' ')" = 0 ] || echo 'non-ASCII bytes in README.md'
```

Expected: no `missing ...`, `out of order`, `key not documented` or `non-ASCII` lines; the `Claude Code`, address and old-name checks print nothing. (Git for Windows' grep strips a trailing CR without `-U`, so `-x` works on a CRLF checkout.) (README.md is not under the LF rule, so the Windows checkout may hold CRLF; the checks allow for it.)

- [ ] **Step 3: Run the whole Pester folder (G6)**

Expected: 0 failed; `deploy.ps1 main sequence` still finds the 255 message in the README.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "README: rewritten for a new reader: both platforms, configuration, user changes, CI, troubleshooting"
```

---

### Task 20: LICENSE, `.gitignore`, v1 document headers, scrub

Suggested model: haiku. Justification: every file content, every command and every expected result is written below; the scrub patterns are spelled with character classes (`161[.]97`, `Doug[C]`) so that this plan does not itself contain what it removes. If any check prints something unexpected, stop and report it.

**Files:**
- Create: `LICENSE`
- Replace: `.gitignore`
- Modify: `tests/pester/deploy.Tests.ps1` (the `.gitignore` test)
- Modify: `docs/superpowers/specs/2026-10-09-sesh-session-broker-design.md`, `docs/superpowers/plans/2026-10-09-sesh-session-broker.md` (header note, scrub)
- Modify: `docs/superpowers/specs/2026-10-12-tmuxkeep-public-release-design.md` (six lines, plan Q6)
- Modify: any other tracked file the scrub finds (expected: none outside `docs/superpowers/` after Tasks 9 and 19)

**Interfaces:**
- Consumes: the tree after Task 19.
- Produces: a tree that passes the spec 10.3 grep and is ready for the history reset (not a task; see "After the merge").

**Behaviour (spec 8, 10.1, 10.3, 10.4, D7, D8; plan Q6):** exactly the steps below.

- [ ] **Step 1: Create `LICENSE` with exactly this content**

```
MIT License

Copyright (c) 2026 Douglas Rojas

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Replace `.gitignore` with exactly these three lines**

```
.claude/
.superpowers/
docs/vps-facts.md
```

Then check that nothing tracked is orphaned (spec 14): `git ls-files docs/vps-facts.md` must print nothing, and `git check-ignore -q docs/vps-facts.md; echo $?` must print `0`.

- [ ] **Step 3: Extend the `.gitignore` test in `tests/pester/deploy.Tests.ps1`**

In `Describe '.gitignore'`, change the line `foreach ($p in '.claude/worktrees/x', '.superpowers/x') {` to `foreach ($p in '.claude/worktrees/x', '.superpowers/x', 'docs/vps-facts.md') {`, and the `It` name to `'ignores agent worktrees, superpowers scratch files and the VPS facts output'`.

- [ ] **Step 4: Insert the historical-record note after the title line of both v1 documents**

Run (Git Bash):

```bash
H=$(mktemp)
printf '%s\n' '' \
  '> Historical design record for v1, which shipped under the name `sesh`. The tool is now' \
  '> `tmuxkeep`; paths, aliases and file names in this document are the v1 ones. Where' \
  '> this document and `README.md` differ, the README is right.' > "$H"
sed -i "1r $H" docs/superpowers/specs/2026-10-09-sesh-session-broker-design.md docs/superpowers/plans/2026-10-09-sesh-session-broker.md
rm -f "$H"
head -n 6 docs/superpowers/specs/2026-10-09-sesh-session-broker-design.md
head -n 6 docs/superpowers/plans/2026-10-09-sesh-session-broker.md
```

Expected for each file: line 1 is the old title, line 2 is empty, lines 3-5 are the three `>` lines, line 6 is empty.

- [ ] **Step 5: Rewrite the six lines of the v1.1 spec that quote the scrub patterns (plan Q6)**

First confirm the line numbers (Git Bash):

```bash
S=docs/superpowers/specs/2026-10-12-tmuxkeep-public-release-design.md
grep -n -i -E '161[.]97|doug[c]' "$S" | cut -d: -f1 | tr '\n' ' '
```

Expected: `529 530 531 540 560 568 `. If the numbers differ, stop and report. Otherwise run the following. It uses GNU sed's one-line `c\` form and contains no backslash inside the new text on purpose: in Git Bash a doubled backslash in that text is lost.

```bash
sed -i \
  -e '529c\| the real VPS address | `203.0.113.10` |' \
  -e '530c\| the Windows profile path of the author | the same path with the user name replaced by `<you>` |' \
  -e '531c\| the macOS home path, the user name and the handles of the author (any remaining) | `<you>` |' \
  -e '540c\A final grep for the real address, the author user name and both handles over the tree must be' \
  -e '560c\5. Verify: `git log --oneline` on `main` shows one commit; a `git grep` for the real address on it is' \
  -e '568c\`gh repo create <you>/tmuxkeep --public --source . --remote origin --push`, then' \
  "$S"
sed -n '529,531p;540,541p;560,561p;568,569p' "$S"
```

Expected output of the last command (line 561 keeps its three leading spaces):

```
| the real VPS address | `203.0.113.10` |
| the Windows profile path of the author | the same path with the user name replaced by `<you>` |
| the macOS home path, the user name and the handles of the author (any remaining) | `<you>` |
A final grep for the real address, the author user name and both handles over the tree must be
empty.
5. Verify: `git log --oneline` on `main` shows one commit; a `git grep` for the real address on it is
   empty; `git branch` lists `main` and `v1-history`.
`gh repo create <you>/tmuxkeep --public --source . --remote origin --push`, then
`git push origin v0.1.0`. No agent runs these.
```

- [ ] **Step 6: The repository-wide scrub (spec 10.3)**

The spec's table replaces the address, then the author's Windows and macOS paths, then any remaining user name. Because both paths differ from their replacements only in the user name, replacing the user name (and the two handles, plan Q6) everywhere gives the same result without writing a backslash. Run (Git Bash), in this order:

```bash
git grep -l -E '161[.]97[.]142[.]123' | xargs -r sed -i 's/161[.]97[.]142[.]123/203.0.113.10/g'
git grep -l -i -E 'doug[c]r?95|Doug[C]' | xargs -r sed -i -E 's/[Dd]oug[Cc]r?95|Doug[C]/<you>/g'
```

- [ ] **Step 7: The checks (each must print nothing unless stated)**

Run (Git Bash):

```bash
git grep -n -i -E '161[.]97|doug[c]'
git grep -n -i sesh -- . ':!docs/superpowers'
git grep -n -w vps -- . ':!docs/superpowers' | grep -vE 'vps[/\\]|vps-facts|@vps|[/\\]vps\b'
git grep -n -E 'id_vps_admin|vps-admin|Host vps\b' -- . ':!docs/superpowers'
git status --short
```

Expected: the first four print nothing (the third: no `vps` ssh alias outside the two v1 documents; directory names and the `tmuxkeep@vps` TOTP label are allowed); `git status --short` lists `LICENSE`, `.gitignore`, `tests/pester/deploy.Tests.ps1` and the three documents under `docs/superpowers/`, and nothing else. If any other file is listed, stop and report it (Tasks 9 and 19 should have left no address in code or README).

- [ ] **Step 8: Full suites**

Run the whole bats directory (G5) and the whole Pester folder (G6). Both green.

- [ ] **Step 9: Commit**

```bash
git add LICENSE .gitignore tests/pester/deploy.Tests.ps1 docs/superpowers/specs/2026-10-09-sesh-session-broker-design.md docs/superpowers/plans/2026-10-09-sesh-session-broker.md docs/superpowers/specs/2026-10-12-tmuxkeep-public-release-design.md
git commit -m "release hygiene: MIT LICENSE, ignore docs/vps-facts.md, v1 docs marked historical, scrub personal values"
```

---

### Task 21: Full verification report

Suggested model: haiku. Justification: it runs fixed commands, compares their output with the exact expectations below and reports; it changes nothing.

**Files:** none (read-only).

- [ ] **Step 1: Run the whole bats directory**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1`
Record the number of `ok` lines, the number of `not ok` lines (expected 0) and the exit code (expected 0). Copy the names of any failing tests verbatim.

- [ ] **Step 2: Run the whole Pester folder**

Run the G6 command with `$c.Run.Path = 'tests\pester'`. Record the `Tests Passed: N, Failed: M` line (expected `Failed: 0`) and any failing test names verbatim.

- [ ] **Step 3: Repository checks (Git Bash)**

```bash
grep -rlIU "$(printf '\r')" vps tests laptop/*.sh laptop/completion.bash .github
git ls-files --eol vps tests laptop/tmuxkeep.sh laptop/deploy.sh laptop/completion.bash .github | grep -v 'i/lf'
git ls-files -s vps/tmuxkeep vps/tmuxkeep-setup vps/vps-facts.sh tests/bats/stubs/oathtool tests/bats/stubs/ssh tests/bats/stubs/scp tests/bats/stubs/ssh-keygen laptop/tmuxkeep.sh laptop/deploy.sh tests/run-bats.sh tests/smoke.sh | cut -c1-6 | sort -u
git grep -n -i sesh -- . ':!docs/superpowers'
git grep -n -i -E '161[.]97|doug[c]'
git status --porcelain
git ls-files
```

Expected:
- the first, second, fourth, fifth and sixth commands print nothing;
- the third prints exactly `100755`;
- `git ls-files` prints exactly these 70 paths, in this order (spec 11 plus this plan's test files):

```
.gitattributes
.github/workflows/ci.yml
.gitignore
LICENSE
README.md
docs/superpowers/plans/2026-10-09-sesh-session-broker.md
docs/superpowers/plans/2026-10-12-tmuxkeep-public-release.md
docs/superpowers/specs/2026-10-09-sesh-session-broker-design.md
docs/superpowers/specs/2026-10-12-tmuxkeep-public-release-design.md
laptop/completion.bash
laptop/deploy.ps1
laptop/deploy.sh
laptop/profile-snippet.ps1
laptop/tmuxkeep.ps1
laptop/tmuxkeep.sh
tests/bats/00-env.bats
tests/bats/broker-cmd.bats
tests/bats/broker-config.bats
tests/bats/broker-core.bats
tests/bats/broker-exact.bats
tests/bats/broker-gate.bats
tests/bats/broker-lifecycle.bats
tests/bats/broker-new-send-go.bats
tests/bats/broker-read.bats
tests/bats/broker-remote.bats
tests/bats/broker-resume-reap.bats
tests/bats/ci.bats
tests/bats/completion.bats
tests/bats/config.bats
tests/bats/facts.bats
tests/bats/helpers.bash
tests/bats/laptop-blocks.bats
tests/bats/laptop-config.bats
tests/bats/laptop-deploy.bats
tests/bats/laptop-helpers.bash
tests/bats/laptop-wrapper.bats
tests/bats/lint-laptop.bats
tests/bats/lint.bats
tests/bats/parity.bats
tests/bats/setup-conf.bats
tests/bats/setup-render.bats
tests/bats/setup.bats
tests/bats/smoke.bats
tests/bats/stubs/oathtool
tests/bats/stubs/scp
tests/bats/stubs/ssh
tests/bats/stubs/ssh-keygen
tests/docker/Dockerfile
tests/fixtures/deploy.conf
tests/fixtures/laptop-config
tests/fixtures/ssh-block
tests/fixtures/tmuxkeep.conf
tests/pester/completer.Tests.ps1
tests/pester/config.Tests.ps1
tests/pester/deploy.Tests.ps1
tests/pester/smoke.Tests.ps1
tests/pester/static.Tests.ps1
tests/pester/tmuxkeep.Tests.ps1
tests/run-bats.ps1
tests/run-bats.sh
tests/smoke.ps1
tests/smoke.sh
vps/sshd.conf.tmpl
vps/sudoers.tmpl
vps/systemd/tmuxkeep-reaper.service
vps/systemd/tmuxkeep-reaper.timer
vps/tmux.conf
vps/tmuxkeep
vps/tmuxkeep-setup
vps/vps-facts.sh
```

- [ ] **Step 4: Report**

Report a short table: bats totals and exit code, Pester totals, CR check, eol check, exec bits, the old-name grep, the scrub grep, a clean tree, and whether `git ls-files` matched (list any extra or missing path). Copy failing test names verbatim. Do not fix anything; the orchestrator re-briefs.

---

## After the merge (not tasks)

These happen after Task 21 is green, the branch is merged to `main` and its worktree is removed. No implementer runs them.

1. **Optional CI dry run (orchestrator with Doug, plan Q16).** CI cannot run before the code is on GitHub. Push the merged `main` to a private scratch repository, confirm the three jobs (`bats`, `pester`, `macos`) are green, fix forward if not, then delete the scratch repository.
2. **History reset (spec 10.6; orchestrator, only after Doug says go at step d).**
   a. On `main`: `git grep -n -i -E '161[.]97|doug[c]'` prints nothing, and both suites are green.
   b. `git branch v1-history main` (kept locally, never pushed).
   c. `git checkout --orphan public`, `git add -A`, one commit with the message `tmuxkeep 0.1.0: initial public release`. Check `git config user.name` and `git config user.email` first: they become public on that commit (plan Q17).
   d. With Doug's go: `git branch -D main && git branch -m public main`, then `git tag v0.1.0`.
   e. Verify: `git log --oneline` shows one commit; `git grep -n -i -E '161[.]97|doug[c]'` is empty; `git branch` lists `main` and `v1-history`.
3. **Publishing (spec 10.7; operator only).** `gh repo create <you>/tmuxkeep --public --source . --remote origin --push`, then `git push origin v0.1.0`. Release notes live on the tag; there is no changelog file (spec 10.5).
4. **Doug's own install (spec 13; operator only; replaces v1 O1-O7).**
   1. Create `~/.ssh/id_tmuxkeep_admin_ed25519` with a passphrase.
   2. `powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 -Init`: answer the VPS address; it writes the config, the session key and both Host blocks, then prints the admin-key steps.
   3. Install the admin public key with one root password login (the printed step 2), then `ssh -o PasswordAuthentication=no tmuxkeep-admin true`.
   4. Facts: `Get-Content .\vps\vps-facts.sh | ssh tmuxkeep-admin 'bash -s' | Out-File -Encoding utf8 docs\vps-facts.md`; hand it to the orchestrator for the v1 G1 review (the file is git-ignored).
   5. Set `INSTALL_CLAUDE_CODE=yes` in `~\.tmuxkeep\config`, run `laptop\deploy.ps1` (passphrase twice; the TOTP QR code is shown once and never pasted into an agent conversation).
   6. `tmuxkeep new scratch`, `tmuxkeep go scratch`, log Claude Code in, detach.
   7. Migrate work out of `/root` (README "Migrating work from root").
   8. `tests\smoke.ps1`.
   9. `laptop\deploy.ps1 -HardenRoot`.
   10. Publish (item 3).

## Self-review

**1. Spec coverage (sections 4-12, plus 13-14).**

| Spec | Requirement | Task(s) |
|---|---|---|
| 4.1 | One `KEY=value` per line; trim; blank and `#` lines skipped; first `=` splits; unknown key is an error; last repeat wins; values 0x20-0x7E only; no CR, no BOM; message names the file | 2 (broker), 5 (installer), 7 (PowerShell), 12 (bash); rules in G30 |
| 4.2 | `~/.tmuxkeep/config`, every key, default and validation | 7, 12 (G31, G32) |
| 4.2 | First run asks one question, validates `HOST`, writes every key with a comment above each | 7, 12 (functions), 9, 14 (main sequence) |
| 4.2 | Later runs never prompt; an invalid file is an error naming the key | 9, 14 |
| 4.2 | `--config` / `-Config` | 9, 14 |
| 4.2 | Fixed aliases `tmuxkeep`, `tmuxkeep-admin` | 8, 13 (block), G27 |
| 4.3 | `deploy.conf` in the staging folder with the twelve keys; no command-line values; the installer validates it again with `--conf`; no secret | 7, 12 (text), 9, 14 (staged, remote command), 5 (reader), fixture `deploy.conf` |
| 4.4 | `/etc/tmuxkeep/tmuxkeep.conf` written every run, atomically, root 0644, keys and values of the table | 6 (writer), 2 (fixture) |
| 4.4 | Hand edits overwritten, README says so | 19 |
| 4.4 | `OTP_STEP`, `SEND_ENTER_DELAY` stay constants | 2 |
| 4.4 | Broker's own strict parser with a whitelist, never `source`; remote missing or invalid file is exit 1 with `tmuxkeep: config invalid: <reason>` and no audit line | 2 (and the `never sources` lint) |
| 4.5 | Laptop: `--config` only, no environment override | 9, 14 |
| 4.5 | Broker local mode: `TMUXKEEP_CONF`, built-in defaults otherwise (amended by plan Q1 to read the system file when it exists); renamed `TMUXKEEP_*` overrides with the same guard; all ignored in remote mode | 1 (rename), 2 |
| 4.5 | Installer: flags only, defaults without `--conf` | 5 |
| 5 | Every rename-map row; the unchanged items stay unchanged; `git grep -i sesh` outside `docs/superpowers/` is empty | 1 (all rows; template file names), 8, 13 (aliases), 9, 14 (stage names), 19 (README), 21 (final check); G12 |
| 6.1 | Wrapper: ssh options, `-t` for gated verbs, local checks, ssh's exit code, 255 hint naming `tmuxkeep` | 10 (bash), 1 (PowerShell, renamed) |
| 6.1 | One gated list in both wrappers and the broker | 15 (parity), 10, v1 Pester assertion |
| 6.1 | Deploy steps 0-9 in order, the exact remote command line (plus cleanup, plan Q4) | 9, 14 |
| 6.1 | `--init`/`-Init` stops after step 3; `--harden-root`, `--rotate-totp`, `--unlock-otp` and the PowerShell spellings | 9, 14 |
| 6.1 | Two-host marked block, write-or-replace, CRLF from PowerShell, LF from bash, no `AddKeysToAgent` | 8, 13 (and G3 tests in 9, 14) |
| 6.2 | `laptop/tmuxkeep.ps1`, `global:tmuxkeep`, completer for `tmuxkeep`, the two cache names, 5.1 rules | 1 |
| 6.3 | `deploy.ps1` keeps its shape and gains the config functions, `deploy.conf` writer, `Set-TmuxkeepMarkedBlock`, `laptop.pub`, `-Init`, `-Config`, step 7, admin help from the config | 7, 8, 9 |
| 6.4 | bash 3.2, shellcheck with `--shell=bash` and no exclusions | 10 (`lint-laptop.bats`), 17, 18; G19-G21 |
| 6.4 | `laptop/tmuxkeep.sh`: `base64 \| tr -d '\n'`, empty word, `tk_prompt` for both prompts, ssh in the foreground, 255 message, source guard | 10 |
| 6.4 | `laptop/deploy.sh`: the nine steps, source guard, step 7 copies and the rc block in `~/.zshrc` or `~/.bashrc` (write-or-replace) | 12, 13, 14 |
| 6.4 | `laptop/completion.bash`: verbs, names, tombstones, the exact ssh, 60-second cache in `${TMPDIR:-/tmp}`, empty cache on failure, stderr discarded only there | 11 |
| 6.4 | Tests force `/bin/bash` on macOS | 10 (G22, interpreter test), 18 |
| 6.5 | Admin-key help text with config values; never `ssh-add` | 9, 14, 19 |
| 7.1 | Broker reads the config; `DEFAULT_*` and tunables come from it | 2 |
| 7.1 | `new` types `LAUNCH_CMD`, `resume` types `RESUME_CMD`, empty types nothing, `--repo` unchanged | 3 |
| 7.1 | `--cmd` for `new` and `resume`, 0-200 printable ASCII, `cmd` audit field, gated | 3 |
| 7.1 | `ls`/`reap` unchanged; messages `tmuxkeep:`; header comment | 3, 1 |
| 7.2 | `--conf` checked before any step, exit 2 naming the key | 5 |
| 7.2 | `TK_USER`/`TK_HOME`, home from `getent`, `useradd -m -s /bin/bash` | 5 |
| 7.2 | `__USER__` templates rendered, validated (`visudo -cf`; `sshd -T` checks), moved into place; file names | 6 |
| 7.2 | `/etc/tmuxkeep/tmuxkeep.conf` written and checked with `tmuxkeep --check-conf` | 6 (plan Q7), 2 (`--check-conf`) |
| 7.2 | Claude Code install and the root warning only with `INSTALL_CLAUDE_CODE=yes`; TOTP output unchanged; `tmuxkeep-setup:` messages; next steps name `WORK_DIR` | 5, 1 |
| 7.3 | Facts `--user`, CR guard kept, output git-ignored | 4, 20 |
| 7.4 | tmux and systemd files renamed; hourly, persistent, `/usr/local/bin/tmuxkeep reap` | 1, 6 (`config.bats`) |
| 8 | Root-owned VPS config, broker fails closed | 2, 6 |
| 8 | Laptop-config trust and the admin passphrase; `--cmd` audited; template values validated; `deploy.conf` has no secret; nothing secret published | 19 (stated), 3, 5, 6, 7, 12, 20, "After the merge" |
| 9.1 | Renamed suites; temp config via `TMUXKEEP_CONF`; config tests; `new`/`resume` tests; installer tests; rendered-output `cmp` tests | 1, 2, 3, 5, 6 |
| 9.2 | `laptop-wrapper.bats`, `laptop-deploy.bats` (plus `laptop-config.bats`, `laptop-blocks.bats`), `completion.bats`; stub ssh, scp, ssh-keygen; prompts through `tk_prompt`; temp `HOME` and `--config` | 10, 11, 12, 13, 14 |
| 9.3 | `parity.bats`: gated verbs, staged files, completer verbs, with exact extractions; Pester keeps its own assertion | 15, 1 |
| 9.4 | Pester: config read, write, interactive with `Read-Host` mocked, failures by key; marked block with two hosts; admin help with no literal address; `deploy.conf` and `laptop.pub` staged; `-Init`; remote command line | 7, 8, 9 |
| 9.5 | shellcheck over the listed files; CR/BOM/ASCII in Pester including `laptop/*.sh`; `.gitattributes` lines | 10, 17 |
| 9.6 | `ci.yml` with the three jobs; version proofs; `tests/run-bats.sh` | 17, 18 |
| 9.7 | `smoke.ps1` renamed; `smoke.sh` twin; agents never run them for real | 1, 16; G2 |
| 10.1 | MIT `LICENSE`, `Copyright (c) 2026 Douglas Rojas` | 20 |
| 10.2 | README sections, examples, Claude Code mentions | 19 |
| 10.3 | Scrub table, v1 header note, final grep empty | 20 (plan Q6), 21 |
| 10.4 | `.gitignore` | 20 |
| 10.5 | Git short-hash stamp; tag `v0.1.0`; no changelog | 9, 14; "After the merge" |
| 10.6, 10.7 | History reset; publishing | "After the merge" (not tasks, by design) |
| 11 | Layout | all tasks; checked path by path in 21 |
| 12 | Laptop config missing/unknown/bad/CR/BOM; `deploy.conf` rejected; `--check-conf` failure; remote bad config; `--cmd` errors; rc or ssh config not writable | 7, 9, 12, 14; 5; 6; 2; 3; 8, 13, 14 |
| 13 | Operator steps | "After the merge" item 4 |
| 14 | PowerShell 5.1 and bash 3.2 on the runners; bats under 3.2; `docs/vps-facts.md` not tracked | 18; 18; 20 |

No gaps found.

**2. Placeholder scan.** Searched the plan for `TBD`, `TODO`, `implement later`, `fill in`, `similar to Task`, `appropriate`, and every `...`. The `...` that remain are argument notation (`WORD...`), shell syntax (`$(...)`), text a program prints (`zz~<n>~... row`), or prose pointing at existing code that the task quotes or names exactly; none stands for code an implementer has to invent. Every bats command is spelled out in full.

**3. Type and name consistency.** Every function, variable and file name used by a later task is listed in the earlier task's Interfaces and spelled the same: `parse_conf`/`CF_*`/`CONF_ERR` (2), `type_line`/`valid_cmd`/`AUDIT_CMD` (3), `read_deploy_conf`/`CONF_*`/`TK_USER`/`TK_HOME`/`VPS_CONF` (5), `render_template`/`install_sudoers`/`write_vps_conf`/`STAGED_FILES` (6), `Get-TmuxkeepConfigKeys` ... `Expand-TmuxkeepPath` (7), `Set-TmuxkeepMarkedBlock`/`Get-TmuxkeepSshBlock` (8), `Get-TmuxkeepVpsFiles`/`Get-TmuxkeepAdminHelp` (9), `TK_GATED_VERBS`/`tk_prompt`/`tk_main` (10), `_TK_VERBS`/`_TK_NAME_VERBS` (11), `tk_conf_*`/`TKC_*` (12), `tk_set_block`/`tk_rc_block` (13), `TK_VPS_FILES`/`tk_setup_command`/`tk_admin_help` (14). The four fixtures are created once (Tasks 2, 5, 7, 8) and quoted verbatim wherever consumed.

**4. Review Focus.** Each of the five items has a test in its owning task: 1 and 5 in Task 5 (`account_ok`, `user_unchanged`, and the main-order guard test), 2 in Tasks 7 and 12, 3 and 4 in Task 13.

## Questions for the orchestrator

The spec is approved; D5-D11 are not reopened. Each item is a gap, contradiction or unimplementable detail found while planning. The plan is written against the **recommended answer**; if you decide otherwise, re-brief the named task.

**Q1. The hourly reaper would ignore the configured `TOMBSTONE_TTL` (spec 4.5).** The reaper runs `tmuxkeep --key reaper reap` locally, and spec 4.5 says that in local mode without `TMUXKEEP_CONF` the built-in defaults apply. A user who set `TOMBSTONE_TTL=3600` would still see tombstones live 24 hours, and a root shell running `tmuxkeep` locally would use the default paths. **Recommendation:** local mode reads `TMUXKEEP_CONF` when set, else `/etc/tmuxkeep/tmuxkeep.conf` when it exists, else the defaults; a present but invalid system file is exit 1. Unit tests still run without a system file because `setup_local` always sets `TMUXKEEP_CONF`. *Task 2.*

**Q2. An empty `--cmd` cannot be sent by either wrapper (spec 7.1 vs 6.1).** Both wrappers reject empty words, and a `b64` token cannot be empty. **Recommendation:** the broker types nothing when the command, from `--cmd` or from the config, is empty or only spaces; the README documents `--cmd ' '` for "shell only". *Tasks 3, 19.*

**Q3. The spec's rc block breaks every new zsh on a fresh macOS account (spec 6.4).** bashcompinit's `complete` calls `compdef`, which exists only after `compinit`; without it each shell prints `complete:13: command not found: compdef`. **Recommendation:** line 2 of the block becomes `[ -n "$ZSH_VERSION" ] && { whence compdef >/dev/null || { autoload -U +X compinit && compinit -i; }; } && autoload -U +X bashcompinit && bashcompinit`. The other lines are the spec's. The zsh test in Task 13 is the proof; it could not be run while planning (no zsh in the current image and no network), so its implementer is told to stop and report if it fails as written. *Task 13 (Review Focus 4).*

**Q4. Spec 6.1 step 6 drops v1's remote cleanup.** v1 ran `...; rc=$?; rm -rf /root/<stage>; exit $rc`; the spec's form ends after the flags, so every deploy would leave a staging folder in `/root`. **Recommendation:** keep the suffix (fixed words only, so the no-quoting argument of 6.1 still holds); the tests pin the full string. *Tasks 9, 14.*

**Q5. Which keys are required is unstated.** **Recommendation:** the VPS config and `deploy.conf` require every key (both are machine-written; a missing key means a version mismatch, so fail closed); the hand-edited laptop config requires only `HOST` and fills the rest from the defaults. *Tasks 2, 5, 7, 12.*

**Q6. The scrub collides with the spec's own text (spec 10.3, 10.6, 10.7).** The v1.1 spec quotes the very strings its final grep must not find, and the GitHub handle and the e-mail handle have no replacement row. **Recommendation:** replace both handles with `<you>`, and rewrite the six spec lines that quote the patterns so they describe them instead (exact text in Task 20). This plan spells the patterns with character classes so it does not trip the grep itself. *Task 20.*

**Q7. When `--check-conf` runs (spec 7.2).** Checking `/etc/tmuxkeep/tmuxkeep.conf` after it is written would leave a rejected file in place. **Recommendation:** render to `/etc/tmuxkeep/.tmuxkeep.conf.new`, check that file with the newly installed broker, and only then `mv` it over the old one. *Task 6.*

**Q8. Passing `--user` to the piped facts script (spec 7.3).** Line 2 re-runs the rest of stdin in a new `bash -s`, which drops the arguments. **Recommendation:** line 2 becomes `case "$0" in *vps-facts.sh) ;; *) tr -d '\r' | bash -s -- "$@"; exit $? ;; esac #`, and the operator runs `ssh tmuxkeep-admin 'bash -s -- --user <name>'`. *Task 4.*

**Q9. Profile snippet: "appends ... as today" (spec 6.3) vs `Set-TmuxkeepMarkedBlock` replacing `Add-SeshMarkedBlock`.** **Recommendation:** the profile uses the same write-or-replace function, so a changed snippet reaches the profile on the next deploy, matching the bash rc block. *Task 8.*

**Q10. How `KEY` and `ADMIN_KEY` appear in `~/.ssh/config`.** **Recommendation:** written as configured (the default `~/.ssh/...` form, which ssh expands on every platform), double-quoted when the path contains a space; a value with `"` is rejected by the parsers. `ssh-keygen` and file checks use the expanded path. *Tasks 7, 8, 12, 13.*

**Q11. `<pubkey>` in the admin help (spec 6.5) when the key does not exist yet.** **Recommendation:** substitute the first line of `<ADMIN_KEY>.pub` when it exists and is a plain `ssh-ed25519` line, else print `<contents of <ADMIN_KEY>.pub>`; `-Init`/`--init` also prints the steps when it finishes, since installing the admin key is the operator's next step. *Tasks 9, 14.*

**Q12. Test seams for the two main sequences.** **Recommendation:** `deploy.ps1` gains `-HomeDir` and `-ProfilePath` (defaults `$HOME`, `$PROFILE`) and its tests run it in a child `powershell.exe` with `.ps1` stubs first on `PATH` (verified while planning: a stub `ssh.ps1` on `PATH` shadows `ssh.exe` and its exit code reaches `$LASTEXITCODE`). `deploy.sh` tests run it from a temporary one-commit git copy of `laptop/` and `vps/`, because an agent worktree's `.git` file points at a Windows path that does not exist inside Docker. *Tasks 9, 14.*

**Q13. System accounts and a changed `USER` (Review Focus 1 and 5).** Neither is covered by the spec; `USER=root` would replace root's `AuthorizedKeysFile` and hand root's account the sudoers rules. **Recommendation:** the installer refuses an existing account with a uid outside 1000-59999 and a `USER` that differs from the installed `tmuxkeep.conf`, both before any change; the README's "Changing the VPS user" gives the manual steps. *Tasks 5, 19.*

**Q14. `HOST` written as `host:port` passes the spec's regex (Review Focus 2).** **Recommendation:** a `HOST` with exactly one `:` is rejected with `HOST: looks like host:port; put the port in PORT`; IPv6 literals have two or more. Both laptop parsers apply it; `deploy.conf` and the VPS config carry no `HOST`. *Tasks 7, 12.*

**Q15. The completion cache's age on bash 3.2 without discarding stderr (spec 6.4).** **Recommendation:** read the mtime with `stat -c %Y` on `Linux` and `stat -f %m` elsewhere, chosen by `uname -s`; a symlinked cache file, or one owned by another user, is neither read nor written (shared `/tmp`). *Task 11.*

**Q16. CI details (spec 9.6, 14).** **Recommendation:** the Windows job uses `shell: cmd` and calls `powershell.exe -NoProfile` explicitly (GitHub's `shell: powershell` does not pass `-NoProfile`) and bootstraps the NuGet provider before `Install-Module`; the macOS job puts `/bin` first on `PATH` so every `env bash` is 3.2, and sets `TK_EXPECT_BASH_MAJOR=3` so a wrong interpreter fails the run. Because CI first runs on GitHub, push the merged branch to a private scratch repository once before the history reset. *Task 18; "After the merge".*

**Q17. The public commit's author (spec 10.6).** The single squashed commit carries whatever `user.name` and `user.email` git is configured with. **Recommendation:** before that commit, decide whether to use the GitHub no-reply address for it, so a personal e-mail address is not published. Not a task.

**Q18. Message streams differ between the wrappers.** The PowerShell wrapper prints its local errors and the 255 hint with `Write-Host` (spec 6.2 says rename only); the bash wrapper prints them on stderr (spec 6.4). Exit codes are identical. **Recommendation:** leave both as specified. No task changes it.
