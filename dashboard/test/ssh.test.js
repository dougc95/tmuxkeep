import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { MAX_OUTPUT_CHARS, runVerb, sshCommand } from '../lib/ssh.js';
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

// Ruling P8b: the cap is exact. The first write ends 10 characters short of the cap and the second
// would cross it, so the kept text is the cap's worth and no more, however the pipe chunks it.
test('stdout and stderr are each kept to exactly MAX_OUTPUT_CHARS, cut inside the chunk that crosses it', async () => {
  const head = 'a'.repeat(MAX_OUTPUT_CHARS - 10);
  const tail = 'b'.repeat(5000);
  const s = stubPlan({
    peek: [{ steps: [{ out: head }, { out: tail }, { err: head }, { err: tail }], code: 0 }],
  });
  const r = await runVerb(['peek', 'api'], { env: s.env, timeoutMs: 20000 });
  assert.equal(r.code, 0);
  assert.equal(r.stdout.length, MAX_OUTPUT_CHARS);
  assert.equal(r.stderr.length, MAX_OUTPUT_CHARS);
  assert.equal(r.stdout, head + 'b'.repeat(10));
  assert.equal(r.stderr, head + 'b'.repeat(10));
});
