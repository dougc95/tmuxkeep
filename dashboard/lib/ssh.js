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

// capped(text, chunk): text plus as much of chunk as fits under MAX_OUTPUT_CHARS. The cap is exact:
// the chunk that crosses it is sliced, and everything after is dropped.
function capped(text, chunk) {
  const room = MAX_OUTPUT_CHARS - text.length;
  if (room <= 0) return text;
  return chunk.length <= room ? text + chunk : text + chunk.slice(0, room);
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
    child.stdout.on('data', (s) => { stdout = capped(stdout, s); });
    child.stderr.on('data', (s) => { stderr = capped(stderr, s); });
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
