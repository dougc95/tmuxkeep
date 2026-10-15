import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ACTION_VERBS, checkAction, checkTerminal, SEND_MAX_BYTES } from '../lib/validate.js';

const ok = (words) => assert.equal(checkAction(words), null, JSON.stringify(words));
const bad = (words, message) => assert.equal(checkAction(words), message, JSON.stringify(words));

test('the allowlist is the twelve verbs of spec 6.4, without go, ui or reap', () => {
  assert.deepEqual(ACTION_VERBS, ['new', 'send', 'rename', 'lock', 'unlock', 'rm', 'restore', 'resume', 'log', 'peek', 'status', 'auth']);
  bad(['go', 'api'], 'not allowed from the dashboard: go');
  bad(['ui'], 'not allowed from the dashboard: ui');
  bad(['reap'], 'not allowed from the dashboard: reap');
  bad(['LS'], 'not allowed from the dashboard: LS');
  bad(['ls'], 'not allowed from the dashboard: ls');
  bad(['fro' + String.fromCharCode(7) + 'b'], 'not allowed from the dashboard: fro?b');
});

test('words must be a non-empty array of non-empty, well-formed strings', () => {
  bad(undefined, 'words must be a non-empty array of strings');
  bad('send api hi', 'words must be a non-empty array of strings');
  bad([], 'words must be a non-empty array of strings');
  bad(['send', 'api', 5], 'words must be a non-empty array of strings');
  bad(['send', 'api', null], 'words must be a non-empty array of strings');
  bad(['send', 'api', ''], 'empty argument');
  bad(['send', 'api', 'a' + String.fromCharCode(0xd800) + 'b'], 'argument is not valid text');
});

test('auth is allowed only as exactly auth --end', () => {
  ok(['auth', '--end']);
  bad(['auth'], 'only auth --end is allowed from the dashboard');
  bad(['auth', '--end', '--end'], 'only auth --end is allowed from the dashboard');
  bad(['auth', '--frob'], 'only auth --end is allowed from the dashboard');
});

test('names follow the broker rule; tombstone names only for peek and rm --now', () => {
  ok(['lock', 'api']);
  ok(['lock', 'a-b_9']);
  ok(['lock', 'a'.repeat(32)]);
  bad(['lock', 'a'.repeat(33)], 'invalid session name');
  bad(['lock', '1api'], 'invalid session name');
  bad(['lock', 'Api'], 'invalid session name');
  bad(['lock', '-api'], 'invalid session name');
  bad(['lock'], 'missing session name');
  bad(['lock', 'zz~api~1790000000'], 'invalid session name');
  ok(['peek', 'zz~api~1790000000']);
  ok(['rm', 'zz~api~1790000000', '--now', '--confirm', 'zz~api~1790000000']);
  bad(['rm', 'zz~api~1790000000'], 'invalid session name');
  bad(['restore', 'zz~api~1790000000'], 'invalid session name');
  bad(['peek', 'zz~Api~1'], 'invalid session name');
});

test('new: options in any order, each once; https only; --cmd printable ASCII up to 200; never with --shell', () => {
  ok(['new', 'api']);
  ok(['new', '--repo', 'https://github.com/you/api.git', 'api', '--cmd', 'claude --continue']);
  ok(['new', 'api', '--shell']);
  ok(['new', 'api', '--cmd', 'x'.repeat(200)]);
  bad(['new', 'api', '--cmd', 'x'.repeat(201)], '--cmd must be at most 200 printable ASCII characters');
  bad(['new', 'api', '--cmd', 'caf' + String.fromCodePoint(0xe9)], '--cmd must be at most 200 printable ASCII characters');
  bad(['new', 'api', '--repo', 'http://github.com/you/api.git'], '--repo must be an https:// URL');
  bad(['new', 'api', '--repo', 'https://'], '--repo must be an https:// URL');
  bad(['new', 'api', '--repo', 'https://a b'], '--repo must be an https:// URL');
  bad(['new', 'api', '--shell', '--cmd', 'x'], '--shell and --cmd cannot be combined');
  bad(['new', 'api', 'web'], 'usage: tmuxkeep new <name> [--repo <https-url>] [--cmd <text>] [--shell]');
  bad(['new', 'api', '--repo'], 'usage: tmuxkeep new <name> [--repo <https-url>] [--cmd <text>] [--shell]');
  bad(['new', 'api', '--shell', '--shell'], 'usage: tmuxkeep new <name> [--repo <https-url>] [--cmd <text>] [--shell]');
  bad(['new'], 'missing session name');
});

test('send: text joined by spaces, no control characters (tab included, as in the broker), at most 65536 bytes', () => {
  ok(['send', 'api', 'run the tests']);
  ok(['send', 'api', 'a', 'b']);
  ok(['send', 'api', String.fromCodePoint(0xe9).repeat(SEND_MAX_BYTES / 2)]);
  bad(['send', 'api', 'x'.repeat(SEND_MAX_BYTES - 1) + String.fromCodePoint(0xe9)], 'text longer than 65536 bytes');
  bad(['send', 'api'], 'nothing to send');
  bad(['send', 'api', 'a\tb'], 'text contains control characters (line breaks and tabs cannot be sent; send one line at a time)');
  bad(['send', 'api', 'del' + String.fromCharCode(0x7f)],'text contains control characters (line breaks and tabs cannot be sent; send one line at a time)');
});

// Review Focus 1: a multi-line prompt pasted into the Send box is refused before any ssh call.
test('send: pasted multi-line text is refused with a message that says why', () => {
  for (const text of ['line one\nline two', 'windows\r\nline', 'trailing newline\n']) {
    bad(['send', 'api', text], 'text contains control characters (line breaks and tabs cannot be sent; send one line at a time)');
  }
});

test('rename, unlock and restore take exact arguments', () => {
  ok(['rename', 'api', 'web']);
  bad(['rename', 'api'], 'usage: tmuxkeep rename <old> <new>');
  bad(['rename', 'api', 'Web'], 'invalid session name');
  ok(['unlock', 'api']);
  bad(['unlock'], 'usage: tmuxkeep unlock <name>');
  bad(['unlock', 'api', 'web'], 'usage: tmuxkeep unlock <name>');
  ok(['restore', 'api']);
  bad(['restore', 'api', 'x'], 'usage: tmuxkeep restore <name>');
  bad(['lock', 'api', 'web'], 'usage: tmuxkeep lock <name>');
});

test('rm: soft by default; --now needs --confirm equal to the name', () => {
  ok(['rm', 'api']);
  ok(['rm', 'api', '--now', '--confirm', 'api']);
  ok(['rm', '--now', 'api', '--confirm', 'api']);
  bad(['rm', 'api', '--now', '--confirm', 'web'], '--confirm must equal api');
  bad(['rm', 'api', '--now'], '--confirm must equal api');
  bad(['rm', 'api', '--confirm', 'api'], '--confirm needs --now');
  bad(['rm', 'api', '--frob'], 'usage: tmuxkeep rm <name> [--now --confirm <name>]');
  bad(['rm', 'api', 'web'], 'usage: tmuxkeep rm <name> [--now --confirm <name>]');
  bad(['rm'], 'usage: tmuxkeep rm <name> [--now --confirm <name>]');
});

test('resume: one name, --cmd or --shell', () => {
  ok(['resume', 'api']);
  ok(['resume', 'api', '--shell']);
  ok(['resume', '--cmd', 'claude', 'api']);
  bad(['resume', 'api', '--shell', '--cmd', 'x'], '--shell and --cmd cannot be combined');
  bad(['resume'], 'usage: tmuxkeep resume <name> [--cmd <text>] [--shell]');
  bad(['resume', 'api', '--frob'], 'usage: tmuxkeep resume <name> [--cmd <text>] [--shell]');
});

test('log -n, peek -n and status --lines have the broker bounds', () => {
  ok(['log']);
  ok(['log', '-n', '0']);
  ok(['log', '-n', '9999']);
  bad(['log', '-n', '10000'], '-n must be 0-9999');
  bad(['log', '-n', 'x'], '-n must be 0-9999');
  bad(['log', '100'], 'usage: tmuxkeep log [-n N]');
  ok(['peek', 'api']);
  ok(['peek', 'api', '-n', '200']);
  bad(['peek', 'api', '-n', '-1'], '-n must be 0-9999');
  bad(['peek', 'api', '200'], 'usage: tmuxkeep peek <name> [-n N]');
  bad(['peek'], 'missing session name');
  ok(['status']);
  ok(['status', '--lines', '0']);
  ok(['status', '--lines', '40']);
  bad(['status', '--lines', '41'], '--lines must be 0-40');
  bad(['status', '--lines'], 'usage: tmuxkeep status [--lines N]');
  bad(['status', '--follow'], 'status --follow is not an action');
  bad(['status', '--lines', '12', '--follow'], 'status --follow is not an action');
});

test('terminal requests: go with a valid name, or auth alone', () => {
  assert.equal(checkTerminal({ verb: 'go', name: 'api' }), null);
  assert.equal(checkTerminal({ verb: 'auth' }), null);
  assert.equal(checkTerminal({ verb: 'auth', name: 'api' }), 'auth takes no name');
  assert.equal(checkTerminal({ verb: 'go' }), 'go needs a session name');
  assert.equal(checkTerminal({ verb: 'go', name: 5 }), 'go needs a session name');
  assert.equal(checkTerminal({ verb: 'go', name: 'api', extra: 1 }), 'go needs a session name');
  assert.equal(checkTerminal({ verb: 'go', name: 'zz~api~1' }), 'invalid session name');
  assert.equal(checkTerminal({ verb: 'go', name: 'api; rm -rf ~' }), 'invalid session name');
  assert.equal(checkTerminal({ verb: 'ui' }), 'verb must be go or auth');
  assert.equal(checkTerminal(['go', 'api']), 'body must be an object');
  assert.equal(checkTerminal(null), 'body must be an object');
});
