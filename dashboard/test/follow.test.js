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

// Final review M1: BatchMode host-key and publickey failures also exit 255, so the message keeps the
// last stderr line in parentheses when ssh printed one, and is the bare text when it printed nothing.
test('exit 255 shows VPS unreachable with the last stderr line in parentheses when there is one', async () => {
  const { children, f } = setup();
  f.touch();
  children[0].stderr.write('Warning: Permanently added x\ntmuxkeep@203.0.113.10: Permission denied (publickey).\n');
  await flush();
  children[0].emit('close', 255);
  assert.equal(f.state().error, 'ssh exited 255: VPS unreachable (tmuxkeep@203.0.113.10: Permission denied (publickey).)');
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

// Review Focus 4, the EMFILE and ENFILE case: spawn returns a child with no stdio streams and reports
// the failure later as an 'error' event. Starting it must not throw, and the event must not go unhandled.
test('a child with no stdio streams that fails later is shown and retried', () => {
  const clock = fakeClock();
  const bare = new EventEmitter();
  bare.kill = () => true;
  const f = createFollower({ clock, spawnChild: () => bare });
  f.touch();
  bare.emit('error', Object.assign(new Error('spawn EMFILE'), { code: 'EMFILE' }));
  assert.equal(f.state().error, 'cannot run ssh: EMFILE');
  assert.equal(f.state().connected, false);
  assert.equal(f.stats().running, false);
  assert.equal(clock.pending()[0], 2000);
  f.stop();
});

test('endMessage covers a signal and a plain exit code', () => {
  assert.equal(endMessage(null, null, ''), 'ssh was stopped by a signal');
  assert.equal(endMessage(1, null, ''), 'ssh exited 1');
  assert.equal(endMessage(1, null, 'tmuxkeep: config invalid: x'), 'tmuxkeep: config invalid: x');
  assert.equal(endMessage(255, null, ''), 'ssh exited 255: VPS unreachable');
  assert.equal(endMessage(255, null, 'ssh: connect to host x port 22: Connection refused'),
    'ssh exited 255: VPS unreachable (ssh: connect to host x port 22: Connection refused)');
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
