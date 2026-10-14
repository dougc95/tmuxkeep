// app.js - the dashboard page (spec 7). One ES module. The helpers at the top touch no DOM and are
// exported for dashboard/test/app.test.js, which imports this file under Node; the code at the
// bottom runs only in a browser. Text that comes from the VPS (names, titles, pane lines, log lines,
// stderr) only ever reaches the page through textContent or createTextNode: never as markup, never
// in an attribute, never in a URL. dashboard/test/app.test.js greps this file to keep it that way.

export const POLL_MS = 1000;
export const BANNER_AFTER_MS = 10000;
export const PENDING_MS = 180000;
export const STALL_MS = 10000;
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

// connectionView(state, now, serverDown): the connection dot and its tooltip text, from the last
// /api/state body, the browser's own clock and whether the local server answered. The dot is green
// ({on: true}) only while the VPS follow connection is up AND its last snapshot is less than
// STALL_MS old; a connection that claims to be up but has delivered nothing for STALL_MS or more is
// grey with 'no update for N s' (N whole seconds). Otherwise the reason is the follow error, or
// 'connecting' while there is none.
export function connectionView(state, now, serverDown = false) {
  if (serverDown) return { on: false, text: 'the local server is not running (tmuxkeep ui was stopped)' };
  if (!state || !state.connected) return { on: false, text: (state && state.error) || 'connecting' };
  if (typeof state.updated === 'number' && now - state.updated >= STALL_MS) {
    return { on: false, text: `no update for ${Math.floor((now - state.updated) / 1000)} s` };
  }
  return { on: true, text: 'connected' };
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
    const view = connectionView(st, Date.now(), ui.serverDown);
    const connected = view.on;
    $('dot').className = connected ? 'dot on' : 'dot off';
    $('dot-tip').textContent = view.text;
    if (connected) ui.offlineSince = null;
    else if (ui.offlineSince === null) ui.offlineSince = Date.now();
    const banner = $('banner');
    const late = !connected && ui.offlineSince !== null && Date.now() - ui.offlineSince >= BANNER_AFTER_MS;
    banner.textContent = late ? `not connected to the VPS: ${view.text}` : '';
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
