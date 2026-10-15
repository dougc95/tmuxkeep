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
