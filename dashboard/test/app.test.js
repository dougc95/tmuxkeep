import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  actionOutcome, BANNER_AFTER_MS, bannerDue, clock, connectionView, createActions, errorText, HINT_255, humanise, lastLine, leaseLabel,
  logEntries, PENDING_MS, pendingStep, planRows, POLL_TIMEOUT_MS, rowCells, splitSessions, STALL_MS, words,
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

test('the connection dot is green only for a fresh connection; a stalled one is grey and says how long (stall rule)', () => {
  const now = 5000000;
  const live = (age) => ({ snapshot: { version: '1' }, connected: true, updated: now - age, error: null });
  assert.equal(STALL_MS, 10000);
  assert.deepEqual(connectionView(live(0), now, false), { on: true, stalled: false, text: 'connected' });
  assert.deepEqual(connectionView(live(2000), now, false), { on: true, stalled: false, text: 'connected' });
  assert.deepEqual(connectionView(live(9999), now, false), { on: true, stalled: false, text: 'connected' });
  assert.deepEqual(connectionView(live(10000), now, false), { on: false, stalled: true, text: 'no update for 10 s' });
  assert.deepEqual(connectionView(live(10999), now, false), { on: false, stalled: true, text: 'no update for 10 s' });
  assert.deepEqual(connectionView(live(95400), now, false), { on: false, stalled: true, text: 'no update for 95 s' });
});

test('the connection dot for a dropped connection or a stopped local server is unchanged by the stall rule', () => {
  const now = 5000000;
  const down = (updated, error) => ({ snapshot: null, connected: false, updated, error });
  const off = (text) => ({ on: false, stalled: false, text });
  assert.deepEqual(connectionView(down(null, 'ssh exited 255: VPS unreachable'), now, false), off('ssh exited 255: VPS unreachable'));
  assert.deepEqual(connectionView(down(null, null), now, false), off('connecting'));
  assert.deepEqual(connectionView(null, now, false), off('connecting'));
  assert.deepEqual(connectionView(down(now - 60000, 'ssh exited 255: VPS unreachable'), now, false), off('ssh exited 255: VPS unreachable'));
  const stopped = connectionView({ snapshot: {}, connected: true, updated: now, error: null }, now, true);
  assert.deepEqual(stopped, off('the local server is not running (tmuxkeep ui was stopped)'));
});

test('the banner: at once for a stall; after 10 seconds grey for any other loss; never while connected', () => {
  const now = 5000000;
  const live = { snapshot: {}, connected: true, updated: now - 1000, error: null };
  const stalled = { snapshot: {}, connected: true, updated: now - 10000, error: null };
  const dropped = { snapshot: null, connected: false, updated: null, error: 'ssh exited 255: VPS unreachable' };
  assert.equal(BANNER_AFTER_MS, 10000);
  assert.equal(bannerDue(connectionView(live, now, false), null, now), false);
  assert.equal(bannerDue(connectionView(stalled, now, false), now, now), true);
  assert.equal(bannerDue(connectionView(dropped, now, false), now, now), false);
  assert.equal(bannerDue(connectionView(dropped, now, false), now - 9999, now), false);
  assert.equal(bannerDue(connectionView(dropped, now, false), now - 10000, now), true);
  assert.equal(bannerDue(connectionView(dropped, now, true), now - 10000, now), true);
  assert.equal(bannerDue(connectionView(dropped, now, false), null, now), false);
});

test('a table row is six strings, whatever the snapshot holds', () => {
  assert.deepEqual(rowCells({ name: 'api', state: 'live', attached: true, age_secs: 3700, idle_secs: 4, title: 'build' }),
    ['api', 'live', '*', '1h', '4s', 'build']);
  assert.deepEqual(rowCells({ name: 'web', state: 'locked', attached: false }), ['web', 'locked', '', '0s', '0s', '']);
  assert.deepEqual(rowCells({ name: 'x', state: 'live', title: null }), ['x', 'live', '', '0s', '0s', '']);
});

// applyPlan: what start() does to the rows of one table body, on a plain array of names.
function applyPlan(order, plan) {
  const list = order.filter((n) => !plan.remove.includes(n));
  for (const { name, before } of plan.inserts) {
    const at = list.indexOf(name);
    if (at !== -1) list.splice(at, 1);
    if (before === null) list.push(name);
    else list.splice(list.indexOf(before), 0, name);
  }
  return list;
}

test('row plan: rows still wanted are kept; nothing moves when the order did not change', () => {
  assert.deepEqual(planRows([], []), { remove: [], inserts: [] });
  assert.deepEqual(planRows(['a', 'b', 'c'], ['a', 'b', 'c']), { remove: [], inserts: [] });
  assert.deepEqual(planRows(['a', 'b'], ['a', 'b', 'c']), { remove: [], inserts: [{ name: 'c', before: null }] });
  assert.deepEqual(planRows(['a', 'c'], ['a', 'b', 'c']), { remove: [], inserts: [{ name: 'b', before: 'c' }] });
  assert.deepEqual(planRows([], ['a', 'b']), { remove: [], inserts: [{ name: 'a', before: null }, { name: 'b', before: null }] });
  assert.deepEqual(planRows(['a', 'b', 'c'], ['a', 'c']), { remove: ['b'], inserts: [] });
  assert.deepEqual(planRows(['a', 'b'], []), { remove: ['a', 'b'], inserts: [] });
  assert.deepEqual(planRows(['a', 'b', 'c'], ['b', 'c', 'a']).remove, []);
  assert.deepEqual(planRows(['a'], ['a', 'a']), { remove: [], inserts: [] });
});

test('row plan: applying it always yields the new order (every small reordering, with adds and removals)', () => {
  const pool = ['a', 'b', 'c', 'd'];
  const subsets = [];
  for (let mask = 0; mask < 16; mask += 1) subsets.push(pool.filter((_, i) => mask & (1 << i)));
  const orders = (items) => (items.length <= 1 ? [items] : items.flatMap((x, i) => orders([...items.slice(0, i), ...items.slice(i + 1)]).map((r) => [x, ...r])));
  let checked = 0;
  for (const before of subsets) {
    for (const after of subsets.flatMap(orders)) {
      const plan = planRows(before, after);
      assert.deepEqual(applyPlan(before, plan), after, `${before} -> ${after}`);
      if (before.join() === after.join()) assert.equal(plan.inserts.length, 0, `${before} did not change`);
      checked += 1;
    }
  }
  assert.ok(checked > 1000);
});

test('an action answers ok, error, or auth (auth only on the first try)', () => {
  assert.equal(actionOutcome({ code: 0, needs_auth: false }, false), 'ok');
  assert.equal(actionOutcome({ code: 3, needs_auth: false }, false), 'error');
  assert.equal(actionOutcome({ code: 4, needs_auth: true }, false), 'auth');
  assert.equal(actionOutcome({ code: 4, needs_auth: true }, true), 'error');
});

// A fake of everything createActions needs from the page.
function rig(answers) {
  const r = { calls: [], notices: [], terminals: [], clockNow: 1000000, success: [] };
  const queue = [...answers];
  const actions = createActions({
    call: async (path, body) => {
      r.calls.push([path, body]);
      const next = queue.shift();
      if (next instanceof Error) throw next;
      return next;
    },
    openTerminal: async (body) => {
      r.terminals.push(body);
      return true;
    },
    notice: (text, isError) => r.notices.push([text, isError]),
    now: () => r.clockNow,
  });
  r.actions = actions;
  r.onSuccess = (res) => r.success.push(res.stdout);
  return r;
}

const OK = (stdout = '') => ({ status: 200, data: { code: 0, stdout, stderr: '', needs_auth: false } });
const NEEDS_AUTH = { status: 200, data: { code: 4, stdout: '', stderr: 'tmuxkeep: authentication required\n', needs_auth: true } };
const withLease = (updated) => ({ snapshot: { lease_secs_left: 1800 }, updated });

test('a refused send keeps its success handler: after the code, the re-send clears the box, once', async () => {
  const r = rig([NEEDS_AUTH, OK('sent\n')]);
  const first = await r.actions.act(['send', 'api', 'run the tests'], { onSuccess: r.onSuccess });
  assert.equal(first.needs_auth, true);
  assert.deepEqual(r.success, [], 'not finished yet');
  assert.deepEqual(r.terminals, [{ verb: 'auth' }]);
  assert.deepEqual(r.notices.at(-1), ['type the code in the terminal that opened', false]);
  assert.deepEqual(r.actions.pending().words, ['send', 'api', 'run the tests']);
  // no lease yet, or only a snapshot read before the refusal: nothing happens
  assert.equal(r.actions.tick({ snapshot: { lease_secs_left: 0 }, updated: r.clockNow + 2000 }), null);
  assert.equal(r.actions.tick(withLease(r.clockNow - 1)), null);
  assert.equal(r.calls.length, 1);
  // a snapshot read after the refusal shows the lease: one re-send, which finishes like the first try
  r.clockNow += 6000;
  await r.actions.tick(withLease(r.clockNow - 500));
  assert.equal(r.calls.length, 2);
  assert.deepEqual(r.calls[1], ['api/action', { words: ['send', 'api', 'run the tests'] }]);
  assert.deepEqual(r.success, ['sent\n']);
  assert.equal(r.actions.pending(), null);
  assert.equal(r.actions.tick(withLease(r.clockNow + 1000)), null, 'never re-sent twice');
  assert.equal(r.calls.length, 2);
});

test('a refused new-session or rename finishes the same way (each keeps its own handler)', async () => {
  for (const w of [['new', 'api'], ['rename', 'api', 'web']]) {
    const r = rig([NEEDS_AUTH, OK('done\n')]);
    await r.actions.act(w, { onSuccess: r.onSuccess });
    r.clockNow += 3000;
    await r.actions.tick(withLease(r.clockNow));
    assert.deepEqual(r.calls[1], ['api/action', { words: w }]);
    assert.deepEqual(r.success, ['done\n']);
  }
});

test('an action that works the first time runs its success handler at once', async () => {
  const r = rig([OK('created\n')]);
  await r.actions.act(['new', 'api'], { onSuccess: r.onSuccess });
  assert.deepEqual(r.success, ['created\n']);
  assert.equal(r.actions.pending(), null);
  assert.deepEqual(r.terminals, []);
});

test('the success handler never runs for a failed re-send, a second refusal, a 409 or a dead server', async () => {
  const failed = rig([NEEDS_AUTH, { status: 200, data: { code: 3, stdout: '', stderr: 'tmuxkeep: session api is locked\n', needs_auth: false } }]);
  await failed.actions.act(['send', 'api', 'x'], { onSuccess: failed.onSuccess });
  failed.clockNow += 3000;
  await failed.actions.tick(withLease(failed.clockNow));
  assert.deepEqual(failed.success, []);
  assert.deepEqual(failed.notices.at(-1), ['exit 3: tmuxkeep: session api is locked', true]);
  assert.equal(failed.actions.pending(), null);

  const again = rig([NEEDS_AUTH, NEEDS_AUTH]);
  await again.actions.act(['send', 'api', 'x'], { onSuccess: again.onSuccess });
  again.clockNow += 3000;
  await again.actions.tick(withLease(again.clockNow));
  assert.deepEqual(again.success, []);
  assert.deepEqual(again.terminals, [{ verb: 'auth' }], 'the terminal opens once');
  assert.equal(again.actions.pending(), null);
  assert.deepEqual(again.notices.at(-1), ['exit 4: tmuxkeep: authentication required', true]);

  const busy = rig([{ status: 409, data: { error: 'busy' } }]);
  assert.equal(await busy.actions.act(['log', '-n', '100'], { onSuccess: busy.onSuccess }), null);
  assert.deepEqual(busy.success, []);
  assert.equal(busy.notices.at(-1)[1], true);

  const dead = rig([new Error('connection refused')]);
  assert.equal(await dead.actions.act(['log', '-n', '100'], { onSuccess: dead.onSuccess }), null);
  assert.deepEqual(dead.success, []);
  assert.deepEqual(dead.notices.at(-1), ['the local server did not answer', true]);
});

test('any other action drops the pending one; so does expiry after 3 minutes', async () => {
  const other = rig([NEEDS_AUTH, OK('listed\n')]);
  await other.actions.act(['send', 'api', 'x'], { onSuccess: other.onSuccess });
  await other.actions.act(['log', '-n', '100']);
  assert.equal(other.actions.pending(), null);
  other.clockNow += 5000;
  assert.equal(other.actions.tick(withLease(other.clockNow)), null);
  assert.deepEqual(other.success, []);
  assert.equal(other.calls.length, 2);

  const stale = rig([NEEDS_AUTH]);
  await stale.actions.act(['send', 'api', 'x'], { onSuccess: stale.onSuccess });
  stale.clockNow += PENDING_MS;
  assert.equal(stale.actions.tick(withLease(stale.clockNow)), null);
  assert.equal(stale.actions.pending(), null);
  assert.deepEqual(stale.notices.at(-1), ['the action that needed a code was dropped after 3 minutes', true]);
  assert.equal(stale.calls.length, 1);
  assert.deepEqual(stale.success, []);

  const attach = rig([NEEDS_AUTH]);
  await attach.actions.act(['send', 'api', 'x'], { onSuccess: attach.onSuccess });
  attach.actions.drop();
  assert.equal(attach.actions.pending(), null);
});

test('the page has no leftover state field and polls with a timeout and a guard', () => {
  assert.equal(POLL_TIMEOUT_MS, 3000);
  assert.ok(!APP.includes('stateAt'));
  assert.ok(APP.includes('AbortSignal.timeout(POLL_TIMEOUT_MS)'));
  assert.match(APP, /if \(polling\) \{/);
});
