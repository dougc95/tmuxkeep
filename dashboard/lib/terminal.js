// terminal.js - starts the programs the dashboard hands work to (spec 6.5, 6.1 step 5, D14): a
// terminal window or tab that runs the laptop wrapper for go and auth, so the TOTP code is only ever
// typed into a real terminal, and the browser. Every spawn is an argv array with shell: false.
// TMUXKEEP_TERMINAL_DRYRUN=1 returns the argv instead of starting anything (tests).
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const HOME_REFUSED = 'tmuxkeep ui: the home folder path contains " or %; set TERMINAL_CMD to open terminals another way';
const BAD_REQUEST = 'tmuxkeep ui: invalid terminal request';
const BAD_ADDRESS = 'tmuxkeep ui: refusing to open an unexpected address';
const NAME_RE = /^[a-z][a-z0-9_-]{0,31}$/;
const URL_RE = /^http:\/\/127\.0\.0\.1:[0-9]{4,5}\/[0-9a-f]{32}\/$/;

// On Windows cmd.exe and powershell.exe are started by absolute path under SystemRoot (taken from the
// injected env, C:\Windows when it has none), never by a lookup that could pick up a program of the
// same name in the current folder (final review L104). Only the two names are ever built this way.
function systemDir(env) {
  return path.win32.join((env && env.SystemRoot) || 'C:\\Windows', 'System32');
}
function cmdExe(env) {
  return path.win32.join(systemDir(env), 'cmd.exe');
}
function powershellExe(env) {
  return path.win32.join(systemDir(env), 'WindowsPowerShell', 'v1.0', 'powershell.exe');
}

// isWindowsProgram(argv0, name): whether argv0, a Windows program path, is the program called name.
// Compares the lower-cased basename, so it holds for a bare name and for an absolute path alike.
function isWindowsProgram(argv0, name) {
  return path.win32.basename(argv0).toLowerCase() === name;
}

// wrapperArgv({verb, name, platform, home, env}): the command that runs the installed wrapper.
export function wrapperArgv({ verb, name, platform, home, env }) {
  const words = name ? [verb, name] : [verb];
  if (platform === 'win32') {
    const script = path.win32.join(home, 'scripts', 'tmuxkeep.ps1');
    return [powershellExe(env), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', script, ...words];
  }
  return [path.posix.join(home, '.local', 'bin', 'tmuxkeep'), ...words];
}

// onPath(file, {platform, pathEnv, lstat}): the full path of the first directory of pathEnv that holds
// file, or null. lstat, not stat or exists: the Windows Terminal alias WindowsApps\wt.exe is a reparse
// point that stat refuses with EACCES (seen on Node 24), while lstat finds it.
export function onPath(file, { platform, pathEnv, lstat = fs.lstatSync }) {
  const p = platform === 'win32' ? path.win32 : path.posix;
  for (const dir of (pathEnv || '').split(platform === 'win32' ? ';' : ':')) {
    if (!dir) continue;
    const candidate = p.join(dir, file);
    try {
      lstat(candidate);
      return candidate;
    } catch {
      // not in this directory
    }
  }
  return null;
}

// titleFor(verb, name): the window or tab title, "tmuxkeep <verb> [<name>]".
function titleFor(verb, name) {
  return ['tmuxkeep', verb, ...(name ? [name] : [])].join(' ');
}

// consoleArgv({verb, name, home, env}): the Windows command that opens a console window of its own
// (used when wt.exe is missing or fails to start). powershell.exe cannot get a console from a detached,
// stdio-less spawn, so cmd.exe's start opens one for it. /d skips the registry AutoRun commands and
// /v:off keeps delayed expansion off, whatever the machine's defaults are. The caller spawns this with
// windowsVerbatimArguments: Node then adds no quotes, and the title, the powershell.exe path and the
// script path carry their own. cmd.exe expands %VAR% even inside double quotes, so a home with " or %
// is refused. The verb and the name are checked by openTerminal (letters, digits, - and _ only).
export function consoleArgv({ verb, name, home, env }) {
  if (/["%]/.test(home)) throw new Error(HOME_REFUSED);
  const script = path.win32.join(home, 'scripts', 'tmuxkeep.ps1');
  const words = name ? [verb, name] : [verb];
  return [cmdExe(env), '/d', '/v:off', '/c', 'start', `"${titleFor(verb, name)}"`, `"${powershellExe(env)}"`, '-NoProfile',
    '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', `"${script}"`, ...words];
}

// shQuote(s): s in single quotes for sh.
export function shQuote(s) {
  return `'${s.replaceAll("'", "'\\''")}'`;
}

// appleScriptString(s): s as an AppleScript string literal.
export function appleScriptString(s) {
  return `"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
}

// terminalArgv(opts): the launcher argv for {verb, name} (spec 6.5), in this order: TERMINAL_CMD;
// Windows Terminal or a console window; macOS Terminal; x-terminal-emulator, then $TERMINAL.
// Throws when Linux has neither.
export function terminalArgv({ verb, name, platform, home, terminalCmd = '', pathEnv = '', terminalEnv = '', lstat, env }) {
  const cmd = wrapperArgv({ verb, name, platform, home, env });
  if (terminalCmd) return [...terminalCmd.split(' ').filter((w) => w !== ''), ...cmd];
  if (platform === 'win32') {
    const wt = onPath('wt.exe', { platform, pathEnv, lstat });
    if (wt) {
      // Windows Terminal expands %NAME% in the tab command line too, like cmd.exe does (final review L179).
      if (home.includes('%')) throw new Error(HOME_REFUSED);
      return [wt, '-w', '0', 'new-tab', '--title', titleFor(verb, name), ...cmd];
    }
    return consoleArgv({ verb, name, home, env });
  }
  if (platform === 'darwin') {
    // Orchestrator ruling Q24: the second -e brings Terminal in front of the browser.
    return ['osascript', '-e', `tell application "Terminal" to do script ${appleScriptString(cmd.map(shQuote).join(' '))}`,
      '-e', 'tell application "Terminal" to activate'];
  }
  if (onPath('x-terminal-emulator', { platform, pathEnv, lstat })) return ['x-terminal-emulator', '-e', ...cmd];
  if (terminalEnv) return [terminalEnv, '-e', ...cmd];
  throw new Error('no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config');
}

// spawnDetached(argv, spawnFn, extra): resolves null once the program started, else the reason.
export function spawnDetached(argv, spawnFn = spawn, extra = {}) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawnFn(argv[0], argv.slice(1), { detached: true, stdio: 'ignore', shell: false, windowsHide: false, ...extra });
    } catch (err) {
      resolve(err.code || err.message);
      return;
    }
    child.once('error', (err) => resolve(err.code || err.message));
    child.once('spawn', () => {
      child.unref();
      resolve(null);
    });
  });
}

// requestOk(request): true for exactly {verb: 'go', name: <session name>} or {verb: 'auth'}. The route
// has already run checkTerminal; this is a second check so nothing odd can reach a command line.
function requestOk(request) {
  if (request === null || typeof request !== 'object') return false;
  if (request.verb === 'auth') return request.name === undefined;
  if (request.verb === 'go') return typeof request.name === 'string' && NAME_RE.test(request.name);
  return false;
}

// openTerminal(request, opts): {ok: true, argv} or {ok: false, error} (spec 6.5).
export async function openTerminal(request, { platform = process.platform, home, terminalCmd = '', env = process.env, spawnFn = spawn, lstat = fs.lstatSync } = {}) {
  if (!requestOk(request)) return { ok: false, error: BAD_REQUEST };
  const base = { verb: request.verb, name: request.name, platform, home };
  let argv;
  try {
    argv = terminalArgv({ ...base, terminalCmd, pathEnv: env.PATH || '', terminalEnv: env.TERMINAL || '', lstat, env });
  } catch (err) {
    return { ok: false, error: err.message };
  }
  if (env.TMUXKEEP_TERMINAL_DRYRUN === '1') return { ok: true, argv };
  // The cmd.exe start form must reach cmd.exe verbatim; every other argv is quoted by Node as usual.
  // argv[0] is an absolute path now, so the program is recognised by its lower-cased basename.
  const ownLauncher = platform === 'win32' && !terminalCmd;
  const verbatim = ownLauncher && isWindowsProgram(argv[0], 'cmd.exe');
  const failed = await spawnDetached(argv, spawnFn, verbatim ? { windowsVerbatimArguments: true } : {});
  if (failed === null) return { ok: true, argv };
  // The Windows Terminal alias can be found and still fail to start; a console window of its own
  // (cmd.exe start) is the fallback. Its failure is reported together with the first one.
  if (ownLauncher && isWindowsProgram(argv[0], 'wt.exe')) {
    let fallback;
    try {
      fallback = consoleArgv({ ...base, env });
    } catch (err) {
      return { ok: false, error: `cannot start wt.exe: ${failed}; ${err.message}` };
    }
    const failedToo = await spawnDetached(fallback, spawnFn, { windowsVerbatimArguments: true });
    if (failedToo === null) return { ok: true, argv: fallback };
    return { ok: false, error: `cannot start wt.exe: ${failed}; cannot start cmd.exe: ${failedToo}` };
  }
  // The message names the program, not its absolute path (cannot start cmd.exe: ENOENT).
  return { ok: false, error: `cannot start ${ownLauncher ? path.win32.basename(argv[0]) : argv[0]}: ${failed}` };
}

// browserArgv(url, platform, env): the command that opens url in the default browser (spec 6.1). On
// Windows cmd.exe is started by absolute path with /d /v:off, as in consoleArgv.
export function browserArgv(url, platform, env = process.env) {
  if (platform === 'win32') return [cmdExe(env), '/d', '/v:off', '/c', 'start', '""', url];
  if (platform === 'darwin') return ['open', url];
  return ['xdg-open', url];
}

// openBrowser(url, opts): {argv, error}; error is null once the program started. cmd.exe gets its
// arguments verbatim, so the "" title argument reaches start as two quote characters. Only the
// dashboard's own address is opened ({ok: false, error} for any other), so nothing cmd.exe would
// interpret can reach start.
export async function openBrowser(url, { platform = process.platform, env = process.env, spawnFn = spawn } = {}) {
  if (typeof url !== 'string' || !URL_RE.test(url)) return { ok: false, error: BAD_ADDRESS };
  const argv = browserArgv(url, platform, env);
  if (env.TMUXKEEP_TERMINAL_DRYRUN === '1') return { argv, error: null };
  const error = await spawnDetached(argv, spawnFn, { windowsVerbatimArguments: platform === 'win32', windowsHide: true });
  return { argv, error };
}
