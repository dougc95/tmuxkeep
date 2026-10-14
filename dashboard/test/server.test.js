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

// TERMINAL gives /api/terminal a program to name on a Linux runner that has no x-terminal-emulator; the
// dry run never starts it (plan ruling P1).
function envFor(h, extra = {}) {
  return { ...process.env, HOME: h, USERPROFILE: h, TMUXKEEP_TERMINAL_DRYRUN: '1', TERMINAL: 'xterm', ...extra };
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

// An ssh stand-in that records its process id and then stays alive for at most 20 seconds.
const PID_SSH = "import fs from 'node:fs';\nfs.writeFileSync(`${process.argv[1]}.pid`, String(process.pid));\nsetTimeout(() => {}, 20000);\n";

test('Ctrl-C stops the follow connection too: no ssh child outlives the server', { skip: process.platform === 'win32' ? 'Windows has no catchable SIGINT' : false }, async () => {
  const port = await freePort();
  const fake = path.join(tempDir(), 'fake-ssh.js');
  fs.writeFileSync(fake, PID_SSH);
  const run = start(['--port', String(port), '--no-open'], envFor(home(), { TMUXKEEP_SSH: fake }));
  let pid = null;
  try {
    const line = await waitFor(() => run.out().match(/^tmuxkeep ui: http:\/\/127\.0\.0\.1:\d+\/([0-9a-f]{32})\/  \(Ctrl-C stops\)\n$/));
    assert.equal((await get(port, `/${line[1]}/api/state`, { host: `127.0.0.1:${port}` })).status, 200);
    pid = Number(await waitFor(() => (fs.existsSync(`${fake}.pid`) ? fs.readFileSync(`${fake}.pid`, 'utf8') : '')));
    assert.ok(pid > 0);
    run.child.kill('SIGINT');
    assert.deepEqual(await run.exit, { code: 0, signal: null });
    const gone = () => {
      try {
        process.kill(pid, 0);
        return false;
      } catch {
        return true;
      }
    };
    await waitFor(gone, 3000);
  } finally {
    if (run.child.exitCode === null && run.child.signalCode === null) run.child.kill();
    if (pid) {
      try {
        process.kill(pid);
      } catch {
        // already gone
      }
    }
  }
});
