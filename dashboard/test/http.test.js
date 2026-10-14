import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { createHandler, createServer, CSP, MAX_BODY_BYTES } from '../lib/http.js';
import { waitFor } from './helpers.js';

const TOKEN = '0123456789abcdef0123456789abcdef';
const FILES = {
  'index.html': Buffer.from('<!doctype html><title>t</title>\n'),
  'app.js': Buffer.from('export const x = 1;\n'),
  'style.css': Buffer.from('body { margin: 0; }\n'),
};

let server;
let port;
let host;
const seen = { state: 0, actions: [], terminals: [] };
let actionImpl;
let terminalImpl;
let stateValue;

before(async () => {
  let handler = null;
  server = createServer((req, res) => handler(req, res));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  port = server.address().port;
  host = `127.0.0.1:${port}`;
  handler = createHandler({
    token: TOKEN,
    port,
    files: FILES,
    getState: () => {
      seen.state += 1;
      if (stateValue instanceof Error) throw stateValue;
      return stateValue;
    },
    runAction: (words) => {
      seen.actions.push(words);
      return actionImpl(words);
    },
    openTerminal: (body) => {
      seen.terminals.push(body);
      return terminalImpl(body);
    },
  });
});

after(() => new Promise((resolve) => {
  server.close(resolve);
  server.closeAllConnections();
}));

beforeEach(() => {
  seen.state = 0;
  seen.actions = [];
  seen.terminals = [];
  stateValue = { snapshot: null, connected: false, updated: null, error: null };
  actionImpl = async () => ({ code: 0, stdout: 'ok\n', stderr: '', needs_auth: false });
  terminalImpl = async () => ({ ok: true, argv: ['x'] });
});

// request(opts): one HTTP request with exactly the given headers; resolves {status, headers, body}.
function request({ method = 'GET', path = `/${TOKEN}/`, headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const all = { host, ...headers };
    for (const k of Object.keys(all)) if (all[k] === null) delete all[k];
    const req = http.request({ host: '127.0.0.1', port, method, path, headers: all, agent: false, setHost: false }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

const JSON_HEADERS = { 'content-type': 'application/json' };
const post = (route, value, headers = {}) => request({
  method: 'POST', path: `/${TOKEN}${route}`, headers: { ...JSON_HEADERS, ...headers }, body: typeof value === 'string' ? value : JSON.stringify(value),
});

function assertSecurityHeaders(r) {
  assert.equal(r.headers['cache-control'], 'no-store');
  assert.equal(r.headers['x-content-type-options'], 'nosniff');
  assert.equal(r.headers['referrer-policy'], 'no-referrer');
  assert.equal(r.headers['content-security-policy'], CSP);
  for (const h of Object.keys(r.headers)) assert.ok(!h.startsWith('access-control-'), h);
}

function assertEmpty(r, status) {
  assert.equal(r.status, status);
  assert.equal(r.body, '');
  assertSecurityHeaders(r);
}

test('the CSP is the spec 6.2 policy', () => {
  assert.equal(CSP, "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
});

test('a wrong or missing Host is 404 with an empty body for every method, before anything runs', async () => {
  for (const h of ['evil.example', `evil.example:${port}`, `127.0.0.1:${port + 1}`, `[::1]:${port}`, '127.0.0.1', null]) {
    assertEmpty(await request({ headers: { host: h } }), 404);
    assertEmpty(await request({ path: `/${TOKEN}/api/state`, headers: { host: h } }), 404);
    assertEmpty(await post('/api/action', { words: ['log'] }, { host: h }), 404);
    assertEmpty(await post('/api/terminal', { verb: 'auth' }, { host: h }), 404);
  }
  assert.deepEqual(seen, { state: 0, actions: [], terminals: [] });
});

test('localhost:<port> and 127.0.0.1:<port> are both accepted', async () => {
  assert.equal((await request({ headers: { host: `localhost:${port}` } })).status, 200);
  assert.equal((await request({ headers: { host: `LOCALHOST:${port}` } })).status, 200);
  assert.equal((await request()).status, 200);
});

test('a wrong or missing token, or an unlisted route or method, is 404 with an empty body', async () => {
  const other = 'f'.repeat(32);
  for (const path of ['/', '/app.js', '/api/state', `/${other}/`, `/${other}/api/state`, `/${TOKEN}`, `/${TOKEN.toUpperCase()}/`,
    `/${TOKEN}/index.html`, `/${TOKEN}/api/`, `/${TOKEN}/../${TOKEN}/`, `/${TOKEN}//app.js`, `/${TOKEN}/app.js/`, `/x/${TOKEN}/`]) {
    assertEmpty(await request({ path }), 404);
  }
  for (const [method, path] of [['POST', '/'], ['POST', '/api/state'], ['GET', '/api/action'], ['GET', '/api/terminal'],
    ['PUT', '/api/action'], ['DELETE', '/'], ['HEAD', '/'], ['OPTIONS', '/api/action']]) {
    assertEmpty(await request({ method, path: `/${TOKEN}${path}`, headers: JSON_HEADERS }), 404);
  }
  assertEmpty(await post('/api/frob', { words: ['log'] }), 404);
  assert.deepEqual(seen, { state: 0, actions: [], terminals: [] });
});

test('the page, the script and the stylesheet are served with their types and the security headers', async () => {
  for (const [path, name, type] of [['/', 'index.html', 'text/html; charset=utf-8'], ['/app.js', 'app.js', 'text/javascript; charset=utf-8'],
    ['/style.css', 'style.css', 'text/css; charset=utf-8']]) {
    const r = await request({ path: `/${TOKEN}${path}?v=1` });
    assert.equal(r.status, 200);
    assert.equal(r.headers['content-type'], type);
    assert.equal(r.body, FILES[name].toString());
    assertSecurityHeaders(r);
  }
});

test('/api/state returns what getState gives, as JSON, before and after a snapshot', async () => {
  let r = await request({ path: `/${TOKEN}/api/state` });
  assert.equal(r.status, 200);
  assert.equal(r.headers['content-type'], 'application/json; charset=utf-8');
  assert.deepEqual(JSON.parse(r.body), { snapshot: null, connected: false, updated: null, error: null });
  stateValue = { snapshot: { version: 'dev', sessions: [] }, connected: true, updated: 1790000000000, error: null };
  r = await request({ path: `/${TOKEN}/api/state` });
  assert.deepEqual(JSON.parse(r.body), stateValue);
  assertSecurityHeaders(r);
  assert.equal(seen.state, 2);
});

test('a POST that is not JSON from this origin is 403 with an empty body, and nothing runs', async () => {
  const words = { words: ['log'] };
  for (const headers of [
    { 'content-type': 'text/plain' },
    { 'content-type': null },
    { 'content-type': 'application/x-www-form-urlencoded' },
    { 'content-type': 'multipart/form-data; boundary=x' },
    { origin: 'http://evil.example' },
    { origin: 'null' },
    { origin: `http://127.0.0.1:${port + 1}` },
    { origin: `https://127.0.0.1:${port}` },
    { 'sec-fetch-site': 'cross-site' },
    { 'sec-fetch-site': 'same-site' },
  ]) {
    assertEmpty(await post('/api/action', words, headers), 403);
    assertEmpty(await post('/api/terminal', { verb: 'auth' }, headers), 403);
  }
  assertEmpty(await post('/api/action', '{"words": ["log"]'), 403);
  assertEmpty(await post('/api/action', ''), 403);
  const exact = '{"words":["log"]}';
  assertEmpty(await post('/api/action', exact + ' '.repeat(MAX_BODY_BYTES - exact.length + 1)), 403);
  assert.deepEqual(seen, { state: 0, actions: [], terminals: [] });
});

test('the allowed origins, fetch metadata and a body of exactly 140000 bytes pass', async () => {
  for (const headers of [{ origin: `http://127.0.0.1:${port}` }, { origin: `http://localhost:${port}` },
    { 'sec-fetch-site': 'same-origin' }, { 'sec-fetch-site': 'none' }, { 'content-type': 'application/json; charset=utf-8' }]) {
    assert.equal((await post('/api/action', { words: ['log'] }, headers)).status, 200, JSON.stringify(headers));
  }
  const exact = '{"words":["log"]}';
  assert.equal((await post('/api/action', exact + ' '.repeat(MAX_BODY_BYTES - exact.length))).status, 200);
});

test('an action runs the words and returns code, stdout, stderr and needs_auth', async () => {
  actionImpl = async () => ({ code: 4, stdout: '', stderr: "tmuxkeep: TOTP required: run with a terminal or run 'tmuxkeep auth' first\n", needs_auth: true });
  const r = await post('/api/action', { words: ['send', 'api', 'run the tests'] });
  assert.equal(r.status, 200);
  assert.deepEqual(JSON.parse(r.body), { code: 4, stdout: '', stderr: "tmuxkeep: TOTP required: run with a terminal or run 'tmuxkeep auth' first\n", needs_auth: true });
  assert.deepEqual(seen.actions, [['send', 'api', 'run the tests']]);
});

test('go, ui, a bare auth, unknown verbs and bad words are 400 with the reason, and nothing runs', async () => {
  for (const [body, error] of [
    [{ words: ['go', 'api'] }, 'not allowed from the dashboard: go'],
    [{ words: ['ui'] }, 'not allowed from the dashboard: ui'],
    [{ words: ['auth'] }, 'only auth --end is allowed from the dashboard'],
    [{ words: ['frob'] }, 'not allowed from the dashboard: frob'],
    [{ words: 'log' }, 'words must be a non-empty array of strings'],
    [{}, 'words must be a non-empty array of strings'],
    [['log'], 'words must be a non-empty array of strings'],
    [null, 'words must be a non-empty array of strings'],
    [{ words: ['send', 'api', 'two\nlines'] }, 'text contains control characters (line breaks and tabs cannot be sent; send one line at a time)'],
  ]) {
    const r = await post('/api/action', body);
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.deepEqual(JSON.parse(r.body), { error });
  }
  assert.equal((await post('/api/action', { words: ['auth', '--end'] })).status, 200);
  assert.deepEqual(seen.actions, [['auth', '--end']]);
});

test('a second action while one runs is 409; the next one after it ends runs', async () => {
  let release = () => {};
  actionImpl = () => new Promise((resolve) => {
    release = () => resolve({ code: 0, stdout: '', stderr: '', needs_auth: false });
  });
  const first = post('/api/action', { words: ['log'] });
  first.catch(() => {}); // a failure below must not leave an unhandled rejection behind
  try {
    await waitFor(() => seen.actions.length > 0);
    const second = await post('/api/action', { words: ['status'] });
    assert.equal(second.status, 409);
    assert.deepEqual(JSON.parse(second.body), { error: 'another action is still running' });
  } finally {
    release(); // never leave the first request hanging, even when an assertion above failed
  }
  assert.equal((await first).status, 200);
  actionImpl = async () => ({ code: 0, stdout: '', stderr: '', needs_auth: false });
  assert.equal((await post('/api/action', { words: ['status'] })).status, 200);
  assert.deepEqual(seen.actions, [['log'], ['status']]);
});

test('a terminal request opens go or auth; a failure is 500 with the error; a bad body is 400', async () => {
  terminalImpl = async (b) => ({ ok: true, argv: ['kitty', '-e', b.verb] });
  let r = await post('/api/terminal', { verb: 'go', name: 'api' });
  assert.equal(r.status, 200);
  assert.deepEqual(JSON.parse(r.body), { ok: true, argv: ['kitty', '-e', 'go'] });
  terminalImpl = async () => ({ ok: false, error: 'no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config' });
  r = await post('/api/terminal', { verb: 'auth' });
  assert.equal(r.status, 500);
  assert.deepEqual(JSON.parse(r.body), { ok: false, error: 'no terminal program found; set TERMINAL_CMD in ~/.tmuxkeep/config' });
  r = await post('/api/terminal', { verb: 'go', name: 'Bad Name' });
  assert.equal(r.status, 400);
  assert.deepEqual(JSON.parse(r.body), { error: 'invalid session name' });
  assert.deepEqual(seen.terminals, [{ verb: 'go', name: 'api' }, { verb: 'auth' }]);
});

// raw(text): writes text on a plain socket (no HTTP client in between); resolves {data, closed} once the
// server closes the connection, or after 2 seconds with closed false.
function raw(text) {
  return new Promise((resolve) => {
    const sock = net.connect(port, '127.0.0.1');
    let data = '';
    let closed = false;
    const timer = setTimeout(() => {
      sock.destroy();
      resolve({ data, closed });
    }, 2000);
    sock.setEncoding('utf8');
    sock.on('connect', () => sock.write(text));
    sock.on('data', (chunk) => { data += chunk; });
    sock.on('error', () => {}); // a reset after the answer was sent is judged by what arrived
    sock.on('close', () => {
      closed = true;
      clearTimeout(timer);
      resolve({ data, closed });
    });
  });
}

// parseRaw(result): {status, headers, body, closed} of the last response in a raw reply.
function parseRaw({ data, closed }) {
  const start = data.lastIndexOf('HTTP/1.1 ');
  if (start < 0) return { status: 0, headers: {}, body: data, closed };
  const [headText, ...rest] = data.slice(start).split('\r\n\r\n');
  const lines = headText.split('\r\n');
  const headers = {};
  for (const line of lines.slice(1)) headers[line.slice(0, line.indexOf(':')).toLowerCase()] = line.slice(line.indexOf(':') + 1).trim();
  return { status: Number(lines[0].split(' ')[1]), headers, body: rest.join('\r\n\r\n'), closed };
}

test('the body limit is 140000 bytes, and a send text of 65536 quote or backslash characters fits under it', async () => {
  assert.equal(MAX_BODY_BYTES, 140000);
  for (const ch of ['"', '\\']) {
    const text = ch.repeat(65536);
    const size = Buffer.byteLength(JSON.stringify({ words: ['send', 'api', text] }));
    assert.ok(size > 131072 && size < MAX_BODY_BYTES, String(size));
    assert.equal((await post('/api/action', { words: ['send', 'api', text] })).status, 200);
  }
  assert.equal(seen.actions.length, 2);
});

test('a body declared larger than the limit is refused before it is read, and the connection is closed', async () => {
  const r = parseRaw(await raw(`POST /${TOKEN}/api/action HTTP/1.1\r\nHost: ${host}\r\nContent-Type: application/json\r\nContent-Length: 1000000\r\n\r\n`));
  assert.equal(r.status, 403);
  assert.equal(r.body, '');
  assert.equal(r.headers.connection, 'close');
  assert.equal(r.closed, true);
  assertSecurityHeaders(r);
  assert.deepEqual(seen, { state: 0, actions: [], terminals: [] });
});

test('a chunked body that outgrows the limit is refused as soon as it does, and the connection is closed', async () => {
  const chunk = 'x'.repeat(MAX_BODY_BYTES + 1);
  // The terminating 0-length chunk is never sent: reading the body to its end would never finish.
  const r = parseRaw(await raw(`POST /${TOKEN}/api/action HTTP/1.1\r\nHost: ${host}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n${chunk.length.toString(16)}\r\n${chunk}\r\n`));
  assert.equal(r.status, 403);
  assert.equal(r.body, '');
  assert.equal(r.headers.connection, 'close');
  assert.equal(r.closed, true);
  assertSecurityHeaders(r);
  assert.deepEqual(seen, { state: 0, actions: [], terminals: [] });
});

test('a request Node cannot parse, or one with too large a header block, gets the security headers and the connection is closed', async () => {
  for (const [text, status] of [
    ['GARBAGE\r\n\r\n', 400],
    [`GET /${TOKEN}/ HTTP/1.1\r\nHost: ${host}\r\nX-Big: ${'a'.repeat(20000)}\r\n\r\n`, 431],
  ]) {
    const r = parseRaw(await raw(text));
    assert.equal(r.status, status);
    assert.equal(r.body, '');
    assert.equal(r.closed, true);
    assertSecurityHeaders(r);
  }
});

test('an Expect request goes through the Host and token checks first', async () => {
  const expectPost = (expect, hostLine, token = TOKEN) => `POST /${token}/api/action HTTP/1.1\r\nHost: ${hostLine}\r\nContent-Type: application/json\r\nContent-Length: 17\r\nExpect: ${expect}\r\nConnection: close\r\n\r\n{"words":["log"]}`;
  for (const text of [
    expectPost('100-continue', 'evil.example'),
    expectPost('frob', 'evil.example'),
    expectPost('100-continue', host, 'f'.repeat(32)),
    expectPost('frob', host, 'f'.repeat(32)),
  ]) {
    const r = await raw(text);
    assert.ok(!r.data.includes('100 Continue'), r.data);
    const parsed = parseRaw(r);
    assert.equal(parsed.status, 404);
    assert.equal(parsed.body, '');
    assertSecurityHeaders(parsed);
  }
  assert.deepEqual(seen, { state: 0, actions: [], terminals: [] });
  // For the right Host and token an Expect: 100-continue is answered with 100 and then the action runs;
  // any other Expect value is no longer a 417.
  const ok = await raw(expectPost('100-continue', host));
  assert.match(ok.data, /^HTTP\/1\.1 100 Continue\r\n\r\nHTTP\/1\.1 200 OK\r\n/);
  assert.deepEqual(seen.actions, [['log']]);
  const page = parseRaw(await raw(`GET /${TOKEN}/ HTTP/1.1\r\nHost: ${host}\r\nExpect: frob\r\nConnection: close\r\n\r\n`));
  assert.equal(page.status, 200);
  assertSecurityHeaders(page);
});

test('a Host that only starts with a good one, or hides it in front of or inside another name, is 404', async () => {
  for (const h of [`${host}.evil.com`, `${host}@evil.com`, `user@${host}`, `127.0.0.1.evil.com:${port}`, `evil.com/127.0.0.1:${port}`, `${host} evil.com`]) {
    assertEmpty(await request({ headers: { host: h } }), 404);
    assertEmpty(await post('/api/action', { words: ['log'] }, { host: h }), 404);
  }
  assert.deepEqual(seen, { state: 0, actions: [], terminals: [] });
});

test('an encoded slash anywhere in the path is no slash: 404', async () => {
  for (const path of [`/${TOKEN}%2F`, `/${TOKEN}%2Fapi%2Fstate`, `/${TOKEN}/api%2Fstate`, `/${TOKEN}/api%2fstate`, `/%2F${TOKEN}/`, `/${TOKEN}/%2e%2e/`, `/${TOKEN.slice(0, 31)}%30/`]) {
    assertEmpty(await request({ path }), 404);
  }
  assertEmpty(await post('/api%2Faction', { words: ['log'] }), 404);
  assert.deepEqual(seen, { state: 0, actions: [], terminals: [] });
});

test('/api/terminal takes exactly the keys of its verb and a JSON object: 400, nothing opens', async () => {
  for (const [body, error] of [
    [{ verb: 'auth', extra: 1 }, 'auth takes no name'],
    [{ verb: 'auth', name: 'api' }, 'auth takes no name'],
    [{ verb: 'go', name: 'api', extra: 1 }, 'go needs a session name'],
    [{ verb: 'go' }, 'go needs a session name'],
    [{ verb: 'attach', name: 'api' }, 'verb must be go or auth'],
    ['[]', 'body must be an object'],
    ['"auth"', 'body must be an object'],
    ['5', 'body must be an object'],
    ['true', 'body must be an object'],
    ['null', 'body must be an object'],
  ]) {
    const r = await post('/api/terminal', body);
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.deepEqual(JSON.parse(r.body), { error });
    assertSecurityHeaders(r);
  }
  assert.deepEqual(seen.terminals, []);
});

test('status --follow is not an action: 400, and nothing runs', async () => {
  const r = await post('/api/action', { words: ['status', '--follow'] });
  assert.equal(r.status, 400);
  assert.deepEqual(JSON.parse(r.body), { error: 'status --follow is not an action' });
  assert.deepEqual(seen.actions, []);
});

test('an internal error is one stderr line with the message only and a 500 with the security headers; the action lock is released', async (t) => {
  const written = [];
  t.mock.method(process.stderr, 'write', (chunk) => {
    written.push(String(chunk));
    return true;
  });
  stateValue = new Error('state boom\nsecond line');
  assertEmpty(await request({ path: `/${TOKEN}/api/state` }), 500);
  terminalImpl = async () => {
    throw new Error('terminal boom');
  };
  assertEmpty(await post('/api/terminal', { verb: 'auth' }), 500);
  actionImpl = async () => {
    throw new Error('action boom');
  };
  assertEmpty(await post('/api/action', { words: ['log'] }), 500);
  actionImpl = async () => ({ code: 0, stdout: 'again\n', stderr: '', needs_auth: false });
  const again = await post('/api/action', { words: ['status'] });
  assert.equal(again.status, 200, 'a failed action must not keep the lock');
  assert.deepEqual(written.filter((l) => l.includes('internal error')), [
    'tmuxkeep ui: internal error: state boom second line\n',
    'tmuxkeep ui: internal error: terminal boom\n',
    'tmuxkeep ui: internal error: action boom\n',
  ]);
  assert.ok(!written.some((l) => l.includes(TOKEN)));
});
