// terminal.js - starts the programs the dashboard hands work to (spec 6.5, 6.1 step 5, D14): a
// terminal window or tab that runs the laptop wrapper for go and auth, so the TOTP code is only ever
// typed into a real terminal, and the browser. Every spawn is an argv array with shell: false.
// TMUXKEEP_TERMINAL_DRYRUN=1 returns the argv instead of starting anything (tests).
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// wrapperArgv({verb, name, platform, home}): the command that runs the installed wrapper.
export function wrapperArgv({ verb, name, platform, home }) {
  const words = name ? [verb, name] : [verb];
  if (platform === 'win32') {
    const script = path.win32.join(home, 'scripts', 'tmuxkeep.ps1');
    return ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', script, ...words];
  }
  return [path.posix.join(home, '.local', 'bin', 'tmuxkeep'), ...words];
}

// onPath(file, {platform, pathEnv, lstat}): true when a directory of pathEnv holds file. lstat, not
// stat or exists: the Windows Terminal alias WindowsApps\wt.exe is a reparse point that stat refuses
// with EACCES (seen on Node 24), while lstat finds it.
export function onPath(file, { platform, pathEnv, lstat = fs.lstatSync }) {
  const p = platform === 'win32' ? path.win32 : path.posix;
  for (const dir of (pathEnv || '').split(platform === 'win32' ? ';' : ':')) {
    if (!dir) continue;
    try {
      lstat(p.join(dir, file));
      return true;
    } catch {
      // not in this directory
    }
  }
  return false;
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
export function terminalArgv({ verb, name, platform, home, terminalCmd = '', pathEnv = '', terminalEnv = '', lstat }) {
  const cmd = wrapperArgv({ verb, name, platform, home });
  if (terminalCmd) return [...terminalCmd.split(' ').filter((w) => w !== ''), ...cmd];
  if (platform === 'win32') {
    if (onPath('wt.exe', { platform, pathEnv, lstat })) {
      const title = ['tmuxkeep', verb, ...(name ? [name] : [])].join(' ');
      return ['wt.exe', '-w', '0', 'new-tab', '--title', title, ...cmd];
    }
    return cmd;
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

// openTerminal(request, opts): {ok: true, argv} or {ok: false, error} (spec 6.5).
export async function openTerminal(request, { platform = process.platform, home, terminalCmd = '', env = process.env, spawnFn = spawn, lstat = fs.lstatSync } = {}) {
  const base = { verb: request.verb, name: request.name, platform, home };
  let argv;
  try {
    argv = terminalArgv({ ...base, terminalCmd, pathEnv: env.PATH || '', terminalEnv: env.TERMINAL || '', lstat });
  } catch (err) {
    return { ok: false, error: err.message };
  }
  if (env.TMUXKEEP_TERMINAL_DRYRUN === '1') return { ok: true, argv };
  const failed = await spawnDetached(argv, spawnFn);
  if (failed === null) return { ok: true, argv };
  // The Windows Terminal alias can be found and still fail to start; a console window always works.
  if (platform === 'win32' && argv[0] === 'wt.exe' && !terminalCmd) {
    const fallback = wrapperArgv(base);
    if (await spawnDetached(fallback, spawnFn) === null) return { ok: true, argv: fallback };
  }
  return { ok: false, error: `cannot start ${argv[0]}: ${failed}` };
}

// browserArgv(url, platform): the command that opens url in the default browser (spec 6.1).
export function browserArgv(url, platform) {
  if (platform === 'win32') return ['cmd.exe', '/c', 'start', '""', url];
  if (platform === 'darwin') return ['open', url];
  return ['xdg-open', url];
}

// openBrowser(url, opts): {argv, error}; error is null once the program started. cmd.exe gets its
// arguments verbatim, so the "" title argument reaches start as two quote characters.
export async function openBrowser(url, { platform = process.platform, env = process.env, spawnFn = spawn } = {}) {
  const argv = browserArgv(url, platform);
  if (env.TMUXKEEP_TERMINAL_DRYRUN === '1') return { argv, error: null };
  const error = await spawnDetached(argv, spawnFn, { windowsVerbatimArguments: platform === 'win32', windowsHide: true });
  return { argv, error };
}
