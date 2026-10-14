// http.js - the request handler of tmuxkeep ui (spec 6.2, D17). Every request is checked in this
// order: the Host header must be 127.0.0.1:<port> or localhost:<port> (the DNS rebinding guard), then
// the path must be /<token>/ followed by a listed route for that method; either failure is 404 with
// an empty body, before anything else happens. A POST must then carry JSON from this origin, or it is
// 403 with an empty body. No CORS header is ever sent. createServer() also routes Node's own replies
// (400/408/431 for a broken request, Expect handling) through the same security headers and checks.
import crypto from 'node:crypto';
import http from 'node:http';
import { checkAction, checkTerminal } from './validate.js';

// A valid send text is at most 65,536 bytes and JSON escaping can double it (every " and \), so the
// limit is 140,000 bytes with room for the rest of the object.
export const MAX_BODY_BYTES = 140000;
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

// refuseAndClose(req, res): 403 with an empty body for a body that is too large, then the connection
// is closed as soon as the answer is out; the rest of the body is never read.
function refuseAndClose(req, res) {
  res.setHeader('Connection', 'close');
  res.once('finish', () => req.socket.destroy());
  empty(res, 403);
}

const TOO_BIG = Symbol('too big');

// readJson(req): the parsed body; undefined when it is not JSON; TOO_BIG as soon as more than
// MAX_BODY_BYTES have arrived (reading stops there).
function readJson(req) {
  return new Promise((resolve) => {
    const chunks = [];
    let size = 0;
    const onData = (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        req.removeListener('data', onData);
        req.pause();
        resolve(TOO_BIG);
        return;
      }
      chunks.push(chunk);
    };
    req.on('data', onData);
    req.on('end', () => {
      try {
        return resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        return resolve(undefined);
      }
    });
    req.on('error', () => resolve(undefined));
  });
}

// onClientError(err, socket): Node's own answer to a request it cannot parse (400, 431, 408) with
// the security headers and an empty body, then the connection is closed.
export function onClientError(err, socket) {
  if (socket.destroyed || !socket.writable || socket.bytesWritten > 0) {
    socket.destroy();
    return;
  }
  let status = 400;
  if (err && err.code === 'HPE_HEADER_OVERFLOW') status = 431;
  else if (err && err.code === 'ERR_HTTP_REQUEST_TIMEOUT') status = 408;
  const lines = Object.entries(SECURITY_HEADERS).map(([name, value]) => `${name}: ${value}\r\n`).join('');
  socket.write(`HTTP/1.1 ${status} ${http.STATUS_CODES[status]}\r\n${lines}Content-Length: 0\r\nConnection: close\r\n\r\n`);
  socket.destroySoon();
}

// createServer(handler): the http.Server for a createHandler() handler. A request with an Expect
// header goes through the handler too (Host and token first), and a request Node cannot parse is
// answered by onClientError.
export function createServer(handler) {
  const server = http.createServer(SERVER_OPTIONS, handler);
  server.on('clientError', onClientError);
  server.on('checkContinue', handler);
  server.on('checkExpectation', handler);
  return server;
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
    // A body that is declared too large is refused before a byte of it is read.
    const declared = req.headers['content-length'];
    if (declared !== undefined && Number(declared) > MAX_BODY_BYTES) return refuseAndClose(req, res);
    // 100 Continue only to an HTTP/1.1 client that asked for it, matched the way Node dispatches checkContinue.
    if (req.httpVersion === '1.1' && /(?:^|\W)100-continue(?:$|\W)/i.test(req.headers.expect || '')) res.writeContinue();
    const body = await readJson(req);
    if (body === TOO_BIG) return refuseAndClose(req, res);
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
    handle(req, res).catch((err) => {
      // One line for the operator: the message only, never the request (its URL holds the token).
      process.stderr.write(`tmuxkeep ui: internal error: ${String(err && err.message).replace(/[\r\n]+/g, ' ')}\n`);
      if (!res.headersSent) empty(res, 500);
      else res.destroy();
    });
  };
}
