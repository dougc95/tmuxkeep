import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import {
  appleScriptString, browserArgv, onPath, openBrowser, openTerminal, shQuote, terminalArgv, wrapperArgv,
} from '../lib/terminal.js';

const WIN_HOME = 'C:\\Users\\you';
const PS = (home, ...words) => ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', `${home}\\scripts\\tmuxkeep.ps1`, ...words];

// CMD(home, title, ...words): the Windows console window command, cmd.exe start with the title and the
// script path carrying their own double quotes (it is spawned with windowsVerbatimArguments).
const CMD = (home, title, ...words) => ['cmd.exe', '/c', 'start', `"${title}"`, 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', `"${home}\\scripts\\tmuxkeep.ps1"`, ...words];
const HOME_REFUSED = 'tmuxkeep ui: the home folder path contains " or %; set TERMINAL_CMD to open terminals another way';

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

// A detached, stdio-less powershell.exe gets no console, so without wt.exe cmd.exe's start opens a
// console window of its own for it.
test('Windows: without wt.exe, cmd.exe start opens a console window running powershell.exe', () => {
  const opts = { platform: 'win32', home: WIN_HOME, pathEnv: 'C:\\Windows', lstat: lstatOnly() };
  assert.deepEqual(terminalArgv({ verb: 'go', name: 'api', ...opts }), CMD(WIN_HOME, 'tmuxkeep go api', 'go', 'api'));
  assert.deepEqual(terminalArgv({ verb: 'auth', ...opts }), CMD(WIN_HOME, 'tmuxkeep auth', 'auth'));
});

// Review Focus 2: a home directory with spaces or a quote.
test('a home directory with spaces stays one argument; a quote in a macOS home is quoted for sh and AppleScript', () => {
  const home = 'C:\\Users\\John Smith';
  const argv = terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home, pathEnv: '', lstat: lstatOnly() });
  assert.deepEqual(argv, CMD(home, 'tmuxkeep go api', 'go', 'api'));
  assert.equal(argv[10], '"C:\\Users\\John Smith\\scripts\\tmuxkeep.ps1"');
  assert.equal(argv.length, 13);
  const wt = terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home, pathEnv: 'C:\\apps', lstat: lstatOnly('C:\\apps\\wt.exe') });
  assert.equal(wt[12], 'C:\\Users\\John Smith\\scripts\\tmuxkeep.ps1');
  assert.equal(wt.length, 15);
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

test('Windows: when the wt.exe alias fails to start, a console window (cmd.exe start, verbatim arguments) is used instead', async () => {
  const s = fakeSpawn(['UNKNOWN', 'spawn']);
  const env = { PATH: 'C:\\apps' };
  const r = await openTerminal({ verb: 'go', name: 'api' }, { platform: 'win32', home: WIN_HOME, env, spawnFn: s.fn, lstat: lstatOnly('C:\\apps\\wt.exe') });
  assert.deepEqual(r, { ok: true, argv: CMD(WIN_HOME, 'tmuxkeep go api', 'go', 'api') });
  assert.equal(s.calls.length, 2);
  assert.equal(s.calls[0].argv[0], 'wt.exe');
  assert.equal(s.calls[0].options.windowsVerbatimArguments, undefined);
  assert.deepEqual(s.calls[1].argv, CMD(WIN_HOME, 'tmuxkeep go api', 'go', 'api'));
  assert.equal(s.calls[1].options.windowsVerbatimArguments, true);
  assert.equal(s.calls[1].options.shell, false);
  assert.equal(s.calls[1].options.detached, true);
});

test('Windows: when wt.exe and the cmd.exe fallback both fail, the error names both', async () => {
  const s = fakeSpawn(['UNKNOWN', 'ENOENT']);
  const r = await openTerminal({ verb: 'auth' }, { platform: 'win32', home: WIN_HOME, env: { PATH: 'C:\\apps' }, spawnFn: s.fn, lstat: lstatOnly('C:\\apps\\wt.exe') });
  assert.deepEqual(r, { ok: false, error: 'cannot start wt.exe: UNKNOWN; cannot start cmd.exe: ENOENT' });
  assert.equal(s.calls.length, 2);
});

test('Windows: without wt.exe, the console window is started through cmd.exe with verbatim arguments, once', async () => {
  const s = fakeSpawn(['spawn']);
  const env = { PATH: 'C:\\Windows' };
  const r = await openTerminal({ verb: 'auth' }, { platform: 'win32', home: WIN_HOME, env, spawnFn: s.fn, lstat: lstatOnly() });
  assert.deepEqual(r, { ok: true, argv: CMD(WIN_HOME, 'tmuxkeep auth', 'auth') });
  assert.equal(s.calls.length, 1);
  assert.deepEqual(s.calls[0].argv, CMD(WIN_HOME, 'tmuxkeep auth', 'auth'));
  assert.equal(s.calls[0].options.windowsVerbatimArguments, true);
  assert.equal(s.calls[0].options.shell, false);
  const f = fakeSpawn(['ENOENT']);
  assert.deepEqual(await openTerminal({ verb: 'auth' }, { platform: 'win32', home: WIN_HOME, env, spawnFn: f.fn, lstat: lstatOnly() }),
    { ok: false, error: 'cannot start cmd.exe: ENOENT' });
});

// cmd.exe expands %VAR% even inside double quotes, so the cmd.exe console form refuses such a home.
test('Windows: a home with a percent sign or a double quote is refused for the console window, with no spawn', async () => {
  for (const home of ['C:\\Users\\100%', 'C:\\Users\\%USERNAME%', 'C:\\Users\\a"b']) {
    assert.throws(() => terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home, pathEnv: '', lstat: lstatOnly() }), { message: HOME_REFUSED });
    const s = fakeSpawn([]);
    const env = { PATH: 'C:\\Windows' };
    assert.deepEqual(await openTerminal({ verb: 'go', name: 'api' }, { platform: 'win32', home, env, spawnFn: s.fn, lstat: lstatOnly() }),
      { ok: false, error: HOME_REFUSED });
    assert.equal(s.calls.length, 0);
  }
  // wt.exe fails to start, and the fallback is the console form: refused, the error names both.
  const home = 'C:\\Users\\100%';
  const w = fakeSpawn(['UNKNOWN']);
  assert.deepEqual(await openTerminal({ verb: 'auth' }, { platform: 'win32', home, env: { PATH: 'C:\\apps' }, spawnFn: w.fn, lstat: lstatOnly('C:\\apps\\wt.exe') }),
    { ok: false, error: `cannot start wt.exe: UNKNOWN; ${HOME_REFUSED}` });
  assert.equal(w.calls.length, 1);
  // The Windows Terminal path and TERMINAL_CMD do not go through cmd.exe, so they are not refused.
  const t = fakeSpawn(['spawn']);
  const ok = await openTerminal({ verb: 'auth' }, { platform: 'win32', home, env: { PATH: 'C:\\apps' }, spawnFn: t.fn, lstat: lstatOnly('C:\\apps\\wt.exe') });
  assert.equal(ok.ok, true);
  assert.equal(ok.argv[0], 'wt.exe');
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'win32', home, terminalCmd: 'wezterm start --' }), ['wezterm', 'start', '--', ...PS(home, 'auth')]);
});

// Defence in depth: the route has run checkTerminal, but nothing odd may reach a command line.
test('openTerminal refuses a request that is not exactly go <name> or auth, and spawns nothing', async () => {
  const bad = [
    { verb: 'GO', name: 'api' }, { verb: 'ui' }, { verb: 'go; calc', name: 'api' }, { name: 'api' }, { verb: 'go' },
    { verb: 'go', name: 'a;b' }, { verb: 'go', name: '-x' }, { verb: 'go', name: 'API' }, { verb: 'go', name: 'a b' },
    { verb: 'go', name: `a${'b'.repeat(32)}` }, { verb: 'go', name: '' }, { verb: 'go', name: 7 }, { verb: 'go', name: ['api'] },
    { verb: 'auth', name: 'api' }, { verb: 'auth', name: '' }, { verb: 'auth', name: null }, null, 'go api',
  ];
  for (const request of bad) {
    for (const platform of ['linux', 'win32', 'darwin']) {
      const s = fakeSpawn([]);
      const env = { TERMINAL: 'kitty', PATH: '/nowhere' };
      assert.deepEqual(await openTerminal(request, { platform, home: '/home/you', env, spawnFn: s.fn, lstat: lstatOnly() }),
        { ok: false, error: 'tmuxkeep ui: invalid terminal request' }, JSON.stringify(request));
      assert.equal(s.calls.length, 0, JSON.stringify(request));
    }
  }
  // The longest allowed name and the shortest still go through (dry run).
  const env = { TMUXKEEP_TERMINAL_DRYRUN: '1', TERMINAL: 'kitty', PATH: '/nowhere' };
  const long = `a${'b'.repeat(31)}`;
  assert.deepEqual(await openTerminal({ verb: 'go', name: long }, { platform: 'linux', home: '/home/you', env, lstat: lstatOnly() }),
    { ok: true, argv: ['kitty', '-e', '/home/you/.local/bin/tmuxkeep', 'go', long] });
  assert.equal((await openTerminal({ verb: 'go', name: 'a_1-b' }, { platform: 'linux', home: '/home/you', env, lstat: lstatOnly() })).ok, true);
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

// cmd.exe interprets & | ^ % and quotes, so only the dashboard's own address (127.0.0.1, a port, a
// 32-hex token) is ever opened.
test('openBrowser refuses any address that is not the dashboard\'s own, and spawns nothing', async () => {
  const token = '0123456789abcdef0123456789abcdef';
  const bad = [
    `http://127.0.0.1:7707/${token}/&calc`, `http://127.0.0.1:7707/${token}/&calc/`, `http://127.0.0.1:7707/${token}/ & calc`,
    `http://127.0.0.1:7707/${token.slice(1)}/`, `http://127.0.0.1:7707/${token}0/`, `http://127.0.0.1:7707/${token.toUpperCase()}/`,
    `http://127.0.0.1:7707/${token}`, `http://127.0.0.1:7707/${token}/x`, `http://127.0.0.1:7707/${token}/\n`,
    `https://127.0.0.1:7707/${token}/`, `http://localhost:7707/${token}/`, `http://127.0.0.1.evil.example:7707/${token}/`,
    `http://127.0.0.1:770/${token}/`, `http://127.0.0.1:770700/${token}/`, `http://127.0.0.1/${token}/`,
    `http://user@127.0.0.1:7707/${token}/`, 'http://127.0.0.1:7707/', '', undefined, null, 7,
  ];
  for (const url of bad) {
    for (const platform of ['win32', 'darwin', 'linux']) {
      for (const env of [{}, { TMUXKEEP_TERMINAL_DRYRUN: '1' }]) {
        const s = fakeSpawn([]);
        assert.deepEqual(await openBrowser(url, { platform, env, spawnFn: s.fn }),
          { ok: false, error: 'tmuxkeep ui: refusing to open an unexpected address' }, String(url));
        assert.equal(s.calls.length, 0, String(url));
      }
    }
  }
  // Four and five digit ports are accepted.
  const s = fakeSpawn([]);
  const ok = await openBrowser(`http://127.0.0.1:65535/${token}/`, { platform: 'linux', env: { TMUXKEEP_TERMINAL_DRYRUN: '1' }, spawnFn: s.fn });
  assert.deepEqual(ok, { argv: ['xdg-open', `http://127.0.0.1:65535/${token}/`], error: null });
  assert.deepEqual((await openBrowser(`http://127.0.0.1:1024/${token}/`, { platform: 'linux', env: { TMUXKEEP_TERMINAL_DRYRUN: '1' }, spawnFn: s.fn })).error, null);
  assert.equal(s.calls.length, 0);
});
