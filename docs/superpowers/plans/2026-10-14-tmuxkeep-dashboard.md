# tmuxkeep v1.2 Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `tmuxkeep ui`, a local web page on the laptop that shows every tmuxkeep session with a live preview and buttons for the everyday verbs, backed by a new read-only broker verb `status` and a way to end a lease early (`auth --end`), without weakening any security property of tmuxkeep.

**Architecture:** The broker gains `status` (one JSON snapshot per line, produced with `jq`; `--follow` repeats it every 2 seconds over one ssh connection and writes one audit line) and `auth --end`; the lease and OTP arithmetic of the gate is factored into helpers that both use. A dependency-free Node program in `dashboard/` (built-in modules only, ES modules, no build step) binds 127.0.0.1, holds the latest snapshot from one `status --follow` child, serves one HTML page, one script and one stylesheet behind a per-run token, and runs the existing verbs over ssh exactly as the wrappers encode them; `go` and `auth` open a real terminal instead. Both laptop wrappers gain the local verb `ui`, both deploy scripts gain two config keys and copy `dashboard/` next to the wrapper, and CI gains a Node job.

**Tech Stack:** bash 5 on the VPS (broker), bash 3.2 and BSD userland on the laptop (macOS `/bin/bash`), Windows PowerShell 5.1; tmux >= 3.0, jq (1.6 in the test image), OpenSSH; Node 20 or newer at run time (Node 24 on the laptop, Node 22 in CI) with `node:test`; tests: bats 1.8 in Docker (`debian:bookworm`), Pester >= 5.5 (6.2.0 installed) under `powershell.exe`, bats-core under `/bin/bash` on macOS CI, `node --test`; GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-14-tmuxkeep-dashboard-design.md` (approved; decisions D12-D19 are settled, and D1-D11 of the earlier specs stay in force). "Spec 6.2" means a section of that spec. Where this plan departs from the spec text, the departure is listed under "Questions for the orchestrator" at the end with its recommended answer, and the plan is written against that recommendation.

**How much code this plan contains:** every product file and every test is given in full or as an exact edit. The Node files, the broker edits, the wrapper `ui` blocks, `Install-TmuxkeepDashboard` and `tk_install_dashboard` were run while planning: the whole Node suite passed on Windows with Node 24.20.0 (85 passed, 1 skipped on Windows), the broker's `status`, `status --follow` and `auth --end` were exercised in Git Bash against a fake tmux layer, and the Pester `ui` tests passed under Windows PowerShell 5.1 with Pester 6.2.0. The bats files could not be run while planning (Docker was not running); their implementer runs them first and reports any failure instead of weakening a test.

## Global Constraints

Every task's requirements include this section. A task repeats what it needs; if the two ever disagree, stop and report.

**Safety**

- **G1.** No agent ever connects to the VPS or any remote host, and no agent runs `laptop/deploy.ps1`'s main, `laptop/deploy.sh`, `vps/tmuxkeep-setup`'s main, `tests/smoke.ps1` or `tests/smoke.sh` for real. Every test is offline: bats in Docker (`bash tests/run-bats.sh [file]`), Pester under Windows PowerShell 5.1 (`Invoke-Pester -Configuration` with `Run.Path='tests\pester'`), Node tests with `node --test "dashboard/test/*.test.js"` (Node 24 on the laptop, Node 22 in CI; see Q2 for why the spec's `node --test dashboard/test` is not used).
- **G2.** Pester child-process tests of `deploy.ps1` must bind `-HomeDir` and `-ProfilePath` (a 2026-10-12 incident ran the real main against the user's home). The existing `Invoke-Deploy` helper does; use it.
- **G3.** Any `producer | head` pipeline must have a bounded producer (the CI hang lesson). `status --follow` never ends on its own, so every test pipeline that reads it runs under `timeout 30` and treats exit 124 as a failure.
- **G4.** No real address, hostname or personal path anywhere in the tree: examples use `203.0.113.10`, `198.51.100.x` and the user name `you`. Edit `docs/superpowers/**` in no task.
- **G5.** No test ever opens a browser or a terminal window. Every Node test that can reach `openTerminal` or `openBrowser` sets `TMUXKEEP_TERMINAL_DRYRUN=1` or injects a fake `spawnFn`; every server test passes `--no-open` or sets `TMUXKEEP_TERMINAL_DRYRUN=1`.

**Verification**

- **G6.** Bats (Git Bash on Windows, any shell on macOS and Linux): `bash tests/run-bats.sh tests/bats/<file>.bats`; with no argument it runs the whole `tests/bats` directory. Docker must be running; if `docker info` fails, stop and report `BLOCKED: Docker is not running`. **Pass means every result line is `ok N ...`, there is no `not ok` line, and the exit code is 0.**
- **G7.** Pester, from the PowerShell tool, with `$c.Run.Path` set to the file the task names or `'tests\pester'` for the whole folder. **Pass means `Tests Passed: N, Failed: 0` and exit 0.**

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

- **G8.** Node, from the repository root: `node --test "dashboard/test/*.test.js"` (keep the quotes: Node expands the pattern itself, on every platform). **Pass means `fail 0` in the summary and exit 0.** On Windows one server test is reported as skipped (SIGTERM).
- **G9.** Before every commit run the whole bats directory, the whole Pester folder and, from Task 5 on, the whole Node suite; all pass. No task leaves any suite red.
- **G10.** shellcheck runs only inside the Docker image and on macOS CI, as `shellcheck --shell=bash -S warning <file>` with no exclusions and no new `# shellcheck disable` directive anywhere (bats files included).

**Files and line endings**

- **G11.** LF line endings in every file the VPS, bash or Node reads. `.gitattributes` forces LF for `vps/**`, `tests/**`, `laptop/*.sh`, `laptop/completion.bash`, `.github/**` and, from Task 5 on, `dashboard/**`. The laptop's git has `core.autocrlf=true`. Check in Git Bash, which must print nothing: `grep -rlIU "$(printf '\r')" vps tests dashboard laptop/*.sh laptop/completion.bash` (the `-U` is required). Fix an offender with `sed -i 's/\r$//' <file>` in Git Bash.
- **G12.** Every file this plan creates or edits is ASCII only. Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI, so a `.ps1` file must never contain a byte above 127 (build non-ASCII test strings with `[char]0x00E9`). In JavaScript build a non-ASCII test string with `String.fromCodePoint(0xe9)` or `String.fromCharCode(...)`, never with a literal character or a `\u` escape of a printable character. `dashboard/test/static.test.js` (Task 5) enforces ASCII, LF and no BOM for every file under `dashboard/`.
- **G13.** `core.fileMode=false`: record exec bits with `git add --chmod=+x`. No new file in this plan needs one (`server.js` and the stub are run with `node`).

**Windows PowerShell 5.1 (every `.ps1`)**

- **G14.** `laptop/tmuxkeep.ps1` keeps no `param()` block and no `[CmdletBinding()]` at the top (they would capture `-n` and `-d`). Local errors are printed with `Write-Host`, as the wrapper already does.
- **G15.** Never write a file with `>`, `Out-File`, `Set-Content` or `Tee-Object` in product code; tests may use `Set-Content -Encoding ascii`. Use `-LiteralPath` for every path. Inside double-quoted strings write `${Path}:` (never `$Path:`).
- **G16.** Never redirect a native command's stderr in product scripts (5.1 wraps each line in an error record). `node` in the `ui` verb and every `ssh` run as plain statements so the console stays attached.
- **G17.** Pester 6: no file-level `BeforeEach` (each file is one top-level `Describe`); never put angle brackets in an `It` or `Describe` name (the deliberate `-ForEach` templates such as `'rejects <Name>'` are the exception). A test file that dot-sources `laptop/deploy.ps1` must not use the variable names `$Config`, `$Init`, `$HardenRoot`, `$RotateTotp`, `$UnlockOtp`, `$HomeDir` or `$ProfilePath`.

**bash on the laptop: 3.2 (macOS `/bin/bash`) and BSD userland**

These rules apply to `laptop/tmuxkeep.sh`, `laptop/deploy.sh`, `laptop/completion.bash`, `tests/bats/laptop-helpers.bash`, `tests/smoke.sh` and every bats file that loads `laptop-helpers`.

- **G18.** None of: associative arrays, `declare -n`/`-g`, `mapfile`/`readarray`, `${v,,}` `${v^^}`, `read -i`, `|&`, `;&`, `;;&`, `coproc`, `[[ -v`, `${v@Q}`, negative subscripts, `printf '%(...)T'`, `EPOCHSECONDS`, `BASHPID`, `wait -n`, `&>>`, `shopt -s globstar|lastpipe`. No `set -u`. No GNU-only tools or flags (`sed -i`, `grep -P`, `readlink -f`, `date -d`, `base64 -w`/`-d`, `realpath`, `timeout`, `mktemp --suffix`). `tests/bats/lint-laptop.bats` enforces these.
- **G19.** Tests run scripts with `"$BASH"`, never a bare `bash`. In `laptop/` product files the completer's ssh stays the only command whose stderr is discarded (`command -v node >/dev/null` discards nothing: `command -v` prints nothing on stderr).

**Broker rules carried from v1.1 (`vps/tmuxkeep`)**

- **G20.** `fail` and `succeed` exit the shell: never call them inside `$(...)`, a pipeline segment or `cmd | while read`. Every verb calls `authorize` once, after validating its arguments and before touching tmux; the one exception is `auth --end` (spec 4.2: it does not take the gate). Every tmux call goes through `tmx`, targets through `tmux_on`. Arithmetic on any value read from a file or an argument uses `10#`. Audit lines are built with `jq -acn ... 2>/dev/null >> "$AUDIT_FILE"` (the `audit` function). `TMUXKEEP_*` overrides are honoured only in local mode. No `eval`, no `has-session`.
- **G21.** Exit codes: 0 ok, 2 usage, 3 refused, 4 auth, 5 not found, 1 anything else. Every failure prints one stderr line `tmuxkeep: <message>`.
- **G22.** `GATED_VERBS` stays `new go send rename unlock rm resume auth` in the broker and both wrappers; `status` and `ui` are not gated.

**Dashboard (`dashboard/`)**

- **G23.** ES modules (`"type": "module"` in `dashboard/package.json`, which has no dependencies of any kind), Node built-in modules only (`node:` specifiers), no build step, no `require`. ES modules are strict mode by definition. `dashboard/test/static.test.js` enforces the imports.
- **G24.** No `innerHTML`, `insertAdjacentHTML`, `outerHTML`, `document.write`, `eval(` or `new Function` in `public/app.js`, and (plan Q11) no `setAttribute`, `.dataset`, `.title =`, `.href`, `.src`, `srcdoc`, `javascript:`, `location` or `window.open` either, not even in a comment. `dashboard/test/app.test.js` greps for all of them.
- **G25.** The b64 protocol in `dashboard/lib/protocol.js` is bit-identical to the wrappers: standard base64 of UTF-8 bytes, padded; `ssh -o BatchMode=yes -o ConnectTimeout=5 tmuxkeep b64 <tokens>`; never `-t` from the server; stdin closed. `tests/fixtures/b64-words` pins it for all three clients.
- **G26.** Test seams, and only these: `TMUXKEEP_SSH` (a path; one ending in `.js` is run with the current Node), `TMUXKEEP_STUB_SCRIPT` (read by `test/stub-ssh.js` only), `TMUXKEEP_TERMINAL_DRYRUN=1` (no terminal and no browser is started), `TMUXKEEP_NODE_VERSION` (stands in for `process.versions.node`, so the version check can be tested; plan Q8).

**Process**

- **G27.** Each task names a suggested model. Stop and report, do not guess, on any design question, ambiguity, missing tool, or a test that cannot pass without weakening it.
- **G28.** One commit per task on the branch you were given, with the subject the task gives, ending with the attribution trailer your harness specifies. Never amend, never push.

## Review Focus

These are the inputs the spec implies but no spec test exercises, most likely first. Each has a test in the owning task.

1. **A multi-line prompt pasted into the Send box** (or one with a tab). People paste multi-line prompts into a coding assistant all day. The broker refuses every control character, so a reasonable person expects the page to refuse at once, before any ssh call, with a message that says why and what to do, and to keep the text in the box. `validate.js` answers `text contains control characters (line breaks and tabs cannot be sent; send one line at a time)` (400) and nothing runs; the page shows it and leaves the textarea alone. *Tests in Task 5 (validator) and Task 10 (HTTP 400, no action run).*
2. **A home directory whose path has a space or a quote** (`C:\Users\John Smith`, `/Users/o'brien`). Windows user names with spaces are common. **Attach** and **Authenticate** must still start the wrapper: the path stays one argv element on Windows (Windows Terminal and the console fallback), and is quoted for sh and for AppleScript on macOS; `tmuxkeep ui` must find `server.js` under such a home; deploy must copy the dashboard there. *Tests in Task 8 (terminal argv), Task 4 (Pester `ui` from a home with a space), Task 11 (deploy into `home dir`).*
3. **A pane that prints bytes that are not UTF-8 text, escape sequences, or a line of thousands of characters** (a `cat` of a binary, a progress bar). A single invalid snapshot would be dropped by the follow parser every 2 seconds, so the whole page would freeze while that pane shows it. A reasonable person expects the preview to keep updating with the odd bytes removed. The broker's `status` output stays one valid, ASCII-only JSON line, lines are cut to 400 characters and contain no control characters. *Test in Task 1.*
4. **ssh that cannot be started** (the OpenSSH client missing from `PATH`, or a `send` text so long that the Windows command line limit of 32,767 characters rejects `ssh.exe` with a large `SEND_MAX_BYTES`). An unhandled `error` event on a child process would crash the Node server and close the page. A reasonable person expects an error line on the page and the server to stay up. Actions answer `code: 1` with `tmuxkeep ui: cannot run ssh: <code>`; the follow connection shows `cannot run ssh: <code>` and backs off. *Tests in Task 6 (`runVerb`) and Task 7 (follower).*
5. **A VPS whose broker has no `status` verb** (a second laptop that later deployed an older checkout, or `node dashboard/server.js` started from a fresh checkout before deploying it). The follow child exits 2 with `tmuxkeep: unknown verb: status` and is restarted every 30 seconds. A reasonable person expects that exact line on the page, not a vague "not connected", and a README row that says to deploy again. *Test in Task 7 (the last stderr line becomes the error); README row in Task 14.*

---

## Execution notes

- **Roles.** The orchestrator briefs each task to a fresh subagent with the suggested model and reviews the diff. Ask Opus to review Task 1 (the gate refactor), Task 10 (the HTTP trust boundary) and Task 11 (deploy, which deletes and recreates a folder under the user's home).
- **Order.** Tasks 1-3 change the broker; Task 4 the wrappers; Tasks 5-10 build the dashboard bottom-up (the page, Task 9, comes before the server, Task 10, because the server reads the page's files at start-up); Task 11 changes deploy only after `dashboard/` exists, because deploy copies it; Tasks 12-14 are smoke, CI and README. This order differs from the brief's (deploy was fifth) so that every task leaves every suite green.
- **Working directory.** Commands assume the repository root (or the worktree you were given). Git Bash commands are marked; everything else runs from the PowerShell tool.
- **Bats on macOS.** Agents cannot run the macOS job. The laptop suites run in Docker with bash 5; bash 3.2 compliance is enforced statically by `tests/bats/lint-laptop.bats` and dynamically only in CI.
- **Node in the bats image.** The Docker test image has no Node and does not get one: the bats suites never run Node. The parity test reads `dashboard/lib/validate.js` as text.

## File map

| Path | Responsibility | Task |
|---|---|---|
| `vps/tmuxkeep` | `status` (one-shot), shared lease/OTP/clock/peek helpers, usage line | 1 |
| `vps/tmuxkeep` | `status --follow` | 2 |
| `vps/tmuxkeep` | `auth --end` | 3 |
| `tests/bats/broker-status.bats` (new) | `status` and `status --follow` | 1, 2 |
| `tests/bats/broker-gate.bats`, `tests/bats/broker-remote.bats` | `auth --end`; remote `status` | 1, 3 |
| `laptop/completion.bash`, `laptop/profile-snippet.ps1`, `tests/bats/completion.bats`, `tests/pester/completer.Tests.ps1`, `tests/bats/parity.bats` | verb lists gain `status` (Task 1) and `ui` (Task 4) | 1, 4 |
| `laptop/tmuxkeep.ps1`, `laptop/tmuxkeep.sh`, `tests/pester/tmuxkeep.Tests.ps1`, `tests/bats/laptop-wrapper.bats` | the local `ui` verb; the shared b64 cases (Task 5) | 4, 5 |
| `tests/fixtures/b64-words` (new) | encoding cases shared by Node, bats and Pester | 5 |
| `.gitattributes`, `tests/pester/static.Tests.ps1` | `dashboard/** text eol=lf` | 5 |
| `dashboard/package.json`, `dashboard/lib/protocol.js`, `dashboard/lib/validate.js`, `dashboard/lib/config.js` (new) | words to ssh argv, the broker's rules, the two config keys and the CLI | 5 |
| `dashboard/test/protocol.test.js`, `validate.test.js`, `config.test.js`, `static.test.js` (new) | their tests | 5 |
| `dashboard/lib/ssh.js`, `dashboard/test/stub-ssh.js`, `dashboard/test/helpers.js`, `dashboard/test/ssh.test.js` (new) | one verb over ssh; the stub | 6 |
| `dashboard/lib/follow.js`, `dashboard/test/follow.test.js` (new) | the follow connection | 7 |
| `dashboard/lib/terminal.js`, `dashboard/test/terminal.test.js` (new) | terminal and browser launchers | 8 |
| `dashboard/public/index.html`, `app.js`, `style.css`, `dashboard/test/app.test.js` (new) | the page | 9 |
| `dashboard/lib/http.js`, `dashboard/server.js`, `dashboard/test/http.test.js`, `dashboard/test/server.test.js` (new) | the request handler and the entry point | 10 |
| `laptop/deploy.ps1`, `laptop/deploy.sh`, `tests/fixtures/laptop-config`, `tests/pester/config.Tests.ps1`, `tests/pester/deploy.Tests.ps1`, `tests/bats/laptop-config.bats`, `tests/bats/laptop-deploy.bats`, `tests/bats/laptop-helpers.bash` | `DASHBOARD_PORT`, `TERMINAL_CMD`, the dashboard copy and its summary line | 11 |
| `tests/smoke.sh`, `tests/smoke.ps1`, `tests/bats/smoke.bats`, `tests/pester/smoke.Tests.ps1` | one `status` step | 12 |
| `.github/workflows/ci.yml`, `tests/bats/ci.bats` | the `dashboard` job | 13 |
| `README.md` | Dashboard section and the other spec 5/7/8 text | 14 |

## Task overview

| # | Task | Suggested model | Depends on |
|---|---|---|---|
| 1 | Broker: `status` one-shot, shared gate helpers, verb lists gain `status` | sonnet | none |
| 2 | Broker: `status --follow` | sonnet | 1 |
| 3 | Broker: `auth --end` | sonnet | 1 |
| 4 | Laptop wrappers: the local `ui` verb, verb lists gain `ui` | sonnet | 1 |
| 5 | Dashboard: package, protocol, validator, config; the shared b64 fixture | sonnet | 4 |
| 6 | Dashboard: `ssh.js` and the stub ssh | sonnet | 5 |
| 7 | Dashboard: `follow.js` | sonnet | 6 |
| 8 | Dashboard: `terminal.js` | sonnet | 5 |
| 9 | Dashboard: the page | sonnet | 5 |
| 10 | Dashboard: `http.js` and `server.js` | sonnet | 6, 7, 8, 9 |
| 11 | Deploy: two config keys and the dashboard copy | sonnet | 10 |
| 12 | Smoke tests: one `status` step | sonnet | 1 |
| 13 | CI: the `dashboard` job | haiku | 10 |
| 14 | README | sonnet | 1-13 |

Tasks 6, 8 and 9 touch disjoint files and may run in parallel lanes once Task 5 is in; Task 12 may run any time after Task 1. Everything else is sequential.

---

### Task 1: Broker: `status` one-shot, shared gate helpers, verb lists gain `status`

Suggested model: sonnet. The edits are given exactly; the judgment is in keeping the gate's behaviour identical while its arithmetic moves into helpers.

**Files:**
- Modify: `vps/tmuxkeep` (read in full; edits at 24-28 patterns, 256-265 `lease_valid`, 274-319 head of `gate`, 468-471 `clean_title`, 527-532 the row format in `verb_ls`, 574-576 the pipeline in `verb_peek`, before 580 `verb_lock`, 1008 the usage line, 1014-1016 the audit switch in `main`)
- Create: `tests/bats/broker-status.bats`
- Modify: `tests/bats/broker-remote.bats` (append after line 129, the end of the file)
- Modify: `laptop/completion.bash:9`, `laptop/profile-snippet.ps1:57`
- Modify: `tests/bats/completion.bats:24-37`, `tests/pester/completer.Tests.ps1:107-111`, `tests/bats/parity.bats:70-79`

**Interfaces:**
- Consumes: the v1.1 broker as it is at HEAD (`tmx`, `tmux_on`, `authorize`, `fail`, `succeed`, `audit`, `AUDIT_ENABLED`, `NOW`, `MODE`, `KEY_ID`, `CLIENT_IP`, `STATE_DIR`, `WORK_DIR`, `CF_USER`, `LEASE_SECS`, `OTP_FAIL_MAX`, `OTP_FAIL_WINDOW`, `OTP_COOLDOWN`, `TOMB_RE`, `TMUXKEEP_VERSION`).
- Produces (broker functions and globals, used by Tasks 2 and 3):
  - `SESSION_ROW_FORMAT` (the `list-sessions -F` format shared by `ls` and `status`);
  - `lease_left FILE` (status 0 for a valid lease and sets `LEASE_LEFT=LEASE_SECS-age`; else status 1 and `LEASE_LEFT=0`; replaces `lease_valid`);
  - `otp_scan FILE NOW` (sets `OTP_COUNT`, `OTP_NEWEST`), `otp_cooldown_left NOW` (sets `COOLDOWN_LEFT`), `fresh_now` (re-reads `NOW` unless a local test pinned it);
  - `printable_only STRING` (sets `PRINTABLE`), `pane_tail N` (filter: the peek algorithm);
  - `session_json ROW N`, `status_json N` (print one JSON line), `verb_status`.
- Produces (the wire contract every later task relies on): `tmuxkeep status [--lines N]` prints exactly one line, `{"version":...,"now":"<UTC ISO-8601>","user":"<USER>","lease_secs_left":<int>,"lease_secs":<int>,"otp":{"locked":<bool>,"fails":<int>,"cooldown_secs_left":<int>},"lines":<N>,"sessions":[{"name":...,"state":"live|locked|tombstone","tombstone_of":<base or null>,"attached":<bool>,"age_secs":<int>,"idle_secs":<int>,"title":"<max 40>","dir_exists":<bool>,"lines":[...]}]}`, keys in exactly that order, ASCII-escaped (`jq -ac`). Usage errors: `tmuxkeep: usage: tmuxkeep status [--follow] [--lines N]` and `tmuxkeep: --lines must be 0-40` (exit 2, audited). Success writes no audit line. `dir_exists` is whether `<WORK_DIR>/<name>` exists, for a tombstone `<WORK_DIR>/<base name>` (plan Q4).
- Produces (lists): `_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth status"` and the PowerShell completer's `@('new', ..., 'auth', 'status')`.

- [ ] **Step 1: Baseline**

Run (Git Bash) `git status --porcelain` (expect nothing), `bash tests/run-bats.sh` and the G7 Pester command with `'tests\pester'`. Both must be fully green before you change anything; note the bats `ok` count and `Tests Passed: N`.

- [ ] **Step 2: Write the failing broker tests**

Create `tests/bats/broker-status.bats` with exactly this content:

```bash
#!/usr/bin/env bats
# status (dashboard spec 4.1): the JSON snapshot, its bounds and its silence in the audit log.
load helpers
setup() { setup_local; }
teardown() { teardown_local; }

# status_of ARGS...: runs status and fails the test unless it printed exactly one valid JSON line.
status_of() {
  run --separate-stderr tmuxkeep status "$@"
  [ "$status" -eq 0 ] || { echo "exit $status: $stderr"; return 1; }
  [ "${#lines[@]}" -eq 1 ] || { echo "$output"; return 1; }
  jq -e . >/dev/null <<<"$output"
}

@test "status with no tmux server: one JSON line with no sessions, exit 0, no audit line, no server started" {
  status_of
  [ "$output" = "{\"version\":\"dev\",\"now\":\"$(date -u -d "@$FIXED_NOW" +%Y-%m-%dT%H:%M:%SZ)\",\"user\":\"claude\",\"lease_secs_left\":0,\"lease_secs\":1800,\"otp\":{\"locked\":false,\"fails\":0,\"cooldown_secs_left\":0},\"lines\":12,\"sessions\":[]}" ]
  [ -z "$stderr" ]
  [ "$(audit_count)" -eq 0 ]
  [ ! -e "$TMUXKEEP_TMUX_SOCKET" ]
  [ ! -e "$TMUXKEEP_HOME/gate.lock" ]
}

@test "status keys come in the spec order, for the snapshot and for each session" {
  mk_session api
  status_of
  [ "$(jq -c 'keys_unsorted' <<<"$output")" = '["version","now","user","lease_secs_left","lease_secs","otp","lines","sessions"]' ]
  [ "$(jq -c '.otp | keys_unsorted' <<<"$output")" = '["locked","fails","cooldown_secs_left"]' ]
  [ "$(jq -c '.sessions[0] | keys_unsorted' <<<"$output")" = '["name","state","tombstone_of","attached","age_secs","idle_secs","title","dir_exists","lines"]' ]
}

@test "status describes a live, a locked and a tombstone session in tmux order" {
  # +30s of slack, as in the ls table test, so a second boundary cannot change the hour.
  export TMUXKEEP_NOW=$(( $(date +%s) + 7230 ))
  mkdir -p "$TMUXKEEP_WORK/api" "$TMUXKEEP_WORK/old"
  mk_session api
  mk_session web
  mk_session 'zz~old~1789990000'
  tm set-option -t '=web:' @tmuxkeep_locked 1
  tm select-pane -t '=api:' -T 'Fix: the build: now'
  status_of
  [ "$(jq -r '[.sessions[].name] | join(" ")' <<<"$output")" = "$(session_names | tr '\n' ' ' | sed 's/ $//')" ]
  [ "$(jq -c '.sessions[] | select(.name == "api") | [.state, .tombstone_of, .attached, .title, .dir_exists]' <<<"$output")" = '["live",null,false,"Fix: the build: now",true]' ]
  [ "$(jq -c '.sessions[] | select(.name == "web") | [.state, .tombstone_of, .dir_exists]' <<<"$output")" = '["locked",null,false]' ]
  [ "$(jq -c '.sessions[] | select(.name == "zz~old~1789990000") | [.state, .tombstone_of, .dir_exists]' <<<"$output")" = '["tombstone","old",true]' ]
  jq -e '.sessions[] | select(.name == "api") | .age_secs >= 7200 and .age_secs < 7300 and .idle_secs >= 7200 and .idle_secs < 7300' <<<"$output"
  jq -e '[.sessions[].attached | type] | unique == ["boolean"]' <<<"$output"
}

@test "status lines are the pane's last N lines, trailing blank lines dropped, exactly as peek" {
  mk_session_cmd api 'printf "l%s\n" 1 2 3 4 5; exec sleep 300'
  wait_for_pane_line api l5
  status_of --lines 2
  [ "$(jq -c '[.lines, .sessions[0].lines]' <<<"$output")" = '[2,["l4","l5"]]' ]
  [ "$(jq -r '.sessions[0].lines | join(",")' <<<"$output")" = "$(tmuxkeep peek api -n 2 | paste -sd, -)" ]
  status_of
  [ "$(jq -c '.sessions[0].lines' <<<"$output")" = '["l1","l2","l3","l4","l5"]' ]
  status_of --lines 0
  [ "$(jq -c '[.lines, .sessions[0].lines]' <<<"$output")" = '[0,[]]' ]
}

@test "status --lines takes 0 to 40; anything else is a usage error, and usage errors are audited" {
  status_of --lines 40
  status_of --lines 007
  [ "$(jq .lines <<<"$output")" = 7 ]
  [ "$(audit_count)" -eq 0 ]
  local line
  local -a args
  while IFS= read -r line; do
    read -r -a args <<<"$line"
    run --separate-stderr tmuxkeep status "${args[@]}"
    [ "$status" -eq 2 ] || { echo "status $line gave $status"; return 1; }
  done <<'EOF'
--lines 41
--lines -1
--lines abc
--lines 12345
--lines
--lines 2 --lines 3
extra
--frob
EOF
  run --separate-stderr tmuxkeep status --lines 41
  [ "$stderr" = 'tmuxkeep: --lines must be 0-40' ]
  run --separate-stderr tmuxkeep status --frob
  [ "$stderr" = 'tmuxkeep: usage: tmuxkeep status [--follow] [--lines N]' ]
  [ "$(audit_count)" -eq 10 ]
  [ "$(audit_field verb)" = status ]
  [ "$(audit_field ok)" = false ]
}

@test "status reports this key id's lease and the OTP state with the gate's own arithmetic" {
  mk_lease t - $(( TMUXKEEP_NOW - 100 ))
  mk_lease other - $(( TMUXKEEP_NOW - 1 ))
  printf '%s\n' $(( TMUXKEEP_NOW - 100 )) $(( TMUXKEEP_NOW - 50 )) $(( TMUXKEEP_NOW - 10 )) junk $(( TMUXKEEP_NOW + 5 )) $(( TMUXKEEP_NOW - 9999 )) > "$TMUXKEEP_HOME/otp-fails"
  status_of
  [ "$(jq -c '[.lease_secs_left, .lease_secs, .otp]' <<<"$output")" = '[1700,1800,{"locked":false,"fails":3,"cooldown_secs_left":290}]' ]
  # The gate says the same: a cooldown of 290 seconds.
  run --separate-stderr tmuxkeep auth
  [ "$stderr" = 'tmuxkeep: cooldown, retry in 290s' ]
  : > "$TMUXKEEP_HOME/otp-locked"
  status_of
  [ "$(jq -c '.otp.locked' <<<"$output")" = true ]
  mk_lease t - $(( TMUXKEEP_NOW - 1800 ))
  status_of
  [ "$(jq '.lease_secs_left' <<<"$output")" = 0 ]
}

@test "status works with an unwritable audit log, because it writes none" {
  export TMUXKEEP_AUDIT=/nonexistent-dir/audit.log
  status_of
  [ -z "$stderr" ]
}

# Review Focus 3: whatever a program prints, the snapshot stays one valid JSON line, or the dashboard
# would drop every snapshot while that pane shows it.
@test "pane bytes that are not text, escape sequences and a 450-character line still give valid JSON, cut to 400" {
  mk_session_cmd api "printf 'bad \\377\\376 bytes\\n\\033[31mred\\033[0m\\001\\n%s\\n' \"\$(printf 'x%.0s' \$(seq 1 450))\"; exec sleep 300"
  wait_for_pane_contains api xxxxxxxxxx
  tm select-pane -t '=api:' -T "$(printf 'evil\033]0;pwned\007title')"
  status_of --lines 3
  jq -e '.sessions[0].lines | length == 3' <<<"$output"
  jq -e '.sessions[0].lines[0] | (startswith("bad") and endswith("bytes"))' <<<"$output"
  jq -e '.sessions[0].lines[2] == ("x" * 400)' <<<"$output"
  jq -e '[.sessions[0].lines[], .sessions[0].title] | all(explode | all(. >= 32 and . != 127 and (. < 128 or . > 159)))' <<<"$output"
  [ "$(LC_ALL=C tr -d '\000-\177' <<<"$output" | wc -c)" -eq 0 ]
}

@test "a session name no verb accepts and a title full of colons keep their fields" {
  export TMUXKEEP_NOW=$(( $(date +%s) + 7230 ))
  mk_session 'a|b'
  mk_session Bad
  tm select-pane -t '=a|b:' -T 'one: two: three'
  status_of
  [ "$(jq -c '.sessions[] | select(.name == "a|b") | [.state, .title]' <<<"$output")" = '["live","one: two: three"]' ]
  jq -e '.sessions[] | select(.name == "a|b") | .age_secs >= 7200' <<<"$output"
  jq -e 'any(.sessions[]; .name == "Bad")' <<<"$output"
}

@test "lease_left, otp_scan and otp_cooldown_left are the one copy of the gate arithmetic" {
  export LC_ALL=C.UTF-8
  source "$TMUXKEEP_BIN"
  NOW=1000000 LEASE_SECS=1800 OTP_FAIL_MAX=3 OTP_FAIL_WINDOW=600 OTP_COOLDOWN=300
  printf '%s\n' 999000 > "$BATS_TEST_TMPDIR/lease"
  lease_left "$BATS_TEST_TMPDIR/lease"
  [ "$LEASE_LEFT" -eq 800 ]
  printf '%s\n' 998200 > "$BATS_TEST_TMPDIR/lease"
  run lease_left "$BATS_TEST_TMPDIR/lease"
  [ "$status" -eq 1 ]
  printf '%s\n' 999700 999800 999900 1000100 > "$BATS_TEST_TMPDIR/fails"
  otp_scan "$BATS_TEST_TMPDIR/fails" 1000000
  [ "$OTP_COUNT" -eq 3 ]
  [ "$OTP_NEWEST" -eq 999900 ]
  otp_cooldown_left 1000000
  [ "$COOLDOWN_LEFT" -eq 200 ]
  otp_scan "$BATS_TEST_TMPDIR/missing" 1000000
  otp_cooldown_left 1000000
  [ "$OTP_COUNT" -eq 0 ]
  [ "$COOLDOWN_LEFT" -eq 0 ]
  [ "$(grep -c 'OTP_FAIL_WINDOW )); then continue' "$TMUXKEEP_BIN")" -eq 1 ]
  [ "$(grep -c 'age < LEASE_SECS' "$TMUXKEEP_BIN")" -eq 1 ]
}
```

Append to the end of `tests/bats/broker-remote.bats`:

```bash

@test "remote: status is not gated, writes no audit line, and reports the lease of this key id and client IP" {
  rtm new-session -d -s api
  printf '%s\n' "$(date +%s)" > /home/claude/.tmuxkeep/leases/laptop@203.0.113.9
  run remote 203.0.113.9 laptop status
  [ "$status" -eq 0 ]
  jq -e '.lease_secs_left > 1790 and .lease_secs_left <= 1800 and ([.sessions[].name] == ["api"]) and .user == "claude"' <<<"$output"
  run remote 198.51.100.7 laptop "$(b64cmd status --lines 0)"
  [ "$status" -eq 0 ]
  jq -e '.lease_secs_left == 0 and .lines == 0 and .sessions[0].lines == []' <<<"$output"
  [ ! -s /var/log/tmuxkeep/audit.log ]
}
```

- [ ] **Step 3: Run them to see them fail**

Run (Git Bash): `bash tests/run-bats.sh tests/bats/broker-status.bats`
Expected: `not ok` for all ten tests: `status` is still `tmuxkeep: unknown verb: status` (exit 2), and the last test finds no `lease_left`.

- [ ] **Step 4: Add the shared row format**

In `vps/tmuxkeep`, after line 28 (`URL_RE='^https://[!-~]+$'`), insert:

```bash
# The fields ls and status read per session. ":" separates them, not tab (tab is IFS whitespace and
# would collapse an empty @tmuxkeep_locked field) and not "|" (a legal character in a session name).
# tmux rewrites ":" in session names to "_", so no earlier field can contain it. The title is last,
# so a ":" inside a title stays in the title.
SESSION_ROW_FORMAT='#{session_name}:#{session_created}:#{session_activity}:#{session_attached}:#{@tmuxkeep_locked}:#{pane_title}'
```

In `verb_ls`, replace

```bash
  # ":" separates the fields, not tab (tab is IFS whitespace and would collapse an empty
  # @tmuxkeep_locked field) and not "|" (a legal character in a session name). tmux rewrites
  # ":" in session names to "_", so no earlier field can contain it. The title is last, so
  # a ":" inside a title stays in the title.
  local -a rows=()
  mapfile -t rows < <(tmx list-sessions -F '#{session_name}:#{session_created}:#{session_activity}:#{session_attached}:#{@tmuxkeep_locked}:#{pane_title}' 2>/dev/null)
```

with

```bash
  local -a rows=()
  mapfile -t rows < <(tmx list-sessions -F "$SESSION_ROW_FORMAT" 2>/dev/null)
```

- [ ] **Step 5: Factor the lease, OTP and clock arithmetic out of the gate**

Replace `lease_valid` (lines 256-265, from its comment line to its closing brace) with:

```bash
# lease_left FILE: status 0 when FILE holds a digits-only epoch E with 0 <= NOW - E < LEASE_SECS, and
# LEASE_LEFT is then LEASE_SECS - (NOW - E). Anything else (missing, empty, signs, spaces, more than
# 15 digits, a future epoch) is no lease: status 1 and LEASE_LEFT=0. Used by gate and status.
lease_left() {
  local e='' age
  LEASE_LEFT=0
  [[ -f $1 ]] || return 1
  { IFS= read -r e < "$1" || [[ -n $e ]]; } 2>/dev/null || return 1
  [[ $e =~ ^[0-9]{1,15}$ ]] || return 1
  age=$(( 10#$NOW - 10#$e ))
  (( age >= 0 && age < LEASE_SECS )) || return 1
  LEASE_LEFT=$(( LEASE_SECS - age ))
}

# otp_scan FILE NOW: sets OTP_COUNT to the entries of FILE inside OTP_FAIL_WINDOW (0 <= NOW - E <
# OTP_FAIL_WINDOW) and OTP_NEWEST to the newest of them (0 when none). Lines that are not 1-15 digits
# are ignored; a missing or unreadable file counts as empty (gate refuses an unreadable one first).
otp_scan() {
  local e age now=$2
  OTP_COUNT=0
  OTP_NEWEST=0
  [[ -f $1 && -r $1 ]] || return 0
  while IFS= read -r e || [[ -n $e ]]; do
    [[ $e =~ ^[0-9]{1,15}$ ]] || continue
    e=$(( 10#$e ))
    age=$(( now - e ))
    if (( age < 0 || age >= OTP_FAIL_WINDOW )); then continue; fi
    OTP_COUNT=$(( OTP_COUNT + 1 ))
    if (( e > OTP_NEWEST )); then OTP_NEWEST=$e; fi
  done < "$1"
}

# otp_cooldown_left NOW: sets COOLDOWN_LEFT from OTP_COUNT and OTP_NEWEST (run otp_scan first): the
# seconds until the cooldown they imply ends, 0 when there is none.
otp_cooldown_left() {
  COOLDOWN_LEFT=0
  if (( OTP_COUNT >= OTP_FAIL_MAX && $1 - OTP_NEWEST < OTP_COOLDOWN )); then
    COOLDOWN_LEFT=$(( OTP_COOLDOWN - ($1 - OTP_NEWEST) ))
  fi
}

# fresh_now: a new reading of the clock into NOW, unless a local-mode test pinned it with TMUXKEEP_NOW.
fresh_now() {
  local fresh
  if [[ ${MODE:-} != local ]] || ! [[ ${TMUXKEEP_NOW:-} =~ ^[0-9]+$ ]]; then
    fresh=$(date +%s 2>/dev/null) || fresh=''
    if [[ $fresh =~ ^[0-9]+$ ]]; then NOW=$fresh; fi
  fi
}
```

In `gate`, replace this block (from the second `local` line through the cooldown `fi`, original lines 277-319):

```bash
  local e='' code='' matched='' lastraw='' fresh='' made_lock=0 count=0 newest=0 last=0 n=0
  local age secret step s out

  # 1. State directory and the lock that serialises every gated call.
  mkdir -p "$STATE_DIR/leases" 2>/dev/null || fail 1 "cannot create state directory"
  { exec 9>>"$STATE_DIR/gate.lock"; } 2>/dev/null || fail 1 "cannot open the gate lock"
  flock 9 || fail 1 "cannot take the gate lock"

  # main sampled NOW before the lock wait, which can last a whole prompt. Take a fresh reading
  # unless a local-mode test pinned the clock with TMUXKEEP_NOW.
  if [[ ${MODE:-} != local ]] || ! [[ ${TMUXKEEP_NOW:-} =~ ^[0-9]+$ ]]; then
    fresh=$(date +%s 2>/dev/null) || fresh=''
    if [[ $fresh =~ ^[0-9]+$ ]]; then NOW=$fresh; fi
  fi
  now=$(( 10#$NOW ))

  # 2. Hard lockout: root must remove the marker. It overrides a valid lease.
  if [[ -e $locked_file || -L $locked_file ]]; then
    fail 3 "OTP locked after repeated failures; root must remove $locked_file" otp-locked
  fi

  # 3. A valid lease for this key id and client IP skips the prompt, except for auth itself.
  if [[ $VERB != auth ]] && lease_valid "$lease"; then
    exec 9>&-
    return 0
  fi

  # 4. Cooldown: OTP_FAIL_MAX failures inside OTP_FAIL_WINDOW, the newest younger than OTP_COOLDOWN.
  # newest is taken over the counted (in-window) entries. Lines that are not digits are ignored.
  if [[ -e $fails_file && ! -r $fails_file ]]; then fail 1 "cannot read otp-fails"; fi
  if [[ -f $fails_file ]]; then
    while IFS= read -r e || [[ -n $e ]]; do
      [[ $e =~ ^[0-9]{1,15}$ ]] || continue
      e=$(( 10#$e ))
      age=$(( now - e ))
      if (( age < 0 || age >= OTP_FAIL_WINDOW )); then continue; fi
      count=$(( count + 1 ))
      if (( e > newest )); then newest=$e; fi
    done < "$fails_file"
  fi
  if (( count >= OTP_FAIL_MAX && now - newest < OTP_COOLDOWN )); then
    fail 4 "cooldown, retry in $(( OTP_COOLDOWN - (now - newest) ))s" cooldown
  fi
```

with:

```bash
  local e='' code='' matched='' lastraw='' made_lock=0 last=0 n=0
  local secret step s out

  # 1. State directory and the lock that serialises every gated call.
  mkdir -p "$STATE_DIR/leases" 2>/dev/null || fail 1 "cannot create state directory"
  { exec 9>>"$STATE_DIR/gate.lock"; } 2>/dev/null || fail 1 "cannot open the gate lock"
  flock 9 || fail 1 "cannot take the gate lock"

  # main sampled NOW before the lock wait, which can last a whole prompt.
  fresh_now
  now=$(( 10#$NOW ))

  # 2. Hard lockout: root must remove the marker. It overrides a valid lease.
  if [[ -e $locked_file || -L $locked_file ]]; then
    fail 3 "OTP locked after repeated failures; root must remove $locked_file" otp-locked
  fi

  # 3. A valid lease for this key id and client IP skips the prompt, except for auth itself.
  if [[ $VERB != auth ]] && lease_left "$lease"; then
    exec 9>&-
    return 0
  fi

  # 4. Cooldown: OTP_FAIL_MAX failures inside OTP_FAIL_WINDOW, the newest younger than OTP_COOLDOWN
  # (otp_scan and otp_cooldown_left, shared with status).
  if [[ -e $fails_file && ! -r $fails_file ]]; then fail 1 "cannot read otp-fails"; fi
  otp_scan "$fails_file" "$now"
  otp_cooldown_left "$now"
  if (( COOLDOWN_LEFT > 0 )); then fail 4 "cooldown, retry in ${COOLDOWN_LEFT}s" cooldown; fi
```

The rest of `gate` (steps 5-11) is unchanged; it still uses `e` and `n`. `git grep -n lease_valid` must print nothing afterwards.

- [ ] **Step 6: One copy of the character filter and of the peek algorithm**

Replace `clean_title` and its comment (lines 468-471) with:

```bash
# printable_only STRING: sets PRINTABLE to STRING with every non-printable character removed, which
# includes C0, DEL and the UTF-8 C1 controls U+0080-U+009F. Needs a UTF-8 LC_ALL (main exports
# C.UTF-8). clean_title prints the same; status uses this form to avoid a subshell per pane line.
printable_only() { PRINTABLE=${1//[^[:print:]]/}; }

# clean_title STRING: prints STRING through printable_only's filter. Use it on any tmux-supplied
# text that is shown to a terminal.
clean_title() { printable_only "$1"; printf '%s' "$PRINTABLE"; }

# pane_tail N: stdin without its trailing blank lines, then the last N lines of what is left. The one
# copy of the peek algorithm, used by peek and status.
pane_tail() {
  awk '{ l[NR] = $0 } /[^[:space:]]/ { last = NR } END { for (i = 1; i <= last; i++) print l[i] }' | tail -n "$1"
}
```

In `verb_peek`, replace

```bash
  printf '%s\n' "$pane" \
    | awk '{ l[NR] = $0 } /[^[:space:]]/ { last = NR } END { for (i = 1; i <= last; i++) print l[i] }' \
    | tail -n "$n" || fail 1 "cannot read pane"
```

with

```bash
  printf '%s\n' "$pane" | pane_tail "$n" || fail 1 "cannot read pane"
```

- [ ] **Step 7: The `status` verb**

Insert immediately before the line `verb_lock() { # lock <name>`:

```bash
# session_json ROW N: prints the status object of one session (spec 4.1) from a SESSION_ROW_FORMAT
# row, on one line. lines are the pane's last N lines by pane_tail, each through printable_only and
# cut to 400 characters; a pane that cannot be read gives no lines. dir_exists says whether
# WORK_DIR/<name> exists (for a tombstone, WORK_DIR/<base name>).
session_json() {
  local row=$1 n=$2 name created activity attached locked title state tomb='' base att=false dir=false
  local age idle pane line
  local -a lines=()
  IFS=':' read -r name created activity attached locked title <<< "$row"
  [[ $created =~ ^[0-9]{1,15}$ ]] || created=$NOW
  [[ $activity =~ ^[0-9]{1,15}$ ]] || activity=$NOW
  age=$(( 10#$NOW - 10#$created ))
  idle=$(( 10#$NOW - 10#$activity ))
  if (( age < 0 )); then age=0; fi
  if (( idle < 0 )); then idle=0; fi
  base=$name
  if [[ $name =~ $TOMB_RE ]]; then
    state=tombstone
    tomb=${BASH_REMATCH[1]}
    base=$tomb
  elif [[ $locked == 1 ]]; then
    state=locked
  else
    state=live
  fi
  if [[ $attached =~ ^[1-9][0-9]*$ ]]; then att=true; fi
  if [[ -d $WORK_DIR/$base ]]; then dir=true; fi
  printable_only "$title"
  title=${PRINTABLE:0:40}
  # Orchestrator ruling Q10: status captures at most 1000 history lines plus the visible pane, not
  # the whole 50000-line scrollback, because it runs for every session every 2 seconds. pane_tail is
  # unchanged; only a pane whose last 1000 lines of history and screen are all blank previews empty.
  if (( n > 0 )) && pane=$(tmux_on "$name" capture-pane -p -J -S -1000 2>/dev/null); then
    while IFS= read -r line; do
      printable_only "$line"
      lines+=("${PRINTABLE:0:400}")
    done < <(printf '%s\n' "$pane" | pane_tail "$n")
  fi
  if (( ${#lines[@]} > 0 )); then printf '%s\n' "${lines[@]}"; fi |
    jq -acnR --arg name "$name" --arg state "$state" --arg tomb "$tomb" --argjson attached "$att" \
      --argjson age "$age" --argjson idle "$idle" --arg title "$title" --argjson dir "$dir" \
      '{name:$name,state:$state,tombstone_of:(if $tomb == "" then null else $tomb end),attached:$attached,age_secs:$age,idle_secs:$idle,title:$title,dir_exists:$dir,lines:[inputs]}'
}

# status_json N: prints one status snapshot (spec 4.1) on one line: version, now, user, lease and OTP
# state for this key id and client IP, and every session in tmux order. It only reads: no gate lock,
# and no tmux server is started. A tmux error or no server gives "sessions":[].
status_json() {
  local n=$1 now ts locked=false row
  local -a rows=()
  now=$(( 10#$NOW ))
  ts=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ) || return 1
  lease_left "$STATE_DIR/leases/$KEY_ID@$CLIENT_IP" || LEASE_LEFT=0
  otp_scan "$STATE_DIR/otp-fails" "$now"
  otp_cooldown_left "$now"
  if [[ -e $STATE_DIR/otp-locked || -L $STATE_DIR/otp-locked ]]; then locked=true; fi
  mapfile -t rows < <(tmx list-sessions -F "$SESSION_ROW_FORMAT" 2>/dev/null)
  for row in "${rows[@]}"; do session_json "$row" "$n"; done |
    jq -acs --arg version "$TMUXKEEP_VERSION" --arg now "$ts" --arg user "$CF_USER" \
      --argjson left "$LEASE_LEFT" --argjson lease "$LEASE_SECS" --argjson locked "$locked" \
      --argjson fails "$OTP_COUNT" --argjson cool "$COOLDOWN_LEFT" --argjson lines "$n" \
      '{version:$version,now:$now,user:$user,lease_secs_left:$left,lease_secs:$lease,otp:{locked:$locked,fails:$fails,cooldown_secs_left:$cool},lines:$lines,sessions:.}'
}

# status [--lines N]: the dashboard's read (spec 4.1, D15, D19). Not gated. It writes no audit line
# (main turned auditing off); a usage error turns auditing back on first, as in ls. Task 2 adds --follow.
verb_status() {
  local usage="usage: tmuxkeep status [--follow] [--lines N]"
  local n=12 have_lines=0 json
  while (( $# > 0 )); do
    case $1 in
      --lines)
        (( have_lines == 0 && $# >= 2 )) || { AUDIT_ENABLED=1; fail 2 "$usage"; }
        n=$2
        have_lines=1
        shift 2 ;;
      *) AUDIT_ENABLED=1; fail 2 "$usage" ;;
    esac
  done
  if ! [[ $n =~ ^[0-9]{1,4}$ ]] || (( 10#$n > 40 )); then AUDIT_ENABLED=1; fail 2 "--lines must be 0-40"; fi
  n=$(( 10#$n ))
  authorize
  json=$(status_json "$n") || fail 1 "cannot build status"
  printf '%s\n' "$json"
  exit 0
}

```

In `main`, replace the usage line

```bash
    fail 2 "usage: tmuxkeep <new|ls|peek|go|send|rename|lock|unlock|rm|restore|resume|log|auth> [args]"
```

with

```bash
    fail 2 "usage: tmuxkeep <new|ls|peek|go|send|rename|lock|unlock|rm|restore|resume|log|auth|status> [args]"
```

and right after the `ls --names`/`--tombstones` block (the `fi` that closes `AUDIT_ENABLED=0` for `ls`) insert:

```bash
  # status is an unaudited read (D19); its usage errors and --follow switch auditing back on.
  if [[ $VERB == status ]]; then AUDIT_ENABLED=0; fi
```

- [ ] **Step 8: Run the broker tests**

Run (Git Bash): `bash tests/run-bats.sh tests/bats/broker-status.bats`, then `bash tests/run-bats.sh tests/bats/broker-remote.bats`, `bash tests/run-bats.sh tests/bats/broker-gate.bats`, `bash tests/run-bats.sh tests/bats/broker-read.bats`, `bash tests/run-bats.sh tests/bats/lint.bats`.
Expected: all `ok`. `broker-gate.bats` and `broker-read.bats` are unchanged and prove the refactor kept the gate, `ls` and `peek` as they were; `lint.bats` proves shellcheck is clean. (`parity.bats` fails until Step 9: the broker now has a verb the completers lack.)

- [ ] **Step 9: Add `status` to both completers and the parity test**

`laptop/completion.bash` line 9 becomes:

```bash
_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth status"
```

`laptop/profile-snippet.ps1` line 57 becomes:

```powershell
        $candidates = @('new', 'ls', 'peek', 'go', 'send', 'rename', 'lock', 'unlock', 'rm', 'restore', 'resume', 'log', 'auth', 'status')
```

In `tests/bats/completion.bats`, replace the first two tests (lines 24-37) with:

```bash
@test "sourcing registers the completer and the two one-line lists" {
  run complete -p tmuxkeep
  [ "$output" = 'complete -F _tmuxkeep tmuxkeep' ]
  grep -qx '_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth status"' "$REPO/laptop/completion.bash"
  grep -qx '_TK_NAME_VERBS="peek go send rename lock unlock rm resume"' "$REPO/laptop/completion.bash"
}

@test "the first word completes the verbs" {
  run complete_words tmuxkeep re
  [ "$output" = "$(printf '%s\n' rename restore resume)" ]
  run complete_words tmuxkeep st
  [ "$output" = status ]
  run complete_words tmuxkeep ''
  [ "${#lines[@]}" -eq 14 ]
  [ ! -s "$TK_STUB_LOG" ]
}
```

In `tests/pester/completer.Tests.ps1`, after the `It 'completes verbs for the first word'` block (ends at line 111), insert:

```powershell

        It 'completes status for the first word' {
            $r = TabExpansion2 -inputScript 'tmuxkeep st' -cursorColumn 11
            ($r.CompletionMatches.CompletionText -join ',') | Should -BeExactly 'status'
        }
```

In `tests/bats/parity.bats`, replace the test at lines 70-79 with:

```bash
@test "the completer verb lists match the broker's verbs (reap excluded) and each other" {
  local want b p s
  want='auth go lock log ls new peek rename restore resume rm send status unlock'
  b=$(broker_verbs | sorted_words)
  [ "$b" = "$want" ] || { echo "broker verb_ functions: $b"; return 1; }
  p=$(ps_verbs); one_line 'PowerShell completer verbs' "$p"
  s=$(bash_verbs); one_line 'bash completer verbs' "$s"
  [ "$(printf '%s' "$p" | sorted_words)" = "$want" ] || { echo "PowerShell completer: $p"; return 1; }
  [ "$(printf '%s' "$s" | sorted_words)" = "$want" ] || { echo "bash completer: $s"; return 1; }
}
```

- [ ] **Step 10: Run the whole bats directory and the whole Pester folder**

Run (Git Bash): `bash tests/run-bats.sh`. Expected: the baseline count plus 11 new `ok` lines (10 in `broker-status.bats`, 1 in `broker-remote.bats`), no `not ok`, exit 0.
Run the G7 command with `'tests\pester'`. Expected: the baseline `Tests Passed` plus 1, `Failed: 0`.

- [ ] **Step 11: Commit**

```bash
git add vps/tmuxkeep tests/bats/broker-status.bats tests/bats/broker-remote.bats laptop/completion.bash laptop/profile-snippet.ps1 tests/bats/completion.bats tests/pester/completer.Tests.ps1 tests/bats/parity.bats
git commit -m "broker: status, a JSON snapshot for the dashboard; gate arithmetic shared"
```

---

### Task 2: Broker: `status --follow`

Suggested model: sonnet.

**Files:**
- Modify: `vps/tmuxkeep` (the `verb_status` function added in Task 1)
- Modify: `tests/bats/broker-status.bats` (append)

**Interfaces:**
- Consumes (Task 1): `status_json N`, `fresh_now`, `audit`, `AUDIT_ENABLED`, `authorize`, `fail`.
- Produces: `tmuxkeep status --follow [--lines N]` (options in any order, each at most once): writes one audit line first (`verb: status`, `ok: true`, `session: ""`, `detail: follow lines=N`; a failed write prints `tmuxkeep: audit write failed` on stderr and the stream still runs), then prints one snapshot per line, the first at once and then every 2 seconds, each with a fresh `NOW` and fresh tmux queries, until writing stdout fails. With SIGPIPE at its default the broker dies of SIGPIPE (exit 141); with SIGPIPE ignored the failed `printf` ends it with exit 0. If a snapshot cannot be built the stream ends with `tmuxkeep: cannot build status` (exit 1), so a broken `jq` cannot spin forever writing nothing. Task 7's follower relies on exactly this: one JSON object per line, and an exit when ssh goes away.

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/broker-status.bats`:

```bash

# follow_lines N ARGS...: the first N lines of "status --follow ARGS...", read through head. The
# producer never ends on its own, so timeout bounds the whole pipeline (the CI hang lesson); exit
# 124 would mean the broker did not stop when head went away.
follow_lines() {
  local n=$1
  shift
  timeout 30 bash -c 'n=$1; shift; bash "$@" </dev/null | head -n "$n"' _ "$n" "$TMUXKEEP_BIN" --key t status --follow "$@"
}

@test "status --follow writes one audit line first, then one valid JSON object per line" {
  mk_session api
  run follow_lines 2 --lines 5
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  local l
  for l in "${lines[@]}"; do
    [ "$(jq -c '[.lines, (.sessions | length)]' <<<"$l")" = '[5,1]' ] || { echo "$l"; return 1; }
  done
  [ "$(audit_count)" -eq 1 ]
  [ "$(audit_field verb)" = status ]
  [ "$(audit_field ok)" = true ]
  [ "$(audit_field session)" = '' ]
  [ "$(audit_field detail)" = 'follow lines=5' ]
}

@test "status --follow ends when the reader goes away: SIGPIPE by default, the failed write when SIGPIPE is ignored" {
  run timeout 30 bash -c 'bash "$1" --key t status --follow </dev/null | head -n 1 >/dev/null; echo "broker=${PIPESTATUS[0]}"' _ "$TMUXKEEP_BIN"
  [ "$status" -eq 0 ]
  [ "$output" = 'broker=141' ]
  run timeout 30 bash -c 'trap "" PIPE; bash "$1" --key t status --follow </dev/null | head -n 1 >/dev/null; echo "broker=${PIPESTATUS[0]}"' _ "$TMUXKEEP_BIN"
  [ "$status" -eq 0 ]
  [ "$output" = 'broker=0' ]
  [ "$(audit_count)" -eq 2 ]
}

@test "status --follow reads the clock again for every snapshot" {
  unset TMUXKEEP_NOW
  run follow_lines 2
  [ "$status" -eq 0 ]
  [ "$(jq -r .now <<<"${lines[0]}")" != "$(jq -r .now <<<"${lines[1]}")" ]
}

@test "status --follow with an unwritable audit log warns once on stderr and still streams" {
  export TMUXKEEP_AUDIT=/nonexistent-dir/audit.log
  run --separate-stderr follow_lines 2
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: audit write failed' ]
}

@test "status --follow given twice is a usage error, audited" {
  run --separate-stderr tmuxkeep status --follow --follow
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: usage: tmuxkeep status [--follow] [--lines N]' ]
  [ "$(audit_field ok)" = false ]
}
```

- [ ] **Step 2: Run them to see them fail**

Run (Git Bash): `bash tests/run-bats.sh tests/bats/broker-status.bats`
Expected: the ten Task 1 tests `ok`; the five new ones `not ok` (`--follow` is still a usage error, so `follow_lines` prints nothing). None of them hangs: `timeout 30` bounds every pipeline.

- [ ] **Step 3: Implement `--follow`**

Replace the whole `verb_status` function and its comment (from `# status [--lines N]: the dashboard's read` to the function's closing brace) with:

```bash
# status [--follow] [--lines N]: the dashboard's read (spec 4.1, D15, D19). Not gated. One-shot writes
# no audit line (main turned auditing off); a usage error turns it back on, as in ls. --follow writes
# one audit line, then one snapshot every 2 seconds, each with a fresh NOW, until stdout is gone: a
# closed pipe ends it by SIGPIPE, or by the failed write when SIGPIPE is ignored.
verb_status() {
  local usage="usage: tmuxkeep status [--follow] [--lines N]"
  local follow=0 n=12 have_lines=0 json
  while (( $# > 0 )); do
    case $1 in
      --follow)
        (( follow == 0 )) || { AUDIT_ENABLED=1; fail 2 "$usage"; }
        follow=1
        shift ;;
      --lines)
        (( have_lines == 0 && $# >= 2 )) || { AUDIT_ENABLED=1; fail 2 "$usage"; }
        n=$2
        have_lines=1
        shift 2 ;;
      *) AUDIT_ENABLED=1; fail 2 "$usage" ;;
    esac
  done
  if ! [[ $n =~ ^[0-9]{1,4}$ ]] || (( 10#$n > 40 )); then AUDIT_ENABLED=1; fail 2 "--lines must be 0-40"; fi
  n=$(( 10#$n ))
  authorize
  if (( ! follow )); then
    json=$(status_json "$n") || fail 1 "cannot build status"
    printf '%s\n' "$json"
    exit 0
  fi
  AUDIT_ENABLED=1
  audit true "follow lines=$n"
  AUDIT_ENABLED=0
  while :; do
    json=$(status_json "$n") || fail 1 "cannot build status"
    printf '%s\n' "$json" 2>/dev/null || exit 0
    sleep 2
    fresh_now
  done
}
```

The snapshot is built into a variable first and written by `printf` in the main shell, so a closed pipe is seen by the broker itself and not by `jq`; `2>/dev/null` keeps bash's `write error: Broken pipe` off stderr.

- [ ] **Step 4: Run the tests**

Run (Git Bash): `bash tests/run-bats.sh tests/bats/broker-status.bats`
Expected: 15 `ok`, exit 0, in well under a minute (each follow test takes 2-5 seconds). While planning, the same broker ended with `broker=141` and `broker=0` in Git Bash for the two pipelines of the second test.

- [ ] **Step 5: Run the whole bats directory and the whole Pester folder**

Expected: all green (the bats count is up by 5 from Task 1; Pester unchanged).

- [ ] **Step 6: Commit**

```bash
git add vps/tmuxkeep tests/bats/broker-status.bats
git commit -m "broker: status --follow, one audited stream of snapshots every 2 seconds"
```

---

### Task 3: Broker: `auth --end`

Suggested model: sonnet.

**Files:**
- Modify: `vps/tmuxkeep:591-596` (`verb_auth`; line numbers as at HEAD, before Task 1 moved them)
- Modify: `tests/bats/broker-gate.bats` (append after line 273, the end of the file), `tests/bats/broker-remote.bats` (append)

**Interfaces:**
- Consumes: `fail`, `succeed`, `authorize`, `STATE_DIR`, `KEY_ID`, `CLIENT_IP`.
- Produces: `tmuxkeep auth --end` removes `<STATE_DIR>/leases/<key id>@<client ip>`, prints `lease ended`, exits 0, audits `detail: lease-ended`; it takes no gate lock and asks no code, works during a cooldown and a hard lock, and succeeds when there is no lease. Any other argument: `tmuxkeep: usage: tmuxkeep auth [--end]`, exit 2, audited. A lease file that cannot be removed: `tmuxkeep: cannot end lease`, exit 1. Plain `auth` is unchanged. Task 10's allowlist sends exactly `["auth","--end"]`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/bats/broker-gate.bats` (its `setup` creates a locked session `api`; `fails_file` is defined at the top of the file):

```bash

@test "auth --end removes this key id's lease without a code, prints lease ended and audits lease-ended" {
  mk_lease t -
  mk_lease other -
  run --separate-stderr tmuxkeep auth --end
  [ "$status" -eq 0 ]
  [ "$output" = 'lease ended' ]
  [ -z "$stderr" ]
  [ ! -e "$TMUXKEEP_HOME/leases/t@-" ]
  [ -e "$TMUXKEEP_HOME/leases/other@-" ]
  [ "$(audit_field verb)" = auth ]
  [ "$(audit_field ok)" = true ]
  [ "$(audit_field detail)" = lease-ended ]
  [ ! -s "$OATH_STUB_LOG" ]
}

@test "auth --end succeeds when there is no lease, and needs no terminal" {
  run tmuxkeep auth --end
  [ "$status" -eq 0 ]
  [ "$output" = 'lease ended' ]
}

@test "after auth --end a gated verb asks for a code again" {
  mk_lease t -
  run tmuxkeep auth --end
  [ "$status" -eq 0 ]
  run --separate-stderr tmuxkeep unlock api
  [ "$status" -eq 4 ]
  [[ "$stderr" == *'TOTP required'* ]]
  [ "$(locked_flag api)" = 1 ]
}

@test "auth --end does not take the gate: it works during a cooldown and a hard lock" {
  mk_lease t -
  printf '%s\n' $(( TMUXKEEP_NOW - 3 )) $(( TMUXKEEP_NOW - 2 )) $(( TMUXKEEP_NOW - 1 )) > "$(fails_file)"
  : > "$TMUXKEEP_HOME/otp-locked"
  run tmuxkeep auth --end
  [ "$status" -eq 0 ]
  [ ! -e "$TMUXKEEP_HOME/leases/t@-" ]
  [ ! -e "$TMUXKEEP_HOME/gate.lock" ]
}

@test "auth with any argument other than exactly --end is a usage error, audited" {
  local a
  for a in --frob --END end; do
    run --separate-stderr tmuxkeep auth "$a"
    [ "$status" -eq 2 ] || { echo "auth $a gave $status"; return 1; }
    [ "$stderr" = 'tmuxkeep: usage: tmuxkeep auth [--end]' ]
  done
  run tmuxkeep auth --end --end
  [ "$status" -eq 2 ]
  run tmuxkeep auth --end extra
  [ "$status" -eq 2 ]
  [ "$(audit_field ok)" = false ]
  [ "$(audit_field verb)" = auth ]
}
```

Append to `tests/bats/broker-remote.bats`:

```bash

@test "remote: auth --end removes only the lease of this key id and client IP" {
  local now
  now=$(date +%s)
  printf '%s\n' "$now" > /home/claude/.tmuxkeep/leases/laptop@203.0.113.9
  printf '%s\n' "$now" > /home/claude/.tmuxkeep/leases/laptop@198.51.100.7
  run remote 203.0.113.9 laptop "$(b64cmd auth --end)"
  [ "$status" -eq 0 ]
  [ "$output" = 'lease ended' ]
  [ ! -e /home/claude/.tmuxkeep/leases/laptop@203.0.113.9 ]
  [ -e /home/claude/.tmuxkeep/leases/laptop@198.51.100.7 ]
  [ "$(jq -r .detail <<<"$(remote_audit_last)")" = lease-ended ]
  [ "$(jq -r .ip <<<"$(remote_audit_last)")" = 203.0.113.9 ]
}
```

- [ ] **Step 2: Run them to see them fail**

Run (Git Bash): `bash tests/run-bats.sh tests/bats/broker-gate.bats`
Expected: the existing tests `ok`; the five new ones `not ok` (`auth --end` is `usage: tmuxkeep auth`, exit 2).

- [ ] **Step 3: Implement**

Replace

```bash
verb_auth() { # auth: always prompts for a code, then starts a lease for this key id and client IP
  (( $# == 0 )) || fail 2 "usage: tmuxkeep auth"
  authorize
```

with

```bash
# auth: always prompts for a code, then starts a lease for this key id and client IP.
# auth --end (spec 4.2, D18): removes that lease, with no gate and no code (ending a lease needs
# none), so it is the one verb path that does not call authorize. Succeeds when there is no lease.
verb_auth() {
  if (( $# == 1 )) && [[ $1 == --end ]]; then
    { rm -f -- "$STATE_DIR/leases/$KEY_ID@$CLIENT_IP"; } 2>/dev/null || fail 1 "cannot end lease"
    printf 'lease ended\n'
    succeed lease-ended
  fi
  (( $# == 0 )) || fail 2 "usage: tmuxkeep auth [--end]"
  authorize
```

The two lines after `authorize` (`printf 'authenticated; ...` and `succeed authenticated`) stay.

- [ ] **Step 4: Run the tests**

Run (Git Bash): `bash tests/run-bats.sh tests/bats/broker-gate.bats` and `bash tests/run-bats.sh tests/bats/broker-remote.bats`. Expected: all `ok`.

- [ ] **Step 5: Run the whole bats directory and the whole Pester folder**

Expected: all green (bats up by 6; Pester unchanged). `parity.bats` still passes: `verb_auth() {` still matches its `verb_` extraction.

- [ ] **Step 6: Commit**

```bash
git add vps/tmuxkeep tests/bats/broker-gate.bats tests/bats/broker-remote.bats
git commit -m "broker: auth --end ends this key's lease without a code"
```

---

### Task 4: Laptop wrappers: the local `ui` verb, verb lists gain `ui`

Suggested model: sonnet.

**Files:**
- Modify: `laptop/tmuxkeep.ps1` (insert after line 88, the end of the empty-argument loop)
- Modify: `laptop/tmuxkeep.sh` (insert before line 46, `# tk_main WORD...`; insert into `tk_main` after line 53, the end of its empty-argument loop)
- Modify: `laptop/completion.bash:9`, `laptop/profile-snippet.ps1:57` (as changed in Task 1)
- Modify: `tests/pester/tmuxkeep.Tests.ps1` (insert before line 212, `Describe 'contract with the broker'`), `tests/bats/laptop-wrapper.bats` (append after line 204), `tests/bats/completion.bats`, `tests/pester/completer.Tests.ps1`, `tests/bats/parity.bats` (as changed in Task 1)

**Interfaces:**
- Consumes: nothing from earlier tasks except the verb lists of Task 1.
- Produces: `tmuxkeep ui [args...]` is handled by both wrappers before anything is sent and never reaches ssh. It runs `node <dashboard dir>/server.js <args...>` in the foreground with the console attached and exits with node's exit code. `<dashboard dir>` is `<folder of tmuxkeep.ps1>\tmuxkeep-dashboard` on Windows (deploy installs the wrapper in `~\scripts`, so this is `~\scripts\tmuxkeep-dashboard`; plan Q9) and `~/.local/share/tmuxkeep/dashboard` elsewhere. Errors, exit 2: `tmuxkeep: node not found; install Node 20 or newer to use the dashboard`; `tmuxkeep: dashboard not installed at <dir>; run deploy again`. The verb is matched case-sensitively, like every verb (`UI` goes to the broker). Task 10's `server.js` validates the arguments; Task 11's deploy installs `<dashboard dir>`.
- Produces (lists): `_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth status ui"`; the PowerShell completer ends `'auth', 'status', 'ui')`. Completion of `ui` comes from these lists only; the broker has no `verb_ui`.

- [ ] **Step 1: Write the failing Pester tests**

In `tests/pester/tmuxkeep.Tests.ps1`, insert before the line `    Describe 'contract with the broker' {`:

```powershell
    Describe 'ui verb (local, spec 5.1)' {
        BeforeAll {
            # A home whose path has a space (Review Focus 2), with the wrapper installed the way deploy does it.
            $script:UiHome = Join-Path $TestDrive 'home dir'
            $script:UiScripts = Join-Path $UiHome 'scripts'
            $script:UiWrapper = Join-Path $UiScripts 'tmuxkeep.ps1'
            $script:UiServer = Join-Path $UiScripts 'tmuxkeep-dashboard\server.js'
            New-Item -ItemType Directory -Path (Split-Path $UiServer) -Force | Out-Null
            Copy-Item -LiteralPath $Wrapper -Destination $UiWrapper
            Set-Content -LiteralPath $UiServer -Value '// stand-in' -Encoding ascii
            $script:UiBin = Join-Path $TestDrive 'uibin'
            New-Item -ItemType Directory -Path $UiBin | Out-Null
            # A fake node: logs its arguments, exits 7.
            Set-Content -LiteralPath (Join-Path $UiBin 'node.cmd') -Encoding ascii -Value @('@echo off', '>"%TK_NODE_LOG%" echo %*', 'exit /b 7')
            $script:NodeLog = Join-Path $TestDrive 'node.log'
        }

        BeforeEach {
            $script:SavedPath = $env:PATH
            $env:TK_NODE_LOG = $NodeLog
            Remove-Item -LiteralPath $NodeLog -ErrorAction SilentlyContinue
        }

        AfterEach {
            $env:PATH = $SavedPath
            Remove-Item Env:\TK_NODE_LOG -ErrorAction SilentlyContinue
        }

        It 'runs node on the installed server.js with the other words, exits with its code, and never calls ssh' {
            $env:PATH = "$UiBin;$env:SystemRoot\System32"
            & $UiWrapper ui --port 8080 --no-open
            $LASTEXITCODE | Should -Be 7
            (Get-Content -LiteralPath $NodeLog) | Should -BeExactly ('"' + $UiServer + '" --port 8080 --no-open')
            Should -Invoke ssh -Times 0 -Exactly
        }

        It 'reports a missing node with exit 2 and never calls ssh' {
            $env:PATH = "$env:SystemRoot\System32"
            $out = & $UiWrapper ui 6>&1 | Out-String -Width 4096
            $LASTEXITCODE | Should -Be 2
            $out.Trim() | Should -BeExactly 'tmuxkeep: node not found; install Node 20 or newer to use the dashboard'
            Test-Path -LiteralPath $NodeLog | Should -BeFalse
            Should -Invoke ssh -Times 0 -Exactly
        }

        It 'reports a missing dashboard with exit 2' {
            $env:PATH = "$UiBin;$env:SystemRoot\System32"
            $bare = Join-Path $TestDrive 'bare\scripts'
            New-Item -ItemType Directory -Path $bare -Force | Out-Null
            Copy-Item -LiteralPath $Wrapper -Destination (Join-Path $bare 'tmuxkeep.ps1')
            $out = & (Join-Path $bare 'tmuxkeep.ps1') ui 6>&1 | Out-String -Width 4096
            $LASTEXITCODE | Should -Be 2
            $out.Trim() | Should -BeExactly ('tmuxkeep: dashboard not installed at ' + (Join-Path $bare 'tmuxkeep-dashboard') + '; run deploy again')
            Should -Invoke ssh -Times 0 -Exactly
        }

        It 'matches ui case-sensitively: UI goes to the broker like any other word' {
            & $Wrapper UI
            Actual | Should -BeExactly (Expected @('UI'))
        }
    }

```

- [ ] **Step 2: Write the failing bats tests**

Append to `tests/bats/laptop-wrapper.bats`:

```bash

# fake_node: a stub node first on PATH; it logs its arguments like the other stubs and exits 7.
fake_node() {
  mkdir -p "$BATS_TEST_TMPDIR/nodebin"
  printf '#!/usr/bin/env bash\n{ printf node; printf " [%%s]" "$@"; printf "\\n"; } >> "$TK_STUB_LOG"\nexit 7\n' > "$BATS_TEST_TMPDIR/nodebin/node"
  chmod +x "$BATS_TEST_TMPDIR/nodebin/node"
  PATH="$BATS_TEST_TMPDIR/nodebin:$PATH"
}

# install_dashboard: the file deploy.sh would install, under the current HOME.
install_dashboard() {
  mkdir -p "$HOME/.local/share/tmuxkeep/dashboard"
  : > "$HOME/.local/share/tmuxkeep/dashboard/server.js"
}

@test "ui runs node on the installed dashboard with the other words, returns its code and never calls ssh" {
  # Review Focus 2: a home directory with a space in its path.
  export HOME="$BATS_TEST_TMPDIR/home dir"
  fake_node
  install_dashboard
  run tk_main ui --port 8080 --no-open
  [ "$status" -eq 7 ]
  [ "$(stub_calls)" = "node [$HOME/.local/share/tmuxkeep/dashboard/server.js] [--port] [8080] [--no-open]" ]
}

@test "run as a program, ui exits with node's code" {
  fake_node
  install_dashboard
  run "$BASH" "$WRAPPER" ui
  [ "$status" -eq 7 ]
  [ "$(stub_calls)" = "node [$HOME/.local/share/tmuxkeep/dashboard/server.js]" ]
}

@test "ui without node on PATH says so, exits 2 and never calls ssh" {
  local p="$STUBS:/usr/bin:/bin"
  if ( PATH=$p; command -v node >/dev/null ); then skip 'a node is installed in /usr/bin or /bin'; fi
  install_dashboard
  PATH=$p
  run --separate-stderr tk_main ui
  [ "$status" -eq 2 ]
  [ "$stderr" = 'tmuxkeep: node not found; install Node 20 or newer to use the dashboard' ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "ui without an installed dashboard says where it looked and exits 2" {
  fake_node
  run --separate-stderr tk_main ui
  [ "$status" -eq 2 ]
  [ "$stderr" = "tmuxkeep: dashboard not installed at $HOME/.local/share/tmuxkeep/dashboard; run deploy again" ]
  [ ! -s "$TK_STUB_LOG" ]
}

@test "ui is matched case-sensitively: UI goes to the broker like any other word" {
  fake_node
  install_dashboard
  run tk_main UI
  [ "$(stub_calls)" = "$(line_for 0 UI)" ]
}
```

- [ ] **Step 3: Run them to see them fail**

Run the G7 command with `$c.Run.Path = 'tests\pester\tmuxkeep.Tests.ps1'`. Expected: the four `ui verb` tests fail except the case-sensitivity one (the mock ssh is called for `ui`, so `Should -Invoke ssh -Times 0` fails).
Run (Git Bash): `bash tests/run-bats.sh tests/bats/laptop-wrapper.bats`. Expected: the new tests `not ok` except the last one.

- [ ] **Step 4: Implement the PowerShell verb**

In `laptop/tmuxkeep.ps1`, after the `foreach ($w in $words) { ... }` loop that rejects empty arguments (it ends at line 88) and before the line `# "send <name>" with no text: ask for it locally and send it as one word.`, insert:

```powershell

# "ui" is local (spec 5.1): it starts the dashboard server in the foreground and never reaches the
# broker. Deploy installs the dashboard next to this script, in ~\scripts\tmuxkeep-dashboard.
if ($words.Count -gt 0 -and $words[0] -ceq 'ui') {
    $node = @(Get-Command -Name node -CommandType Application -ErrorAction SilentlyContinue)
    if ($node.Count -eq 0) {
        Write-Host 'tmuxkeep: node not found; install Node 20 or newer to use the dashboard'
        exit 2
    }
    $dashboard = Join-Path $PSScriptRoot 'tmuxkeep-dashboard'
    $server = Join-Path $dashboard 'server.js'
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) {
        Write-Host "tmuxkeep: dashboard not installed at $dashboard; run deploy again"
        exit 2
    }
    [string[]]$uiArgs = @($server) + @($words | Select-Object -Skip 1)
    $global:LASTEXITCODE = $null
    & $node[0].Source @uiArgs
    $code = $LASTEXITCODE
    if ($null -eq $code) {
        $code = 1
    }
    exit $code
}

```

`Get-Command -CommandType Application` finds `node.exe` (or, in the tests, `node.cmd`) on `PATH` and never a function or alias. `& $node[0].Source @uiArgs` is a plain statement: no capture, no redirection (G16).

- [ ] **Step 5: Implement the bash verb**

In `laptop/tmuxkeep.sh`, insert before the line `# tk_main WORD...: the wrapper; returns ssh's exit code, or 2 for a local usage error.`:

```bash
# tk_ui WORD...: the local ui verb (spec 5.1). Runs node on the dashboard that deploy.sh installs in
# ~/.local/share/tmuxkeep/dashboard, in the foreground, and returns node's exit code. Never calls ssh.
tk_ui() {
  local dir="$HOME/.local/share/tmuxkeep/dashboard"
  if ! command -v node >/dev/null; then
    printf 'tmuxkeep: node not found; install Node 20 or newer to use the dashboard\n' >&2
    return 2
  fi
  if [ ! -f "$dir/server.js" ]; then
    printf 'tmuxkeep: dashboard not installed at %s; run deploy again\n' "$dir" >&2
    return 2
  fi
  node "$dir/server.js" "$@"
}

```

and in `tk_main`, right after the `for w in "$@"; do ... done` loop that rejects empty arguments, insert:

```bash
  # "ui" never reaches the broker: it starts the local dashboard server.
  if [ "$#" -gt 0 ] && [ "$1" = ui ]; then
    shift
    tk_ui "$@"
    return
  fi
```

(`return` with no argument returns `tk_ui`'s status, which is node's exit code.)

- [ ] **Step 6: Add `ui` to both completers and the parity rule**

`laptop/completion.bash` line 9 becomes:

```bash
_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth status ui"
```

`laptop/profile-snippet.ps1` line 57 becomes:

```powershell
        $candidates = @('new', 'ls', 'peek', 'go', 'send', 'rename', 'lock', 'unlock', 'rm', 'restore', 'resume', 'log', 'auth', 'status', 'ui')
```

In `tests/bats/completion.bats`, the first test's verb line becomes

```bash
  grep -qx '_TK_VERBS="new ls peek go send rename lock unlock rm restore resume log auth status ui"' "$REPO/laptop/completion.bash"
```

and in the second test replace `[ "${#lines[@]}" -eq 14 ]` with:

```bash
  [ "${#lines[@]}" -eq 15 ]
  run complete_words tmuxkeep u
  [ "$output" = "$(printf '%s\n' unlock ui)" ]
```

In `tests/pester/completer.Tests.ps1`, after the `It 'completes status for the first word'` block from Task 1, insert:

```powershell

        It 'completes the local ui verb for the first word' {
            $r = TabExpansion2 -inputScript 'tmuxkeep ui' -cursorColumn 11
            ($r.CompletionMatches.CompletionText -join ',') | Should -BeExactly 'ui'
        }
```

In `tests/bats/parity.bats`, replace the test `the completer verb lists match the broker's verbs (reap excluded) and each other` with:

```bash
@test "the completer verb lists are the broker's verbs (reap excluded) plus the local ui, and agree" {
  local want b p s
  want='auth go lock log ls new peek rename restore resume rm send status unlock'
  b=$(broker_verbs | sorted_words)
  [ "$b" = "$want" ] || { echo "broker verb_ functions: $b"; return 1; }
  want=$(printf '%s ui' "$want" | sorted_words)
  p=$(ps_verbs); one_line 'PowerShell completer verbs' "$p"
  s=$(bash_verbs); one_line 'bash completer verbs' "$s"
  [ "$(printf '%s' "$p" | sorted_words)" = "$want" ] || { echo "PowerShell completer: $p"; return 1; }
  [ "$(printf '%s' "$s" | sorted_words)" = "$want" ] || { echo "bash completer: $s"; return 1; }
}
```

- [ ] **Step 7: Run the tests**

Run the G7 command with `'tests\pester\tmuxkeep.Tests.ps1'`, then with `'tests\pester\completer.Tests.ps1'`. Expected: `Failed: 0`. (While planning, this exact `ui` block and these four tests passed under Windows PowerShell 5.1 with Pester 6.2.0.)
Run (Git Bash): `bash tests/run-bats.sh tests/bats/laptop-wrapper.bats`, `... tests/bats/completion.bats`, `... tests/bats/parity.bats`, `... tests/bats/lint-laptop.bats`. Expected: all `ok`.

- [ ] **Step 8: Run the whole bats directory and the whole Pester folder**

Expected: all green (bats up by 5; Pester up by 5).

- [ ] **Step 9: Commit**

```bash
git add laptop/tmuxkeep.ps1 laptop/tmuxkeep.sh laptop/completion.bash laptop/profile-snippet.ps1 tests/pester/tmuxkeep.Tests.ps1 tests/bats/laptop-wrapper.bats tests/bats/completion.bats tests/pester/completer.Tests.ps1 tests/bats/parity.bats
git commit -m "wrappers: local ui verb starts the dashboard server; completion lists ui"
```

---

### Task 5: Dashboard: package, protocol, validator, config; the shared b64 fixture

Suggested model: sonnet.

**Files:**
- Create: `dashboard/package.json`, `dashboard/lib/protocol.js`, `dashboard/lib/validate.js`, `dashboard/lib/config.js`
- Create: `dashboard/test/protocol.test.js`, `dashboard/test/validate.test.js`, `dashboard/test/config.test.js`, `dashboard/test/static.test.js`
- Create: `tests/fixtures/b64-words`
- Modify: `.gitattributes` (append after line 5), `tests/pester/static.Tests.ps1:52-59`
- Modify: `tests/pester/tmuxkeep.Tests.ps1` (insert before `Describe 'ui verb (local, spec 5.1)'`, added in Task 4), `tests/bats/laptop-wrapper.bats` (append), `tests/bats/parity.bats` (append after line 109 and add one helper after line 33)

**Interfaces:**
- Consumes: the wrappers' encoders `ConvertTo-TmuxkeepToken` (`laptop/tmuxkeep.ps1`) and `tk_encode` (`laptop/tmuxkeep.sh`), unchanged; `broker_verbs`, `ps_list`, `sorted_words`, `one_line` in `parity.bats`.
- Produces (`dashboard/lib/protocol.js`): `SSH_PREFIX` (frozen `['-o','BatchMode=yes','-o','ConnectTimeout=5','tmuxkeep','b64']`), `encodeWord(word: string): string`, `sshArgs(words: string[]): string[]`.
- Produces (`dashboard/lib/validate.js`): `NAME_RE`, `TOMB_RE`, `URL_RE`, `ACTION_VERBS` (one line, read by `parity.bats`), `SEND_MAX_BYTES = 65536`, `checkAction(words): string|null`, `checkTerminal(body): string|null`. `null` means acceptable; a string is the message for a 400 answer.
- Produces (`dashboard/lib/config.js`): `DEFAULT_PORT = 7707`, `USAGE = 'usage: tmuxkeep ui [--port N] [--no-open]'`, `configPath(home = os.homedir()): string`, `portValue(text): number|null`, `readConfig(file): {port: number, terminalCmd: string}` (throws `Error('config <file>: <reason>')`), `parseArgs(argv): {port: number|null, open: boolean}` (throws `Error(USAGE)` or `Error('--port must be an integer from 1024 to 65535')`).
- Produces: `tests/fixtures/b64-words`, one case per line `<label> <hex of the UTF-8 bytes> <token>`, fifteen cases, lines starting `#` are comments.
- Produces: `.gitattributes` line `dashboard/** text eol=lf` (without it a Windows checkout with `core.autocrlf=true`, the laptop's and the CI runner's, would put CR into every dashboard file and `static.test.js` would fail).

- [ ] **Step 1: The fixture and the line-ending rule**

Create `tests/fixtures/b64-words`, LF line endings, exactly:

```
# Shared b64 cases (spec 6.4): <label> <hex of the word's UTF-8 bytes> <token every client must send>.
# Read by dashboard/test/protocol.test.js, tests/bats/laptop-wrapper.bats and tests/pester/tmuxkeep.Tests.ps1.
verb 73656e64 c2VuZA==
name 617069 YXBp
spaces 72756e20746865207465737473 cnVuIHRoZSB0ZXN0cw==
shell-specials 613b20622023202463202864292040652c2066 YTsgYiAjICRjIChkKSBAZSwgZg==
quotes 69742773202271756f74656422205c206261636b aXQncyAicXVvdGVkIiBcIGJhY2s=
double-dash 2d2d LS0=
short-option 2d6e LW4=
tombstone 7a7a7e6170697e31373930303030303030 enp+YXBpfjE3OTAwMDAwMDA=
slash 3f3e3f7e Pz4/fg==
tab 610962 YQli
latin1 636166c3a9 Y2Fmw6k=
cjk e697a5e69cac 5pel5pys
emoji f09f9880 8J+YgA==
url 68747470733a2f2f6769746875622e636f6d2f796f752f6170692e676974 aHR0cHM6Ly9naXRodWIuY29tL3lvdS9hcGkuZ2l0
long-120 787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878 eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4
```

(The values were computed with Node's `Buffer` and checked against the bash wrapper's `tk_encode` and the PowerShell wrapper's `ConvertTo-TmuxkeepToken` while planning; all fifteen agree.)

Append to `.gitattributes`:

```
dashboard/** text eol=lf
```

In `tests/pester/static.Tests.ps1`, in the `.gitattributes` test, change the path list of the first `foreach` to

```powershell
        foreach ($p in 'laptop/tmuxkeep.sh', 'laptop/deploy.sh', 'laptop/completion.bash', 'vps/tmuxkeep', 'tests/smoke.sh', 'dashboard/server.js', 'dashboard/public/app.js') {
```

and rename the `It` to `'forces LF on the laptop bash files, vps, tests and the dashboard, and leaves the PowerShell files alone'`.

- [ ] **Step 2: Pin the wrappers to the fixture**

In `tests/pester/tmuxkeep.Tests.ps1`, insert before `    Describe 'ui verb (local, spec 5.1)' {`:

```powershell
    Describe 'shared b64 cases' {
        It 'encodes every case of tests\fixtures\b64-words to its token' {
            . $Wrapper
            $cases = @(Get-Content -LiteralPath (Join-Path $Repo 'tests\fixtures\b64-words') | Where-Object { $_ -and -not $_.StartsWith('#') })
            $cases.Count | Should -Be 15
            foreach ($case in $cases) {
                $label, $hex, $token = $case -split ' '
                $bytes = [byte[]]@(for ($i = 0; $i -lt $hex.Length; $i += 2) { [Convert]::ToByte($hex.Substring($i, 2), 16) })
                ConvertTo-TmuxkeepToken ([Text.Encoding]::UTF8.GetString($bytes)) | Should -BeExactly $token -Because $label
            }
        }
    }

```

Append to `tests/bats/laptop-wrapper.bats`:

```bash

# hex_word HEX: the bytes HEX spells, two hex digits per byte (printf %b with \0NNN works in bash 3.2).
hex_word() {
  local h=$1 esc=''
  while [ -n "$h" ]; do
    esc="$esc\\0$(printf '%03o' "0x${h%"${h#??}"}")"
    h=${h#??}
  done
  printf '%b' "$esc"
}

@test "every shared b64 case in tests/fixtures/b64-words encodes to its token" {
  local label hex token n=0
  while read -r label hex token; do
    case $label in ''|'#'*) continue ;; esac
    [ "$(tk_encode "$(hex_word "$hex")")" = "$token" ] || { echo "case $label"; return 1; }
    n=$((n + 1))
  done < "$REPO/tests/fixtures/b64-words"
  [ "$n" -eq 15 ]
}
```

Run the G7 command for `'tests\pester\tmuxkeep.Tests.ps1'` and `'tests\pester\static.Tests.ps1'`, and (Git Bash) `bash tests/run-bats.sh tests/bats/laptop-wrapper.bats`. Expected: all pass. These are characterization tests: the wrappers already encode this way, and the fixture pins it before the Node encoder exists.

- [ ] **Step 3: The package**

Create `dashboard/package.json`:

```json
{
  "name": "tmuxkeep-dashboard",
  "version": "0.0.0",
  "private": true,
  "description": "Local web dashboard for tmuxkeep: tmuxkeep ui. Built-in Node modules only.",
  "license": "MIT",
  "type": "module",
  "engines": {
    "node": ">=20"
  },
  "scripts": {
    "test": "node --test \"test/*.test.js\""
  }
}
```

- [ ] **Step 4: Write the failing Node tests**

Create `dashboard/test/protocol.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { encodeWord, sshArgs, SSH_PREFIX } from '../lib/protocol.js';

// tests/fixtures/b64-words is shared with tests/bats/laptop-wrapper.bats and tests/pester/tmuxkeep.Tests.ps1.
const FIXTURE = new URL('../../tests/fixtures/b64-words', import.meta.url);

function fixtureCases() {
  return fs.readFileSync(FIXTURE, 'utf8').split('\n')
    .filter((line) => line !== '' && !line.startsWith('#'))
    .map((line) => {
      const [label, hex, token] = line.split(' ');
      return { label, word: Buffer.from(hex, 'hex').toString('utf8'), token };
    });
}

test('the shared fixture holds the fifteen agreed cases', () => {
  const labels = fixtureCases().map((c) => c.label);
  assert.deepEqual(labels, ['verb', 'name', 'spaces', 'shell-specials', 'quotes', 'double-dash', 'short-option',
    'tombstone', 'slash', 'tab', 'latin1', 'cjk', 'emoji', 'url', 'long-120']);
});

test('every fixture word encodes to its token, bit for bit', () => {
  for (const c of fixtureCases()) assert.equal(encodeWord(c.word), c.token, c.label);
});

test('sshArgs is the fixed prefix, then one token per word, and never -t', () => {
  assert.deepEqual(SSH_PREFIX, ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'tmuxkeep', 'b64']);
  assert.deepEqual(sshArgs(['send', 'api', 'run the tests']),
    ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'tmuxkeep', 'b64', 'c2VuZA==', 'YXBp', 'cnVuIHRoZSB0ZXN0cw==']);
  for (const words of [['go', 'api'], ['auth', '--end'], ['new', 'api'], ['status']]) {
    assert.ok(!sshArgs(words).includes('-t'), words.join(' '));
  }
});

test('a lone surrogate never reaches the encoder as a surprise: it encodes as U+FFFD, which validate.js refuses earlier', () => {
  assert.equal(encodeWord(String.fromCharCode(0xd800)),Buffer.from([0xef, 0xbf, 0xbd]).toString('base64'));
});
```

Create `dashboard/test/validate.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ACTION_VERBS, checkAction, checkTerminal, SEND_MAX_BYTES } from '../lib/validate.js';

const ok = (words) => assert.equal(checkAction(words), null, JSON.stringify(words));
const bad = (words, message) => assert.equal(checkAction(words), message, JSON.stringify(words));

test('the allowlist is the twelve verbs of spec 6.4, without go, ui or reap', () => {
  assert.deepEqual(ACTION_VERBS, ['new', 'send', 'rename', 'lock', 'unlock', 'rm', 'restore', 'resume', 'log', 'peek', 'status', 'auth']);
  bad(['go', 'api'], 'not allowed from the dashboard: go');
  bad(['ui'], 'not allowed from the dashboard: ui');
  bad(['reap'], 'not allowed from the dashboard: reap');
  bad(['LS'], 'not allowed from the dashboard: LS');
  bad(['ls'], 'not allowed from the dashboard: ls');
  bad(['fro' + String.fromCharCode(7) + 'b'], 'not allowed from the dashboard: fro?b');
});

test('words must be a non-empty array of non-empty, well-formed strings', () => {
  bad(undefined, 'words must be a non-empty array of strings');
  bad('send api hi', 'words must be a non-empty array of strings');
  bad([], 'words must be a non-empty array of strings');
  bad(['send', 'api', 5], 'words must be a non-empty array of strings');
  bad(['send', 'api', null], 'words must be a non-empty array of strings');
  bad(['send', 'api', ''], 'empty argument');
  bad(['send', 'api', 'a' + String.fromCharCode(0xd800) + 'b'], 'argument is not valid text');
});

test('auth is allowed only as exactly auth --end', () => {
  ok(['auth', '--end']);
  bad(['auth'], 'only auth --end is allowed from the dashboard');
  bad(['auth', '--end', '--end'], 'only auth --end is allowed from the dashboard');
  bad(['auth', '--frob'], 'only auth --end is allowed from the dashboard');
});

test('names follow the broker rule; tombstone names only for peek and rm --now', () => {
  ok(['lock', 'api']);
  ok(['lock', 'a-b_9']);
  ok(['lock', 'a'.repeat(32)]);
  bad(['lock', 'a'.repeat(33)], 'invalid session name');
  bad(['lock', '1api'], 'invalid session name');
  bad(['lock', 'Api'], 'invalid session name');
  bad(['lock', '-api'], 'invalid session name');
  bad(['lock'], 'missing session name');
  bad(['lock', 'zz~api~1790000000'], 'invalid session name');
  ok(['peek', 'zz~api~1790000000']);
  ok(['rm', 'zz~api~1790000000', '--now', '--confirm', 'zz~api~1790000000']);
  bad(['rm', 'zz~api~1790000000'], 'invalid session name');
  bad(['restore', 'zz~api~1790000000'], 'invalid session name');
  bad(['peek', 'zz~Api~1'], 'invalid session name');
});

test('new: options in any order, each once; https only; --cmd printable ASCII up to 200; never with --shell', () => {
  ok(['new', 'api']);
  ok(['new', '--repo', 'https://github.com/you/api.git', 'api', '--cmd', 'claude --continue']);
  ok(['new', 'api', '--shell']);
  ok(['new', 'api', '--cmd', 'x'.repeat(200)]);
  bad(['new', 'api', '--cmd', 'x'.repeat(201)], '--cmd must be at most 200 printable ASCII characters');
  bad(['new', 'api', '--cmd', 'caf' + String.fromCodePoint(0xe9)], '--cmd must be at most 200 printable ASCII characters');
  bad(['new', 'api', '--repo', 'http://github.com/you/api.git'], '--repo must be an https:// URL');
  bad(['new', 'api', '--repo', 'https://'], '--repo must be an https:// URL');
  bad(['new', 'api', '--repo', 'https://a b'], '--repo must be an https:// URL');
  bad(['new', 'api', '--shell', '--cmd', 'x'], '--shell and --cmd cannot be combined');
  bad(['new', 'api', 'web'], 'usage: tmuxkeep new <name> [--repo <https-url>] [--cmd <text>] [--shell]');
  bad(['new', 'api', '--repo'], 'usage: tmuxkeep new <name> [--repo <https-url>] [--cmd <text>] [--shell]');
  bad(['new', 'api', '--shell', '--shell'], 'usage: tmuxkeep new <name> [--repo <https-url>] [--cmd <text>] [--shell]');
  bad(['new'], 'missing session name');
});

test('send: text joined by spaces, no control characters (tab included, as in the broker), at most 65536 bytes', () => {
  ok(['send', 'api', 'run the tests']);
  ok(['send', 'api', 'a', 'b']);
  ok(['send', 'api', String.fromCodePoint(0xe9).repeat(SEND_MAX_BYTES / 2)]);
  bad(['send', 'api', 'x'.repeat(SEND_MAX_BYTES - 1) + String.fromCodePoint(0xe9)], 'text longer than 65536 bytes');
  bad(['send', 'api'], 'nothing to send');
  bad(['send', 'api', 'a\tb'], 'text contains control characters (line breaks and tabs cannot be sent; send one line at a time)');
  bad(['send', 'api', 'del' + String.fromCharCode(0x7f)],'text contains control characters (line breaks and tabs cannot be sent; send one line at a time)');
});

// Review Focus 1: a multi-line prompt pasted into the Send box is refused before any ssh call.
test('send: pasted multi-line text is refused with a message that says why', () => {
  for (const text of ['line one\nline two', 'windows\r\nline', 'trailing newline\n']) {
    bad(['send', 'api', text], 'text contains control characters (line breaks and tabs cannot be sent; send one line at a time)');
  }
});

test('rename, unlock and restore take exact arguments', () => {
  ok(['rename', 'api', 'web']);
  bad(['rename', 'api'], 'usage: tmuxkeep rename <old> <new>');
  bad(['rename', 'api', 'Web'], 'invalid session name');
  ok(['unlock', 'api']);
  bad(['unlock'], 'usage: tmuxkeep unlock <name>');
  bad(['unlock', 'api', 'web'], 'usage: tmuxkeep unlock <name>');
  ok(['restore', 'api']);
  bad(['restore', 'api', 'x'], 'usage: tmuxkeep restore <name>');
  bad(['lock', 'api', 'web'], 'usage: tmuxkeep lock <name>');
});

test('rm: soft by default; --now needs --confirm equal to the name', () => {
  ok(['rm', 'api']);
  ok(['rm', 'api', '--now', '--confirm', 'api']);
  ok(['rm', '--now', 'api', '--confirm', 'api']);
  bad(['rm', 'api', '--now', '--confirm', 'web'], '--confirm must equal api');
  bad(['rm', 'api', '--now'], '--confirm must equal api');
  bad(['rm', 'api', '--confirm', 'api'], '--confirm needs --now');
  bad(['rm', 'api', '--frob'], 'usage: tmuxkeep rm <name> [--now --confirm <name>]');
  bad(['rm', 'api', 'web'], 'usage: tmuxkeep rm <name> [--now --confirm <name>]');
  bad(['rm'], 'usage: tmuxkeep rm <name> [--now --confirm <name>]');
});

test('resume: one name, --cmd or --shell', () => {
  ok(['resume', 'api']);
  ok(['resume', 'api', '--shell']);
  ok(['resume', '--cmd', 'claude', 'api']);
  bad(['resume', 'api', '--shell', '--cmd', 'x'], '--shell and --cmd cannot be combined');
  bad(['resume'], 'usage: tmuxkeep resume <name> [--cmd <text>] [--shell]');
  bad(['resume', 'api', '--frob'], 'usage: tmuxkeep resume <name> [--cmd <text>] [--shell]');
});

test('log -n, peek -n and status --lines have the broker bounds', () => {
  ok(['log']);
  ok(['log', '-n', '0']);
  ok(['log', '-n', '9999']);
  bad(['log', '-n', '10000'], '-n must be 0-9999');
  bad(['log', '-n', 'x'], '-n must be 0-9999');
  bad(['log', '100'], 'usage: tmuxkeep log [-n N]');
  ok(['peek', 'api']);
  ok(['peek', 'api', '-n', '200']);
  bad(['peek', 'api', '-n', '-1'], '-n must be 0-9999');
  bad(['peek', 'api', '200'], 'usage: tmuxkeep peek <name> [-n N]');
  bad(['peek'], 'missing session name');
  ok(['status']);
  ok(['status', '--lines', '0']);
  ok(['status', '--lines', '40']);
  bad(['status', '--lines', '41'], '--lines must be 0-40');
  bad(['status', '--lines'], 'usage: tmuxkeep status [--lines N]');
  bad(['status', '--follow'], 'status --follow is not an action');
  bad(['status', '--lines', '12', '--follow'], 'status --follow is not an action');
});

test('terminal requests: go with a valid name, or auth alone', () => {
  assert.equal(checkTerminal({ verb: 'go', name: 'api' }), null);
  assert.equal(checkTerminal({ verb: 'auth' }), null);
  assert.equal(checkTerminal({ verb: 'auth', name: 'api' }), 'auth takes no name');
  assert.equal(checkTerminal({ verb: 'go' }), 'go needs a session name');
  assert.equal(checkTerminal({ verb: 'go', name: 5 }), 'go needs a session name');
  assert.equal(checkTerminal({ verb: 'go', name: 'api', extra: 1 }), 'go needs a session name');
  assert.equal(checkTerminal({ verb: 'go', name: 'zz~api~1' }), 'invalid session name');
  assert.equal(checkTerminal({ verb: 'go', name: 'api; rm -rf ~' }), 'invalid session name');
  assert.equal(checkTerminal({ verb: 'ui' }), 'verb must be go or auth');
  assert.equal(checkTerminal(['go', 'api']), 'body must be an object');
  assert.equal(checkTerminal(null), 'body must be an object');
});
```

Create `dashboard/test/config.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { configPath, DEFAULT_PORT, parseArgs, readConfig, USAGE } from '../lib/config.js';
import { fileURLToPath } from 'node:url';

function tempFile(text) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tk-config-'));
  const file = path.join(dir, 'config');
  fs.writeFileSync(file, text, 'latin1');
  return file;
}

const reason = (text) => {
  const file = tempFile(text);
  try {
    readConfig(file);
    return 'no error';
  } catch (err) {
    return err.message.replace(`config ${file}: `, '');
  }
};

test('configPath is ~/.tmuxkeep/config', () => {
  assert.equal(configPath('/home/you'), path.join('/home/you', '.tmuxkeep', 'config'));
});

test('a missing file gives the defaults', () => {
  assert.deepEqual(readConfig(path.join(os.tmpdir(), 'tk-no-such-dir', 'config')), { port: 7707, terminalCmd: '' });
  assert.equal(DEFAULT_PORT, 7707);
});

test('the laptop-config fixture reads as the defaults', () => {
  const fixture = fileURLToPath(new URL('../../tests/fixtures/laptop-config', import.meta.url));
  assert.deepEqual(readConfig(fixture), { port: 7707, terminalCmd: '' });
});

test('missing keys default; present keys are read, trimmed, the last one winning; other lines are ignored', () => {
  const file = tempFile('HOST=203.0.113.10\nPORT=22\n');
  assert.deepEqual(readConfig(file), { port: 7707, terminalCmd: '' });
  const file2 = tempFile('# c\n\n  DASHBOARD_PORT = 8080 \nTERMINAL_CMD=\talacritty -e\t\njust words\nFROB=1\nDASHBOARD_PORT=8081\n');
  assert.deepEqual(readConfig(file2), { port: 8081, terminalCmd: 'alacritty -e' });
  assert.deepEqual(readConfig(tempFile('DASHBOARD_PORT=09000\r\nTERMINAL_CMD=\r\n')), { port: 9000, terminalCmd: '' });
});

test('bad values name the key, as the deploy scripts do', () => {
  assert.equal(reason('DASHBOARD_PORT=80\n'), 'DASHBOARD_PORT: must be an integer from 1024 to 65535');
  assert.equal(reason('DASHBOARD_PORT=65536\n'), 'DASHBOARD_PORT: must be an integer from 1024 to 65535');
  assert.equal(reason('DASHBOARD_PORT=abc\n'), 'DASHBOARD_PORT: must be an integer from 1024 to 65535');
  assert.equal(reason('DASHBOARD_PORT=\n'), 'DASHBOARD_PORT: must be an integer from 1024 to 65535');
  assert.equal(reason('DASHBOARD_PORT=00001024\n'), 'DASHBOARD_PORT: must be an integer from 1024 to 65535');
  assert.equal(reason('DASHBOARD_PORT=1024\nTERMINAL_CMD=' + 'x'.repeat(200) + '\n'), 'no error');
  assert.equal(reason('TERMINAL_CMD=' + 'x'.repeat(201) + '\n'), 'TERMINAL_CMD: at most 200 characters');
  // The file holds the two UTF-8 bytes of e-acute; read as latin1 they are two non-ASCII characters.
  assert.equal(reason('TERMINAL_CMD=caf' + String.fromCharCode(0xc3, 0xa9) + '\n'), 'TERMINAL_CMD: non-printable or non-ASCII character');
  assert.equal(reason('TERMINAL_CMD=a\tb\n'), 'TERMINAL_CMD: non-printable or non-ASCII character');
});

test('a path that cannot be read as a file is an error', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tk-config-'));
  assert.throws(() => readConfig(dir), { message: `config ${dir}: cannot read` });
});

test('parseArgs: --port N and --no-open, each at most once, nothing else', () => {
  assert.deepEqual(parseArgs([]), { port: null, open: true });
  assert.deepEqual(parseArgs(['--no-open']), { port: null, open: false });
  assert.deepEqual(parseArgs(['--port', '8080', '--no-open']), { port: 8080, open: false });
  assert.deepEqual(parseArgs(['--no-open', '--port', '65535']), { port: 65535, open: false });
  for (const argv of [['--frob'], ['--port'], ['--no-open', '--no-open'], ['--port', '8080', '--port', '8081'], ['8080']]) {
    assert.throws(() => parseArgs(argv), { message: USAGE }, argv.join(' '));
  }
  for (const v of ['80', '1023', '65536', 'abc', '']) {
    assert.throws(() => parseArgs(['--port', v]), { message: '--port must be an integer from 1024 to 65535' }, v);
  }
  assert.equal(USAGE, 'usage: tmuxkeep ui [--port N] [--no-open]');
});

```

Create `dashboard/test/static.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

test('every dashboard file is ASCII with LF line endings and no byte order mark', () => {
  const files = walk(ROOT);
  assert.ok(files.length >= 5, `found ${files.length} files`);
  for (const f of files) {
    const b = fs.readFileSync(f);
    const name = path.relative(ROOT, f);
    assert.ok(!(b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf), `${name} starts with a BOM`);
    assert.equal(b.indexOf(13), -1, `${name} has a CR`);
    assert.equal(b.findIndex((x) => x > 127), -1, `${name} has a non-ASCII byte`);
  }
});

test('package.json: an ES module package with no dependencies at all', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
  assert.equal(pkg.type, 'module');
  for (const k of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies', 'bundledDependencies']) {
    assert.equal(pkg[k], undefined, k);
  }
  assert.equal(pkg.engines.node, '>=20');
  assert.ok(!fs.existsSync(path.join(ROOT, 'node_modules')));
});

test('library and server code import only node: built-ins and relative files', () => {
  for (const f of walk(ROOT).filter((x) => x.endsWith('.js'))) {
    const text = fs.readFileSync(f, 'utf8');
    for (const m of text.matchAll(/(?:^|\n)\s*import\s[^'"]*['"]([^'"]+)['"]/g)) {
      assert.ok(m[1].startsWith('node:') || m[1].startsWith('./') || m[1].startsWith('../'), `${path.relative(ROOT, f)} imports ${m[1]}`);
    }
    assert.ok(!/\brequire\(/.test(text), `${path.relative(ROOT, f)} calls require`);
  }
});
```

- [ ] **Step 5: Run them to see them fail**

Run: `node --test "dashboard/test/*.test.js"`
Expected: FAIL, `ERR_MODULE_NOT_FOUND` for `../lib/protocol.js`, `../lib/validate.js` and `../lib/config.js`; `static.test.js` passes.

- [ ] **Step 6: Implement `protocol.js`**

Create `dashboard/lib/protocol.js`:

```js
// protocol.js - words to ssh arguments, exactly as laptop/tmuxkeep.ps1 and laptop/tmuxkeep.sh build
// them (spec 6.4): the literal word b64, then each word as standard, padded base64 of its UTF-8
// bytes, so nothing ever reaches a remote shell. The dashboard never asks ssh for a terminal (-t).

export const SSH_PREFIX = Object.freeze(['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'tmuxkeep', 'b64']);

// encodeWord(word): the token for one word.
export function encodeWord(word) {
  return Buffer.from(word, 'utf8').toString('base64');
}

// sshArgs(words): the whole ssh argument list for these words.
export function sshArgs(words) {
  return [...SSH_PREFIX, ...words.map(encodeWord)];
}
```

- [ ] **Step 7: Implement `validate.js`**

Create `dashboard/lib/validate.js`:

```js
// validate.js - the broker's argument rules (vps/tmuxkeep), applied before any ssh call so a bad
// input never costs a round trip, a TOTP prompt or an audit line (spec 6.4). Each check returns
// null when the input is acceptable, or the message the page shows. Messages repeat the broker's
// wording where the broker has one.

export const NAME_RE = /^[a-z][a-z0-9_-]{0,31}$/;
export const TOMB_RE = /^zz~[a-z][a-z0-9_-]{0,31}~[0-9]+$/;
export const URL_RE = /^https:\/\/[!-~]+$/;
// One line on purpose: tests/bats/parity.bats reads it.
export const ACTION_VERBS = ['new', 'send', 'rename', 'lock', 'unlock', 'rm', 'restore', 'resume', 'log', 'peek', 'status', 'auth'];
export const SEND_MAX_BYTES = 65536;

const CONTROL_RE = /[\x00-\x1f\x7f]/;
const PRINTABLE_RE = /^[\x20-\x7e]*$/;
const COUNT_RE = /^[0-9]{1,4}$/;

function nameError(s) {
  if (s === undefined) return 'missing session name';
  return NAME_RE.test(s) ? null : 'invalid session name';
}

function nameOrTombError(s) {
  if (s === undefined) return 'missing session name';
  return NAME_RE.test(s) || TOMB_RE.test(s) ? null : 'invalid session name';
}

function cmdError(s) {
  return s.length <= 200 && PRINTABLE_RE.test(s) ? null : '--cmd must be at most 200 printable ASCII characters';
}

function shown(s) {
  return s.replace(/[^\x20-\x7e]/g, '?').slice(0, 32);
}

const CHECKS = {
  new(args) {
    const usage = 'usage: tmuxkeep new <name> [--repo <https-url>] [--cmd <text>] [--shell]';
    let name;
    let repo;
    let cmd;
    let shell = false;
    for (let i = 0; i < args.length; i += 1) {
      const a = args[i];
      if (a === '--repo') {
        if (repo !== undefined || i + 1 >= args.length) return usage;
        i += 1;
        repo = args[i];
      } else if (a === '--cmd') {
        if (cmd !== undefined || i + 1 >= args.length) return usage;
        i += 1;
        cmd = args[i];
      } else if (a === '--shell') {
        if (shell) return usage;
        shell = true;
      } else {
        if (name !== undefined) return usage;
        name = a;
      }
    }
    const e = nameError(name);
    if (e) return e;
    if (repo !== undefined && !URL_RE.test(repo)) return '--repo must be an https:// URL';
    if (shell && cmd !== undefined) return '--shell and --cmd cannot be combined';
    return cmd === undefined ? null : cmdError(cmd);
  },

  send(args) {
    const e = nameError(args[0]);
    if (e) return e;
    const text = args.slice(1).join(' ');
    if (text === '') return 'nothing to send';
    if (CONTROL_RE.test(text)) return 'text contains control characters (line breaks and tabs cannot be sent; send one line at a time)';
    if (Buffer.byteLength(text, 'utf8') > SEND_MAX_BYTES) return `text longer than ${SEND_MAX_BYTES} bytes`;
    return null;
  },

  rename(args) {
    if (args.length !== 2) return 'usage: tmuxkeep rename <old> <new>';
    return nameError(args[0]) || (NAME_RE.test(args[1]) ? null : 'invalid session name');
  },

  lock(args) {
    if (args.length > 1) return 'usage: tmuxkeep lock <name>';
    return nameError(args[0]);
  },

  unlock(args) {
    if (args.length !== 1) return 'usage: tmuxkeep unlock <name>';
    return nameError(args[0]);
  },

  restore(args) {
    if (args.length !== 1) return 'usage: tmuxkeep restore <name>';
    return nameError(args[0]);
  },

  rm(args) {
    const usage = 'usage: tmuxkeep rm <name> [--now --confirm <name>]';
    let name;
    let now = false;
    let confirm;
    for (let i = 0; i < args.length; i += 1) {
      const a = args[i];
      if (a === '--now') {
        if (now) return usage;
        now = true;
      } else if (a === '--confirm') {
        if (confirm !== undefined || i + 1 >= args.length) return usage;
        i += 1;
        confirm = args[i];
      } else if (a.startsWith('--')) {
        return usage;
      } else {
        if (name !== undefined) return usage;
        name = a;
      }
    }
    if (name === undefined) return usage;
    if (confirm !== undefined && !now) return '--confirm needs --now';
    if (!now) return nameError(name);
    return nameOrTombError(name) || (confirm === name ? null : `--confirm must equal ${name}`);
  },

  resume(args) {
    const usage = 'usage: tmuxkeep resume <name> [--cmd <text>] [--shell]';
    let name;
    let cmd;
    let shell = false;
    for (let i = 0; i < args.length; i += 1) {
      const a = args[i];
      if (a === '--cmd') {
        if (cmd !== undefined || i + 1 >= args.length) return usage;
        i += 1;
        cmd = args[i];
      } else if (a === '--shell') {
        if (shell) return usage;
        shell = true;
      } else if (a.startsWith('--')) {
        return usage;
      } else {
        if (name !== undefined) return usage;
        name = a;
      }
    }
    if (name === undefined) return usage;
    const e = nameError(name);
    if (e) return e;
    if (shell && cmd !== undefined) return '--shell and --cmd cannot be combined';
    return cmd === undefined ? null : cmdError(cmd);
  },

  log(args) {
    if (args.length === 0) return null;
    if (args.length !== 2 || args[0] !== '-n') return 'usage: tmuxkeep log [-n N]';
    return COUNT_RE.test(args[1]) ? null : '-n must be 0-9999';
  },

  peek(args) {
    if (args.length === 2 || args.length > 3) return 'usage: tmuxkeep peek <name> [-n N]';
    if (args.length === 3) {
      if (args[1] !== '-n') return 'usage: tmuxkeep peek <name> [-n N]';
      if (!COUNT_RE.test(args[2])) return '-n must be 0-9999';
    }
    return nameOrTombError(args[0]);
  },

  status(args) {
    if (args.includes('--follow')) return 'status --follow is not an action';
    if (args.length === 0) return null;
    if (args.length !== 2 || args[0] !== '--lines') return 'usage: tmuxkeep status [--lines N]';
    return COUNT_RE.test(args[1]) && Number(args[1]) <= 40 ? null : '--lines must be 0-40';
  },

  auth(args) {
    return args.length === 1 && args[0] === '--end' ? null : 'only auth --end is allowed from the dashboard';
  },
};

// checkAction(words): null when /api/action may run these words, else the reason (spec 6.4).
export function checkAction(words) {
  if (!Array.isArray(words) || words.length === 0) return 'words must be a non-empty array of strings';
  for (const w of words) {
    if (typeof w !== 'string') return 'words must be a non-empty array of strings';
    if (w === '') return 'empty argument';
    if (!w.isWellFormed()) return 'argument is not valid text';
  }
  const [verb, ...args] = words;
  if (!ACTION_VERBS.includes(verb)) return `not allowed from the dashboard: ${shown(verb)}`;
  return CHECKS[verb](args);
}

// checkTerminal(body): null when /api/terminal may open a terminal for this body (spec 6.5).
export function checkTerminal(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return 'body must be an object';
  const keys = Object.keys(body).sort().join(',');
  if (body.verb === 'auth') return keys === 'verb' ? null : 'auth takes no name';
  if (body.verb === 'go') {
    if (keys !== 'name,verb' || typeof body.name !== 'string') return 'go needs a session name';
    return nameError(body.name);
  }
  return 'verb must be go or auth';
}
```

The rules mirror `vps/tmuxkeep` verb by verb (argument grammar, name and tombstone rules, `URL_RE`, `valid_cmd`, `has_ctrl`, `valid_count`), so a refusal here is the refusal the broker would give. Two places are stricter than the broker on purpose: `status --follow` is refused (an action must end), and `auth` is allowed only as `auth --end` (spec 6.4). Tabs are refused in `send` text as the broker refuses them (plan Q1).

- [ ] **Step 8: Implement `config.js`**

Create `dashboard/lib/config.js`:

```js
// config.js - the settings of tmuxkeep ui (spec 5.2, 6.1): DASHBOARD_PORT and TERMINAL_CMD from
// ~/.tmuxkeep/config, and the server's own command line. The deploy scripts validate the whole file;
// this reader looks only at its two keys and ignores every other line. A missing file or key takes
// the default.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const DEFAULT_PORT = 7707;
export const USAGE = 'usage: tmuxkeep ui [--port N] [--no-open]';

// configPath(home): the laptop config file.
export function configPath(home = os.homedir()) {
  return path.join(home, '.tmuxkeep', 'config');
}

// portValue(text): the port number for 1-7 decimal digits within 1024-65535, else null.
export function portValue(text) {
  if (!/^[0-9]{1,7}$/.test(text)) return null;
  const n = Number.parseInt(text, 10);
  return n >= 1024 && n <= 65535 ? n : null;
}

// readConfig(file): { port, terminalCmd }. Throws Error("config <file>: <reason>") for a bad value.
export function readConfig(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'latin1');
  } catch (err) {
    if (err.code === 'ENOENT') return { port: DEFAULT_PORT, terminalCmd: '' };
    throw new Error(`config ${file}: cannot read`);
  }
  const found = {};
  for (const raw of text.split('\n')) {
    const line = raw.replace(/^[ \t\r]+|[ \t\r]+$/g, '');
    if (line === '' || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).replace(/[ \t]+$/, '');
    if (key === 'DASHBOARD_PORT' || key === 'TERMINAL_CMD') found[key] = line.slice(eq + 1).replace(/^[ \t]+/, '');
  }
  const out = { port: DEFAULT_PORT, terminalCmd: '' };
  if (found.DASHBOARD_PORT !== undefined) {
    out.port = portValue(found.DASHBOARD_PORT);
    if (out.port === null) throw new Error(`config ${file}: DASHBOARD_PORT: must be an integer from 1024 to 65535`);
  }
  if (found.TERMINAL_CMD !== undefined) {
    if (!/^[\x20-\x7e]*$/.test(found.TERMINAL_CMD)) throw new Error(`config ${file}: TERMINAL_CMD: non-printable or non-ASCII character`);
    if (found.TERMINAL_CMD.length > 200) throw new Error(`config ${file}: TERMINAL_CMD: at most 200 characters`);
    out.terminalCmd = found.TERMINAL_CMD;
  }
  return out;
}

// parseArgs(argv): { port: number|null, open: boolean } for [--port N] [--no-open], each at most once.
// Throws Error(USAGE), or Error('--port must be an integer from 1024 to 65535').
export function parseArgs(argv) {
  const out = { port: null, open: true };
  let sawOpen = false;
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--no-open' && !sawOpen) {
      sawOpen = true;
      out.open = false;
    } else if (a === '--port' && out.port === null && i + 1 < argv.length) {
      i += 1;
      out.port = portValue(argv[i]);
      if (out.port === null) throw new Error('--port must be an integer from 1024 to 65535');
    } else {
      throw new Error(USAGE);
    }
  }
  return out;
}
```

- [ ] **Step 9: Run the Node tests**

Run: `node --test "dashboard/test/*.test.js"`
Expected: `pass 26`, `fail 0`.

- [ ] **Step 10: The parity assertion (spec 9)**

In `tests/bats/parity.bats`, after the line `deploy_conf_keys_fixture() { ... }` (line 33), add:

```bash
action_verbs() { sed -n "s/^export const ACTION_VERBS = \[\(.*\)];\$/\1/p" "$REPO/dashboard/lib/validate.js" | ps_list; }
```

and append:

```bash

@test "the dashboard's action allowlist is a subset of the broker's verbs, without go, ui or reap" {
  local a v broker
  a=$(action_verbs); one_line 'dashboard ACTION_VERBS' "$a"
  broker=" $(broker_verbs | tr '\n' ' ') "
  for v in $a; do
    case $broker in *" $v "*) ;; *) echo "not a broker verb: $v"; return 1 ;; esac
    case $v in go|ui|reap) echo "must not be allowed: $v"; return 1 ;; esac
  done
  [ "$(printf '%s' "$a" | sorted_words)" = 'auth lock log new peek rename restore resume rm send status unlock' ]
}
```

Run (Git Bash): `bash tests/run-bats.sh tests/bats/parity.bats`. Expected: all `ok`.

- [ ] **Step 11: Check line endings and run every suite**

Run (Git Bash): `grep -rlIU "$(printf '\r')" vps tests dashboard laptop/*.sh laptop/completion.bash` (prints nothing), then the whole bats directory (up by 2), the whole Pester folder (up by 1) and `node --test "dashboard/test/*.test.js"`.

- [ ] **Step 12: Commit**

```bash
git add .gitattributes dashboard tests/fixtures/b64-words tests/pester/static.Tests.ps1 tests/pester/tmuxkeep.Tests.ps1 tests/bats/laptop-wrapper.bats tests/bats/parity.bats
git commit -m "dashboard: protocol, validator and config modules; shared b64 fixture for all clients"
```

---

### Task 6: Dashboard: `ssh.js` and the stub ssh

Suggested model: sonnet.

**Files:**
- Create: `dashboard/lib/ssh.js`
- Create: `dashboard/test/stub-ssh.js`, `dashboard/test/helpers.js`, `dashboard/test/ssh.test.js`

**Interfaces:**
- Consumes (Task 5): `sshArgs(words)`.
- Produces (`dashboard/lib/ssh.js`): `ACTION_TIMEOUT_MS = 30000`, `MAX_OUTPUT_CHARS` (2 MiB of stdout and of stderr are kept; the rest is dropped so a huge `peek` cannot exhaust memory), `sshCommand(args, env): [program, argv]` (`TMUXKEEP_SSH` replaces `ssh`; a value ending in `.js` runs as `[process.execPath, [path, ...args]]`), `spawnSsh(words, env): ChildProcess` (stdin `ignore`, stdout and stderr pipes, `shell: false`, `windowsHide: true`), `runVerb(words, {timeoutMs, env}): Promise<{code, stdout, stderr, needs_auth}>` which never rejects: a run past `timeoutMs` is killed and answers `code: 124` with `tmuxkeep ui: no answer within <s> seconds; ssh was stopped` appended to stderr; a program that cannot start answers `code: 1` with `tmuxkeep ui: cannot run ssh: <code>` (Review Focus 4); `needs_auth` is `code === 4 && stderr.includes('TOTP required')` (spec 6.4).
- Produces (`dashboard/test/stub-ssh.js`): the ssh stand-in, scripted by the JSON file named in `TMUXKEEP_STUB_SCRIPT` (format in its header comment). It logs `{argv, words}` per call to `<script>.log`, so tests can assert the exact ssh arguments and the decoded words.
- Produces (`dashboard/test/helpers.js`, not a test file): `STUB`, `DASHBOARD` (absolute paths), `tempDir()`, `stubPlan(plan): {script, env, calls()}`, `waitFor(check, ms)`. Tasks 7 and 10 use them.

- [ ] **Step 1: The stub and the helpers**

Create `dashboard/test/stub-ssh.js`:

```js
// stub-ssh.js - stands in for ssh in the dashboard tests. TMUXKEEP_SSH points here and lib/ssh.js
// runs it with node. It checks the fixed argument prefix, decodes the b64 tokens, appends one JSON
// line {"argv":[...],"words":[...]} to <script>.log, then plays what the JSON file named by
// TMUXKEEP_STUB_SCRIPT says for the first decoded word (the verb), or for "*":
//   { "<verb>": [ { "steps": [ step, ... ], "code": 0 }, ... ], "*": [ ... ] }
//   step: {"out": "text"} | {"err": "text"} | {"sleep": ms} | {"hang": true} | {"stdin": true}
// The n-th call for a verb plays entry n; the last entry repeats. <script>.count-<verb> counts calls.
// "hang" waits until killed, but never longer than 20 seconds, so an orphan cannot outlive a test
// run. "stdin" reads stdin to its end and prints "stdin:<bytes>".
import fs from 'node:fs';

const PREFIX = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'tmuxkeep', 'b64'];
const argv = process.argv.slice(2);
const script = process.env.TMUXKEEP_STUB_SCRIPT;
if (!script) {
  process.stderr.write('stub-ssh: TMUXKEEP_STUB_SCRIPT is not set\n');
  process.exit(97);
}
const prefixOk = PREFIX.every((p, i) => argv[i] === p);
const words = prefixOk ? argv.slice(PREFIX.length).map((t) => Buffer.from(t, 'base64').toString('utf8')) : [];
fs.appendFileSync(`${script}.log`, JSON.stringify({ argv, words }) + '\n');
if (!prefixOk) {
  process.stderr.write('stub-ssh: unexpected arguments\n');
  process.exit(98);
}
const plan = JSON.parse(fs.readFileSync(script, 'utf8'));
const key = Object.hasOwn(plan, words[0] ?? '') ? words[0] : '*';
const entries = plan[key];
if (!Array.isArray(entries) || entries.length === 0) {
  process.stderr.write(`stub-ssh: no behaviour for ${words[0]}\n`);
  process.exit(99);
}
const counter = `${script}.count-${key === '*' ? 'any' : key}`;
let n = 0;
try {
  n = Number.parseInt(fs.readFileSync(counter, 'utf8'), 10) || 0;
} catch {
  n = 0;
}
fs.writeFileSync(counter, String(n + 1));
const entry = entries[Math.min(n, entries.length - 1)];

const write = (stream, text) => new Promise((resolve) => stream.write(text, resolve));
const readAll = () => new Promise((resolve) => {
  let bytes = 0;
  process.stdin.on('data', (b) => { bytes += b.length; });
  process.stdin.on('end', () => resolve(bytes));
  process.stdin.on('error', () => resolve(bytes));
});

for (const step of entry.steps ?? []) {
  if (step.out !== undefined) await write(process.stdout, step.out);
  if (step.err !== undefined) await write(process.stderr, step.err);
  if (step.sleep !== undefined) await new Promise((resolve) => setTimeout(resolve, step.sleep));
  if (step.stdin) await write(process.stdout, `stdin:${await readAll()}\n`);
  if (step.hang) await new Promise((resolve) => setTimeout(resolve, 20000));
}
process.exitCode = entry.code ?? 0;
```

Create `dashboard/test/helpers.js`:

```js
// helpers.js - shared by the dashboard tests (not a test file itself: only *.test.js files run).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const STUB = fileURLToPath(new URL('./stub-ssh.js', import.meta.url));
export const DASHBOARD = fileURLToPath(new URL('..', import.meta.url));

// tempDir(): a new empty directory under the system temp folder.
export function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'tk-dash-'));
}

// stubPlan(plan): writes the stub script and returns {script, env, calls()}. env runs ssh as the stub;
// calls() reads the log the stub appends to, one {argv, words} object per call.
export function stubPlan(plan) {
  const script = path.join(tempDir(), 'script.json');
  fs.writeFileSync(script, JSON.stringify(plan));
  const env = { ...process.env, TMUXKEEP_SSH: STUB, TMUXKEEP_STUB_SCRIPT: script };
  const calls = () => {
    try {
      return fs.readFileSync(`${script}.log`, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    } catch {
      return [];
    }
  };
  return { script, env, calls };
}

// waitFor(check, ms): resolves once check() is truthy, polling every 20 ms; rejects after ms.
export async function waitFor(check, ms = 5000) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await check();
    if (v) return v;
    if (Date.now() > end) throw new Error('waitFor: timed out');
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}
```

- [ ] **Step 2: Write the failing test**

Create `dashboard/test/ssh.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { runVerb, sshCommand } from '../lib/ssh.js';
import { sshArgs } from '../lib/protocol.js';
import { stubPlan, tempDir } from './helpers.js';

const TOTP = "tmuxkeep: TOTP required: run with a terminal or run 'tmuxkeep auth' first\n";

test('sshCommand: plain ssh by default, TMUXKEEP_SSH as the program, a .js path through this node', () => {
  assert.deepEqual(sshCommand(['a'], {}), ['ssh', ['a']]);
  assert.deepEqual(sshCommand(['a'], { TMUXKEEP_SSH: '/opt/ssh' }), ['/opt/ssh', ['a']]);
  assert.deepEqual(sshCommand(['a'], { TMUXKEEP_SSH: '/t/stub-ssh.js' }), [process.execPath, ['/t/stub-ssh.js', 'a']]);
});

test('runVerb sends the encoded words with the fixed prefix and no -t, and returns code, stdout and stderr', async () => {
  const s = stubPlan({ send: [{ steps: [{ out: 'sent 13 bytes to api\n' }], code: 0 }] });
  const r = await runVerb(['send', 'api', 'run the tests'], { env: s.env });
  assert.deepEqual(r, { code: 0, stdout: 'sent 13 bytes to api\n', stderr: '', needs_auth: false });
  const calls = s.calls();
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].argv, sshArgs(['send', 'api', 'run the tests']));
  assert.deepEqual(calls[0].words, ['send', 'api', 'run the tests']);
  assert.ok(!calls[0].argv.includes('-t'));
});

test('the exit code is the broker one, and needs_auth is code 4 with TOTP required on stderr', async () => {
  const s = stubPlan({
    rm: [{ steps: [{ err: 'tmuxkeep: session api is locked\n' }], code: 3 }],
    new: [
      { steps: [{ err: TOTP }], code: 4 },
      { steps: [{ err: 'tmuxkeep: wrong code\n' }], code: 4 },
      { steps: [{ out: TOTP }], code: 0 },
    ],
    log: [{ steps: [{ err: 'ssh: connect to host 203.0.113.10 port 22: Connection refused\n' }], code: 255 }],
  });
  assert.deepEqual(await runVerb(['rm', 'api'], { env: s.env }),
    { code: 3, stdout: '', stderr: 'tmuxkeep: session api is locked\n', needs_auth: false });
  assert.equal((await runVerb(['new', 'api'], { env: s.env })).needs_auth, true);
  assert.equal((await runVerb(['new', 'api'], { env: s.env })).needs_auth, false);
  assert.equal((await runVerb(['new', 'api'], { env: s.env })).needs_auth, false);
  assert.equal((await runVerb(['log'], { env: s.env })).code, 255);
});

test('stdin is closed: the child reads end of input at once', async () => {
  const s = stubPlan({ log: [{ steps: [{ stdin: true }], code: 0 }] });
  assert.equal((await runVerb(['log'], { env: s.env, timeoutMs: 5000 })).stdout, 'stdin:0\n');
});

test('a run that outlives the timeout is killed and reported as 124', async () => {
  const s = stubPlan({ peek: [{ steps: [{ out: 'partial\n' }, { hang: true }], code: 0 }] });
  const started = Date.now();
  const r = await runVerb(['peek', 'api'], { env: s.env, timeoutMs: 300 });
  assert.equal(r.code, 124);
  assert.equal(r.needs_auth, false);
  assert.match(r.stderr, /no answer within 0 seconds; ssh was stopped\n$/);
  assert.ok(Date.now() - started < 5000);
});

// Review Focus 4: ssh that cannot be started (missing, or a command line too long for Windows) is an
// answer with code 1, never a crash of the server.
test('a program that cannot be started is code 1 with the reason, and nothing throws', async () => {
  const env = { ...process.env, TMUXKEEP_SSH: path.join(tempDir(), 'no-such-ssh') };
  const r = await runVerb(['log'], { env });
  assert.equal(r.code, 1);
  assert.equal(r.needs_auth, false);
  assert.match(r.stderr, /^tmuxkeep ui: cannot run ssh: (ENOENT|EACCES|UNKNOWN)\n$/);
});
```

- [ ] **Step 3: Run it to see it fail**

Run: `node --test "dashboard/test/ssh.test.js"`
Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `../lib/ssh.js`.

- [ ] **Step 4: Implement**

Create `dashboard/lib/ssh.js`:

```js
// ssh.js - runs one broker verb over the session key's ssh alias (spec 6.4): an argv array, never a
// shell, never -t, stdin closed. TMUXKEEP_SSH replaces the ssh program for tests; a path that ends
// in .js is run with this Node (the test stub, dashboard/test/stub-ssh.js).
import { spawn } from 'node:child_process';
import { sshArgs } from './protocol.js';

export const ACTION_TIMEOUT_MS = 30000;
export const MAX_OUTPUT_CHARS = 2 * 1024 * 1024;

// sshCommand(args, env): [program, argv] for the ssh argument list args.
export function sshCommand(args, env = process.env) {
  const override = env.TMUXKEEP_SSH;
  if (override) {
    if (override.endsWith('.js')) return [process.execPath, [override, ...args]];
    return [override, args];
  }
  return ['ssh', args];
}

// spawnSsh(words, env): the ChildProcess for these words; stdout and stderr are pipes.
export function spawnSsh(words, env = process.env) {
  const [program, argv] = sshCommand(sshArgs(words), env);
  return spawn(program, argv, { stdio: ['ignore', 'pipe', 'pipe'], shell: false, windowsHide: true, env });
}

// runVerb(words, opts): resolves to {code, stdout, stderr, needs_auth}; never rejects. A run longer
// than timeoutMs is killed and reported as code 124. A program that cannot be started is code 1.
export function runVerb(words, { timeoutMs = ACTION_TIMEOUT_MS, env = process.env } = {}) {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    let done = false;
    let timer = null;
    const finish = (code, extra) => {
      if (done) return;
      done = true;
      if (timer) clearTimeout(timer);
      if (extra) stderr += (stderr === '' || stderr.endsWith('\n') ? '' : '\n') + extra + '\n';
      resolve({ code, stdout, stderr, needs_auth: code === 4 && stderr.includes('TOTP required') });
    };
    let child;
    try {
      child = spawnSsh(words, env);
    } catch (err) {
      finish(1, `tmuxkeep ui: cannot run ssh: ${err.code || err.message}`);
      return;
    }
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (s) => { if (stdout.length < MAX_OUTPUT_CHARS) stdout += s; });
    child.stderr.on('data', (s) => { if (stderr.length < MAX_OUTPUT_CHARS) stderr += s; });
    child.on('error', (err) => finish(1, `tmuxkeep ui: cannot run ssh: ${err.code || err.message}`));
    child.on('close', (code) => {
      if (timedOut) finish(124, `tmuxkeep ui: no answer within ${Math.round(timeoutMs / 1000)} seconds; ssh was stopped`);
      else finish(code === null ? 1 : code);
    });
    timer = setTimeout(() => {
      timedOut = true;
      child.kill();
    }, timeoutMs);
  });
}
```

- [ ] **Step 5: Run the tests**

Run: `node --test "dashboard/test/*.test.js"`
Expected: `pass 32`, `fail 0`. The timeout test takes about 0.3 seconds; the stub it starts is killed by `runVerb`.

- [ ] **Step 6: Commit**

```bash
git add dashboard/lib/ssh.js dashboard/test/stub-ssh.js dashboard/test/helpers.js dashboard/test/ssh.test.js
git commit -m "dashboard: run one verb over ssh (timeout 124, needs_auth) and a scripted stub ssh"
```

---

### Task 7: Dashboard: `follow.js`

Suggested model: sonnet.

**Files:**
- Create: `dashboard/lib/follow.js`, `dashboard/test/follow.test.js`

**Interfaces:**
- Consumes (Task 6): `spawnSsh(words, env)` (only the last test; the others inject fake children); `stubPlan`, `waitFor` from `test/helpers.js`.
- Produces: `FOLLOW_WORDS = ['status','--follow','--lines','12']`, `BACKOFF_MS = [2000,4000,8000,16000,30000]`, `IDLE_MS = 120000`, `MAX_LINE_CHARS`, `endMessage(code, err, lastErr): string`, and `createFollower({spawnChild, clock, backoffMs, idleMs})` returning `{touch(), state(), stop(), stats()}`:
  - `touch()`: a page asked for the state. Re-arms the idle timer; starts the child when none runs and no restart is pending. The first `touch()` is what starts the connection (spec 6.1 step 6).
  - `state()`: `{snapshot, connected, updated, error}`, the body of `/api/state` (spec 6.2). Each parsed object replaces `snapshot`, sets `updated` to `clock.now()` (ms), `connected = true`, `error = null`, and resets the backoff. A line that is not a JSON object is dropped and counted.
  - When the child ends: `connected = false`; `error` is `ssh exited 255: VPS unreachable` for 255, else the last non-empty stderr line (Review Focus 5), else `ssh exited <code>`; `cannot run ssh: <code>` when it could not start (Review Focus 4). It restarts after 2, 4, 8, 16, 30, 30... seconds.
  - Idle stop: no `touch()` for `idleMs` kills the child and cancels a pending restart; `connected` becomes `false`; the snapshot and error stay.
  - `stop()`: for shutdown; kills the child; nothing restarts afterwards.
  - `stats()`: `{badLines, starts, running, waiting}` for the tests.
  - `clock` defaults to the real `Date.now`/`setTimeout`/`clearTimeout`; the tests inject a manual clock.

- [ ] **Step 1: Write the failing test**

Create `dashboard/test/follow.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { createFollower, endMessage, FOLLOW_WORDS } from '../lib/follow.js';
import { spawnSsh } from '../lib/ssh.js';
import { stubPlan, waitFor } from './helpers.js';

// A clock whose timers run only when advance() passes their due time.
function fakeClock() {
  let t = 1000000;
  let seq = 0;
  const timers = new Map();
  return {
    now: () => t,
    setTimeout(fn, ms) {
      seq += 1;
      timers.set(seq, { at: t + ms, fn });
      return seq;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    advance(ms) {
      const end = t + ms;
      for (;;) {
        let next = null;
        for (const [id, tm] of timers) if (tm.at <= end && (next === null || tm.at < next[1].at)) next = [id, tm];
        if (next === null) break;
        timers.delete(next[0]);
        t = next[1].at;
        next[1].fn();
      }
      t = end;
    },
    pending: () => [...timers.values()].map((x) => x.at - t).sort((a, b) => a - b),
  };
}

// A child process stand-in; kill() closes it with no exit code, as a signal would.
function fakeChild() {
  const c = new EventEmitter();
  c.stdout = new PassThrough();
  c.stderr = new PassThrough();
  c.killed = false;
  c.kill = () => {
    c.killed = true;
    c.emit('close', null);
    return true;
  };
  return c;
}

const flush = () => new Promise((resolve) => setImmediate(resolve));

function setup(opts = {}) {
  const clock = fakeClock();
  const children = [];
  const f = createFollower({
    clock,
    spawnChild: () => {
      if (opts.throwOnSpawn) throw Object.assign(new Error('spawn ssh ENOENT'), { code: 'ENOENT' });
      const c = fakeChild();
      children.push(c);
      return c;
    },
  });
  return { clock, children, f };
}

const SNAP = { version: 'dev', lease_secs_left: 0, sessions: [] };

test('the follow words are status --follow --lines 12', () => {
  assert.deepEqual(FOLLOW_WORDS, ['status', '--follow', '--lines', '12']);
});

test('nothing starts before the first touch; the state starts empty', () => {
  const { children, f } = setup();
  assert.deepEqual(f.state(), { snapshot: null, connected: false, updated: null, error: null });
  assert.equal(children.length, 0);
  f.touch();
  f.touch();
  assert.equal(children.length, 1);
});

test('each object replaces the snapshot and sets updated; lines split across chunks are joined', async () => {
  const { clock, children, f } = setup();
  f.touch();
  const text = JSON.stringify(SNAP);
  children[0].stdout.write(text.slice(0, 10));
  await flush();
  assert.equal(f.state().snapshot, null);
  children[0].stdout.write(text.slice(10) + '\n');
  await flush();
  assert.deepEqual(f.state(), { snapshot: SNAP, connected: true, updated: clock.now(), error: null });
  clock.advance(2000);
  children[0].stdout.write(JSON.stringify({ ...SNAP, lease_secs_left: 5 }) + '\r\n');
  await flush();
  assert.equal(f.state().snapshot.lease_secs_left, 5);
  assert.equal(f.state().updated, clock.now());
});

test('unparsable lines are dropped and counted; the last good snapshot stays', async () => {
  const { children, f } = setup();
  f.touch();
  children[0].stdout.write(JSON.stringify(SNAP) + '\nnot json\n[1,2]\n42\nnull\n\n{"half":\n');
  await flush();
  assert.deepEqual(f.state().snapshot, SNAP);
  assert.equal(f.stats().badLines, 5);
});

test('after an exit the error is shown and the restarts back off 2, 4, 8, 16, 30, 30 seconds', async () => {
  const { clock, children, f } = setup();
  f.touch();
  children[0].emit('close', 255);
  assert.deepEqual(f.state(), { snapshot: null, connected: false, updated: null, error: 'ssh exited 255: VPS unreachable' });
  const delays = [];
  for (let i = 0; i < 6; i += 1) {
    const due = clock.pending()[0]; // the restart; the idle stop is further away
    delays.push(due);
    clock.advance(due);
    assert.equal(children.length, i + 2);
    children[i + 1].emit('close', 255);
  }
  assert.deepEqual(delays, [2000, 4000, 8000, 16000, 30000, 30000]);
});

test('an object resets the backoff to 2 seconds', async () => {
  const { clock, children, f } = setup();
  f.touch();
  children[0].emit('close', 255);
  clock.advance(2000);
  children[1].emit('close', 255);
  clock.advance(4000);
  children[2].stdout.write(JSON.stringify(SNAP) + '\n');
  await flush();
  children[2].emit('close', 255);
  assert.equal(clock.pending()[0], 2000);
});

// Review Focus 5: a VPS whose broker has no status verb yet answers with exit 2 and one stderr line.
test('the last stderr line becomes the error: an old broker says unknown verb: status', async () => {
  const { children, f } = setup();
  f.touch();
  children[0].stderr.write('Warning: something\ntmuxkeep: unknown verb: status\n');
  await flush();
  children[0].emit('close', 2);
  assert.equal(f.state().error, 'tmuxkeep: unknown verb: status');
  assert.equal(f.state().connected, false);
});

// Review Focus 4: ssh that cannot be started must not crash the server; it shows and backs off.
test('a child that fails to start reports cannot run ssh and is retried with backoff', async () => {
  const { clock, children, f } = setup();
  f.touch();
  children[0].emit('error', Object.assign(new Error('spawn ssh ENOENT'), { code: 'ENOENT' }));
  children[0].emit('close', -4058);
  assert.equal(f.state().error, 'cannot run ssh: ENOENT');
  assert.equal(clock.pending()[0], 2000);
  const thrown = setup({ throwOnSpawn: true });
  thrown.f.touch();
  assert.equal(thrown.f.state().error, 'cannot run ssh: ENOENT');
  assert.equal(thrown.clock.pending()[0], 2000);
});

test('endMessage covers a signal and a plain exit code', () => {
  assert.equal(endMessage(null, null, ''), 'ssh was stopped by a signal');
  assert.equal(endMessage(1, null, ''), 'ssh exited 1');
  assert.equal(endMessage(1, null, 'tmuxkeep: config invalid: x'), 'tmuxkeep: config invalid: x');
  assert.equal(endMessage(255, null, 'ssh: connect to host x port 22: Connection refused'), 'ssh exited 255: VPS unreachable');
});

test('with no touch for 120 seconds the child is killed and nothing restarts; the next touch starts it at once', async () => {
  const { clock, children, f } = setup();
  f.touch();
  children[0].stdout.write(JSON.stringify(SNAP) + '\n');
  await flush();
  clock.advance(60000);
  f.touch();
  clock.advance(119999);
  assert.equal(children[0].killed, false);
  clock.advance(1);
  assert.equal(children[0].killed, true);
  assert.equal(f.state().connected, false);
  assert.deepEqual(f.state().snapshot, SNAP);
  assert.equal(f.state().error, null);
  clock.advance(600000);
  assert.equal(children.length, 1);
  f.touch();
  assert.equal(children.length, 2);
});

test('going idle while waiting to restart cancels the restart', () => {
  const { clock, children, f } = setup();
  f.touch();
  clock.advance(119000);
  children[0].emit('close', 255); // the restart is due at 121000, after the idle stop at 120000
  clock.advance(1000);
  assert.equal(children.length, 1);
  assert.equal(f.stats().waiting, false);
  clock.advance(60000);
  assert.equal(children.length, 1);
});

test('stop() kills the child and nothing restarts, even on touch', () => {
  const { clock, children, f } = setup();
  f.touch();
  f.stop();
  assert.equal(children[0].killed, true);
  clock.advance(600000);
  f.touch();
  assert.equal(children.length, 1);
});

test('with the stub as ssh: the real child is parsed, and its end is noticed', async () => {
  const snap = JSON.stringify(SNAP) + '\n';
  const s = stubPlan({ status: [{ steps: [{ out: snap }, { sleep: 50 }, { out: 'garbage\n' }, { err: 'tmuxkeep: bye\n' }], code: 1 }] });
  const f = createFollower({ spawnChild: () => spawnSsh(FOLLOW_WORDS, s.env), backoffMs: [60000] });
  f.touch();
  await waitFor(() => f.state().error === 'tmuxkeep: bye');
  assert.deepEqual(f.state().snapshot, SNAP);
  assert.equal(f.stats().badLines, 1);
  assert.deepEqual(s.calls()[0].words, ['status', '--follow', '--lines', '12']);
  f.stop();
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `node --test "dashboard/test/follow.test.js"`
Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `../lib/follow.js`.

- [ ] **Step 3: Implement**

Create `dashboard/lib/follow.js`:

```js
// follow.js - the one VPS connection the dashboard keeps (spec 6.3, D15): "status --follow" as a
// child process whose stdout is one JSON object per line. Each object replaces the snapshot. When the
// child ends, it is started again after 2, 4, 8, 16, 30, 30... seconds (back to 2 after an object).
// With no touch() (no /api/state request) for IDLE_MS the child is stopped; the next touch() starts
// it again, so a closed browser tab does not keep an ssh session open all day.

export const FOLLOW_WORDS = Object.freeze(['status', '--follow', '--lines', '12']);
export const BACKOFF_MS = Object.freeze([2000, 4000, 8000, 16000, 30000]);
export const IDLE_MS = 120000;
export const MAX_LINE_CHARS = 8 * 1024 * 1024;

const realClock = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (t) => clearTimeout(t),
};

// endMessage(code, err, lastErr): the error shown after the child ended.
export function endMessage(code, err, lastErr) {
  if (err) return `cannot run ssh: ${err.code || err.message}`;
  if (code === 255) return 'ssh exited 255: VPS unreachable';
  if (lastErr) return lastErr;
  return code === null ? 'ssh was stopped by a signal' : `ssh exited ${code}`;
}

// createFollower({spawnChild, clock, backoffMs, idleMs}): spawnChild() returns a ChildProcess (or an
// object with the same events, stdout, stderr and kill()). Returns {touch, state, stop, stats}.
export function createFollower({ spawnChild, clock = realClock, backoffMs = BACKOFF_MS, idleMs = IDLE_MS }) {
  const st = { snapshot: null, connected: false, updated: null, error: null };
  let child = null;
  let restartTimer = null;
  let idleTimer = null;
  let idle = false;
  let stopped = false;
  let attempt = 0;
  let badLines = 0;
  let starts = 0;

  function onLine(raw) {
    const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    if (line.trim() === '') return;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      badLines += 1;
      return;
    }
    if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
      badLines += 1;
      return;
    }
    st.snapshot = obj;
    st.updated = clock.now();
    st.connected = true;
    st.error = null;
    attempt = 0;
  }

  function schedule() {
    if (stopped || idle) return;
    const delay = backoffMs[Math.min(attempt, backoffMs.length - 1)];
    attempt += 1;
    restartTimer = clock.setTimeout(start, delay);
  }

  function start() {
    restartTimer = null;
    starts += 1;
    let ended = false;
    let buf = '';
    let errTail = '';
    let lastErr = '';
    let c;
    const end = (code, err) => {
      if (ended) return;
      ended = true;
      if (child !== c) return; // stopped on purpose: idle or shutdown
      child = null;
      st.connected = false;
      st.error = endMessage(code, err, lastErr);
      schedule();
    };
    try {
      c = spawnChild();
    } catch (err) {
      c = null;
      child = null;
      st.connected = false;
      st.error = endMessage(null, err, '');
      schedule();
      return;
    }
    child = c;
    c.on('error', (err) => end(null, err));
    c.on('close', (code) => end(code, null));
    c.stdout.setEncoding('utf8');
    c.stderr.setEncoding('utf8');
    c.stdout.on('data', (chunk) => {
      if (child !== c) return;
      buf += chunk;
      let nl = buf.indexOf('\n');
      while (nl >= 0) {
        onLine(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
        nl = buf.indexOf('\n');
      }
      if (buf.length > MAX_LINE_CHARS) {
        badLines += 1;
        buf = '';
      }
    });
    c.stderr.on('data', (chunk) => {
      errTail = (errTail + chunk).slice(-4096);
      const lines = errTail.split('\n').map((l) => l.replace(/\r$/, '')).filter((l) => l.trim() !== '');
      if (lines.length > 0) lastErr = lines[lines.length - 1];
    });
  }

  function goIdle() {
    idleTimer = null;
    idle = true;
    attempt = 0;
    if (restartTimer) {
      clock.clearTimeout(restartTimer);
      restartTimer = null;
    }
    const c = child;
    child = null;
    st.connected = false;
    if (c) c.kill();
  }

  return {
    // touch(): a page asked for the state. Starts the child when none runs or waits to restart.
    touch() {
      if (stopped) return;
      if (idleTimer) clock.clearTimeout(idleTimer);
      idleTimer = clock.setTimeout(goIdle, idleMs);
      idle = false;
      if (!child && !restartTimer) start();
    },
    // state(): the /api/state body (spec 6.2).
    state() {
      return { snapshot: st.snapshot, connected: st.connected, updated: st.updated, error: st.error };
    },
    // stop(): for shutdown. Kills the child; nothing restarts.
    stop() {
      stopped = true;
      for (const t of [restartTimer, idleTimer]) if (t) clock.clearTimeout(t);
      restartTimer = null;
      idleTimer = null;
      const c = child;
      child = null;
      st.connected = false;
      if (c) c.kill();
    },
    // stats(): for the tests.
    stats() {
      return { badLines, starts, running: child !== null, waiting: restartTimer !== null };
    },
  };
}
```

- [ ] **Step 4: Run the tests**

Run: `node --test "dashboard/test/*.test.js"`
Expected: `pass 45`, `fail 0`.

- [ ] **Step 5: Commit**

```bash
git add dashboard/lib/follow.js dashboard/test/follow.test.js
git commit -m "dashboard: the follow connection (NDJSON, backoff, idle stop)"
```

---

### Task 8: Dashboard: `terminal.js`

Suggested model: sonnet.

**Files:**
- Create: `dashboard/lib/terminal.js`, `dashboard/test/terminal.test.js`

**Interfaces:**
- Consumes: nothing from earlier tasks (the request it gets has passed `checkTerminal`, Task 5).
- Produces: `wrapperArgv({verb, name, platform, home})`; `onPath(file, {platform, pathEnv, lstat})`; `shQuote(s)`; `appleScriptString(s)`; `terminalArgv({verb, name, platform, home, terminalCmd, pathEnv, terminalEnv, lstat})` (throws `Error('no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config')`); `spawnDetached(argv, spawnFn, extra): Promise<null|string>`; `openTerminal(request, {platform, home, terminalCmd, env, spawnFn, lstat}): Promise<{ok: true, argv} | {ok: false, error}>`; `browserArgv(url, platform)`; `openBrowser(url, {platform, env, spawnFn}): Promise<{argv, error}>`. With `env.TMUXKEEP_TERMINAL_DRYRUN === '1'` neither `openTerminal` nor `openBrowser` starts anything; both still return the argv (spec 6.5, G5).
- The launcher order is spec 6.5's: `TERMINAL_CMD` split on single spaces (empty pieces dropped, plan Q16) plus the wrapper command; on Windows `wt.exe -w 0 new-tab --title "tmuxkeep <verb> [<name>]" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File <home>\scripts\tmuxkeep.ps1 <verb> [<name>]` when `wt.exe` is on `PATH`, else that `powershell.exe` command started detached (its own console); on macOS `osascript -e 'tell application "Terminal" to do script "<cmd>"' -e 'tell application "Terminal" to activate'` (orchestrator ruling Q24) with every word single-quoted for sh and the whole AppleScript-escaped; on Linux `x-terminal-emulator -e <wrapper> <verb> [<name>]`, else `$TERMINAL -e ...`. When the Windows Terminal alias is found but fails to start, the plain console window is used instead (plan Q14). Every spawn has `shell: false`. The browser: `cmd.exe /c start "" <url>` (with `windowsVerbatimArguments`), `open <url>`, `xdg-open <url>`.

- [ ] **Step 1: Write the failing test**

Create `dashboard/test/terminal.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import {
  appleScriptString, browserArgv, onPath, openBrowser, openTerminal, shQuote, terminalArgv, wrapperArgv,
} from '../lib/terminal.js';

const WIN_HOME = 'C:\\Users\\you';
const PS = (home, ...words) => ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', `${home}\\scripts\\tmuxkeep.ps1`, ...words];

// lstatOnly(paths): an lstat that finds exactly these paths.
const lstatOnly = (...paths) => (p) => {
  if (paths.includes(p)) return {};
  throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' });
};

// fakeSpawn(outcomes): records each call; the n-th call emits 'spawn' or 'error' per outcomes[n].
function fakeSpawn(outcomes) {
  const calls = [];
  const fn = (cmd, args, options) => {
    const child = new EventEmitter();
    child.unref = () => {};
    const outcome = outcomes[calls.length] ?? 'spawn';
    calls.push({ argv: [cmd, ...args], options });
    setImmediate(() => (outcome === 'spawn' ? child.emit('spawn') : child.emit('error', Object.assign(new Error(outcome), { code: outcome }))));
    return child;
  };
  return { fn, calls };
}

test('the wrapper command per platform', () => {
  assert.deepEqual(wrapperArgv({ verb: 'go', name: 'api', platform: 'win32', home: WIN_HOME }), PS(WIN_HOME, 'go', 'api'));
  assert.deepEqual(wrapperArgv({ verb: 'auth', platform: 'linux', home: '/home/you' }), ['/home/you/.local/bin/tmuxkeep', 'auth']);
  assert.deepEqual(wrapperArgv({ verb: 'go', name: 'api', platform: 'darwin', home: '/Users/you' }), ['/Users/you/.local/bin/tmuxkeep', 'go', 'api']);
});

test('Windows: a new Windows Terminal tab when wt.exe is on PATH, titled tmuxkeep <verb> [<name>]', () => {
  const pathEnv = 'C:\\Windows\\System32;C:\\Users\\you\\AppData\\Local\\Microsoft\\WindowsApps';
  const lstat = lstatOnly('C:\\Users\\you\\AppData\\Local\\Microsoft\\WindowsApps\\wt.exe');
  assert.deepEqual(terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home: WIN_HOME, pathEnv, lstat }),
    ['wt.exe', '-w', '0', 'new-tab', '--title', 'tmuxkeep go api', ...PS(WIN_HOME, 'go', 'api')]);
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'win32', home: WIN_HOME, pathEnv, lstat }),
    ['wt.exe', '-w', '0', 'new-tab', '--title', 'tmuxkeep auth', ...PS(WIN_HOME, 'auth')]);
});

test('Windows: without wt.exe, powershell.exe itself (started detached, it gets its own console)', () => {
  assert.deepEqual(terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home: WIN_HOME, pathEnv: 'C:\\Windows', lstat: lstatOnly() }),
    PS(WIN_HOME, 'go', 'api'));
});

// Review Focus 2: a home directory with spaces or a quote.
test('a home directory with spaces stays one argument; a quote in a macOS home is quoted for sh and AppleScript', () => {
  const home = 'C:\\Users\\John Smith';
  const argv = terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home, pathEnv: '', lstat: lstatOnly() });
  assert.equal(argv[6], 'C:\\Users\\John Smith\\scripts\\tmuxkeep.ps1');
  assert.equal(argv.length, 9);
  const mac = terminalArgv({ verb: 'go', name: 'api', platform: 'darwin', home: "/Users/o'brien \"x\"" });
  assert.deepEqual(mac, ['osascript', '-e',
    'tell application "Terminal" to do script "\'/Users/o\'\\\\\'\'brien \\"x\\"/.local/bin/tmuxkeep\' \'go\' \'api\'"',
    '-e', 'tell application "Terminal" to activate']);
});

test('macOS: Terminal via osascript, every word single-quoted', () => {
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'darwin', home: '/Users/you' }),
    ['osascript', '-e', 'tell application "Terminal" to do script "\'/Users/you/.local/bin/tmuxkeep\' \'auth\'"',
      '-e', 'tell application "Terminal" to activate']);
  assert.equal(shQuote("a'b"), "'a'\\''b'");
  assert.equal(appleScriptString('a"b\\c'), '"a\\"b\\\\c"');
});

test('Linux: x-terminal-emulator -e, else $TERMINAL -e, else an error naming TERMINAL_CMD', () => {
  const home = '/home/you';
  const lstat = lstatOnly('/usr/bin/x-terminal-emulator');
  assert.deepEqual(terminalArgv({ verb: 'go', name: 'api', platform: 'linux', home, pathEnv: '/bin:/usr/bin', lstat }),
    ['x-terminal-emulator', '-e', '/home/you/.local/bin/tmuxkeep', 'go', 'api']);
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'linux', home, pathEnv: '/bin', terminalEnv: 'kitty', lstat }),
    ['kitty', '-e', '/home/you/.local/bin/tmuxkeep', 'auth']);
  assert.throws(() => terminalArgv({ verb: 'auth', platform: 'linux', home, pathEnv: '/bin', lstat }),
    { message: 'no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config' });
});

test('TERMINAL_CMD comes first on every platform, split on single spaces, the wrapper words appended', () => {
  assert.deepEqual(terminalArgv({ verb: 'go', name: 'api', platform: 'linux', home: '/home/you', terminalCmd: 'alacritty  -e' }),
    ['alacritty', '-e', '/home/you/.local/bin/tmuxkeep', 'go', 'api']);
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'win32', home: WIN_HOME, terminalCmd: 'wezterm start --' }),
    ['wezterm', 'start', '--', ...PS(WIN_HOME, 'auth')]);
});

test('onPath splits PATH by platform and ignores empty parts', () => {
  assert.equal(onPath('x', { platform: 'linux', pathEnv: '::/a', lstat: lstatOnly('/a/x') }), true);
  assert.equal(onPath('x', { platform: 'linux', pathEnv: '', lstat: lstatOnly('/a/x') }), false);
  assert.equal(onPath('x.exe', { platform: 'win32', pathEnv: 'C:\\a;;C:\\b', lstat: lstatOnly('C:\\b\\x.exe') }), true);
});

test('dry run returns the argv and starts nothing', async () => {
  const s = fakeSpawn([]);
  const r = await openTerminal({ verb: 'go', name: 'api' },
    { platform: 'linux', home: '/home/you', env: { TMUXKEEP_TERMINAL_DRYRUN: '1', TERMINAL: 'kitty', PATH: '/nowhere' }, spawnFn: s.fn, lstat: lstatOnly() });
  assert.deepEqual(r, { ok: true, argv: ['kitty', '-e', '/home/you/.local/bin/tmuxkeep', 'go', 'api'] });
  assert.equal(s.calls.length, 0);
});

test('a real start is detached, without a shell; a failure is reported; no terminal is an error', async () => {
  const s = fakeSpawn(['spawn']);
  const env = { TERMINAL: 'kitty', PATH: '/nowhere' };
  const r = await openTerminal({ verb: 'auth' }, { platform: 'linux', home: '/home/you', env, spawnFn: s.fn, lstat: lstatOnly() });
  assert.equal(r.ok, true);
  assert.equal(s.calls[0].options.shell, false);
  assert.equal(s.calls[0].options.detached, true);
  const f = fakeSpawn(['ENOENT']);
  assert.deepEqual(await openTerminal({ verb: 'auth' }, { platform: 'linux', home: '/home/you', env, spawnFn: f.fn, lstat: lstatOnly() }),
    { ok: false, error: 'cannot start kitty: ENOENT' });
  assert.deepEqual(await openTerminal({ verb: 'auth' }, { platform: 'linux', home: '/home/you', env: { PATH: '' }, spawnFn: f.fn, lstat: lstatOnly() }),
    { ok: false, error: 'no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config' });
});

test('Windows: when the wt.exe alias fails to start, a plain console window is used instead', async () => {
  const s = fakeSpawn(['UNKNOWN', 'spawn']);
  const env = { PATH: 'C:\\apps' };
  const r = await openTerminal({ verb: 'go', name: 'api' }, { platform: 'win32', home: WIN_HOME, env, spawnFn: s.fn, lstat: lstatOnly('C:\\apps\\wt.exe') });
  assert.deepEqual(r, { ok: true, argv: PS(WIN_HOME, 'go', 'api') });
  assert.equal(s.calls[0].argv[0], 'wt.exe');
});

test('the browser command per platform; cmd.exe gets verbatim arguments; dry run starts nothing', async () => {
  const url = 'http://127.0.0.1:7707/0123456789abcdef0123456789abcdef/';
  assert.deepEqual(browserArgv(url, 'win32'), ['cmd.exe', '/c', 'start', '""', url]);
  assert.deepEqual(browserArgv(url, 'darwin'), ['open', url]);
  assert.deepEqual(browserArgv(url, 'linux'), ['xdg-open', url]);
  const s = fakeSpawn(['spawn']);
  assert.deepEqual(await openBrowser(url, { platform: 'win32', env: {}, spawnFn: s.fn }), { argv: browserArgv(url, 'win32'), error: null });
  assert.equal(s.calls[0].options.windowsVerbatimArguments, true);
  const d = fakeSpawn([]);
  assert.deepEqual(await openBrowser(url, { platform: 'linux', env: { TMUXKEEP_TERMINAL_DRYRUN: '1' }, spawnFn: d.fn }), { argv: ['xdg-open', url], error: null });
  assert.equal(d.calls.length, 0);
  const f = fakeSpawn(['ENOENT']);
  assert.deepEqual(await openBrowser(url, { platform: 'linux', env: {}, spawnFn: f.fn }), { argv: ['xdg-open', url], error: 'ENOENT' });
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `node --test "dashboard/test/terminal.test.js"`
Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `../lib/terminal.js`.

- [ ] **Step 3: Implement**

Create `dashboard/lib/terminal.js`:

```js
// terminal.js - starts the programs the dashboard hands work to (spec 6.5, 6.1 step 5, D14): a
// terminal window or tab that runs the laptop wrapper for go and auth, so the TOTP code is only ever
// typed into a real terminal, and the browser. Every spawn is an argv array with shell: false.
// TMUXKEEP_TERMINAL_DRYRUN=1 returns the argv instead of starting anything (tests).
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// wrapperArgv({verb, name, platform, home}): the command that runs the installed wrapper.
export function wrapperArgv({ verb, name, platform, home }) {
  const words = name ? [verb, name] : [verb];
  if (platform === 'win32') {
    const script = path.win32.join(home, 'scripts', 'tmuxkeep.ps1');
    return ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', script, ...words];
  }
  return [path.posix.join(home, '.local', 'bin', 'tmuxkeep'), ...words];
}

// onPath(file, {platform, pathEnv, lstat}): true when a directory of pathEnv holds file. lstat, not
// stat or exists: the Windows Terminal alias WindowsApps\wt.exe is a reparse point that stat refuses
// with EACCES (seen on Node 24), while lstat finds it.
export function onPath(file, { platform, pathEnv, lstat = fs.lstatSync }) {
  const p = platform === 'win32' ? path.win32 : path.posix;
  for (const dir of (pathEnv || '').split(platform === 'win32' ? ';' : ':')) {
    if (!dir) continue;
    try {
      lstat(p.join(dir, file));
      return true;
    } catch {
      // not in this directory
    }
  }
  return false;
}

// shQuote(s): s in single quotes for sh.
export function shQuote(s) {
  return `'${s.replaceAll("'", "'\\''")}'`;
}

// appleScriptString(s): s as an AppleScript string literal.
export function appleScriptString(s) {
  return `"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
}

// terminalArgv(opts): the launcher argv for {verb, name} (spec 6.5), in this order: TERMINAL_CMD;
// Windows Terminal or a console window; macOS Terminal; x-terminal-emulator, then $TERMINAL.
// Throws when Linux has neither.
export function terminalArgv({ verb, name, platform, home, terminalCmd = '', pathEnv = '', terminalEnv = '', lstat }) {
  const cmd = wrapperArgv({ verb, name, platform, home });
  if (terminalCmd) return [...terminalCmd.split(' ').filter((w) => w !== ''), ...cmd];
  if (platform === 'win32') {
    if (onPath('wt.exe', { platform, pathEnv, lstat })) {
      const title = ['tmuxkeep', verb, ...(name ? [name] : [])].join(' ');
      return ['wt.exe', '-w', '0', 'new-tab', '--title', title, ...cmd];
    }
    return cmd;
  }
  if (platform === 'darwin') {
    // Orchestrator ruling Q24: the second -e brings Terminal in front of the browser.
    return ['osascript', '-e', `tell application "Terminal" to do script ${appleScriptString(cmd.map(shQuote).join(' '))}`,
      '-e', 'tell application "Terminal" to activate'];
  }
  if (onPath('x-terminal-emulator', { platform, pathEnv, lstat })) return ['x-terminal-emulator', '-e', ...cmd];
  if (terminalEnv) return [terminalEnv, '-e', ...cmd];
  throw new Error('no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config');
}

// spawnDetached(argv, spawnFn, extra): resolves null once the program started, else the reason.
export function spawnDetached(argv, spawnFn = spawn, extra = {}) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawnFn(argv[0], argv.slice(1), { detached: true, stdio: 'ignore', shell: false, windowsHide: false, ...extra });
    } catch (err) {
      resolve(err.code || err.message);
      return;
    }
    child.once('error', (err) => resolve(err.code || err.message));
    child.once('spawn', () => {
      child.unref();
      resolve(null);
    });
  });
}

// openTerminal(request, opts): {ok: true, argv} or {ok: false, error} (spec 6.5).
export async function openTerminal(request, { platform = process.platform, home, terminalCmd = '', env = process.env, spawnFn = spawn, lstat = fs.lstatSync } = {}) {
  const base = { verb: request.verb, name: request.name, platform, home };
  let argv;
  try {
    argv = terminalArgv({ ...base, terminalCmd, pathEnv: env.PATH || '', terminalEnv: env.TERMINAL || '', lstat });
  } catch (err) {
    return { ok: false, error: err.message };
  }
  if (env.TMUXKEEP_TERMINAL_DRYRUN === '1') return { ok: true, argv };
  const failed = await spawnDetached(argv, spawnFn);
  if (failed === null) return { ok: true, argv };
  // The Windows Terminal alias can be found and still fail to start; a console window always works.
  if (platform === 'win32' && argv[0] === 'wt.exe' && !terminalCmd) {
    const fallback = wrapperArgv(base);
    if (await spawnDetached(fallback, spawnFn) === null) return { ok: true, argv: fallback };
  }
  return { ok: false, error: `cannot start ${argv[0]}: ${failed}` };
}

// browserArgv(url, platform): the command that opens url in the default browser (spec 6.1).
export function browserArgv(url, platform) {
  if (platform === 'win32') return ['cmd.exe', '/c', 'start', '""', url];
  if (platform === 'darwin') return ['open', url];
  return ['xdg-open', url];
}

// openBrowser(url, opts): {argv, error}; error is null once the program started. cmd.exe gets its
// arguments verbatim, so the "" title argument reaches start as two quote characters.
export async function openBrowser(url, { platform = process.platform, env = process.env, spawnFn = spawn } = {}) {
  const argv = browserArgv(url, platform);
  if (env.TMUXKEEP_TERMINAL_DRYRUN === '1') return { argv, error: null };
  const error = await spawnDetached(argv, spawnFn, { windowsVerbatimArguments: platform === 'win32', windowsHide: true });
  return { argv, error };
}
```

- [ ] **Step 4: Run the tests**

Run: `node --test "dashboard/test/*.test.js"`
Expected: `fail 0`; the count is up by 12 from the task before it in your lane.

- [ ] **Step 5: Commit**

```bash
git add dashboard/lib/terminal.js dashboard/test/terminal.test.js
git commit -m "dashboard: terminal and browser launchers per platform, with a dry-run mode"
```

---

### Task 9: Dashboard: the page

Suggested model: sonnet.

**Files:**
- Create: `dashboard/public/index.html`, `dashboard/public/app.js`, `dashboard/public/style.css`, `dashboard/test/app.test.js`

**Interfaces:**
- Consumes (the HTTP contract of Task 10, spec 6.2; all URLs are relative, so they keep the `/<token>/` prefix): `GET api/state` answers `{snapshot, connected, updated, error}`; `POST api/action` with `{"words": [...]}` answers 200 `{code, stdout, stderr, needs_auth}`, 400 `{error}`, 409 `{error}`; `POST api/terminal` with `{"verb":"go","name":...}` or `{"verb":"auth"}` answers 200 `{ok: true, argv}`, 400 `{error}` or 500 `{ok: false, error}`. The snapshot shape is Task 1's.
- Produces: the three static files Task 10 serves, and these DOM-free exports of `public/app.js` (the page is one ES module; under Node, `typeof document === 'undefined'`, so importing it runs no DOM code): `POLL_MS = 1000`, `BANNER_AFTER_MS = 10000`, `PENDING_MS = 180000`, `MORE_LINES = '200'`, `HINT_255`, `clock(secs)`, `humanise(secs)`, `leaseLabel(snapshot, elapsedMs) -> {text, kind}`, `splitSessions(sessions) -> {live, tombstones}`, `lastLine(text)`, `errorText(result)`, `words.{send, rename, lock, unlock, resume, remove, removeNow, restore, more, log, endLease, create}`, `pendingStep(pending, state, now) -> 'none'|'wait'|'expired'|'resend'`, `logEntries(stdout) -> [{text, failed}]`.
- Behaviour (spec 7): polls `api/state` once a second; header with the broker version, a connection dot (green when connected; grey otherwise, the reason in a tooltip that is a child element shown on hover, never a `title` attribute, plan Q11; a banner after 10 seconds without a connection), the lease label (`LOCKED`, `lease m:ss`, `cooldown m:ss`, `no lease`, counted down from the snapshot by local elapsed time), **End lease** (`auth --end`) and **Authenticate** (auth terminal); the sessions table and a collapsed tombstone group; a detail panel with the live lines, **Attach**, **Lock/Unlock**, **Resume**, **More lines** (`peek -n 200`), **Restore** (tombstones), **Remove**, **Send** (Ctrl-Enter or the button), **Rename**, **Remove now** (the typed name becomes `--confirm`); the new-session form; the audit log panel (`log -n 100`, failures marked); the needs-auth flow (keep the action, open the auth terminal, say `type the code in the terminal that opened`, re-send once when a snapshot read after the refusal shows a lease; drop it on any other action or after 3 minutes); errors as `exit <code>: <last stderr line>`, 255 as the wrapper hint. Everything from the VPS goes in through `textContent` only.

- [ ] **Step 1: Write the failing test**

Create `dashboard/test/app.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  clock, errorText, HINT_255, humanise, lastLine, leaseLabel, logEntries, PENDING_MS, pendingStep, splitSessions, words,
} from '../public/app.js';

const APP = fs.readFileSync(new URL('../public/app.js', import.meta.url), 'utf8');
const PAGE = fs.readFileSync(new URL('../public/index.html', import.meta.url), 'utf8');

test('app.js never uses an API that parses markup or code (spec 7)', () => {
  for (const banned of ['innerHTML', 'insertAdjacentHTML', 'outerHTML', 'document.write', 'eval(', 'new Function']) {
    assert.ok(!APP.includes(banned), `app.js contains ${banned}`);
  }
});

test('app.js never writes an attribute or a URL (the rendering rule of spec 7)', () => {
  for (const banned of ['setAttribute', '.dataset', '.title =', '.href', '.src', 'srcdoc', 'javascript:', 'location', 'window.open']) {
    assert.ok(!APP.includes(banned), `app.js contains ${banned}`);
  }
});

test('index.html has no inline script, no inline style and no event handler attributes', () => {
  assert.equal((PAGE.match(/<script\b/g) || []).length, 1);
  assert.match(PAGE, /<script type="module" src="app\.js"><\/script>/);
  assert.ok(!/<style\b/i.test(PAGE));
  assert.ok(!/\sstyle=/i.test(PAGE));
  assert.ok(!/\son[a-z]+=/i.test(PAGE));
  assert.match(PAGE, /<link rel="stylesheet" href="style\.css">/);
  assert.ok(!/https?:\/\//.test(PAGE), 'no external request');
});

test('clock and humanise', () => {
  assert.equal(clock(0), '0:00');
  assert.equal(clock(59), '0:59');
  assert.equal(clock(1390), '23:10');
  assert.equal(clock(3600), '1:00:00');
  assert.equal(clock(-5), '0:00');
  assert.deepEqual([0, 59, 60, 3599, 3600, 86399, 86400, 200000, -1, 'x'].map(humanise),
    ['0s', '59s', '1m', '59m', '1h', '23h', '1d', '2d', '0s', '0s']);
});

test('the lease label: LOCKED, then a counting-down lease, then a cooldown, else no lease', () => {
  const snap = (lease, cool, locked) => ({ lease_secs_left: lease, otp: { locked, fails: 3, cooldown_secs_left: cool } });
  assert.deepEqual(leaseLabel(null, 0), { text: 'no data', kind: 'none' });
  assert.deepEqual(leaseLabel(snap(1390, 0, false), 0), { text: 'lease 23:10', kind: 'lease' });
  assert.deepEqual(leaseLabel(snap(1390, 0, false), 10500), { text: 'lease 23:00', kind: 'lease' });
  assert.deepEqual(leaseLabel(snap(5, 0, false), 6000), { text: 'no lease', kind: 'none' });
  assert.deepEqual(leaseLabel(snap(0, 299, false), 0), { text: 'cooldown 4:59', kind: 'cooldown' });
  assert.deepEqual(leaseLabel(snap(100, 299, false), 0), { text: 'lease 1:40', kind: 'lease' });
  assert.deepEqual(leaseLabel(snap(100, 299, true), 0), { text: 'LOCKED', kind: 'locked' });
  assert.deepEqual(leaseLabel({ sessions: [] }, 0), { text: 'no lease', kind: 'none' });
});

test('sessions split into live and tombstones, keeping tmux order', () => {
  const s = [{ name: 'api', state: 'live' }, { name: 'zz~old~1', state: 'tombstone' }, { name: 'web', state: 'locked' }];
  assert.deepEqual(splitSessions(s), { live: [s[0], s[2]], tombstones: [s[1]] });
  assert.deepEqual(splitSessions(undefined), { live: [], tombstones: [] });
});

test('errors show the exit code and the last stderr line verbatim; 255 shows the wrapper hint', () => {
  assert.equal(errorText({ code: 3, stderr: 'tmuxkeep: session api is locked\n' }), 'exit 3: tmuxkeep: session api is locked');
  assert.equal(errorText({ code: 1, stderr: 'warning\r\ntmuxkeep: tmux: no server\n\n' }), 'exit 1: tmuxkeep: tmux: no server');
  assert.equal(errorText({ code: 5, stderr: '' }), 'exit 5: (no message)');
  assert.equal(errorText({ code: 255, stderr: 'ssh: connect to host 203.0.113.10 port 22: Connection refused\n' }), `exit 255: ${HINT_255}`);
  assert.equal(HINT_255, "tmuxkeep: ssh to host 'tmuxkeep' failed (unreachable, key rejected, or remote killed by signal)");
  assert.equal(lastLine('a\nb\n'), 'b');
});

test('every button sends the words of its verb', () => {
  assert.deepEqual(words.send('api', 'run the tests'), ['send', 'api', 'run the tests']);
  assert.deepEqual(words.rename('api', 'web'), ['rename', 'api', 'web']);
  assert.deepEqual(words.lock('api'), ['lock', 'api']);
  assert.deepEqual(words.unlock('api'), ['unlock', 'api']);
  assert.deepEqual(words.resume('api'), ['resume', 'api']);
  assert.deepEqual(words.remove('api'), ['rm', 'api']);
  assert.deepEqual(words.removeNow('api', 'api'), ['rm', 'api', '--now', '--confirm', 'api']);
  assert.deepEqual(words.restore('old'), ['restore', 'old']);
  assert.deepEqual(words.more('api'), ['peek', 'api', '-n', '200']);
  assert.deepEqual(words.log(), ['log', '-n', '100']);
  assert.deepEqual(words.endLease(), ['auth', '--end']);
  assert.deepEqual(words.create('api', '', '', false), ['new', 'api']);
  assert.deepEqual(words.create('api', 'https://github.com/you/api.git', 'claude', false),
    ['new', 'api', '--repo', 'https://github.com/you/api.git', '--cmd', 'claude']);
  assert.deepEqual(words.create('api', '', 'claude', true), ['new', 'api', '--shell']);
});

test('a pending action waits for a snapshot read after it with a lease, then resends once; it expires after 3 minutes', () => {
  const since = 1000000;
  const pending = { words: ['new', 'api'], since };
  const state = (updated, lease) => ({ snapshot: { lease_secs_left: lease }, updated });
  assert.equal(pendingStep(null, state(since + 1, 100), since + 1), 'none');
  assert.equal(pendingStep(pending, state(since + 5000, 0), since + 5000), 'wait');
  assert.equal(pendingStep(pending, state(since - 1, 1800), since + 5000), 'wait');
  assert.equal(pendingStep(pending, { snapshot: null, updated: null }, since + 5000), 'wait');
  assert.equal(pendingStep(pending, state(since + 6000, 1800), since + 6100), 'resend');
  assert.equal(pendingStep(pending, state(since + 6000, 1800), since + PENDING_MS), 'expired');
});

test('audit lines become one entry each; failures are marked; other lines are kept as they are', () => {
  const out = [
    '{"ts":"2026-10-14T10:00:00Z","key":"laptop","ip":"203.0.113.9","verb":"new","session":"api","ok":true,"detail":"created dir=/home/claude/work/api"}',
    '{"ts":"2026-10-14T10:01:00Z","key":"laptop","ip":"203.0.113.9","verb":"auth","session":"","ok":false,"detail":"otp-fail"}',
    'not json <b>',
    '',
  ].join('\n');
  assert.deepEqual(logEntries(out), [
    { text: '2026-10-14T10:00:00Z  203.0.113.9  laptop  new  api  ok  created dir=/home/claude/work/api', failed: false },
    { text: '2026-10-14T10:01:00Z  203.0.113.9  laptop  auth  FAILED  otp-fail', failed: true },
    { text: 'not json <b>', failed: false },
  ]);
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `node --test "dashboard/test/app.test.js"`
Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `../public/app.js`.

- [ ] **Step 3: The page skeleton**

Create `dashboard/public/index.html`:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>tmuxkeep</title>
<link rel="stylesheet" href="style.css">
<script type="module" src="app.js"></script>
</head>
<body>
<header>
  <span class="brand">tmuxkeep</span>
  <span id="version" class="muted"></span>
  <span id="dot" class="dot off"><span id="dot-tip" class="tip"></span></span>
  <span id="lease" class="lease">no data</span>
  <span class="spacer"></span>
  <button id="end-lease" type="button">End lease</button>
  <button id="authenticate" type="button">Authenticate</button>
</header>
<div id="banner" class="banner" hidden></div>
<div id="notice" class="notice" hidden></div>
<main>
  <section id="list">
    <table id="sessions">
      <thead>
        <tr><th>Name</th><th>State</th><th>Attached</th><th>Age</th><th>Idle</th><th>Title</th></tr>
      </thead>
      <tbody id="session-rows"></tbody>
    </table>
    <p id="empty" class="muted" hidden>No sessions.</p>
    <details id="tombstones">
      <summary>Tombstones (<span id="tomb-count">0</span>)</summary>
      <table><tbody id="tomb-rows"></tbody></table>
    </details>
    <form id="new-form">
      <h2>New session</h2>
      <label>Name <input id="new-name" autocomplete="off" spellcheck="false"></label>
      <label>Repository URL (optional, https only) <input id="new-repo" autocomplete="off" spellcheck="false"></label>
      <label>Command (optional) <input id="new-cmd" autocomplete="off" spellcheck="false"></label>
      <label class="check"><input id="new-shell" type="checkbox"> Shell only</label>
      <button type="submit">Create</button>
    </form>
  </section>
  <section id="detail" hidden>
    <h2 id="detail-name"></h2>
    <pre id="detail-lines"></pre>
    <div class="buttons">
      <button id="attach" type="button">Attach</button>
      <button id="lock" type="button">Lock</button>
      <button id="resume" type="button">Resume</button>
      <button id="more" type="button">More lines</button>
      <button id="restore" type="button">Restore</button>
      <button id="remove" type="button">Remove</button>
    </div>
    <pre id="more-lines" hidden></pre>
    <div id="send-row">
      <label for="send-text">Send (Ctrl-Enter sends)</label>
      <textarea id="send-text" rows="3" spellcheck="false"></textarea>
      <button id="send" type="button">Send</button>
    </div>
    <div id="rename-row" class="row">
      <input id="rename-to" autocomplete="off" spellcheck="false" placeholder="new name">
      <button id="rename" type="button">Rename</button>
    </div>
    <div class="row">
      <input id="confirm-name" autocomplete="off" spellcheck="false" placeholder="type the session name">
      <button id="remove-now" type="button">Remove now</button>
    </div>
  </section>
</main>
<section id="log">
  <button id="log-button" type="button">Show the last 100 audit lines</button>
  <ol id="log-lines"></ol>
</section>
</body>
</html>
```

- [ ] **Step 4: The script**

Create `dashboard/public/app.js`:

```js
// app.js - the dashboard page (spec 7). One ES module. The helpers at the top touch no DOM and are
// exported for dashboard/test/app.test.js, which imports this file under Node; the code at the
// bottom runs only in a browser. Text that comes from the VPS (names, titles, pane lines, log lines,
// stderr) only ever reaches the page through textContent or createTextNode: never as markup, never
// in an attribute, never in a URL. dashboard/test/app.test.js greps this file to keep it that way.

export const POLL_MS = 1000;
export const BANNER_AFTER_MS = 10000;
export const PENDING_MS = 180000;
export const MORE_LINES = '200';
export const HINT_255 = "tmuxkeep: ssh to host 'tmuxkeep' failed (unreachable, key rejected, or remote killed by signal)";

// clock(secs): m:ss, or h:mm:ss from one hour on.
export function clock(secs) {
  const s = Math.max(0, Math.floor(secs));
  const two = (n) => String(n).padStart(2, '0');
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h}:${two(m)}:${two(s % 60)}` : `${m}:${two(s % 60)}`;
}

// humanise(secs): 59s, 59m, 23h, then days; the broker's ls column.
export function humanise(secs) {
  const s = Math.max(0, Math.floor(Number(secs) || 0));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

// leaseLabel(snapshot, elapsedMs): the header text and its kind. elapsedMs is the time since the
// snapshot was read on this laptop, so the countdown never depends on the VPS clock. LOCKED wins,
// then a running lease (the gate lets a lease through a cooldown), then a cooldown.
export function leaseLabel(snapshot, elapsedMs) {
  if (!snapshot) return { text: 'no data', kind: 'none' };
  const gone = Math.floor(Math.max(0, elapsedMs) / 1000);
  const otp = snapshot.otp || {};
  if (otp.locked) return { text: 'LOCKED', kind: 'locked' };
  const lease = (Number(snapshot.lease_secs_left) || 0) - gone;
  if (lease > 0) return { text: `lease ${clock(lease)}`, kind: 'lease' };
  const cool = (Number(otp.cooldown_secs_left) || 0) - gone;
  if (cool > 0) return { text: `cooldown ${clock(cool)}`, kind: 'cooldown' };
  return { text: 'no lease', kind: 'none' };
}

// splitSessions(sessions): live and locked sessions first, tombstones apart, each in tmux order.
export function splitSessions(sessions) {
  const live = [];
  const tombstones = [];
  for (const s of Array.isArray(sessions) ? sessions : []) (s.state === 'tombstone' ? tombstones : live).push(s);
  return { live, tombstones };
}

// lastLine(text): the last non-empty line of text, or ''.
export function lastLine(text) {
  const lines = String(text || '').split('\n').map((l) => l.replace(/\r$/, '')).filter((l) => l.trim() !== '');
  return lines.length > 0 ? lines[lines.length - 1] : '';
}

// errorText(result): the banner for a non-zero action: the exit code and the broker's stderr line,
// or for 255 the wrapper's hint.
export function errorText(result) {
  if (result.code === 255) return `exit 255: ${HINT_255}`;
  return `exit ${result.code}: ${lastLine(result.stderr) || '(no message)'}`;
}

// The words each button sends (spec 7). Validation happens on the server.
export const words = {
  send: (name, text) => ['send', name, text],
  rename: (name, to) => ['rename', name, to],
  lock: (name) => ['lock', name],
  unlock: (name) => ['unlock', name],
  resume: (name) => ['resume', name],
  remove: (name) => ['rm', name],
  removeNow: (name, typed) => ['rm', name, '--now', '--confirm', typed],
  restore: (base) => ['restore', base],
  more: (name) => ['peek', name, '-n', MORE_LINES],
  log: () => ['log', '-n', '100'],
  endLease: () => ['auth', '--end'],
  create(name, repo, cmd, shellOnly) {
    const w = ['new', name];
    if (repo) w.push('--repo', repo);
    if (shellOnly) w.push('--shell');
    else if (cmd) w.push('--cmd', cmd);
    return w;
  },
};

// pendingStep(pending, state, now): what to do with an action that needed a code (spec 7):
// 'none', 'wait', 'expired' after PENDING_MS, or 'resend' once a snapshot read after the refusal
// shows a lease.
export function pendingStep(pending, state, now) {
  if (!pending) return 'none';
  if (now - pending.since >= PENDING_MS) return 'expired';
  const snap = state && state.snapshot;
  if (snap && typeof state.updated === 'number' && state.updated > pending.since && Number(snap.lease_secs_left) > 0) return 'resend';
  return 'wait';
}

// logEntries(stdout): one entry per audit line, {text, failed}; a line that is not JSON is kept as it is.
export function logEntries(stdout) {
  return String(stdout || '').split('\n').filter((l) => l.trim() !== '').map((line) => {
    let e;
    try {
      e = JSON.parse(line);
    } catch {
      return { text: line, failed: false };
    }
    if (e === null || typeof e !== 'object') return { text: line, failed: false };
    const parts = [e.ts, e.ip, e.key, e.verb, e.session, e.ok === false ? 'FAILED' : 'ok', e.detail];
    return { text: parts.filter((p) => p !== undefined && p !== null && p !== '').map(String).join('  '), failed: e.ok === false };
  });
}

// ---- browser only from here on ----

function start() {
  const $ = (id) => document.getElementById(id);
  const ui = { state: null, stateAt: 0, selected: null, pending: null, offlineSince: null, serverDown: false };

  function show(el, on) {
    el.hidden = !on;
  }

  function notice(text, isError) {
    const el = $('notice');
    el.textContent = text;
    el.className = isError ? 'notice error' : 'notice';
    show(el, text !== '');
  }

  async function call(path, body) {
    const init = body === undefined
      ? { cache: 'no-store' }
      : { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
    const res = await fetch(path, init);
    let data = null;
    try {
      data = await res.json();
    } catch {
      data = null;
    }
    return { status: res.status, data };
  }

  async function openTerminal(body) {
    try {
      const r = await call('api/terminal', body);
      if (r.status === 200) return true;
      notice((r.data && r.data.error) || `could not open a terminal (${r.status})`, true);
    } catch {
      notice('the local server did not answer', true);
    }
    return false;
  }

  // act(w, resend): runs one verb. Any action drops a pending one, except the resend itself.
  async function act(w, resend = false) {
    if (!resend) ui.pending = null;
    notice(`${w[0]}...`, false);
    let r;
    try {
      r = await call('api/action', { words: w });
    } catch {
      notice('the local server did not answer', true);
      return null;
    }
    if (r.status === 409) {
      notice('another action is still running; try again in a moment', true);
      return null;
    }
    if (r.status !== 200 || !r.data) {
      notice((r.data && r.data.error) || `refused (${r.status})`, true);
      return null;
    }
    const res = r.data;
    if (res.needs_auth && !resend) {
      ui.pending = { words: w, since: Date.now() };
      if (await openTerminal({ verb: 'auth' })) notice('type the code in the terminal that opened', false);
      return res;
    }
    if (res.code !== 0) notice(errorText(res), true);
    else notice(lastLine(res.stdout) || 'done', false);
    return res;
  }

  function cell(tr, text) {
    const td = document.createElement('td');
    td.textContent = text;
    tr.appendChild(td);
  }

  function row(s) {
    const tr = document.createElement('tr');
    if (s.name === ui.selected) tr.className = 'selected';
    cell(tr, s.name);
    cell(tr, s.state);
    cell(tr, s.attached ? '*' : '');
    cell(tr, humanise(s.age_secs));
    cell(tr, humanise(s.idle_secs));
    cell(tr, s.title);
    tr.addEventListener('click', () => select(s.name));
    return tr;
  }

  function current() {
    const snap = ui.state && ui.state.snapshot;
    const list = snap && Array.isArray(snap.sessions) ? snap.sessions : [];
    return list.find((s) => s.name === ui.selected) || null;
  }

  function select(name) {
    if (ui.selected !== name) {
      $('more-lines').textContent = '';
      show($('more-lines'), false);
      $('confirm-name').value = '';
      $('rename-to').value = '';
    }
    ui.selected = name;
    render();
  }

  function renderHeader() {
    const st = ui.state;
    const snap = st && st.snapshot;
    $('version').textContent = snap ? String(snap.version) : '';
    const connected = !ui.serverDown && st && st.connected;
    $('dot').className = connected ? 'dot on' : 'dot off';
    const why = ui.serverDown ? 'the local server is not running (tmuxkeep ui was stopped)' : (st && st.error) || 'connecting';
    $('dot-tip').textContent = connected ? 'connected' : why;
    if (connected) ui.offlineSince = null;
    else if (ui.offlineSince === null) ui.offlineSince = Date.now();
    const banner = $('banner');
    const late = !connected && ui.offlineSince !== null && Date.now() - ui.offlineSince >= BANNER_AFTER_MS;
    banner.textContent = late ? `not connected to the VPS: ${why}` : '';
    show(banner, late);
    const label = leaseLabel(snap, st && typeof st.updated === 'number' ? Date.now() - st.updated : 0);
    $('lease').textContent = label.text;
    $('lease').className = `lease k-${label.kind}`;
  }

  function renderSessions() {
    const snap = ui.state && ui.state.snapshot;
    const { live, tombstones } = splitSessions(snap && snap.sessions);
    $('session-rows').replaceChildren(...live.map(row));
    show($('empty'), snap !== null && snap !== undefined && live.length === 0);
    $('tomb-rows').replaceChildren(...tombstones.map(row));
    $('tomb-count').textContent = String(tombstones.length);
  }

  function renderDetail() {
    const s = current();
    show($('detail'), s !== null);
    if (!s) return;
    const tomb = s.state === 'tombstone';
    $('detail-name').textContent = s.name;
    $('detail-lines').textContent = Array.isArray(s.lines) ? s.lines.join('\n') : '';
    $('lock').textContent = s.state === 'locked' ? 'Unlock' : 'Lock';
    for (const id of ['attach', 'lock', 'resume', 'remove', 'send-row', 'rename-row']) show($(id), !tomb);
    show($('restore'), tomb);
  }

  function render() {
    renderHeader();
    renderSessions();
    renderDetail();
  }

  function checkPending() {
    const step = pendingStep(ui.pending, ui.state, Date.now());
    if (step === 'expired') {
      ui.pending = null;
      notice('the action that needed a code was dropped after 3 minutes', true);
    } else if (step === 'resend') {
      const w = ui.pending.words;
      ui.pending = null;
      act(w, true);
    }
  }

  async function poll() {
    try {
      const r = await call('api/state');
      ui.serverDown = r.status !== 200 || !r.data;
      if (!ui.serverDown) {
        ui.state = r.data;
        ui.stateAt = Date.now();
      }
    } catch {
      ui.serverDown = true;
    }
    render();
    checkPending();
  }

  async function sendText() {
    const s = current();
    const text = $('send-text').value;
    if (!s || text === '') return;
    const res = await act(words.send(s.name, text));
    if (res && res.code === 0) $('send-text').value = '';
  }

  $('end-lease').addEventListener('click', () => act(words.endLease()));
  $('authenticate').addEventListener('click', () => openTerminal({ verb: 'auth' }));
  $('attach').addEventListener('click', () => {
    const s = current();
    ui.pending = null;
    if (s) openTerminal({ verb: 'go', name: s.name });
  });
  $('lock').addEventListener('click', () => {
    const s = current();
    if (s) act(s.state === 'locked' ? words.unlock(s.name) : words.lock(s.name));
  });
  $('resume').addEventListener('click', () => {
    const s = current();
    if (s) act(words.resume(s.name));
  });
  $('remove').addEventListener('click', () => {
    const s = current();
    if (s) act(words.remove(s.name));
  });
  $('restore').addEventListener('click', () => {
    const s = current();
    if (s && s.tombstone_of) act(words.restore(s.tombstone_of));
  });
  $('more').addEventListener('click', async () => {
    const s = current();
    if (!s) return;
    const res = await act(words.more(s.name));
    if (res && res.code === 0) {
      $('more-lines').textContent = res.stdout;
      show($('more-lines'), true);
    }
  });
  $('send').addEventListener('click', sendText);
  $('send-text').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      sendText();
    }
  });
  $('rename').addEventListener('click', async () => {
    const s = current();
    const to = $('rename-to').value.trim();
    if (!s || to === '') return;
    const res = await act(words.rename(s.name, to));
    if (res && res.code === 0) {
      $('rename-to').value = '';
      ui.selected = to;
    }
  });
  $('remove-now').addEventListener('click', async () => {
    const s = current();
    const typed = $('confirm-name').value.trim();
    if (!s) return;
    if (typed === '') {
      notice('type the session name first, exactly as shown', true);
      return;
    }
    const res = await act(words.removeNow(s.name, typed));
    if (res && res.code === 0) $('confirm-name').value = '';
  });
  $('new-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const name = $('new-name').value.trim();
    if (name === '') return;
    const w = words.create(name, $('new-repo').value.trim(), $('new-cmd').value.trim(), $('new-shell').checked);
    const res = await act(w);
    if (res && res.code === 0) {
      for (const id of ['new-name', 'new-repo', 'new-cmd']) $(id).value = '';
      $('new-shell').checked = false;
      ui.selected = name;
    }
  });
  $('log-button').addEventListener('click', async () => {
    const res = await act(words.log());
    if (!res || res.code !== 0) return;
    const items = logEntries(res.stdout).map((entry) => {
      const li = document.createElement('li');
      li.textContent = entry.text;
      if (entry.failed) li.className = 'fail';
      return li;
    });
    $('log-lines').replaceChildren(...items);
  });

  setInterval(poll, POLL_MS);
  poll();
}

if (typeof document !== 'undefined') start();
```

- [ ] **Step 5: The stylesheet**

Create `dashboard/public/style.css`:

```css
/* style.css - the dashboard page: system fonts, no icons, no external requests, light and dark. */
:root {
  color-scheme: light dark;
  --bg: #ffffff;
  --fg: #1d1f21;
  --muted: #6a6f75;
  --line: #d8dbde;
  --panel: #f5f6f7;
  --accent: #1f6feb;
  --ok: #1a7f37;
  --warn: #9a6700;
  --bad: #c62828;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16181b;
    --fg: #e6e8ea;
    --muted: #9aa0a6;
    --line: #33373c;
    --panel: #1f2226;
    --accent: #58a6ff;
    --ok: #3fb950;
    --warn: #d29922;
    --bad: #f85149;
  }
}

* { box-sizing: border-box; }
[hidden] { display: none !important; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--fg);
  font: 14px/1.4 system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
}

header {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 16px;
  border-bottom: 1px solid var(--line);
}

.brand { font-weight: 600; }
.muted { color: var(--muted); }
.spacer { flex: 1; }

.dot {
  position: relative;
  display: inline-block;
  width: 10px;
  height: 10px;
  border-radius: 50%;
}
.dot.on { background: var(--ok); }
.dot.off { background: var(--muted); }
.dot .tip {
  display: none;
  position: absolute;
  top: 16px;
  left: 0;
  z-index: 1;
  width: max-content;
  max-width: 480px;
  padding: 6px 8px;
  border: 1px solid var(--line);
  background: var(--panel);
  color: var(--fg);
  white-space: pre-wrap;
}
.dot:hover .tip { display: block; }

.lease { font-variant-numeric: tabular-nums; }
.k-lease { color: var(--ok); }
.k-cooldown { color: var(--warn); }
.k-locked { color: var(--bad); font-weight: 600; }

.banner, .notice {
  margin: 8px 16px 0;
  padding: 8px 10px;
  border: 1px solid var(--line);
  background: var(--panel);
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
.banner, .notice.error { border-color: var(--bad); }

main {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
  gap: 16px;
  padding: 16px;
}

table { width: 100%; border-collapse: collapse; }
th, td {
  padding: 4px 6px;
  border-bottom: 1px solid var(--line);
  text-align: left;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 260px;
}
tbody tr { cursor: pointer; }
tbody tr:hover { background: var(--panel); }
tr.selected { outline: 2px solid var(--accent); outline-offset: -2px; }

details { margin-top: 12px; }

h2 { font-size: 15px; margin: 16px 0 8px; }

pre {
  margin: 0 0 8px;
  padding: 8px;
  max-height: 360px;
  overflow: auto;
  background: var(--panel);
  border: 1px solid var(--line);
  font: 12px/1.35 ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
  white-space: pre;
}

form label, #send-row label { display: block; margin: 6px 0; }
label.check { display: flex; align-items: center; gap: 6px; }
input, textarea, button { font: inherit; color: inherit; }
input, textarea {
  width: 100%;
  padding: 4px 6px;
  background: var(--bg);
  border: 1px solid var(--line);
}
input[type="checkbox"] { width: auto; }
textarea { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
button {
  padding: 4px 10px;
  background: var(--panel);
  border: 1px solid var(--line);
  cursor: pointer;
}
button:hover { border-color: var(--accent); }

.buttons { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 8px; }
.row { display: flex; gap: 6px; margin-top: 8px; }

#log { padding: 0 16px 16px; }
#log ol { padding-left: 24px; font: 12px/1.35 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
#log li { white-space: pre-wrap; overflow-wrap: anywhere; }
#log li.fail { color: var(--bad); }

@media (max-width: 899px) {
  main { grid-template-columns: minmax(0, 1fr); }
}
```

`[hidden] { display: none !important; }` is required: `.row` sets `display: flex`, which would otherwise override the `hidden` attribute the script toggles. The layout is two columns from 900 px up and one column below.

- [ ] **Step 6: Run the tests**

Run: `node --test "dashboard/test/*.test.js"`
Expected: `fail 0`; the count is up by 10 from the task before it in your lane.

- [ ] **Step 7: Commit**

```bash
git add dashboard/public dashboard/test/app.test.js
git commit -m "dashboard: the page (text-only rendering, needs-auth flow, light and dark)"
```

---

### Task 10: Dashboard: `http.js` and `server.js`

Suggested model: sonnet (ask Opus to review the diff: this is the trust boundary of D17).

**Files:**
- Create: `dashboard/lib/http.js`, `dashboard/server.js`, `dashboard/test/http.test.js`, `dashboard/test/server.test.js`

**Interfaces:**
- Consumes: `checkAction`, `checkTerminal` (Task 5); `configPath`, `parseArgs`, `readConfig` (Task 5); `runVerb`, `spawnSsh` (Task 6); `createFollower`, `FOLLOW_WORDS` (Task 7); `openTerminal`, `openBrowser` (Task 8); `public/index.html`, `public/app.js`, `public/style.css` (Task 9); `test/helpers.js` (Task 6).
- Produces (`dashboard/lib/http.js`): `MAX_BODY_BYTES = 70000`; `SERVER_OPTIONS = {requireHostHeader: false}` (without it Node answers a request that has no `Host` header with its own 400, before the handler, and the spec wants 404; found while planning); `CSP` (the spec 6.2 policy, sent on every response, plan Q11); `createHandler({token, port, files, getState, runAction, openTerminal}) -> (req, res) => void`. Order of checks for every request: `Host` (`127.0.0.1:<port>` or `localhost:<port>`, case-insensitive), then `/<token>/` (compared with `crypto.timingSafeEqual`) followed by a listed method and path (query strings ignored); either failure is 404 with an empty body. A POST then needs `Content-Type: application/json` (parameters allowed), an `Origin` that is absent or one of the two allowed origins, a `Sec-Fetch-Site` that is absent, `same-origin` or `none`, and a body of at most 70,000 bytes that parses as JSON; any failure is 403 with an empty body. Then: `POST /api/action` validates `body.words` (400 `{error}`), refuses a second action while one runs (409 `{error: 'another action is still running'}`), and answers 200 with `runAction`'s result; `POST /api/terminal` validates (400) and answers `openTerminal`'s result with 200, or 500 when `ok` is false. Every response carries `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and the CSP; no response carries any `Access-Control-*` header.
- Produces (`dashboard/server.js`, the entry point; spec 6.1): checks Node >= 20 (`TMUXKEEP_NODE_VERSION` stands in for tests, plan Q8) else `tmuxkeep ui: Node 20 or newer is required (found v<x>)` exit 2; parses `[--port N] [--no-open]` (usage or `--port` error, exit 2); reads `~/.tmuxkeep/config` (`tmuxkeep ui: config <path>: <reason>`, exit 2); `--port` wins over `DASHBOARD_PORT`; token from `crypto.randomBytes(16)`; listens on `127.0.0.1` only; a busy port is `tmuxkeep ui: port <p> is in use; set DASHBOARD_PORT or pass --port`, exit 1; prints `tmuxkeep ui: http://127.0.0.1:<port>/<token>/  (Ctrl-C stops)` on stdout; opens the browser unless `--no-open` (a failure is a warning on stderr; in dry run it prints `tmuxkeep ui: dry run: <argv as JSON>`); starts the follow child on the first `/api/state`; SIGINT and SIGTERM stop the follower, close the server and exit 0. It writes nothing to disk.

- [ ] **Step 1: Write the failing handler test**

Create `dashboard/test/http.test.js`:

```js
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createHandler, CSP, MAX_BODY_BYTES, SERVER_OPTIONS } from '../lib/http.js';

const TOKEN = '0123456789abcdef0123456789abcdef';
const FILES = {
  'index.html': Buffer.from('<!doctype html><title>t</title>\n'),
  'app.js': Buffer.from('export const x = 1;\n'),
  'style.css': Buffer.from('body { margin: 0; }\n'),
};

let server;
let port;
let host;
const seen = { state: 0, actions: [], terminals: [] };
let actionImpl;
let terminalImpl;
let stateValue;

before(async () => {
  let handler = null;
  server = http.createServer(SERVER_OPTIONS, (req, res) => handler(req, res));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  port = server.address().port;
  host = `127.0.0.1:${port}`;
  handler = createHandler({
    token: TOKEN,
    port,
    files: FILES,
    getState: () => {
      seen.state += 1;
      return stateValue;
    },
    runAction: (words) => {
      seen.actions.push(words);
      return actionImpl(words);
    },
    openTerminal: (body) => {
      seen.terminals.push(body);
      return terminalImpl(body);
    },
  });
});

after(() => new Promise((resolve) => server.close(resolve)));

beforeEach(() => {
  seen.state = 0;
  seen.actions = [];
  seen.terminals = [];
  stateValue = { snapshot: null, connected: false, updated: null, error: null };
  actionImpl = async () => ({ code: 0, stdout: 'ok\n', stderr: '', needs_auth: false });
  terminalImpl = async () => ({ ok: true, argv: ['x'] });
});

// request(opts): one HTTP request with exactly the given headers; resolves {status, headers, body}.
function request({ method = 'GET', path = `/${TOKEN}/`, headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const all = { host, ...headers };
    for (const k of Object.keys(all)) if (all[k] === null) delete all[k];
    const req = http.request({ host: '127.0.0.1', port, method, path, headers: all, agent: false, setHost: false }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

const JSON_HEADERS = { 'content-type': 'application/json' };
const post = (route, value, headers = {}) => request({
  method: 'POST', path: `/${TOKEN}${route}`, headers: { ...JSON_HEADERS, ...headers }, body: typeof value === 'string' ? value : JSON.stringify(value),
});

function assertSecurityHeaders(r) {
  assert.equal(r.headers['cache-control'], 'no-store');
  assert.equal(r.headers['x-content-type-options'], 'nosniff');
  assert.equal(r.headers['referrer-policy'], 'no-referrer');
  assert.equal(r.headers['content-security-policy'], CSP);
  for (const h of Object.keys(r.headers)) assert.ok(!h.startsWith('access-control-'), h);
}

function assertEmpty(r, status) {
  assert.equal(r.status, status);
  assert.equal(r.body, '');
  assertSecurityHeaders(r);
}

test('the CSP is the spec 6.2 policy', () => {
  assert.equal(CSP, "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
});

test('a wrong or missing Host is 404 with an empty body for every method, before anything runs', async () => {
  for (const h of ['evil.example', `evil.example:${port}`, `127.0.0.1:${port + 1}`, `[::1]:${port}`, '127.0.0.1', null]) {
    assertEmpty(await request({ headers: { host: h } }), 404);
    assertEmpty(await request({ path: `/${TOKEN}/api/state`, headers: { host: h } }), 404);
    assertEmpty(await post('/api/action', { words: ['log'] }, { host: h }), 404);
    assertEmpty(await post('/api/terminal', { verb: 'auth' }, { host: h }), 404);
  }
  assert.deepEqual(seen, { state: 0, actions: [], terminals: [] });
});

test('localhost:<port> and 127.0.0.1:<port> are both accepted', async () => {
  assert.equal((await request({ headers: { host: `localhost:${port}` } })).status, 200);
  assert.equal((await request({ headers: { host: `LOCALHOST:${port}` } })).status, 200);
  assert.equal((await request()).status, 200);
});

test('a wrong or missing token, or an unlisted route or method, is 404 with an empty body', async () => {
  const other = 'f'.repeat(32);
  for (const path of ['/', '/app.js', '/api/state', `/${other}/`, `/${other}/api/state`, `/${TOKEN}`, `/${TOKEN.toUpperCase()}/`,
    `/${TOKEN}/index.html`, `/${TOKEN}/api/`, `/${TOKEN}/../${TOKEN}/`, `/${TOKEN}//app.js`, `/${TOKEN}/app.js/`, `/x/${TOKEN}/`]) {
    assertEmpty(await request({ path }), 404);
  }
  for (const [method, path] of [['POST', '/'], ['POST', '/api/state'], ['GET', '/api/action'], ['GET', '/api/terminal'],
    ['PUT', '/api/action'], ['DELETE', '/'], ['HEAD', '/'], ['OPTIONS', '/api/action']]) {
    assertEmpty(await request({ method, path: `/${TOKEN}${path}`, headers: JSON_HEADERS }), 404);
  }
  assertEmpty(await post('/api/frob', { words: ['log'] }), 404);
  assert.deepEqual(seen, { state: 0, actions: [], terminals: [] });
});

test('the page, the script and the stylesheet are served with their types and the security headers', async () => {
  for (const [path, name, type] of [['/', 'index.html', 'text/html; charset=utf-8'], ['/app.js', 'app.js', 'text/javascript; charset=utf-8'],
    ['/style.css', 'style.css', 'text/css; charset=utf-8']]) {
    const r = await request({ path: `/${TOKEN}${path}?v=1` });
    assert.equal(r.status, 200);
    assert.equal(r.headers['content-type'], type);
    assert.equal(r.body, FILES[name].toString());
    assertSecurityHeaders(r);
  }
});

test('/api/state returns what getState gives, as JSON, before and after a snapshot', async () => {
  let r = await request({ path: `/${TOKEN}/api/state` });
  assert.equal(r.status, 200);
  assert.equal(r.headers['content-type'], 'application/json; charset=utf-8');
  assert.deepEqual(JSON.parse(r.body), { snapshot: null, connected: false, updated: null, error: null });
  stateValue = { snapshot: { version: 'dev', sessions: [] }, connected: true, updated: 1790000000000, error: null };
  r = await request({ path: `/${TOKEN}/api/state` });
  assert.deepEqual(JSON.parse(r.body), stateValue);
  assertSecurityHeaders(r);
  assert.equal(seen.state, 2);
});

test('a POST that is not JSON from this origin is 403 with an empty body, and nothing runs', async () => {
  const words = { words: ['log'] };
  for (const headers of [
    { 'content-type': 'text/plain' },
    { 'content-type': null },
    { 'content-type': 'application/x-www-form-urlencoded' },
    { 'content-type': 'multipart/form-data; boundary=x' },
    { origin: 'http://evil.example' },
    { origin: 'null' },
    { origin: `http://127.0.0.1:${port + 1}` },
    { origin: `https://127.0.0.1:${port}` },
    { 'sec-fetch-site': 'cross-site' },
    { 'sec-fetch-site': 'same-site' },
  ]) {
    assertEmpty(await post('/api/action', words, headers), 403);
    assertEmpty(await post('/api/terminal', { verb: 'auth' }, headers), 403);
  }
  assertEmpty(await post('/api/action', '{"words": ["log"]'), 403);
  assertEmpty(await post('/api/action', ''), 403);
  assertEmpty(await post('/api/action', `{"words":["log"]}${' '.repeat(MAX_BODY_BYTES)}`), 403);
  assert.deepEqual(seen, { state: 0, actions: [], terminals: [] });
});

test('the allowed origins, fetch metadata and a body of exactly 70000 bytes pass', async () => {
  for (const headers of [{ origin: `http://127.0.0.1:${port}` }, { origin: `http://localhost:${port}` },
    { 'sec-fetch-site': 'same-origin' }, { 'sec-fetch-site': 'none' }, { 'content-type': 'application/json; charset=utf-8' }]) {
    assert.equal((await post('/api/action', { words: ['log'] }, headers)).status, 200, JSON.stringify(headers));
  }
  const exact = '{"words":["log"]}';
  assert.equal((await post('/api/action', exact + ' '.repeat(MAX_BODY_BYTES - exact.length))).status, 200);
});

test('an action runs the words and returns code, stdout, stderr and needs_auth', async () => {
  actionImpl = async () => ({ code: 4, stdout: '', stderr: "tmuxkeep: TOTP required: run with a terminal or run 'tmuxkeep auth' first\n", needs_auth: true });
  const r = await post('/api/action', { words: ['send', 'api', 'run the tests'] });
  assert.equal(r.status, 200);
  assert.deepEqual(JSON.parse(r.body), { code: 4, stdout: '', stderr: "tmuxkeep: TOTP required: run with a terminal or run 'tmuxkeep auth' first\n", needs_auth: true });
  assert.deepEqual(seen.actions, [['send', 'api', 'run the tests']]);
});

test('go, ui, a bare auth, unknown verbs and bad words are 400 with the reason, and nothing runs', async () => {
  for (const [body, error] of [
    [{ words: ['go', 'api'] }, 'not allowed from the dashboard: go'],
    [{ words: ['ui'] }, 'not allowed from the dashboard: ui'],
    [{ words: ['auth'] }, 'only auth --end is allowed from the dashboard'],
    [{ words: ['frob'] }, 'not allowed from the dashboard: frob'],
    [{ words: 'log' }, 'words must be a non-empty array of strings'],
    [{}, 'words must be a non-empty array of strings'],
    [['log'], 'words must be a non-empty array of strings'],
    [null, 'words must be a non-empty array of strings'],
    [{ words: ['send', 'api', 'two\nlines'] }, 'text contains control characters (line breaks and tabs cannot be sent; send one line at a time)'],
  ]) {
    const r = await post('/api/action', body);
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.deepEqual(JSON.parse(r.body), { error });
  }
  assert.equal((await post('/api/action', { words: ['auth', '--end'] })).status, 200);
  assert.deepEqual(seen.actions, [['auth', '--end']]);
});

test('a second action while one runs is 409; the next one after it ends runs', async () => {
  let release;
  actionImpl = () => new Promise((resolve) => {
    release = () => resolve({ code: 0, stdout: '', stderr: '', needs_auth: false });
  });
  const first = post('/api/action', { words: ['log'] });
  while (seen.actions.length === 0) await new Promise((resolve) => setTimeout(resolve, 5));
  const second = await post('/api/action', { words: ['status'] });
  assert.equal(second.status, 409);
  assert.deepEqual(JSON.parse(second.body), { error: 'another action is still running' });
  release();
  assert.equal((await first).status, 200);
  actionImpl = async () => ({ code: 0, stdout: '', stderr: '', needs_auth: false });
  assert.equal((await post('/api/action', { words: ['status'] })).status, 200);
  assert.deepEqual(seen.actions, [['log'], ['status']]);
});

test('a terminal request opens go or auth; a failure is 500 with the error; a bad body is 400', async () => {
  terminalImpl = async (b) => ({ ok: true, argv: ['kitty', '-e', b.verb] });
  let r = await post('/api/terminal', { verb: 'go', name: 'api' });
  assert.equal(r.status, 200);
  assert.deepEqual(JSON.parse(r.body), { ok: true, argv: ['kitty', '-e', 'go'] });
  terminalImpl = async () => ({ ok: false, error: 'no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config' });
  r = await post('/api/terminal', { verb: 'auth' });
  assert.equal(r.status, 500);
  assert.deepEqual(JSON.parse(r.body), { ok: false, error: 'no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config' });
  r = await post('/api/terminal', { verb: 'go', name: 'Bad Name' });
  assert.equal(r.status, 400);
  assert.deepEqual(JSON.parse(r.body), { error: 'invalid session name' });
  assert.deepEqual(seen.terminals, [{ verb: 'go', name: 'api' }, { verb: 'auth' }]);
});
```

- [ ] **Step 2: Run it to see it fail**

Run: `node --test "dashboard/test/http.test.js"`
Expected: FAIL with `ERR_MODULE_NOT_FOUND` for `../lib/http.js`.

- [ ] **Step 3: Implement the handler**

Create `dashboard/lib/http.js`:

```js
// http.js - the request handler of tmuxkeep ui (spec 6.2, D17). Every request is checked in this
// order: the Host header must be 127.0.0.1:<port> or localhost:<port> (the DNS rebinding guard), then
// the path must be /<token>/ followed by a listed route for that method; either failure is 404 with
// an empty body, before anything else happens. A POST must then carry JSON from this origin, or it is
// 403 with an empty body. No CORS header is ever sent.
import crypto from 'node:crypto';
import { checkAction, checkTerminal } from './validate.js';

export const MAX_BODY_BYTES = 70000;
// Node answers a request without Host with its own 400; the spec wants 404 from the handler.
export const SERVER_OPTIONS = Object.freeze({ requireHostHeader: false });
export const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
const SECURITY_HEADERS = Object.freeze({
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': CSP,
});
const STATIC = Object.freeze({
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/style.css': ['style.css', 'text/css; charset=utf-8'],
});
const ROUTES = new Set(['GET /', 'GET /app.js', 'GET /style.css', 'GET /api/state', 'POST /api/action', 'POST /api/terminal']);
const TOKEN_PATH_RE = /^\/([0-9a-f]{32})(\/[^?]*)(\?.*)?$/;

function send(res, status, type, body) {
  const headers = { ...SECURITY_HEADERS, 'Content-Length': String(body.length) };
  if (type) headers['Content-Type'] = type;
  res.writeHead(status, headers);
  res.end(body);
}

const empty = (res, status) => send(res, status, null, Buffer.alloc(0));
const json = (res, status, value) => send(res, status, 'application/json; charset=utf-8', Buffer.from(JSON.stringify(value), 'utf8'));

// readJson(req): the parsed body, or undefined when it is larger than MAX_BODY_BYTES or not JSON.
function readJson(req) {
  return new Promise((resolve) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size <= MAX_BODY_BYTES) chunks.push(chunk);
    });
    req.on('end', () => {
      if (size > MAX_BODY_BYTES) return resolve(undefined);
      try {
        return resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        return resolve(undefined);
      }
    });
    req.on('error', () => resolve(undefined));
  });
}

// createHandler(opts): the (req, res) handler. opts: token (32 hex), port, files {name: Buffer} for
// index.html, app.js and style.css, getState() for /api/state, runAction(words) and
// openTerminal({verb, name}) returning promises.
export function createHandler({ token, port, files, getState, runAction, openTerminal }) {
  const hosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
  const origins = new Set([`http://127.0.0.1:${port}`, `http://localhost:${port}`]);
  const tokenBytes = Buffer.from(token, 'utf8');
  let busy = false;

  function route(req) {
    const m = TOKEN_PATH_RE.exec(req.url || '');
    if (!m || !crypto.timingSafeEqual(Buffer.from(m[1], 'utf8'), tokenBytes)) return null;
    const key = `${req.method} ${m[2]}`;
    return ROUTES.has(key) ? key : null;
  }

  function postAllowed(req) {
    const type = (req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    if (type !== 'application/json') return false;
    const origin = req.headers.origin;
    if (origin !== undefined && !origins.has(origin)) return false;
    const site = req.headers['sec-fetch-site'];
    return site === undefined || site === 'same-origin' || site === 'none';
  }

  async function handle(req, res) {
    if (!hosts.has((req.headers.host || '').toLowerCase())) return empty(res, 404);
    const key = route(req);
    if (key === null) return empty(res, 404);
    if (req.method === 'GET') {
      if (key === 'GET /api/state') return json(res, 200, getState());
      const [file, type] = STATIC[key.slice(4)];
      return send(res, 200, type, files[file]);
    }
    if (!postAllowed(req)) {
      req.resume();
      return empty(res, 403);
    }
    const body = await readJson(req);
    if (body === undefined) return empty(res, 403);
    if (key === 'POST /api/terminal') {
      const problem = checkTerminal(body);
      if (problem) return json(res, 400, { error: problem });
      const result = await openTerminal(body.verb === 'go' ? { verb: 'go', name: body.name } : { verb: 'auth' });
      return json(res, result.ok ? 200 : 500, result);
    }
    const words = body !== null && typeof body === 'object' && !Array.isArray(body) ? body.words : undefined;
    const problem = checkAction(words);
    if (problem) return json(res, 400, { error: problem });
    if (busy) return json(res, 409, { error: 'another action is still running' });
    busy = true;
    try {
      return json(res, 200, await runAction(words));
    } finally {
      busy = false;
    }
  }

  return (req, res) => {
    handle(req, res).catch(() => {
      if (!res.headersSent) empty(res, 500);
      else res.destroy();
    });
  };
}
```

- [ ] **Step 4: Run the handler test**

Run: `node --test "dashboard/test/http.test.js"`
Expected: `pass 12`, `fail 0`.

- [ ] **Step 5: Write the failing server test**

Create `dashboard/test/server.test.js`:

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { DASHBOARD, stubPlan, tempDir, waitFor } from './helpers.js';

const SERVER = path.join(DASHBOARD, 'server.js');
const SNAP = { version: 'abc1234', now: '2026-10-14T10:00:00Z', user: 'claude', lease_secs_left: 0, lease_secs: 1800,
  otp: { locked: false, fails: 0, cooldown_secs_left: 0 }, lines: 12, sessions: [] };

// freePort(): a port that was free a moment ago.
async function freePort() {
  const s = net.createServer();
  await new Promise((resolve) => s.listen(0, '127.0.0.1', resolve));
  const { port } = s.address();
  await new Promise((resolve) => s.close(resolve));
  return port;
}

// home(config): a temporary home directory, with ~/.tmuxkeep/config when config is a string.
function home(config) {
  const h = tempDir();
  if (config !== undefined) {
    fs.mkdirSync(path.join(h, '.tmuxkeep'));
    fs.writeFileSync(path.join(h, '.tmuxkeep', 'config'), config);
  }
  return h;
}

// start(args, env): runs server.js; resolves {child, out(), err(), exit} where exit resolves {code, signal}.
function start(args, env) {
  const child = spawn(process.execPath, [SERVER, ...args], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  let err = '';
  child.stdout.on('data', (b) => { out += b; });
  child.stderr.on('data', (b) => { err += b; });
  const exit = new Promise((resolve) => child.on('close', (code, signal) => resolve({ code, signal })));
  return { child, out: () => out, err: () => err, exit };
}

function envFor(h, extra = {}) {
  return { ...process.env, HOME: h, USERPROFILE: h, TMUXKEEP_TERMINAL_DRYRUN: '1', ...extra };
}

function get(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path, headers, agent: false }, (res) => {
      let body = '';
      res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

function post(port, path, value) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(value);
    const req = http.request({ host: '127.0.0.1', port, path, method: 'POST', agent: false,
      headers: { 'content-type': 'application/json', origin: `http://127.0.0.1:${port}` } }, (res) => {
      let text = '';
      res.on('data', (c) => { text += c; });
      res.on('end', () => resolve({ status: res.statusCode, body: text }));
    });
    req.on('error', reject);
    req.end(body);
  });
}

async function stop(run) {
  if (run.child.exitCode === null && run.child.signalCode === null) run.child.kill();
  await run.exit;
}

test('a Node older than 20 is refused with exit 2 before anything else', async () => {
  const run = start(['--no-open'], envFor(home(), { TMUXKEEP_NODE_VERSION: '18.19.0' }));
  const { code } = await run.exit;
  assert.equal(code, 2);
  assert.equal(run.err(), 'tmuxkeep ui: Node 20 or newer is required (found v18.19.0)\n');
  assert.equal(run.out(), '');
});

test('usage, a bad --port and a bad config value are exit 2 with one line', async () => {
  for (const [args, want] of [
    [['--frob'], 'usage: tmuxkeep ui [--port N] [--no-open]\n'],
    [['--port'], 'usage: tmuxkeep ui [--port N] [--no-open]\n'],
    [['--port', '80'], 'tmuxkeep ui: --port must be an integer from 1024 to 65535\n'],
  ]) {
    const run = start(args, envFor(home()));
    assert.equal((await run.exit).code, 2, args.join(' '));
    assert.equal(run.err(), want);
  }
  const h = home('DASHBOARD_PORT=80\n');
  const run = start(['--no-open'], envFor(h));
  assert.equal((await run.exit).code, 2);
  assert.equal(run.err(), `tmuxkeep ui: config ${path.join(h, '.tmuxkeep', 'config')}: DASHBOARD_PORT: must be an integer from 1024 to 65535\n`);
});

test('a busy port is exit 1 with the spec message', async () => {
  const blocker = net.createServer();
  await new Promise((resolve) => blocker.listen(0, '127.0.0.1', resolve));
  const { port } = blocker.address();
  try {
    const run = start(['--port', String(port), '--no-open'], envFor(home()));
    assert.equal((await run.exit).code, 1);
    assert.equal(run.err(), `tmuxkeep ui: port ${port} is in use; set DASHBOARD_PORT or pass --port\n`);
  } finally {
    await new Promise((resolve) => blocker.close(resolve));
  }
});

test('a full run: the address, the page, the follow connection, an action and a terminal request', async () => {
  const port = await freePort();
  const h = home(`DASHBOARD_PORT=${port}\n`);
  const s = stubPlan({
    status: [{ steps: [{ out: `${JSON.stringify(SNAP)}\n` }, { hang: true }], code: 0 }],
    send: [{ steps: [{ out: 'sent 13 bytes to api\n' }], code: 0 }],
  });
  const run = start(['--no-open'], envFor(h, { TMUXKEEP_SSH: s.env.TMUXKEEP_SSH, TMUXKEEP_STUB_SCRIPT: s.script }));
  try {
    const line = await waitFor(() => run.out().match(/^tmuxkeep ui: http:\/\/127\.0\.0\.1:(\d+)\/([0-9a-f]{32})\/  \(Ctrl-C stops\)\n$/));
    assert.equal(Number(line[1]), port);
    const token = line[2];
    const hostHeader = { host: `127.0.0.1:${port}` };
    const page = await get(port, `/${token}/`, hostHeader);
    assert.equal(page.status, 200);
    assert.match(page.body, /<script type="module" src="app\.js"><\/script>/);
    assert.equal(s.calls().length, 0, 'no ssh before the first /api/state');
    const snap = await waitFor(async () => JSON.parse((await get(port, `/${token}/api/state`, hostHeader)).body).snapshot);
    assert.deepEqual(snap, SNAP);
    assert.deepEqual(s.calls()[0].words, ['status', '--follow', '--lines', '12']);
    const action = await post(port, `/${token}/api/action`, { words: ['send', 'api', 'run the tests'] });
    assert.equal(action.status, 200);
    assert.deepEqual(JSON.parse(action.body), { code: 0, stdout: 'sent 13 bytes to api\n', stderr: '', needs_auth: false });
    const term = await post(port, `/${token}/api/terminal`, { verb: 'go', name: 'api' });
    assert.equal(term.status, 200);
    const argv = JSON.parse(term.body).argv;
    assert.ok(argv.includes('go') && argv.includes('api'));
    assert.ok(argv.some((a) => a.startsWith(h)), 'the wrapper path is under the home directory');
    assert.equal((await get(port, `/${'0'.repeat(32)}/`, hostHeader)).status, 404);
  } finally {
    await stop(run);
  }
});

test('the server listens on 127.0.0.1 only, not on ::1', async () => {
  const port = await freePort();
  const run = start(['--port', String(port), '--no-open'], envFor(home()));
  try {
    await waitFor(() => run.out().includes('Ctrl-C stops'));
    const v6 = await new Promise((resolve) => {
      const sock = net.connect({ host: '::1', port }, () => {
        sock.destroy();
        resolve('connected');
      });
      sock.on('error', () => resolve('refused'));
    });
    assert.equal(v6, 'refused');
  } finally {
    await stop(run);
  }
});

test('--port wins over DASHBOARD_PORT; without --no-open the browser command is printed in dry run', async () => {
  const port = await freePort();
  const run = start(['--port', String(port)], envFor(home('DASHBOARD_PORT=1024\n')));
  try {
    await waitFor(() => run.out().includes('dry run'));
    const lines = run.out().trim().split('\n');
    assert.match(lines[0], new RegExp(`^tmuxkeep ui: http://127\\.0\\.0\\.1:${port}/[0-9a-f]{32}/  \\(Ctrl-C stops\\)$`));
    const argv = JSON.parse(lines[1].replace('tmuxkeep ui: dry run: ', ''));
    assert.equal(argv[argv.length - 1], lines[0].split(' ')[2]);
  } finally {
    await stop(run);
  }
});

test('SIGTERM stops the server with exit 0', { skip: process.platform === 'win32' ? 'Windows has no catchable SIGTERM' : false }, async () => {
  const port = await freePort();
  const run = start(['--port', String(port), '--no-open'], envFor(home()));
  await waitFor(() => run.out().includes('Ctrl-C stops'));
  run.child.kill('SIGTERM');
  assert.deepEqual(await run.exit, { code: 0, signal: null });
});
```

- [ ] **Step 6: Run it to see it fail**

Run: `node --test "dashboard/test/server.test.js"`
Expected: FAIL: every child exits 1 with `Cannot find module` for `server.js` (on Windows the SIGTERM test is reported as skipped).

- [ ] **Step 7: Implement the entry point**

Create `dashboard/server.js`:

```js
// server.js - tmuxkeep ui, the local dashboard server (spec 6). The laptop wrappers run it as
//   node <dashboard dir>/server.js [--port N] [--no-open]
// It listens on 127.0.0.1 only, prints the address with a fresh token, and keeps one
// "status --follow" ssh connection while a page is open. It writes nothing to disk.
// Exit codes: 0 after Ctrl-C (SIGINT) or SIGTERM; 1 when the port cannot be bound; 2 for a usage or
// config error, or a Node older than 20. TMUXKEEP_NODE_VERSION stands in for the Node version in tests.
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { configPath, parseArgs, readConfig } from './lib/config.js';
import { createFollower, FOLLOW_WORDS } from './lib/follow.js';
import { createHandler, SERVER_OPTIONS } from './lib/http.js';
import { runVerb, spawnSsh } from './lib/ssh.js';
import { openBrowser, openTerminal } from './lib/terminal.js';

function quit(code, message) {
  process.stderr.write(`${message}\n`);
  process.exit(code);
}

// 1. Node 20 or newer.
const found = process.env.TMUXKEEP_NODE_VERSION || process.versions.node;
if (Number.parseInt(found, 10) < 20) quit(2, `tmuxkeep ui: Node 20 or newer is required (found v${found})`);

// 2. Arguments, then the config file; --port wins over DASHBOARD_PORT.
let args;
try {
  args = parseArgs(process.argv.slice(2));
} catch (err) {
  quit(2, err.message.startsWith('usage:') ? err.message : `tmuxkeep ui: ${err.message}`);
}
let config;
try {
  config = readConfig(configPath());
} catch (err) {
  quit(2, `tmuxkeep ui: ${err.message}`);
}
const port = args.port ?? config.port;

// 3. A fresh token for this run.
const token = crypto.randomBytes(16).toString('hex');

const here = path.dirname(fileURLToPath(import.meta.url));
const files = {};
for (const name of ['index.html', 'app.js', 'style.css']) files[name] = fs.readFileSync(path.join(here, 'public', name));

const follower = createFollower({ spawnChild: () => spawnSsh(FOLLOW_WORDS) });
const handler = createHandler({
  token,
  port,
  files,
  getState: () => {
    follower.touch();
    return follower.state();
  },
  runAction: (words) => runVerb(words),
  openTerminal: (request) => openTerminal(request, { home: os.homedir(), terminalCmd: config.terminalCmd }),
});

// 4. 127.0.0.1 only: never 0.0.0.0, never ::.
const server = http.createServer(SERVER_OPTIONS, handler);
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') quit(1, `tmuxkeep ui: port ${port} is in use; set DASHBOARD_PORT or pass --port`);
  quit(1, `tmuxkeep ui: cannot listen on 127.0.0.1:${port}: ${err.code || err.message}`);
});
server.listen(port, '127.0.0.1', async () => {
  // 5. The address, then the browser.
  const url = `http://127.0.0.1:${port}/${token}/`;
  process.stdout.write(`tmuxkeep ui: ${url}  (Ctrl-C stops)\n`);
  if (!args.open) return;
  const opened = await openBrowser(url);
  if (process.env.TMUXKEEP_TERMINAL_DRYRUN === '1') process.stdout.write(`tmuxkeep ui: dry run: ${JSON.stringify(opened.argv)}\n`);
  else if (opened.error) process.stderr.write(`tmuxkeep ui: could not open a browser (${opened.error}); open the address above yourself\n`);
});

// 7. Ctrl-C or SIGTERM: stop the follow child, close the server, exit 0.
function shutdown() {
  follower.stop();
  server.close();
  server.closeAllConnections();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
```

- [ ] **Step 8: Run every Node test**

Run: `node --test "dashboard/test/*.test.js"`
Expected: `tests 86`, `fail 0` (on Windows `pass 85` and `skipped 1`; on Linux `pass 86`). The whole suite took under 3 seconds on the laptop while planning. A stub started by the full-run test may outlive the server by up to 20 seconds on Windows (no catchable SIGTERM there); it exits by itself.

- [ ] **Step 9: Run the whole bats directory and the whole Pester folder**

Expected: all green and unchanged (nothing outside `dashboard/` changed in this task).

- [ ] **Step 10: Commit**

```bash
git add dashboard/lib/http.js dashboard/server.js dashboard/test/http.test.js dashboard/test/server.test.js
git commit -m "dashboard: loopback HTTP server with token, Host, Origin and CSP checks"
```

---

### Task 11: Deploy: two config keys and the dashboard copy

Suggested model: sonnet (ask Opus to review: deploy removes and recreates a folder under the user's home).

**Files:**
- Modify: `laptop/deploy.ps1` (157-158 the key list, 178 defaults, 240 validation, 327 comments, before 570 a new function, 681-688 step 7, 698 the last line)
- Modify: `laptop/deploy.sh` (10 the key list, 35 defaults, 106 validation, 191-193 the config text, before 539 a new function, 570-581 step 7, 670-673 the end of `tk_deploy_main`)
- Modify: `tests/fixtures/laptop-config` (append after line 35)
- Modify: `tests/pester/config.Tests.ps1` (45-52, 62-67, 105-106, 121-122, 211-222), `tests/pester/deploy.Tests.ps1` (23-30, before 150, 314-320)
- Modify: `tests/bats/laptop-config.bats` (25-32, 48-55, 68-106, 108-125, 250-263, 272-274), `tests/bats/laptop-deploy.bats` (93-101, append), `tests/bats/laptop-helpers.bash:28-40`

**Interfaces:**
- Consumes: the whole `dashboard/` folder (Tasks 5-10) as files to copy; nothing is executed.
- Produces (both deploys): laptop config keys `DASHBOARD_PORT` (default `7707`, integer 1024-65535, message `DASHBOARD_PORT: must be an integer from 1024 to 65535`) and `TERMINAL_CMD` (default empty, at most 200 characters, message `TERMINAL_CMD: at most 200 characters`; printable ASCII is already enforced for every value by both readers), after `SEND_MAX_BYTES` in the key lists, the defaults, the validators and the writers, each with the spec 5.2 comment line. A config without them is valid and gets the defaults (both readers start from the defaults; the new tests prove it). `deploy.conf` never carries them.
- Produces (PowerShell): `Install-TmuxkeepDashboard -RepoRoot <repo> -Destination <dir>`: refuses a missing `<repo>\dashboard\server.js` (`missing <path>`) and a destination whose last part is not `tmuxkeep-dashboard`; otherwise removes the destination, copies `dashboard\` there and removes its `test\`. Step 7 installs into `<HomeDir>\scripts\tmuxkeep-dashboard`, right after the wrapper, and the run ends with `dashboard: installed at <dir> (run: tmuxkeep ui)` before `deploy: done. ...`.
- Produces (bash): `tk_install_dashboard REPO DEST` (status 1 with `TK_ERR` set; refuses a `DEST` not ending in `/tmuxkeep/dashboard`); step 7 installs into `$HOME/.local/share/tmuxkeep/dashboard` after the completion script; on success `dashboard: installed at <dir> (run: tmuxkeep ui)` goes to stderr before `deploy: done. ...`, like every other status line of the bash deploy.
- A failure to copy the dashboard is fatal at step 7, exactly like a failure to copy the wrapper (exit 1, no proof of life). The spec's "step 3 (laptop files)" is the README's numbering of the Windows deploy; in the scripts it is step 7 (plan Q3).

- [ ] **Step 1: The fixture**

Append to `tests/fixtures/laptop-config` (LF endings, the file still ends with a newline):

```
# Loopback port for tmuxkeep ui (1024-65535).
DASHBOARD_PORT=7707
# Program that opens a terminal for go and auth; empty picks the platform default.
TERMINAL_CMD=
```

- [ ] **Step 2: Write the failing PowerShell config tests**

In `tests/pester/config.Tests.ps1`:

Replace the first `It` (lines 45-52) with:

```powershell
    It 'reads the fixture into the eighteen keys, in file order' {
        $v = Read-TmuxkeepConfig -Path (New-Cfg $Fixture)
        (@($v.Keys) -join ' ') | Should -BeExactly 'HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES DASHBOARD_PORT TERMINAL_CMD'
        $v['HOST'] | Should -BeExactly '203.0.113.10'
        $v['PORT'] | Should -BeExactly '22'
        $v['KEY'] | Should -BeExactly '~/.ssh/id_tmuxkeep_ed25519'
        $v['RESUME_CMD'] | Should -BeExactly 'claude --continue'
        $v['DASHBOARD_PORT'] | Should -BeExactly '7707'
        $v['TERMINAL_CMD'] | Should -BeExactly ''
    }
```

After the `It 'a missing key other than HOST takes its default; a missing HOST is required'` block, insert:

```powershell

    It 'a config written before the dashboard keys existed reads with their defaults (spec 5.2)' {
        $old = [regex]::Replace($Fixture, '(?m)^(# Loopback port.*|DASHBOARD_PORT=.*|# Program that opens.*|TERMINAL_CMD=.*)\n', '')
        $old | Should -Not -Match 'DASHBOARD_PORT|TERMINAL_CMD'
        $v = Read-TmuxkeepConfig -Path (New-Cfg $old)
        $v['DASHBOARD_PORT'] | Should -BeExactly '7707'
        $v['TERMINAL_CMD'] | Should -BeExactly ''
    }
```

In the `It 'rejects <Name>'` table, after the `SEND_MAX_BYTES 65537` row, add:

```powershell
        @{ Name = 'DASHBOARD_PORT 1023';        Key = 'DASHBOARD_PORT';      Value = '1023';              Reason = 'DASHBOARD_PORT: must be an integer from 1024 to 65535' }
        @{ Name = 'DASHBOARD_PORT 65536';       Key = 'DASHBOARD_PORT';      Value = '65536';             Reason = 'DASHBOARD_PORT: must be an integer from 1024 to 65535' }
        @{ Name = 'an empty DASHBOARD_PORT';    Key = 'DASHBOARD_PORT';      Value = '';                  Reason = 'DASHBOARD_PORT: must be an integer from 1024 to 65535' }
        @{ Name = 'a 201-character TERMINAL_CMD'; Key = 'TERMINAL_CMD';      Value = ('x' * 201);         Reason = 'TERMINAL_CMD: at most 200 characters' }
```

In the `It 'accepts <Name>'` table, after the `SEND_MAX_BYTES 65536` row, add:

```powershell
        @{ Name = 'DASHBOARD_PORT 1024';    Key = 'DASHBOARD_PORT'; Value = '1024' }
        @{ Name = 'DASHBOARD_PORT 65535';   Key = 'DASHBOARD_PORT'; Value = '65535' }
        @{ Name = 'a TERMINAL_CMD';         Key = 'TERMINAL_CMD';   Value = 'wezterm start --' }
        @{ Name = 'a 200-character TERMINAL_CMD'; Key = 'TERMINAL_CMD'; Value = ('x' * 200) }
```

In `It 'ConvertTo-TmuxkeepDeployConf carries the configured values and nothing laptop-only'`, after its last line add:

```powershell
        $t | Should -Not -Match 'DASHBOARD|TERMINAL'
```

- [ ] **Step 3: Write the failing PowerShell deploy tests**

In `tests/pester/deploy.Tests.ps1`:

Add `'Install-TmuxkeepDashboard'` to the first `foreach` list of `It 'defines the deploy functions and no longer the v1 append-once ones'` (after `'Get-TmuxkeepSshAgentProblems'`).

Insert before `Describe 'deploy.ps1 main sequence' {`:

```powershell
Describe 'Install-TmuxkeepDashboard' {
    BeforeAll {
        # A stand-in repository: dashboard\ with a lib file, a page file and a test folder.
        $script:DashRepo = Join-Path $TestDrive 'dash repo'
        foreach ($d in 'dashboard\lib', 'dashboard\public', 'dashboard\test') {
            New-Item -ItemType Directory -Path (Join-Path $DashRepo $d) -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $DashRepo 'dashboard\server.js') -Value '// server' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $DashRepo 'dashboard\lib\a.js') -Value '// a' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $DashRepo 'dashboard\public\app.js') -Value '// app' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $DashRepo 'dashboard\test\a.test.js') -Value '// test' -Encoding ascii
        function Get-Tree([string]$Root) {
            $names = [string[]]@(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { $_.FullName.Substring($Root.Length + 1).Replace('\', '/') })
            [Array]::Sort($names, [StringComparer]::Ordinal)
            return ($names -join ',')
        }
    }

    It 'copies dashboard\ without test\ into a new folder under a path with spaces (Review Focus 2)' {
        $dest = Join-Path $TestDrive 'home dir\scripts\tmuxkeep-dashboard'
        Install-TmuxkeepDashboard -RepoRoot $DashRepo -Destination $dest
        Get-Tree $dest | Should -BeExactly 'lib/a.js,public/app.js,server.js'
    }

    It 'replaces the folder: a file from an older version is gone' {
        $dest = Join-Path $TestDrive 'again\scripts\tmuxkeep-dashboard'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'stale.js') -Value 'old' -Encoding ascii
        Install-TmuxkeepDashboard -RepoRoot $DashRepo -Destination $dest
        Get-Tree $dest | Should -BeExactly 'lib/a.js,public/app.js,server.js'
    }

    It 'refuses a destination that is not a tmuxkeep-dashboard folder, and a repository without the dashboard' {
        $other = Join-Path $TestDrive 'precious'
        New-Item -ItemType Directory -Path $other | Out-Null
        Set-Content -LiteralPath (Join-Path $other 'keep.txt') -Value 'keep' -Encoding ascii
        { Install-TmuxkeepDashboard -RepoRoot $DashRepo -Destination $other } | Should -Throw -ExpectedMessage "refusing to replace ${other}: the folder must be named tmuxkeep-dashboard"
        Test-Path -LiteralPath (Join-Path $other 'keep.txt') | Should -BeTrue
        { Install-TmuxkeepDashboard -RepoRoot (Join-Path $TestDrive 'empty') -Destination (Join-Path $TestDrive 'x\tmuxkeep-dashboard') } | Should -Throw -ExpectedMessage '*dashboard\server.js'
    }
}

```

In `It 'installs the wrapper, the profile block and the ssh config block'`, after its last line add (`$HomeRoot` is `...\home dir`, with a space):

```powershell
        $dash = Join-Path $HomeRoot 'scripts\tmuxkeep-dashboard'
        ([IO.File]::ReadAllBytes((Join-Path $dash 'server.js')) -join ',') | Should -BeExactly ([IO.File]::ReadAllBytes((Join-Path $Repo 'dashboard\server.js')) -join ',')
        Test-Path -LiteralPath (Join-Path $dash 'public\app.js') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dash 'test') | Should -BeFalse
        $r.Out | Should -Match ([regex]::Escape("dashboard: installed at $dash (run: tmuxkeep ui)"))
```

and after that `It` block insert:

```powershell

    It 'replaces the dashboard folder on every deploy, and a failing installer leaves it alone' {
        $dash = Join-Path $HomeRoot 'scripts\tmuxkeep-dashboard'
        New-Item -ItemType Directory -Path $dash -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dash 'stale.js') -Value 'old' -Encoding ascii
        $env:TK_STUB_SSH_RC = '3'
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 3 -Because $r.Out
        Test-Path -LiteralPath (Join-Path $dash 'stale.js') | Should -BeTrue
        $r.Out | Should -Not -Match 'dashboard: installed'
        Remove-Item Env:\TK_STUB_SSH_RC
        $r = Invoke-Deploy @()
        $r.Code | Should -Be 0 -Because $r.Out
        Test-Path -LiteralPath (Join-Path $dash 'stale.js') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dash 'server.js') | Should -BeTrue
    }
```

- [ ] **Step 4: Run them to see them fail**

Run the G7 command with `'tests\pester\config.Tests.ps1'` and then `'tests\pester\deploy.Tests.ps1'`. Expected: the fixture and key-list tests fail with `line 37: unknown key DASHBOARD_PORT` (and the deploy child runs fail the same way, since they copy the fixture); `Install-TmuxkeepDashboard` is not found.

- [ ] **Step 5: Implement the PowerShell side**

In `laptop/deploy.ps1`:

Lines 157-158 become:

```powershell
# The eighteen laptop keys in file order. One line on purpose: the parity test reads it.
function Get-TmuxkeepConfigKeys { @('HOST', 'PORT', 'USER', 'KEY', 'ADMIN_KEY', 'LAUNCH_CMD', 'RESUME_CMD', 'INSTALL_CLAUDE_CODE', 'LEASE_SECS', 'TOMBSTONE_TTL', 'OTP_FAIL_MAX', 'OTP_FAIL_WINDOW', 'OTP_COOLDOWN', 'OTP_HARD_MAX', 'OTP_READ_TIMEOUT', 'SEND_MAX_BYTES', 'DASHBOARD_PORT', 'TERMINAL_CMD') }
```

In `Get-TmuxkeepConfigDefaults`, after `$d['SEND_MAX_BYTES'] = '8000'` add:

```powershell
    $d['DASHBOARD_PORT'] = '7707'
    $d['TERMINAL_CMD'] = ''
```

In `Test-TmuxkeepConfigValues`, after the `SEND_MAX_BYTES` line add:

```powershell
    Assert-TmuxkeepInt -Key 'DASHBOARD_PORT' -Value ([string]$Values['DASHBOARD_PORT']) -Lo 1024 -Hi 65535
    if (([string]$Values['TERMINAL_CMD']).Length -gt 200) {
        throw 'TERMINAL_CMD: at most 200 characters'
    }
```

In `ConvertTo-TmuxkeepConfigText`, after the `SEND_MAX_BYTES = '...'` entry of `$comments` add:

```powershell
        DASHBOARD_PORT = 'Loopback port for tmuxkeep ui (1024-65535).'
        TERMINAL_CMD = 'Program that opens a terminal for go and auth; empty picks the platform default.'
```

Before the line `# Dot-sourced (the tests): functions only.` insert:

```powershell
# The dashboard (spec 5.3): Destination is removed and made again from <RepoRoot>\dashboard, without
# its test folder. Destination must end in \tmuxkeep-dashboard, so a wrong argument cannot remove
# anything else.
function Install-TmuxkeepDashboard {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Destination
    )
    $src = Join-Path $RepoRoot 'dashboard'
    if (-not (Test-Path -LiteralPath (Join-Path $src 'server.js') -PathType Leaf)) {
        throw ('missing ' + (Join-Path $src 'server.js'))
    }
    if ((Split-Path -Leaf $Destination) -cne 'tmuxkeep-dashboard') {
        throw "refusing to replace ${Destination}: the folder must be named tmuxkeep-dashboard"
    }
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction Stop
    }
    Copy-Item -LiteralPath $src -Destination $Destination -Recurse -ErrorAction Stop
    $tests = Join-Path $Destination 'test'
    if (Test-Path -LiteralPath $tests) {
        Remove-Item -LiteralPath $tests -Recurse -Force -ErrorAction Stop
    }
}

```

Replace step 7 (lines 681-688) with:

```powershell
    # 7. The wrapper, the dashboard next to it, and the profile snippet.
    try {
        $scriptsDir = Join-Path $HomeDir 'scripts'
        [void][IO.Directory]::CreateDirectory($scriptsDir)
        Copy-Item -LiteralPath (Join-Path $repo 'laptop\tmuxkeep.ps1') -Destination (Join-Path $scriptsDir 'tmuxkeep.ps1') -Force
        $dashboardDir = Join-Path $scriptsDir 'tmuxkeep-dashboard'
        Install-TmuxkeepDashboard -RepoRoot $repo -Destination $dashboardDir
        Set-TmuxkeepProfileSnippet -ProfilePath $ProfilePath -SnippetPath (Join-Path $repo 'laptop\profile-snippet.ps1')
    }
    catch { Write-Host ('deploy: ' + $_.Exception.Message); exit 1 }
```

and the last line (698) becomes the two lines:

```powershell
Write-Host "dashboard: installed at $dashboardDir (run: tmuxkeep ui)"
Write-Host 'deploy: done. Open a new PowerShell window to load the tmuxkeep function.'
```

- [ ] **Step 6: Run the PowerShell tests**

Run the G7 command with `'tests\pester\config.Tests.ps1'`, `'tests\pester\deploy.Tests.ps1'`, `'tests\pester\static.Tests.ps1'`. Expected: `Failed: 0`.

- [ ] **Step 7: Write the failing bats tests**

In `tests/bats/laptop-helpers.bash`, `mk_repo_copy` copies the dashboard too. Replace lines 28-40 with:

```bash
# mk_repo_copy: prints the path of a fresh one-commit git repository holding copies of laptop/, vps/
# and dashboard/. deploy.sh runs from there, so no test depends on the real checkout's .git (a
# worktree's .git file points at a Windows path that does not exist inside Docker).
mk_repo_copy() {
  local r="$BATS_TEST_TMPDIR/repo"
  rm -rf "$r"
  mkdir -p "$r"
  cp -R "$REPO/laptop" "$REPO/vps" "$REPO/dashboard" "$r/"
  git -c init.defaultBranch=main init -q "$r"
  git -C "$r" add -A
  git -C "$r" -c user.email=test@example.invalid -c user.name=test commit -q -m test
  printf '%s' "$r"
}
```

In `tests/bats/laptop-config.bats`:

In `@test "reads the fixture"` add, after the `TKC_SEND_MAX_BYTES` line:

```bash
  [ "$TKC_DASHBOARD_PORT" = 7707 ]
  [ -z "$TKC_TERMINAL_CMD" ]
```

After `@test "a missing key other than HOST takes its default; a missing HOST is required"` insert:

```bash

@test "a config written before the dashboard keys existed reads with their defaults (spec 5.2)" {
  grep -v -e '^DASHBOARD_PORT=' -e '^TERMINAL_CMD=' -e '^# Loopback port' -e '^# Program that opens' "$FIX" > "$C"
  [ "$(grep -c -e DASHBOARD -e TERMINAL "$C")" -eq 0 ]
  TKC_DASHBOARD_PORT=1
  TKC_TERMINAL_CMD=x
  tk_conf_read "$C"
  [ "$TKC_DASHBOARD_PORT" = 7707 ]
  [ -z "$TKC_TERMINAL_CMD" ]
}
```

In `@test "rejects each invalid value with the key named"`, add to the here-document after the `SEND_MAX_BYTES|65537|...` line:

```
DASHBOARD_PORT|1023|DASHBOARD_PORT: must be an integer from 1024 to 65535
DASHBOARD_PORT|65536|DASHBOARD_PORT: must be an integer from 1024 to 65535
DASHBOARD_PORT||DASHBOARD_PORT: must be an integer from 1024 to 65535
```

and after the test's last two lines (the `RESUME_CMD` check) add:

```bash
  with_line TERMINAL_CMD "$(printf 'x%.0s' $(seq 1 201))"
  [ "$(reason "$C")" = "$C: TERMINAL_CMD: at most 200 characters" ]
```

In `@test "accepts the bounds and the edge values"`, add to the here-document after `SEND_MAX_BYTES|65536`:

```
DASHBOARD_PORT|1024
DASHBOARD_PORT|65535
TERMINAL_CMD|wezterm start --
```

In `@test "tk_deploy_conf_text on the defaults is the deploy.conf fixture, and carries the configured values"`, add as its last line:

```bash
  [ "$(tk_deploy_conf_text | grep -c -e DASHBOARD -e TERMINAL)" -eq 0 ]
```

`@test "the key list is one line"` becomes:

```bash
@test "the key list is one line" {
  grep -qx 'TK_CONF_KEYS="HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES DASHBOARD_PORT TERMINAL_CMD"' "$REPO/laptop/deploy.sh"
}
```

In `tests/bats/laptop-deploy.bats`, in `@test "installs the wrapper, the completion and the rc block, and writes the ssh config block"` add after its last line:

```bash
  cmp "$HOME/.local/share/tmuxkeep/dashboard/server.js" "$REPO/dashboard/server.js"
  [ -f "$HOME/.local/share/tmuxkeep/dashboard/public/app.js" ]
  [ ! -e "$HOME/.local/share/tmuxkeep/dashboard/test" ]
```

and append to the file:

```bash

@test "the dashboard is replaced on every deploy, its place is printed, and a failing installer leaves it alone" {
  local dash="$HOME/.local/share/tmuxkeep/dashboard"
  mkdir -p "$dash"
  printf 'old\n' > "$dash/stale.js"
  export TK_STUB_SSH_RC=3
  run --separate-stderr deploy
  [ "$status" -eq 3 ]
  [ -f "$dash/stale.js" ]
  [[ "$stderr" != *'dashboard: installed'* ]]
  unset TK_STUB_SSH_RC
  run --separate-stderr deploy
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ ! -e "$dash/stale.js" ]
  [ -f "$dash/server.js" ]
  [[ "$stderr" == *"dashboard: installed at $dash (run: tmuxkeep ui)"* ]]
  [[ "$output" != *'dashboard:'* ]]
}

@test "tk_install_dashboard refuses a folder that is not .../tmuxkeep/dashboard and touches nothing" {
  mkdir -p "$BATS_TEST_TMPDIR/precious"
  printf 'keep\n' > "$BATS_TEST_TMPDIR/precious/keep.txt"
  run "$BASH" -c '. "$1"; tk_install_dashboard "$2" "$3" || { printf "%s\n" "$TK_ERR"; exit 1; }' _ "$R/laptop/deploy.sh" "$R" "$BATS_TEST_TMPDIR/precious"
  [ "$status" -eq 1 ]
  [ "$output" = "refusing to replace $BATS_TEST_TMPDIR/precious: the folder must be .../tmuxkeep/dashboard" ]
  [ -f "$BATS_TEST_TMPDIR/precious/keep.txt" ]
}
```

- [ ] **Step 8: Run them to see them fail**

Run (Git Bash): `bash tests/run-bats.sh tests/bats/laptop-config.bats` and `bash tests/run-bats.sh tests/bats/laptop-deploy.bats`. Expected: failures naming `unknown key DASHBOARD_PORT`, and no dashboard under `~/.local/share`.

- [ ] **Step 9: Implement the bash side**

In `laptop/deploy.sh`:

Line 10 becomes:

```bash
TK_CONF_KEYS="HOST PORT USER KEY ADMIN_KEY LAUNCH_CMD RESUME_CMD INSTALL_CLAUDE_CODE LEASE_SECS TOMBSTONE_TTL OTP_FAIL_MAX OTP_FAIL_WINDOW OTP_COOLDOWN OTP_HARD_MAX OTP_READ_TIMEOUT SEND_MAX_BYTES DASHBOARD_PORT TERMINAL_CMD"
```

In `tk_conf_defaults`, after `TKC_SEND_MAX_BYTES=8000` add:

```bash
  TKC_DASHBOARD_PORT=7707
  TKC_TERMINAL_CMD=''
```

In `tk_conf_validate`, after the `SEND_MAX_BYTES` line add:

```bash
  tk_check_int DASHBOARD_PORT "$TKC_DASHBOARD_PORT" 1024 65535 || return 1
  if [ "${#TKC_TERMINAL_CMD}" -gt 200 ]; then TK_ERR='TERMINAL_CMD: at most 200 characters'; return 1; fi
```

In `tk_conf_text`, replace its last two lines (the only place where `"SEND_MAX_BYTES=$TKC_SEND_MAX_BYTES"` is followed by `}`; `tk_deploy_conf_text` further down must not change)

```bash
    '# Largest text that send accepts, in bytes (1-65536).' \
    "SEND_MAX_BYTES=$TKC_SEND_MAX_BYTES"
}
```

with

```bash
    '# Largest text that send accepts, in bytes (1-65536).' \
    "SEND_MAX_BYTES=$TKC_SEND_MAX_BYTES" \
    '# Loopback port for tmuxkeep ui (1024-65535).' \
    "DASHBOARD_PORT=$TKC_DASHBOARD_PORT" \
    '# Program that opens a terminal for go and auth; empty picks the platform default.' \
    "TERMINAL_CMD=$TKC_TERMINAL_CMD"
}
```

Before the line `# ---- the main sequence (spec 6.1 steps 0-9) ----` insert:

```bash
# tk_install_dashboard REPO DEST: removes DEST and copies REPO/dashboard there without its test/
# folder (spec 5.3). DEST must end in /tmuxkeep/dashboard, so a wrong argument cannot remove anything
# else. Status 1 with TK_ERR set on any failure. cp -R SRC/. DEST/ works with BSD and GNU cp.
tk_install_dashboard() {
  local src=$1/dashboard dest=$2
  TK_ERR=''
  case $dest in
    */tmuxkeep/dashboard) ;;
    *) TK_ERR="refusing to replace $dest: the folder must be .../tmuxkeep/dashboard"; return 1 ;;
  esac
  if [ ! -f "$src/server.js" ]; then TK_ERR="missing $src/server.js"; return 1; fi
  if ! rm -rf "$dest" || ! mkdir -p "$dest"; then TK_ERR="cannot create $dest"; return 1; fi
  if ! cp -R "$src/." "$dest/" || ! rm -rf "$dest/test"; then TK_ERR="cannot copy the dashboard to $dest"; return 1; fi
  return 0
}

```

In `tk_deploy_remote`, change the step 7 comment to `# 7. The wrapper, the completion, the dashboard and the rc block.` and insert after the `completion.bash` copy (the `if ... fi` that ends with `return 1; fi` for `$HOME/.tmuxkeep/completion.bash`):

```bash
  if ! tk_install_dashboard "$repo" "$HOME/.local/share/tmuxkeep/dashboard"; then
    printf 'deploy: %s\n' "$TK_ERR" >&2; return 1
  fi
```

In `tk_deploy_main`, the success block at the end becomes:

```bash
  if [ "$rc" -eq 0 ]; then
    rcfile=$(tk_rc_file)
    printf 'dashboard: installed at %s (run: tmuxkeep ui)\n' "$HOME/.local/share/tmuxkeep/dashboard" >&2
    printf 'deploy: done. Open a new terminal, or run: . %s\n' "$rcfile" >&2
  fi
```

- [ ] **Step 10: Run the bats tests**

Run (Git Bash): `bash tests/run-bats.sh tests/bats/laptop-config.bats`, `... tests/bats/laptop-deploy.bats`, `... tests/bats/parity.bats`, `... tests/bats/lint-laptop.bats`, `... tests/bats/lint.bats`. Expected: all `ok` (`parity.bats` checks that both deploys list the same eighteen keys in the same order, and that the `deploy.conf` key whitelist did not change).

- [ ] **Step 11: Run every suite**

The whole bats directory (up by 3), the whole Pester folder (up by 13), and the Node suite (unchanged: `config.test.js` reads the new fixture as the defaults, as before).

- [ ] **Step 12: Commit**

```bash
git add laptop/deploy.ps1 laptop/deploy.sh tests/fixtures/laptop-config tests/pester/config.Tests.ps1 tests/pester/deploy.Tests.ps1 tests/bats/laptop-config.bats tests/bats/laptop-deploy.bats tests/bats/laptop-helpers.bash
git commit -m "deploy: DASHBOARD_PORT and TERMINAL_CMD; install the dashboard next to the wrapper"
```

---

### Task 12: Smoke tests: one `status` step

Suggested model: sonnet.

**Files:**
- Modify: `tests/smoke.sh` (whole file shown below; the changes are the header, `TK_JQ`, `tk_names_session` and the steps renumbered to 14 with the new step 4)
- Modify: `tests/smoke.ps1` (whole file shown below; the same changes)
- Modify: `tests/bats/smoke.bats` (the fake wrapper at lines 12-53, `setup` line 9, tests at lines 59-64 and 81-89; append), `tests/pester/smoke.Tests.ps1` (the fake at lines 7-44, `BeforeEach` 48-52, `AfterAll` 54-58, tests at 60-64 and 88-95; append)

**Interfaces:**
- Consumes (Task 1): `tmuxkeep status` prints one JSON object naming every session.
- Produces: smoke step `4/14 status (JSON naming the session)`, between `ls` and `peek`; every later step renumbered (`5/14 peek` ... `14/14 log -n 20`). bash: the JSON is parsed with `jq -e` when `jq` is on `PATH` (`TK_SMOKE_JQ` names another program, for the tests), else the session name must appear as `"name":"<n>"`; PowerShell: `ConvertFrom-Json`. A failure stops with `FAIL 4/14 status (JSON naming the session): the status output does not name <n>` and the cleanup hint (the session exists by then). Agents never run either script for real (G1); only the fake-wrapper suites run them.

- [ ] **Step 1: Write the failing bats tests**

In `tests/bats/smoke.bats`:

In `setup`, the `unset` line becomes:

```bash
  unset TK_FAKE_IGNORE_LOCK TK_FAKE_RM_NOW_LOCKED TK_FAKE_STATUS_EMPTY TK_FAKE_STATUS_BAD TK_SMOKE_JQ
```

In the fake wrapper (inside the `<<'EOF'` here-document), insert before the line `  log) while IFS= read -r c; do`:

```bash
  status) if [ -n "${TK_FAKE_STATUS_BAD:-}" ]; then printf '{"sessions":[{"name":"%s"}\n' "$n"; exit 0; fi
          if [ "$state" = live ] && [ -z "${TK_FAKE_STATUS_EMPTY:-}" ]; then
            printf '{"version":"x","sessions":[{"name":"%s","state":"live"}]}\n' "$n"
          else
            printf '{"version":"x","sessions":[]}\n'
          fi
          exit 0 ;;
```

In `@test "passes against a broker that behaves"` change `-eq 13` to `-eq 14`. In `@test "prints the cleanup hint once, restore before unlock, when rm --now is refused as locked"` change `'FAIL 12/13'` to `'FAIL 13/14'`.

Append:

```bash

@test "step 4 fails, with the cleanup hint, when the status JSON does not name the session" {
  export TK_FAKE_STATUS_EMPTY=1
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 1 ]
  [[ "$output" == *'FAIL 4/14 status (JSON naming the session): the status output does not name smoke-'* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'To clean it up')" -eq 1 ]
  [ "$(calls | tail -n 1)" = status ]
}

@test "step 4 rejects output that is not JSON when jq is installed, and matches the name as text without jq" {
  export TK_FAKE_STATUS_BAD=1
  if command -v jq >/dev/null; then
    run "$BASH" "$SMOKE" --wrapper "$FAKE"
    [ "$status" -eq 1 ]
    [[ "$output" == *'FAIL 4/14'* ]]
  fi
  export TK_FAKE_DIR="$BATS_TEST_TMPDIR/fake2"
  mkdir -p "$TK_FAKE_DIR"
  export TK_SMOKE_JQ=no-such-jq-program
  run "$BASH" "$SMOKE" --wrapper "$FAKE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *'PASS 4/14 status (JSON naming the session)'* ]]
}
```

- [ ] **Step 2: Write the failing Pester tests**

In `tests/pester/smoke.Tests.ps1`:

In the fake wrapper text, insert before the line `    'peek'    { 'some pane text'; exit 0 }`:

```powershell
    'status'  { if ($env:TMUXKEEP_FAKE_STATUS_BAD) { '{"sessions":[{"name":'; exit 0 }
                $s = Get-Content -LiteralPath $stateFile -ErrorAction SilentlyContinue
                $n = Get-Content -LiteralPath $nameFile -ErrorAction SilentlyContinue
                if ($s -eq 'live' -and -not $env:TMUXKEEP_FAKE_STATUS_EMPTY) { '{"version":"x","sessions":[{"name":"' + $n + '","state":"live"}]}' }
                else { '{"version":"x","sessions":[]}' }
                exit 0 }
```

Add these two lines to the end of both `BeforeEach` and `AfterAll`:

```powershell
        Remove-Item Env:\TMUXKEEP_FAKE_STATUS_EMPTY -ErrorAction SilentlyContinue
        Remove-Item Env:\TMUXKEEP_FAKE_STATUS_BAD -ErrorAction SilentlyContinue
```

In `It 'passes against a broker that behaves'` add as its last line:

```powershell
        ([regex]::Matches($out, '(?m)^PASS ')).Count | Should -Be 14
```

In `It 'prints the cleanup hint once, with restore before unlock, when rm --now is refused as locked'` change `'FAIL 12/13'` to `'FAIL 13/14'`, and after that `It` add:

```powershell

    It 'step 4 fails, with the cleanup hint, when the status JSON does not name the session' {
        $env:TMUXKEEP_FAKE_STATUS_EMPTY = '1'
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String -Width 4096
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'FAIL 4/14 status \(JSON naming the session\): the status output does not name smoke-[a-z0-9]{6}'
        [regex]::Matches($out, 'To clean it up').Count | Should -Be 1
        $calls = @(Get-Content -LiteralPath (Join-Path $env:TMUXKEEP_FAKE_DIR 'calls.log'))
        $calls[-1] | Should -BeExactly 'status'
    }

    It 'step 4 fails when the status output is not JSON' {
        $env:TMUXKEEP_FAKE_STATUS_BAD = '1'
        $out = & $Smoke -Wrapper $Fake *>&1 | Out-String -Width 4096
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'FAIL 4/14'
    }
```

- [ ] **Step 3: Run them to see them fail**

Run (Git Bash) `bash tests/run-bats.sh tests/bats/smoke.bats` and the G7 command with `'tests\pester\smoke.Tests.ps1'`. Expected: the new tests and the two changed ones fail (13 steps, no `status` step).

- [ ] **Step 4: Implement `tests/smoke.sh`**

`tests/smoke.sh` becomes exactly:

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
# lifecycle (14 steps) and removes it again. Exit 0 when every step passes, 1 at the first mismatch:
# the script stops there and prints how to clean up by hand. The same hint is printed if the run is
# interrupted while a session may exist. Step 1 (auth) runs uncaptured so the "TOTP: " prompt
# reaches the terminal; every other step is captured, and the gated verbs reuse the lease. Step 4
# checks the dashboard's status JSON with jq when jq is installed, else with a fixed-string match.

TK_WRAPPER=$HOME/.local/bin/tmuxkeep
TK_N=''
TK_SESSION_MAY_EXIST=0
TK_HINT_PRINTED=0
TK_OUT=''
# The JSON checker for step 4. TK_SMOKE_JQ names another program for the tests.
TK_JQ=${TK_SMOKE_JQ:-jq}

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

# tk_names_session TEXT: status 0 when TEXT is a status object whose sessions include one named
# $TK_N. With jq the object must parse; without it, the name must appear as jq -c prints it.
tk_names_session() {
  if command -v "$TK_JQ" >/dev/null; then
    printf '%s\n' "$1" | "$TK_JQ" -e --arg n "$TK_N" 'any(.sessions[]; .name == $n)' >/dev/null
  else
    printf '%s\n' "$1" | grep -qF "\"name\":\"$TK_N\""
  fi
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
  # Bounded read (-N3): a `tr < urandom | head` pipeline never ends where SIGPIPE is ignored
  # (GitHub Actions, Node-spawned shells) because BSD tr ignores write errors.
  TK_N="smoke-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  printf 'smoke: session name %s\n' "$TK_N"
  trap 'tk_cleanup_hint; exit 130' INT TERM

  # 1. auth, uncaptured, so the TOTP prompt reaches the terminal.
  echo 'Type the code from your phone at the TOTP prompt.'
  "$TK_WRAPPER" auth
  code=$?
  tk_check '1/14 auth' "$code" 0 '' ''

  # A session may exist from here on, even if new itself fails halfway.
  TK_SESSION_MAY_EXIST=1
  tk_step "2/14 new $TK_N" 0 "created $TK_N in " new "$TK_N"
  tk_step '3/14 ls (live row)' 0 "^${TK_N}[[:space:]]+live" ls

  # 4. The dashboard's status: one JSON object that names the session. PASS only after that check.
  TK_OUT=$("$TK_WRAPPER" status 2>&1)
  code=$?
  if [ "$code" = 0 ] && ! tk_names_session "$TK_OUT"; then
    tk_stop '4/14 status (JSON naming the session)' "the status output does not name $TK_N" "$TK_OUT"
  fi
  tk_check '4/14 status (JSON naming the session)' "$code" 0 "$TK_OUT" ''

  tk_step "5/14 peek $TK_N" 0 '' peek "$TK_N"
  tk_step "6/14 send $TK_N /help" 0 "sent [0-9]+ bytes to $TK_N" send "$TK_N" /help
  tk_step "7/14 lock $TK_N" 0 "locked $TK_N" lock "$TK_N"
  tk_step "8/14 rm $TK_N (locked, must be refused with exit 3)" 3 '' rm "$TK_N"
  tk_step "9/14 unlock $TK_N" 0 '' unlock "$TK_N"
  tk_step "10/14 rm $TK_N (tombstone)" 0 "tombstoned $TK_N;" rm "$TK_N"
  tk_step '11/14 ls (tombstone row)' 0 "^zz~$TK_N~[0-9]+[[:space:]]+tombstone" ls
  tk_step "12/14 restore $TK_N" 0 "restored $TK_N" restore "$TK_N"
  tk_step "13/14 rm $TK_N --now --confirm $TK_N" 0 "killed $TK_N" rm "$TK_N" --now --confirm "$TK_N"
  # The session is gone now; a later failure has nothing to clean up.
  TK_SESSION_MAY_EXIST=0

  # 14. The audit log must show every verb used against this session. PASS only after that check.
  TK_OUT=$("$TK_WRAPPER" log -n 20 2>&1)
  code=$?
  if [ "$code" = 0 ]; then
    for v in new peek send lock rm unlock restore; do
      printf '%s\n' "$TK_OUT" | grep -F "\"verb\":\"$v\"" | grep -qF "\"session\":\"$TK_N\"" || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
      tk_stop '14/14 log -n 20 (audit lines for this session)' "no audit line for session $TK_N and verb:$missing" "$TK_OUT"
    fi
  fi
  tk_check '14/14 log -n 20 (audit lines for this session)' "$code" 0 "$TK_OUT" ''
  trap - INT TERM
  echo 'smoke: all steps passed'
  return 0
}

[[ ${BASH_SOURCE[0]} != "$0" ]] && return 0
tk_smoke_main "$@"
exit $?
```

- [ ] **Step 5: Implement `tests/smoke.ps1`**

`tests/smoke.ps1` becomes exactly:

```powershell
# smoke.ps1 - operator end-to-end smoke test for the tmuxkeep session broker (Windows PowerShell 5.1).
#
# Run it yourself, from a terminal, against the real VPS:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 [-Wrapper <path>]
# The default wrapper is $HOME\scripts\tmuxkeep.ps1. Agents never run this against the real wrapper;
# tests\pester\smoke.Tests.ps1 drives it with a fake wrapper instead.
#
# It creates one throwaway session named smoke-<6 random chars>, walks it through the whole
# lifecycle (14 steps), and removes it again. Exit 0 when every step passes. Exit 1 at the first
# mismatch: the script stops there and prints how to clean up by hand. The same cleanup hint is
# printed if the run is interrupted (Ctrl+C) while a session may exist.
#
# Step 1 (auth) runs uncaptured so the "TOTP: " prompt (which arrives on ssh's stdout) reaches the
# console. Every other step is captured with Out-String. The gated verbs after auth reuse the lease.
param([string]$Wrapper = (Join-Path $HOME 'scripts\tmuxkeep.ps1'))

$script:SessionMayExist = $false
$script:HintPrinted = $false
$script:LastOut = ''

# Print how to remove a leftover test session, at most once, and only while one may exist.
# Called from Stop-Smoke (so the hint follows the FAIL text) and from the finally block below
# (so an interrupt still gets it). The HintPrinted flag stops a normal FAIL from printing it twice.
function Write-CleanupHint {
    if (-not $script:SessionMayExist -or $script:HintPrinted) { return }
    $script:HintPrinted = $true
    Write-Host "A test session may be left behind. To clean it up: tmuxkeep rm $n --now --confirm $n"
    Write-Host "If the rm is refused as locked: run 'tmuxkeep restore $n' only if 'tmuxkeep ls' shows a zz~$n~... row, then 'tmuxkeep unlock $n', then the rm again."
}

# Print the failure, the cleanup hint (when a session may be left behind), and stop.
function Stop-Smoke {
    param([string]$Step, [string]$Reason, [string]$Output = '')
    Write-Host "FAIL ${Step}: $Reason"
    if ($Output.Trim().Length -gt 0) {
        Write-Host '--- output ---'
        Write-Host $Output.TrimEnd()
        Write-Host '--- end of output ---'
    }
    Write-CleanupHint
    exit 1
}

# Check one step's exit code and (optionally) its output, print PASS, or stop on the first mismatch.
function Confirm-Step {
    param([string]$Step, [object]$Code, [int]$ExpectCode, [string]$Output = '', [string]$Pattern = '')
    if ($null -eq $Code) {
        Stop-Smoke -Step $Step -Reason 'the wrapper returned no exit code' -Output $Output
    }
    if ($Code -ne $ExpectCode) {
        Stop-Smoke -Step $Step -Reason "exit code $Code, expected $ExpectCode" -Output $Output
    }
    if ($Pattern -ne '' -and $Output -cnotmatch $Pattern) {
        Stop-Smoke -Step $Step -Reason "output did not match /$Pattern/" -Output $Output
    }
    Write-Host "PASS $Step"
}

# Run one captured step: call the wrapper, capture its output as one string, then check it.
# The output is left in $script:LastOut.
function Invoke-Step {
    param([string]$Step, [string[]]$Words, [int]$ExpectCode = 0, [string]$Pattern = '')
    $global:LASTEXITCODE = $null
    $script:LastOut = & $Wrapper @Words | Out-String
    Confirm-Step -Step $Step -Code $LASTEXITCODE -ExpectCode $ExpectCode -Output $script:LastOut -Pattern $Pattern
}

if (-not (Test-Path -LiteralPath $Wrapper)) {
    Write-Host "FAIL setup: wrapper not found: $Wrapper"
    exit 1
}

$chars = 'abcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
$n = 'smoke-' + (-join (1..6 | ForEach-Object { Get-Random -InputObject $chars }))
$e = [regex]::Escape($n)
Write-Host "smoke: session name $n"

# 1. auth, uncaptured, so the TOTP prompt reaches the console.
Write-Host 'Type the code from your phone at the TOTP prompt.'
$global:LASTEXITCODE = $null
& $Wrapper auth
Confirm-Step -Step '1/14 auth' -Code $LASTEXITCODE -ExpectCode 0

# Steps 2-14 run inside try/finally: if the run is interrupted (Ctrl+C) or a step throws while a
# session may exist, the finally block still prints the cleanup hint. A normal FAIL has already
# printed it (once, via Stop-Smoke); a clean run has SessionMayExist false, so nothing prints.
try {
    # A session may exist from here on, even if `new` itself fails halfway.
    $script:SessionMayExist = $true

    Invoke-Step -Step "2/14 new $n" -Words @('new', $n) -Pattern "created $e in "
    Invoke-Step -Step '3/14 ls (live row)' -Words @('ls') -Pattern "(?m)^$e\s+live"

    # 4. The dashboard's status: one JSON object that names the session. PASS only after that check.
    $statusStep = '4/14 status (JSON naming the session)'
    $global:LASTEXITCODE = $null
    $script:LastOut = & $Wrapper status | Out-String
    $statusCode = $LASTEXITCODE
    if ($statusCode -eq 0) {
        $named = $false
        try {
            $obj = $script:LastOut | ConvertFrom-Json -ErrorAction Stop
            $named = @($obj.sessions | Where-Object { $_.name -ceq $n }).Count -gt 0
        }
        catch {
            $named = $false
        }
        if (-not $named) {
            Stop-Smoke -Step $statusStep -Reason "the status output does not name $n" -Output $script:LastOut
        }
    }
    Confirm-Step -Step $statusStep -Code $statusCode -ExpectCode 0 -Output $script:LastOut

    Invoke-Step -Step "5/14 peek $n" -Words @('peek', $n)
    Invoke-Step -Step "6/14 send $n /help" -Words @('send', $n, '/help') -Pattern "sent \d+ bytes to $e"
    Invoke-Step -Step "7/14 lock $n" -Words @('lock', $n) -Pattern "locked $e"
    Invoke-Step -Step "8/14 rm $n (locked, must be refused with exit 3)" -Words @('rm', $n) -ExpectCode 3
    Invoke-Step -Step "9/14 unlock $n" -Words @('unlock', $n)
    Invoke-Step -Step "10/14 rm $n (tombstone)" -Words @('rm', $n) -Pattern "tombstoned $e;"
    Invoke-Step -Step '11/14 ls (tombstone row)' -Words @('ls') -Pattern "(?m)^zz~$e~\d+\s+tombstone"
    Invoke-Step -Step "12/14 restore $n" -Words @('restore', $n) -Pattern "restored $e"
    Invoke-Step -Step "13/14 rm $n --now --confirm $n" -Words @('rm', $n, '--now', '--confirm', $n) -Pattern "killed $e"

    # The session is gone now; a later failure has nothing to clean up.
    $script:SessionMayExist = $false

    # 14. The audit log must show every verb we used, against this session. This step does its own
    # check (instead of Invoke-Step) so that PASS is printed only after the audit lines are verified.
    $logStep = '14/14 log -n 20 (audit lines for this session)'
    $logWords = @('log', '-n', '20')
    $global:LASTEXITCODE = $null
    $script:LastOut = & $Wrapper @logWords | Out-String
    $logCode = $LASTEXITCODE
    if ($logCode -eq 0) {
        $lines = @($script:LastOut -split "\r?\n")
        $sessionKey = '"session":"' + $n + '"'
        $missing = @()
        foreach ($v in @('new', 'peek', 'send', 'lock', 'rm', 'unlock', 'restore')) {
            $verbKey = '"verb":"' + $v + '"'
            $hits = @($lines | Where-Object { $_.Contains($verbKey) -and $_.Contains($sessionKey) })
            if ($hits.Count -eq 0) { $missing += $v }
        }
        if ($missing.Count -gt 0) {
            Stop-Smoke -Step $logStep -Reason ('no audit line for session ' + $n + ' and verb: ' + ($missing -join ', ')) -Output $script:LastOut
        }
    }
    Confirm-Step -Step $logStep -Code $logCode -ExpectCode 0 -Output $script:LastOut
}
finally {
    Write-CleanupHint
}

Write-Host 'smoke: all steps passed'
exit 0
```

- [ ] **Step 6: Run the tests**

Run (Git Bash) `bash tests/run-bats.sh tests/bats/smoke.bats`, `... tests/bats/lint-laptop.bats`, `... tests/bats/lint.bats`, and the G7 command with `'tests\pester\smoke.Tests.ps1'` and `'tests\pester\static.Tests.ps1'`. Expected: all pass. (While planning, the new `smoke.ps1` passed all seven Pester tests of Step 2, and the new `smoke.sh` passed, failed at 4/14 for an empty and for a malformed status, and passed with the text fallback, against an equivalent fake wrapper.)

- [ ] **Step 7: Run every suite**

The whole bats directory (up by 2), the whole Pester folder (up by 2), the Node suite.

- [ ] **Step 8: Commit**

```bash
git add tests/smoke.sh tests/smoke.ps1 tests/bats/smoke.bats tests/pester/smoke.Tests.ps1
git commit -m "smoke: a status step whose JSON must name the smoke session"
```

---

### Task 13: CI: the `dashboard` job

Suggested model: haiku. Justification: every line to add or change is written below; if any check fails, stop and report its output.

**Files:**
- Modify: `.github/workflows/ci.yml` (append after line 57, the end of the file; header comment lines 1-2)
- Modify: `tests/bats/ci.bats` (lines 1-3, 54-61, 76-86; append)

**Interfaces:**
- Consumes: the Node suite (Tasks 5-10) and its command `node --test "dashboard/test/*.test.js"`.
- Produces: a fourth job `dashboard`, a matrix over `ubuntu-latest` and `windows-latest` (`fail-fast: false`, so one platform's failure does not hide the other's), `timeout-minutes: 20`, `actions/checkout@v4`, `actions/setup-node@v4` with `node-version: 22`, then the Node suite. The Windows leg runs under the default `pwsh` shell; the quoted pattern reaches Node unexpanded on both platforms, and Node 22 expands it. `.gitattributes` (Task 5) keeps the Windows checkout LF, which `static.test.js` requires.

- [ ] **Step 1: Write the failing checks**

In `tests/bats/ci.bats`:

Line 2 of the header comment becomes `# Static checks on .github/workflows/ci.yml (spec 9.6, 14; dashboard spec 9). The workflow itself first runs on GitHub;`.

Replace `@test "has the three jobs on the three runners"` (lines 54-61) with:

```bash
@test "has the four jobs: bats, pester and macos on their runners, and dashboard on a two-runner matrix" {
  grep -qx '  bats:' "$CI_FILE"
  grep -qx '    runs-on: ubuntu-latest' "$CI_FILE"
  grep -qx '  pester:' "$CI_FILE"
  grep -qx '    runs-on: windows-latest' "$CI_FILE"
  grep -qx '  macos:' "$CI_FILE"
  grep -qx '    runs-on: macos-latest' "$CI_FILE"
  grep -qx '  dashboard:' "$CI_FILE"
  grep -qxF '        os: [ubuntu-latest, windows-latest]' "$CI_FILE"
  grep -qxF '    runs-on: ${{ matrix.os }}' "$CI_FILE"
}
```

Replace `@test "every job has a 20 minute timeout, so a hang cannot run for the default six hours"` (lines 76-86) with:

```bash
@test "every job has a 20 minute timeout, so a hang cannot run for the default six hours" {
  [ "$(grep -c '^    timeout-minutes: 20$' "$CI_FILE")" -eq 4 ]
  local r t
  for r in ubuntu-latest windows-latest macos-latest '${{ matrix.os }}'; do
    t=$(grep -nxF "    runs-on: $r" "$CI_FILE" | cut -d: -f1)
    [ -n "$t" ] || { echo "no runs-on: $r"; return 1; }
    sed -n "$(( t + 1 ))p" "$CI_FILE" | grep -qx '    timeout-minutes: 20'
  done
}
```

Append:

```bash

@test "the dashboard job runs the Node suite on Node 22 with setup-node, with no npm install" {
  grep -qx '      - uses: actions/setup-node@v4' "$CI_FILE"
  grep -qx '          node-version: 22' "$CI_FILE"
  grep -qxF '          node --test "dashboard/test/*.test.js"' "$CI_FILE"
  grep -qx '      fail-fast: false' "$CI_FILE"
  [ "$(grep -c 'npm' "$CI_FILE")" -eq 0 ]
}
```

Run (Git Bash): `bash tests/run-bats.sh tests/bats/ci.bats`. Expected: the three changed or new tests `not ok`, the rest `ok`.

- [ ] **Step 2: Add the job**

Lines 1-2 of `.github/workflows/ci.yml` become:

```yaml
# CI for tmuxkeep (spec 9.6): bats and shellcheck in Docker on Linux, Pester under Windows
# PowerShell 5.1, the laptop suites under macOS /bin/bash 3.2, and the dashboard's Node suite.
```

Append to the end of the file (two spaces of indentation under `jobs:`, like the other jobs; no tabs):

```yaml

  dashboard:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - name: Run the dashboard tests (node:test, built-in modules only, no packages)
        run: |
          node --version
          node --test "dashboard/test/*.test.js"
```

- [ ] **Step 3: Run the checks**

Run (Git Bash): `bash tests/run-bats.sh tests/bats/ci.bats`. Expected: all `ok` (the existing checks still hold: one `permissions:` block, no `write`, three `shell: cmd`, three `powershell.exe -NoProfile`, ASCII, no tabs).

- [ ] **Step 4: Run every suite**

The whole bats directory (up by 1), the whole Pester folder, the Node suite.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml tests/bats/ci.bats
git commit -m "ci: dashboard job runs the Node suite on Ubuntu and Windows"
```

---

### Task 14: README

Suggested model: sonnet. Every new paragraph, row and line is given below; place them exactly where each step says and change nothing else.

**Files:**
- Modify: `README.md` (line numbers as at HEAD c3e8834: 10, 119-120, 233-235, 299, 412-415, after 466, after 664, 673-698, 721-743, 749, 756, 763-766, 769, 801, 825-828)

**Interfaces:**
- Consumes: the behaviour and every message of Tasks 1-13.
- Produces: the README sections the spec names (spec 3, 5, 7, 8): a `## Dashboard` section, two Configuration rows, the security addendum, the Everyday use rows for `status`, `auth --end` and `ui`, Troubleshooting rows, and the Development and tests text for the Node suite.

- [ ] **Step 1: Overview**

Line 10 becomes:

```markdown
- **One SSH round trip per command.** `tmuxkeep new`, `ls`, `peek`, `go`, `send`, `rename`, `lock`, `unlock`, `rm`, `restore`, `resume`, `log`, `auth` and `status` each make one `ssh` call. You never handle tmux by hand.
- **A local dashboard.** `tmuxkeep ui` opens a page on the laptop with every session, a live preview of its last lines and buttons for the everyday verbs, over the same key and the same gate (see "Dashboard").
```

- [ ] **Step 2: The two deploy descriptions**

In "### 5. First deploy" (Windows), item 3 (line 119) gets this sentence appended: ` It also replaces `C:\Users\you\scripts\tmuxkeep-dashboard` with a copy of the repository's `dashboard\` folder (without `test\`): the local dashboard that `tmuxkeep ui` starts.` Item 4 (line 120) becomes:

```markdown
4. Runs `ssh -o BatchMode=yes tmuxkeep ls` as proof of life and prints `deploy: proof of life exit N` (0 means the session key works), then `dashboard: installed at C:\Users\you\scripts\tmuxkeep-dashboard (run: tmuxkeep ui)` and `deploy: done. Open a new PowerShell window to load the tmuxkeep function.`
```

In the macOS and Linux "On the laptop it installs:" list, insert after the completion-script item (line 234):

```markdown
- the dashboard as `~/.local/share/tmuxkeep/dashboard` (the repository's `dashboard/` without `test/`, replaced on every deploy; the last lines of deploy say `dashboard: installed at ... (run: tmuxkeep ui)`),
```

- [ ] **Step 3: Configuration**

After the `SEND_MAX_BYTES` row of the laptop-file table (line 299) add:

```markdown
| `DASHBOARD_PORT` | `7707` | integer 1024-65535 | Loopback port of `tmuxkeep ui`; `--port` overrides it for one run. Laptop only: deploy never sends it to the VPS |
| `TERMINAL_CMD` | empty | at most 200 printable ASCII characters | Program that opens a terminal for **Attach** and **Authenticate** in the dashboard, split on single spaces with the wrapper command appended (for example `alacritty -e` or `wezterm start --`); empty picks the platform default (see "Dashboard"). A path with spaces is not supported. Laptop only |
```

- [ ] **Step 4: Everyday use**

Replace the `auth` row (line 413) with these three rows (the `status` row goes after `log`):

```markdown
| `status` | `[--follow] [--lines N]` | no | One line of JSON: the lease and OTP state for this key and address, and every session with its last N pane lines (default 12, 0-40). Not audited. With `--follow` it writes one audit line, then a new line every 2 seconds until the connection closes. The dashboard uses it | `tmuxkeep status --lines 5` |
| `auth` | `[--end]` | yes (`--end` asks no code) | Always asks for a code and starts a lease. `--end` ends the lease of this key and address at once, without a code | `tmuxkeep auth --end` |
| `ui` | `[--port N] [--no-open]` | local | Starts the dashboard on this laptop (see "Dashboard"); never sent to the VPS | `tmuxkeep ui` |
```

- [ ] **Step 5: The Dashboard section**

Insert before `## Quoting rules` (line 468), after the paragraph and code block that end the "Soft delete, tombstones, locking" subsection:

````markdown
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

- The header shows the broker version; a dot that is green while the page has a live connection to the VPS (grey otherwise: hover over it for the reason, and after 10 seconds without a connection a banner says why); the lease (`lease 23:10` counting down, `no lease`, `cooldown 4:59`, or `LOCKED`); and two buttons: **End lease** runs `tmuxkeep auth --end`, **Authenticate** opens a terminal that runs `tmuxkeep auth`.
- The sessions table: name, state, attached, age, idle time and title, as `tmuxkeep ls` shows them. Tombstones are in a collapsed group. Click a row to select it.
- The selected session shows its last 12 lines, updated every 2 seconds, and the buttons **Attach** (opens a terminal that runs `tmuxkeep go <name>`), **Lock** or **Unlock**, **Resume**, **More lines** (`peek -n 200`), **Remove** (soft delete: a tombstone) and **Send** (the text box; `Ctrl-Enter` sends). **Rename** takes the new name. **Remove now** kills the session and needs its name typed first, as the wrapper's prompt does. A tombstone has **Restore** and **Remove now**.
- **New session**: a name, an optional `https://` repository and an optional command, or **Shell only** (`new` with `--repo`, `--cmd`, `--shell`).
- **Show the last 100 audit lines** runs `log -n 100`; failures are marked.
- An action that fails shows the broker's own message and exit code; an exit 255 shows the wrapper's `ssh to host 'tmuxkeep' failed` line.

**When a verb needs a code.** If an action needs the TOTP gate and there is no lease, the page keeps the action, opens a terminal that runs `tmuxkeep auth` and says `type the code in the terminal that opened`. Type the code there. As soon as the page sees the new lease it sends the action once more by itself. Any other action, or 3 minutes without a lease, drops the waiting action. The code is never typed into the page.

**End lease.** A lease lets every gated verb through for `LEASE_SECS` (30 minutes by default) from your address, and the page can use it too. When you are done, press **End lease** (or run `tmuxkeep auth --end`): your lease ends at once, with no code, and the next gated action asks again. A shorter `LEASE_SECS` narrows the window further.

**What it costs.** While a page is open the server keeps one ssh connection running `tmuxkeep status --follow`, which writes one audit line when it starts and then sends a new snapshot every 2 seconds; if the connection drops it reconnects after 2, 4, 8 and 16 seconds and then every 30 seconds. When no page has asked for an update for 2 minutes (the tab was closed) it closes that connection, and the next page load opens it again. Each button is one ssh call, exactly like the same command typed in a terminal, and is audited like it; one action runs at a time.

**Terminals.** **Attach** and **Authenticate** open a terminal that runs the wrapper: on Windows a new Windows Terminal tab when `wt.exe` is installed, otherwise a new PowerShell console window; on macOS a Terminal window; on Linux `x-terminal-emulator`, or `$TERMINAL` when that is not installed. To use another program set `TERMINAL_CMD` in `~/.tmuxkeep/config`: it is split on single spaces and the wrapper command is appended, so `TERMINAL_CMD=alacritty -e` runs `alacritty -e ~/.local/bin/tmuxkeep go api`. A program path with spaces is not supported there.

**Limits.** One VPS per dashboard; no terminal inside the page; no HTTPS and no login on the page (it is reachable from this laptop only); no mobile layout; and the server is not a background service: it runs while `tmuxkeep ui` runs. Text with line breaks or tabs cannot be sent, because the broker refuses control characters: send one line at a time.

````

- [ ] **Step 6: The security addendum (spec 8)**

After the paragraph that ends "so step 4 is not optional when the admin key was on it." (line 664), before `## Development and tests`, insert:

```markdown

### The dashboard

- The dashboard adds one trust boundary, the browser, and nothing else: it holds no key, no secret and no code, and only runs ssh calls that the wrapper could run, encoded exactly as the wrapper encodes them, so the gate, the lease, the audit line and the exit codes stay the broker's.
- Against another web page in the same browser: the server listens on `127.0.0.1` only; every address needs the per-run token; the `Host` header must be `127.0.0.1:<port>` or `localhost:<port>` (a DNS-rebinding guard); every action is a `POST` of `application/json` whose `Origin` and `Sec-Fetch-Site`, when the browser sends them, must be this page's; no CORS header is ever sent; and a strict Content Security Policy allows only the page's own script and stylesheet. A request that fails these checks gets an empty `404` or `403`.
- Against hostile session output: everything that comes from the VPS (names, titles, pane lines, log lines, error text) is shown as plain text, never as HTML, never in an attribute or a URL; the policy forbids inline script; the VPS strips non-printable characters and cuts each line to 400 characters before it leaves.
- Worst case if the page is driven by an attacker: whatever the session key with a live lease allows, including `send` into a shell, which is command execution as `USER`. That is the same ceiling as a compromised laptop today, and it lasts until the lease ends. **End lease** closes it at once; a shorter `LEASE_SECS` narrows it.
- What stays unaudited: one-shot `tmuxkeep status`, like `ls --names`. Every `status --follow` connection leaves one audit line, so a stolen key cannot watch sessions without a trace; `auth --end` is audited.
- The token appears in your browser history and on the screen; it changes on every `tmuxkeep ui`.
- The local server writes nothing to disk: no log, no cache, no state.
```

- [ ] **Step 7: Development and tests**

In the layout block, line 673 becomes

```
.gitattributes              LF line endings for vps/, tests/, dashboard/, laptop/*.sh, laptop/completion.bash, .github/
```

line 675 becomes

```
.github/workflows/ci.yml    the four CI jobs
```

and after the `laptop/deploy.sh` line insert:

```
dashboard/server.js         tmuxkeep ui, the local dashboard server (installed next to the wrapper)
dashboard/lib/              protocol, validation, config, ssh, follow, terminal and HTTP modules
dashboard/public/           the page: index.html, app.js, style.css
dashboard/test/             node:test suites and the stand-in ssh (stub-ssh.js); not installed
```

After the paragraph that starts "Success ends with `Tests Passed: N, Failed: 0`." (line 741), insert:

````markdown

**Node (the dashboard).** Node 20 or newer; no packages. From the repository root:

```
node --test "dashboard/test/*.test.js"
```

Keep the quotes: Node expands the pattern itself on every platform (Node 21 and newer; `node --test dashboard/test` does not work, because Node then looks for a file of that name). The suites run the real modules against `dashboard/test/stub-ssh.js`, a stand-in for ssh that `TMUXKEEP_SSH` points to and a JSON script named in `TMUXKEEP_STUB_SCRIPT` drives; `TMUXKEEP_TERMINAL_DRYRUN=1` makes every terminal and browser launch return its command instead of starting it. Nothing contacts a VPS, opens a window, or listens anywhere but `127.0.0.1`. Success ends with `fail 0`; on Windows one test (SIGTERM) is reported as skipped.
````

In the CI paragraph (line 743) change `in three jobs` to `in four jobs`, and after the `macos` row (line 749) add:

```markdown
| `dashboard` | `ubuntu-latest` and `windows-latest` | Installs Node 22 with `actions/setup-node` and runs `node --test "dashboard/test/*.test.js"`: the dashboard's modules, its HTTP checks and the page's helpers, on Linux and on Windows |
```

In "How to add a test", after the *Pester* item add:

```markdown
- *Node.* Name the file `dashboard/test/<name>.test.js` (only `*.test.js` files run; `helpers.js` and `stub-ssh.js` are not tests) and use `node:test` and `node:assert/strict` only. Listen on `127.0.0.1` only, script ssh with `stubPlan` from `helpers.js`, and set `TMUXKEEP_TERMINAL_DRYRUN=1` or pass a `spawnFn` wherever a terminal or a browser could open. Every file under `dashboard/` must stay ASCII with LF line endings (`static.test.js` checks).
```

and the *Fixtures* item (line 756) gets this sentence appended: ` `b64-words` holds the encoding cases that the dashboard and both wrappers must agree on, bit for bit.`

In the line-endings paragraph (line 763) change ``` `vps/**`, `tests/**`, `laptop/*.sh` ``` to ``` `vps/**`, `tests/**`, `dashboard/**`, `laptop/*.sh` ```, and the command on line 766 becomes:

```
grep -rlIU "$(printf '\r')" vps tests dashboard laptop/*.sh laptop/completion.bash
```

In the smoke-test paragraph (line 769) replace `through a 13-step lifecycle: `auth`, `new`, `ls`, `peek`,` with `through a 14-step lifecycle: `auth`, `new`, `ls`, `status` (its JSON must name the session; checked with `jq` when `jq` is installed, otherwise as text), `peek`,`.

- [ ] **Step 8: Troubleshooting**

Insert a new subsection before `### Broker messages`:

```markdown
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
| `cannot run ssh: ENOENT` in the banner, or `tmuxkeep ui: cannot run ssh: ...` after an action | The server could not start `ssh`: it is not on the PATH of the terminal that ran `tmuxkeep ui`, or (Windows) a `send` text is too long for one command line, which needs `SEND_MAX_BYTES` above about 24000. |
| **Attach** or **Authenticate** says `no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config` | Linux without `x-terminal-emulator` and without `$TERMINAL`. Set `TERMINAL_CMD`, for example `TERMINAL_CMD=gnome-terminal --`. |
| `cannot start <program>: <reason>` after **Attach** or **Authenticate** | The terminal program could not start. Check `TERMINAL_CMD`, or empty it to use the platform default. |
| `text contains control characters (line breaks and tabs cannot be sent; send one line at a time)` | The broker types text literally and refuses control characters. Send each line on its own. |
| `another action is still running; try again in a moment` | One action runs at a time and the earlier one has not answered yet (after 30 seconds it is stopped and reported as exit 124). |
| `exit 124: tmuxkeep ui: no answer within 30 seconds; ssh was stopped` | The VPS did not answer within 30 seconds. Check the connection, or run the same verb in a terminal to see more. |
| The page keeps saying `type the code in the terminal that opened` | The new lease has not shown up: the code was not accepted, or the terminal's connection came from another address than the dashboard's (a VPN that covers one and not the other). After 3 minutes the waiting action is dropped; run it again. |

```

In "### Broker messages", in the argument-errors row (line 825) add `` `--lines must be 0-40` `` after `` `-n must be 0-9999` ``, and in the row that starts `` `cannot create state directory` `` (line 828) add `` `cannot end lease` `` after `` `cannot create otp-locked` ``.

- [ ] **Step 9: Check**

Run (Git Bash):

```bash
grep -n 'tmuxkeep ui' README.md | head -n 5
grep -c '^## Dashboard$' README.md
grep -c '^### The dashboard$' README.md
grep -c '^### Dashboard$' README.md
LC_ALL=C grep -n '[^ -~]' README.md | head -n 5
git grep -n -i -E '161[.]97|doug[c]' -- README.md
```

Expected: matches for the first; `1`, `1` and `1` for the three counts; no output from the last two (ASCII only, no personal data).

- [ ] **Step 10: Run every suite and commit**

The README is read by one existing test (`deploy.Tests.ps1`, the 255 message); run the whole Pester folder and the whole bats directory once more, then:

```bash
git add README.md
git commit -m "README: the dashboard, status, auth --end, the two config keys and the Node suite"
```

---

## After the merge (not tasks)

No implementer runs these; they are Doug's (spec 11).

1. `git pull`, then deploy once (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File laptop\deploy.ps1`, or `bash laptop/deploy.sh`): it ships the new broker and copies the dashboard. The last lines show `dashboard: installed at ...`.
2. `tmuxkeep ui`. Check by hand what no test could: the browser opens the printed address; on Windows **Attach** opens a Windows Terminal tab running `tmuxkeep go <name>` and **Authenticate** one running `tmuxkeep auth` (plan Q14: spawning the `wt.exe` alias from Node was not verified while planning, because no agent may open a window); the needs-auth flow re-sends the action after the code is typed; **End lease** shows `no lease`.
3. Run the operator smoke test once (`tests\smoke.ps1` or `bash tests/smoke.sh`): step 4 now checks `status`.
4. CI: the first push runs the new `dashboard` job on Ubuntu and Windows.

## Self-review

**1. Spec coverage.**

| Spec | Requirement | Task(s) |
|---|---|---|
| 1, D12 | Same repo, optional component in `dashboard/`, copied by deploy; a laptop without Node loses only `tmuxkeep ui` | 5-10 (files), 11 (copy), 4 (`node not found`) |
| D13 | Node 20+, built-in modules only, no `node_modules`, no build step, one HTML file, one script, one stylesheet, no framework | 5 (`package.json`, `static.test.js`), 9, 10 (version check); G23 |
| D14 | `go` and `auth` open a terminal running the wrapper; the page never sees a code | 8, 9, 10 |
| D15 | `status` JSON snapshot; `--follow` every 2 seconds over one connection; the server holds the latest snapshot; no polling of `ls`/`peek` | 1, 2, 7, 10 |
| D16 | Every button is an existing verb, encoded exactly as the wrappers encode it | 5 (protocol, shared fixture with both wrappers), 6, 9 (`words`), 10 |
| D17 | Loopback bind, per-run token, Host and Origin checks, JSON-only actions, strict CSP, text-only rendering | 10 (handler, server), 9 (rendering, grep test) |
| D18 | `auth --end` | 3; page button 9 |
| D19 | One-shot `status` unaudited; `--follow` one audit line | 1, 2 |
| 3 | Files and the "touched elsewhere" list | File map; one extra test helper `dashboard/test/helpers.js` (not a test file) |
| 4.1 | Not gated; usage errors exit 2, audited; `--lines` 0-40 default 12; options in any order; one-shot one line, no audit; `--follow` one audit line (a failed write warns and streams on), a snapshot every 2 seconds until the write fails, fresh `NOW` and tmux queries each time; keys in order via `jq -c`, ASCII-escaped; `sessions` in tmux order with tombstones; lines by the peek algorithm, filtered, cut to 400; OTP fields; lease and OTP arithmetic factored, one copy; tmux error is `[]`; no gate lock | 1 (one-shot, helpers, bounds, no lock, no server), 2 (follow) |
| 4.2 | `auth --end`: removes the lease of this key id and IP, `lease ended`, exit 0, `lease-ended`, no gate, succeeds without a lease, other arguments are usage | 3 |
| 4.3 | `status` in the usage line; `GATED_VERBS` unchanged; completion lists gain `status` and `ui` | 1 (usage, `status`), 4 (`ui`); G22 |
| 5.1 | `ui [--port N] [--no-open]` local in both wrappers, node in the foreground, its exit code, `node not found` exit 2, the two dashboard dirs | 4 |
| 5.2 | `DASHBOARD_PORT`, `TERMINAL_CMD`: defaults, rules, comment lines, after `SEND_MAX_BYTES`, missing keys default, fixtures and config tests | 11; `config.js` in 5 |
| 5.3 | Deploy removes and recreates the dashboard dir from `dashboard/` without `test/`; summary line | 11 (plan Q3, Q13) |
| 6.1 | Version check, config and `--port`, token, `127.0.0.1` only, busy port exit 1, the printed line, browser open (warning on failure), follow on first `/api/state`, SIGINT/SIGTERM exit 0 | 10 (server), 8 (browser), 7 (start on touch) |
| 6.2 | Host check then token and route, 404 empty for every method; POST checks 403 empty; body limit; security headers; CSP; no CORS; `/api/state` shape | 10 |
| 6.3 | Follow argv, NDJSON, bad lines dropped and counted, `updated`, `connected`, error text, backoff 2-4-8-16-30, reset, idle stop after 120 seconds and restart | 7, 10 |
| 6.4 | Allowlist, `auth` only as `--end`, `go`/`ui` 400, local validation of every rule, argv with no `-t`, stdin closed, 30-second timeout 124, one action at a time 409, response shape, `needs_auth`, bit-identical encoding pinned against shared fixtures, `TMUXKEEP_SSH` | 5, 6, 10 (plan Q1 for tab, Q7) |
| 6.5 | Wrapper command per platform; `TERMINAL_CMD`; Windows Terminal or detached PowerShell; osascript; `x-terminal-emulator` then `$TERMINAL`; argv with `shell: false`; dry run; response shapes | 8, 10 |
| 7 | Header, table, tombstone group, detail panel and buttons, new-session form, log panel, needs-auth flow, errors, rendering rule and its grep test, look | 9 |
| 8 | Security model addendum | 14 |
| 9 | Node tests (each item), bats tests (each item), Pester tests (each item), smoke, CI job and `ci.bats`, parity assertion | 5-10; 1-5, 11, 12, 13; 1, 4, 5, 11, 12; 12; 13; 5 |
| 10 | Out of scope | not built |
| 11 | Operator steps | "After the merge" |
| 12 | 2-second interval and 12 lines fixed; `status` not rate limited; page polls once a second; `peek` stays in the allowlist; Remove now asks the name; `TERMINAL_CMD` split on single spaces, path with spaces unsupported and the README says so | 2, 7 (`FOLLOW_WORDS`); 1; 9 (`POLL_MS`); 5; 9; 8, 14 |

No gaps found.

**2. Placeholder scan.** Searched for `TBD`, `TODO`, `implement later`, `fill in`, `similar to Task`, `appropriate` and `...`. The `...` that remain are argument notation (`[args...]`, `WORD...`), text a program prints (`dashboard: installed at ...`), JSON shape notation in Interfaces, or the README's own examples; none stands for code an implementer has to write. Every product file and test is given in full or as an exact replacement.

**3. Type and name consistency.** Checked across tasks: `lease_left`/`LEASE_LEFT`, `otp_scan`/`OTP_COUNT`/`OTP_NEWEST`, `otp_cooldown_left`/`COOLDOWN_LEFT`, `fresh_now`, `printable_only`/`PRINTABLE`, `pane_tail`, `SESSION_ROW_FORMAT`, `status_json`, `session_json` (1, 2); `sshArgs`, `encodeWord`, `SSH_PREFIX` (5, 6); `checkAction`, `checkTerminal`, `ACTION_VERBS` (5, 10, parity); `readConfig`, `configPath`, `parseArgs`, `USAGE`, `portValue` (5, 10); `runVerb`, `spawnSsh`, `sshCommand` (6, 7, 10); `createFollower`, `FOLLOW_WORDS`, `touch`, `state`, `stop` (7, 10); `openTerminal`, `openBrowser`, `terminalArgv`, `wrapperArgv` (8, 10); `createHandler`, `SERVER_OPTIONS`, `CSP`, `MAX_BODY_BYTES` (10); `stubPlan`, `waitFor`, `tempDir`, `STUB`, `DASHBOARD` (6, 7, 10); `pendingStep`, `leaseLabel`, `errorText`, `words` (9); `Install-TmuxkeepDashboard`, `tk_install_dashboard` (11); the env names in G26. The JSON keys of `status` (Task 1) are the ones `app.js` reads (Task 9): `version`, `lease_secs_left`, `otp.locked`, `otp.cooldown_secs_left`, `sessions[].name/state/tombstone_of/attached/age_secs/idle_secs/title/lines`.

**4. Review Focus.** Each of the five has its test: 1 in Tasks 5 and 10, 2 in Tasks 4, 8 and 11, 3 in Task 1, 4 in Tasks 6 and 7, 5 in Task 7 (and its README row in Task 14).

## Questions for the orchestrator

The spec is approved; D12-D19 are not reopened. Each item is a gap, a contradiction or an unimplementable detail found while planning; the plan is written against the **recommended answer**, and the cost of being wrong is named. If you decide otherwise, re-brief the named task.

**Q1. Tabs in `send` text: the spec contradicts the broker.** Spec 6.4 says "`send` text at most 65,536 bytes with no control characters except tab", but the broker's `has_ctrl` (`tr -d '\001-\037\177'`) refuses tab too, with `text contains control characters`. **Recommendation:** refuse tab locally as well, so the local check is the broker's rule (the point of 6.4: "a bad input never costs a round trip"). *Task 5.* If wrong: allowing tab only moves the refusal to the broker (exit 2, one audit line); changing the broker to accept tab would be a new broker behaviour for every client and is out of this round.

**Q2. `node --test dashboard/test` does not run the suite.** Verified on Node 24.20.0: a directory argument is taken as a module path (`Cannot find module ...\dashboard\test`, one failing pseudo-test); from Node 21 the arguments are glob patterns. Node's default discovery would also run `test/stub-ssh.js` as a test. **Recommendation:** use `node --test "dashboard/test/*.test.js"` everywhere (CI, README, `package.json`); keep the quotes so Node expands the pattern on Windows too. *Tasks 5-10, 13, 14.* If wrong: there is no working form of the spec's command on Node 22 or 24.

**Q3. "Step 3 of deploy (laptop files)" (spec 5.3).** That is the README's numbering of the Windows deploy; in both scripts the laptop-files step is step 7 (step 3 writes the ssh config). **Recommendation:** install the dashboard in step 7, right after the wrapper, with the same failure handling (fatal, exit 1, no proof of life). *Task 11.* If wrong (for example a dashboard failure should only warn, per D12's "optional"), only `Install-TmuxkeepDashboard`'s call site and one test change.

**Q4. What `dir_exists` means (spec 4.1).** Unstated. **Recommendation:** whether `<WORK_DIR>/<name>` exists, for a tombstone `<WORK_DIR>/<base name>`: the directory `resume` and `restore` would use. A renamed session reads `false`, which is exactly when `resume <name>` would not find it after a reboot. The page does not use it yet. *Task 1.* If wrong (the session's own `#{session_path}` was meant): one more tmux field per session, and a `:` in a path would need a second `list-sessions` call.

**Q5. `"user"` is the configured `USER` (spec 4.1).** **Recommendation:** `CF_USER` from `/etc/tmuxkeep/tmuxkeep.conf` (the same account the forced command runs as), not the environment's `$USER`, which local-mode tests do not control. *Task 1.*

**Q6. `status` option errors.** The spec gives one usage line. **Recommendation:** malformed options use it; an out-of-range or non-numeric `--lines` says `--lines must be 0-40`, like peek's `-n must be 0-9999`; `--lines` accepts 1-4 digits with leading zeros (`007` is 7), like `valid_count`. Both exit 2 and are audited. *Tasks 1, 2.*

**Q7. Bodies the spec does not define.** **Recommendation:** a 400 answers `{"error":"<reason>"}` (the page shows it); a 409 answers `{"error":"another action is still running"}`; `status --follow` is refused as an action (an action must end within 30 seconds); a terminal request with extra keys is 400. *Tasks 5, 10.*

**Q8. Test seams beyond the spec's two.** `TMUXKEEP_NODE_VERSION` stands in for `process.versions.node` (the version check cannot be tested otherwise: `process.versions` is read-only); `TMUXKEEP_SSH` ending in `.js` runs with the current Node (the stub cannot be executed directly on Windows); `TMUXKEEP_TERMINAL_DRYRUN=1` also covers the browser launch (so no test can open a browser); the stub's `hang` ends by itself after 20 seconds (on Windows a killed server cannot stop its follow child). Also found: Node's HTTP server answers a request without a `Host` header with its own 400 unless `requireHostHeader: false` is set; the plan sets it so the handler can answer 404 as the spec says. *Tasks 6, 8, 10; G26.*

**Q9. Where the PowerShell wrapper looks for the dashboard.** **Recommendation:** next to itself, `$PSScriptRoot\tmuxkeep-dashboard`, which is `<home>\scripts\tmuxkeep-dashboard` once deploy installs the wrapper (the spec's path), and is testable in-process (`$HOME` is read-only in PowerShell). Both wrappers also say `tmuxkeep: dashboard not installed at <dir>; run deploy again` (exit 2) instead of a Node stack trace when the folder is missing. *Task 4.*

**Q10. Cost of "exactly the peek algorithm" every 2 seconds.** `peek` captures the whole scrollback (`capture-pane -S -`), and `vps/tmux.conf` sets `history-limit 50000`; `status --follow` does that for every session every 2 seconds while a page is open. **Recommendation:** keep the exact algorithm (one shared `pane_tail`), and revisit only if the VPS shows the load; a cheaper capture (`-S -<N+height>`) differs from peek when the visible pane is mostly blank. *Task 1.*

**Q11. The rendering rule, made testable.** "Never as an attribute value" rules out a `title` tooltip for the error text on hover, so the tooltip is a child element shown by CSS on hover; the grep test also forbids `setAttribute`, `.dataset`, `.title =`, `.href`, `.src`, `srcdoc`, `javascript:`, `location` and `window.open`, so the rule cannot erode. The CSP goes on every response, not only the page (harmless, simpler to test). *Tasks 9, 10.*

**Q12. The smoke step's JSON check on a laptop without `jq` (spec 9).** macOS 15 ships `jq`, many Linux laptops do not. **Recommendation:** `smoke.sh` uses `jq -e` when `jq` is installed, else a fixed-string match of `"name":"<session>"`; `TK_SMOKE_JQ` lets the tests take the second path. The new step is 4 of 14, so every later step is renumbered. *Task 12.* If wrong (require `jq`): one branch and one test go.

**Q13. The deploy summary line.** Printed exactly as the spec gives it, `dashboard: installed at <dir> (run: tmuxkeep ui)`, without the `deploy:` prefix the other lines carry, right before `deploy: done. ...`; in the bash deploy it goes to stderr with the other status lines (stdout carries only the admin help). *Task 11.*

**Q14. Windows Terminal detection.** Verified on this laptop with Node 24: `fs.existsSync` and `fs.statSync` report the `WindowsApps\wt.exe` app-execution alias as missing (`EACCES`), `fs.lstatSync` finds it; the plan uses `lstat`. Spawning the alias from Node could not be verified (no agent may open a window), so when `wt.exe` fails to start the launcher falls back to the detached PowerShell console. Doug checks it after the merge. *Task 8.*

**Q15. Built-in modules beyond D13's list.** `node:os` (home directory), `node:url` (`fileURLToPath`) in product code, and `node:events`, `node:stream`, `node:net` in tests. **Recommendation:** allowed: D13's rule is "only built-in modules", the list reads as examples. `static.test.js` enforces `node:` specifiers only. *Tasks 5-10.*

**Q16. `TERMINAL_CMD` with two spaces in a row.** Splitting on single spaces would make empty argv elements. **Recommendation:** drop empty pieces. *Task 8.*

**Q17. How strict `config.js` is.** **Recommendation:** it validates only its two keys (with the deploy scripts' messages) and ignores every other line, including lines without `=` and a CR at a line end: the deploy scripts already refuse a bad file, and the dashboard should not refuse to start over a key it does not use. An empty `DASHBOARD_PORT=` is an error, as in deploy. *Task 5.*

**Q18. "The parity test keeps passing untouched" (spec 4.3).** True for the gated-verb test; the completer-verb test must change, because `status` is a new broker verb (Task 1) and `ui` is a completion-only word (Task 4): its rule becomes "the broker's verbs plus `ui`". *Tasks 1, 4.*

**Q19. When the page re-sends a pending action.** "When `lease_secs_left` in the next snapshots becomes positive" could fire on a stale snapshot taken before the refusal. **Recommendation:** only a snapshot read after the refusal (`updated > since`) with `lease_secs_left > 0` triggers the single re-send; a re-send that again needs a code is shown as an error, not queued again. *Task 9.*

**Q20. `auth --end` details.** It works during a cooldown and a hard lock (ending a lease is always safe), succeeds with no lease, and changes plain `auth`'s usage message to `usage: tmuxkeep auth [--end]`. It is the one verb path that does not call `authorize` (G20). *Task 3.*

**Q21. The spec's 65,536-byte `send` limit is unreachable on Windows.** Base64 makes 65,536 bytes about 87,400 characters in one argument, beyond the Windows command-line limit of 32,767 characters, for the PowerShell wrapper as much as for the dashboard; with the default `SEND_MAX_BYTES=8000` it never matters. **Recommendation:** keep the spec's limit, report the spawn failure as `code: 1` (Review Focus 4) and document the limit in Troubleshooting (about 24,000 bytes on Windows). *Tasks 6, 14.*

**Q22. Output and timeout details.** An action keeps at most 2 MiB of stdout and of stderr (a `peek -n 9999` cannot exhaust memory); a timeout appends `tmuxkeep ui: no answer within 30 seconds; ssh was stopped` to stderr, so the page's banner says what 124 means. *Task 6.*

**Q23. Task order.** The brief put deploy fifth and the HTTP server before the page; here deploy is Task 11 (it copies a `dashboard/` that must exist, and its tests run the real copy) and the page is Task 9 (the server reads the page's files at start-up), so every task leaves every suite green. *Task overview.*

**Q24. macOS Terminal is not brought to the front.** The spec's single `osascript -e 'tell application "Terminal" to do script ...'` opens the window but may leave it behind the browser. **Recommendation:** keep the spec's command; a second `-e 'tell application "Terminal" to activate'` is a one-line change if Doug wants it. *Task 8.*

**Q25. A browser that fails to open after it started.** Only a failure to start the opener (`ENOENT`) is reported; an `xdg-open` that starts and then fails is not waited for, because the server must not block on it. The printed address is always there. *Tasks 8, 10.*

## Orchestrator rulings (2026-10-14)

Recorded before execution. Each task brief carries the rulings that touch it.

- **Accepted as recommended:** Q1-Q9, Q11-Q23, Q25. The plan text already implements them.
- **Q10, changed:** `status` captures `-S -1000` (1000 history lines plus the visible pane), not `-S -`; `peek` keeps `-S -`; `pane_tail` stays the one shared algorithm. Applied in Task 1's `session_json`. Why: `status --follow` runs the capture for every session every 2 seconds and `history-limit` is 50000. Cost if wrong: one constant.
- **Q24, changed:** macOS adds `-e 'tell application "Terminal" to activate'` after the `do script` argument. Applied in Task 8's code and its two tests.
- **Execution:** tasks run strictly one at a time (no parallel lanes for Tasks 6, 8, 9, 12), in an isolated worktree on branch `dashboard`. Task reviews: Opus for Tasks 1, 7, 8, 9, 10, 11 and the final whole-branch review; Sonnet for the others.
- **Q14 and the post-merge checks** stay operator steps for Doug.
