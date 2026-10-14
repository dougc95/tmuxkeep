// stub-ssh.js - stands in for ssh in the dashboard tests. TMUXKEEP_SSH points here and lib/ssh.js
// runs it with node. It checks the fixed argument prefix, decodes the b64 tokens, appends one JSON
// line {"argv":[...],"words":[...]} to <script>.log, then plays what the JSON file named by
// TMUXKEEP_STUB_SCRIPT says for the first decoded word (the verb), or for "*":
//   { "<verb>": [ { "steps": [ step, ... ], "code": 0 }, ... ], "*": [ ... ] }
//   step: {"out": "text"} | {"err": "text"} | {"sleep": ms} | {"hang": true} | {"stdin": true}
// The n-th call for a verb plays entry n; the last entry repeats. <script>.count-<verb> counts calls.
// "hang" waits until killed, but never longer than 20 seconds, so an orphan cannot outlive a test
// run. "stdin" reads stdin to its end and prints "stdin:<bytes>".
import fs from 'node:fs';

const PREFIX = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'tmuxkeep', 'b64'];
const argv = process.argv.slice(2);
const script = process.env.TMUXKEEP_STUB_SCRIPT;
if (!script) {
  process.stderr.write('stub-ssh: TMUXKEEP_STUB_SCRIPT is not set\n');
  process.exit(97);
}
const prefixOk = PREFIX.every((p, i) => argv[i] === p);
const words = prefixOk ? argv.slice(PREFIX.length).map((t) => Buffer.from(t, 'base64').toString('utf8')) : [];
fs.appendFileSync(`${script}.log`, JSON.stringify({ argv, words }) + '\n');
if (!prefixOk) {
  process.stderr.write('stub-ssh: unexpected arguments\n');
  process.exit(98);
}
const plan = JSON.parse(fs.readFileSync(script, 'utf8'));
const key = Object.hasOwn(plan, words[0] ?? '') ? words[0] : '*';
const entries = plan[key];
if (!Array.isArray(entries) || entries.length === 0) {
  process.stderr.write(`stub-ssh: no behaviour for ${words[0]}\n`);
  process.exit(99);
}
const counter = `${script}.count-${key === '*' ? 'any' : key}`;
let n = 0;
try {
  n = Number.parseInt(fs.readFileSync(counter, 'utf8'), 10) || 0;
} catch {
  n = 0;
}
fs.writeFileSync(counter, String(n + 1));
const entry = entries[Math.min(n, entries.length - 1)];

const write = (stream, text) => new Promise((resolve) => stream.write(text, resolve));
const readAll = () => new Promise((resolve) => {
  let bytes = 0;
  process.stdin.on('data', (b) => { bytes += b.length; });
  process.stdin.on('end', () => resolve(bytes));
  process.stdin.on('error', () => resolve(bytes));
});

for (const step of entry.steps ?? []) {
  if (step.out !== undefined) await write(process.stdout, step.out);
  if (step.err !== undefined) await write(process.stderr, step.err);
  if (step.sleep !== undefined) await new Promise((resolve) => setTimeout(resolve, step.sleep));
  if (step.stdin) await write(process.stdout, `stdin:${await readAll()}\n`);
  if (step.hang) await new Promise((resolve) => setTimeout(resolve, 20000));
}
process.exitCode = entry.code ?? 0;
