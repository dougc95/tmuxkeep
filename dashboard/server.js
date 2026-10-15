// server.js - tmuxkeep ui, the local dashboard server (spec 6). The laptop wrappers run it as
//   node <dashboard dir>/server.js [--port N] [--no-open]
// It listens on 127.0.0.1 only, prints the address with a fresh token, and keeps one
// "status --follow" ssh connection while a page is open. It writes nothing to disk.
// Exit codes: 0 after Ctrl-C (SIGINT) or SIGTERM; 1 when the port cannot be bound; 2 for a usage or
// config error, or a Node older than 20. TMUXKEEP_NODE_VERSION stands in for the Node version in tests.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { configPath, parseArgs, readConfig } from './lib/config.js';
import { createFollower, FOLLOW_WORDS } from './lib/follow.js';
import { createHandler, createServer } from './lib/http.js';
import { runVerb, spawnSsh } from './lib/ssh.js';
import { openBrowser, openTerminal } from './lib/terminal.js';

function quit(code, message) {
  process.stderr.write(`${message}\n`);
  process.exit(code);
}

// 1. Node 20 or newer.
const found = process.env.TMUXKEEP_NODE_VERSION || process.versions.node;
if (Number.parseInt(found, 10) < 20) quit(2, `tmuxkeep ui: Node 20 or newer is required (found v${found})`);

// 2. Arguments, then the config file; --port wins over DASHBOARD_PORT.
let args;
try {
  args = parseArgs(process.argv.slice(2));
} catch (err) {
  quit(2, err.message.startsWith('usage:') ? err.message : `tmuxkeep ui: ${err.message}`);
}
let config;
try {
  config = readConfig(configPath());
} catch (err) {
  quit(2, `tmuxkeep ui: ${err.message}`);
}
const port = args.port ?? config.port;

// 3. A fresh token for this run: 32 lowercase hex characters, the form openBrowser accepts.
const token = crypto.randomBytes(16).toString('hex');

const here = path.dirname(fileURLToPath(import.meta.url));
const files = {};
for (const name of ['index.html', 'app.js', 'style.css']) files[name] = fs.readFileSync(path.join(here, 'public', name));

const follower = createFollower({ spawnChild: () => spawnSsh(FOLLOW_WORDS) });
const handler = createHandler({
  token,
  port,
  files,
  getState: () => {
    follower.touch();
    return follower.state();
  },
  runAction: (words) => runVerb(words),
  openTerminal: (request) => openTerminal(request, { home: os.homedir(), terminalCmd: config.terminalCmd }),
});

// 4. 127.0.0.1 only: never 0.0.0.0, never ::.
const server = createServer(handler);
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') quit(1, `tmuxkeep ui: port ${port} is in use; set DASHBOARD_PORT or pass --port`);
  quit(1, `tmuxkeep ui: cannot listen on 127.0.0.1:${port}: ${err.code || err.message}`);
});
server.listen(port, '127.0.0.1', async () => {
  // 5. The address, then the browser. openBrowser answers {argv, error}, or {ok: false, error} with
  // no argv when it refuses the address; any error is a warning, and the argv is printed only when
  // there is one.
  const url = `http://127.0.0.1:${port}/${token}/`;
  process.stdout.write(`tmuxkeep ui: ${url}  (Ctrl-C stops)\n`);
  if (!args.open) return;
  const opened = await openBrowser(url);
  if (opened.error != null) process.stderr.write(`tmuxkeep ui: could not open a browser (${opened.error}); open the address above yourself\n`);
  else if (process.env.TMUXKEEP_TERMINAL_DRYRUN === '1') process.stdout.write(`tmuxkeep ui: dry run: ${JSON.stringify(opened.argv)}\n`);
});

// 6. Ctrl-C or SIGTERM: stop the follow child (its timers and the ssh session must not outlive the
// server), close the server, exit 0.
function shutdown() {
  follower.stop();
  server.close();
  server.closeAllConnections();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
