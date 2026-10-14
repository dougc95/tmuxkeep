import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import {
  appleScriptString, browserArgv, onPath, openBrowser, openTerminal, shQuote, terminalArgv, wrapperArgv,
} from '../lib/terminal.js';

const WIN_HOME = 'C:\\Users\\you';
const PS = (home, ...words) => ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', `${home}\\scripts\\tmuxkeep.ps1`, ...words];

// lstatOnly(paths): an lstat that finds exactly these paths.
const lstatOnly = (...paths) => (p) => {
  if (paths.includes(p)) return {};
  throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' });
};

// fakeSpawn(outcomes): records each call; the n-th call emits 'spawn' or 'error' per outcomes[n].
function fakeSpawn(outcomes) {
  const calls = [];
  const fn = (cmd, args, options) => {
    const child = new EventEmitter();
    child.unref = () => {};
    const outcome = outcomes[calls.length] ?? 'spawn';
    calls.push({ argv: [cmd, ...args], options });
    setImmediate(() => (outcome === 'spawn' ? child.emit('spawn') : child.emit('error', Object.assign(new Error(outcome), { code: outcome }))));
    return child;
  };
  return { fn, calls };
}

test('the wrapper command per platform', () => {
  assert.deepEqual(wrapperArgv({ verb: 'go', name: 'api', platform: 'win32', home: WIN_HOME }), PS(WIN_HOME, 'go', 'api'));
  assert.deepEqual(wrapperArgv({ verb: 'auth', platform: 'linux', home: '/home/you' }), ['/home/you/.local/bin/tmuxkeep', 'auth']);
  assert.deepEqual(wrapperArgv({ verb: 'go', name: 'api', platform: 'darwin', home: '/Users/you' }), ['/Users/you/.local/bin/tmuxkeep', 'go', 'api']);
});

test('Windows: a new Windows Terminal tab when wt.exe is on PATH, titled tmuxkeep <verb> [<name>]', () => {
  const pathEnv = 'C:\\Windows\\System32;C:\\Users\\you\\AppData\\Local\\Microsoft\\WindowsApps';
  const lstat = lstatOnly('C:\\Users\\you\\AppData\\Local\\Microsoft\\WindowsApps\\wt.exe');
  assert.deepEqual(terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home: WIN_HOME, pathEnv, lstat }),
    ['wt.exe', '-w', '0', 'new-tab', '--title', 'tmuxkeep go api', ...PS(WIN_HOME, 'go', 'api')]);
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'win32', home: WIN_HOME, pathEnv, lstat }),
    ['wt.exe', '-w', '0', 'new-tab', '--title', 'tmuxkeep auth', ...PS(WIN_HOME, 'auth')]);
});

test('Windows: without wt.exe, powershell.exe itself (started detached, it gets its own console)', () => {
  assert.deepEqual(terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home: WIN_HOME, pathEnv: 'C:\\Windows', lstat: lstatOnly() }),
    PS(WIN_HOME, 'go', 'api'));
});

// Review Focus 2: a home directory with spaces or a quote.
test('a home directory with spaces stays one argument; a quote in a macOS home is quoted for sh and AppleScript', () => {
  const home = 'C:\\Users\\John Smith';
  const argv = terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home, pathEnv: '', lstat: lstatOnly() });
  assert.equal(argv[6], 'C:\\Users\\John Smith\\scripts\\tmuxkeep.ps1');
  assert.equal(argv.length, 9);
  const mac = terminalArgv({ verb: 'go', name: 'api', platform: 'darwin', home: "/Users/o'brien \"x\"" });
  assert.deepEqual(mac, ['osascript', '-e',
    'tell application "Terminal" to do script "\'/Users/o\'\\\\\'\'brien \\"x\\"/.local/bin/tmuxkeep\' \'go\' \'api\'"',
    '-e', 'tell application "Terminal" to activate']);
});

test('macOS: Terminal via osascript, every word single-quoted', () => {
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'darwin', home: '/Users/you' }),
    ['osascript', '-e', 'tell application "Terminal" to do script "\'/Users/you/.local/bin/tmuxkeep\' \'auth\'"',
      '-e', 'tell application "Terminal" to activate']);
  assert.equal(shQuote("a'b"), "'a'\\''b'");
  assert.equal(appleScriptString('a"b\\c'), '"a\\"b\\\\c"');
});

test('Linux: x-terminal-emulator -e, else $TERMINAL -e, else an error naming TERMINAL_CMD', () => {
  const home = '/home/you';
  const lstat = lstatOnly('/usr/bin/x-terminal-emulator');
  assert.deepEqual(terminalArgv({ verb: 'go', name: 'api', platform: 'linux', home, pathEnv: '/bin:/usr/bin', lstat }),
    ['x-terminal-emulator', '-e', '/home/you/.local/bin/tmuxkeep', 'go', 'api']);
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'linux', home, pathEnv: '/bin', terminalEnv: 'kitty', lstat }),
    ['kitty', '-e', '/home/you/.local/bin/tmuxkeep', 'auth']);
  assert.throws(() => terminalArgv({ verb: 'auth', platform: 'linux', home, pathEnv: '/bin', lstat }),
    { message: 'no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config' });
});

test('TERMINAL_CMD comes first on every platform, split on single spaces, the wrapper words appended', () => {
  assert.deepEqual(terminalArgv({ verb: 'go', name: 'api', platform: 'linux', home: '/home/you', terminalCmd: 'alacritty  -e' }),
    ['alacritty', '-e', '/home/you/.local/bin/tmuxkeep', 'go', 'api']);
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'win32', home: WIN_HOME, terminalCmd: 'wezterm start --' }),
    ['wezterm', 'start', '--', ...PS(WIN_HOME, 'auth')]);
});

test('onPath splits PATH by platform and ignores empty parts', () => {
  assert.equal(onPath('x', { platform: 'linux', pathEnv: '::/a', lstat: lstatOnly('/a/x') }), true);
  assert.equal(onPath('x', { platform: 'linux', pathEnv: '', lstat: lstatOnly('/a/x') }), false);
  assert.equal(onPath('x.exe', { platform: 'win32', pathEnv: 'C:\\a;;C:\\b', lstat: lstatOnly('C:\\b\\x.exe') }), true);
});

test('dry run returns the argv and starts nothing', async () => {
  const s = fakeSpawn([]);
  const r = await openTerminal({ verb: 'go', name: 'api' },
    { platform: 'linux', home: '/home/you', env: { TMUXKEEP_TERMINAL_DRYRUN: '1', TERMINAL: 'kitty', PATH: '/nowhere' }, spawnFn: s.fn, lstat: lstatOnly() });
  assert.deepEqual(r, { ok: true, argv: ['kitty', '-e', '/home/you/.local/bin/tmuxkeep', 'go', 'api'] });
  assert.equal(s.calls.length, 0);
});

test('a real start is detached, without a shell; a failure is reported; no terminal is an error', async () => {
  const s = fakeSpawn(['spawn']);
  const env = { TERMINAL: 'kitty', PATH: '/nowhere' };
  const r = await openTerminal({ verb: 'auth' }, { platform: 'linux', home: '/home/you', env, spawnFn: s.fn, lstat: lstatOnly() });
  assert.equal(r.ok, true);
  assert.equal(s.calls[0].options.shell, false);
  assert.equal(s.calls[0].options.detached, true);
  const f = fakeSpawn(['ENOENT']);
  assert.deepEqual(await openTerminal({ verb: 'auth' }, { platform: 'linux', home: '/home/you', env, spawnFn: f.fn, lstat: lstatOnly() }),
    { ok: false, error: 'cannot start kitty: ENOENT' });
  assert.deepEqual(await openTerminal({ verb: 'auth' }, { platform: 'linux', home: '/home/you', env: { PATH: '' }, spawnFn: f.fn, lstat: lstatOnly() }),
    { ok: false, error: 'no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config' });
});

test('Windows: when the wt.exe alias fails to start, a plain console window is used instead', async () => {
  const s = fakeSpawn(['UNKNOWN', 'spawn']);
  const env = { PATH: 'C:\\apps' };
  const r = await openTerminal({ verb: 'go', name: 'api' }, { platform: 'win32', home: WIN_HOME, env, spawnFn: s.fn, lstat: lstatOnly('C:\\apps\\wt.exe') });
  assert.deepEqual(r, { ok: true, argv: PS(WIN_HOME, 'go', 'api') });
  assert.equal(s.calls[0].argv[0], 'wt.exe');
});

test('the browser command per platform; cmd.exe gets verbatim arguments; dry run starts nothing', async () => {
  const url = 'http://127.0.0.1:7707/0123456789abcdef0123456789abcdef/';
  assert.deepEqual(browserArgv(url, 'win32'), ['cmd.exe', '/c', 'start', '""', url]);
  assert.deepEqual(browserArgv(url, 'darwin'), ['open', url]);
  assert.deepEqual(browserArgv(url, 'linux'), ['xdg-open', url]);
  const s = fakeSpawn(['spawn']);
  assert.deepEqual(await openBrowser(url, { platform: 'win32', env: {}, spawnFn: s.fn }), { argv: browserArgv(url, 'win32'), error: null });
  assert.equal(s.calls[0].options.windowsVerbatimArguments, true);
  const d = fakeSpawn([]);
  assert.deepEqual(await openBrowser(url, { platform: 'linux', env: { TMUXKEEP_TERMINAL_DRYRUN: '1' }, spawnFn: d.fn }), { argv: ['xdg-open', url], error: null });
  assert.equal(d.calls.length, 0);
  const f = fakeSpawn(['ENOENT']);
  assert.deepEqual(await openBrowser(url, { platform: 'linux', env: {}, spawnFn: f.fn }), { argv: ['xdg-open', url], error: 'ENOENT' });
});
