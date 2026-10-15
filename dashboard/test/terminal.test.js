import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import {
  appleScriptString, browserArgv, onPath, openBrowser, openTerminal, shQuote, terminalArgv, wrapperArgv,
} from '../lib/terminal.js';

const WIN_HOME = 'C:\\Users\\you';
// Windows programs are started by absolute path under the injected SystemRoot (final review L104):
// no program lookup in the current folder, whatever PATH or the registry says.
const SYS_ROOT = 'C:\\Windows';
const WIN_ENV = { SystemRoot: SYS_ROOT };
const CMD_EXE = `${SYS_ROOT}\\System32\\cmd.exe`;
const PS_EXE = `${SYS_ROOT}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`;
const WT_EXE = 'C:\\Users\\you\\AppData\\Local\\Microsoft\\WindowsApps\\wt.exe';
const PS = (home, ...words) => [PS_EXE, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', `${home}\\scripts\\tmuxkeep.ps1`, ...words];

// CMD(home, title, ...words): the Windows console window command, cmd.exe /d /v:off /c start with the
// title, the powershell.exe path and the script path carrying their own double quotes (it is spawned
// with windowsVerbatimArguments).
const CMD = (home, title, ...words) => [CMD_EXE, '/d', '/v:off', '/c', 'start', `"${title}"`, `"${PS_EXE}"`, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', `"${home}\\scripts\\tmuxkeep.ps1"`, ...words];
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
  assert.deepEqual(wrapperArgv({ verb: 'go', name: 'api', platform: 'win32', home: WIN_HOME, env: WIN_ENV }), PS(WIN_HOME, 'go', 'api'));
  // No SystemRoot in the env: C:\Windows. Another SystemRoot is used as given.
  assert.deepEqual(wrapperArgv({ verb: 'go', name: 'api', platform: 'win32', home: WIN_HOME, env: {} }), PS(WIN_HOME, 'go', 'api'));
  assert.deepEqual(wrapperArgv({ verb: 'go', name: 'api', platform: 'win32', home: WIN_HOME }), PS(WIN_HOME, 'go', 'api'));
  assert.equal(wrapperArgv({ verb: 'auth', platform: 'win32', home: WIN_HOME, env: { SystemRoot: 'D:\\WINNT' } })[0],
    'D:\\WINNT\\System32\\WindowsPowerShell\\v1.0\\powershell.exe');
  assert.deepEqual(wrapperArgv({ verb: 'auth', platform: 'linux', home: '/home/you' }), ['/home/you/.local/bin/tmuxkeep', 'auth']);
  assert.deepEqual(wrapperArgv({ verb: 'go', name: 'api', platform: 'darwin', home: '/Users/you' }), ['/Users/you/.local/bin/tmuxkeep', 'go', 'api']);
});

test('Windows: a new Windows Terminal tab when wt.exe is on PATH, titled tmuxkeep <verb> [<name>]', () => {
  const pathEnv = 'C:\\Windows\\System32;C:\\Users\\you\\AppData\\Local\\Microsoft\\WindowsApps';
  const lstat = lstatOnly(WT_EXE);
  // wt.exe is started by the full path the PATH lookup found, and powershell.exe inside it by absolute path.
  assert.deepEqual(terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home: WIN_HOME, pathEnv, lstat, env: WIN_ENV }),
    [WT_EXE, '-w', '0', 'new-tab', '--title', 'tmuxkeep go api', ...PS(WIN_HOME, 'go', 'api')]);
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'win32', home: WIN_HOME, pathEnv, lstat, env: WIN_ENV }),
    [WT_EXE, '-w', '0', 'new-tab', '--title', 'tmuxkeep auth', ...PS(WIN_HOME, 'auth')]);
});

// A detached, stdio-less powershell.exe gets no console, so without wt.exe cmd.exe's start opens a
// console window of its own for it.
test('Windows: without wt.exe, cmd.exe start opens a console window running powershell.exe', () => {
  const opts = { platform: 'win32', home: WIN_HOME, pathEnv: 'C:\\Windows', lstat: lstatOnly(), env: WIN_ENV };
  assert.deepEqual(terminalArgv({ verb: 'go', name: 'api', ...opts }), CMD(WIN_HOME, 'tmuxkeep go api', 'go', 'api'));
  assert.deepEqual(terminalArgv({ verb: 'auth', ...opts }), CMD(WIN_HOME, 'tmuxkeep auth', 'auth'));
});

// Final review L104: cmd.exe never reads the registry AutoRun commands (/d) and never expands !VAR!
// (/v:off) for these command lines, and is found by absolute path, not by a lookup in the current folder.
test('Windows: both cmd.exe command lines are absolute and carry /d and /v:off before /c', () => {
  const consoleLine = terminalArgv({ verb: 'auth', platform: 'win32', home: WIN_HOME, pathEnv: '', lstat: lstatOnly(), env: { SystemRoot: 'D:\\WINNT' } });
  assert.deepEqual(consoleLine.slice(0, 5), ['D:\\WINNT\\System32\\cmd.exe', '/d', '/v:off', '/c', 'start']);
  assert.equal(consoleLine[6], '"D:\\WINNT\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"');
  const url = 'http://127.0.0.1:7707/0123456789abcdef0123456789abcdef/';
  assert.deepEqual(browserArgv(url, 'win32', WIN_ENV), [CMD_EXE, '/d', '/v:off', '/c', 'start', '""', url]);
  assert.deepEqual(browserArgv(url, 'win32', {}), [CMD_EXE, '/d', '/v:off', '/c', 'start', '""', url]);
  assert.deepEqual(browserArgv(url, 'win32', { SystemRoot: 'D:\\WINNT' }), ['D:\\WINNT\\System32\\cmd.exe', '/d', '/v:off', '/c', 'start', '""', url]);
  // Nothing is looked up by bare name on Windows any more.
  for (const argv of [consoleLine, browserArgv(url, 'win32', WIN_ENV)]) assert.notEqual(argv[0], 'cmd.exe');
});

// Review Focus 2: a home directory with spaces or a quote.
test('a home directory with spaces stays one argument; a quote in a macOS home is quoted for sh and AppleScript', () => {
  const home = 'C:\\Users\\John Smith';
  const argv = terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home, pathEnv: '', lstat: lstatOnly(), env: WIN_ENV });
  assert.deepEqual(argv, CMD(home, 'tmuxkeep go api', 'go', 'api'));
  assert.equal(argv[12], '"C:\\Users\\John Smith\\scripts\\tmuxkeep.ps1"');
  assert.equal(argv.length, 15);
  const wt = terminalArgv({ verb: 'go', name: 'api', platform: 'win32', home, pathEnv: 'C:\\apps', lstat: lstatOnly('C:\\apps\\wt.exe'), env: WIN_ENV });
  assert.equal(wt[0], 'C:\\apps\\wt.exe');
  assert.equal(wt[12], 'C:\\Users\\John Smith\\scripts\\tmuxkeep.ps1');
  assert.equal(wt.length, 15);
  // Final review L98: inside the wt.exe argv the spaced home is exactly one element (the -File argument).
  assert.deepEqual(wt.filter((a) => a.includes('John Smith')), ['C:\\Users\\John Smith\\scripts\\tmuxkeep.ps1']);
  assert.equal(wt[11], '-File');
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
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'win32', home: WIN_HOME, terminalCmd: 'wezterm start --', env: WIN_ENV }),
    ['wezterm', 'start', '--', ...PS(WIN_HOME, 'auth')]);
});

test('onPath splits PATH by platform and ignores empty parts', () => {
  assert.equal(onPath('x', { platform: 'linux', pathEnv: '::/a', lstat: lstatOnly('/a/x') }), '/a/x');
  assert.equal(onPath('x', { platform: 'linux', pathEnv: '', lstat: lstatOnly('/a/x') }), null);
  assert.equal(onPath('x', { platform: 'linux', pathEnv: '/b:/c', lstat: lstatOnly('/a/x') }), null);
  assert.equal(onPath('x.exe', { platform: 'win32', pathEnv: 'C:\\a;;C:\\b', lstat: lstatOnly('C:\\b\\x.exe') }), 'C:\\b\\x.exe');
  assert.equal(onPath('x.exe', { platform: 'win32', pathEnv: 'C:\\a;;C:\\b', lstat: lstatOnly('C:\\a\\x.exe', 'C:\\b\\x.exe') }), 'C:\\a\\x.exe');
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
  const env = { PATH: 'C:\\apps', ...WIN_ENV };
  const r = await openTerminal({ verb: 'go', name: 'api' }, { platform: 'win32', home: WIN_HOME, env, spawnFn: s.fn, lstat: lstatOnly('C:\\apps\\wt.exe') });
  assert.deepEqual(r, { ok: true, argv: CMD(WIN_HOME, 'tmuxkeep go api', 'go', 'api') });
  assert.equal(s.calls.length, 2);
  assert.equal(s.calls[0].argv[0], 'C:\\apps\\wt.exe');
  assert.deepEqual(s.calls[0].argv.slice(1), ['-w', '0', 'new-tab', '--title', 'tmuxkeep go api', ...PS(WIN_HOME, 'go', 'api')]);
  assert.equal(s.calls[0].options.windowsVerbatimArguments, undefined);
  assert.deepEqual(s.calls[1].argv, CMD(WIN_HOME, 'tmuxkeep go api', 'go', 'api'));
  assert.equal(s.calls[1].options.windowsVerbatimArguments, true);
  assert.equal(s.calls[1].options.shell, false);
  assert.equal(s.calls[1].options.detached, true);
});

test('Windows: when wt.exe and the cmd.exe fallback both fail, the error names both', async () => {
  const s = fakeSpawn(['UNKNOWN', 'ENOENT']);
  const r = await openTerminal({ verb: 'auth' }, { platform: 'win32', home: WIN_HOME, env: { PATH: 'C:\\apps', ...WIN_ENV }, spawnFn: s.fn, lstat: lstatOnly('C:\\apps\\wt.exe') });
  assert.deepEqual(r, { ok: false, error: 'cannot start wt.exe: UNKNOWN; cannot start cmd.exe: ENOENT' });
  assert.equal(s.calls.length, 2);
});

test('Windows: without wt.exe, the console window is started through cmd.exe with verbatim arguments, once', async () => {
  const s = fakeSpawn(['spawn']);
  const env = { PATH: 'C:\\Windows', ...WIN_ENV };
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
    const env = { PATH: 'C:\\Windows', ...WIN_ENV };
    assert.deepEqual(await openTerminal({ verb: 'go', name: 'api' }, { platform: 'win32', home, env, spawnFn: s.fn, lstat: lstatOnly() }),
      { ok: false, error: HOME_REFUSED });
    assert.equal(s.calls.length, 0);
  }
  // A quote (not a percent sign) passes the Windows Terminal path; wt.exe fails to start, and the
  // fallback is the console form: refused, the error names both.
  const quoted = 'C:\\Users\\a"b';
  const w = fakeSpawn(['UNKNOWN']);
  assert.deepEqual(await openTerminal({ verb: 'auth' }, { platform: 'win32', home: quoted, env: { PATH: 'C:\\apps', ...WIN_ENV }, spawnFn: w.fn, lstat: lstatOnly('C:\\apps\\wt.exe') }),
    { ok: false, error: `cannot start wt.exe: UNKNOWN; ${HOME_REFUSED}` });
  assert.equal(w.calls.length, 1);
});

// Final review L179: Windows Terminal expands %NAME% in the tab command line too, so the default wt.exe
// path refuses a percent sign in the home exactly as the cmd.exe fallback does. TERMINAL_CMD is the
// user's own command line and is not checked.
test('Windows: the default wt.exe path refuses a home with a percent sign, with no spawn; TERMINAL_CMD does not', async () => {
  const wtOnly = lstatOnly('C:\\apps\\wt.exe');
  for (const home of ['C:\\Users\\100%', 'C:\\Users\\%USERNAME%', 'C:\\Users\\a%b']) {
    assert.throws(() => terminalArgv({ verb: 'auth', platform: 'win32', home, pathEnv: 'C:\\apps', lstat: wtOnly, env: WIN_ENV }), { message: HOME_REFUSED });
    const s = fakeSpawn([]);
    assert.deepEqual(await openTerminal({ verb: 'auth' }, { platform: 'win32', home, env: { PATH: 'C:\\apps', ...WIN_ENV }, spawnFn: s.fn, lstat: wtOnly }),
      { ok: false, error: HOME_REFUSED });
    assert.equal(s.calls.length, 0);
  }
  // A home with no percent sign still goes through wt.exe, and a quote alone does not stop it.
  const t = fakeSpawn(['spawn']);
  const ok = await openTerminal({ verb: 'auth' }, { platform: 'win32', home: 'C:\\Users\\John Smith', env: { PATH: 'C:\\apps', ...WIN_ENV }, spawnFn: t.fn, lstat: wtOnly });
  assert.equal(ok.ok, true);
  assert.equal(ok.argv[0], 'C:\\apps\\wt.exe');
  const home = 'C:\\Users\\100%';
  assert.deepEqual(terminalArgv({ verb: 'auth', platform: 'win32', home, terminalCmd: 'wezterm start --', env: WIN_ENV }), ['wezterm', 'start', '--', ...PS(home, 'auth')]);
  const c = fakeSpawn(['spawn']);
  const viaCmd = await openTerminal({ verb: 'auth' }, { platform: 'win32', home, terminalCmd: 'wezterm start --', env: { PATH: 'C:\\apps', ...WIN_ENV }, spawnFn: c.fn, lstat: wtOnly });
  assert.equal(viaCmd.ok, true);
  assert.equal(c.calls[0].argv[0], 'wezterm');
});

// Final review M7: with absolute paths argv[0] is no longer the bare name cmd.exe or wt.exe, so the
// verbatim flag and the wt fallback must not depend on it. windowsVerbatimArguments is set for the
// cmd.exe spawns only; a failed wt.exe falls back to the console window; TERMINAL_CMD gets neither.
test('Windows: the verbatim flag is set exactly for the cmd.exe spawns and the wt.exe failure still falls back', async () => {
  const wtOnly = lstatOnly('C:\\apps\\wt.exe');
  const env = { PATH: 'C:\\apps', ...WIN_ENV };
  // wt.exe starts: one spawn, no verbatim flag.
  const a = fakeSpawn(['spawn']);
  assert.equal((await openTerminal({ verb: 'auth' }, { platform: 'win32', home: WIN_HOME, env, spawnFn: a.fn, lstat: wtOnly })).ok, true);
  assert.equal(a.calls.length, 1);
  assert.equal(a.calls[0].options.windowsVerbatimArguments, undefined);
  // wt.exe fails: the second spawn is cmd.exe, by absolute path, with the verbatim flag.
  const b = fakeSpawn(['UNKNOWN', 'spawn']);
  assert.equal((await openTerminal({ verb: 'auth' }, { platform: 'win32', home: WIN_HOME, env, spawnFn: b.fn, lstat: wtOnly })).ok, true);
  assert.equal(b.calls.length, 2);
  assert.equal(b.calls[0].options.windowsVerbatimArguments, undefined);
  assert.equal(b.calls[1].argv[0], CMD_EXE);
  assert.equal(b.calls[1].options.windowsVerbatimArguments, true);
  // No wt.exe: the console window is the first spawn, with the verbatim flag.
  const c = fakeSpawn(['spawn']);
  await openTerminal({ verb: 'auth' }, { platform: 'win32', home: WIN_HOME, env, spawnFn: c.fn, lstat: lstatOnly() });
  assert.equal(c.calls[0].argv[0], CMD_EXE);
  assert.equal(c.calls[0].options.windowsVerbatimArguments, true);
  // The case of the path does not matter (Windows paths are case-insensitive): SystemRoot as C:\WINDOWS.
  const d = fakeSpawn(['spawn']);
  await openTerminal({ verb: 'auth' }, { platform: 'win32', home: WIN_HOME, env: { PATH: 'C:\\apps', SystemRoot: 'C:\\WINDOWS' }, spawnFn: d.fn, lstat: lstatOnly() });
  assert.equal(d.calls[0].argv[0], 'C:\\WINDOWS\\System32\\cmd.exe');
  assert.equal(d.calls[0].options.windowsVerbatimArguments, true);
  // TERMINAL_CMD naming cmd.exe or wt.exe is the user's own command: no verbatim flag, no fallback.
  for (const terminalCmd of [`${CMD_EXE} /c start`, 'wt.exe -w 0 new-tab', 'cmd.exe /c start']) {
    const e = fakeSpawn(['UNKNOWN']);
    const r = await openTerminal({ verb: 'auth' }, { platform: 'win32', home: WIN_HOME, terminalCmd, env, spawnFn: e.fn, lstat: wtOnly });
    assert.equal(r.ok, false);
    assert.equal(e.calls.length, 1, terminalCmd);
    assert.equal(e.calls[0].options.windowsVerbatimArguments, undefined, terminalCmd);
  }
  // Other platforms never use the flag.
  const f = fakeSpawn(['spawn']);
  await openTerminal({ verb: 'auth' }, { platform: 'linux', home: '/home/you', env: { TERMINAL: 'kitty', PATH: '/nowhere' }, spawnFn: f.fn, lstat: lstatOnly() });
  assert.equal(f.calls[0].options.windowsVerbatimArguments, undefined);
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
  assert.deepEqual(browserArgv(url, 'win32', WIN_ENV), [CMD_EXE, '/d', '/v:off', '/c', 'start', '""', url]);
  assert.deepEqual(browserArgv(url, 'darwin'), ['open', url]);
  assert.deepEqual(browserArgv(url, 'linux'), ['xdg-open', url]);
  const s = fakeSpawn(['spawn']);
  assert.deepEqual(await openBrowser(url, { platform: 'win32', env: WIN_ENV, spawnFn: s.fn }), { argv: browserArgv(url, 'win32', WIN_ENV), error: null });
  assert.equal(s.calls[0].argv[0], CMD_EXE);
  assert.equal(s.calls[0].options.windowsVerbatimArguments, true);
  // SystemRoot comes from the injected env, with C:\Windows when it has none.
  const r = fakeSpawn(['spawn']);
  await openBrowser(url, { platform: 'win32', env: { SystemRoot: 'D:\\WINNT' }, spawnFn: r.fn });
  assert.equal(r.calls[0].argv[0], 'D:\\WINNT\\System32\\cmd.exe');
  const n = fakeSpawn(['spawn']);
  await openBrowser(url, { platform: 'win32', env: {}, spawnFn: n.fn });
  assert.equal(n.calls[0].argv[0], CMD_EXE);
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
