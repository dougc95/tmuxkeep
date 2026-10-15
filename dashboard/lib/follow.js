// follow.js - the one VPS connection the dashboard keeps (spec 6.3, D15): "status --follow" as a
// child process whose stdout is one JSON object per line. Each object replaces the snapshot. When the
// child ends, it is started again after 2, 4, 8, 16, 30, 30... seconds (back to 2 after an object).
// With no touch() (no /api/state request) for IDLE_MS the child is stopped; the next touch() starts
// it again, so a closed browser tab does not keep an ssh session open all day.

export const FOLLOW_WORDS = Object.freeze(['status', '--follow', '--lines', '12']);
export const BACKOFF_MS = Object.freeze([2000, 4000, 8000, 16000, 30000]);
export const IDLE_MS = 120000;
export const MAX_LINE_CHARS = 8 * 1024 * 1024;

const realClock = {
  now: () => Date.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (t) => clearTimeout(t),
};

// endMessage(code, err, lastErr): the error shown after the child ended. Exit 255 is ssh itself failing
// (unreachable, but also a rejected host key or key): the last stderr line, when there is one, follows in
// parentheses so the reason reaches the page.
export function endMessage(code, err, lastErr) {
  if (err) return `cannot run ssh: ${err.code || err.message}`;
  if (code === 255) return lastErr ? `ssh exited 255: VPS unreachable (${lastErr})` : 'ssh exited 255: VPS unreachable';
  if (lastErr) return lastErr;
  return code === null ? 'ssh was stopped by a signal' : `ssh exited ${code}`;
}

// createFollower({spawnChild, clock, backoffMs, idleMs}): spawnChild() returns a ChildProcess (or an
// object with the same events, stdout, stderr and kill()). Returns {touch, state, stop, stats}.
export function createFollower({ spawnChild, clock = realClock, backoffMs = BACKOFF_MS, idleMs = IDLE_MS }) {
  const st = { snapshot: null, connected: false, updated: null, error: null };
  let child = null;
  let restartTimer = null;
  let idleTimer = null;
  let idle = false;
  let stopped = false;
  let attempt = 0;
  let badLines = 0;
  let starts = 0;

  function onLine(raw) {
    const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    if (line.trim() === '') return;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      badLines += 1;
      return;
    }
    if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
      badLines += 1;
      return;
    }
    st.snapshot = obj;
    st.updated = clock.now();
    st.connected = true;
    st.error = null;
    attempt = 0;
  }

  function schedule() {
    if (stopped || idle) return;
    const delay = backoffMs[Math.min(attempt, backoffMs.length - 1)];
    attempt += 1;
    restartTimer = clock.setTimeout(start, delay);
  }

  function start() {
    restartTimer = null;
    starts += 1;
    let ended = false;
    let buf = '';
    let errTail = '';
    let lastErr = '';
    let c;
    const end = (code, err) => {
      if (ended) return;
      ended = true;
      if (child !== c) return; // stopped on purpose: idle or shutdown
      child = null;
      st.connected = false;
      st.error = endMessage(code, err, lastErr);
      schedule();
    };
    try {
      c = spawnChild();
    } catch (err) {
      c = null;
      child = null;
      st.connected = false;
      st.error = endMessage(null, err, '');
      schedule();
      return;
    }
    child = c;
    // The 'error' listener comes first: for EMFILE and ENFILE spawn returns a child with no stdio
    // streams and reports the failure later as an 'error' event, which must never go unhandled.
    c.on('error', (err) => end(null, err));
    c.on('close', (code) => end(code, null));
    c.stdout?.setEncoding('utf8');
    c.stderr?.setEncoding('utf8');
    c.stdout?.on('data', (chunk) => {
      if (child !== c) return;
      buf += chunk;
      let nl = buf.indexOf('\n');
      while (nl >= 0) {
        onLine(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
        nl = buf.indexOf('\n');
      }
      if (buf.length > MAX_LINE_CHARS) {
        badLines += 1;
        buf = '';
      }
    });
    c.stderr?.on('data', (chunk) => {
      errTail = (errTail + chunk).slice(-4096);
      const lines = errTail.split('\n').map((l) => l.replace(/\r$/, '')).filter((l) => l.trim() !== '');
      if (lines.length > 0) lastErr = lines[lines.length - 1];
    });
  }

  function goIdle() {
    idleTimer = null;
    idle = true;
    attempt = 0;
    if (restartTimer) {
      clock.clearTimeout(restartTimer);
      restartTimer = null;
    }
    const c = child;
    child = null;
    st.connected = false;
    if (c) c.kill();
  }

  return {
    // touch(): a page asked for the state. Starts the child when none runs or waits to restart.
    touch() {
      if (stopped) return;
      if (idleTimer) clock.clearTimeout(idleTimer);
      idleTimer = clock.setTimeout(goIdle, idleMs);
      idle = false;
      if (!child && !restartTimer) start();
    },
    // state(): the /api/state body (spec 6.2).
    state() {
      return { snapshot: st.snapshot, connected: st.connected, updated: st.updated, error: st.error };
    },
    // stop(): for shutdown. Kills the child; nothing restarts.
    stop() {
      stopped = true;
      for (const t of [restartTimer, idleTimer]) if (t) clock.clearTimeout(t);
      restartTimer = null;
      idleTimer = null;
      const c = child;
      child = null;
      st.connected = false;
      if (c) c.kill();
    },
    // stats(): for the tests.
    stats() {
      return { badLines, starts, running: child !== null, waiting: restartTimer !== null };
    },
  };
}
