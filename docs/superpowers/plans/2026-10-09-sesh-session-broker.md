# sesh Session Broker Implementation Plan

> Historical design record for v1, which shipped under the name `sesh`. The tool is now
> `tmuxkeep`; paths, aliases and file names in this document are the v1 ones. Where
> this document and `README.md` differ, the README is right.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `sesh`, a forced-command broker on the VPS plus a Windows PowerShell 5.1 wrapper on the laptop, so Claude Code sessions in tmux can be created, listed, inspected, nudged, attached, renamed, locked, soft-deleted, restored and resumed from the laptop behind a TOTP lease, without Claude running as root.

**Architecture:** A single bash broker (`vps/sesh`) is the only program the `claude` user's session key may run. It decodes base64 arguments, validates them, applies a TOTP/lease gate to the verbs that change sessions, and drives one tmux server through a single exact-target helper, writing every action to an append-only JSON audit log. A root installer (`vps/sesh-setup`) provisions the user, sshd drop-in, sudoers, systemd reaper timer and audit log. The laptop side is a thin `sesh.ps1` wrapper with a tab completer, plus a `deploy.ps1` the operator runs over the separate passphrase-protected admin path.

**Tech Stack:** bash 5, tmux >= 3.0, oathtool, jq, util-linux (flock, script), systemd user units, OpenSSH sshd; Windows PowerShell 5.1, Windows OpenSSH 9.5; tests: bats 1.8 in Docker Desktop (`debian:bookworm`), Pester >= 5.5 under `powershell.exe`.

**Spec:** `docs/superpowers/specs/2026-10-09-sesh-session-broker-design.md` (frozen; the single source of truth). Section numbers below ("spec 6", "spec 7.1") refer to it.

**How much code this plan contains:** tests are given in full: they are the contract. Configuration files fixed by the spec are given verbatim. For product code, the plan gives exact interfaces, behaviour, messages and the load-bearing fragments where a trap lives; the implementer writes the rest.

---

## Questions for the orchestrator

The spec is frozen. Each item below is a gap, contradiction or unimplementable detail found while planning. Every affected task is written against the **recommended answer** so the plan is complete as it stands; if you decide otherwise, re-brief the named task.

**Q1. Root hardening is not sticky, so the first normal deploy after `-HardenRoot` would abort (spec 4.2, 9.3, 10).** Setup compares `sshd -T` for root before and after installing the drop-in and allows a `permitrootlogin` difference only when `--harden-root` is passed. After one hardened deploy, a plain deploy would re-install the commented line, root's effective `permitrootlogin` would change back, and setup would abort (or, if the check were loosened, silently undo hardening). Two related traps: (a) uncommenting the spec's line literally leaves `<- uncommented by setup --harden-root` on it, which sshd rejects as garbage; (b) sshd uses the first value it reads, so a drop-in sorting before `sesh.conf` (for example `50-cloud-init.conf` with `PermitRootLogin yes`) would make hardening a no-op that the diff check cannot see. **Recommendation:** hardening is sticky: setup hardens when `--harden-root` is given **or** the installed `/etc/ssh/sshd_config.d/sesh.conf` already has an uncommented `PermitRootLogin prohibit-password` line. Hardening replaces the whole commented line with exactly `PermitRootLogin prohibit-password`. After installing a hardened drop-in, setup also requires root's effective `permitrootlogin` to be `prohibit-password` or `without-password`, and otherwise aborts, restores, and says so. *Encoded in Task 11.*

**Q2. The spec's Task 0 command feeds the script to bash with CRLF line endings and, on this laptop, a UTF-8 BOM (spec 13).** Verified on this laptop's Windows PowerShell 5.1.26100 (console code page UTF-8): `Get-Content file | native.exe` sends `EF BB BF` then `\r\n` line endings, and `$OutputEncoding` is US-ASCII (non-ASCII becomes `?`). Run as-is, bash fails on every line with `$'\r': command not found`. **Recommendation:** keep the spec's operator command unchanged and make `vps/vps-facts.sh` tolerant. It must be ASCII only. Line 1 is the shebang, which absorbs a BOM; at worst bash prints one harmless "command not found" line on stderr. Line 2 re-executes the rest of stdin through `tr -d '\r'`. Its trailing ` #` turns the stray CR into a comment. *Encoded in Task 3 (with a Docker test that pipes BOM+CRLF) and O2.*

**Q3. Deploy cannot both re-run `ssh -o PasswordAuthentication=no vps true` (spec 4.5) and need the passphrase only twice (spec 9.3).** A separate check would be a third prompt. **Recommendation:** no separate check. Both `scp` and `ssh` to `vps` get `-o PreferredAuthentications=publickey`, so a missing admin key fails with 255 at the scp step instead of falling back to the root password. Deploy then prints the spec 4.5 instructions and stops. *Encoded in Task 14.*

**Q4. `--rotate-totp` and `--unlock-otp` are setup flags (spec 10) with no way to pass them from the laptop.** Deploy forwards only `--harden-root`. **Recommendation:** `deploy.ps1` gets `-RotateTotp` and `-UnlockOtp` switches passed straight through, and the README documents them as the recovery path. Both remain operator-only. *Encoded in Tasks 14 and 16.*

**Q5. `resume`'s recreate path bypasses the rules `new` enforces (spec 6).** When the session is missing but `/home/claude/work/<name>` exists, `resume` would recreate `<name>` even if a tombstone of `<name>` exists, or another session's `#{session_path}` is that directory. Both outcomes are things `new` refuses. **Recommendation:** in the recreate path, refuse (3) if a tombstone of `<name>` exists (`tombstone of <name> exists; use sesh restore <name>`) or another session already uses the directory. *Encoded in Task 9.*

**Q6. The facts script is "read-only" but must report "whether chattr works on /var/log" (spec 13).** That can only be proven by writing a file. **Recommendation:** stay strictly read-only. Report the filesystem type and mount options of `/var/log`, whether `chattr`/`lsattr` exist, and `lsattr -d /var/log`. Setup's preflight already performs the real `chattr +a` test before changing anything. *Encoded in Task 3.*

**Q7. The order of validation, gate and existence checks is unstated.** **Recommendation:** for every verb, in this order: (1) parse and validate arguments → 2; (2) for gated verbs, the gate → 3/4; (3) existence and state checks → 3/5; (4) for `go` only, the TTY check → 4; (5) act. A typo therefore never costs a TOTP prompt, and an attacker without a code learns nothing from existence errors that `ls` would not already show. *Encoded in Tasks 4-9.*

**Q8. Behaviour when the audit log cannot be written, or `totp.secret` is missing, is unstated.** **Recommendation:** fail closed. After decoding the verb, and before acting, the broker opens the audit file for append. If that fails it prints `sesh: audit log not writable` and exits 1 without acting; `ls --names` and `ls --tombstones` are exempt because they are never audited. A missing or unreadable `totp.secret` exits 1 with `TOTP not configured; run sesh-setup`, and is not counted as an OTP failure. *Encoded in Tasks 4 and 6.*

**Q9. "Replacing any line whose comment matches the same key id" (spec 4.4) is ambiguous.** The key's comment is `sesh-laptop` while the key id is `laptop`. **Recommendation:** setup identifies existing lines by the option text `command="/usr/local/bin/sesh --key <id>"`. It always writes the comment as `sesh-<id>`, whatever comment the `.pub` file carried. *Encoded in Task 11.*

**Q10. Setup's preflight runs `chattr` (spec 10) before step 1 installs `e2fsprogs`.** **Recommendation:** if `chattr` is missing at preflight, fail with `chattr missing: apt-get install e2fsprogs, then re-run`. `e2fsprogs` is Priority: required on Debian and Ubuntu, so this should never fire. *Encoded in Task 11.*

**Q11. Remote-only behaviour cannot be tested with the `SESH_*` hooks.** The hooks are ignored on remote calls, and `ip` is `-` on local calls (spec 5.1, 7.3, 12.1), yet spec 12.1 requires tests of b64-versus-plain parity, `reap` over SSH, and leases per IP. **Recommendation:** no spec change. Bats "remote mode" tests set `SSH_ORIGINAL_COMMAND`/`SSH_CLIENT` and run against the broker's real default paths (`/home/claude/.sesh`, `/var/log/sesh/audit.log`, `/home/claude/work`) inside the disposable container. `XDG_RUNTIME_DIR` is set per test for the socket. *Encoded in Tasks 2, 4, 6, 9.*

**Q12. The `b64` form is defined only for `SSH_ORIGINAL_COMMAND` (spec 5.2).** **Recommendation:** decoding applies to the argument list whatever its source, so a local `sesh --key t b64 ...` also decodes. There is no security impact, and it lets local tests send arbitrary bytes. *Encoded in Task 4.*

**Q13. The spec names only `sesh-names.txt` for the completer cache, and says the completer runs `sesh ls --names` (spec 9.2).** **Recommendations:** (a) tombstones get their own cache file, `$env:TEMP\sesh-tombstones.txt`, with the same 60-second rules; (b) the completer calls `ssh -o BatchMode=yes -o ConnectTimeout=5 sesh ls --names` (plain form) directly, with stderr discarded inside try/catch. Going through `sesh.ps1` would print the 255 hint into the prompt, because the wrapper must never redirect stderr. (c) The snippet defines its two functions with the `global:` scope prefix, so they behave the same when dot-sourced by a profile or by a Pester test. *Encoded in Task 13.*

**Q14. The test image needs more than spec 12.1's list (tmux, bats, oathtool, jq, util-linux, git).** **Recommendation:** add, as test-only tools, `openssh-server` (to validate the drop-in and setup's `sshd -T` logic against real sshd), `sudo` (for `visudo -cf`), `shellcheck`, `procps`, `bsdutils` (`script`) and `ca-certificates`, and create a `claude` user in the image. Nothing ships to the VPS. *Encoded in Task 1.*

**Q15. Small outputs and log details are unspecified. Recommended values, used consistently by the tests:**
- `ls` with no sessions prints only the header row.
- `send` prints `sent <bytes> bytes to <name>`.
- `auth` prints `authenticated; lease valid for 30m`.
- `rename` prints `renamed <old> to <new>`.
- `lock` and `unlock` print `locked <name>` and `unlocked <name>`.
- `rm --now` prints `killed <session>`.
- `reap` prints `reaped <tombstone>` for each kill and writes no audit line when nothing is reaped, which avoids 24 empty lines a day.
- `reap` exits 1 if any kill failed, after attempting all of them.
- `log -n` uses the same `^[0-9]{1,4}$` rule as `peek -n`.
- `log` prints first, then audits itself.

Audit `detail` vocabulary:
- `new`: `created dir=<dir>`, plus ` repo=<redacted url>` when a repo was given.
- `send`: `len:<bytes>`.
- `rm`: `tombstoned`.
- `rm --now`: `killed <session>`.
- `restore`: `restored from <tombstone>`.
- `resume`: `resumed` or `recreated`.
- `auth`: `authenticated`.
- `go`: `attached`.
- `reap`: `reaped`.
- `ls`: `listed`.
- `peek` and `log`: `lines=<N>`.
- Gate failures: `otp-fail`, `cooldown`, `otp-locked`, `no-tty`.
- Any other failure: its stderr message without the `sesh: ` prefix.

*Encoded throughout.*

**Q16. Three small interpretations in the broker.**
- (a) Spec 5.1 says the SSH-variable scrub applies "before starting a tmux server". The plan routes *every* tmux call through the same `env -u ... LANG=C.UTF-8` wrapper, which costs nothing and leaves no path that forgets it.
- (b) `-f /etc/sesh/tmux.conf` is passed only when that file is readable, so the Docker tests run without it, and one test installs it to prove it is applied.
- (c) The broker exports `LC_ALL=C.UTF-8` so name regexes compare ASCII codepoints and the 40-column title cut counts characters. Byte counts for `send` use `wc -c`.

*Encoded in Tasks 4, 5, 7.*

**Q17. Smoke "send a harmless line" (spec 12.3).** The pane runs Claude Code, so any ordinary text becomes a model prompt. **Recommendation:** send `/help`. If the folder-trust dialog is showing instead, the keys are ignored and Enter accepts trust for a throwaway directory that the smoke test deletes. *Encoded in Task 15.*

**Q18. The spec 4.5 admin-key command has the same PowerShell piping hazard as Q2.** `Get-Content key.pub | ssh vps '... cat >> ~/.ssh/authorized_keys ...'` sends a trailing CR and, when the console code page is UTF-8 (as in this session), a leading BOM. A BOM before `ssh-ed25519` makes sshd ignore the line, so the admin key silently fails and O1's check (`ssh -o PasswordAuthentication=no vps true`) fails. **Recommendation:** O1 gives the operator a pipe-free variant that keeps the spec's single root-password login and newline guard, but passes the key text inside the remote command. `$k` is its only PowerShell expansion. O1 also says how to repair the file if the spec's form was already used. *Encoded in O1.*

### Risks noted while planning (no plan change; worth a look before implementation)

- **R1. The sudoers allowlist is root-equivalent in practice**, like `docker` (D4). `systemctl status *` and `journalctl *` open `less` as root, from which `!sh` gives a root shell, and `apt-get install *` accepts `-o` hook options. Threat 2 is therefore reduced only nominally while these rules exist. The plan has the README state this plainly (Task 16). Tightening it (for example the sudoers `NOEXEC:` tag, or dropping `status`/`journalctl`) would be a spec change.
- **R2. The gate holds `gate.lock` for up to `OTP_READ_TIMEOUT` (60 s)** while a code is being typed, so a second gated call waits behind it. That is fine for one operator.
- **R3. Pester mocking of native `ssh` inside a script invoked with `&`** is relied on (Pester 5 supports mocking external commands). Every Pester file puts fake `ssh`/`scp`/`ssh-keygen` `.cmd` files first on `PATH`, so a mock miss can never reach the VPS. If mocking does not work, the implementer stops and reports.
- **R4. The most likely flaky test is `go attaches ... (-d)`** (Task 7), which drives tmux clients through `script(1)` in Docker. The brief says to report rather than weaken it.
- **R5. Sessions survive SSH logout only because `KillUserProcesses` is not `yes` and linger is on.** The tmux server is started from the SSH session's scope. Setup re-checks logind on every deploy, but a later OS change to logind would kill sessions at logout.
- **R6. `systemctl --user -M claude@` needs systemd >= 248.** GATE G1 checks this and names the fallback.

---

## Global Constraints

Every task's requirements implicitly include this section. Values are copied from the spec.

- **Agents never touch the VPS.** No `ssh`/`scp` to `vps`, `sesh` or `203.0.113.10`; never run `laptop/deploy.ps1`, `tests/smoke.ps1`, or `vps/sesh-setup` (bats tests may only `source` it); never depend on `docs/vps-facts.md` (it will not exist while you work); never read the TOTP secret or any deploy output. Agents verify only with the Docker bats suite and the Pester suite (spec 16).
- **Line endings:** `.gitattributes` forces LF for `vps/**` and `tests/**`. The laptop's git has `core.autocrlf=true`, so a file written with CRLF stays CRLF in the working tree that Docker mounts. Before calling any task done, run `grep -rlIU "$(printf '\r')" vps tests` in Git Bash; it must print nothing. **The `-U` is required**: Git for Windows' grep strips CR at end of line unless given `-U`, so without it the check silently passes. Also do not rely on `$'\r'` in the Bash tool (verified unreliable there). Inside bats tests, which run in Linux, `$'\r'` is fine. Fix offenders with `sed -i 's/\r$//' <file>` (verified to work in Git Bash).
- **Executable bits:** the laptop's git has `core.fileMode=false`; record exec bits with `git add --chmod=+x` for `vps/sesh`, `vps/sesh-setup`, `vps/vps-facts.sh`, `tests/bats/stubs/oathtool`.
- **Broker constants (spec 7), defined once at the top of `vps/sesh`:** `LEASE_SECS=1800`, `TOMBSTONE_TTL=86400`, `OTP_STEP=30`, `OTP_FAIL_MAX=3`, `OTP_FAIL_WINDOW=600`, `OTP_COOLDOWN=300`, `OTP_HARD_MAX=10`, `OTP_READ_TIMEOUT=60`, `SEND_ENTER_DELAY=0.3`, `SEND_MAX_BYTES=8000`, and exactly this one line: `GATED_VERBS="new go send rename unlock rm resume auth"`.
- **Version line:** `vps/sesh` contains exactly one line `SESH_VERSION=dev`, which `deploy.ps1` rewrites.
- **Names (spec 5.3):** `^[a-z][a-z0-9_-]{0,31}$`. Tombstones are `zz~<name>~<epoch>`, and only `peek` and `rm --now` accept them as input. Reaper regex: `^zz~[a-z][a-z0-9_-]*~([0-9]+)$`. Key ids: `^[a-z][a-z0-9_-]{0,15}$`.
- **Exact targeting (spec 5.3):** every tmux call that takes a target goes through one helper passing `-t "=$name:"`. Existence is checked only by exact string comparison against `tmux list-sessions -F '#{session_name}'`; `has-session` is never used.
- **Exit codes (spec 5.4):** 0 success; 2 usage; 3 refused; 4 auth; 5 not found; 1 anything else. Every failure writes one stderr line `sesh: <message>` and one audit line before exiting.
- **Audit (spec 7.3):** one JSON object per line via `jq -cn`, keys `ts,key,ip,verb,session,ok,detail`; `ts` is UTC `YYYY-MM-DDTHH:MM:SSZ`, `key` is the `--key` id or `local`, `ip` is the first field of `SSH_CLIENT` on remote calls and `-` on local calls. `send` logs `len:<bytes>`, never text; repo URL credentials redacted; `ls --names`/`--tombstones` not logged.
- **Paths (spec 4, 7, 8):** state `/home/claude/.sesh` (0700), audit `/var/log/sesh/audit.log`, work `/home/claude/work`, socket `$XDG_RUNTIME_DIR/sesh.sock` else `/run/user/<uid>/sesh.sock`, tmux config `/etc/sesh/tmux.conf`, broker `/usr/local/bin/sesh`.
- **Test hooks (spec 12.1), honoured only on local calls:** `SESH_HOME`, `SESH_AUDIT`, `SESH_WORK`, `SESH_TMUX_SOCKET`, `SESH_NOW`, `SESH_OATHTOOL`. The broker does not reset `PATH`.
- **Windows PowerShell 5.1 only** (`powershell.exe`, not `pwsh`). Every `.ps1` file is ASCII only (5.1 reads BOM-less UTF-8 as ANSI). `laptop/sesh.ps1` has no `param()` block and no `[CmdletBinding()]`.
- **Never write files from PowerShell 5.1 with `>`, `Tee-Object`, or `Out-File`/`Set-Content` without an explicit encoding**: they produce UTF-16 or ANSI. Use `Add-Content -Encoding ascii` (spec-mandated for the profile and ssh config) or `[IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding $false))`. Use `-LiteralPath` for any path that could contain spaces or brackets.
- **Never redirect a native command's stderr** in `sesh.ps1`, `deploy.ps1` or `smoke.ps1` (5.1 wraps each line in an error record). The completer is the one exception (Q13).
- **Tests:** bats in Docker via `tests/run-bats.ps1`; Pester >= 5.5 under `powershell.exe`. Installing Pester to CurrentUser scope is an allowed agent action.
- **Model per task** follows the CLAUDE.md roles table: Sonnet for anything with logic or judgment, Haiku only for verbatim/mechanical work. If a Haiku task's verification fails, Haiku stops and reports the output; it does not improvise fixes.
- **Stop and report** (do not guess) on any design question, ambiguity, missing tool, or a test you cannot make pass without weakening it.

## Review Focus

These are the inputs and conditions the spec implies but does not test, most likely first. Each has a test added to the owning task.

1. **Pane titles carrying terminal escape sequences reach the operator's terminal through `sesh ls`.** Claude Code sets the pane title from task text, which can echo repo content. `ls` must strip C0 control characters and DEL from TITLE. *Test in Task 5.*
2. **Text that tmux could read as a flag or key name** (`-l`, `C-c`, `Enter`, text beginning with `-`). `send` must type it literally. *Test in Task 7.*
3. **Multi-byte UTF-8 text near the 8000-byte limit.** `send` must count bytes, not characters: 4000 x `é` (8000 bytes) passes, and 4001 fails. *Test in Task 7.*
4. **A stale socket after the tmux server dies** (OOM kill, crash). `ls` must report an empty list, and `new` must start a fresh server rather than fail. *Test in Task 7.*
5. **Profile paths with spaces.** The real `$PROFILE` on this laptop is `C:\Users\<you>\Cloud Drive\My Docs\Docs\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`. Deploy's profile append and staging must work with spaces, and must refuse a UTF-16 file rather than corrupt it. *Test in Task 14.*

---

## Execution notes

- **Roles.** The orchestrator (Fable) briefs each task to a fresh subagent with the model named in the task header and reviews the diff. CLAUDE.md says to prefer Opus for reviews, especially Tasks 6, 11 and 14. OPERATOR steps are performed by the human; the orchestrator only tells the human when they are unblocked. GATE G1 is the orchestrator's own review.
- **Working directory.** Every command below assumes the current directory is the repo root (`C:\Users\<you>\Code\sesh`, or the worktree you were given). Bats commands run from Git Bash or PowerShell. Pester commands run from the PowerShell tool and start a clean `powershell.exe -NoProfile`.
- **Bats command (used in many tasks):** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/<file>.bats`. With no `-Path` it runs the whole `tests/bats` directory. Bats prints `N tests, 0 failures` on success. The first run builds the image (1-3 minutes).
- **Pester command (used in Tasks 12-15):**

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command {
    Set-Location 'C:\Users\<you>\Code\sesh'   # or your worktree
    Import-Module Pester -MinimumVersion 5.5
    $c = New-PesterConfiguration
    $c.Run.Path = 'tests\pester\<file>.Tests.ps1'
    $c.Run.Exit = $true
    $c.Output.Verbosity = 'Detailed'
    Invoke-Pester -Configuration $c
  }
  ```

  Success ends with `Tests Passed: N, Failed: 0`.
- **Commits.** One commit per task, on the branch you were given, with the subject shown in the task. End every commit message with the attribution trailer your harness specifies. Never push.

## File map

| Path | Responsibility | Task |
|---|---|---|
| `.gitattributes` | LF for `vps/**`, `tests/**` | 1 |
| `tests/docker/Dockerfile` | bookworm test image | 1 |
| `tests/run-bats.ps1` | build image, run bats with repo mounted read-only | 2 |
| `tests/bats/helpers.bash` | shared bats helpers (local and remote mode) | 2 |
| `tests/bats/stubs/oathtool` | deterministic TOTP stub | 2 |
| `tests/bats/00-env.bats` | image and repo sanity | 2 |
| `vps/vps-facts.sh`, `tests/bats/facts.bats` | read-only Task 0 facts | 3 |
| `vps/sesh` | the broker | 4-9 |
| `tests/bats/broker-core.bats`, `broker-remote.bats`, `lint.bats` | invocation, decoding, audit, `log` | 4 (+6, 9) |
| `tests/bats/broker-read.bats` | tmux layer, `ls`, `peek`, `lock` | 5 |
| `tests/bats/broker-gate.bats` | TOTP gate, lease, `auth`, `unlock` | 6 |
| `tests/bats/broker-new-send-go.bats` | `new`, `send`, `go` | 7 |
| `tests/bats/broker-lifecycle.bats` | `rename`, `rm`, `restore` | 8 |
| `tests/bats/broker-resume-reap.bats`, `broker-exact.bats` | `resume`, `reap`, cross-verb sweeps | 9 |
| `vps/tmux.conf`, `vps/sshd-sesh.conf`, `vps/sudoers-claude`, `vps/systemd/*`, `tests/bats/config.bats` | VPS config files | 10 |
| `vps/sesh-setup`, `tests/bats/setup.bats` | root installer | 11 |
| `laptop/sesh.ps1`, `tests/pester/sesh.Tests.ps1`, `tests/pester/static.Tests.ps1` | wrapper | 12 |
| `laptop/profile-snippet.ps1`, `tests/pester/completer.Tests.ps1` | profile function and completer | 13 |
| `laptop/deploy.ps1`, `tests/pester/deploy.Tests.ps1` | operator deploy | 14 |
| `tests/smoke.ps1`, `tests/pester/smoke.Tests.ps1` | operator end-to-end smoke | 15 |
| `README.md` | usage, quoting, migration, risks, rotation, development | 16 |
| `docs/vps-facts.md` | Task 0 output (operator) | O2 |

## Task overview

| # | Task | Model | Depends on |
|---|---|---|---|
| 1 | Scaffolding: `.gitattributes`, Dockerfile | Haiku | none |
| 2 | Bats harness: `run-bats.ps1`, helpers, stub, env tests | Sonnet | 1 |
| 3 | `vps-facts.sh` (Task 0 script) | Sonnet | 2 |
| O1 | OPERATOR: admin key (spec 4.5) | human | none (before O3) |
| O2 | OPERATOR: run Task 0 facts, commit `docs/vps-facts.md` | human | 3 |
| G1 | GATE: orchestrator reviews facts against spec 14 | orchestrator | O2 (before O3) |
| 4 | Broker core: invocation, decoding, audit, exit codes, `log` | Sonnet | 2 |
| 5 | Broker tmux layer, names, `ls`, `peek`, `lock` | Sonnet | 4 |
| 6 | Broker TOTP gate, lease, `auth`, `unlock` | Sonnet | 5 |
| 7 | Broker `new`, `send`, `go` | Sonnet | 6 |
| 8 | Broker `rename`, `rm`, `restore` | Sonnet | 7 |
| 9 | Broker `resume`, `reap`, cross-verb sweeps | Sonnet | 8 |
| 10 | VPS config files (verbatim) + config tests | Haiku | 7 |
| 11 | `sesh-setup` | Sonnet | 10 |
| 12 | `sesh.ps1` wrapper + Pester | Sonnet | 4 |
| 13 | Profile snippet + completer | Sonnet | 12 |
| 14 | `deploy.ps1` | Sonnet | 11, 13 |
| 15 | `smoke.ps1` | Sonnet | 12 |
| 16 | README | Sonnet | 14, 15 |
| 17 | Full-suite verification report | Haiku | 16 |
| O3-O7 | OPERATOR: first deploy, Claude login, migration, smoke, `-HardenRoot` | human | 17, O1, G1 |

Tasks 12-13 touch only `laptop/` and `tests/pester/` and may run in parallel with Tasks 5-9 if the orchestrator wants a second lane. Everything else is sequential.

---

### Task 1: Scaffolding: `.gitattributes` and the test image

**Model:** Haiku (verbatim files, mechanical verification). **Depends on:** nothing.

**Files:**
- Create: `.gitattributes`
- Create: `tests/docker/Dockerfile`

**Interfaces:**
- Produces: image tag `sesh-bats:latest`, built from `tests/docker/`; the repo is mounted read-only at `/src` by Task 2's runner. The image contains user `claude` (home `/home/claude`), and directories `/var/log/sesh`, `/etc/sesh`, `/run/sshd`, with sshd host keys generated.

- [ ] **Step 1: Environment preflight (first verification step of the whole plan)**

Run (PowerShell or Git Bash):

```
docker info --format '{{.ServerVersion}}'
git config --get core.autocrlf
```

Expected: a version string such as `27.3.1`, then `true`.
If `docker info` fails or prints an error about the daemon, **stop and report `BLOCKED: Docker Desktop is not running or not installed`**. Do not try to install or start anything, and do not continue to later steps.

- [ ] **Step 2: Create `.gitattributes` with exactly this content**

```
# Force LF for everything that runs on Linux or in the Docker test image (spec 15).
vps/** text eol=lf
tests/** text eol=lf
```

- [ ] **Step 3: Verify the attribute applies (paths need not exist yet)**

Run: `git check-attr text eol -- vps/sesh tests/run-bats.ps1`
Expected:

```
vps/sesh: text: set
vps/sesh: eol: lf
tests/run-bats.ps1: text: set
tests/run-bats.ps1: eol: lf
```

- [ ] **Step 4: Create `tests/docker/Dockerfile` with exactly this content**

```dockerfile
# Test image for the sesh broker and VPS scripts. Built and run by tests/run-bats.ps1.
# Spec 12.1 lists tmux, bats, oathtool, jq, util-linux and git. openssh-server, sudo,
# shellcheck, procps, bsdutils and ca-certificates are test-only additions (plan Q14).
FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bats tmux oathtool jq util-linux bsdutils git ca-certificates \
      openssh-server sudo shellcheck procps \
 && rm -rf /var/lib/apt/lists/*

# A claude user and the broker's default directories, for remote-mode tests that run
# against the real default paths inside this disposable container (plan Q11).
RUN useradd -m -s /bin/bash claude \
 && mkdir -p /var/log/sesh /etc/sesh /run/sshd \
 && ssh-keygen -A

WORKDIR /src
CMD ["bats", "/src/tests/bats"]
```

- [ ] **Step 5: Check for carriage returns**

Run in Git Bash: `grep -lU "$(printf '\r')" tests/docker/Dockerfile .gitattributes`
Expected: no output. (`-U` is required; Git for Windows' grep otherwise strips CRs before matching.) If a file is listed, run `sed -i 's/\r$//' <file>` and re-check.

- [ ] **Step 6: Build and probe the image**

Run:

```
docker build -t sesh-bats:latest tests/docker
docker run --rm sesh-bats:latest bash -c "bats --version; tmux -V; oathtool --version | head -n 1; shellcheck --version | sed -n 2p; id claude"
```

Expected: the build succeeds. The probe prints a `Bats 1.8.x` line, `tmux 3.3a`, an `oathtool (OATH Toolkit) 2.6.x` line, a `version: 0.9.x` line, and a `uid=1000(claude) ...` line. If the build fails, stop and report the full output.

- [ ] **Step 7: Commit**

```
git add .gitattributes tests/docker/Dockerfile
git commit -m "Add .gitattributes (LF for vps/ and tests/) and bats test image"
```

---

### Task 2: Bats harness: runner, shared helpers, oathtool stub, environment tests

**Model:** Sonnet. **Depends on:** Task 1.

**Files:**
- Create: `tests/run-bats.ps1`
- Create: `tests/bats/helpers.bash`
- Create: `tests/bats/stubs/oathtool` (executable)
- Create: `tests/bats/00-env.bats`

**Interfaces:**
- Consumes: image `sesh-bats:latest` built from `tests/docker` (Task 1).
- Produces, for every later bats file (`load helpers` at the top):
  - Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 [-Path <repo-relative file or dir>] [-Filter <regex>]`. The exit code is bats' own; it is 2 when Docker is unavailable or the path does not exist.
  - Constants: `SESH_BIN=/src/vps/sesh`; `FIXED_NOW=1790000000`, which is TOTP step `59666666`, for which the stub's code is `666666`.
  - Local mode, with `SESH_*` overrides honoured: `setup_local`, `teardown_local`, `sesh ARGS...` (runs `bash $SESH_BIN --key t ARGS...` with stdin from `/dev/null`), `sesh_key KEY ARGS...`, `sesh_nokey ARGS...`.
  - Direct tmux on the test socket: `tm ARGS...`, `mk_session NAME [DIR]`, `mk_session_cmd NAME CMD`, `session_names`, `locked_flag NAME`.
  - Gate fixtures: `mk_lease KEY IP [EPOCH]`, `now_step`, `code_for_step STEP`, and `with_tty INPUT ARGS...`. The last runs the broker under a pseudo-terminal created by `script(1)`, typing INPUT at the prompt; its output contains CRs.
  - Audit: `audit_last`, `audit_field FIELD`, `audit_count`.
  - Polling: `wait_for_pane_line NAME TEXT [SECS]`, `wait_for_pane_contains NAME TEXT [SECS]`, `wait_for_cmd NAME CMD [SECS]`, `wait_for_clients NAME N [SECS]`, `_poll SECS CMD...`.
  - Misc: `strip_cr`, `b64 STRING`, `b64cmd WORDS...` (prints `b64 <tok> <tok>...`).
  - Remote mode, which uses the broker's real default paths (plan Q11): `setup_remote`, `teardown_remote`, `rtm ARGS...`, `remote IP KEY "COMMAND STRING"`, `remote_audit_last`.
  - Stub `tests/bats/stubs/oathtool`. It accepts `--totp -b -N @<epoch> -` with the key on stdin, prints `printf %06d $(( (epoch/30) % 1000000 ))`, and appends its argv (never stdin) to `$OATH_STUB_LOG`.

- [ ] **Step 1: Write `tests/run-bats.ps1`**

This file lives under `tests/`, so it must have LF endings and ASCII only. Do not redirect native stderr, and keep the `param()` block (this is not the wrapper).

```powershell
# run-bats.ps1 - build the sesh test image and run bats in Docker Desktop.
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 [-Path tests/bats/x.bats] [-Filter regex]
# Exit code: bats' exit code; 2 if Docker is unavailable, the path is wrong, or the build fails.
param(
    [string]$Path = 'tests/bats',
    [string]$Filter = ''
)

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$image = 'sesh-bats:latest'

& docker info --format '{{.ServerVersion}}' | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'run-bats: Docker is not available. Start Docker Desktop and retry.'
    exit 2
}

$rel = ($Path -replace '\\', '/') -replace '^\./', ''
if (-not (Test-Path -LiteralPath (Join-Path $repo $rel))) {
    Write-Host "run-bats: no such path in the repo: $rel"
    exit 2
}

& docker build --quiet --tag $image (Join-Path $repo 'tests/docker') | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'run-bats: docker build failed'; exit 2 }

$bats = @('bats')
if ($Filter) { $bats += @('--filter', $Filter) }
$bats += "/src/$rel"

# --mount (not -v) so the drive-letter colon in the Windows path is not misparsed.
& docker run --rm --mount "type=bind,source=$repo,target=/src,readonly" $image @bats
exit $LASTEXITCODE
```

- [ ] **Step 2: Write `tests/bats/stubs/oathtool` exactly**

```bash
#!/bin/bash
# Test stub for oathtool, used through SESH_OATHTOOL. Deterministic: the code for
# "-N @E" is (E / 30) mod 1000000, zero-padded to six digits. It logs its argv
# (never stdin) to $OATH_STUB_LOG so tests can prove the secret is not on argv.
printf '%s\n' "$*" >> "${OATH_STUB_LOG:-/dev/null}"
secret=$(cat)
[ -n "$secret" ] || { echo 'oathtool stub: empty key on stdin' >&2; exit 1; }
[ "${!#}" = - ] || { echo 'oathtool stub: last argument must be -' >&2; exit 1; }
epoch=
while [ $# -gt 0 ]; do
  case $1 in
    -N) epoch=${2#@}; shift 2 ;;
    *) shift ;;
  esac
done
case $epoch in ''|*[!0-9]*) echo 'oathtool stub: need -N @<epoch>' >&2; exit 1 ;; esac
printf '%06d\n' $(( (epoch / 30) % 1000000 ))
```

- [ ] **Step 3: Write `tests/bats/helpers.bash` exactly**

```bash
# tests/bats/helpers.bash: shared helpers for every bats file. Load with: load helpers
# The repo is mounted read-only at /src. Write only under $BATS_TEST_TMPDIR or the
# container paths /home/claude, /var/log/sesh, /etc/sesh and /etc/ssh.
# Do not run bats with --jobs: remote-mode tests share the real default paths.
bats_require_minimum_version 1.5.0

SESH_BIN=/src/vps/sesh
FIXED_NOW=1790000000   # TOTP step 59666666; the stub's code for that step is 666666

# ---- local mode: SESH_* overrides are honoured ----
setup_local() {
  export SESH_HOME="$BATS_TEST_TMPDIR/home/.sesh"
  export SESH_AUDIT="$BATS_TEST_TMPDIR/audit.log"
  export SESH_WORK="$BATS_TEST_TMPDIR/work"
  export SESH_TMUX_SOCKET="$BATS_TEST_TMPDIR/tmux.sock"
  export SESH_NOW="$FIXED_NOW"
  export OATH_STUB_LOG="$BATS_TEST_TMPDIR/oathtool.args"
  mkdir -p "$SESH_HOME/leases" "$SESH_WORK"
  chmod 700 "$SESH_HOME"
  printf 'JBSWY3DPEHPK3PXP\n' > "$SESH_HOME/totp.secret"
  printf '0\n' > "$SESH_HOME/last-otp"
  : > "$SESH_AUDIT"
  install -m 0755 /src/tests/bats/stubs/oathtool "$BATS_TEST_TMPDIR/oathtool"
  export SESH_OATHTOOL="$BATS_TEST_TMPDIR/oathtool"
  export SHELL=/bin/bash TERM=xterm-256color
  unset SSH_ORIGINAL_COMMAND SSH_CLIENT SSH_CONNECTION SSH_TTY TMUX XDG_RUNTIME_DIR
}
teardown_local() {
  [ -n "${SESH_TMUX_SOCKET:-}" ] && tmux -S "$SESH_TMUX_SOCKET" kill-server 2>/dev/null
  return 0
}

sesh()       { bash "$SESH_BIN" --key t "$@" </dev/null; }
sesh_key()   { local k=$1; shift; bash "$SESH_BIN" --key "$k" "$@" </dev/null; }
sesh_nokey() { bash "$SESH_BIN" "$@" </dev/null; }

tm()             { tmux -S "$SESH_TMUX_SOCKET" "$@"; }
mk_session()     { tm new-session -d -s "$1" -c "${2:-/tmp}"; }
mk_session_cmd() { tm new-session -d -s "$1" -c /tmp "$2"; }
session_names()  { tm list-sessions -F '#{session_name}' 2>/dev/null; }
locked_flag()    { tm display-message -p -t "=$1:" '#{@sesh_locked}'; }

mk_lease()      { printf '%s\n' "${3:-$SESH_NOW}" > "$SESH_HOME/leases/$1@$2"; }
now_step()      { echo $(( SESH_NOW / 30 )); }
code_for_step() { printf '%06d' $(( $1 % 1000000 )); }

audit_last()  { tail -n 1 "$SESH_AUDIT"; }
audit_field() { audit_last | jq -r ".$1"; }
audit_count() { wc -l < "$SESH_AUDIT"; }

strip_cr() { printf '%s' "$1" | tr -d '\r'; }
b64()      { printf '%s' "$1" | base64 -w0; }
b64cmd()   { local out=b64 a; for a in "$@"; do out+=" $(b64 "$a")"; done; printf '%s' "$out"; }

# Run the broker on a pseudo-terminal; INPUT is typed at the TOTP prompt. The sleep keeps
# the pty open until the broker has read its line. Output contains \r: use strip_cr.
with_tty() {
  local input=$1; shift
  local cmd
  printf -v cmd '%q ' bash "$SESH_BIN" "$@"
  { printf '%s\n' "$input"; sleep 1; } | script -qec "$cmd" /dev/null
}

_poll() { # _poll SECONDS COMMAND...: retry every 0.1s until COMMAND succeeds
  local deadline=$(( $(date +%s) + $1 )); shift
  until "$@"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}
_pane_has_line() { tm capture-pane -p -J -S - -t "=$1:" | grep -qxF -- "$2"; }
_pane_contains() { tm capture-pane -p -J -S - -t "=$1:" | grep -qF -- "$2"; }
_pane_cmd_is()   { [ "$(tm display-message -p -t "=$1:" '#{pane_current_command}')" = "$2" ]; }
_clients_are()   { [ "$(tm list-clients -t "=$1:" 2>/dev/null | wc -l)" -eq "$2" ]; }
wait_for_pane_line()     { _poll "${3:-5}" _pane_has_line "$1" "$2"; }
wait_for_pane_contains() { _poll "${3:-5}" _pane_contains "$1" "$2"; }
wait_for_cmd()           { _poll "${3:-5}" _pane_cmd_is "$1" "$2"; }
wait_for_clients()       { _poll "${3:-5}" _clients_are "$1" "$2"; }

# ---- remote mode: SESH_* overrides are ignored, so these use the real default paths ----
setup_remote() {
  unset SESH_HOME SESH_AUDIT SESH_WORK SESH_TMUX_SOCKET SESH_NOW SESH_OATHTOOL
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
  rm -rf /home/claude/.sesh /home/claude/work
  mkdir -p /home/claude/.sesh/leases /home/claude/work /var/log/sesh
  chmod 700 /home/claude/.sesh
  printf 'JBSWY3DPEHPK3PXP\n' > /home/claude/.sesh/totp.secret
  printf '0\n' > /home/claude/.sesh/last-otp
  : > /var/log/sesh/audit.log
  export SHELL=/bin/bash TERM=xterm-256color
  unset SSH_ORIGINAL_COMMAND SSH_CLIENT SSH_CONNECTION SSH_TTY TMUX
}
teardown_remote() {
  tmux -S "$XDG_RUNTIME_DIR/sesh.sock" kill-server 2>/dev/null
  return 0
}
rtm() { tmux -S "$XDG_RUNTIME_DIR/sesh.sock" "$@"; }
# remote IP KEY "COMMAND STRING": what sshd does for the forced command
remote() {
  SSH_ORIGINAL_COMMAND="$3" SSH_CLIENT="$1 50000 22" SSH_CONNECTION="$1 50000 172.17.0.2 22" \
    bash "$SESH_BIN" --key "$2" </dev/null
}
remote_audit_last() { tail -n 1 /var/log/sesh/audit.log; }
```

- [ ] **Step 4: Write `tests/bats/00-env.bats` exactly**

```bash
#!/usr/bin/env bats
# Sanity checks for the test image and the mounted repo.
load helpers

@test "required tools are present" {
  local t
  for t in bash tmux bats oathtool jq script flock base64 base32 git visudo shellcheck timeout; do
    command -v "$t" >/dev/null || { echo "missing: $t"; return 1; }
  done
  [ -x /usr/sbin/sshd ]
}

@test "tmux is 3.0 or newer" {
  run tmux -V
  [ "$status" -eq 0 ]
  local v=${output#tmux }
  [ "${v%%.*}" -ge 3 ]
}

@test "repo is mounted read-only at /src" {
  [ -f /src/tests/bats/helpers.bash ]
  run touch /src/.write-probe
  [ "$status" -ne 0 ]
}

@test "real oathtool accepts - to read the key from stdin (spec 14)" {
  local a b
  a=$(printf 'JBSWY3DPEHPK3PXP' | oathtool --totp -b -N @0 -)
  b=$(oathtool --totp -b -N @0 JBSWY3DPEHPK3PXP)
  [ "$a" = "$b" ]
  [[ "$a" =~ ^[0-9]{6}$ ]]
}

@test "oathtool stub is deterministic and logs argv only" {
  setup_local
  run bash -c "printf secret | '$SESH_OATHTOOL' --totp -b -N @$(( 59666666 * 30 )) -"
  [ "$status" -eq 0 ]
  [ "$output" = 666666 ]
  run grep -c secret "$OATH_STUB_LOG"
  [ "$output" = 0 ]
}

@test "script(1) gives the child a terminal" {
  run script -qec 'test -t 0 && echo tty' /dev/null
  [ "$status" -eq 0 ]
  [[ "$(strip_cr "$output")" == *tty* ]]
}

@test "no carriage returns under vps/ or tests/" {
  local dirs=(/src/tests)
  [ -d /src/vps ] && dirs+=(/src/vps)
  run grep -rlI $'\r' "${dirs[@]}"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 5: Run the environment tests**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/00-env.bats`
Expected: `7 tests, 0 failures`. If `real oathtool accepts -` fails, stop and report: it is a spec 14 assumption that the broker depends on.

- [ ] **Step 6: Check the runner rejects a bad path**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/nope.bats; echo "exit=$?"` (Git Bash), or check `$LASTEXITCODE` in PowerShell.
Expected: `run-bats: no such path in the repo: tests/bats/nope.bats` and exit 2.

- [ ] **Step 7: Line endings, exec bit, commit**

```
grep -rlIU "$(printf '\r')" tests        # must print nothing
git add tests/run-bats.ps1 tests/bats/helpers.bash tests/bats/00-env.bats
git add --chmod=+x tests/bats/stubs/oathtool
git commit -m "Add bats harness: Docker runner, shared helpers, oathtool stub, env tests"
```

---

### Task 3: `vps/vps-facts.sh`: the read-only Task 0 facts script

**Model:** Sonnet. **Depends on:** Task 2. Write it early so the operator can run O2 while Tasks 4+ proceed.

**Files:**
- Create: `vps/vps-facts.sh` (executable)
- Create: `tests/bats/facts.bats`

**Interfaces:**
- Consumes: `tests/run-bats.ps1`, `helpers.bash` (Task 2).
- Produces: a script the operator pipes to the VPS with the spec 13 command `Get-Content .\vps\vps-facts.sh | ssh vps 'bash -s' | Out-File -Encoding utf8 docs\vps-facts.md`. It prints Markdown with the section headers listed in Step 1, which GATE G1 reads.

**Behaviour (spec 13, plan Q2, Q6):**
- Lines 1 and 2 are exactly:

  ```bash
  #!/bin/bash
  case "$0" in *vps-facts.sh) ;; *) tr -d '\r' | bash -s; exit $? ;; esac #
  ```

  Why, so nobody "simplifies" it: PowerShell 5.1 pipes the file to `ssh` with a UTF-8 BOM and CRLF line endings (verified on this laptop). Line 1 absorbs the BOM (at worst one harmless stderr line). When fed on stdin (`$0` is `bash`), line 2 hands the rest of stdin to a fresh `bash -s` with every CR removed, and the trailing ` #` turns line 2's own CR into a comment. bash reads a pipe one byte at a time, so `tr` sees exactly the lines after line 2. When run as a file (`bash vps-facts.sh`), line 2 does nothing.
- Line 3: `export LC_ALL=C` so all output is ASCII (PowerShell decodes ssh output with the console code page).
- The file is **ASCII only**. Do not use `set -e`; every probe must survive missing tools. Run each probe with `2>&1` so stderr stays empty, and wrap anything that can hang in `timeout 20`.
- **Strictly read-only (Q6).** Write no files. No package installs. Do not use `apt-cache` without `--no-generate` (otherwise it may rebuild caches). Do not use `tmux ls` without `-S` (otherwise tmux may create `/tmp/tmux-0`). Never print environment variables, history, keys, `authorized_keys` contents, or anything under `/home/claude/.sesh`.
- Output is Markdown: a first line `# VPS facts`, then a line `Generated: <date -u>`, then each section as a header line followed by a fenced block holding the probe output. When a command is missing or fails, print `(unavailable: <cmd> exit <n>)` inside the fence.
- Sections, with the **exact header line** first and then what to run:
  1. `## Distro`: the `PRETTY_NAME`, `ID`, `ID_LIKE`, `VERSION_ID` lines of `/etc/os-release`; `uname -r`.
  2. `## Versions`: `tmux -V`; `ssh -V`; `dpkg-query -W -f='${Package} ${Version}\n' openssh-server tmux oathtool jq qrencode git curl e2fsprogs`; `oathtool --version | head -n 1`; `bash --version | head -n 1`; `systemctl --version | head -n 1` (setup needs systemd >= 248 for `systemctl --user -M`).
  3. `## Package candidates`: `apt-cache --no-generate policy tmux oathtool jq qrencode`.
  4. `## oathtool stdin key`: if `oathtool` exists, print `stdin: $(printf JBSWY3DPEHPK3PXP | oathtool --totp -b -N @0 -)` and `argv: $(oathtool --totp -b -N @0 JBSWY3DPEHPK3PXP)`, then `MATCH` or `MISMATCH`. Otherwise print `oathtool not installed`. `JBSWY3DPEHPK3PXP` is the public RFC test key, not a secret.
  5. `## sshd`: `grep -nE '^[[:space:]]*(Include|Match|PermitRootLogin|AllowUsers|PasswordAuthentication|UsePAM)' /etc/ssh/sshd_config`; `ls -la /etc/ssh/sshd_config.d/`; the same grep over `/etc/ssh/sshd_config.d/*.conf`; `/usr/sbin/sshd -T -C user=root,host=localhost,addr=127.0.0.1 | grep -E '^(allowusers|usepam|pubkeyauthentication|authorizedkeysfile|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|clientaliveinterval|clientalivecountmax)'`.
  6. `## logind`: `busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager KillUserProcesses`; `systemd-analyze cat-config systemd/logind.conf | grep -n KillUserProcesses`; `loginctl --no-pager list-users`.
  7. `## Time sync`: `timedatectl show -p NTPSynchronized -p Timezone`.
  8. `## Locale`: `locale`; `cat /etc/default/locale`; `locale -a | grep -iE '^(c\.utf-?8|en_us\.utf-?8)$'`.
  9. `## chattr and /var/log`: `findmnt -no FSTYPE,OPTIONS -T /var/log`; `command -v chattr lsattr`; `lsattr -d /var/log`.
  10. `## /tmp cleanup`: `findmnt -no FSTYPE -T /tmp`; `systemctl is-enabled tmp.mount systemd-tmpfiles-clean.timer`; `systemd-tmpfiles --cat-config | grep -E '^[^#]*[[:space:]]/tmp([[:space:]]|$)'`.
  11. `## Root tmux sessions`: `ls -la /tmp/tmux-0/`; for each socket `s` in `/tmp/tmux-0/*`, run `tmux -S "$s" ls`.
  12. `## claude processes`: `ps -eo user,pid,etime,comm | awk 'NR==1 || $4=="claude"'`. Use `comm` only, never full command lines.
  13. `## Root Claude Code state`: `ls -ld /root/.claude /root/.local/bin/claude`; `du -sh /root/.claude`.
  14. `## Disk`: `df -h / /home /var/log`.
  15. `## Users and groups`: `getent group docker`; `getent passwd claude`; `id`.
  16. `## Outbound HTTPS`: `curl -fsS -o /dev/null -w '%{http_code}\n' --max-time 10 https://claude.ai/install.sh`; the same for `https://github.com`.
- Exit status 0 even when probes fail.

- [ ] **Step 1: Write the failing test `tests/bats/facts.bats`**

```bash
#!/usr/bin/env bats
# vps/vps-facts.sh: read-only, ASCII-only, survives PowerShell 5.1's BOM + CRLF piping.
load helpers

FACTS=/src/vps/vps-facts.sh
SECTIONS=(
  '# VPS facts'
  '## Distro'
  '## Versions'
  '## Package candidates'
  '## oathtool stdin key'
  '## sshd'
  '## logind'
  '## Time sync'
  '## Locale'
  '## chattr and /var/log'
  '## /tmp cleanup'
  '## Root tmux sessions'
  '## claude processes'
  '## Root Claude Code state'
  '## Disk'
  '## Users and groups'
  '## Outbound HTTPS'
)

assert_sections() {
  local s
  for s in "${SECTIONS[@]}"; do
    printf '%s\n' "$output" | grep -qxF -- "$s" || { echo "missing section: $s"; return 1; }
  done
}

@test "facts script is ASCII only" {
  run grep -nP '[^\x00-\x7F]' "$FACTS"
  [ "$status" -eq 1 ]
}

@test "facts script passes bash -n and shellcheck" {
  run bash -n "$FACTS"
  [ "$status" -eq 0 ]
  run shellcheck -S warning "$FACTS"
  [ "$status" -eq 0 ]
}

@test "lines 1 and 2 are the BOM/CRLF guard" {
  local want
  want=$(cat <<'EOF'
case "$0" in *vps-facts.sh) ;; *) tr -d '\r' | bash -s; exit $? ;; esac #
EOF
)
  [ "$(sed -n 1p "$FACTS")" = '#!/bin/bash' ]
  [ "$(sed -n 2p "$FACTS")" = "$want" ]
}

@test "runs as a file: exit 0, every section, empty stderr" {
  run --separate-stderr bash "$FACTS"
  [ "$status" -eq 0 ]
  assert_sections
  [ -z "$stderr" ]
}

@test "survives PowerShell 5.1 piping: UTF-8 BOM and CRLF on stdin" {
  run --separate-stderr bash -c "{ printf '\xef\xbb\xbf'; sed 's/\$/\r/' '$FACTS'; } | bash -s"
  [ "$status" -eq 0 ]
  assert_sections
  [[ "$output" != *$'\r'* ]]
  [ "${#stderr_lines[@]}" -le 1 ]
}

@test "survives plain LF on stdin" {
  run --separate-stderr bash -c "bash -s < '$FACTS'"
  [ "$status" -eq 0 ]
  assert_sections
  [ -z "$stderr" ]
}

@test "output is ASCII only and holds no key material" {
  run bash "$FACTS"
  [ "$status" -eq 0 ]
  local bad
  bad=$(printf '%s\n' "$output" | grep -cP '[^\x00-\x7F]' || true)
  [ "$bad" -eq 0 ]
  [[ "$output" != *"PRIVATE KEY"* ]]
}

@test "never touches secrets or dumps the environment" {
  run grep -nE 'printenv|^[[:space:]]*env[[:space:]]*$|totp\.secret|authorized_keys|bash_history|/etc/shadow|id_ed25519|id_rsa' "$FACTS"
  [ "$status" -eq 1 ]
}

@test "is read-only: changes no file outside /tmp" {
  local marker="$BATS_TEST_TMPDIR/marker"
  touch "$marker"
  sleep 1
  run bash "$FACTS"
  [ "$status" -eq 0 ]
  run find /etc /var /home /root /usr /opt /srv -xdev -newer "$marker" -print
  [ -z "$output" ]
}

@test "finishes within 60 seconds" {
  run timeout 60 bash "$FACTS"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/facts.bats`
Expected: failures because `/src/vps/vps-facts.sh` does not exist.

- [ ] **Step 3: Write `vps/vps-facts.sh` to the behaviour above**

Hint for the section helper. Probes are fixed literals in this file, so a function taking a header and a command string is fine:

```bash
section() { # section HEADER COMMAND-STRING
  printf '\n%s\n\n```\n' "$1"
  timeout 20 bash -c "$2" 2>&1 || printf '(unavailable: exit %s)\n' "$?"
  printf '```\n'
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/facts.bats`
Expected: `10 tests, 0 failures`.

- [ ] **Step 5: Line endings, exec bit, commit**

```
grep -lU "$(printf '\r')" vps/vps-facts.sh tests/bats/facts.bats   # must print nothing
git add --chmod=+x vps/vps-facts.sh
git add tests/bats/facts.bats
git commit -m "Add read-only VPS facts script (Task 0) tolerant of PowerShell BOM/CRLF piping"
```

---

### OPERATOR O1: Admin key and `Host vps` (spec 4.5): human only

**No agent action.** The orchestrator tells the operator this can be done any time before O3. It must be done before O3, because deploy uses publickey-only authentication to `vps` (Q3).

Steps for the operator, in PowerShell:

1. `ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_vps_admin_ed25519" -C vps-admin`. Choose a passphrase; do not leave it empty.
2. Install the key with one root-password login. Use this pipe-free variant of the spec 4.5 command (Q18). Piping with `Get-Content | ssh` can prepend a UTF-8 BOM, which makes sshd ignore the key line. `$k` is the only thing PowerShell expands inside the double quotes; the remote side sees no other `$`:

   ```
   $k = (Get-Content "$env:USERPROFILE\.ssh\id_vps_admin_ed25519.pub" -TotalCount 1).Trim()
   ssh vps "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (tail -c1 ~/.ssh/authorized_keys | read -r _ || echo >> ~/.ssh/authorized_keys) && echo $k >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
   ```

   If you already ran the spec's piped form and step 4 fails, repair the file from an interactive root shell, not through a PowerShell-quoted command (5.1 mangles embedded double quotes):

   ```
   ssh vps
   # now on the VPS:
   sed -i -e 's/^\xEF\xBB\xBF//' -e 's/\r$//' ~/.ssh/authorized_keys
   grep -c $'\r' ~/.ssh/authorized_keys      # must print 0
   exit
   ```
3. Replace the `Host vps` block in `~\.ssh\config` with the spec 4.3 block (`IdentityFile ~/.ssh/id_vps_admin_ed25519`, `IdentitiesOnly yes`, `ServerAliveInterval 30`, `ServerAliveCountMax 4`). Do not add `AddKeysToAgent` and never `ssh-add` this key.
4. Verify: `ssh -o PasswordAuthentication=no vps true`. It must prompt for the passphrase and exit 0.

### OPERATOR O2: Run Task 0 facts (spec 13): human only

**No agent action.** Unblocked once Task 3 is committed. Agents continue with Task 4 meanwhile.

1. From the repo root in PowerShell:

   ```
   Get-Content .\vps\vps-facts.sh | ssh vps 'bash -s' | Out-File -Encoding utf8 docs\vps-facts.md
   ```

2. You may see one line like `bash: line 1: $'\357\273\277#!/bin/bash\r': No such file or directory`. That is PowerShell's byte-order mark hitting line 1, and it is harmless (Q2). Any other error line is worth reporting.
3. Skim `docs\vps-facts.md`: it must contain the 17 headers listed in Task 3, and no keys or secrets.
4. Commit it: `git add docs/vps-facts.md; git commit -m "Add VPS facts from Task 0"`. Or ask the orchestrator to commit it.

### GATE G1: Orchestrator reviews `docs/vps-facts.md` against spec 14: orchestrator only

**No agent depends on this.** It must pass before OPERATOR O3 (first deploy). If a row fails, take the listed action. Any action that changes behaviour is a spec change and goes to the user first.

| Assumption | Where in the facts | If it fails |
|---|---|---|
| Debian or Ubuntu with apt (spec 14) | `## Distro` | Stop. The spec's premise is broken; escalate to the user. |
| tmux >= 3.0 available from apt (spec 14) | `## Versions`, `## Package candidates` | Do not deploy. The broker's exact targeting and literal `send-keys` are tested on 3.3a. Escalate to the user: OS upgrade or backports. |
| `KillUserProcesses` not `yes` (spec 14) | `## logind` | Setup preflight will refuse. Escalate: the user may approve a logind drop-in `KillUserProcesses=no` (spec change) or accept sessions dying at logout. |
| `sshd_config` includes `sshd_config.d` (spec 14) | `## sshd` | Setup refuses. The operator adds `Include /etc/ssh/sshd_config.d/*.conf` as the first line of `/etc/ssh/sshd_config` over the admin path, then re-runs O2. |
| `oathtool` accepts `-` (spec 14) | `## oathtool stdin key` (if installed); otherwise the candidate version in `## Package candidates` | The broker passes the secret on stdin only. If the result is `MISMATCH`, or the candidate is older than bookworm's 2.6.7 (proved by Task 2's env test), escalate before deploy; setup step 1 would stop anyway. |
| Outbound HTTPS (spec 14) | `## Outbound HTTPS` | Without it the Claude Code install (setup step 8) and `--repo` clones fail. Escalate; firewall changes are the operator's. |
| OpenSSH >= 7.4, and `ClientAlive*`/`DisableForwarding` accepted inside `Match` | `## Versions` | Setup's `sshd -t` would abort safely. Escalate if the version is older than 8.0. |
| systemd >= 248 (`systemctl --user -M`) | `## Versions` | Re-brief Task 11: replace `systemctl --user -M claude@ ...` with `runuser -u claude -- env XDG_RUNTIME_DIR=/run/user/<uid> systemctl --user ...`. |
| No `AllowUsers`, or one that includes `claude`; no earlier drop-in setting `PermitRootLogin` | `## sshd` | Setup refuses on `AllowUsers`; the operator adds `claude`. An earlier drop-in setting `PermitRootLogin` makes `-HardenRoot` abort (Q1). The operator edits that file before O7. |
| NTP synchronized | `## Time sync` | Setup refuses. The operator runs `timedatectl set-ntp true`, then re-runs O2. |
| `/var/log` on ext4, xfs or btrfs (chattr support) | `## chattr and /var/log` | Setup's real `chattr +a` preflight will tell. Escalate if the filesystem is anything else. |
| `C.UTF-8` locale present | `## Locale` | The broker sets `LC_ALL=C.UTF-8`. If it is missing, escalate (install `locales`). |
| bash >= 4.4 | `## Versions` | The broker expands empty arrays under `set -u`. Escalate if older. |
| Root tmux sessions, `claude` processes running as root, `/root/.claude` | the matching sections | Informational. They feed OPERATOR O5 (migration) and setup's report. |
| `docker` group | `## Users and groups` | If absent, setup skips Docker membership, as spec 10 already allows. |

---

### Task 4: Broker core: invocation, decoding, audit, exit codes, `log`

**Model:** Sonnet. **Depends on:** Task 2.

**Files:**
- Create: `vps/sesh` (executable)
- Create: `tests/bats/broker-core.bats`
- Create: `tests/bats/broker-remote.bats`
- Create: `tests/bats/lint.bats`

**Interfaces:**
- Consumes: `tests/run-bats.ps1` and every helper in `tests/bats/helpers.bash` (Task 2): `setup_local`, `teardown_local`, `sesh`, `sesh_key`, `sesh_nokey`, `audit_last`, `audit_field`, `audit_count`, `b64`, `b64cmd`, `setup_remote`, `teardown_remote`, `remote`, `remote_audit_last`, `SESH_BIN`, `FIXED_NOW`.
- Produces, for Tasks 5-9, which add `verb_*` functions to this same file:
  - Constants (Global Constraints) and `DEFAULT_STATE_DIR=/home/claude/.sesh`, `DEFAULT_AUDIT=/var/log/sesh/audit.log`, `DEFAULT_WORK=/home/claude/work`, `TMUX_CONF=/etc/sesh/tmux.conf`, `NAME_RE='^[a-z][a-z0-9_-]{0,31}$'`, `TOMB_RE='^zz~([a-z][a-z0-9_-]{0,31})~([0-9]+)$'`, `REAP_RE='^zz~[a-z][a-z0-9_-]*~([0-9]+)$'`, `KEY_RE='^[a-z][a-z0-9_-]{0,15}$'`.
  - Runtime globals, set by `main` before any verb runs: `MODE` (`local`|`remote`), `KEY_ID`, `CLIENT_IP`, `NOW` (epoch), `STATE_DIR`, `AUDIT_FILE`, `WORK_DIR`, `TMUX_SOCK`, `OATHTOOL`, `VERB`, `SESSION` (verbs set it), `AUDIT_ENABLED` (1|0), `ARGS` (decoded argument array; `ARGS[0]` is the verb).
  - `audit OK DETAIL`: OK is the literal `true` or `false`. It appends one JSON line, and is a no-op when `AUDIT_ENABLED=0`.
  - `fail CODE MESSAGE [DETAIL]`: prints `sesh: MESSAGE` to stderr, audits `false` with DETAIL (default MESSAGE), and exits CODE.
  - `succeed DETAIL`: audits `true` with DETAIL and exits 0. Verbs print their stdout first.
  - `safe STRING`: the first 64 bytes, with C0/DEL replaced by `?`. Use it for every untrusted string placed in a message.
  - `byte_len STRING`: prints the byte count.
  - `has_ctrl STRING`: status 0 if the string contains any byte 0x01-0x1F or 0x7F.
  - `valid_count N`: status 0 if N matches `^[0-9]{1,4}$`.
  - `authorize`: runs `gate` if `$VERB` is in `GATED_VERBS`, otherwise returns 0. **Every verb calls `authorize` once, after validating its arguments and before touching tmux** (plan Q7). `gate` is written in Task 6; until then only open verbs exist.
  - Dispatch: `main` calls `verb_$VERB "${ARGS[@]:1}"` if a function of that name exists, else fails `2 unknown verb: <safe verb>`. Later tasks add verbs just by defining `verb_<name>`; they never edit `main`.

**Behaviour (spec 5.1, 5.2, 5.4, 7.3, plan Q8, Q12, Q16c):**

File layout, top to bottom. Note the constants order and directives: `shellcheck` treats a directive placed before the first command as file-wide, so the first command must be `LEASE_SECS=1800`.

```bash
#!/bin/bash
# sesh: Claude Code session broker, the forced command for the claude user's session key.
# Spec: docs/superpowers/specs/2026-10-09-sesh-session-broker-design.md
LEASE_SECS=1800
TOMBSTONE_TTL=86400
OTP_STEP=30
OTP_FAIL_MAX=3
OTP_FAIL_WINDOW=600
OTP_COOLDOWN=300
OTP_HARD_MAX=10
OTP_READ_TIMEOUT=60
SEND_ENTER_DELAY=0.3
SEND_MAX_BYTES=8000
GATED_VERBS="new go send rename unlock rm resume auth"
# shellcheck disable=SC2034  # rewritten by deploy.ps1, read by sesh-setup
SESH_VERSION=dev
# ...defaults and regexes, then helpers, then verb_* functions, then main...
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
```

`main` does exactly this, in order:
1. `set -u -o pipefail`; `umask 077`; `export LC_ALL=C.UTF-8`. Do not use `set -e`: every failure goes through `fail`.
2. Set `KEY_ID=local`. If `$1` is `--key`, then `KEY_ID=$2` and shift both (tolerate a missing value).
3. Set `MODE=remote` if `SSH_ORIGINAL_COMMAND` is **set** (test with `${SSH_ORIGINAL_COMMAND+x}`, so an empty value counts) **and** no arguments remain; otherwise `MODE=local` (spec 5.1).
4. Paths. On a local call, honour `SESH_HOME`, `SESH_AUDIT`, `SESH_WORK`, `SESH_TMUX_SOCKET`, `SESH_NOW`, `SESH_OATHTOOL` when set and non-empty. On a remote call, ignore them all. Defaults: `STATE_DIR=$DEFAULT_STATE_DIR`, `AUDIT_FILE=$DEFAULT_AUDIT`, `WORK_DIR=$DEFAULT_WORK`, `OATHTOOL=oathtool`, `TMUX_SOCK=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sesh.sock`. `NOW` is `SESH_NOW` only if it matches `^[0-9]+$`, else `$(date +%s)`.
5. `CLIENT_IP=-`. On remote calls only, use the first space-separated field of `SSH_CLIENT` if it matches `^[0-9A-Fa-f:.]{1,45}$`.
6. Set `VERB=`, `SESSION=`, `AUDIT_ENABLED=1`. If `KEY_ID` does not match `KEY_RE`, fail `2 invalid key id`.
7. Word list. Remote: if `has_ctrl "$SSH_ORIGINAL_COMMAND"`, fail `2 control characters in command`. Otherwise split it with `set -f; read -r -a words <<< "$SSH_ORIGINAL_COMMAND"; set +f`. Local: `words=("$@")`.
8. `decode_args "${words[@]}"`, which sets `ARGS` (fragment below). It applies to both modes (Q12).
9. `VERB=${ARGS[0]:-}`. If empty, fail `2 usage: sesh <new|ls|peek|go|send|rename|lock|unlock|rm|restore|resume|log|auth> [args]`.
10. If `VERB` is `reap` and `MODE` is `remote`, fail `2 reap is local only` (spec 5.1).
11. If `VERB` does not match `^[a-z]+$`, or `declare -F "verb_$VERB"` fails, fail `2 unknown verb: $(safe "$VERB")`. (The audit's `verb` field is `VERB` truncated to 32 bytes.)
12. If `VERB` is `ls` and `ARGS[1]` is `--names` or `--tombstones`, set `AUDIT_ENABLED=0` (spec 6, 7.3).
13. If `AUDIT_ENABLED=1`, open the audit file for append without writing: `{ : >> "$AUDIT_FILE"; } 2>/dev/null`. On failure, print `sesh: audit log not writable` to stderr and `exit 1` (Q8). Do not call `fail`, which would try to audit.
14. `"verb_$VERB" "${ARGS[@]:1}"`.

Load-bearing fragments:

```bash
audit() { # audit true|false DETAIL
  (( AUDIT_ENABLED )) || return 0
  local ts
  ts=$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)
  jq -cn --arg ts "$ts" --arg key "${KEY_ID:0:32}" --arg ip "$CLIENT_IP" \
         --arg verb "${VERB:0:32}" --arg session "${SESSION:0:64}" \
         --argjson ok "$1" --arg detail "$2" \
     '{ts:$ts,key:$key,ip:$ip,verb:$verb,session:$session,ok:$ok,detail:$detail}' \
     >> "$AUDIT_FILE" 2>/dev/null || printf 'sesh: audit write failed\n' >&2
}

decode_args() { # decode_args WORD...: sets ARGS. "b64" first means every later word is base64.
  ARGS=()
  if [[ ${1:-} != b64 ]]; then ARGS=("$@"); return 0; fi
  shift
  local tok dec n
  for tok in "$@"; do
    [[ $tok =~ ^[A-Za-z0-9+/]+={0,2}$ ]] && (( ${#tok} % 4 == 0 )) || fail 2 "bad encoded argument"
    # The trailing x protects trailing newlines that $(...) would otherwise strip.
    { dec=$(printf '%s' "$tok" | base64 -d && printf x); } 2>/dev/null || fail 2 "bad encoded argument"
    dec=${dec%x}
    # bash silently drops NUL bytes; compare byte counts to catch them.
    n=$(printf '%s' "$tok" | base64 -d 2>/dev/null | wc -c)
    (( n == $(byte_len "$dec") )) || fail 2 "bad encoded argument"
    ARGS+=("$dec")
  done
}

byte_len() { printf '%s' "$1" | wc -c; }
has_ctrl() { # status 0 when $1 contains C0 (0x01-0x1F) or DEL
  local stripped
  stripped=$(printf '%s' "$1" | LC_ALL=C tr -d '\001-\037\177'; printf x)
  [[ $(byte_len "${stripped%x}") -ne $(byte_len "$1") ]]
}
safe() { printf '%s' "${1:0:64}" | LC_ALL=C tr '\001-\037\177' '?'; }
authorize() { [[ " $GATED_VERBS " == *" $VERB "* ]] || return 0; gate; }
```

`verb_log [-n N]`: N defaults to 50. Any argument other than `-n <N>` is usage (2). If N fails `valid_count`, fail `2 -n must be 0-9999`. Then `authorize`, then print `tail -n "$N" "$AUDIT_FILE"`; if that fails, fail `1 cannot read audit log`. Finally `succeed "lines=$N"`, so `log` audits itself after printing (Q15).

**Traps for this task (read before coding):**
- `fail` exits the **current shell**. Never call `fail` (or a helper that may call it) inside `$(...)`, in any segment of a pipeline, or in a `cmd | while read` loop: that only exits a subshell. Use `while ...; done < <(cmd)` instead.
- Never pass an argument through `eval`, `bash -c` or an unquoted expansion. Every external command gets an argument array.
- Use `wc -c` for byte counts. `${#var}` counts characters under `LC_ALL=C.UTF-8`.

- [ ] **Step 1: Write the failing tests: `tests/bats/broker-core.bats`**

```bash
#!/usr/bin/env bats
# Broker core: invocation, --key, argument decoding, audit, exit codes, log.
load helpers
setup() { setup_local; }
teardown() { teardown_local; }

@test "no arguments is usage (2), one stderr line, audited" {
  run --separate-stderr sesh
  [ "$status" -eq 2 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == "sesh: "* ]]
  [ "$(audit_count)" -eq 1 ]
  [ "$(audit_field ok)" = false ]
}

@test "unknown verb is usage (2) and the verb is audited" {
  run --separate-stderr sesh frobnicate
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown verb"* ]]
  [ "$(audit_field verb)" = frobnicate ]
  [ "$(audit_field ok)" = false ]
}

@test "verbs are case-sensitive" {
  run sesh LOG
  [ "$status" -eq 2 ]
}

@test "control characters in an unknown verb are not echoed raw" {
  run --separate-stderr sesh $'fro\ebnicate'
  [ "$status" -eq 2 ]
  [[ "$stderr" != *$'\e'* ]]
}

@test "invalid --key id is usage (2)" {
  run sesh_key BAD log
  [ "$status" -eq 2 ]
  run sesh_key 1abc log
  [ "$status" -eq 2 ]
  run sesh_key abcdefghijklmnopq log
  [ "$status" -eq 2 ]
}

@test "audit line has exactly the spec keys and values" {
  run sesh log
  [ "$status" -eq 0 ]
  run jq -e 'keys == ["detail","ip","key","ok","session","ts","verb"] and (.ok | type == "boolean")' <<<"$(audit_last)"
  [ "$status" -eq 0 ]
  [ "$(audit_field ts)" = "$(date -u -d "@$FIXED_NOW" +%Y-%m-%dT%H:%M:%SZ)" ]
  [ "$(audit_field key)" = t ]
  [ "$(audit_field ip)" = - ]
  [ "$(audit_field verb)" = log ]
  [ "$(audit_field ok)" = true ]
}

@test "without --key the audit key is local" {
  run sesh_nokey log
  [ "$status" -eq 0 ]
  [ "$(audit_field key)" = local ]
}

@test "log prints the last N lines, then audits itself" {
  local i
  for i in 1 2 3 4 5; do printf '{"n":%d}\n' "$i" >> "$SESH_AUDIT"; done
  run sesh log -n 2
  [ "$status" -eq 0 ]
  [ "$output" = $'{"n":4}\n{"n":5}' ]
  [ "$(audit_field verb)" = log ]
  [ "$(audit_field detail)" = lines=2 ]
}

@test "log defaults to 50 lines" {
  local i
  for i in $(seq 1 60); do printf '{"n":%d}\n' "$i" >> "$SESH_AUDIT"; done
  run sesh log
  [ "${#lines[@]}" -eq 50 ]
  [ "${lines[0]}" = '{"n":11}' ]
}

@test "log -n must be 0-9999 and log takes no other arguments" {
  run sesh log -n abc
  [ "$status" -eq 2 ]
  run sesh log -n 12345
  [ "$status" -eq 2 ]
  run sesh log -n
  [ "$status" -eq 2 ]
  run sesh log extra
  [ "$status" -eq 2 ]
  run sesh log -n 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unwritable audit log fails closed with exit 1" {
  export SESH_AUDIT=/nonexistent-dir/audit.log
  run --separate-stderr sesh log
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"audit log not writable"* ]]
}

@test "b64 form decodes every argument" {
  printf '{"n":1}\n{"n":2}\n' >> "$SESH_AUDIT"
  run sesh $(b64cmd log -n 1)
  [ "$status" -eq 0 ]
  [ "$output" = '{"n":2}' ]
}

@test "invalid b64 tokens are usage (2)" {
  run sesh b64 'bG9n!'
  [ "$status" -eq 2 ]
  run sesh b64 bG9
  [ "$status" -eq 2 ]
  run sesh b64 '===='
  [ "$status" -eq 2 ]
  run sesh b64
  [ "$status" -eq 2 ]
}

@test "a decoded argument containing NUL is usage (2)" {
  # YQBi is base64 of the three bytes a, NUL, b.
  run sesh b64 "$(b64 log)" YQBi
  [ "$status" -eq 2 ]
}

@test "a trailing newline inside an encoded argument is kept, not stripped" {
  # bG9nCg== is base64 of "log\n"; a decoder that stripped it would run 'log' and exit 0.
  run sesh b64 bG9nCg==
  [ "$status" -eq 2 ]
}

@test "SESH_NOW that is not digits falls back to the real clock" {
  export SESH_NOW=garbage
  run sesh log
  [ "$status" -eq 0 ]
  [ "$(audit_field ts)" != "$(date -u -d "@$FIXED_NOW" +%Y-%m-%dT%H:%M:%SZ)" ]
}

@test "the broker can be sourced without running main" {
  run bash -c "source '$SESH_BIN'; declare -F main >/dev/null && echo sourced"
  [ "$status" -eq 0 ]
  [ "$output" = sourced ]
}
```

- [ ] **Step 2: Write the failing tests: `tests/bats/broker-remote.bats`**

```bash
#!/usr/bin/env bats
# Remote-mode behaviour: sshd sets SSH_ORIGINAL_COMMAND and the broker ignores SESH_*.
# These tests use the broker's real default paths inside the container (plan Q11).
load helpers
setup() { setup_remote; }
teardown() { teardown_remote; }

@test "remote: plain and b64 forms give identical results" {
  run --separate-stderr remote 203.0.113.9 laptop 'frobnicate x'
  local s1=$status e1=$stderr
  run --separate-stderr remote 203.0.113.9 laptop "$(b64cmd frobnicate x)"
  [ "$status" -eq "$s1" ]
  [ "$stderr" = "$e1" ]
  [ "$s1" -eq 2 ]
}

@test "remote: audit records the key id and the client IP" {
  run remote 203.0.113.9 laptop 'log -n 1'
  [ "$status" -eq 0 ]
  local line
  line=$(remote_audit_last)
  [ "$(jq -r .key <<<"$line")" = laptop ]
  [ "$(jq -r .ip <<<"$line")" = 203.0.113.9 ]
}

@test "remote: SESH_* overrides are ignored" {
  export SESH_AUDIT="$BATS_TEST_TMPDIR/override.log"
  : > "$SESH_AUDIT"
  run remote 203.0.113.9 laptop 'log -n 1'
  [ "$status" -eq 0 ]
  [ ! -s "$SESH_AUDIT" ]
  [ "$(wc -l < /var/log/sesh/audit.log)" -eq 1 ]
}

@test "remote: reap is refused (2) and audited" {
  run --separate-stderr remote 203.0.113.9 laptop reap
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"local only"* ]]
  [ "$(jq -r .ok <<<"$(remote_audit_last)")" = false ]
}

@test "remote: control characters in the command are usage (2)" {
  run remote 203.0.113.9 laptop $'log\n-n 1'
  [ "$status" -eq 2 ]
}

@test "remote: words are never glob-expanded" {
  mkdir -p "$BATS_TEST_TMPDIR/g"
  touch "$BATS_TEST_TMPDIR/g/log"
  cd "$BATS_TEST_TMPDIR/g"
  run --separate-stderr remote 203.0.113.9 laptop '*'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown verb"* ]]
}

@test "ssh with no command is a local call with no verb (2)" {
  run env SSH_CLIENT='203.0.113.9 50000 22' bash "$SESH_BIN" --key laptop </dev/null
  [ "$status" -eq 2 ]
}

@test "argv after --key makes the call local even with SSH_ORIGINAL_COMMAND set" {
  run env SSH_ORIGINAL_COMMAND=frobnicate bash "$SESH_BIN" --key laptop log -n 1 </dev/null
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 3: Write the failing tests: `tests/bats/lint.bats`**

```bash
#!/usr/bin/env bats
# Static checks on the broker. SC2034 (unused variable) is excluded until Task 9,
# when every constant is in use; Task 9 removes the exclusion.
load helpers

@test "broker passes bash -n and shellcheck -S warning" {
  run bash -n "$SESH_BIN"
  [ "$status" -eq 0 ]
  run shellcheck -S warning -e SC2034 "$SESH_BIN"
  [ "$status" -eq 0 ]
}

@test "GATED_VERBS is one line in the agreed format" {
  run grep -c '^GATED_VERBS=' "$SESH_BIN"
  [ "$output" = 1 ]
  grep -qx 'GATED_VERBS="new go send rename unlock rm resume auth"' "$SESH_BIN"
}

@test "SESH_VERSION=dev appears exactly once" {
  run grep -c '^SESH_VERSION=dev$' "$SESH_BIN"
  [ "$output" = 1 ]
}

@test "constants have the spec values" {
  local c
  for c in LEASE_SECS=1800 TOMBSTONE_TTL=86400 OTP_STEP=30 OTP_FAIL_MAX=3 OTP_FAIL_WINDOW=600 \
           OTP_COOLDOWN=300 OTP_HARD_MAX=10 OTP_READ_TIMEOUT=60 SEND_ENTER_DELAY=0.3 SEND_MAX_BYTES=8000; do
    grep -qx "$c" "$SESH_BIN" || { echo "missing: $c"; return 1; }
  done
}

@test "no eval and no has-session anywhere" {
  run grep -nE '(^|[^a-z_])eval[[:space:]]|has-session' "$SESH_BIN"
  [ "$status" -eq 1 ]
}

@test "broker has no carriage returns" {
  run grep -c $'\r' "$SESH_BIN"
  [ "$output" = 0 ]
}
```

- [ ] **Step 4: Run them to see them fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-core.bats` (then the same with `broker-remote.bats` and `lint.bats`).
Expected: failures, because `/src/vps/sesh` does not exist.

- [ ] **Step 5: Implement `vps/sesh` to the behaviour above.**

- [ ] **Step 6: Run the three files until green**

Expected: `broker-core.bats` 17 tests, `broker-remote.bats` 8 tests, `lint.bats` 6 tests; all `0 failures`.

- [ ] **Step 7: Line endings, exec bit, commit**

```
grep -lU "$(printf '\r')" vps/sesh tests/bats/broker-core.bats tests/bats/broker-remote.bats tests/bats/lint.bats   # must print nothing
git add --chmod=+x vps/sesh
git add tests/bats/broker-core.bats tests/bats/broker-remote.bats tests/bats/lint.bats
git commit -m "Add broker core: invocation rules, b64 decoding, audit log, exit codes, log verb"
```

---

### Task 5: Broker tmux layer, names, `ls`, `peek`, `lock`

**Model:** Sonnet. **Depends on:** Task 4.

**Files:**
- Modify: `vps/sesh`. Add helpers and `verb_ls`, `verb_peek`, `verb_lock`; do not edit `main`.
- Create: `tests/bats/broker-read.bats`

**Interfaces:**
- Consumes (Task 4, same file): globals `TMUX_SOCK`, `TMUX_CONF`, `NOW`, `VERB`, `SESSION`, `NAME_RE`, `TOMB_RE`; functions `fail CODE MSG [DETAIL]`, `succeed DETAIL`, `safe`, `valid_count`, `authorize`. Helpers from `helpers.bash`: `setup_local`, `teardown_local`, `sesh`, `tm`, `mk_session`, `mk_session_cmd`, `locked_flag`, `wait_for_pane_line`, `audit_field`, `audit_count`, `SESH_BIN`.
- Produces, for Tasks 6-9:
  - `tmx ARGS...`: the only place `tmux` is invoked. It runs `env -u SSH_ORIGINAL_COMMAND -u SSH_CLIENT -u SSH_CONNECTION -u SSH_TTY LANG=C.UTF-8 tmux -u [-f "$TMUX_CONF" if readable] -S "$TMUX_SOCK" ARGS...` (spec 5.1, 8, Q16a/b).
  - `tmux_on NAME SUBCOMMAND [ARGS...]`: runs `tmx SUBCOMMAND -t "=NAME:" ARGS...`. It is the **only** way to target a session (spec 5.3). Examples: `tmux_on api send-keys -l -- "$text"`; `tmux_on api set-option @sesh_locked 1`; `tmux_on api rename-session newname`; `tmux_on api kill-session`.
  - `list_sessions`: prints session names one per line, and prints nothing (status 0) when there is no server or the socket is stale.
  - `session_exists NAME`: exact string match only.
  - `tombstones_of BASE`: prints that base's tombstone names, oldest epoch first.
  - `newest_tombstone BASE`: prints the greatest-epoch tombstone of BASE, or nothing.
  - `valid_name STR`, `valid_tombstone STR`: status only.
  - `require_name STR`: sets `SESSION=STR`, then fails 2 on a missing name or one that is not a valid non-tombstone name. Messages: `missing session name`; `invalid session name: <safe>`.
  - `require_name_or_tombstone STR`: the same, but tombstone names are also accepted.
  - `session_locked NAME`: status 0 if `#{@sesh_locked}` is `1`.
  - `humanise SECONDS`: prints `Ns` under 60, `Nm` under 3600, `Nh` under 86400, else `Nd`; floors; negative values count as 0.
  - Convention (not a function): when a tmux action fails, call `fail 1 "tmux: <first line of tmux stderr>"`.

**Behaviour (spec 5.3, 6, 8):**
- `tmx` fragment (`-f` only when readable; `${conf[@]}` is safe under `set -u` on bash >= 4.4):

  ```bash
  tmx() {
    local -a conf=()
    [[ -r $TMUX_CONF ]] && conf=(-f "$TMUX_CONF")
    env -u SSH_ORIGINAL_COMMAND -u SSH_CLIENT -u SSH_CONNECTION -u SSH_TTY LANG=C.UTF-8 \
      tmux -u "${conf[@]}" -S "$TMUX_SOCK" "$@"
  }
  tmux_on() { local name=$1 sub=$2; shift 2; tmx "$sub" -t "=$name:" "$@"; }
  ```

  Why `=NAME:` with the colon: without it, `-t =bash` on a window- or pane-type command (`send-keys`, `capture-pane`, `display-message`) can resolve to a *window* named `bash` in another session.
- `ls [--names | --tombstones]`: at most one flag; anything else is usage (2). Then `authorize` (a no-op; `ls` is open).
  - `--names`: every name from `list_sessions` that is not a tombstone, in tmux order.
  - `--tombstones`: the base names that have at least one tombstone, `sort -u`.
  - Both print names only and exit 0 **without** calling `succeed` (they are not audited; `main` already set `AUDIT_ENABLED=0`).
  - Default table:
    - Read `tmx list-sessions -F '#{session_name}|#{session_created}|#{session_activity}|#{session_attached}|#{@sesh_locked}|#{pane_title}'` with `IFS='|' read -r name created activity attached locked title`. Use `|`, not tab: tab is IFS whitespace, so an empty `@sesh_locked` field would collapse.
    - STATE is `tombstone` if the name matches `TOMB_RE`, else `locked` if locked=1, else `live`. ATTACHED is `*` if attached > 0, else empty.
    - AGE is `humanise $((NOW-created))` and IDLE is `humanise $((NOW-activity))`.
    - TITLE: strip bytes 0x00-0x1F and 0x7F (`LC_ALL=C tr -d '\000-\037\177'`), then take the first 40 characters (`${title:0:40}` under `LC_ALL=C.UTF-8`).
    - Print the header and rows with `printf '%-*s  %-9s  %-8s  %-5s  %-5s  %s\n'`, where the first width is max(4, longest name). Columns: NAME STATE ATTACHED AGE IDLE TITLE.
    - With no sessions, print the header only.
    - Then `succeed listed`.
  - No server is an empty list and exit 0.
- `peek <name|tombstone> [-n N]`: N defaults to 40 and must pass `valid_count` (else 2). `require_name_or_tombstone`, then `authorize`. Fail `5 no such session: <name>` unless `session_exists`. Then print the pane with trailing blank lines dropped and only the last N lines kept:

  ```bash
  tmux_on "$name" capture-pane -p -J -S - \
    | awk '{ l[NR] = $0 } /[^[:space:]]/ { last = NR } END { for (i = 1; i <= last; i++) print l[i] }' \
    | tail -n "$n"
  ```

  Then `succeed "lines=$n"`. If tmux fails, fail 1.
- `lock <name>`: `require_name` (tombstones rejected with 2), `authorize`, exists or 5, `tmux_on "$name" set-option @sesh_locked 1`, print `locked <name>`, `succeed locked`.

- [ ] **Step 1: Write the failing test `tests/bats/broker-read.bats`**

```bash
#!/usr/bin/env bats
# tmux layer, name rules, exact targeting for ls, peek and lock.
load helpers
setup() { setup_local; }
teardown() { teardown_local; }

@test "humanise boundaries" {
  source "$SESH_BIN"
  [ "$(humanise 0)" = 0s ]
  [ "$(humanise 59)" = 59s ]
  [ "$(humanise 60)" = 1m ]
  [ "$(humanise 3599)" = 59m ]
  [ "$(humanise 3600)" = 1h ]
  [ "$(humanise 86399)" = 23h ]
  [ "$(humanise 86400)" = 1d ]
  [ "$(humanise 200000)" = 2d ]
  [ "$(humanise -5)" = 0s ]
}

@test "ls with no tmux server: empty lists, header-only table, exit 0" {
  run sesh ls --names
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sesh ls --tombstones
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sesh ls
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" =~ ^NAME\ +STATE\ +ATTACHED\ +AGE\ +IDLE\ +TITLE$ ]]
}

@test "ls --names lists live and locked sessions, not tombstones" {
  mk_session api
  mk_session web
  mk_session 'zz~old~1789990000'
  tm set-option -t '=web:' @sesh_locked 1
  run sesh ls --names
  [ "$status" -eq 0 ]
  [ "$output" = $'api\nweb' ]
}

@test "ls --tombstones lists each base name once, sorted" {
  mk_session 'zz~old~1789990000'
  mk_session 'zz~old~1789990500'
  mk_session 'zz~gone~1'
  mk_session live
  run sesh ls --tombstones
  [ "$output" = $'gone\nold' ]
}

@test "ls --names and --tombstones are not audited; plain ls is" {
  mk_session api
  sesh ls --names
  sesh ls --tombstones
  [ "$(audit_count)" -eq 0 ]
  sesh ls
  [ "$(audit_count)" -eq 1 ]
  [ "$(audit_field verb)" = ls ]
}

@test "ls rejects unknown or combined flags (2)" {
  run sesh ls --bogus
  [ "$status" -eq 2 ]
  run sesh ls --names --tombstones
  [ "$status" -eq 2 ]
}

@test "ls table: state, humanised age and idle, title" {
  # +30s of slack so a second boundary between here and session creation cannot yield 1h.
  export SESH_NOW=$(( $(date +%s) + 7230 ))
  mk_session api
  mk_session web
  mk_session 'zz~old~1'
  tm set-option -t '=web:' @sesh_locked 1
  tm select-pane -t '=api:' -T 'Refactoring the parser'
  run sesh ls
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^NAME\ +STATE\ +ATTACHED\ +AGE\ +IDLE\ +TITLE$ ]]
  local api web old
  api=$(printf '%s\n' "${lines[@]}" | grep '^api ')
  web=$(printf '%s\n' "${lines[@]}" | grep '^web ')
  old=$(printf '%s\n' "${lines[@]}" | grep '^zz~old~1 ')
  [[ "$api" =~ ^api\ +live\ +2h\ +2h\ +Refactoring\ the\ parser$ ]]
  [[ "$web" =~ ^web\ +locked\  ]]
  [[ "$old" =~ ^zz~old~1\ +tombstone\  ]]
}

@test "ls truncates titles to 40 columns and strips control characters (Review Focus 1)" {
  mk_session api
  tm select-pane -t '=api:' -T "$(printf 'A%.0s' $(seq 1 50))"
  run sesh ls
  local row
  row=$(printf '%s\n' "${lines[@]}" | grep '^api ')
  [[ "$row" == *" $(printf 'A%.0s' $(seq 1 40))" ]]
  [[ "$row" != *"$(printf 'A%.0s' $(seq 1 41))"* ]]
  tm select-pane -t '=api:' -T $'evil\e]0;pwned\atitle'
  run sesh ls
  [[ "$output" != *$'\e'* ]]
  [[ "$output" != *$'\a'* ]]
}

@test "peek prints the last N non-blank lines" {
  mk_session_cmd api 'printf "l%s\n" 1 2 3 4 5; exec sleep 300'
  wait_for_pane_line api l5
  run sesh peek api -n 2
  [ "$status" -eq 0 ]
  [ "$output" = $'l4\nl5' ]
  run sesh peek api
  [ "$output" = $'l1\nl2\nl3\nl4\nl5' ]
  [ "$(audit_field detail)" = lines=40 ]
}

@test "peek -n validation" {
  mk_session api
  run sesh peek api -n abc
  [ "$status" -eq 2 ]
  run sesh peek api -n 12345
  [ "$status" -eq 2 ]
  run sesh peek api -n 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "peek accepts a tombstone name" {
  mk_session_cmd 'zz~api~1789990000' 'echo tomb; exec sleep 300'
  wait_for_pane_line 'zz~api~1789990000' tomb
  run sesh peek 'zz~api~1789990000'
  [ "$status" -eq 0 ]
  [ "$output" = tomb ]
}

@test "peek on a missing session is not found (5); a prefix is not a match" {
  mk_session api2
  run sesh peek api
  [ "$status" -eq 5 ]
}

@test "lock sets @sesh_locked on exactly that session, without a lease" {
  mk_session api
  mk_session api2
  run sesh lock api
  [ "$status" -eq 0 ]
  [ "$output" = "locked api" ]
  [ "$(locked_flag api)" = 1 ]
  [ -z "$(locked_flag api2)" ]
}

@test "lock rejects tombstone names (2) and missing sessions (5)" {
  mk_session 'zz~api~1'
  mk_session api2
  run sesh lock 'zz~api~1'
  [ "$status" -eq 2 ]
  run sesh lock api
  [ "$status" -eq 5 ]
  [ -z "$(locked_flag api2)" ]
}

@test "name rules: digit start, uppercase, punctuation, too long, dash start are usage (2)" {
  local n
  for n in 1kb Api a.b a:b 'a b' -x "$(printf 'a%.0s' $(seq 1 33))"; do
    run sesh lock "$n"
    [ "$status" -eq 2 ] || { echo "name '$n' gave $status"; return 1; }
  done
  run sesh lock "$(printf 'a%.0s' $(seq 1 32))"
  [ "$status" -eq 5 ]
}

@test "a session named bash is targeted, not a window named bash in another session" {
  mk_session other
  tm rename-window -t '=other:' bash
  mk_session bash
  run sesh lock bash
  [ "$status" -eq 0 ]
  [ "$(locked_flag bash)" = 1 ]
  [ -z "$(locked_flag other)" ]
}
```

- [ ] **Step 2: Run to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-read.bats`
Expected: failures with `unknown verb` (exit 2) for `ls`, `peek`, `lock`, and `humanise: command not found`.

- [ ] **Step 3: Implement the helpers and the three verbs in `vps/sesh`.**

- [ ] **Step 4: Run the new file and the earlier broker files**

Run with `-Path tests/bats/broker-read.bats`, then `-Path tests/bats` (everything so far).
Expected: `broker-read.bats` 16 tests, 0 failures; the whole directory has 0 failures.

- [ ] **Step 5: Line endings, commit**

```
grep -lU "$(printf '\r')" vps/sesh tests/bats/broker-read.bats   # must print nothing
git add vps/sesh tests/bats/broker-read.bats
git commit -m "Broker: exact-target tmux layer, name rules, ls, peek, lock"
```

---

### Task 6: Broker TOTP gate, lease, `auth`, `unlock`

**Model:** Sonnet. Security-critical: the orchestrator should have Opus review this diff. **Depends on:** Task 5.

**Files:**
- Modify: `vps/sesh`. Add `lease_valid`, `gate`, `verb_auth`, `verb_unlock`.
- Create: `tests/bats/broker-gate.bats`
- Modify: `tests/bats/broker-remote.bats` (append one test)

**Interfaces:**
- Consumes (same file): globals `STATE_DIR`, `KEY_ID`, `CLIENT_IP`, `NOW`, `VERB`, `OATHTOOL`, the OTP constants, `LEASE_SECS`; functions `fail CODE MSG [DETAIL]`, `succeed`, `authorize` (which calls `gate` for verbs in `GATED_VERBS`), `require_name`, `session_exists`, `session_locked`, `tmux_on`. Helpers: `setup_local`, `teardown_local`, `sesh`, `sesh_key`, `tm`, `mk_session`, `locked_flag`, `mk_lease`, `now_step`, `code_for_step`, `with_tty`, `strip_cr`, `audit_field`, `setup_remote`, `teardown_remote`, `rtm`, `remote`.
- Produces, for Tasks 7-9:
  - `gate`: returns 0 when the caller may proceed; otherwise it exits through `fail`. **It closes its lock fd before returning** so that nothing the verb starts (tmux server, `exec tmux attach`) inherits the lock.
  - `lease_valid FILE`: status 0 if FILE holds a digits-only epoch E with `0 <= NOW - E < LEASE_SECS`.

**Behaviour (spec 7.1, plan Q8, Q15):** state lives in `STATE_DIR`: `totp.secret`, `last-otp`, `otp-fails` (one epoch per line), `otp-locked`, `gate.lock`, `leases/<KEY_ID>@<CLIENT_IP>`. `gate` does, in order:
1. `mkdir -p "$STATE_DIR/leases"` (umask is 077); on failure, fail `1 cannot create state directory`. Open the lock with `exec 9>>"$STATE_DIR/gate.lock"` and take it with `flock 9`. The whole gate runs under this lock.
2. If `otp-locked` exists: fail `3 OTP locked after repeated failures; root must remove $STATE_DIR/otp-locked`, detail `otp-locked`. This happens even with a valid lease.
3. If `VERB` is not `auth` and `lease_valid "$STATE_DIR/leases/$KEY_ID@$CLIENT_IP"`: close fd 9 (`exec 9>&-`) and return 0.
4. Cooldown: of the epochs in `otp-fails`, count those with `0 <= NOW - e < OTP_FAIL_WINDOW`; let `newest` be the greatest epoch. If the count is >= `OTP_FAIL_MAX` and `NOW - newest < OTP_COOLDOWN`, fail `4 cooldown, retry in <OTP_COOLDOWN-(NOW-newest)>s`, detail `cooldown`.
5. If `[[ ! -t 0 ]]`: fail `4 TOTP required: run with a terminal or run 'sesh auth' first`, detail `no-tty`.
6. Read the secret: if `totp.secret` is unreadable, or empty after `tr -d '[:space:]'`, fail `1 TOTP not configured; run sesh-setup`. This is not counted as a failure (Q8).
7. Prompt on the terminal, never on stdout:

   ```bash
   printf 'TOTP: ' > /dev/tty
   IFS= read -r -s -t "$OTP_READ_TIMEOUT" code < /dev/tty || code=
   printf '\n' > /dev/tty
   ```

8. If `code` matches `^[0-9]{6}$`: `step=$(( NOW / OTP_STEP ))`. For `s` in `step-1 step step+1`, run `printf '%s' "$secret" | "$OATHTOOL" --totp -b -N "@$(( s * OTP_STEP ))" -`. The secret goes only on stdin, never on a command line. The first `s` whose output equals `code` is the match.
9. Replay guard: `last` is the integer in `last-otp` (0 if missing or not digits). Success requires a match with `s > last`. On success: write `s` to `last-otp`, write `NOW` to the lease file, truncate `otp-fails`, close fd 9, return 0.
10. Otherwise (no match, bad format, timeout, or replay): append `NOW` to `otp-fails`. If it now has >= `OTP_HARD_MAX` lines, create `otp-locked`. Then fail `4 wrong code`, detail `otp-fail`.

- `verb_auth`: takes no arguments (else 2). It calls `authorize`, which always prompts because `VERB=auth`, then prints `authenticated; lease valid for 30m` and calls `succeed authenticated`.
- `verb_unlock <name>`: exactly one argument; `require_name`; `authorize`; exists or `5 no such session: <name>`. If `session_locked`, run `tmux_on "$name" set-option -u @sesh_locked`. Print `unlocked <name>`, then `succeed unlocked`.

**Traps:** do not read the code from stdin (`read` without `< /dev/tty`): the prompt must work under `ssh -t`, where only the tty is meaningful. Never print or audit the code or the secret. Do not call `fail` inside `$(...)`. Close fd 9 on every return path (exits close it automatically).

- [ ] **Step 1: Write the failing test `tests/bats/broker-gate.bats`**

```bash
#!/usr/bin/env bats
# TOTP gate and lease (spec 7.1), auth and unlock. Stub code for step S is S mod 1e6.
load helpers
setup() {
  setup_local
  mk_session api
  tm set-option -t '=api:' @sesh_locked 1
}
teardown() { teardown_local; }

fails_file() { printf '%s' "$SESH_HOME/otp-fails"; }

@test "auth accepts the codes for step-1, step and step+1" {
  local s d
  s=$(now_step)
  for d in -1 0 1; do
    printf '0\n' > "$SESH_HOME/last-otp"
    run with_tty "$(code_for_step $((s + d)))" --key t auth
    [ "$status" -eq 0 ] || { echo "offset $d: $output"; return 1; }
    [[ "$(strip_cr "$output")" == *"authenticated; lease valid for 30m"* ]]
  done
}

@test "auth rejects step-2 and step+2 (4)" {
  local s
  s=$(now_step)
  run with_tty "$(code_for_step $((s - 2)))" --key t auth
  [ "$status" -eq 4 ]
  run with_tty "$(code_for_step $((s + 2)))" --key t auth
  [ "$status" -eq 4 ]
}

@test "the prompt is 'TOTP: ' on the terminal" {
  run with_tty "$(code_for_step "$(now_step)")" --key t auth
  [[ "$(strip_cr "$output")" == *"TOTP: "* ]]
}

@test "success writes last-otp and the lease, and truncates otp-fails" {
  local s
  s=$(now_step)
  printf '%s\n' $((SESH_NOW - 5000)) $((SESH_NOW - 4000)) > "$(fails_file)"
  run with_tty "$(code_for_step "$s")" --key t auth
  [ "$status" -eq 0 ]
  [ "$(cat "$SESH_HOME/last-otp")" = "$s" ]
  [ "$(cat "$SESH_HOME/leases/t@-")" = "$SESH_NOW" ]
  [ ! -s "$(fails_file)" ]
  [ "$(audit_field verb)" = auth ]
  [ "$(audit_field detail)" = authenticated ]
}

@test "a replayed step is rejected; a later step is accepted" {
  local s
  s=$(now_step)
  printf '%s\n' "$s" > "$SESH_HOME/last-otp"
  run with_tty "$(code_for_step "$s")" --key t auth
  [ "$status" -eq 4 ]
  run with_tty "$(code_for_step $((s + 1)))" --key t auth
  [ "$status" -eq 0 ]
  [ "$(cat "$SESH_HOME/last-otp")" = $((s + 1)) ]
}

@test "input that is not six digits counts as a failure, audited as otp-fail" {
  run with_tty 12345a --key t auth
  [ "$status" -eq 4 ]
  [ "$(wc -l < "$(fails_file)")" -eq 1 ]
  [ "$(audit_field ok)" = false ]
  [ "$(audit_field detail)" = otp-fail ]
  run with_tty '' --key t auth
  [ "$status" -eq 4 ]
  [ "$(wc -l < "$(fails_file)")" -eq 2 ]
}

@test "no TTY and no lease fails (4) with the spec message and changes nothing" {
  run --separate-stderr sesh unlock api
  [ "$status" -eq 4 ]
  [ "$stderr" = "sesh: TOTP required: run with a terminal or run 'sesh auth' first" ]
  [ "$(locked_flag api)" = 1 ]
  [ "$(audit_field detail)" = no-tty ]
}

@test "a lease younger than LEASE_SECS skips the prompt" {
  mk_lease t - $((SESH_NOW - 1799))
  run sesh unlock api
  [ "$status" -eq 0 ]
  [ "$output" = "unlocked api" ]
  [ -z "$(locked_flag api)" ]
}

@test "a lease exactly LEASE_SECS old has expired" {
  mk_lease t - $((SESH_NOW - 1800))
  run sesh unlock api
  [ "$status" -eq 4 ]
}

@test "a lease from the future is ignored" {
  mk_lease t - $((SESH_NOW + 60))
  run sesh unlock api
  [ "$status" -eq 4 ]
}

@test "a lease belongs to one key id" {
  mk_lease other -
  run sesh unlock api
  [ "$status" -eq 4 ]
  run sesh_key other unlock api
  [ "$status" -eq 0 ]
}

@test "auth prompts even with a valid lease" {
  mk_lease t -
  run sesh auth
  [ "$status" -eq 4 ]
  run with_tty "$(code_for_step "$(now_step)")" --key t auth
  [ "$status" -eq 0 ]
}

@test "three failures trigger the cooldown, without prompting" {
  local i
  for i in 1 2 3; do
    run with_tty 000001 --key t auth
    [ "$status" -eq 4 ]
  done
  run --separate-stderr sesh auth
  [ "$status" -eq 4 ]
  [ "$stderr" = "sesh: cooldown, retry in 300s" ]
  [ "$(audit_field detail)" = cooldown ]
}

@test "cooldown ends once the newest failure is OTP_COOLDOWN old" {
  printf '%s\n' $((SESH_NOW - 400)) $((SESH_NOW - 350)) $((SESH_NOW - 300)) > "$(fails_file)"
  run --separate-stderr sesh auth
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"TOTP required"* ]]
}

@test "cooldown counts only failures inside OTP_FAIL_WINDOW" {
  printf '%s\n' $((SESH_NOW - 700)) $((SESH_NOW - 650)) $((SESH_NOW - 10)) > "$(fails_file)"
  run --separate-stderr sesh auth
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"TOTP required"* ]]
}

@test "the tenth failure creates otp-locked, which blocks even a valid lease (3)" {
  local i
  for i in $(seq 1 9); do printf '%s\n' $((SESH_NOW - 5000 - i)) >> "$(fails_file)"; done
  run with_tty 000001 --key t auth
  [ "$status" -eq 4 ]
  [ -e "$SESH_HOME/otp-locked" ]
  mk_lease t -
  run --separate-stderr sesh unlock api
  [ "$status" -eq 3 ]
  [ "$stderr" = "sesh: OTP locked after repeated failures; root must remove $SESH_HOME/otp-locked" ]
  [ "$(locked_flag api)" = 1 ]
  [ "$(audit_field detail)" = otp-locked ]
}

@test "the secret never appears on oathtool's command line" {
  run with_tty "$(code_for_step "$(now_step)")" --key t auth
  [ "$status" -eq 0 ]
  run grep -c JBSWY3DPEHPK3PXP "$OATH_STUB_LOG"
  [ "$output" = 0 ]
  grep -q -- '--totp -b -N @' "$OATH_STUB_LOG"
}

@test "missing totp.secret is exit 1 and not counted as a failure" {
  rm "$SESH_HOME/totp.secret"
  run with_tty 666666 --key t auth
  [ "$status" -eq 1 ]
  [[ "$(strip_cr "$output")" == *"TOTP not configured"* ]]
  [ ! -s "$(fails_file)" ]
}

@test "the gate lock is released after a failure" {
  run with_tty 000001 --key t auth
  [ "$status" -eq 4 ]
  run flock -n "$SESH_HOME/gate.lock" true
  [ "$status" -eq 0 ]
}

@test "concurrent gated calls serialise on gate.lock" {
  mk_lease t -
  ( flock "$SESH_HOME/gate.lock" sleep 2 ) 3>&- &
  sleep 0.3
  local t0 t1
  t0=$(date +%s%N)
  run sesh unlock api
  t1=$(date +%s%N)
  wait
  [ "$status" -eq 0 ]
  [ $(( (t1 - t0) / 1000000 )) -ge 1400 ]
}

@test "unlock: missing session (5), tombstone name (2), already unlocked is fine (0)" {
  mk_lease t -
  run sesh unlock nosuch
  [ "$status" -eq 5 ]
  run sesh unlock 'zz~api~1'
  [ "$status" -eq 2 ]
  tm set-option -t '=api:' -u @sesh_locked
  run sesh unlock api
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Append this test to `tests/bats/broker-remote.bats`**

```bash
@test "remote: a lease is bound to key id and client IP" {
  rtm new-session -d -s api
  rtm set-option -t '=api:' @sesh_locked 1
  printf '%s\n' "$(date +%s)" > /home/claude/.sesh/leases/laptop@203.0.113.9
  run remote 198.51.100.7 laptop 'unlock api'
  [ "$status" -eq 4 ]
  run remote 203.0.113.9 other 'unlock api'
  [ "$status" -eq 4 ]
  run remote 203.0.113.9 laptop 'unlock api'
  [ "$status" -eq 0 ]
  [ -z "$(rtm display-message -p -t '=api:' '#{@sesh_locked}')" ]
}
```

- [ ] **Step 3: Run to see them fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-gate.bats`
Expected: failures with `unknown verb` for `auth`/`unlock`.

- [ ] **Step 4: Implement `lease_valid`, `gate`, `verb_auth`, `verb_unlock`.**

- [ ] **Step 5: Run until green, then the whole suite**

Expected: `broker-gate.bats` 21 tests, 0 failures; `broker-remote.bats` 9 tests, 0 failures; then `-Path tests/bats` gives 0 failures.
If `with_tty` tests fail because the code is not received, report the raw output rather than changing `helpers.bash`.

- [ ] **Step 6: Line endings, commit**

```
grep -lU "$(printf '\r')" vps/sesh tests/bats/broker-gate.bats tests/bats/broker-remote.bats   # must print nothing
git add vps/sesh tests/bats/broker-gate.bats tests/bats/broker-remote.bats
git commit -m "Broker: TOTP gate with lease, cooldown, lockout and replay guard; auth and unlock"
```

---

### Task 7: Broker `new`, `send`, `go`

**Model:** Sonnet. **Depends on:** Task 6.

**Files:**
- Modify: `vps/sesh`. Add `redact_url`, `session_using_dir`, `verb_new`, `verb_send`, `verb_go`.
- Create: `tests/bats/broker-new-send-go.bats`

**Interfaces:**
- Consumes (same file): `WORK_DIR`, `TMUX_SOCK`, `SEND_MAX_BYTES`, `SEND_ENTER_DELAY`, `SESSION`; `fail`, `succeed`, `audit`, `authorize` (gates `new`, `send`, `go`), `require_name`, `session_exists`, `newest_tombstone`, `tmx`, `tmux_on`, `has_ctrl`, `byte_len`, `safe`. Helpers: `setup_local`, `teardown_local`, `sesh`, `tm`, `mk_session`, `mk_session_cmd`, `session_names`, `mk_lease`, `wait_for_pane_line`, `wait_for_pane_contains`, `wait_for_clients`, `_poll`, `audit_field`, `b64`, `b64cmd`, `SESH_BIN`.
- Produces, for Tasks 8-9:
  - `session_using_dir DIR`: prints the name of the first session (tombstones included) whose `#{session_path}` equals DIR exactly, or nothing.
  - `redact_url STRING`: replaces every `scheme://userinfo@` with `scheme://***@`.

**Behaviour (spec 6, plan Q7, Q15):**
- `new <name> [--repo <url>]`. Options may come before or after the name. There is exactly one positional argument, and `--repo` needs a value; anything else is usage (2).
  1. `require_name`. If `--repo` is given, it must match `^https://[!-~]+$` (printable ASCII, no spaces), else fail `2 --repo must be an https:// URL`.
  2. `authorize`.
  3. Fail `3 <name> already exists` if `session_exists`.
  4. If `newest_tombstone` prints anything, fail `3 a tombstone of <name> exists; use sesh restore <name>`.
  5. `dir=$WORK_DIR/<name>`. If `session_using_dir "$dir"` prints a session, fail `3 directory <dir> already in use by session <s>`.
  6. With `--repo`, if `dir` exists, print `note: <dir> exists; skipping clone`. Otherwise run `mkdir -p "$WORK_DIR"` and capture git's output: `err=$(GIT_TERMINAL_PROMPT=0 git clone -q -- "$url" "$dir" 2>&1 >/dev/null)`. On failure, fail `1 git clone failed: <safe(redact_url(last non-empty line of err))>`; nothing of git's own output reaches stderr. Without `--repo`, `mkdir -p "$dir"`.
  7. `tmx new-session -d -s "$name" -c "$dir"`, then `tmux_on "$name" send-keys -l -- claude` and `tmux_on "$name" send-keys Enter`. On a tmux failure, fail 1.
  8. Print `created <name> in <dir>`, then `succeed "created dir=<dir>"`, adding ` repo=$(redact_url "$url")` when a repo was given.

  `redact_url` fragment: `printf '%s' "$1" | sed -E 's#([a-z]+://)[^/@[:space:]]*@#\1***@#g'`.
- `send <name> [text...]`. The first argument is the name; all remaining arguments are the text, joined by single spaces (`local IFS=' '; text="${*:2}"` inside the verb). Options are **not** parsed, so `send api -n` sends the text `-n`.
  1. `require_name`. Empty text: fail `2 nothing to send`. `has_ctrl`: fail `2 text contains control characters`. `byte_len > SEND_MAX_BYTES`: fail `2 text longer than 8000 bytes`.
  2. `authorize`; exists or 5.
  3. `tmux_on "$name" send-keys -l -- "$text"`; `sleep "$SEND_ENTER_DELAY"`; `tmux_on "$name" send-keys Enter`. The `--` is essential: without it, text that starts with `-` is parsed as tmux flags. `-l` stops key-name lookup, so `C-c` is typed as three characters.
  4. Print `sent <bytes> bytes to <name>`; `succeed "len:<bytes>"`. The text never goes to the audit log or stderr.
- `go <name>`. Exactly one argument; `require_name` (tombstones get 2); `authorize`; exists or 5. Then `[[ -t 0 && -t 1 ]]`, else fail `4 go needs a terminal`. The TTY check comes **after** the existence check (Q7). Then `audit true attached` and exec tmux. This is the one documented place a tmux target is written outside `tmux_on`, because `exec` cannot run a shell function:

  ```bash
  exec env -u SSH_ORIGINAL_COMMAND -u SSH_CLIENT -u SSH_CONNECTION -u SSH_TTY LANG=C.UTF-8 \
    tmux -u -S "$TMUX_SOCK" attach-session -d -t "=$name:"
  ```

- [ ] **Step 1: Write the failing test `tests/bats/broker-new-send-go.bats`**

```bash
#!/usr/bin/env bats
# new, send and go (spec 6). A valid lease exists unless a test removes it.
load helpers
setup() { setup_local; mk_lease t -; }
teardown() { teardown_local; }

no_lease() { rm -f "$SESH_HOME"/leases/*; }

# ---- new ----
@test "new creates the session in the work dir and starts claude" {
  run sesh new api
  [ "$status" -eq 0 ]
  [ "$output" = "created api in $SESH_WORK/api" ]
  [ -d "$SESH_WORK/api" ]
  [ "$(tm display-message -p -t '=api:' '#{session_path}')" = "$SESH_WORK/api" ]
  wait_for_pane_contains api claude
  [ "$(audit_field verb)" = new ]
  [ "$(audit_field session)" = api ]
  [ "$(audit_field detail)" = "created dir=$SESH_WORK/api" ]
}

@test "new refuses a live duplicate (3)" {
  mk_session api
  run sesh new api
  [ "$status" -eq 3 ]
}

@test "new refuses while a tombstone of that name exists (3)" {
  mk_session 'zz~api~1789990000'
  run --separate-stderr sesh new api
  [ "$status" -eq 3 ]
  [[ "$stderr" == *restore* ]]
}

@test "new refuses a directory another session already uses (3)" {
  mkdir -p "$SESH_WORK/api"
  mk_session web "$SESH_WORK/api"
  run --separate-stderr sesh new api
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"in use"* ]]
  [ "$(session_names)" = web ]
}

@test "new validates the name (2) and creates nothing" {
  local n
  for n in 1kb Api 'zz~api~1' "$(printf 'a%.0s' $(seq 1 33))"; do
    run sesh new "$n"
    [ "$status" -eq 2 ] || { echo "name '$n' gave $status"; return 1; }
  done
  [ -z "$(session_names)" ]
}

@test "new without a lease and without a TTY is 4 and creates nothing" {
  no_lease
  run sesh new api
  [ "$status" -eq 4 ]
  [ ! -e "$SESH_WORK/api" ]
  [ -z "$(session_names)" ]
}

@test "--repo must be an https:// URL with a value (2)" {
  local u
  for u in http://example.com/x.git git@github.com:a/b.git 'https://' 'ext::sh -c x' 'file:///etc'; do
    run sesh new api --repo "$u"
    [ "$status" -eq 2 ] || { echo "url '$u' gave $status"; return 1; }
  done
  run sesh new api --repo
  [ "$status" -eq 2 ]
  [ -z "$(session_names)" ]
}

@test "--repo with an existing directory skips the clone; option order is free" {
  mkdir -p "$SESH_WORK/api"
  run sesh new api --repo https://127.0.0.1:9/x.git
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping clone"* ]]
  [[ "$output" == *"created api in $SESH_WORK/api"* ]]
  mkdir -p "$SESH_WORK/web"
  run sesh new --repo https://127.0.0.1:9/x.git web
  [ "$status" -eq 0 ]
}

@test "--repo credentials never reach the audit log" {
  mkdir -p "$SESH_WORK/api"
  run sesh new api --repo https://user:s3cret@127.0.0.1:9/x.git
  [ "$status" -eq 0 ]
  run grep -c s3cret "$SESH_AUDIT"
  [ "$output" = 0 ]
  [[ "$(audit_field detail)" == *'repo=https://***@127.0.0.1:9/x.git'* ]]
}

@test "a failed clone is exit 1 with one redacted stderr line and no session" {
  run --separate-stderr sesh new api --repo https://user:s3cret@127.0.0.1:9/nope.git
  [ "$status" -eq 1 ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  [[ "$stderr" == *"git clone failed"* ]]
  [[ "$stderr" != *s3cret* ]]
  [ -z "$(session_names)" ]
  [ "$(audit_field ok)" = false ]
}

@test "SSH variables do not leak into the tmux server; LANG is C.UTF-8" {
  SSH_CLIENT='198.51.100.7 1 22' SSH_CONNECTION='198.51.100.7 1 10.0.0.1 22' SSH_TTY=/dev/pts/9 run sesh new api
  [ "$status" -eq 0 ]
  run tm show-environment -g
  [[ "$output" != *SSH_CLIENT=* ]]
  [[ "$output" != *SSH_CONNECTION=* ]]
  [[ "$output" != *SSH_TTY=* ]]
  [ "$(tm show-environment -g LANG)" = LANG=C.UTF-8 ]
}

@test "the tmux server does not inherit the gate lock" {
  run sesh new api
  [ "$status" -eq 0 ]
  run flock -n "$SESH_HOME/gate.lock" true
  [ "$status" -eq 0 ]
}

@test "after the server dies leaving a stale socket, ls is empty and new works (Review Focus 4)" {
  mk_session old
  kill -9 "$(tm display-message -p '#{pid}')"
  sleep 0.3
  [ -S "$SESH_TMUX_SOCKET" ]
  run sesh ls --names
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run sesh new api
  [ "$status" -eq 0 ]
  [ "$(session_names)" = api ]
}

# ---- send ----
@test "send types the text and presses Enter" {
  mk_session api
  run sesh send api echo hello-sesh
  [ "$status" -eq 0 ]
  [ "$output" = "sent 16 bytes to api" ]
  wait_for_pane_line api hello-sesh
}

@test "send passes shell metacharacters through unchanged" {
  mk_session api
  run sesh $(b64cmd send api "echo 'semi;colon #hash \$HOME'")
  [ "$status" -eq 0 ]
  wait_for_pane_line api 'semi;colon #hash $HOME'
}

@test "send types tmux key names and dash words literally (Review Focus 2)" {
  mk_session api
  run sesh send api echo C-c Enter -l
  [ "$status" -eq 0 ]
  wait_for_pane_line api 'C-c Enter -l'
  run sesh send api -n
  [ "$status" -eq 0 ]
  wait_for_pane_contains api '-n: command not found'
}

@test "send rejects control characters (2)" {
  mk_session api
  local c
  for c in $'\t' $'\n' $'\r' $'\e' $'\x7f' $'\x01'; do
    run sesh b64 "$(b64 send)" "$(b64 api)" "$(b64 "a${c}b")"
    [ "$status" -eq 2 ] || { echo "char $(printf %q "$c") gave $status"; return 1; }
  done
}

@test "send enforces SEND_MAX_BYTES in bytes, not characters (Review Focus 3)" {
  mk_session_cmd api 'exec cat >/dev/null'
  local a8000 e4000
  a8000=$(printf 'a%.0s' $(seq 1 8000))
  e4000=$(printf '\xc3\xa9%.0s' $(seq 1 4000))
  run sesh b64 "$(b64 send)" "$(b64 api)" "$(b64 "$a8000")"
  [ "$status" -eq 0 ]
  [ "$(audit_field detail)" = len:8000 ]
  run sesh b64 "$(b64 send)" "$(b64 api)" "$(b64 "${a8000}a")"
  [ "$status" -eq 2 ]
  run sesh b64 "$(b64 send)" "$(b64 api)" "$(b64 "$e4000")"
  [ "$status" -eq 0 ]
  run sesh b64 "$(b64 send)" "$(b64 api)" "$(b64 "${e4000}"$'\xc3\xa9')"
  [ "$status" -eq 2 ]
}

@test "send audits the byte length, never the text" {
  mk_session api
  run sesh send api echo secret-text
  [ "$status" -eq 0 ]
  [ "$(audit_field detail)" = len:16 ]
  run grep -c secret-text "$SESH_AUDIT"
  [ "$output" = 0 ]
}

@test "send: missing text or name (2), tombstone (2), missing session (5), no lease (4)" {
  mk_session api
  mk_session 'zz~api~1'
  run sesh send api
  [ "$status" -eq 2 ]
  run sesh send
  [ "$status" -eq 2 ]
  run sesh send 'zz~api~1' hi
  [ "$status" -eq 2 ]
  run sesh send nosuch hi
  [ "$status" -eq 5 ]
  no_lease
  run sesh send api hi
  [ "$status" -eq 4 ]
}

# ---- go ----
@test "go: a missing session is 5 even without a terminal" {
  run sesh go api
  [ "$status" -eq 5 ]
}

@test "go without a terminal is 4 once the session is found" {
  mk_session api
  run --separate-stderr sesh go api
  [ "$status" -eq 4 ]
  [[ "$stderr" == *terminal* ]]
}

@test "go rejects tombstone names (2)" {
  mk_session 'zz~api~1'
  run sesh go 'zz~api~1'
  [ "$status" -eq 2 ]
}

_only_client_other_than() {
  local c
  c=$(tm list-clients -t "=$1:" -F '#{client_tty}' 2>/dev/null)
  [ -n "$c" ] && [ "$(printf '%s\n' "$c" | wc -l)" -eq 1 ] && [ "$c" != "$2" ]
}

@test "go attaches with a terminal and detaches older clients (-d)" {
  mk_session api
  local cmd second tty1
  printf -v cmd '%q ' bash "$SESH_BIN" --key t go api
  { sleep 8; } | script -qec "$cmd" /dev/null >/dev/null 2>&1 3>&- &
  wait_for_clients api 1
  tty1=$(tm list-clients -t '=api:' -F '#{client_tty}')
  { sleep 8; } | script -qec "$cmd" /dev/null >/dev/null 2>&1 3>&- &
  second=$!
  _poll 5 _only_client_other_than api "$tty1"
  [ "$(audit_field verb)" = go ]
  [ "$(audit_field detail)" = attached ]
  tm detach-client -s '=api:'
  wait "$second"
}
```

- [ ] **Step 2: Run to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-new-send-go.bats`
Expected: failures with `unknown verb` for `new`, `send`, `go`.

- [ ] **Step 3: Implement the three verbs and two helpers.**

- [ ] **Step 4: Run until green, then the whole suite**

Expected: 24 tests, 0 failures in this file; `-Path tests/bats` has 0 failures.
If the `go attaches` test is flaky after honest debugging (three consecutive runs), report the output rather than weakening or skipping it.

- [ ] **Step 5: Line endings, commit**

```
grep -lU "$(printf '\r')" vps/sesh tests/bats/broker-new-send-go.bats   # must print nothing
git add vps/sesh tests/bats/broker-new-send-go.bats
git commit -m "Broker: new (with https clone and redaction), literal send, go with -d"
```

---

### Task 8: Broker `rename`, `rm`, `restore`

**Model:** Sonnet. **Depends on:** Task 7.

**Files:**
- Modify: `vps/sesh`. Add `verb_rename`, `verb_rm`, `verb_restore`.
- Create: `tests/bats/broker-lifecycle.bats`

**Interfaces:**
- Consumes (same file): `NOW`, `SESSION`; `fail`, `succeed`, `authorize` (gates `rename` and `rm`; `restore` is open), `require_name`, `require_name_or_tombstone`, `valid_name`, `valid_tombstone`, `session_exists`, `session_locked`, `newest_tombstone`, `tmux_on`, `safe`. Helpers: `setup_local`, `teardown_local`, `sesh`, `tm`, `mk_session`, `mk_session_cmd`, `session_names`, `mk_lease`, `audit_field`.
- Produces: nothing new for later tasks beyond the verbs.

**Behaviour (spec 6, 7.2, plan Q7, Q15):**
- `rename <old> <new>`. Exactly two arguments, else 2.
  1. `require_name old` (tombstones get 2). `new` must pass `valid_name`, else fail `2 invalid session name: <safe new>`.
  2. `authorize`.
  3. Old must exist, else 5. Fail `3 <new> already exists` if `session_exists new`. Fail `3 a tombstone of <new> exists` if `newest_tombstone new` prints anything.
  4. `tmux_on old rename-session "$new"`. Print `renamed <old> to <new>`; `succeed "to <new>"`. The work directory is **not** moved, because Claude Code keys its history by path.
- `rm <name> [--now --confirm <name>]`. Options may appear anywhere after the verb. `--confirm` needs a value. There is exactly one positional argument. Unknown `--options` are usage (2).
  1. `--confirm` without `--now`: fail `2 --confirm needs --now`.
  2. Without `--now`, run `require_name` (tombstones get 2). With `--now`, run `require_name_or_tombstone`, and the `--confirm` value must equal the name exactly, else fail `2 --confirm must equal <name>`.
  3. `authorize`.
  4. Without `--now`: the session must exist, else 5. Fail `3 session <name> is locked` if `session_locked`. Rename it to `zz~<name>~$NOW` with `tmux_on`; nothing inside the session is touched. Print exactly `tombstoned <name>; still running, reaped in 24h; restore with: sesh restore <name>`, then `succeed tombstoned`.
  5. With `--now`, the target is chosen as follows:
     - If `session_exists name`, the target is `name`. This also covers a full tombstone name.
     - Otherwise, if `valid_name name` and `newest_tombstone name` prints something, the target is that tombstone.
     - Otherwise, fail `5 no such session: <name>`.

     Refuse `3` if `session_locked target`. Then `tmux_on target kill-session`, print `killed <target>`, and `succeed "killed <target>"`.
- `restore <name>`. Exactly one argument; `require_name` (tombstone input gets 2); `authorize` (a no-op).
  1. `tomb=$(newest_tombstone name)`; if empty, fail `5 no tombstone for <name>`.
  2. Fail `3 <name> already exists` if `session_exists name`.
  3. `tmux_on "$tomb" rename-session "$name"`. Print `restored <name>`; `succeed "restored from <tomb>"`.

- [ ] **Step 1: Write the failing test `tests/bats/broker-lifecycle.bats`**

```bash
#!/usr/bin/env bats
# rename, rm (soft and --now) and restore (spec 6, 7.2).
load helpers
setup() { setup_local; mk_lease t -; }
teardown() { teardown_local; }

no_lease() { rm -f "$SESH_HOME"/leases/*; }
pane_pid() { tm display-message -p -t "=$1:" '#{pane_pid}'; }

# ---- rename ----
@test "rename keeps the work directory and the processes" {
  mkdir -p "$SESH_WORK/api"
  mk_session api "$SESH_WORK/api"
  local pid
  pid=$(pane_pid api)
  run sesh rename api web
  [ "$status" -eq 0 ]
  [ "$output" = "renamed api to web" ]
  [ "$(session_names)" = web ]
  [ "$(tm display-message -p -t '=web:' '#{session_path}')" = "$SESH_WORK/api" ]
  [ "$(pane_pid web)" = "$pid" ]
  [ -d "$SESH_WORK/api" ]
  [ ! -e "$SESH_WORK/web" ]
}

@test "after a rename, new with the old name is refused: directory in use (3)" {
  mkdir -p "$SESH_WORK/api"
  mk_session api "$SESH_WORK/api"
  sesh rename api web
  run --separate-stderr sesh new api
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"in use"* ]]
}

@test "rename refuses a live or tombstoned target name (3)" {
  mk_session api
  mk_session web
  mk_session 'zz~old~1789990000'
  run sesh rename api web
  [ "$status" -eq 3 ]
  run sesh rename api old
  [ "$status" -eq 3 ]
  [ "$(session_names | sort | tr '\n' ' ')" = "api web zz~old~1789990000 " ]
}

@test "rename: missing source (5), bad names (2), wrong arity (2), no lease (4)" {
  mk_session api
  run sesh rename nosuch web
  [ "$status" -eq 5 ]
  run sesh rename api 1web
  [ "$status" -eq 2 ]
  run sesh rename 'zz~api~1' web
  [ "$status" -eq 2 ]
  run sesh rename api
  [ "$status" -eq 2 ]
  run sesh rename api web extra
  [ "$status" -eq 2 ]
  no_lease
  run sesh rename api web
  [ "$status" -eq 4 ]
}

# ---- rm ----
@test "rm tombstones the session and leaves its process running" {
  mk_session_cmd api 'exec sleep 300'
  local pid
  pid=$(pane_pid api)
  run sesh rm api
  [ "$status" -eq 0 ]
  [ "$output" = "tombstoned api; still running, reaped in 24h; restore with: sesh restore api" ]
  [ "$(session_names)" = "zz~api~$SESH_NOW" ]
  kill -0 "$pid"
  [ "$(audit_field detail)" = tombstoned ]
  [ "$(audit_field session)" = api ]
}

@test "rm refuses a locked session, with or without --now (3)" {
  mk_session api
  tm set-option -t '=api:' @sesh_locked 1
  run --separate-stderr sesh rm api
  [ "$status" -eq 3 ]
  [[ "$stderr" == *locked* ]]
  run sesh rm api --now --confirm api
  [ "$status" -eq 3 ]
  [ "$(session_names)" = api ]
}

@test "rm --now needs --confirm equal to the name (2)" {
  mk_session api
  run sesh rm api --now
  [ "$status" -eq 2 ]
  run sesh rm api --now --confirm apix
  [ "$status" -eq 2 ]
  run sesh rm api --now --confirm
  [ "$status" -eq 2 ]
  run sesh rm api --confirm api
  [ "$status" -eq 2 ]
  [ "$(session_names)" = api ]
}

@test "rm --now kills a live session; option order is free" {
  mk_session api
  mk_session web
  run sesh rm api --now --confirm api
  [ "$status" -eq 0 ]
  [ "$output" = "killed api" ]
  run sesh rm --now --confirm web web
  [ "$status" -eq 0 ]
  [ -z "$(session_names)" ]
}

@test "rm --now <base> kills only the newest tombstone" {
  mk_session 'zz~api~1789990000'
  mk_session 'zz~api~1789995000'
  run sesh rm api --now --confirm api
  [ "$status" -eq 0 ]
  [ "$output" = "killed zz~api~1789995000" ]
  [ "$(session_names)" = 'zz~api~1789990000' ]
}

@test "rm --now <tombstone> kills that tombstone" {
  mk_session 'zz~api~1789990000'
  run sesh rm 'zz~api~1789990000' --now --confirm 'zz~api~1789990000'
  [ "$status" -eq 0 ]
  [ -z "$(session_names)" ]
}

@test "rm without --now rejects a tombstone name (2)" {
  mk_session 'zz~api~1789990000'
  run sesh rm 'zz~api~1789990000'
  [ "$status" -eq 2 ]
}

@test "rm: missing session (5) with and without --now; no lease (4)" {
  run sesh rm api
  [ "$status" -eq 5 ]
  run sesh rm api --now --confirm api
  [ "$status" -eq 5 ]
  mk_session api
  no_lease
  run sesh rm api
  [ "$status" -eq 4 ]
  [ "$(session_names)" = api ]
}

# ---- restore ----
@test "rm then restore round-trips the same running session, without a lease" {
  mk_session_cmd api 'exec sleep 300'
  local pid
  pid=$(pane_pid api)
  sesh rm api
  no_lease
  run sesh restore api
  [ "$status" -eq 0 ]
  [ "$output" = "restored api" ]
  [ "$(session_names)" = api ]
  [ "$(pane_pid api)" = "$pid" ]
  [ "$(audit_field detail)" = "restored from zz~api~$SESH_NOW" ]
}

@test "restore picks the greatest epoch" {
  mk_session_cmd 'zz~api~1789990000' 'exec sleep 300'
  mk_session_cmd 'zz~api~1789995000' 'exec sleep 301'
  run sesh restore api
  [ "$status" -eq 0 ]
  [ "$(session_names | sort | tr '\n' ' ')" = "api zz~api~1789990000 " ]
}

@test "restore: no tombstone (5), live name exists (3), tombstone name as input (2)" {
  run sesh restore api
  [ "$status" -eq 5 ]
  mk_session api
  mk_session 'zz~api~1789990000'
  run sesh restore api
  [ "$status" -eq 3 ]
  run sesh restore 'zz~api~1789990000'
  [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/broker-lifecycle.bats`
Expected: failures with `unknown verb`.

- [ ] **Step 3: Implement the three verbs.**

- [ ] **Step 4: Run until green, then the whole suite**

Expected: 15 tests, 0 failures; `-Path tests/bats` 0 failures.

- [ ] **Step 5: Line endings, commit**

```
grep -lU "$(printf '\r')" vps/sesh tests/bats/broker-lifecycle.bats   # must print nothing
git add vps/sesh tests/bats/broker-lifecycle.bats
git commit -m "Broker: rename, soft rm with tombstones, rm --now with confirmation, restore"
```

---

### Task 9: Broker `resume`, `reap`, and cross-verb sweeps

**Model:** Sonnet. **Depends on:** Task 8.

**Files:**
- Modify: `vps/sesh`. Add `verb_resume`, `verb_reap`.
- Create: `tests/bats/broker-resume-reap.bats`
- Create: `tests/bats/broker-exact.bats`
- Modify: `tests/bats/broker-remote.bats` (append one test)
- Modify: `tests/bats/lint.bats`. Remove the temporary `-e SC2034`.

**Interfaces:**
- Consumes (same file): `WORK_DIR`, `NOW`, `TOMBSTONE_TTL`, `REAP_RE`, `SEND_ENTER_DELAY`, `SESSION`; `fail`, `succeed`, `audit`, `authorize`, `require_name`, `session_exists`, `newest_tombstone`, `session_using_dir`, `list_sessions`, `tmx`, `tmux_on`, `safe`. Helpers: everything in `helpers.bash`, including `_poll`, `wait_for_cmd`, `rtm`, `remote`, `b64cmd`.
- Produces: the finished broker. Every name in `GATED_VERBS` and every open verb is implemented.

**Behaviour (spec 6, 8, 11, plan Q5, Q15):**
- `resume <name>`. Exactly one argument; `require_name`; `authorize`.
  - If `session_exists`, read `cmd=$(tmux_on "$name" display-message -p '#{pane_current_command}')`.
    - If `cmd` is one of `bash sh zsh dash`: `tmux_on "$name" send-keys -l -- 'claude --continue'`; `sleep "$SEND_ENTER_DELAY"`; `tmux_on "$name" send-keys Enter`; print `resumed <name>`; `succeed resumed`.
    - Otherwise fail `3 pane busy (<safe cmd>)`.
  - Else, if `$WORK_DIR/<name>` is a directory:
    - If `newest_tombstone` prints anything, fail `3 tombstone of <name> exists; use sesh restore <name>` (Q5).
    - If `session_using_dir` prints a session, fail `3 directory <dir> already in use by session <s>` (Q5).
    - Otherwise, `tmx new-session -d -s "$name" -c "$dir"`, send `claude --continue` plus Enter as above, print `recreated <name>`, and `succeed recreated`.
  - Otherwise fail `5 nothing to resume for <name>`.
- `reap`. No arguments (else 2); `authorize` (a no-op). `main` has already refused remote calls.
  - For each name from `list_sessions` matching `REAP_RE`, with epoch `E=${BASH_REMATCH[1]}` and `NOW - E > TOMBSTONE_TTL` (strictly older):
    - Set `SESSION=<name>`.
    - If `tmux_on "$name" kill-session` succeeds, print `reaped <name>` and `audit true reaped`.
    - Otherwise print `sesh: reap failed: <name>` to stderr, `audit false "reap failed"`, and remember the failure.
  - Do **not** use `fail` or `succeed` inside the loop: one failure must not stop the others (spec 11).
  - Exit 1 if any kill failed, else 0.
  - No server, or nothing old: exit 0 and write no audit line (Q15).
  - `reap` must never start a tmux server. `list-sessions` does not start one. This matters because the reaper runs as a `Type=oneshot` systemd unit, and any server it started would be killed with the unit.
- `tests/bats/lint.bats`: change `shellcheck -S warning -e SC2034 "$SESH_BIN"` to `shellcheck -S warning "$SESH_BIN"`. Every constant is now used; `SESH_VERSION` keeps its own directive line. Rename that test to `broker passes bash -n and shellcheck -S warning with no exclusions`.

- [ ] **Step 1: Write the failing test `tests/bats/broker-resume-reap.bats`**

```bash
#!/usr/bin/env bats
# resume and reap (spec 6, 8, 11).
load helpers
setup() { setup_local; mk_lease t -; }
teardown() { teardown_local; }

no_lease() { rm -f "$SESH_HOME"/leases/*; }

# ---- resume ----
@test "resume on an idle shell sends claude --continue" {
  mkdir -p "$SESH_WORK/api"
  mk_session api "$SESH_WORK/api"
  wait_for_cmd api bash
  run sesh resume api
  [ "$status" -eq 0 ]
  [ "$output" = "resumed api" ]
  wait_for_pane_contains api 'claude --continue'
  [ "$(audit_field detail)" = resumed ]
}

@test "resume refuses a busy pane (3) and names the command" {
  mk_session api
  wait_for_cmd api bash
  tm send-keys -t '=api:' 'sleep 30' Enter
  wait_for_cmd api sleep
  run --separate-stderr sesh resume api
  [ "$status" -eq 3 ]
  [ "$stderr" = "sesh: pane busy (sleep)" ]
}

@test "resume recreates a missing session from its work directory" {
  mkdir -p "$SESH_WORK/api"
  run sesh resume api
  [ "$status" -eq 0 ]
  [ "$output" = "recreated api" ]
  [ "$(tm display-message -p -t '=api:' '#{session_path}')" = "$SESH_WORK/api" ]
  wait_for_pane_contains api 'claude --continue'
  [ "$(audit_field detail)" = recreated ]
}

@test "resume will not recreate beside a tombstone of the same name (3, plan Q5)" {
  mkdir -p "$SESH_WORK/api"
  mk_session 'zz~api~1789990000'
  run --separate-stderr sesh resume api
  [ "$status" -eq 3 ]
  [[ "$stderr" == *restore* ]]
  [ "$(session_names)" = 'zz~api~1789990000' ]
}

@test "resume will not recreate into a directory another session uses (3, plan Q5)" {
  mkdir -p "$SESH_WORK/api"
  mk_session web "$SESH_WORK/api"
  run sesh resume api
  [ "$status" -eq 3 ]
  [ "$(session_names)" = web ]
}

@test "resume: nothing to resume (5), tombstone name (2), no lease (4)" {
  run sesh resume api
  [ "$status" -eq 5 ]
  run sesh resume 'zz~api~1'
  [ "$status" -eq 2 ]
  mkdir -p "$SESH_WORK/api"
  no_lease
  run sesh resume api
  [ "$status" -eq 4 ]
  [ -z "$(session_names)" ]
}

# ---- reap ----
@test "reap kills only tombstones strictly older than TOMBSTONE_TTL" {
  mk_session "zz~old~$((SESH_NOW - 86401))"
  mk_session "zz~edge~$((SESH_NOW - 86400))"
  mk_session "zz~new~$((SESH_NOW - 100))"
  mk_session live
  mk_session zz-x
  run sesh_key reaper reap
  [ "$status" -eq 0 ]
  [ "$output" = "reaped zz~old~$((SESH_NOW - 86401))" ]
  [ "$(session_names | sort | tr '\n' ' ')" = "live zz-x zz~edge~$((SESH_NOW - 86400)) zz~new~$((SESH_NOW - 100)) " ]
  [ "$(audit_count)" -eq 1 ]
  [ "$(audit_field verb)" = reap ]
  [ "$(audit_field key)" = reaper ]
  [ "$(audit_field session)" = "zz~old~$((SESH_NOW - 86401))" ]
  [ "$(audit_field detail)" = reaped ]
}

@test "reap with no tmux server is a silent no-op (0)" {
  run sesh_key reaper reap
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(audit_count)" -eq 0 ]
}

@test "reap with nothing old writes no audit line" {
  mk_session "zz~new~$((SESH_NOW - 100))"
  run sesh_key reaper reap
  [ "$status" -eq 0 ]
  [ "$(audit_count)" -eq 0 ]
}

@test "reap needs no lease and takes no arguments" {
  no_lease
  run sesh_key reaper reap
  [ "$status" -eq 0 ]
  run sesh_key reaper reap extra
  [ "$status" -eq 2 ]
}

@test "one failed kill does not stop the others; exit 1 and both audited" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/tmux" <<'EOF'
#!/bin/bash
case " $* " in *" kill-session "*"=zz~bad~"*) echo "stub: refusing" >&2; exit 1 ;; esac
exec /usr/bin/tmux "$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
  mk_session "zz~bad~$((SESH_NOW - 90000))"
  mk_session "zz~good~$((SESH_NOW - 90000))"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run sesh_key reaper reap
  [ "$status" -eq 1 ]
  [ "$(session_names)" = "zz~bad~$((SESH_NOW - 90000))" ]
  [ "$(audit_count)" -eq 2 ]
  run jq -s -e 'map(.ok) | sort == [false, true]' "$SESH_AUDIT"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Write the failing test `tests/bats/broker-exact.bats`**

```bash
#!/usr/bin/env bats
# Cross-verb sweeps: exact targeting (spec 12.1), which verbs are gated (spec D3),
# and one audit line per exit class (spec 5.4, 7.3).
load helpers
setup() { setup_local; }
teardown() { teardown_local; }

@test "exact targeting: with api2 live and api absent, every verb on api is 5" {
  mk_lease t -
  mk_session_cmd api2 'echo marker2; exec sleep 300'
  wait_for_pane_line api2 marker2
  local line
  local -a cmd
  while IFS= read -r line; do
    read -r -a cmd <<<"$line"
    run sesh "${cmd[@]}"
    [ "$status" -eq 5 ] || { echo "sesh $line gave $status"; return 1; }
  done <<'EOF'
peek api
go api
send api hello
rename api other
lock api
unlock api
rm api
rm api --now --confirm api
restore api
resume api
EOF
  [ "$(session_names)" = api2 ]
  [ -z "$(locked_flag api2)" ]
  run sesh peek api2
  [ "$output" = marker2 ]
}

@test "exact targeting: a session named bash, not a window named bash elsewhere" {
  mk_lease t -
  mk_session other
  tm rename-window -t '=other:' bash
  mk_session bash
  wait_for_cmd bash bash
  run sesh send bash echo only-in-bash
  [ "$status" -eq 0 ]
  wait_for_pane_line bash only-in-bash
  run tm capture-pane -p -t '=other:'
  [[ "$output" != *only-in-bash* ]]
  run sesh peek bash
  [[ "$output" == *only-in-bash* ]]
  run sesh lock bash
  [ "$(locked_flag bash)" = 1 ]
  [ -z "$(locked_flag other)" ]
}

@test "exactly the GATED_VERBS need a lease (spec D3)" {
  mk_session api
  mk_session 'zz~old~1789990000'
  mkdir -p "$SESH_WORK/api"
  local line
  local -a cmd
  while IFS= read -r line; do
    read -r -a cmd <<<"$line"
    run sesh "${cmd[@]}"
    [ "$status" -eq 4 ] || { echo "gated: sesh $line gave $status"; return 1; }
  done <<'EOF'
new fresh
go api
send api hi
rename api web
unlock api
rm api
resume api
auth
EOF
  while IFS= read -r line; do
    read -r -a cmd <<<"$line"
    run sesh "${cmd[@]}"
    [ "$status" -ne 4 ] || { echo "open: sesh $line was gated"; return 1; }
  done <<'EOF'
ls
peek api
log
lock api
restore old
EOF
}

@test "every exit class writes exactly one audit line with the right ok value" {
  mk_lease t -
  mk_session api
  tm set-option -t '=api:' @sesh_locked 1
  check() { # check STATUS OK ARGS...
    local want=$1 ok=$2 before
    shift 2
    before=$(audit_count)
    run sesh "$@"
    [ "$status" -eq "$want" ] || { echo "sesh $*: status $status, want $want"; return 1; }
    [ "$(audit_count)" -eq $((before + 1)) ] || { echo "sesh $*: audit line count"; return 1; }
    [ "$(audit_field ok)" = "$ok" ] || { echo "sesh $*: ok field"; return 1; }
  }
  check 0 true peek api
  check 2 false peek 1bad
  check 3 false rm api
  check 5 false peek nosuch
  check 1 false new web --repo https://127.0.0.1:9/nope.git
  rm -f "$SESH_HOME"/leases/*
  check 4 false unlock api
}
```

- [ ] **Step 3: Append this test to `tests/bats/broker-remote.bats`**

```bash
@test "remote: plain and b64 give identical ls --names and peek output" {
  rtm new-session -d -s alpha 'printf "a\nb\nc\n"; exec sleep 300'
  rtm new-session -d -s beta
  _poll 5 bash -c "tmux -S '$XDG_RUNTIME_DIR/sesh.sock' capture-pane -p -t '=alpha:' | grep -qx c"
  run remote 203.0.113.9 laptop 'ls --names'
  local plain=$output
  run remote 203.0.113.9 laptop "$(b64cmd ls --names)"
  [ "$output" = "$plain" ]
  [ "$plain" = $'alpha\nbeta' ]
  run remote 203.0.113.9 laptop 'peek alpha -n 2'
  plain=$output
  run remote 203.0.113.9 laptop "$(b64cmd peek alpha -n 2)"
  [ "$output" = "$plain" ]
  [ "$plain" = $'b\nc' ]
}
```

- [ ] **Step 4: Edit `tests/bats/lint.bats` as described in Behaviour.**

- [ ] **Step 5: Run to see the new tests fail**

Run with `-Path tests/bats/broker-resume-reap.bats`, then `broker-exact.bats`.
Expected: failures with `unknown verb` for `resume` and `reap`. The exact-targeting sweep fails on `resume api`.

- [ ] **Step 6: Implement `verb_resume` and `verb_reap`.**

- [ ] **Step 7: Run the whole bats suite**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1`
Expected: every file passes. In particular `broker-resume-reap.bats` 11, `broker-exact.bats` 4, `broker-remote.bats` 10, and `lint.bats` 6 (with shellcheck now run without exclusions).

- [ ] **Step 8: Line endings, commit**

```
grep -rlIU "$(printf '\r')" vps tests   # must print nothing
git add vps/sesh tests/bats/broker-resume-reap.bats tests/bats/broker-exact.bats tests/bats/broker-remote.bats tests/bats/lint.bats
git commit -m "Broker: resume (with recreate guards), reaper, exact-targeting and gating sweeps"
```

---

### Task 10: VPS configuration files (verbatim) and their tests

**Model:** Haiku (verbatim content; mechanical verification). **Depends on:** Task 7, because the tmux.conf test uses `sesh new`.

**Files:**
- Create: `vps/tmux.conf`
- Create: `vps/sshd-sesh.conf`
- Create: `vps/sudoers-claude`
- Create: `vps/systemd/sesh-reaper.service`
- Create: `vps/systemd/sesh-reaper.timer`
- Create: `tests/bats/config.bats`

**Interfaces:**
- Consumes: `helpers.bash` (`setup_local`, `teardown_local`, `sesh`, `tm`, `mk_lease`), `tests/run-bats.ps1`, and the broker's `new` verb (Task 7).
- Produces, for Task 11 (`sesh-setup`) and Task 14 (`deploy.ps1` staging): the five files at exactly these repo paths. In the staging folder they keep the same relative paths, with `vps/` dropped: `tmux.conf`, `sshd-sesh.conf`, `sudoers-claude`, `systemd/sesh-reaper.service`, `systemd/sesh-reaper.timer`.

**Rules for this task:** write each file exactly as shown, ending with a single newline. Use LF only and ASCII only. If any verification fails, **stop and report the full output**. Do not edit the files or the tests to make them pass.

- [ ] **Step 1: Create `vps/tmux.conf` (spec 8)**

```
# sesh: installed to /etc/sesh/tmux.conf by sesh-setup; passed with -f when the broker starts the server.
set -g default-terminal tmux-256color
set -s escape-time 10
set -g history-limit 50000
set -g set-titles off
```

- [ ] **Step 2: Create `vps/sshd-sesh.conf` (spec 4.2)**

```
# sesh: installed to /etc/ssh/sshd_config.d/sesh.conf by sesh-setup. Do not edit on the VPS.
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

- [ ] **Step 3: Create `vps/sudoers-claude` (spec 4.1)**

```
# sesh: installed to /etc/sudoers.d/claude (0440) by sesh-setup after visudo -cf.
claude ALL=(root) NOPASSWD: /usr/bin/apt-get update, /usr/bin/apt-get install *
claude ALL=(root) NOPASSWD: /usr/bin/systemctl restart *, /usr/bin/systemctl reload *, /usr/bin/systemctl status *
claude ALL=(root) NOPASSWD: /usr/bin/journalctl *
```

- [ ] **Step 4: Create `vps/systemd/sesh-reaper.service` (spec 8)**

```
[Unit]
Description=sesh: reap tombstoned tmux sessions older than 24h

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sesh --key reaper reap
```

- [ ] **Step 5: Create `vps/systemd/sesh-reaper.timer` (spec 8)**

```
[Unit]
Description=sesh: hourly tombstone reaper

[Timer]
OnCalendar=hourly
RandomizedDelaySec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 6: Create `tests/bats/config.bats`**

```bash
#!/usr/bin/env bats
# VPS configuration files checked against real sshd, visudo and tmux in the test image.
load helpers

setup() {
  cp /etc/ssh/sshd_config "$BATS_TEST_TMPDIR/sshd_config.orig"
  rm -f /etc/ssh/sshd_config.d/sesh.conf
}
teardown() {
  rm -f /etc/ssh/sshd_config.d/sesh.conf /etc/sesh/tmux.conf
  cp "$BATS_TEST_TMPDIR/sshd_config.orig" /etc/ssh/sshd_config
  teardown_local
}

effective() { /usr/sbin/sshd -T -C "user=$1,host=localhost,addr=127.0.0.1"; }

@test "sudoers-claude passes visudo -cf and holds the three spec rules" {
  run visudo -cf /src/vps/sudoers-claude
  [ "$status" -eq 0 ]
  grep -qxF 'claude ALL=(root) NOPASSWD: /usr/bin/apt-get update, /usr/bin/apt-get install *' /src/vps/sudoers-claude
  grep -qxF 'claude ALL=(root) NOPASSWD: /usr/bin/systemctl restart *, /usr/bin/systemctl reload *, /usr/bin/systemctl status *' /src/vps/sudoers-claude
  grep -qxF 'claude ALL=(root) NOPASSWD: /usr/bin/journalctl *' /src/vps/sudoers-claude
}

@test "the sshd drop-in parses and applies its settings to user claude" {
  grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config
  cp /src/vps/sshd-sesh.conf /etc/ssh/sshd_config.d/sesh.conf
  run /usr/sbin/sshd -t
  [ "$status" -eq 0 ]
  run effective claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"authorizedkeysfile /etc/sesh/authorized_keys"* ]]
  [[ "$output" == *"passwordauthentication no"* ]]
  [[ "$output" == *"disableforwarding yes"* ]]
  [[ "$output" == *"permituserrc no"* ]]
  [[ "$output" == *"clientaliveinterval 30"* ]]
  [[ "$output" == *"clientalivecountmax 4"* ]]
}

@test "root's effective sshd config is unchanged by the drop-in" {
  run effective root
  local before=$output
  cp /src/vps/sshd-sesh.conf /etc/ssh/sshd_config.d/sesh.conf
  run effective root
  [ "$output" = "$before" ]
}

@test "the closing Match all keeps later main-config directives global" {
  # Debian's sshd_config sets X11Forwarding yes after its Include line.
  grep -q '^X11Forwarding yes' /etc/ssh/sshd_config
  cp /src/vps/sshd-sesh.conf /etc/ssh/sshd_config.d/sesh.conf
  run effective root
  [[ "$output" == *"x11forwarding yes"* ]]
  # Control: without Match all, sshd rejects the config or loses the directive for root.
  grep -v '^Match all' /src/vps/sshd-sesh.conf > /etc/ssh/sshd_config.d/sesh.conf
  run effective root
  [ "$status" -ne 0 ] || [[ "$output" == *"x11forwarding no"* ]]
}

@test "uncommenting the whole PermitRootLogin line hardens root over a later 'yes'" {
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  cp /src/vps/sshd-sesh.conf /etc/ssh/sshd_config.d/sesh.conf
  run effective root
  [[ "$output" == *"permitrootlogin yes"* ]]
  sed -E 's/^#[[:space:]]*PermitRootLogin prohibit-password.*/PermitRootLogin prohibit-password/' \
    /src/vps/sshd-sesh.conf > /etc/ssh/sshd_config.d/sesh.conf
  run /usr/sbin/sshd -t
  [ "$status" -eq 0 ]
  run effective root
  [[ "$output" == *"permitrootlogin without-password"* || "$output" == *"permitrootlogin prohibit-password"* ]]
}

@test "systemd units carry the spec values" {
  grep -qx 'Type=oneshot' /src/vps/systemd/sesh-reaper.service
  grep -qx 'ExecStart=/usr/local/bin/sesh --key reaper reap' /src/vps/systemd/sesh-reaper.service
  grep -qx 'OnCalendar=hourly' /src/vps/systemd/sesh-reaper.timer
  grep -qx 'RandomizedDelaySec=5min' /src/vps/systemd/sesh-reaper.timer
  grep -qx 'Persistent=true' /src/vps/systemd/sesh-reaper.timer
  grep -qx 'WantedBy=timers.target' /src/vps/systemd/sesh-reaper.timer
}

@test "the broker applies /etc/sesh/tmux.conf when it starts the server" {
  setup_local
  cp /src/vps/tmux.conf /etc/sesh/tmux.conf
  mk_lease t -
  run sesh new cfgtest
  [ "$status" -eq 0 ]
  [ "$(tm show-options -gv history-limit)" = 50000 ]
  [ "$(tm show-options -sv escape-time)" = 10 ]
  [ "$(tm show-options -gv default-terminal)" = tmux-256color ]
  [ "$(tm show-options -gv set-titles)" = off ]
}

@test "config files have no carriage returns" {
  run grep -l $'\r' /src/vps/tmux.conf /src/vps/sudoers-claude /src/vps/sshd-sesh.conf \
    /src/vps/systemd/sesh-reaper.service /src/vps/systemd/sesh-reaper.timer
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 7: Run the tests**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/config.bats`
Expected: `8 tests, 0 failures`. On any failure, stop and report the full output.

- [ ] **Step 8: Line endings, commit**

```
grep -rlIU "$(printf '\r')" vps tests   # must print nothing
git add vps/tmux.conf vps/sshd-sesh.conf vps/sudoers-claude vps/systemd/sesh-reaper.service vps/systemd/sesh-reaper.timer tests/bats/config.bats
git commit -m "Add VPS config files: tmux.conf, sshd drop-in, sudoers allowlist, reaper units"
```

---

### Task 11: `vps/sesh-setup`: the idempotent root installer

**Model:** Sonnet. Security-critical: the orchestrator should have Opus review this diff. **Depends on:** Task 10.

**Agents never run `main`.** Tests only `source` the script and call its pure or sshd-only functions inside the container.

**Files:**
- Create: `vps/sesh-setup` (executable)
- Create: `tests/bats/setup.bats`

**Interfaces:**
- Consumes: the staged file names from Task 10 and the broker (`sesh`), which deploy stages next to this script (Task 14). The broker contains a `SESH_VERSION=<value>` line.
- Produces:
  - Run: `bash /root/sesh-deploy-<ts>/sesh-setup --pubkey-file <path> [--key-id <id>] [--rotate-totp] [--harden-root] [--unlock-otp]`. Deploy runs it this way (Task 14). Exit 2 is usage, exit 1 is a preflight or step failure, exit 0 is success.
  - Staging layout it requires (relative to its own directory): `sesh`, `sshd-sesh.conf`, `sudoers-claude`, `tmux.conf`, `systemd/sesh-reaper.service`, `systemd/sesh-reaper.timer`. The pubkey path is given by `--pubkey-file`; `vps-facts.sh` may also be present and is unused.
  - Sourceable functions, used by the tests. They **return** non-zero with a message on stdout or stderr; they never `exit`. Only `main` and `die` exit.
    - `valid_key_id ID`
    - `read_pubkey FILE`: prints `ssh-ed25519 <base64>`.
    - `authorized_keys_line KEYID KEYLINE`
    - `render_authorized_keys EXISTING_FILE KEYID KEYLINE`
    - `render_dropin SRC HARDEN(0|1)`
    - `dropin_is_hardened FILE`
    - `want_harden FLAG(0|1)`: prints 0 or 1, reading `$SSHD_DROPIN`.
    - `sshd_effective USER`: sorted `sshd -T` output.
    - `sshd_diff_ok BEFORE_FILE AFTER_FILE HARDEN`
    - `install_sshd_dropin SRC HARDEN`: does not reload sshd.
    - `check_claude_sshd`
    - `sshd_has_include [MAIN]`
    - `allowusers_ok SSHD_T_TEXT`
    - `parse_kill_user_processes TEXT`: prints yes, no or unknown.
    - `tmux_version_ok "tmux X.Y"`
    - `attr_has_append LSATTR_LINE`
    - `has_cr FILE`
    - `ensure_path_snippet FILE`
    - `staged_files_ok DIR`: prints the missing names.
    - `main`
  - Globals at the top: `SSHD=/usr/sbin/sshd`, `SSHD_MAIN=/etc/ssh/sshd_config`, `SSHD_DROPIN=/etc/ssh/sshd_config.d/sesh.conf`, `BROKER_DEST=/usr/local/bin/sesh`, `SESH_ETC=/etc/sesh`, `SUDOERS_DEST=/etc/sudoers.d/claude`, `CLAUDE_USER=claude`, `CLAUDE_HOME=/home/claude`, `AUDIT_DIR=/var/log/sesh`.
  - Last line: `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi`. Do `set -u -o pipefail` inside `main`, not at file level, so sourcing does not change the test shell.

**Function behaviour:**
- `read_pubkey`: the file must hold exactly one non-empty line and no CR. That line must be `ssh-ed25519 <base64> [comment]` with no options prefix. Print the first two fields.
- `authorized_keys_line laptop 'ssh-ed25519 AAA'` prints exactly `restrict,pty,command="/usr/local/bin/sesh --key laptop" ssh-ed25519 AAA sesh-laptop` (spec 4.4, Q9).
- `render_authorized_keys`: prints the existing lines (the file may be missing), minus any line containing `command="/usr/local/bin/sesh --key <KEYID>"`, plus the new line, newline-terminated.
- `render_dropin SRC 1`: replaces the **whole** line matching `^#[[:space:]]*PermitRootLogin[[:space:]]+prohibit-password` with exactly `PermitRootLogin prohibit-password` (Q1a). With `0`, it prints SRC unchanged.
- `dropin_is_hardened FILE`: status 0 if FILE has a line exactly `PermitRootLogin prohibit-password`.
- `want_harden FLAG`: prints `1` if FLAG is 1 or `dropin_is_hardened "$SSHD_DROPIN"`, else `0` (sticky hardening, Q1).
- `sshd_effective USER`: `"$SSHD" -T -C "user=$USER,host=localhost,addr=127.0.0.1" | sort`.
- `sshd_diff_ok A B HARDEN`: status 0 if A and B are identical. With HARDEN=1, it is also 0 when every differing line starts with `permitrootlogin `. On failure it prints the differing lines.
- `install_sshd_dropin SRC HARDEN` (spec 4.2), in order:
  1. Save `sshd_effective root` to a temp file.
  2. Back up any existing `$SSHD_DROPIN`.
  3. Write `render_dropin SRC HARDEN` with `install -o root -g root -m 0644`.
  4. `"$SSHD" -t` must pass.
  5. `sshd_diff_ok before after HARDEN` must pass.
  6. If HARDEN=1, root's effective `permitrootlogin` must be `prohibit-password` or `without-password`. Otherwise print `permitrootlogin is still <value>: an earlier drop-in or the main config overrides it` (Q1b).
  7. `check_claude_sshd` must pass.

  On any failure, restore the backup, or remove the file if none existed, and return 1.
- `check_claude_sshd`: `sshd_effective claude` contains `authorizedkeysfile /etc/sesh/authorized_keys` and `passwordauthentication no`.
- `sshd_has_include [MAIN]`: MAIN has a line matching `^[[:space:]]*Include[[:space:]].*sshd_config\.d`.
- `allowusers_ok TEXT`: 0 if TEXT has no `allowusers` line, or some `allowusers` value is `claude`, `*`, or starts with `claude@`.
- `parse_kill_user_processes`: `b true` gives `yes`, `b false` gives `no`, and anything else gives `unknown`.
- `tmux_version_ok`: extract the first `N.N` number; status 0 if the major version is >= 3.
- `attr_has_append`: the first field (before the space) contains `a`.
- `ensure_path_snippet FILE`: if FILE lacks a `# >>> sesh path` line, append:

  ```bash
  # >>> sesh path
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
  # <<< sesh path
  ```

- `staged_files_ok DIR`: prints each missing required staged file; status 1 if any is missing.

**`main` behaviour (spec 10). Each failure prints one line `sesh-setup: <reason>` to stderr and exits 1 (2 for usage).**
1. Parse arguments. Unknown option, missing `--pubkey-file`, or a `--key-id` failing `valid_key_id`: exit 2 with `sesh-setup: usage: sesh-setup --pubkey-file <path> [--key-id <id>] [--rotate-totp] [--harden-root] [--unlock-otp]`. Parse **before** anything else.
2. Require EUID 0. Set `STAGE_DIR` to the directory of `${BASH_SOURCE[0]}`.
3. Preflight. Make no change before all of these pass:
   - `apt-get` exists.
   - `/run/systemd/system` exists and `loginctl --no-pager list-users` works.
   - `KillUserProcesses` is not `yes`. Check `parse_kill_user_processes` on `busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager KillUserProcesses`. If that prints `unknown`, take the last uncommented `KillUserProcesses=` value from `systemd-analyze cat-config systemd/logind.conf`.
   - `sshd_has_include`.
   - `"$SSHD" -T` shows `pubkeyauthentication yes`, and `allowusers_ok` passes.
   - `timedatectl show -p NTPSynchronized --value` is `yes`.
   - `chattr` and `lsattr` exist; otherwise fail with `chattr missing: apt-get install e2fsprogs, then re-run` (Q10). A `mktemp /var/log/sesh-setup-chattr.XXXXXX` file accepts `chattr +a` then `chattr -a`; remove it in all cases.
   - `staged_files_ok "$STAGE_DIR"`.
   - No staged file `has_cr`.
   - `read_pubkey "$PUBKEY_FILE"` succeeds.
4. Step 1. `DEBIAN_FRONTEND=noninteractive apt-get update`, then `apt-get install -y tmux oathtool jq qrencode e2fsprogs git curl util-linux`. Fail if `tmux_version_ok "$(tmux -V)"` fails. Fail if `printf JBSWY3DPEHPK3PXP | oathtool --totp -b -N @0 -` does not print six digits.
5. Step 2. If `claude` is missing, `useradd -m -s /bin/bash claude`. Then `usermod -p '*' claude`. If `getent group docker` succeeds, `usermod -aG docker claude`. Run `visudo -cf "$STAGE_DIR/sudoers-claude"`, then `install -o root -g root -m 0440` it to `/etc/sudoers.d/claude`.
6. Step 3:
   - `install -o root -g root -m 0755 "$STAGE_DIR/sesh" /usr/local/bin/sesh`.
   - `install -d -o root -g root -m 0755 /etc/sesh`, then install `tmux.conf` there with mode 0644.
   - Render `authorized_keys` to a temp file and install it as root 0644 at `/etc/sesh/authorized_keys`.
   - `HARDEN=$(want_harden <1 if --harden-root else 0>)`, then `install_sshd_dropin "$STAGE_DIR/sshd-sesh.conf" "$HARDEN"`, failing on error.
   - `systemctl reload ssh`.
7. Step 4:
   - `install -d -o claude -g claude -m 0700 /home/claude/.sesh`, then `chown -R claude:claude /home/claude/.sesh`. This repairs files a local root run of the broker may have created.
   - `install -d -o claude -g claude -m 0755 /home/claude/work`.
   - With `--unlock-otp`, remove `otp-locked`, truncate `otp-fails`, and keep it owned by claude.
8. Step 5. If `totp.secret` is missing or `--rotate-totp` was given:
   - Generate the secret: `head -c 20 /dev/urandom | base32 | tr -d '=\n'`.
   - Write it to `totp.secret` (owner claude, 0600; create the file with `install -o claude -g claude -m 0600 /dev/null` first, then write it).
   - Write `0` to `last-otp` (owner claude) and delete `leases/*`.
   - Print `otpauth://totp/sesh@vps?secret=<secret>&issuer=sesh`, then `qrencode -t ANSI '<that url>'`.

   Otherwise print nothing about the secret. **This is the only place the secret is ever printed.**
9. Step 6:
   - `install -d -o root -g root -m 0755 /var/log/sesh`.
   - If `audit.log` is missing: `install -o claude -g claude -m 0640 /dev/null /var/log/sesh/audit.log`, then `chattr +a`.
   - If it exists: `chattr +a` only when `attr_has_append "$(lsattr /var/log/sesh/audit.log)"` fails. Never `chown`/`chmod` an existing file: that returns EPERM on a `+a` file, even for root.
10. Step 7, in the spec 8 order:
    - `loginctl enable-linger claude`.
    - `systemctl start user@<uid>.service`.
    - Create the unit directory as claude: `runuser -u claude -- mkdir -p /home/claude/.config/systemd/user`.
    - Install both units there with `install -o claude -g claude -m 0644`.
    - `systemctl --user -M claude@ daemon-reload`.
    - `systemctl --user -M claude@ enable --now sesh-reaper.timer`.
11. Step 8. Run `ensure_path_snippet` on `/home/claude/.profile` and `/home/claude/.bashrc`, then chown both to claude. Then `runuser -l claude -c 'command -v claude' >/dev/null 2>&1 || runuser -l claude -c 'curl -fsSL https://claude.ai/install.sh | bash'`.
12. Step 9. Report:
    - Warn with the PIDs if `pgrep -u root -x claude` finds any.
    - List root tmux sessions (`tmux ls`).
    - Say whether the TOTP secret was `created`, `rotated` or `kept`.
    - Print a summary: user and uid; broker version (`grep -m1 '^SESH_VERSION=' /usr/local/bin/sesh`); timer status (`systemctl --user -M claude@ is-active sesh-reaper.timer`); root hardening (`on`/`off`).

    Then print the first-run checklist verbatim:

    ```
    First run:
      1. Scan the QR code into an authenticator app.
      2. On the laptop: sesh new scratch, then sesh go scratch, complete the Claude Code login inside it, detach with Ctrl-b d.
      3. Move any existing projects from /root to /home/claude/work/ and stop any root tmux sessions (README section "Migrating from root").
      4. Once vps logs in with the admin key, run deploy.ps1 -HardenRoot.
    ```

- [ ] **Step 1: Write the failing test `tests/bats/setup.bats`**

```bash
#!/usr/bin/env bats
# vps/sesh-setup: sourced for unit tests; the sshd functions run against the image's real sshd.
# main is never run here: it would install packages and create users.
load helpers

setup() {
  source /src/vps/sesh-setup
  cp /etc/ssh/sshd_config "$BATS_TEST_TMPDIR/sshd_config.orig"
  rm -f /etc/ssh/sshd_config.d/sesh.conf /etc/ssh/sshd_config.d/00-test.conf
}
teardown() {
  rm -f /etc/ssh/sshd_config.d/sesh.conf /etc/ssh/sshd_config.d/00-test.conf
  cp "$BATS_TEST_TMPDIR/sshd_config.orig" /etc/ssh/sshd_config
}

newkey() { # newkey NAME: prints the path of a fresh ed25519 public key
  ssh-keygen -q -t ed25519 -N '' -C sesh-laptop -f "$BATS_TEST_TMPDIR/$1" >/dev/null
  printf '%s' "$BATS_TEST_TMPDIR/$1.pub"
}

@test "sourcing defines the functions and runs nothing" {
  declare -F main install_sshd_dropin read_pubkey want_harden >/dev/null
}

@test "sesh-setup passes bash -n and shellcheck, and has no CR" {
  run bash -n /src/vps/sesh-setup
  [ "$status" -eq 0 ]
  run shellcheck -S warning /src/vps/sesh-setup
  [ "$status" -eq 0 ]
  run grep -c $'\r' /src/vps/sesh-setup
  [ "$output" = 0 ]
}

@test "bad arguments are usage (2) before anything happens" {
  run bash /src/vps/sesh-setup --key-id BAD --pubkey-file /nonexistent
  [ "$status" -eq 2 ]
  run bash /src/vps/sesh-setup --bogus
  [ "$status" -eq 2 ]
  run bash /src/vps/sesh-setup
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
  printf 'ssh-rsa AAAAB3NzaC1yc2E sesh-laptop\n' > "$bad"
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

@test "authorized_keys_line has restrict,pty, the forced command and comment sesh-<id>" {
  run authorized_keys_line laptop 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample'
  [ "$output" = 'restrict,pty,command="/usr/local/bin/sesh --key laptop" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample sesh-laptop' ]
}

@test "render_authorized_keys replaces only the line for the same key id (plan Q9)" {
  local f="$BATS_TEST_TMPDIR/ak"
  printf '%s\n' \
    'restrict,pty,command="/usr/local/bin/sesh --key laptop" ssh-ed25519 OLDKEY sesh-laptop' \
    'restrict,pty,command="/usr/local/bin/sesh --key desk" ssh-ed25519 DESKKEY sesh-desk' > "$f"
  run render_authorized_keys "$f" laptop 'ssh-ed25519 NEWKEY'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *'--key desk" ssh-ed25519 DESKKEY sesh-desk'* ]]
  [[ "$output" == *'--key laptop" ssh-ed25519 NEWKEY sesh-laptop'* ]]
  [[ "$output" != *OLDKEY* ]]
}

@test "render_authorized_keys on a missing file yields just the new line" {
  run render_authorized_keys "$BATS_TEST_TMPDIR/none" laptop 'ssh-ed25519 NEWKEY'
  [ "$output" = 'restrict,pty,command="/usr/local/bin/sesh --key laptop" ssh-ed25519 NEWKEY sesh-laptop' ]
}

@test "render_dropin keeps root's line commented unless hardening, then replaces it whole" {
  run render_dropin /src/vps/sshd-sesh.conf 0
  [ "$output" = "$(cat /src/vps/sshd-sesh.conf)" ]
  run render_dropin /src/vps/sshd-sesh.conf 1
  printf '%s\n' "$output" | grep -qx 'PermitRootLogin prohibit-password'
  [[ "$output" != *"<-"* ]]
  run dropin_is_hardened /src/vps/sshd-sesh.conf
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
  run install_sshd_dropin /src/vps/sshd-sesh.conf 0
  [ "$status" -eq 0 ]
  cmp /etc/ssh/sshd_config.d/sesh.conf /src/vps/sshd-sesh.conf
  run check_claude_sshd
  [ "$status" -eq 0 ]
}

@test "install_sshd_dropin with hardening changes only root's permitrootlogin" {
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  run install_sshd_dropin /src/vps/sshd-sesh.conf 1
  [ "$status" -eq 0 ]
  run sshd_effective root
  [[ "$output" == *"permitrootlogin without-password"* || "$output" == *"permitrootlogin prohibit-password"* ]]
}

@test "hardening is sticky across a plain re-run (plan Q1)" {
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  install_sshd_dropin /src/vps/sshd-sesh.conf 1
  [ "$(want_harden 0)" = 1 ]
  run install_sshd_dropin /src/vps/sshd-sesh.conf "$(want_harden 0)"
  [ "$status" -eq 0 ]
  dropin_is_hardened /etc/ssh/sshd_config.d/sesh.conf
}

@test "install_sshd_dropin aborts and restores when root's config would change" {
  install_sshd_dropin /src/vps/sshd-sesh.conf 0
  cp /etc/ssh/sshd_config.d/sesh.conf "$BATS_TEST_TMPDIR/good"
  { echo 'X11Forwarding no'; cat /src/vps/sshd-sesh.conf; } > "$BATS_TEST_TMPDIR/bad.conf"
  run install_sshd_dropin "$BATS_TEST_TMPDIR/bad.conf" 0
  [ "$status" -ne 0 ]
  cmp /etc/ssh/sshd_config.d/sesh.conf "$BATS_TEST_TMPDIR/good"
}

@test "install_sshd_dropin removes its file when sshd -t fails and none existed before" {
  printf 'BogusDirective yes\n' > "$BATS_TEST_TMPDIR/bogus.conf"
  run install_sshd_dropin "$BATS_TEST_TMPDIR/bogus.conf" 0
  [ "$status" -ne 0 ]
  [ ! -e /etc/ssh/sshd_config.d/sesh.conf ]
}

@test "hardening that an earlier drop-in overrides is refused (plan Q1)" {
  printf 'PermitRootLogin yes\n' > /etc/ssh/sshd_config.d/00-test.conf
  run install_sshd_dropin /src/vps/sshd-sesh.conf 1
  [ "$status" -ne 0 ]
  [[ "$output" == *permitrootlogin* ]]
  [ ! -e /etc/ssh/sshd_config.d/sesh.conf ]
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
  attr_has_append '-----a--------e------- /var/log/sesh/audit.log'
  run attr_has_append '--------------e------- /var/log/sesh/audit.log'
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
  [ "$(grep -c '^# >>> sesh path' "$f")" -eq 1 ]
  run bash -c "PATH=/usr/bin; HOME=/home/x; source '$f' >/dev/null 2>&1; printf %s \"\$PATH\""
  [[ "$output" == /home/x/.local/bin:* ]]
}

@test "staged_files_ok names what is missing" {
  local d="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$d/systemd"
  touch "$d/sesh" "$d/tmux.conf"
  run staged_files_ok "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *sudoers-claude* ]]
}
```

- [ ] **Step 2: Run to see it fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1 -Path tests/bats/setup.bats`
Expected: failures, because `/src/vps/sesh-setup` does not exist.

- [ ] **Step 3: Implement `vps/sesh-setup` to the behaviour above.**

- [ ] **Step 4: Run until green, then the whole suite**

Expected: `setup.bats` 25 tests, 0 failures; `-Path tests/bats` 0 failures.

- [ ] **Step 5: Line endings, exec bit, commit**

```
grep -lU "$(printf '\r')" vps/sesh-setup tests/bats/setup.bats   # must print nothing
git add --chmod=+x vps/sesh-setup
git add tests/bats/setup.bats
git commit -m "Add sesh-setup: preflight, sticky root hardening, audited sshd drop-in install"
```

---

### Task 12: `laptop/sesh.ps1`: the wrapper, and the Pester suite

**Model:** Sonnet. **Depends on:** Task 4. The parity test reads the `GATED_VERBS` line of `vps/sesh`.

**Files:**
- Create: `laptop/sesh.ps1`
- Create: `tests/pester/sesh.Tests.ps1`
- Create: `tests/pester/static.Tests.ps1`

**Interfaces:**
- Consumes: the line `GATED_VERBS="new go send rename unlock rm resume auth"` in `vps/sesh` (Task 4).
- Produces, for Tasks 13-15:
  - Invocation: `& "$HOME\scripts\sesh.ps1" <words...>`, which the profile function does with `@args`.
  - Exit code: ssh's, or 2 for a local usage error.
  - Dot-sourcing it (`. .\laptop\sesh.ps1`) defines `$GatedVerbs`, `$SeshHint`, `ConvertTo-SeshWords`, `ConvertTo-SeshToken` and `Get-SeshSshArgs`, and runs nothing.
  - `$GatedVerbs = @('new','go','send','rename','unlock','rm','resume','auth')`.
  - `ConvertTo-SeshWords [object[]]` returns a flattened `string[]`.
  - `ConvertTo-SeshToken [string]` returns base64 of the UTF-8 bytes.
  - `Get-SeshSshArgs [string[]]` returns `@('-o','BatchMode=yes','-o','ConnectTimeout=5', ['-t'], 'sesh', 'b64', <tokens>...)`.

**Behaviour (spec 9.1, 12.2). Each item names a PowerShell 5.1 trap; all of them were verified on this laptop.**
- **No `param()` block and no `[CmdletBinding()]`** at the top of `sesh.ps1`. Otherwise `-n` and `-d` would bind to Verbose/Debug or fail. Helper functions inside the file may declare their own `param()`.
- **The file is ASCII only.** Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI. Build non-ASCII strings with `[char]` codes; never type them literally.
- Read `$args` verbatim and flatten every nested array. In command mode, PowerShell turns `a, b` into one array argument, and `20` arrives as `Int32` (verified). Stringify each element with `[string]`. Flatten recursively anything that is `IEnumerable` but not `[string]`.
- **Reject empty strings** (and `$null`, which stringifies to empty): print `sesh: empty argument` with `Write-Host`, `exit 2`, and do not call ssh. PowerShell keeps `''` when calling a script (verified), but would silently drop it when calling a native exe. Note too that PowerShell **drops `--`** before the script ever sees it (verified); README documents this, and the wrapper needs no code for it.
- Verb comparisons are **case-sensitive**: use `-ceq` and `-ccontains`, never `-eq` or `-contains`.
- If the words are exactly `send <name>`, prompt with `Read-Host 'Text to send'`. **Do not add a colon**: `Read-Host` appends `: ` itself. If the answer is empty, `Write-Host 'sesh: nothing to send'` and `exit 2`. Otherwise append the answer as **one** word.
- If the first word is `rm`, and the words contain `--now` but not `--confirm`, prompt with `Read-Host 'Type the session name to confirm'` (again no colon). If the answer is empty, `Write-Host 'sesh: confirmation required'` and `exit 2`. Otherwise append `--confirm` and the answer.
- Encode every word as `[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($w))`. Call bare `ssh` with `-o BatchMode=yes -o ConnectTimeout=5`, then `-t` only if the first word `-cin $GatedVerbs`, then `sesh b64 <tokens...>`.
- **Run `& ssh @sshArgs` as a plain statement at script level.** Never capture or pipe its output (`$x = & ssh`, `| Out-Null`, `$(...)`). Captured output stops ssh owning the console, which breaks `go` and the TOTP prompt. **Never redirect ssh's stderr** (`2>`), because 5.1 wraps each line in an error record.
- After ssh returns, take `$code = $LASTEXITCODE`. If it is 255, `Write-Host "ssh to host 'sesh' failed (unreachable, key rejected, or remote killed by signal)"`, exactly once. Then `exit $code`.
- Structure: `$GatedVerbs`, `$SeshHint` and the helper functions come first, then `if ($MyInvocation.InvocationName -eq '.') { return }`, then the main statements.

**Pester note.** Tests `Mock ssh` and set `$global:LASTEXITCODE` inside the mock, because a mock is a function and does not set it. As a safety net, the test file puts a fake `ssh.cmd` (which just exits 99) first on `PATH`. If a mock ever fails to intercept, the fake answers rather than the real ssh. If mocks do not intercept calls made inside `& $Wrapper`, **stop and report**; do not change how the wrapper calls ssh. If Pester rejects `Mock` in the file-level `BeforeEach`/`BeforeAll`, wrap the whole file body in one `Describe 'sesh.ps1' { ... }`, keeping the same order. That is the only structural change allowed (the same applies to Tasks 13-15).

- [ ] **Step 1: Install Pester 5 (allowed agent action; CurrentUser scope)**

Run from the PowerShell tool:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $nuget = Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
    Where-Object { $_.Version -ge [version]'2.8.5.201' }
  if (-not $nuget) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null }
  Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
  Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1 Name, Version
}
```

Expected: `Pester 5.x.y`, with x >= 5. If the install fails (proxy, gallery unreachable), stop and report the error.

- [ ] **Step 2: Write the failing test `tests/pester/static.Tests.ps1`**

```powershell
# Static checks on every PowerShell file: ASCII only, parses cleanly; the wrapper has no param block.
BeforeDiscovery {
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:PsFiles = @(Get-ChildItem -Path (Join-Path $repo 'laptop'), (Join-Path $repo 'tests') -Recurse -Filter *.ps1 -File |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repo.Length + 1) } })
}

Describe 'PowerShell file <Name>' -ForEach $PsFiles {
    It 'is ASCII only' {
        $bytes = [IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'parses without errors' {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

Describe 'laptop/sesh.ps1 shape' {
    It 'has no param block and no CmdletBinding' {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'laptop\sesh.ps1'), [ref]$tokens, [ref]$errors)
        $ast.ParamBlock | Should -BeNullOrEmpty
        $ast.Extent.Text | Should -Not -Match '\[CmdletBinding'
    }
}
```

- [ ] **Step 3: Write the failing test `tests/pester/sesh.Tests.ps1`**

```powershell
# Pester 5 tests for laptop/sesh.ps1 (spec 9.1, 12.2). ssh is always mocked.
BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Wrapper = Join-Path $Repo 'laptop\sesh.ps1'
    # Safety net: if a mock ever fails to intercept, this fake answers instead of the real ssh.
    $script:FakeBin = Join-Path $TestDrive 'bin'
    New-Item -ItemType Directory -Path $FakeBin | Out-Null
    Set-Content -LiteralPath (Join-Path $FakeBin 'ssh.cmd') -Value '@exit /b 99' -Encoding ascii
    $script:OldPath = $env:PATH
    $env:PATH = "$FakeBin;$env:PATH"

    function B64([string]$s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
    function Expected([string[]]$Words, [switch]$Tty) {
        $a = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5')
        if ($Tty) { $a += '-t' }
        $a += @('sesh', 'b64')
        foreach ($w in $Words) { $a += (B64 $w) }
        $a -join '|'
    }
    function Actual { $global:SeshSshArgs -join '|' }
}

AfterAll {
    $env:PATH = $OldPath
    Remove-Variable -Name SeshSshArgs -Scope Global -ErrorAction SilentlyContinue
}

BeforeEach {
    $global:SeshSshArgs = $null
    Mock ssh { $global:SeshSshArgs = @($args); $global:LASTEXITCODE = 0 }
}

Describe 'ssh argument array' {
    It '<Line> uses -t: <Tty>' -ForEach @(
        @{ Line = 'new api';        Tty = $true }
        @{ Line = 'go api';         Tty = $true }
        @{ Line = 'send api hi';    Tty = $true }
        @{ Line = 'rename api web'; Tty = $true }
        @{ Line = 'unlock api';     Tty = $true }
        @{ Line = 'rm api';         Tty = $true }
        @{ Line = 'resume api';     Tty = $true }
        @{ Line = 'auth';           Tty = $true }
        @{ Line = 'ls';             Tty = $false }
        @{ Line = 'peek api';       Tty = $false }
        @{ Line = 'log';            Tty = $false }
        @{ Line = 'lock api';       Tty = $false }
        @{ Line = 'restore api';    Tty = $false }
    ) {
        $words = $Line -split ' '
        & $Wrapper @words
        Actual | Should -BeExactly (Expected $words -Tty:$Tty)
    }

    It 'encodes each word of a multi-word send separately' {
        & $Wrapper send api 'echo hi' there
        Actual | Should -BeExactly (Expected @('send', 'api', 'echo hi', 'there') -Tty)
    }

    It 'encodes non-ASCII text as UTF-8' {
        $cafe = 'caf' + [char]0x00E9
        & $Wrapper send api $cafe
        Actual | Should -BeExactly (Expected @('send', 'api', $cafe) -Tty)
        (B64 $cafe) | Should -BeExactly 'Y2Fmw6k='
    }

    It 'stringifies numbers' {
        & $Wrapper peek api -n 20
        Actual | Should -BeExactly (Expected @('peek', 'api', '-n', '20'))
    }

    It 'flattens nested arrays' {
        & $Wrapper send api @('a', @('b', 'c'))
        Actual | Should -BeExactly (Expected @('send', 'api', 'a', 'b', 'c') -Tty)
    }

    It 'passes -n and -d through the profile function unchanged' {
        function sesh { & $Wrapper @args }
        sesh peek api -n 20 -d
        Actual | Should -BeExactly (Expected @('peek', 'api', '-n', '20', '-d'))
    }

    It 'never puts a raw -- on the ssh command line' {
        & $Wrapper send api -- x
        $global:SeshSshArgs | Should -Not -Contain '--'
    }
}

Describe 'local prompts' {
    It 'prompts for the text when send has none, and sends it as one word' {
        Mock Read-Host { 'a; b # $c (d) @e, f' } -ParameterFilter { $Prompt -eq 'Text to send' }
        & $Wrapper send api
        Should -Invoke Read-Host -Times 1 -Exactly
        Actual | Should -BeExactly (Expected @('send', 'api', 'a; b # $c (d) @e, f') -Tty)
    }

    It 'exits 2 without calling ssh when the prompted text is empty' {
        Mock Read-Host { '' }
        & $Wrapper send api
        $LASTEXITCODE | Should -Be 2
        Should -Invoke ssh -Times 0 -Exactly
    }

    It 'rm --now prompts and appends --confirm' {
        Mock Read-Host { 'api' } -ParameterFilter { $Prompt -eq 'Type the session name to confirm' }
        & $Wrapper rm api --now
        Should -Invoke Read-Host -Times 1 -Exactly
        Actual | Should -BeExactly (Expected @('rm', 'api', '--now', '--confirm', 'api') -Tty)
    }

    It 'rm --now with --confirm does not prompt' {
        Mock Read-Host { throw 'must not prompt' }
        & $Wrapper rm api --now --confirm api
        Should -Invoke Read-Host -Times 0 -Exactly
        Actual | Should -BeExactly (Expected @('rm', 'api', '--now', '--confirm', 'api') -Tty)
    }

    It 'plain rm does not prompt' {
        Mock Read-Host { throw 'must not prompt' }
        & $Wrapper rm api
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'an empty confirmation exits 2 without calling ssh' {
        Mock Read-Host { '' }
        & $Wrapper rm api --now
        $LASTEXITCODE | Should -Be 2
        Should -Invoke ssh -Times 0 -Exactly
    }

    It 'verb matching is case-sensitive: RM --now does not prompt' {
        Mock Read-Host { throw 'must not prompt' }
        & $Wrapper RM api --now
        Should -Invoke Read-Host -Times 0 -Exactly
    }
}

Describe 'argument validation' {
    It 'rejects an empty argument with exit 2 and no ssh call' {
        & $Wrapper send api ''
        $LASTEXITCODE | Should -Be 2
        Should -Invoke ssh -Times 0 -Exactly
    }

    It 'rejects a $null argument with exit 2 and no ssh call' {
        & $Wrapper send api $null
        $LASTEXITCODE | Should -Be 2
        Should -Invoke ssh -Times 0 -Exactly
    }
}

Describe 'exit codes' {
    It 'returns the ssh exit code' {
        Mock ssh { $global:LASTEXITCODE = 3 }
        & $Wrapper rm api
        $LASTEXITCODE | Should -Be 3
    }

    It 'prints the hint exactly once on 255' {
        Mock ssh { $global:LASTEXITCODE = 255 }
        $out = & $Wrapper ls 6>&1 | Out-String
        $LASTEXITCODE | Should -Be 255
        $hint = "ssh to host 'sesh' failed (unreachable, key rejected, or remote killed by signal)"
        ([regex]::Matches($out, [regex]::Escape($hint))).Count | Should -Be 1
    }

    It 'prints no hint on other failures' {
        Mock ssh { $global:LASTEXITCODE = 5 }
        $out = & $Wrapper peek nosuch 6>&1 | Out-String
        $out | Should -Not -Match 'failed \(unreachable'
    }
}

Describe 'contract with the broker' {
    It '$GatedVerbs equals the GATED_VERBS line in vps/sesh' {
        . $Wrapper
        $line = Select-String -LiteralPath (Join-Path $Repo 'vps\sesh') -Pattern '^GATED_VERBS="([^"]*)"$' -CaseSensitive
        $line | Should -Not -BeNullOrEmpty
        $broker = @($line.Matches[0].Groups[1].Value -split ' ' | Sort-Object)
        (@($GatedVerbs | Sort-Object) -join ' ') | Should -BeExactly ($broker -join ' ')
    }

    It 'dot-sourcing defines the helpers and calls nothing' {
        . $Wrapper
        Get-Command ConvertTo-SeshWords -CommandType Function | Should -Not -BeNullOrEmpty
        Should -Invoke ssh -Times 0 -Exactly
    }
}
```

- [ ] **Step 4: Run both files to see them fail**

Run the Pester command from Execution notes, with `$c.Run.Path = 'tests\pester'`.
Expected: `sesh.Tests.ps1` fails because `laptop\sesh.ps1` does not exist. `static.Tests.ps1` runs its per-file tests over the files that exist (`tests/run-bats.ps1` and the two test files) and fails the shape test.

- [ ] **Step 5: Write `laptop/sesh.ps1` to the behaviour above.**

- [ ] **Step 6: Run until green**

Expected: `sesh.Tests.ps1` reports 33 passed, 0 failed. `static.Tests.ps1` passes for every `.ps1` file present, plus the shape test.

- [ ] **Step 7: Commit**

```
git add laptop/sesh.ps1 tests/pester/sesh.Tests.ps1 tests/pester/static.Tests.ps1
git commit -m "Add sesh.ps1 laptop wrapper (PowerShell 5.1) with Pester suite"
```

---

### Task 13: `laptop/profile-snippet.ps1`: the `sesh` function and tab completer

**Model:** Sonnet. **Depends on:** Task 12.

**Files:**
- Create: `laptop/profile-snippet.ps1`
- Create: `tests/pester/completer.Tests.ps1`

**Interfaces:**
- Consumes: `~\scripts\sesh.ps1` at run time (installed by deploy, Task 14), and the broker's `ls --names` and `ls --tombstones` (Task 5).
- Produces, for Task 14 (`Add-SeshProfileSnippet` appends this file's lines verbatim to the profile):
  - The file's first non-empty line is `# >>> sesh` and its last is `# <<< sesh`.
  - It defines `function global:sesh { & "$HOME\scripts\sesh.ps1" @args }` and `function global:Get-SeshCompletionList { param([ValidateSet('names','tombstones')][string]$Kind) ... }`. The latter returns a string array.
  - It registers `Register-ArgumentCompleter -Native -CommandName sesh -ScriptBlock { param($wordToComplete, $commandAst, $cursorPosition) ... }`. Verified on this laptop: a `-Native` completer fires for a *function* named `sesh` in 5.1.

**Behaviour (spec 9.2, plan Q13):**
- ASCII only. Nothing in the file writes to the host.
- `Get-SeshCompletionList`:
  - The cache file is `Join-Path $env:TEMP ('sesh-{0}.txt' -f $Kind)`, i.e. `sesh-names.txt` or `sesh-tombstones.txt` (Q13a).
  - If the file exists and its `LastWriteTime` is under 60 seconds old, return its non-empty lines.
  - Otherwise run `& ssh -o BatchMode=yes -o ConnectTimeout=5 sesh ls "--$Kind" 2>$null` inside `try/catch` (Q13b: the one place stderr is discarded).
  - On exit 0, the result is the trimmed non-empty lines; on any failure or exception it is an empty array.
  - Always write the result with `[IO.File]::WriteAllLines($file, [string[]]$names)`; an empty result writes an empty file, which caches the failure for 60 seconds. Return the result.
- Completer:
  - Take the texts of `$commandAst.CommandElements` whose `Extent.EndOffset -lt $cursorPosition`. Element 0 is `sesh`.
  - With one such element, complete the verbs `new ls peek go send rename lock unlock rm restore resume log auth`, in that order.
  - With two, if the second element `-cin` `peek go send rename lock unlock rm resume`, complete `Get-SeshCompletionList names`; if it `-ceq` `restore`, complete `Get-SeshCompletionList tombstones`; otherwise nothing.
  - Filter candidates with `-like "$wordToComplete*"`, and emit each as `[System.Management.Automation.CompletionResult]::new($n, $n, 'ParameterValue', $n)`.
- The `vps` alias and `connect-vps.ps1` are not touched (spec 9.2).

- [ ] **Step 1: Write the failing test `tests/pester/completer.Tests.ps1`**

```powershell
# Pester 5 tests for laptop/profile-snippet.ps1 (spec 9.2, 12.2). ssh is always mocked.
BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Snippet = Join-Path $Repo 'laptop\profile-snippet.ps1'
    $script:FakeBin = Join-Path $TestDrive 'bin'
    New-Item -ItemType Directory -Path $FakeBin | Out-Null
    Set-Content -LiteralPath (Join-Path $FakeBin 'ssh.cmd') -Value '@exit /b 99' -Encoding ascii
    $script:OldPath = $env:PATH
    $script:OldTemp = $env:TEMP
    $env:PATH = "$FakeBin;$env:PATH"
    . $Snippet
}

AfterAll {
    $env:PATH = $OldPath
    $env:TEMP = $OldTemp
    Remove-Variable -Name SeshSshArgs -Scope Global -ErrorAction SilentlyContinue
}

BeforeEach {
    $env:TEMP = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
    $global:SeshSshArgs = $null
    Mock ssh { $global:SeshSshArgs = @($args); $global:LASTEXITCODE = 0; 'api'; 'web' }
}

Describe 'profile snippet text' {
    It 'is wrapped in the sesh markers' {
        $lines = @(Get-Content -LiteralPath $Snippet | Where-Object { $_.Trim() })
        $lines[0] | Should -BeExactly '# >>> sesh'
        $lines[-1] | Should -BeExactly '# <<< sesh'
    }

    It 'is ASCII only' {
        @([IO.File]::ReadAllBytes($Snippet) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'defines sesh as a call to ~\scripts\sesh.ps1 with @args' {
        (Get-Command sesh -CommandType Function).Definition |
            Should -Match ([regex]::Escape('& "$HOME\scripts\sesh.ps1" @args'))
    }
}

Describe 'Get-SeshCompletionList' {
    It 'fetches names with plain ls --names over BatchMode ssh, then serves the cache' {
        (@(Get-SeshCompletionList names) -join ',') | Should -BeExactly 'api,web'
        ($global:SeshSshArgs -join ' ') | Should -BeExactly '-o BatchMode=yes -o ConnectTimeout=5 sesh ls --names'
        (@(Get-SeshCompletionList names) -join ',') | Should -BeExactly 'api,web'
        Should -Invoke ssh -Times 1 -Exactly
        Test-Path -LiteralPath (Join-Path $env:TEMP 'sesh-names.txt') | Should -BeTrue
    }

    It 'uses ls --tombstones and its own cache file' {
        Get-SeshCompletionList tombstones | Out-Null
        ($global:SeshSshArgs -join ' ') | Should -BeExactly '-o BatchMode=yes -o ConnectTimeout=5 sesh ls --tombstones'
        Test-Path -LiteralPath (Join-Path $env:TEMP 'sesh-tombstones.txt') | Should -BeTrue
    }

    It 'refetches once the cache is older than 60 seconds' {
        Get-SeshCompletionList names | Out-Null
        (Get-Item -LiteralPath (Join-Path $env:TEMP 'sesh-names.txt')).LastWriteTime = (Get-Date).AddSeconds(-61)
        Get-SeshCompletionList names | Out-Null
        Should -Invoke ssh -Times 2 -Exactly
    }

    It 'caches a failed fetch as empty for 60 seconds' {
        Mock ssh { $global:LASTEXITCODE = 255 }
        @(Get-SeshCompletionList names).Count | Should -Be 0
        @(Get-SeshCompletionList names).Count | Should -Be 0
        Should -Invoke ssh -Times 1 -Exactly
        (Get-Item -LiteralPath (Join-Path $env:TEMP 'sesh-names.txt')).Length | Should -Be 0
    }
}

Describe 'registered completer' {
    It 'completes verbs for the first word' {
        $r = TabExpansion2 -inputScript 'sesh re' -cursorColumn 7
        ($r.CompletionMatches.CompletionText -join ',') | Should -BeExactly 'rename,restore,resume'
    }

    It 'completes cached session names after go' {
        Set-Content -LiteralPath (Join-Path $env:TEMP 'sesh-names.txt') -Value @('api', 'web') -Encoding ascii
        $r = TabExpansion2 -inputScript 'sesh go a' -cursorColumn 9
        ($r.CompletionMatches.CompletionText -join ',') | Should -BeExactly 'api'
    }

    It 'completes tombstone base names after restore' {
        Set-Content -LiteralPath (Join-Path $env:TEMP 'sesh-tombstones.txt') -Value @('old') -Encoding ascii
        $r = TabExpansion2 -inputScript 'sesh restore ' -cursorColumn 13
        ($r.CompletionMatches.CompletionText -join ',') | Should -BeExactly 'old'
    }

    It 'offers no session names after new' {
        Set-Content -LiteralPath (Join-Path $env:TEMP 'sesh-names.txt') -Value @('api') -Encoding ascii
        $r = TabExpansion2 -inputScript 'sesh new ' -cursorColumn 9
        @($r.CompletionMatches | Where-Object { $_.CompletionText -eq 'api' }).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run the Pester command with `$c.Run.Path = 'tests\pester\completer.Tests.ps1'`.
Expected: failure in `BeforeAll`, because the snippet file does not exist.

- [ ] **Step 3: Write `laptop/profile-snippet.ps1` to the behaviour above.**

- [ ] **Step 4: Run until green, then the whole Pester folder**

Expected: `completer.Tests.ps1` reports 11 passed; `tests\pester` reports 0 failed overall, and `static.Tests.ps1` now also covers the snippet.

- [ ] **Step 5: Commit**

```
git add laptop/profile-snippet.ps1 tests/pester/completer.Tests.ps1
git commit -m "Add profile snippet: sesh function and cached tab completer"
```

---

### Task 14: `laptop/deploy.ps1`: the operator's deploy script

**Model:** Sonnet. Security-relevant (admin path, remote command string): the orchestrator should have Opus review this diff. **Depends on:** Tasks 11 and 13.

**Agents never run `deploy.ps1`** (spec 9.3, 16). The tests dot-source it to unit-test its functions. They mock `ssh`, `scp` and `ssh-keygen` **before** dot-sourcing, and put fake `.cmd` versions of all three first on `PATH`.

**Files:**
- Create: `laptop/deploy.ps1`
- Create: `tests/pester/deploy.Tests.ps1`

**Interfaces:**
- Consumes:
  - The repo files staged for the VPS: `vps/sesh` (exactly one `SESH_VERSION=dev` line), `vps/sesh-setup`, `vps/vps-facts.sh`, `vps/sshd-sesh.conf`, `vps/sudoers-claude`, `vps/tmux.conf`, `vps/systemd/sesh-reaper.service`, `vps/systemd/sesh-reaper.timer`.
  - `laptop/sesh.ps1` and `laptop/profile-snippet.ps1`.
  - Setup's command line (Task 11): `sesh-setup --pubkey-file <path> --key-id laptop [--harden-root] [--rotate-totp] [--unlock-otp]`.
- Produces (operator use):
  - `powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 [-HardenRoot] [-RotateTotp] [-UnlockOtp]`. The last two switches come from Q4.
  - Functions, available when dot-sourced:
    - `Get-SeshVersion -RepoRoot <string>`: returns a string.
    - `New-SeshStaging -RepoRoot <string> -Version <string> -PubKeyPath <string> -Destination <string>`.
    - `Add-SeshHostBlock -ConfigPath <string>`.
    - `Add-SeshProfileSnippet -ProfilePath <string> -SnippetPath <string>`.
    - `Get-SeshSetupCommand -StageName <string> [-HardenRoot] [-RotateTotp] [-UnlockOtp]`: returns a string.
    - `Show-SeshAdminHelp`.
    - Internal helpers: `Write-SeshLfFile -Path -Text` and `Add-SeshMarkedBlock -Path -Lines`.

**Behaviour (spec 4.3, 9.3, plan Q3, Q4). The script and its helpers are ASCII only, and every path parameter is handled with `-LiteralPath` and quoting.** The real `$PROFILE` is `C:\Users\<you>\Cloud Drive\My Docs\Docs\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`.
- File shape: `param([switch]$HardenRoot, [switch]$RotateTotp, [switch]$UnlockOtp)`, then the functions, then `if ($MyInvocation.InvocationName -eq '.') { return }`, then main.
- `Get-SeshVersion`: `& git -C $RepoRoot rev-parse --short HEAD`, trimmed. Append `-dirty` if `& git -C $RepoRoot status --porcelain` prints anything. Throw if git fails.
- `Write-SeshLfFile`: replace `` "`r`n" `` with `` "`n" `` and remove any remaining `` "`r" ``. Create the parent folder. Write with `[IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))`, which is UTF-8 without BOM.
- `New-SeshStaging`:
  - `Version` must match `^[0-9a-f]{4,40}(-dirty)?$`, else throw. It is written into a bash file.
  - For each staged file, keep the relative path minus `vps/`: `sesh`, `sesh-setup`, `vps-facts.sh`, `sshd-sesh.conf`, `sudoers-claude`, `tmux.conf`, `systemd/sesh-reaper.service`, `systemd/sesh-reaper.timer`. Read the text and write it with `Write-SeshLfFile` under `Destination`.
  - For `sesh`, there must be exactly one match of `(?m)^SESH_VERSION=dev$` (else throw); replace it with `SESH_VERSION=<Version>`.
  - Copy the public key the same way to `id_sesh_ed25519.pub`.
- `Add-SeshMarkedBlock -Path -Lines`:
  - If the file exists and starts with bytes `FF FE` or `FE FF` (UTF-16), throw `<path> is UTF-16; convert it to UTF-8 or ASCII first`. Leave the file untouched.
  - If it already has a line exactly `# >>> sesh`, do nothing.
  - Otherwise create the parent folder if needed. If the file is non-empty and does not end with byte `0A`, run `Add-Content -LiteralPath $Path -Value '' -Encoding ascii` (adds the missing newline). Then run `Add-Content -LiteralPath $Path -Value $Lines -Encoding ascii`.
  - Throw if any line has a character above 127.
- `Add-SeshHostBlock`: calls `Add-SeshMarkedBlock` with the spec 4.3 block, preceded by one empty line:

  ```
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

- `Add-SeshProfileSnippet`: calls `Add-SeshMarkedBlock` with the lines of `SnippetPath` (`Get-Content -LiteralPath`).
- `Get-SeshSetupCommand`:
  - `StageName` must match `^sesh-deploy-\d{14}$`, else throw. It is interpolated into `rm -rf`.
  - Flags are appended in the fixed order ` --harden-root`, ` --rotate-totp`, ` --unlock-otp`.
  - Build the string from a **single-quoted** format string, so `$?` and `$rc` stay literal for the remote shell, and so it contains **no double quotes**, which 5.1 does not escape when passing arguments to native programs:

    ```powershell
    'bash /root/{0}/sesh-setup --pubkey-file /root/{0}/id_sesh_ed25519.pub --key-id laptop{1}; rc=$?; rm -rf /root/{0}; exit $rc' -f $StageName, $flags
    ```

- `Show-SeshAdminHelp`: `Write-Host` the spec 4.5 instructions. Use the plan's O1 pipe-free command (Q18) and the check `ssh -o PasswordAuthentication=no vps true`.
- Main, for the operator only. Never `2>` a native command, and never capture setup's output:
  1. `$repo` is the parent of `$PSScriptRoot`. `$key = Join-Path $env:USERPROFILE '.ssh\id_sesh_ed25519'`. If `$key` is missing, run `& ssh-keygen -t ed25519 -f $key -C sesh-laptop -N '""'`. The `'""'` is required: 5.1 drops an empty argument, and the literal `""` reaches ssh-keygen as an empty passphrase. Stop on a non-zero exit.
  2. `Add-SeshHostBlock -ConfigPath (Join-Path $env:USERPROFILE '.ssh\config')`.
  3. Build the stage:
     - `$ts = Get-Date -Format yyyyMMddHHmmss`; `$stage = "sesh-deploy-$ts"`; `$parent = Join-Path $env:TEMP "sesh-stage-$ts"`.
     - `New-SeshStaging -RepoRoot $repo -Version (Get-SeshVersion -RepoRoot $repo) -PubKeyPath "$key.pub" -Destination (Join-Path $parent $stage)`.
  4. Copy it over:
     - `Push-Location -LiteralPath $parent`. A relative source path keeps scp from misreading `C:`.
     - `& scp -o PreferredAuthentications=publickey -r $stage "vps:/root/$stage"`, then `Pop-Location` in a `finally`.
     - Exit 255: `Show-SeshAdminHelp`; `exit 1` (Q3). Any other non-zero: report it and exit with it.
  5. `& ssh -o PreferredAuthentications=publickey vps (Get-SeshSetupCommand -StageName $stage -HardenRoot:$HardenRoot -RotateTotp:$RotateTotp -UnlockOtp:$UnlockOtp)`.
     - No `-t`. Let the output stream to the console.
     - If `$LASTEXITCODE` is non-zero, `Write-Host "deploy: sesh-setup failed with exit <n>"` and exit with it.
  6. Create `$HOME\scripts` if needed. `Copy-Item -LiteralPath (Join-Path $repo 'laptop\sesh.ps1') -Destination (Join-Path $HOME 'scripts\sesh.ps1') -Force`. Then `Add-SeshProfileSnippet -ProfilePath $PROFILE -SnippetPath (Join-Path $repo 'laptop\profile-snippet.ps1')`.
  7. Proof of life: `& ssh -o BatchMode=yes sesh ls`, then `Write-Host "deploy: proof of life exit $LASTEXITCODE"`.
  8. `Remove-Item -LiteralPath $parent -Recurse -Force`. Then `Write-Host 'deploy: done. Open a new PowerShell window to load the sesh function.'`

- [ ] **Step 1: Write the failing test `tests/pester/deploy.Tests.ps1`**

```powershell
# Pester 5 tests for laptop/deploy.ps1. The script is dot-sourced (functions only); main never runs.
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
    $script:Pub = Join-Path $TestDrive 'k.pub'
    [IO.File]::WriteAllText($Pub, "ssh-ed25519 AAAATEST sesh-laptop`r`n")
}

AfterAll { $env:PATH = $OldPath }

Describe 'dot-sourcing' {
    It 'defines the functions' {
        foreach ($f in 'Get-SeshVersion', 'New-SeshStaging', 'Add-SeshHostBlock', 'Add-SeshProfileSnippet', 'Get-SeshSetupCommand') {
            Get-Command $f -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-SeshVersion' {
    It 'returns the short hash, with -dirty when the tree is dirty' {
        $r = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $r | Out-Null
        & git -C $r init -q
        & git -C $r -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
        $hash = (& git -C $r rev-parse --short HEAD).Trim()
        Get-SeshVersion -RepoRoot $r | Should -BeExactly $hash
        Set-Content -LiteralPath (Join-Path $r 'x.txt') -Value 'x' -Encoding ascii
        Get-SeshVersion -RepoRoot $r | Should -BeExactly "$hash-dirty"
    }
}

Describe 'New-SeshStaging' {
    It 'stages every VPS file with LF, no BOM, and the version stamped, under a path with spaces' {
        $dest = Join-Path $TestDrive 'stage dir\sesh-deploy-20261009120000'
        New-SeshStaging -RepoRoot $Repo -Version 'abc1234' -PubKeyPath $Pub -Destination $dest
        $expected = 'id_sesh_ed25519.pub,sesh,sesh-setup,sshd-sesh.conf,sudoers-claude,systemd/sesh-reaper.service,systemd/sesh-reaper.timer,tmux.conf,vps-facts.sh'
        $actual = (Get-ChildItem -LiteralPath $dest -Recurse -File |
            ForEach-Object { $_.FullName.Substring($dest.Length + 1).Replace('\', '/') } | Sort-Object) -join ','
        $actual | Should -BeExactly $expected
        foreach ($f in Get-ChildItem -LiteralPath $dest -Recurse -File) {
            $b = [IO.File]::ReadAllBytes($f.FullName)
            ($b -contains 13) | Should -BeFalse -Because "$($f.Name) must have LF endings"
            ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeFalse -Because "$($f.Name) must have no BOM"
        }
        $sesh = [IO.File]::ReadAllText((Join-Path $dest 'sesh'))
        $sesh | Should -Match '(?m)^SESH_VERSION=abc1234$'
        $sesh | Should -Not -Match '(?m)^SESH_VERSION=dev$'
    }

    It 'rejects a version string that is not a git hash' {
        { New-SeshStaging -RepoRoot $Repo -Version 'abc; rm -rf /' -PubKeyPath $Pub -Destination (Join-Path $TestDrive 's2') } |
            Should -Throw
    }

    It 'throws when vps/sesh lacks exactly one SESH_VERSION=dev line' {
        $fake = Join-Path $TestDrive 'fakerepo'
        New-Item -ItemType Directory -Path $fake | Out-Null
        Copy-Item -LiteralPath (Join-Path $Repo 'vps') -Destination (Join-Path $fake 'vps') -Recurse
        $p = Join-Path $fake 'vps\sesh'
        [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p) -replace '(?m)^SESH_VERSION=dev\r?$', 'SESH_VERSION=other'))
        { New-SeshStaging -RepoRoot $fake -Version 'abc1234' -PubKeyPath $Pub -Destination (Join-Path $TestDrive 's3') } |
            Should -Throw
    }
}

Describe 'Add-SeshHostBlock' {
    It 'appends the block once, after adding a missing final newline' {
        $cfg = Join-Path $TestDrive 'ssh dir\config'
        New-Item -ItemType Directory -Path (Split-Path $cfg) | Out-Null
        [IO.File]::WriteAllText($cfg, "Host vps`n    HostName 203.0.113.10")
        Add-SeshHostBlock -ConfigPath $cfg
        Add-SeshHostBlock -ConfigPath $cfg
        $text = [IO.File]::ReadAllText($cfg)
        ([regex]::Matches($text, '(?m)^# >>> sesh\r?$')).Count | Should -Be 1
        $text | Should -Match 'HostName 203\.0\.113\.10\r?\n'
        foreach ($l in 'Host sesh', '    HostName 203.0.113.10', '    User claude', '    IdentityFile ~/.ssh/id_sesh_ed25519',
                       '    IdentitiesOnly yes', '    ServerAliveInterval 30', '    ServerAliveCountMax 4', '# <<< sesh') {
            $text | Should -Match ('(?m)^' + [regex]::Escape($l) + '\r?$')
        }
        @([IO.File]::ReadAllBytes($cfg) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'creates the file and its folder if missing' {
        $cfg = Join-Path $TestDrive 'new dir\config'
        Add-SeshHostBlock -ConfigPath $cfg
        [IO.File]::ReadAllText($cfg) | Should -Match '(?m)^Host sesh\r?$'
    }

    It 'refuses a UTF-16 file and leaves it untouched' {
        $cfg = Join-Path $TestDrive 'utf16config'
        [IO.File]::WriteAllText($cfg, "Host x`r`n", [Text.Encoding]::Unicode)
        $before = [IO.File]::ReadAllBytes($cfg) -join ','
        { Add-SeshHostBlock -ConfigPath $cfg } | Should -Throw
        ([IO.File]::ReadAllBytes($cfg) -join ',') | Should -BeExactly $before
    }
}

Describe 'Add-SeshProfileSnippet (Review Focus 5)' {
    It 'appends the snippet once to a profile path with spaces, creating folders' {
        $p = Join-Path $TestDrive 'Cloud Drive\My Docs\Docs\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
        $snippet = Join-Path $Repo 'laptop\profile-snippet.ps1'
        Add-SeshProfileSnippet -ProfilePath $p -SnippetPath $snippet
        Add-SeshProfileSnippet -ProfilePath $p -SnippetPath $snippet
        $text = [IO.File]::ReadAllText($p)
        ([regex]::Matches($text, '(?m)^# >>> sesh\r?$')).Count | Should -Be 1
        $text | Should -Match ([regex]::Escape('Register-ArgumentCompleter -Native -CommandName sesh'))
    }

    It 'keeps existing profile content and refuses a UTF-16 profile' {
        $p = Join-Path $TestDrive 'prof\a b.ps1'
        New-Item -ItemType Directory -Path (Split-Path $p) | Out-Null
        [IO.File]::WriteAllText($p, 'Set-Alias ll Get-ChildItem')
        Add-SeshProfileSnippet -ProfilePath $p -SnippetPath (Join-Path $Repo 'laptop\profile-snippet.ps1')
        [IO.File]::ReadAllText($p) | Should -Match '^Set-Alias ll Get-ChildItem\r?\n'
        $u = Join-Path $TestDrive 'prof\u16.ps1'
        [IO.File]::WriteAllText($u, "# x`r`n", [Text.Encoding]::Unicode)
        { Add-SeshProfileSnippet -ProfilePath $u -SnippetPath (Join-Path $Repo 'laptop\profile-snippet.ps1') } | Should -Throw
    }
}

Describe 'Get-SeshSetupCommand' {
    It 'builds the remote command with cleanup and the exit code' {
        Get-SeshSetupCommand -StageName 'sesh-deploy-20261009120000' |
            Should -BeExactly 'bash /root/sesh-deploy-20261009120000/sesh-setup --pubkey-file /root/sesh-deploy-20261009120000/id_sesh_ed25519.pub --key-id laptop; rc=$?; rm -rf /root/sesh-deploy-20261009120000; exit $rc'
    }

    It 'appends the flags in a fixed order' {
        Get-SeshSetupCommand -StageName 'sesh-deploy-20261009120000' -HardenRoot -RotateTotp -UnlockOtp |
            Should -Match '--key-id laptop --harden-root --rotate-totp --unlock-otp; rc='
    }

    It 'never contains a double quote' {
        Get-SeshSetupCommand -StageName 'sesh-deploy-20261009120000' -HardenRoot | Should -Not -Match '"'
    }

    It 'refuses a stage name that is not sesh-deploy-<14 digits>' {
        { Get-SeshSetupCommand -StageName 'x; rm -rf /' } | Should -Throw
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run the Pester command with `$c.Run.Path = 'tests\pester\deploy.Tests.ps1'`.
Expected: failure in `BeforeAll`, because `laptop\deploy.ps1` does not exist.

- [ ] **Step 3: Write `laptop/deploy.ps1` to the behaviour above. Do not run it.**

- [ ] **Step 4: Run until green, then the whole Pester folder**

Expected: `deploy.Tests.ps1` reports 14 passed; `tests\pester` reports 0 failed overall.

- [ ] **Step 5: Commit**

```
git add laptop/deploy.ps1 tests/pester/deploy.Tests.ps1
git commit -m "Add deploy.ps1: LF staging, publickey-only admin copy, sticky flags, profile and ssh config append"
```

---

### Task 15: `tests/smoke.ps1`: the operator's end-to-end smoke test

**Model:** Sonnet. **Depends on:** Task 12.

**Agents never run `smoke.ps1` against the real wrapper** (spec 12.3, 16). The Pester test drives it with a fake wrapper.

**Files:**
- Create: `tests/smoke.ps1`. It lives under `tests/`, so it needs LF endings and ASCII only.
- Create: `tests/pester/smoke.Tests.ps1`

**Interfaces:**
- Consumes: the wrapper interface from Task 12 (`& <wrapper> <words...>`, with the exit code in `$LASTEXITCODE`), and the broker output strings from Tasks 4-9: `created <n> in`, `sent <bytes> bytes to <n>`, `locked <n>`, `unlocked <n>`, `tombstoned <n>;`, `restored <n>`, `killed <n>`; ls rows starting `<n>  live` / `zz~<n>~<epoch>  tombstone`; audit JSON lines containing `"verb":"<v>"` and `"session":"<n>"`.
- Produces: run it with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 [-Wrapper <path>]`. The default wrapper is `$HOME\scripts\sesh.ps1`. Exit 0 when every step passes, 1 at the first mismatch.

**Behaviour (spec 12.3, plan Q17):**
- `param([string]$Wrapper = (Join-Path $HOME 'scripts\sesh.ps1'))`.
- Choose a session name `$n` of `smoke-` plus 6 random characters from `abcdefghijklmnopqrstuvwxyz0123456789`.
- A helper runs one step. It calls `& $Wrapper @words`, checks `$LASTEXITCODE` against the expected code, and optionally matches a regex (built with `[regex]::Escape($n)`) against the output as one string. It prints `PASS <step>` or `FAIL <step>: <reason>` with `Write-Host`. On the first failure it prints a cleanup hint, `sesh rm <n> --now --confirm <n>` (if a session may be left), and then `exit 1`.
- Output is captured with `$out = & $Wrapper @words | Out-String` for every step **except** step 1. `auth` must run uncaptured, because the `TOTP: ` prompt arrives on ssh's stdout and capturing it would hide the prompt. Gated verbs after `auth` reuse the lease.
- Steps, in order:
  1. `auth` uncaptured, expect exit 0. Before it, print `Type the code from your phone at the TOTP prompt.`
  2. `new <n>`: exit 0, output matches `created <n> in `.
  3. `ls`: exit 0, output matches `(?m)^<n>\s+live`.
  4. `peek <n>`: exit 0.
  5. `send <n> /help`: exit 0, output matches `sent \d+ bytes to <n>` (Q17).
  6. `lock <n>`: exit 0, output matches `locked <n>`.
  7. `rm <n>`: **exit 3**, because a locked session is refused.
  8. `unlock <n>`: exit 0.
  9. `rm <n>`: exit 0, output matches `tombstoned <n>;`.
  10. `ls`: exit 0, output matches `(?m)^zz~<n>~\d+\s+tombstone`.
  11. `restore <n>`: exit 0, output matches `restored <n>`.
  12. `rm <n> --now --confirm <n>`: exit 0, output matches `killed <n>`.
  13. `log -n 20`: exit 0. For each verb in `new peek send lock rm unlock restore`, some line contains both `"verb":"<v>"` and `"session":"<n>"`.
- At the end, print `smoke: all steps passed` and `exit 0`.

- [ ] **Step 1: Write the failing test `tests/pester/smoke.Tests.ps1`**

```powershell
# Pester 5 tests for tests/smoke.ps1, driven by a fake wrapper that simulates the broker.
BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Smoke = Join-Path $Repo 'tests\smoke.ps1'
    $script:Fake = Join-Path $TestDrive 'fake-sesh.ps1'
    $fakeText = @'
# Fake wrapper: simulates the broker for smoke.ps1 tests. State lives in $env:SESH_FAKE_DIR.
$dir = $env:SESH_FAKE_DIR
Add-Content -LiteralPath (Join-Path $dir 'calls.log') -Value ($args -join ' ') -Encoding ascii
$stateFile = Join-Path $dir 'state'
$nameFile = Join-Path $dir 'name'
$lockFile = Join-Path $dir 'locked'
$verb = [string]$args[0]
$name = [string]$args[1]
switch -CaseSensitive ($verb) {
    'auth'    { exit 0 }
    'new'     { Set-Content -LiteralPath $nameFile -Value $name -Encoding ascii
                Set-Content -LiteralPath $stateFile -Value 'live' -Encoding ascii
                "created $name in /home/claude/work/$name"; exit 0 }
    'ls'      { $s = Get-Content -LiteralPath $stateFile -ErrorAction SilentlyContinue
                $n = Get-Content -LiteralPath $nameFile -ErrorAction SilentlyContinue
                'NAME  STATE  ATTACHED  AGE  IDLE  TITLE'
                if ($s -eq 'live') { "$n  live    1m  1m  x" }
                if ($s -eq 'tombstone') { "zz~$n~1790000000  tombstone    1m  1m  x" }
                exit 0 }
    'peek'    { 'some pane text'; exit 0 }
    'send'    { "sent 5 bytes to $name"; exit 0 }
    'lock'    { Set-Content -LiteralPath $lockFile -Value 1 -Encoding ascii; "locked $name"; exit 0 }
    'unlock'  { Remove-Item -LiteralPath $lockFile -ErrorAction SilentlyContinue; "unlocked $name"; exit 0 }
    'rm'      { if ((Test-Path -LiteralPath $lockFile) -and -not $env:SESH_FAKE_IGNORE_LOCK) { exit 3 }
                if ($args -ccontains '--now') { Set-Content -LiteralPath $stateFile -Value 'gone' -Encoding ascii; "killed $name"; exit 0 }
                Set-Content -LiteralPath $stateFile -Value 'tombstone' -Encoding ascii
                "tombstoned $name; still running, reaped in 24h; restore with: sesh restore $name"; exit 0 }
    'restore' { Set-Content -LiteralPath $stateFile -Value 'live' -Encoding ascii; "restored $name"; exit 0 }
    'log'     { foreach ($c in Get-Content -LiteralPath (Join-Path $dir 'calls.log')) {
                    $w = $c -split ' '
                    '{{"verb":"{0}","session":"{1}"}}' -f $w[0], $(if ($w.Count -gt 1) { $w[1] } else { '' })
                }
                exit 0 }
    default   { exit 2 }
}
'@
    Set-Content -LiteralPath $Fake -Value $fakeText -Encoding ascii
}

BeforeEach {
    $env:SESH_FAKE_DIR = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
    Remove-Item Env:\SESH_FAKE_IGNORE_LOCK -ErrorAction SilentlyContinue
}

AfterAll {
    Remove-Item Env:\SESH_FAKE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\SESH_FAKE_IGNORE_LOCK -ErrorAction SilentlyContinue
}

Describe 'smoke.ps1' {
    It 'passes against a broker that behaves' {
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'smoke: all steps passed'
    }

    It 'runs auth first and uses a fresh smoke-<6 chars> name' {
        & $Smoke -Wrapper $Fake *>&1 | Out-Null
        $calls = @(Get-Content -LiteralPath (Join-Path $env:SESH_FAKE_DIR 'calls.log'))
        $calls[0] | Should -BeExactly 'auth'
        $calls[1] | Should -Match '^new smoke-[a-z0-9]{6}$'
    }

    It 'fails with exit 1 when rm is not refused on a locked session' {
        $env:SESH_FAKE_IGNORE_LOCK = '1'
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'FAIL'
        $out | Should -Not -Match 'smoke: all steps passed'
    }

    It 'stops at the first failure' {
        $env:SESH_FAKE_IGNORE_LOCK = '1'
        & $Smoke -Wrapper $Fake *>&1 | Out-Null
        $calls = @(Get-Content -LiteralPath (Join-Path $env:SESH_FAKE_DIR 'calls.log'))
        $calls[-1] | Should -Match '^rm smoke-[a-z0-9]{6}$'
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run the Pester command with `$c.Run.Path = 'tests\pester\smoke.Tests.ps1'`.
Expected: failures, because `tests\smoke.ps1` does not exist.

- [ ] **Step 3: Write `tests/smoke.ps1` to the behaviour above.**

- [ ] **Step 4: Run until green, then the whole Pester folder**

Expected: `smoke.Tests.ps1` reports 4 passed. `tests\pester` reports 0 failed, and `static.Tests.ps1` now covers `tests/smoke.ps1`.

- [ ] **Step 5: Line endings, commit**

```
grep -lU "$(printf '\r')" tests/smoke.ps1 tests/pester/smoke.Tests.ps1   # must print nothing
git add tests/smoke.ps1 tests/pester/smoke.Tests.ps1
git commit -m "Add operator smoke test (smoke.ps1) with a fake-broker Pester test"
```

---

### Task 16: README

**Model:** Sonnet (documentation with judgment). **Depends on:** Tasks 14 and 15.

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: the verbs, messages, exit codes and paths in this plan's Global Constraints, Q1-Q18, and Tasks 4-15.
- Produces: the operator manual. Spec 7.3, 7.4 and 15 require usage, quoting rules, migrating from root, residual risks and log rotation.

**Content. Use exactly these headings, in this order (the verification greps for them):**
1. `# sesh`: one paragraph on what it is (spec 1), and the two SSH identities (spec 3 table).
2. `## Install (operator)`:
   - Admin key, using the O1 pipe-free command and why (Q18).
   - Task 0 facts (O2) and the harmless BOM line.
   - First deploy: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1`. It asks for the passphrase twice. The first run shows the TOTP QR code; never paste that output anywhere.
   - The setup first-run checklist.
   - `-HardenRoot`, which is sticky once applied (Q1).
   - `-RotateTotp` and `-UnlockOtp` (Q4).
3. `## Everyday use`:
   - A table of every verb with its arguments, whether it is gated, and a one-line example.
   - The exit-code table (spec 5.4).
   - Names: `^[a-z][a-z0-9_-]{0,31}$`. They start with a letter so PowerShell does not turn `1kb` into 1024.
   - Tombstones and the 24-hour reaper; `rm --now` confirmation; `go` detaches other clients; detaching is `Ctrl-b d`.
4. `## Quoting rules (PowerShell 5.1)`:
   - Single-quote inline text: `sesh send api 'fix the build; then run tests'`.
   - `sesh send api` with no text prompts locally, and is the safest form.
   - `,` makes an array, and words are joined with single spaces.
   - PowerShell drops `--` and empty arguments before `sesh` sees them.
   - `-n` works because the wrapper has no param block.
5. `## TOTP, leases and lockout`:
   - `sesh auth`; the lease is 30 minutes per key and client IP.
   - Three failures in 10 minutes give a 5-minute cooldown. Ten failures give a hard lock: recover with `deploy.ps1 -UnlockOtp`, or as root `rm /home/claude/.sesh/otp-locked`.
   - The code is read on the VPS terminal and never logged.
6. `## Migrating from root`. The steps over the admin path:
   1. List root tmux sessions (`tmux ls`).
   2. Finish or save work, then `tmux kill-session -t '=<name>'`.
   3. `mv /root/<project> /home/claude/work/<name>`, then `chown -R claude:claude /home/claude/work/<name>`.
   4. On the laptop, `sesh resume <name>`. It recreates the session there. `claude --continue` finds no earlier conversation because history is keyed by path; start fresh with `sesh go <name>`.
   5. Check that setup's report no longer lists root `claude` processes.
7. `## Audit log and rotation`:
   - Path and format (spec 7.3), with the example line.
   - `sesh log -n 50`.
   - Rotation as root (spec 7.3): `chattr -a /var/log/sesh/audit.log`, rotate (for example move the file aside and re-run deploy, or truncate after archiving), then `chattr +a`.
   - No automatic rotation in v1.
8. `## Security model and residual risks`: spec 2, 7.4 and D1-D4, stated plainly. Include:
   - The gate does not hold against code running as `claude`.
   - Sessions can `tmux kill-server` or `send-keys` into each other.
   - `docker` group membership is root-equivalent.
   - **The sudoers allowlist is also effectively root-equivalent.** `systemctl status` and `journalctl` open a pager as root, from which `!sh` gives a shell, and `apt-get install` accepts `-o` hook options.
   - A key thief gets about three guesses per ten minutes until the hard lock.
   - `.bashrc` is sourced before the forced command.
9. `## Development and tests`:
   - Bats: `tests/run-bats.ps1` (Docker Desktop).
   - Pester: the install line from spec 12.2, plus the run command from Execution notes.
   - The smoke test is operator-only.
   - `.gitattributes` and why LF matters.
10. `## Troubleshooting`:
    - The 255 hint.
    - `TOTP required` (run `sesh auth` in a terminal).
    - `cooldown`.
    - `OTP locked`.
    - `audit log not writable`.
    - Completion showing nothing offline for up to 60 seconds, which is cached by design.

- [ ] **Step 1: Write `README.md`.**

- [ ] **Step 2: Verify the headings and the risk statements**

Run in Git Bash:

```
for h in '# sesh' '## Install (operator)' '## Everyday use' '## Quoting rules (PowerShell 5.1)' '## TOTP, leases and lockout' '## Migrating from root' '## Audit log and rotation' '## Security model and residual risks' '## Development and tests' '## Troubleshooting'; do grep -qxF "$h" README.md || echo "missing: $h"; done
grep -c 'chattr -a' README.md; grep -c 'root-equivalent' README.md; grep -c 'UnlockOtp' README.md
```

Expected: no `missing:` lines, and each count is at least 1.

- [ ] **Step 3: Commit**

```
git add README.md
git commit -m "Add README: install, usage, quoting, TOTP, migration, audit rotation, residual risks"
```

---

### Task 17: Full-suite verification report

**Model:** Haiku (run commands, collect and summarise output; change nothing). **Depends on:** Task 16.

**Files:** none (read-only).

- [ ] **Step 1: Run the whole bats suite**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/run-bats.ps1`
Record the final `N tests, M failures` line and the names of any failing tests.

- [ ] **Step 2: Run the whole Pester suite**

Run the Pester command from Execution notes with `$c.Run.Path = 'tests\pester'`.
Record the `Tests Passed: N, Failed: M` line and the names of any failing tests.

- [ ] **Step 3: Static checks**

Run in Git Bash:

```
grep -rlIU "$(printf '\r')" vps tests          # expect no output
git ls-files --eol vps tests | grep -v 'i/lf' || true   # expect no output
git ls-files -s vps/sesh vps/sesh-setup vps/vps-facts.sh tests/bats/stubs/oathtool   # expect mode 100755 on each
git status --porcelain              # expect no output
```

- [ ] **Step 4: Report**

Report a short table: bats totals, Pester totals, CR check, eol check, exec bits, and clean tree. Include any failing test names verbatim. **Do not fix anything**; if something failed, report it for the orchestrator to re-brief.

---

### OPERATOR O3: First deploy: human only

**No agent action.** Unblocked when Task 17 is all green, GATE G1 has passed, and O1 is done.

1. From the repo root: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1`.
2. Type the admin passphrase twice (scp, then ssh).
3. The first run prints the TOTP secret and a QR code. Scan it into your authenticator app. **Never paste this output into an agent conversation.**
4. The run ends with the `sesh ls` proof of life (a header row) and `deploy: done`.
5. Open a new PowerShell window so the profile loads the `sesh` function and its completer.
6. Tell the orchestrator only "deploy succeeded" or "failed at step N with exit code X". If it failed, a line of setup's own output is fine to share, but never one containing the secret or the QR code.

### OPERATOR O4: Claude Code login in the first session (spec 10 checklist item 2): human only

1. Run `sesh new scratch`. Type the phone code at `TOTP: `.
2. Run `sesh go scratch`.
3. Complete the Claude Code login inside it, then detach with `Ctrl-b d`.

### OPERATOR O5: Migrate existing work from root (spec 10 checklist item 3): human only, when convenient

Follow README `## Migrating from root` over the admin path. Re-run `deploy.ps1` afterwards if you want setup's report to confirm that no `claude` process runs as root.

### OPERATOR O6: Smoke test (spec 12.3): human only

1. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1`.
2. Type the phone code when prompted.
3. It should end with `smoke: all steps passed`. If it fails, it prints the failing step and a cleanup command.
4. Report pass/fail and the failing step name to the orchestrator.

### OPERATOR O7: Harden root (spec 4.2, 10 checklist item 4): human only

1. Confirm the admin key works: `ssh -o PasswordAuthentication=no vps true` prompts for the passphrase and exits 0.
2. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1 -HardenRoot`.
3. Verify that `ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no vps true` is now refused.
4. Later plain deploys keep hardening on (Q1). If setup aborts with `permitrootlogin is still yes`, an earlier sshd drop-in overrides it. Edit that file over the admin path, then re-run.
