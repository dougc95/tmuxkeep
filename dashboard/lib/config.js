// config.js - the settings of tmuxkeep ui (spec 5.2, 6.1): DASHBOARD_PORT and TERMINAL_CMD from
// ~/.tmuxkeep/config, and the server's own command line. The deploy scripts validate the whole file;
// this reader looks only at its two keys and ignores every other line. A missing file or key takes
// the default.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const DEFAULT_PORT = 7707;
export const USAGE = 'usage: tmuxkeep ui [--port N] [--no-open]';

const PRINTABLE_RE = /^[\x20-\x7e]*$/;

// configPath(home): the laptop config file.
export function configPath(home = os.homedir()) {
  return path.join(home, '.tmuxkeep', 'config');
}

// portValue(text): the port number for 1-7 decimal digits within 1024-65535, else null.
export function portValue(text) {
  if (!/^[0-9]{1,7}$/.test(text)) return null;
  const n = Number.parseInt(text, 10);
  return n >= 1024 && n <= 65535 ? n : null;
}

// readConfig(file): { port, terminalCmd }. Throws Error("config <file>: <reason>") for a bad value.
// A value with a byte outside 0x20-0x7E is refused with the deploy scripts' own words, line number
// included, the moment its line is read.
export function readConfig(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'latin1');
  } catch (err) {
    if (err.code === 'ENOENT') return { port: DEFAULT_PORT, terminalCmd: '' };
    // The message stays as it is; the errno (EACCES, EISDIR...) is kept in the cause for whoever debugs it.
    throw new Error(`config ${file}: cannot read`, { cause: err });
  }
  const found = {};
  const lines = text.split('\n');
  for (let n = 1; n <= lines.length; n += 1) {
    const line = lines[n - 1].replace(/^[ \t\r]+|[ \t\r]+$/g, '');
    if (line === '' || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).replace(/[ \t]+$/, '');
    if (key !== 'DASHBOARD_PORT' && key !== 'TERMINAL_CMD') continue;
    const value = line.slice(eq + 1).replace(/^[ \t]+/, '');
    if (!PRINTABLE_RE.test(value)) throw new Error(`config ${file}: line ${n}: non-printable or non-ASCII character in ${key}`);
    found[key] = value;
  }
  const out = { port: DEFAULT_PORT, terminalCmd: '' };
  if (found.DASHBOARD_PORT !== undefined) {
    out.port = portValue(found.DASHBOARD_PORT);
    if (out.port === null) throw new Error(`config ${file}: DASHBOARD_PORT: must be an integer from 1024 to 65535`);
  }
  if (found.TERMINAL_CMD !== undefined) {
    if (found.TERMINAL_CMD.length > 200) throw new Error(`config ${file}: TERMINAL_CMD: at most 200 characters`);
    out.terminalCmd = found.TERMINAL_CMD;
  }
  return out;
}

// parseArgs(argv): { port: number|null, open: boolean } for [--port N] [--no-open], each at most once.
// Throws Error(USAGE), or Error('--port must be an integer from 1024 to 65535').
export function parseArgs(argv) {
  const out = { port: null, open: true };
  let sawOpen = false;
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--no-open' && !sawOpen) {
      sawOpen = true;
      out.open = false;
    } else if (a === '--port' && out.port === null && i + 1 < argv.length) {
      i += 1;
      out.port = portValue(argv[i]);
      if (out.port === null) throw new Error('--port must be an integer from 1024 to 65535');
    } else {
      throw new Error(USAGE);
    }
  }
  return out;
}
