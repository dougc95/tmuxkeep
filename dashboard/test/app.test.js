import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  clock, connectionView, errorText, HINT_255, humanise, lastLine, leaseLabel, logEntries, PENDING_MS, pendingStep, splitSessions, STALL_MS,
  words,
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
  assert.deepEqual(connectionView(live(0), now, false), { on: true, text: 'connected' });
  assert.deepEqual(connectionView(live(2000), now, false), { on: true, text: 'connected' });
  assert.deepEqual(connectionView(live(9999), now, false), { on: true, text: 'connected' });
  assert.deepEqual(connectionView(live(10000), now, false), { on: false, text: 'no update for 10 s' });
  assert.deepEqual(connectionView(live(10999), now, false), { on: false, text: 'no update for 10 s' });
  assert.deepEqual(connectionView(live(95400), now, false), { on: false, text: 'no update for 95 s' });
});

test('the connection dot for a dropped connection or a stopped local server is unchanged by the stall rule', () => {
  const now = 5000000;
  const down = (updated, error) => ({ snapshot: null, connected: false, updated, error });
  assert.deepEqual(connectionView(down(null, 'ssh exited 255: VPS unreachable'), now, false), { on: false, text: 'ssh exited 255: VPS unreachable' });
  assert.deepEqual(connectionView(down(null, null), now, false), { on: false, text: 'connecting' });
  assert.deepEqual(connectionView(null, now, false), { on: false, text: 'connecting' });
  assert.deepEqual(connectionView(down(now - 60000, 'ssh exited 255: VPS unreachable'), now, false), { on: false, text: 'ssh exited 255: VPS unreachable' });
  const stopped = connectionView({ snapshot: {}, connected: true, updated: now, error: null }, now, true);
  assert.deepEqual(stopped, { on: false, text: 'the local server is not running (tmuxkeep ui was stopped)' });
});
