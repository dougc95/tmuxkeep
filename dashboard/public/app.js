// app.js - the dashboard page (spec 7). One ES module. The helpers at the top touch no DOM and are
// exported for dashboard/test/app.test.js, which imports this file under Node; the code at the
// bottom runs only in a browser. Text that comes from the VPS (names, titles, pane lines, log lines,
// stderr) only ever reaches the page through textContent or createTextNode: never as markup, never
// in an attribute, never in a URL. dashboard/test/app.test.js greps this file to keep it that way.

export const POLL_MS = 1000;
export const BANNER_AFTER_MS = 10000;
export const PENDING_MS = 180000;
export const STALL_MS = 10000;
export const POLL_TIMEOUT_MS = 3000;
export const MORE_LINES = '200';
// The success notices of More lines and Show log: fixed text, never the raw last line of a pane or an
// audit entry.
export const MORE_DONE = `showing the last ${MORE_LINES} lines`;
export const LOG_DONE = 'showing the last 100 audit lines';
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

// connectionView(state, now, serverDown): the connection dot and its tooltip text, from the last
// /api/state body, the browser's own clock and whether the local server answered. The dot is green
// ({on: true}) only while the VPS follow connection is up AND its last snapshot is less than
// STALL_MS old; a connection that claims to be up but has delivered nothing for STALL_MS or more is
// grey with 'no update for N s' (N whole seconds) and stalled: true. Otherwise the reason is the
// follow error, or 'connecting' while there is none.
export function connectionView(state, now, serverDown = false) {
  if (serverDown) return { on: false, stalled: false, text: 'the local server is not running (tmuxkeep ui was stopped)' };
  if (!state || !state.connected) return { on: false, stalled: false, text: (state && state.error) || 'connecting' };
  if (typeof state.updated === 'number' && now - state.updated >= STALL_MS) {
    return { on: false, stalled: true, text: `no update for ${Math.floor((now - state.updated) / 1000)} s` };
  }
  return { on: true, stalled: false, text: 'connected' };
}

// bannerDue(view, offlineSince, now): whether the red banner shows. A stall shows it at once (the dot
// has already been silent for STALL_MS); any other loss of the connection shows it after
// BANNER_AFTER_MS, counted from offlineSince (the first moment the dot was grey).
export function bannerDue(view, offlineSince, now) {
  if (view.on) return false;
  if (view.stalled) return true;
  return offlineSince !== null && now - offlineSince >= BANNER_AFTER_MS;
}

// splitSessions(sessions): live and locked sessions first, tombstones apart, each in tmux order.
export function splitSessions(sessions) {
  const live = [];
  const tombstones = [];
  for (const s of Array.isArray(sessions) ? sessions : []) (s.state === 'tombstone' ? tombstones : live).push(s);
  return { live, tombstones };
}

// newestTombstones(sessions): the names of the tombstones that may offer Restore: for each base name
// the one with the largest epoch (compared as a number; equal epochs: the larger name), which is the
// one the broker restores whichever row was clicked. A tombstone whose name does not parse is kept.
export function newestTombstones(sessions) {
  const best = new Map();
  const keep = new Set();
  for (const s of Array.isArray(sessions) ? sessions : []) {
    if (s.state !== 'tombstone') continue;
    const m = /^zz~([a-z][a-z0-9_-]*)~([0-9]+)$/.exec(String(s.name));
    if (!m) {
      keep.add(s.name);
      continue;
    }
    const epoch = BigInt(m[2]);
    const cur = best.get(m[1]);
    if (!cur || epoch > cur.epoch || (epoch === cur.epoch && s.name > cur.name)) best.set(m[1], { epoch, name: s.name });
  }
  for (const { name } of best.values()) keep.add(name);
  return keep;
}

// rowCells(s): the six cell texts of a table row, in column order: name, state, attached marker, age,
// idle, title. Every one is a string, ready for textContent.
export function rowCells(s) {
  const text = (v) => (v === undefined || v === null ? '' : String(v));
  return [text(s.name), text(s.state), s.attached ? '*' : '', humanise(s.age_secs), humanise(s.idle_secs), text(s.title)];
}

// planRows(oldNames, newNames): how to bring a table body that holds one row per old name (in that
// order) to one row per new name (in that order) without rebuilding rows that are still wanted.
// Returns {remove, inserts}: first drop the rows in remove; then for each {name, before} in order,
// put the row of name in front of the row of before (the end when before is null), creating the
// row when it is new. A table whose names did not change in order gets no inserts at all.
export function planRows(oldNames, newNames) {
  const wanted = [...new Set(newNames)];
  const keep = new Set(wanted);
  const remove = oldNames.filter((n) => !keep.has(n));
  const current = oldNames.filter((n) => keep.has(n));
  const inserts = [];
  wanted.forEach((name, i) => {
    if (current[i] === name) return;
    const before = i < current.length ? current[i] : null;
    const from = current.indexOf(name);
    if (from !== -1) current.splice(from, 1);
    current.splice(i, 0, name);
    inserts.push({ name, before });
  });
  return { remove, inserts };
}

// lastLine(text): the last non-empty line of text, or ''.
export function lastLine(text) {
  const lines = String(text || '').split('\n').map((l) => l.replace(/\r$/, '')).filter((l) => l.trim() !== '');
  return lines.length > 0 ? lines[lines.length - 1] : '';
}

// errorText(result): the banner for a non-zero action: the exit code and the broker's stderr line, or
// for 255 the wrapper's hint followed by ssh's own last stderr line in parentheses when there is one
// (a rejected host key or key also exits 255).
export function errorText(result) {
  if (result.code === 255) {
    const why = lastLine(result.stderr);
    return why ? `exit 255: ${HINT_255} (${why})` : `exit 255: ${HINT_255}`;
  }
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

// fieldsUnchanged takes what a request sent and what the fields hold now, and says whether every
// field still holds what was sent: text compared after trimming (the requests send trimmed text),
// checkboxes as they are. The Rename and New handlers clear their fields only then, as Send does, so a
// re-send that lands minutes later cannot wipe what was typed since.
export function fieldsUnchanged(sent, current) {
  return Object.keys(sent).every((k) => (typeof sent[k] === 'string' ? String(current[k]).trim() === sent[k] : current[k] === sent[k]));
}

// actionOutcome(res, resend): what an answered action means: 'auth' (the lease is missing and this is
// the first try, so keep the action and ask for a code), 'error' (any other non-zero code, which
// includes a second refusal after a re-send), or 'ok'.
export function actionOutcome(res, resend) {
  if (res.needs_auth && !resend) return 'auth';
  return res.code === 0 ? 'ok' : 'error';
}

// createActions({call, openTerminal, notice, now}): runs the verbs and owns the one pending action
// of the needs-auth flow (spec 7). call(path, body) answers {status, data}; openTerminal(body)
// answers true when the terminal opened; notice(text, isError) shows a line. No DOM in here.
// act(words, {resend, onSuccess, done, since}) runs one verb; onSuccess(res) runs when it ends with
// code 0, and done, when given, is the fixed success notice instead of the last stdout line. A refused
// action is kept together with its onSuccess and done, so the re-send finishes exactly like the first
// try would have (clearing the box, selecting the new session). A re-send that meets 409 (another
// action still running) puts the same pending action back, with its first since, so a later tick
// tries again; it still expires after PENDING_MS, and a second needs-auth is never re-sent. since is
// only passed by tick. tick(state) is called after every state poll and returns the promise of a
// re-send, or null.
export function createActions({ call, openTerminal, notice, now = Date.now }) {
  let pending = null;

  async function act(w, { resend = false, onSuccess = null, done = null, since = null } = {}) {
    if (!resend) pending = null;
    notice(`${w[0]}...`, false);
    let r;
    try {
      r = await call('api/action', { words: w });
    } catch {
      notice('the local server did not answer', true);
      return null;
    }
    if (r.status === 409) {
      if (resend) {
        pending = { words: w, since: since ?? now(), onSuccess, done };
        notice('another action is still running; the action that needed a code will be sent again in a moment', true);
      } else {
        notice('another action is still running; try again in a moment', true);
      }
      return null;
    }
    if (r.status !== 200 || !r.data) {
      notice((r.data && r.data.error) || `refused (${r.status})`, true);
      return null;
    }
    const res = r.data;
    const outcome = actionOutcome(res, resend);
    if (outcome === 'auth') {
      pending = { words: w, since: now(), onSuccess, done };
      if (await openTerminal({ verb: 'auth' })) notice('type the code in the terminal that opened', false);
      return res;
    }
    if (outcome === 'error') {
      notice(errorText(res), true);
      return res;
    }
    notice(done ?? (lastLine(res.stdout) || 'done'), false);
    if (onSuccess) onSuccess(res);
    return res;
  }

  function tick(state) {
    const step = pendingStep(pending, state, now());
    if (step === 'expired') {
      pending = null;
      notice('the action that needed a code was dropped after 3 minutes', true);
    } else if (step === 'resend') {
      const p = pending;
      pending = null;
      return act(p.words, { resend: true, onSuccess: p.onSuccess, done: p.done, since: p.since });
    }
    return null;
  }

  return {
    act,
    tick,
    drop() {
      pending = null;
    },
    pending() {
      return pending;
    },
  };
}

// ---- browser only from here on ----

function start() {
  const $ = (id) => document.getElementById(id);
  const ui = { state: null, selected: null, offlineSince: null, serverDown: false };

  // Every per-second write goes through these three, which touch the page only when the value
  // changed: a text selection in the live preview and a click on a row are not disturbed.
  function setText(el, text) {
    if (el.textContent !== text) el.textContent = text;
  }

  function setClass(el, name) {
    if (el.className !== name) el.className = name;
  }

  function show(el, on) {
    if (el.hidden === on) el.hidden = !on;
  }

  function notice(text, isError) {
    const el = $('notice');
    setText(el, text);
    setClass(el, isError ? 'notice error' : 'notice');
    show(el, text !== '');
  }

  async function call(path, body, signal) {
    const init = body === undefined
      ? { cache: 'no-store', signal }
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

  const actions = createActions({ call, openTerminal, notice });

  // rowTable(tbody): one tr per session name, made once with its click listener and then only
  // updated in place; rows of vanished sessions are removed and the order follows the snapshot.
  function rowTable(tbody) {
    const rows = new Map();
    let order = [];

    function make(name) {
      const tr = document.createElement('tr');
      const cells = [];
      for (let i = 0; i < 6; i += 1) {
        const td = document.createElement('td');
        tr.appendChild(td);
        cells.push(td);
      }
      tr.addEventListener('click', () => select(name));
      return { tr, cells };
    }

    return {
      sync(sessions) {
        const byName = new Map();
        for (const s of sessions) byName.set(s.name, s);
        const names = [...byName.keys()];
        const plan = planRows(order, names);
        for (const name of plan.remove) {
          rows.get(name).tr.remove();
          rows.delete(name);
        }
        for (const { name, before } of plan.inserts) {
          let r = rows.get(name);
          if (!r) {
            r = make(name);
            rows.set(name, r);
          }
          tbody.insertBefore(r.tr, before === null ? null : rows.get(before).tr);
        }
        order = names;
        for (const [name, s] of byName) {
          const r = rows.get(name);
          rowCells(s).forEach((text, i) => setText(r.cells[i], text));
          setClass(r.tr, name === ui.selected ? 'selected' : '');
        }
      },
    };
  }

  const liveRows = rowTable($('session-rows'));
  const tombRows = rowTable($('tomb-rows'));

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
    const now = Date.now();
    const st = ui.state;
    const snap = st && st.snapshot;
    setText($('version'), snap ? String(snap.version) : '');
    const view = connectionView(st, now, ui.serverDown);
    setClass($('dot'), view.on ? 'dot on' : 'dot off');
    setText($('dot-tip'), view.text);
    if (view.on) ui.offlineSince = null;
    else if (ui.offlineSince === null) ui.offlineSince = now;
    const late = bannerDue(view, ui.offlineSince, now);
    setText($('banner'), late ? `not connected to the VPS: ${view.text}` : '');
    show($('banner'), late);
    const label = leaseLabel(snap, st && typeof st.updated === 'number' ? now - st.updated : 0);
    setText($('lease'), label.text);
    setClass($('lease'), `lease k-${label.kind}`);
  }

  function renderSessions() {
    const snap = ui.state && ui.state.snapshot;
    const { live, tombstones } = splitSessions(snap && snap.sessions);
    liveRows.sync(live);
    show($('empty'), snap !== null && snap !== undefined && live.length === 0);
    tombRows.sync(tombstones);
    setText($('tomb-count'), String(tombstones.length));
  }

  function renderDetail() {
    const s = current();
    show($('detail'), s !== null);
    if (!s) return;
    const tomb = s.state === 'tombstone';
    setText($('detail-name'), s.name);
    setText($('detail-lines'), Array.isArray(s.lines) ? s.lines.join('\n') : '');
    setText($('lock'), s.state === 'locked' ? 'Unlock' : 'Lock');
    for (const id of ['attach', 'lock', 'resume', 'remove', 'send-row', 'rename-row']) show($(id), !tomb);
    // Restore brings back the newest tombstone of the name, so only that row offers it.
    const snap = ui.state && ui.state.snapshot;
    show($('restore'), tomb && newestTombstones(snap && snap.sessions).has(s.name));
  }

  function render() {
    renderHeader();
    renderSessions();
    renderDetail();
  }

  // poll(): one request for the state at a time, abandoned after POLL_TIMEOUT_MS; a poll that fails
  // or times out counts as the local server being unreachable.
  let polling = false;

  async function poll() {
    if (polling) {
      render();
      return;
    }
    polling = true;
    try {
      const r = await call('api/state', undefined, AbortSignal.timeout(POLL_TIMEOUT_MS));
      ui.serverDown = r.status !== 200 || !r.data;
      if (!ui.serverDown) ui.state = r.data;
    } catch {
      ui.serverDown = true;
    } finally {
      polling = false;
    }
    render();
    actions.tick(ui.state);
  }

  function sendText() {
    const s = current();
    const text = $('send-text').value;
    if (!s || text === '') return;
    actions.act(words.send(s.name, text), {
      onSuccess() {
        if ($('send-text').value === text) $('send-text').value = '';
      },
    });
  }

  $('end-lease').addEventListener('click', () => actions.act(words.endLease()));
  $('authenticate').addEventListener('click', () => openTerminal({ verb: 'auth' }));
  $('attach').addEventListener('click', () => {
    const s = current();
    actions.drop();
    if (s) openTerminal({ verb: 'go', name: s.name });
  });
  $('lock').addEventListener('click', () => {
    const s = current();
    if (s) actions.act(s.state === 'locked' ? words.unlock(s.name) : words.lock(s.name));
  });
  $('resume').addEventListener('click', () => {
    const s = current();
    if (s) actions.act(words.resume(s.name));
  });
  $('remove').addEventListener('click', () => {
    const s = current();
    if (s) actions.act(words.remove(s.name));
  });
  $('restore').addEventListener('click', () => {
    const s = current();
    if (s && s.tombstone_of) actions.act(words.restore(s.tombstone_of));
  });
  $('more').addEventListener('click', () => {
    const s = current();
    if (!s) return;
    actions.act(words.more(s.name), {
      done: MORE_DONE,
      onSuccess(res) {
        if (ui.selected !== s.name) return;
        $('more-lines').textContent = res.stdout;
        show($('more-lines'), true);
      },
    });
  });
  $('send').addEventListener('click', sendText);
  $('send-text').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      sendText();
    }
  });
  $('rename').addEventListener('click', () => {
    const s = current();
    const to = $('rename-to').value.trim();
    if (!s || to === '') return;
    actions.act(words.rename(s.name, to), {
      onSuccess() {
        if (fieldsUnchanged({ to }, { to: $('rename-to').value })) $('rename-to').value = '';
        ui.selected = to;
      },
    });
  });
  $('remove-now').addEventListener('click', () => {
    const s = current();
    const typed = $('confirm-name').value.trim();
    if (!s) return;
    if (typed === '') {
      notice('type the session name first, exactly as shown', true);
      return;
    }
    actions.act(words.removeNow(s.name, typed), {
      onSuccess() {
        $('confirm-name').value = '';
      },
    });
  });
  $('new-form').addEventListener('submit', (e) => {
    e.preventDefault();
    const name = $('new-name').value.trim();
    if (name === '') return;
    const sent = { name, repo: $('new-repo').value.trim(), cmd: $('new-cmd').value.trim(), shell: $('new-shell').checked };
    const w = words.create(sent.name, sent.repo, sent.cmd, sent.shell);
    actions.act(w, {
      onSuccess() {
        const now = { name: $('new-name').value, repo: $('new-repo').value, cmd: $('new-cmd').value, shell: $('new-shell').checked };
        if (fieldsUnchanged(sent, now)) {
          for (const id of ['new-name', 'new-repo', 'new-cmd']) $(id).value = '';
          $('new-shell').checked = false;
        }
        ui.selected = name;
      },
    });
  });
  $('log-button').addEventListener('click', () => {
    actions.act(words.log(), {
      done: LOG_DONE,
      onSuccess(res) {
        const items = logEntries(res.stdout).map((entry) => {
          const li = document.createElement('li');
          li.textContent = entry.text;
          if (entry.failed) li.className = 'fail';
          return li;
        });
        $('log-lines').replaceChildren(...items);
      },
    });
  });

  setInterval(poll, POLL_MS);
  poll();
}

if (typeof document !== 'undefined') start();
