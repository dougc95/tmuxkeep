# tmuxkeep dashboard: design

Date: 2026-10-14. Status: draft for Doug's review. Builds on the v1 spec
(`2026-10-09-sesh-session-broker-design.md`) and the v1.1 public release spec
(`2026-10-12-tmuxkeep-public-release-design.md`); their decisions D1-D11 stay in force.

## 1. Goal

A local web page on the laptop that shows every tmuxkeep session with a live preview of
what it is doing, and offers buttons for the everyday verbs, so that managing sessions
no longer means typing verbs and names. It must not weaken any security property of
tmuxkeep: the session key stays the only path to the VPS, the TOTP code is only ever
typed into a real terminal, and the audit log keeps its meaning.

## 2. Decisions (D12-D19, made with Doug 2026-10-14; do not relitigate)

- **D12 Same repo, optional component.** The dashboard lives in `dashboard/` of the
  tmuxkeep repo and is copied to the laptop by deploy. Nothing else in tmuxkeep depends
  on it; a laptop without Node loses only `tmuxkeep ui`.
- **D13 Node, no packages.** The local server runs on Node 20 or newer using only
  built-in modules (`node:http`, `node:child_process`, `node:crypto`, `node:fs`,
  `node:path`, `node:test`). No `node_modules`, no build step, no bundler. The page is
  one HTML file, one script, one stylesheet, no framework.
- **D14 Attach in a terminal tab.** `go` and `auth` open a terminal window or tab that
  runs the existing wrapper. The page never hosts a terminal and never sees a TOTP code.
- **D15 Data over one connection.** A new read-only broker verb `status` returns a JSON
  snapshot; with `--follow` it keeps emitting snapshots every 2 seconds over one ssh
  connection. The local server holds the latest snapshot and the page reads it locally.
  No polling of `ls`/`peek` (both are audited and each poll would be a new ssh login).
- **D16 Actions reuse the audited verbs unchanged.** Every button maps to an existing
  verb call over ssh, encoded exactly as the wrappers encode it. The gate, the lease,
  the audit line and the exit codes are the broker's; the dashboard adds no bypass.
- **D17 Browser is a trust boundary.** Loopback bind, per-run random token in the URL,
  Host and Origin checks, JSON-only actions, a strict Content Security Policy, and
  text-only rendering of everything that comes from the VPS. Session output is untrusted
  input (section 7).
- **D18 `auth --end`.** The broker gains a way to end the caller's lease early, so the
  exposure window after using the dashboard can be closed with one click.
- **D19 Unaudited reads, audited connections.** One-shot `status` writes no audit line
  (like `ls --names`). `status --follow` writes exactly one line when the stream starts,
  none per snapshot, so a stolen key cannot watch sessions without leaving a trace.

## 3. Components and files

```
dashboard/
  server.js          entry point: args, config, token, http server, follow loop, shutdown
  lib/config.js      reads ~/.tmuxkeep/config (KEY=value, LF), returns the two keys it needs
  lib/protocol.js    words -> ssh argv (b64 encoding identical to laptop/tmuxkeep.ps1 and .sh)
  lib/ssh.js         runs one verb (spawn, timeout, exit code, stdout, stderr, needs_auth)
  lib/follow.js      the status --follow child: NDJSON parsing, reconnect with backoff, idle stop
  lib/terminal.js    opens a terminal tab per platform, or per TERMINAL_CMD
  lib/http.js        routing, token/Host/Origin/Content-Type checks, security headers, static files
  lib/validate.js    name, tombstone, repo URL, cmd text, send text, count checks
  public/index.html  the page skeleton (no inline script, no inline style)
  public/app.js      state polling, rendering with textContent only, actions, needs-auth retry
  public/style.css   plain, system font, light and dark via prefers-color-scheme
  test/*.test.js     node:test suites with a stub ssh and a dry-run terminal launcher
  test/stub-ssh.js   the stub: scripted by a fixture file named in TMUXKEEP_STUB_SCRIPT
```

Touched elsewhere: `vps/tmuxkeep` (verbs `status`, `auth --end`), `laptop/tmuxkeep.ps1`
and `laptop/tmuxkeep.sh` (local verb `ui`), `laptop/profile-snippet.ps1` and
`laptop/completion.bash` (verb lists), `laptop/deploy.ps1` and `laptop/deploy.sh`
(config keys, copy of `dashboard/`), `tests/fixtures/laptop-config` and the config
fixtures, `tests/smoke.sh`/`tests/smoke.ps1` (one `status` call), `.github/workflows/ci.yml`
(a `dashboard` job), `README.md` (sections 5 and 7 of this spec).

## 4. Broker changes (`vps/tmuxkeep`)

### 4.1 `status [--follow] [--lines N]`

- Not gated (not in `GATED_VERBS`); allowed remotely; usage errors exit 2 and are
  audited like `ls` usage errors (main turns auditing off for `status` the way it does
  for `ls --names`, and the usage path turns it back on).
- `--lines N`: 0-40, default 12. Options in any order; anything else is a usage error:
  `usage: tmuxkeep status [--follow] [--lines N]`.
- One-shot: prints exactly one JSON object on one line and exits 0. No audit line.
- `--follow`: re-enables auditing for one write and writes one audit line first
  (`verb: status`, `ok: true`, `detail: follow lines=N`; a failed write prints the usual
  `audit write failed` warning and the stream still runs), then prints one JSON object
  per line every 2 seconds
  until writing stdout fails (client gone: SIGPIPE or EPIPE ends the loop), and never
  otherwise. Each snapshot is produced fresh (new `NOW`, new tmux queries).
- The object (keys in this order, produced with `jq -c` so escaping is correct; all
  strings ASCII-escaped like the audit log):

  ```
  {"version":"<TMUXKEEP_VERSION>","now":"<UTC ISO-8601>","user":"<USER>",
   "lease_secs_left":<int>,            0 when no valid lease for this key id and client IP
   "lease_secs":<LEASE_SECS>,
   "otp":{"locked":<bool>,"fails":<int>,"cooldown_secs_left":<int>},
   "lines":<N>,
   "sessions":[
     {"name":"api","state":"live|locked|tombstone","tombstone_of":"<base>"|null,
      "attached":<bool>,"age_secs":<int>,"idle_secs":<int>,"title":"<cleaned, max 40>",
      "dir_exists":<bool>,"lines":["...","..."]}
   ]}
  ```

  `sessions` is ordered like `ls` (tmux order), tombstones included with their base
  name in `tombstone_of`. `lines` per session are the last N lines of the pane with
  trailing blank lines dropped, exactly the `peek` algorithm, each line passed through
  `clean_title`'s character filter (non-printables removed) and cut to 400 characters.
  `otp.fails` is the number of entries in `otp-fails` inside `OTP_FAIL_WINDOW`;
  `cooldown_secs_left` is the seconds until the cooldown that those entries imply ends,
  0 when none; `locked` mirrors the `otp-locked` marker. The lease and OTP arithmetic
  reuse the gate's helpers; the plan must factor them so there is one copy.
- A tmux error or no server yields `"sessions":[]` (consistent with the known `ls`
  limitation). The gate lock is not taken: `status` only reads.

### 4.2 `auth --end`

- `auth` keeps its current behaviour with no arguments. `auth --end` removes the lease
  file for the caller's key id and client IP, prints `lease ended`, exits 0, audit
  `detail: lease-ended`. It does not take the gate (ending a lease needs no code) and
  succeeds when no lease exists. Any other argument is a usage error.

### 4.3 Lists

`status` joins the usage line in `main`. It is not gated, so `GATED_VERBS` in the broker
and both wrappers are unchanged and the parity test keeps passing untouched. Completion
lists in `profile-snippet.ps1` and `completion.bash` gain `status` and `ui`.

## 5. Laptop changes

### 5.1 The `ui` verb (local only)

`tmuxkeep ui [--port N] [--no-open]` is handled by both wrappers before anything is
sent: it never reaches the broker (a remote `ui` would be `unknown verb`). It runs
`node <dashboard dir>/server.js [--port N] [--no-open]` in the foreground with the
console attached, and exits with the server's exit code. If `node` is not on PATH:
`tmuxkeep: node not found; install Node 20 or newer to use the dashboard`, exit 2.
Dashboard dir: `<home>\scripts\tmuxkeep-dashboard` on Windows,
`~/.local/share/tmuxkeep/dashboard` elsewhere.

### 5.2 Config keys (laptop only, never in `deploy.conf`)

| Key | Default | Rule | Comment line written by -Init |
|---|---|---|---|
| `DASHBOARD_PORT` | `7707` | integer 1024-65535 | `Loopback port for tmuxkeep ui (1024-65535).` |
| `TERMINAL_CMD` | empty | at most 200 printable ASCII characters | `Program that opens a terminal for go and auth; empty picks the platform default.` |

Both deploy scripts add the keys to their key lists, validators and writers, after
`SEND_MAX_BYTES`. A config file that lacks them is valid and gets the defaults (the plan
verifies that missing keys already default in both readers, and adds that behaviour if
not). The fixtures `tests/fixtures/laptop-config` and the config tests change
accordingly.

### 5.3 Deploy

Step 3 of deploy (laptop files) also removes and recreates the dashboard dir and copies
`dashboard/` into it without `test/`. Deploy's summary prints one line:
`dashboard: installed at <dir> (run: tmuxkeep ui)`. Nothing changes for the VPS side
beyond the broker file, which deploy already ships.

## 6. The local server

### 6.1 Start-up and shutdown

1. Checks `process.versions.node` major >= 20, else prints
   `tmuxkeep ui: Node 20 or newer is required (found <v>)` and exits 2.
2. Reads `~/.tmuxkeep/config` for `DASHBOARD_PORT` and `TERMINAL_CMD` (other keys
   ignored, file optional); `--port` overrides the key.
3. Generates a 32-hex-character token with `crypto.randomBytes(16)`.
4. Listens on `127.0.0.1` only (IPv4 loopback, never `0.0.0.0`, never `::`). A busy port
   is an error: `tmuxkeep ui: port 7707 is in use; set DASHBOARD_PORT or pass --port`,
   exit 1.
5. Prints `tmuxkeep ui: http://127.0.0.1:7707/<token>/  (Ctrl-C stops)` and opens that
   URL unless `--no-open` (Windows: `cmd.exe /c start "" <url>`; macOS: `open <url>`;
   Linux: `xdg-open <url>`; a failure to open is a warning, not an error).
6. Starts the follow connection (6.3) on the first `/api/state` request, not before.
7. SIGINT/SIGTERM: kills the follow child, closes the server, exits 0.

### 6.2 Routes

Checks run in this order for every request: first the `Host` header must be
`127.0.0.1:<port>` or `localhost:<port>` (DNS rebinding guard), then the path must begin
with `/<token>/` and name a listed route. Either failure is `404` with an empty body,
for every method, before anything else happens.

| Method | Path | Does |
|---|---|---|
| GET | `/` | `index.html` |
| GET | `/app.js`, `/style.css` | static files |
| GET | `/api/state` | `{"snapshot":<last status object or null>,"connected":<bool>,"updated":<ms epoch or null>,"error":<string or null>}` |
| POST | `/api/action` | body `{"words":["send","api","run the tests"]}`; runs one verb (6.4) |
| POST | `/api/terminal` | body `{"verb":"go","name":"api"}` or `{"verb":"auth"}`; opens a terminal (6.5) |

POST requirements, each failing with `403` empty body: `Content-Type` is
`application/json`; `Origin`, when present, equals `http://127.0.0.1:<port>` or
`http://localhost:<port>`; `Sec-Fetch-Site`, when present, is `same-origin` or `none`;
body at most 70,000 bytes and valid JSON. Every response carries
`Cache-Control: no-store`, `X-Content-Type-Options: nosniff`,
`Referrer-Policy: no-referrer`, and the page carries
`Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self';
connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none';
frame-ancestors 'none'`. No CORS header is ever sent.

### 6.3 The follow connection

`ssh -o BatchMode=yes -o ConnectTimeout=5 tmuxkeep b64 <status> <--follow> <--lines> <12>`
as a child process, stdout parsed line by line as JSON; an unparsable line is dropped
and counted. Each parsed object replaces the snapshot and sets `updated`. When the child
exits: `connected=false`, `error` is the last stderr line (or
`ssh exited 255: VPS unreachable` for 255), and it restarts after 2, 4, 8, 16, 30, 30...
seconds, reset to 2 after a successful object. Idle stop: when no `/api/state` request
has arrived for 120 seconds the child is killed and `connected=false`; the next request
starts it again (so a closed tab does not keep an ssh session open all day).

### 6.4 Actions

`words` must be a non-empty array of strings. `words[0]` must be in the allowlist
`new send rename lock unlock rm restore resume log peek status auth`, and `auth` is
allowed only as exactly `["auth","--end"]`. `go` and `ui` are refused (`400`). Before
spawning, `validate.js` applies the broker's rules locally so a bad input never costs a
round trip: names `^[a-z][a-z0-9_-]{0,31}$` (tombstone names `^zz~...~[0-9]+$` only
where the broker accepts them: `peek`, `rm --now`), repo URL `https://` only, `--cmd`
text at most 200 printable ASCII characters, `send` text at most 65,536 bytes with no
control characters except tab, `-n` 0-9999, `--lines` 0-40. Then it runs
`ssh -o BatchMode=yes -o ConnectTimeout=5 tmuxkeep b64 <tokens>` with no `-t`, stdin
closed, a 30-second timeout (kill, `code: 124`), one action at a time (a second request
while one runs gets `409`). Response `{"code":<int>,"stdout":"...","stderr":"...",
"needs_auth":<bool>}` where `needs_auth` is `code == 4` and stderr contains
`TOTP required`. The encoding of words is bit-identical to the wrappers (standard
base64 of UTF-8, padded); a test pins it against fixtures shared with the bats and
Pester wrapper tests. `TMUXKEEP_SSH` (path) replaces the `ssh` program for tests.

### 6.5 Terminal launch

`verb` is `go` (with a validated `name`) or `auth` (no name). The command run in the
terminal is the wrapper: `<home>\scripts\tmuxkeep.ps1 go api` via
`powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File ...` on Windows,
`~/.local/bin/tmuxkeep go api` elsewhere. Launcher, in order:

1. `TERMINAL_CMD` set: split on single spaces into argv, append the wrapper command's
   words as further argv elements (no shell, no quoting). Example
   `TERMINAL_CMD=alacritty -e`.
2. Windows: `wt.exe -w 0 new-tab --title "tmuxkeep go api" powershell.exe ...` when
   `wt.exe` resolves on PATH; otherwise `powershell.exe ...` spawned detached, which gets
   its own console window.
3. macOS: `osascript -e 'tell application "Terminal" to do script "<cmd>"'` where
   `<cmd>` is the wrapper path and words, each single-quoted for sh (names are already
   validated, the path is quoted).
4. Linux: `x-terminal-emulator -e <wrapper> <verb> [<name>]`, falling back to
   `$TERMINAL -e ...` when set.

Every spawn is an argv array with `shell: false`. `TMUXKEEP_TERMINAL_DRYRUN=1` makes
`terminal.js` return the argv instead of spawning, for tests. Response
`{"ok":true,"argv":[...]}` or `{"ok":false,"error":"..."}` (`500`).

## 7. The page

- **Header:** `tmuxkeep` plus the broker version, a connection dot (green connected,
  grey reconnecting with the error text on hover and in a banner after 10 seconds),
  the lease: `lease 23:10` counting down, `no lease`, `cooldown 4:59`, or `LOCKED`, an
  **End lease** button (sends `auth --end`) and **Authenticate** (opens the auth
  terminal).
- **Sessions table:** name, state, attached mark, age, idle, title; tombstones in a
  collapsed group with **Restore**. Clicking a row selects it.
- **Detail panel for the selected session:** the last lines in a monospace block that
  updates in place; buttons **Attach** (terminal), **Send** (textarea, Ctrl-Enter or
  button), **Rename**, **Lock/Unlock**, **Resume**, **Remove** (tombstone) and
  **Remove now** (asks the name to be typed, sends `rm <name> --now --confirm <name>`).
- **New session form:** name, optional https repo URL, optional command or "shell only".
- **Log panel:** last 100 audit lines on demand (`log -n 100`), one line per entry,
  failures highlighted.
- **Needs-auth flow:** when an action returns `needs_auth`, the page keeps the action
  as pending, opens the auth terminal, shows `type the code in the terminal that
  opened`, and when `lease_secs_left` in the next snapshots becomes positive it re-sends
  the pending action once. Pending is cleared on any other action or after 3 minutes.
- **Errors:** every non-zero action shows the broker's stderr line verbatim in a banner
  with the exit code; 255 shows the wrapper's hint text.
- **Rendering rule:** everything that originates on the VPS (names, titles, lines, log
  lines, stderr) is put in the DOM with `textContent` or `createTextNode`, never
  `innerHTML`, never as an attribute value, never in a URL. A test greps `app.js` for
  `innerHTML`, `insertAdjacentHTML`, `outerHTML`, `document.write`, `eval(` and
  `new Function` and fails on any hit.
- **Look:** system font stack, no icons, no web fonts, no external requests (the CSP
  forbids them), light and dark by `prefers-color-scheme`, usable at 900 px wide.

## 8. Security model (README addendum)

- The dashboard adds one trust boundary, the browser, and nothing else: it holds no
  key, no secret and no code, and only runs ssh calls that the wrapper could run.
- Against another web page: loopback bind, per-run token in the URL, Host check
  (rebinding), Origin and Sec-Fetch-Site checks, JSON-only posts, no CORS, strict CSP.
- Against hostile session output: text-only rendering, CSP without inline script,
  non-printables stripped on the VPS, 400-character line cap.
- Worst case if the page is driven by an attacker: what the session key with a live
  lease allows, including `send` into a shell, which is command execution as `USER`.
  That is the same ceiling as a compromised laptop today and lasts until the lease ends.
  **End lease** closes it; a shorter `LEASE_SECS` narrows it.
- What stays unaudited: one-shot `status`. Every `status --follow` connection leaves one
  audit line. `auth --end` is audited.
- The token appears in browser history and on screen; it changes on every `tmuxkeep ui`.
- The local server logs nothing to disk.

## 9. Tests and CI

- **Node (`node --test dashboard/test`), all offline, ssh replaced by `TMUXKEEP_SSH`:**
  token, Host, Origin, Content-Type and method enforcement (each wrong case is `404` or
  `403` with an empty body and no side effect); security headers present; static files
  served; `/api/state` before and after snapshots; follow parsing, reconnect backoff
  sequence, bad-line tolerance, idle stop and restart; action allowlist (including the
  `auth` exception and `go` refusal), every validator rule, the b64 encoding against the
  shared fixtures, timeout to `124`, `409` on overlap, `needs_auth` detection; terminal
  argv per platform and per `TERMINAL_CMD` in dry-run mode; config reader with missing
  file, missing keys, bad values; the `app.js` forbidden-API grep; Node version check.
- **bats (Docker harness):** `status` one-shot JSON shape with live, locked and
  tombstone sessions, `--lines` bounds, no audit line; `--follow` writes one audit line,
  emits at least two objects, ends when the reader closes; `auth --end` with and without
  a lease; usage errors; `jq` validity of every object; completion lists include
  `status` and `ui`; the `ui` verb in `tmuxkeep.sh` never calls ssh and reports a missing
  `node`; deploy.sh copies the dashboard and validates the new keys.
- **Pester:** `ui` in `tmuxkeep.ps1` never calls ssh and reports a missing `node`;
  deploy.ps1 copies the dashboard, validates the new keys, writes their comment lines;
  the profile completer lists the new verbs.
- **Smoke tests:** one `status` call whose output parses with `jq`/`ConvertFrom-Json`
  and names the smoke session.
- **CI:** a `dashboard` job, matrix `ubuntu-latest` and `windows-latest`,
  `actions/setup-node@v4` with Node 22, `node --test dashboard/test`, `timeout-minutes:
  20`. `ci.bats` asserts the job and its timeout.
- The existing parity test gains one assertion: the server's action allowlist is a
  subset of the broker's verb functions.

## 10. Out of scope (later rounds, each its own spec)

A terminal inside the browser; event-driven updates (tmux hooks) instead of the
2-second loop; more than one VPS per dashboard; HTTPS or any login on the page; a
mobile layout; running the server as a service.

## 11. Operator steps after the merge

1. `git pull`, then deploy once: it ships the new broker and copies the dashboard.
2. `tmuxkeep ui`, then use the page. `End lease` when done.

## 12. Rulings made during design (for the plan writer)

- The 2-second follow interval and the 12-line default are fixed in this round; no config
  keys for them.
- `status` is not rate limited: only the key holder can call it.
- The page polls the local server once a second; the follow child is the only VPS
  connection the dashboard keeps.
- `peek` stays in the action allowlist for an on-demand "more lines" button, even though
  the preview comes from `status`.
- The in-page "Remove now" asks for the name to be typed, mirroring the wrapper's local
  prompt, so a misclick cannot kill a session.
- `TERMINAL_CMD` is split on single spaces with no quoting support; a path with spaces
  is not supported in this round and the README says so.
