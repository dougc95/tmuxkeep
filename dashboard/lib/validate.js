// validate.js - the broker's argument rules (vps/tmuxkeep), applied before any ssh call so a bad
// input never costs a round trip, a TOTP prompt or an audit line (spec 6.4). Each check returns
// null when the input is acceptable, or the message the page shows. Messages repeat the broker's
// wording where the broker has one.

export const NAME_RE = /^[a-z][a-z0-9_-]{0,31}$/;
export const TOMB_RE = /^zz~[a-z][a-z0-9_-]{0,31}~[0-9]+$/;
export const URL_RE = /^https:\/\/[!-~]+$/;
// One line on purpose: tests/bats/parity.bats reads it.
export const ACTION_VERBS = ['new', 'send', 'rename', 'lock', 'unlock', 'rm', 'restore', 'resume', 'log', 'peek', 'status', 'auth'];
export const SEND_MAX_BYTES = 65536;

const CONTROL_RE = /[\x00-\x1f\x7f]/;
const PRINTABLE_RE = /^[\x20-\x7e]*$/;
const COUNT_RE = /^[0-9]{1,4}$/;

const NEW_USAGE = 'usage: tmuxkeep new <name> [--repo <https-url>] [--cmd <text>] [--shell]';
const RESUME_USAGE = 'usage: tmuxkeep resume <name> [--cmd <text>] [--shell]';

function nameError(s) {
  if (s === undefined) return 'missing session name';
  return NAME_RE.test(s) ? null : 'invalid session name';
}

function nameOrTombError(s) {
  if (s === undefined) return 'missing session name';
  return NAME_RE.test(s) || TOMB_RE.test(s) ? null : 'invalid session name';
}

function cmdError(s) {
  return s.length <= 200 && PRINTABLE_RE.test(s) ? null : '--cmd must be at most 200 printable ASCII characters';
}

function shown(s) {
  return s.replace(/[^\x20-\x7e]/g, '?').slice(0, 32);
}

// checkLaunch(args, isNew): the one checker behind new and resume, which share the broker's option
// loop (verb_new, verb_resume): a name and --cmd <text> and --shell, each at most once, in any order.
// new also takes --repo <url>, and a leading -- word is just a name that fails the name rule; resume
// answers its usage for any other -- word and for a missing name, where new says "missing session name".
function checkLaunch(args, isNew) {
  const usage = isNew ? NEW_USAGE : RESUME_USAGE;
  let name;
  let repo;
  let cmd;
  let shell = false;
  for (let i = 0; i < args.length; i += 1) {
    const a = args[i];
    if (isNew && a === '--repo') {
      if (repo !== undefined || i + 1 >= args.length) return usage;
      i += 1;
      repo = args[i];
    } else if (a === '--cmd') {
      if (cmd !== undefined || i + 1 >= args.length) return usage;
      i += 1;
      cmd = args[i];
    } else if (a === '--shell') {
      if (shell) return usage;
      shell = true;
    } else if (!isNew && a.startsWith('--')) {
      return usage;
    } else {
      if (name !== undefined) return usage;
      name = a;
    }
  }
  if (name === undefined && !isNew) return usage;
  const e = nameError(name);
  if (e) return e;
  if (repo !== undefined && !URL_RE.test(repo)) return '--repo must be an https:// URL';
  if (shell && cmd !== undefined) return '--shell and --cmd cannot be combined';
  return cmd === undefined ? null : cmdError(cmd);
}

const CHECKS = {
  new(args) {
    return checkLaunch(args, true);
  },

  send(args) {
    const e = nameError(args[0]);
    if (e) return e;
    const text = args.slice(1).join(' ');
    if (text === '') return 'nothing to send';
    if (CONTROL_RE.test(text)) return 'text contains control characters (line breaks and tabs cannot be sent; send one line at a time)';
    if (Buffer.byteLength(text, 'utf8') > SEND_MAX_BYTES) return `text longer than ${SEND_MAX_BYTES} bytes`;
    return null;
  },

  rename(args) {
    if (args.length !== 2) return 'usage: tmuxkeep rename <old> <new>';
    return nameError(args[0]) || (NAME_RE.test(args[1]) ? null : 'invalid session name');
  },

  lock(args) {
    if (args.length > 1) return 'usage: tmuxkeep lock <name>';
    return nameError(args[0]);
  },

  unlock(args) {
    if (args.length !== 1) return 'usage: tmuxkeep unlock <name>';
    return nameError(args[0]);
  },

  restore(args) {
    if (args.length !== 1) return 'usage: tmuxkeep restore <name>';
    return nameError(args[0]);
  },

  rm(args) {
    const usage = 'usage: tmuxkeep rm <name> [--now --confirm <name>]';
    let name;
    let now = false;
    let confirm;
    for (let i = 0; i < args.length; i += 1) {
      const a = args[i];
      if (a === '--now') {
        if (now) return usage;
        now = true;
      } else if (a === '--confirm') {
        if (confirm !== undefined || i + 1 >= args.length) return usage;
        i += 1;
        confirm = args[i];
      } else if (a.startsWith('--')) {
        return usage;
      } else {
        if (name !== undefined) return usage;
        name = a;
      }
    }
    if (name === undefined) return usage;
    if (confirm !== undefined && !now) return '--confirm needs --now';
    if (!now) return nameError(name);
    return nameOrTombError(name) || (confirm === name ? null : `--confirm must equal ${name}`);
  },

  resume(args) {
    return checkLaunch(args, false);
  },

  log(args) {
    if (args.length === 0) return null;
    if (args.length !== 2 || args[0] !== '-n') return 'usage: tmuxkeep log [-n N]';
    return COUNT_RE.test(args[1]) ? null : '-n must be 0-9999';
  },

  peek(args) {
    if (args.length === 2 || args.length > 3) return 'usage: tmuxkeep peek <name> [-n N]';
    if (args.length === 3) {
      if (args[1] !== '-n') return 'usage: tmuxkeep peek <name> [-n N]';
      if (!COUNT_RE.test(args[2])) return '-n must be 0-9999';
    }
    return nameOrTombError(args[0]);
  },

  status(args) {
    if (args.includes('--follow')) return 'status --follow is not an action';
    if (args.length === 0) return null;
    if (args.length !== 2 || args[0] !== '--lines') return 'usage: tmuxkeep status [--lines N]';
    return COUNT_RE.test(args[1]) && Number(args[1]) <= 40 ? null : '--lines must be 0-40';
  },

  auth(args) {
    return args.length === 1 && args[0] === '--end' ? null : 'only auth --end is allowed from the dashboard';
  },
};

// checkAction(words): null when /api/action may run these words, else the reason (spec 6.4).
export function checkAction(words) {
  if (!Array.isArray(words) || words.length === 0) return 'words must be a non-empty array of strings';
  for (const w of words) {
    if (typeof w !== 'string') return 'words must be a non-empty array of strings';
    if (w === '') return 'empty argument';
    if (!w.isWellFormed()) return 'argument is not valid text';
  }
  const [verb, ...args] = words;
  if (!ACTION_VERBS.includes(verb)) return `not allowed from the dashboard: ${shown(verb)}`;
  return CHECKS[verb](args);
}

// checkTerminal(body): null when /api/terminal may open a terminal for this body (spec 6.5).
export function checkTerminal(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return 'body must be an object';
  const keys = Object.keys(body).sort().join(',');
  if (body.verb === 'auth') return keys === 'verb' ? null : 'auth takes no name';
  if (body.verb === 'go') {
    if (keys !== 'name,verb' || typeof body.name !== 'string') return 'go needs a session name';
    return nameError(body.name);
  }
  return 'verb must be go or auth';
}
