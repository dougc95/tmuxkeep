// http.js - the request handler of tmuxkeep ui (spec 6.2, D17). Every request is checked in this
// order: the Host header must be 127.0.0.1:<port> or localhost:<port> (the DNS rebinding guard), then
// the path must be /<token>/ followed by a listed route for that method; either failure is 404 with
// an empty body, before anything else happens. A POST must then carry JSON from this origin, or it is
// 403 with an empty body. No CORS header is ever sent.
import crypto from 'node:crypto';
import { checkAction, checkTerminal } from './validate.js';

export const MAX_BODY_BYTES = 70000;
// Node answers a request without Host with its own 400; the spec wants 404 from the handler.
export const SERVER_OPTIONS = Object.freeze({ requireHostHeader: false });
export const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
const SECURITY_HEADERS = Object.freeze({
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': CSP,
});
const STATIC = Object.freeze({
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/style.css': ['style.css', 'text/css; charset=utf-8'],
});
const ROUTES = new Set(['GET /', 'GET /app.js', 'GET /style.css', 'GET /api/state', 'POST /api/action', 'POST /api/terminal']);
const TOKEN_PATH_RE = /^\/([0-9a-f]{32})(\/[^?]*)(\?.*)?$/;

function send(res, status, type, body) {
  const headers = { ...SECURITY_HEADERS, 'Content-Length': String(body.length) };
  if (type) headers['Content-Type'] = type;
  res.writeHead(status, headers);
  res.end(body);
}

const empty = (res, status) => send(res, status, null, Buffer.alloc(0));
const json = (res, status, value) => send(res, status, 'application/json; charset=utf-8', Buffer.from(JSON.stringify(value), 'utf8'));

// readJson(req): the parsed body, or undefined when it is larger than MAX_BODY_BYTES or not JSON.
function readJson(req) {
  return new Promise((resolve) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size <= MAX_BODY_BYTES) chunks.push(chunk);
    });
    req.on('end', () => {
      if (size > MAX_BODY_BYTES) return resolve(undefined);
      try {
        return resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        return resolve(undefined);
      }
    });
    req.on('error', () => resolve(undefined));
  });
}

// createHandler(opts): the (req, res) handler. opts: token (32 hex), port, files {name: Buffer} for
// index.html, app.js and style.css, getState() for /api/state, runAction(words) and
// openTerminal({verb, name}) returning promises.
export function createHandler({ token, port, files, getState, runAction, openTerminal }) {
  const hosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
  const origins = new Set([`http://127.0.0.1:${port}`, `http://localhost:${port}`]);
  const tokenBytes = Buffer.from(token, 'utf8');
  let busy = false;

  function route(req) {
    const m = TOKEN_PATH_RE.exec(req.url || '');
    if (!m || !crypto.timingSafeEqual(Buffer.from(m[1], 'utf8'), tokenBytes)) return null;
    const key = `${req.method} ${m[2]}`;
    return ROUTES.has(key) ? key : null;
  }

  function postAllowed(req) {
    const type = (req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
    if (type !== 'application/json') return false;
    const origin = req.headers.origin;
    if (origin !== undefined && !origins.has(origin)) return false;
    const site = req.headers['sec-fetch-site'];
    return site === undefined || site === 'same-origin' || site === 'none';
  }

  async function handle(req, res) {
    if (!hosts.has((req.headers.host || '').toLowerCase())) return empty(res, 404);
    const key = route(req);
    if (key === null) return empty(res, 404);
    if (req.method === 'GET') {
      if (key === 'GET /api/state') return json(res, 200, getState());
      const [file, type] = STATIC[key.slice(4)];
      return send(res, 200, type, files[file]);
    }
    if (!postAllowed(req)) {
      req.resume();
      return empty(res, 403);
    }
    const body = await readJson(req);
    if (body === undefined) return empty(res, 403);
    if (key === 'POST /api/terminal') {
      const problem = checkTerminal(body);
      if (problem) return json(res, 400, { error: problem });
      const result = await openTerminal(body.verb === 'go' ? { verb: 'go', name: body.name } : { verb: 'auth' });
      return json(res, result.ok ? 200 : 500, result);
    }
    const words = body !== null && typeof body === 'object' && !Array.isArray(body) ? body.words : undefined;
    const problem = checkAction(words);
    if (problem) return json(res, 400, { error: problem });
    if (busy) return json(res, 409, { error: 'another action is still running' });
    busy = true;
    try {
      return json(res, 200, await runAction(words));
    } finally {
      busy = false;
    }
  }

  return (req, res) => {
    handle(req, res).catch(() => {
      if (!res.headersSent) empty(res, 500);
      else res.destroy();
    });
  };
}
