import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { configPath, DEFAULT_PORT, parseArgs, readConfig, USAGE } from '../lib/config.js';
import { fileURLToPath } from 'node:url';

function tempFile(text) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tk-config-'));
  const file = path.join(dir, 'config');
  fs.writeFileSync(file, text, 'latin1');
  return file;
}

const reason = (text) => {
  const file = tempFile(text);
  try {
    readConfig(file);
    return 'no error';
  } catch (err) {
    return err.message.replace(`config ${file}: `, '');
  }
};

test('configPath is ~/.tmuxkeep/config', () => {
  assert.equal(configPath('/home/you'), path.join('/home/you', '.tmuxkeep', 'config'));
});

test('a missing file gives the defaults', () => {
  assert.deepEqual(readConfig(path.join(os.tmpdir(), 'tk-no-such-dir', 'config')), { port: 7707, terminalCmd: '' });
  assert.equal(DEFAULT_PORT, 7707);
});

test('the laptop-config fixture reads as the defaults', () => {
  const fixture = fileURLToPath(new URL('../../tests/fixtures/laptop-config', import.meta.url));
  assert.deepEqual(readConfig(fixture), { port: 7707, terminalCmd: '' });
});

test('missing keys default; present keys are read, trimmed, the last one winning; other lines are ignored', () => {
  const file = tempFile('HOST=203.0.113.10\nPORT=22\n');
  assert.deepEqual(readConfig(file), { port: 7707, terminalCmd: '' });
  const file2 = tempFile('# c\n\n  DASHBOARD_PORT = 8080 \nTERMINAL_CMD=\talacritty -e\t\njust words\nFROB=1\nDASHBOARD_PORT=8081\n');
  assert.deepEqual(readConfig(file2), { port: 8081, terminalCmd: 'alacritty -e' });
  assert.deepEqual(readConfig(tempFile('DASHBOARD_PORT=09000\r\nTERMINAL_CMD=\r\n')), { port: 9000, terminalCmd: '' });
});

test('bad values name the key, as the deploy scripts do', () => {
  assert.equal(reason('DASHBOARD_PORT=80\n'), 'DASHBOARD_PORT: must be an integer from 1024 to 65535');
  assert.equal(reason('DASHBOARD_PORT=65536\n'), 'DASHBOARD_PORT: must be an integer from 1024 to 65535');
  assert.equal(reason('DASHBOARD_PORT=abc\n'), 'DASHBOARD_PORT: must be an integer from 1024 to 65535');
  assert.equal(reason('DASHBOARD_PORT=\n'), 'DASHBOARD_PORT: must be an integer from 1024 to 65535');
  assert.equal(reason('DASHBOARD_PORT=00001024\n'), 'DASHBOARD_PORT: must be an integer from 1024 to 65535');
  assert.equal(reason('DASHBOARD_PORT=1024\nTERMINAL_CMD=' + 'x'.repeat(200) + '\n'), 'no error');
  assert.equal(reason('TERMINAL_CMD=' + 'x'.repeat(201) + '\n'), 'TERMINAL_CMD: at most 200 characters');
  // The file holds the two UTF-8 bytes of e-acute; read as latin1 they are two non-ASCII characters.
  // The wording is the deploy scripts' (laptop/deploy.ps1, laptop/deploy.sh), line number included.
  assert.equal(reason('TERMINAL_CMD=caf' + String.fromCharCode(0xc3, 0xa9) + '\n'), 'line 1: non-printable or non-ASCII character in TERMINAL_CMD');
  assert.equal(reason('TERMINAL_CMD=a\tb\n'), 'line 1: non-printable or non-ASCII character in TERMINAL_CMD');
  assert.equal(reason('# c\n\nTERMINAL_CMD=a\tb\n'), 'line 3: non-printable or non-ASCII character in TERMINAL_CMD');
  assert.equal(reason('DASHBOARD_PORT=80\t80\n'), 'line 1: non-printable or non-ASCII character in DASHBOARD_PORT');
  // Lines of other keys are not this reader's business, whatever they hold.
  assert.equal(reason('LAUNCH_CMD=a\tb\n'), 'no error');
});

test('a path that cannot be read as a file is an error, and the errno stays in the cause', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tk-config-'));
  assert.throws(() => readConfig(dir), { message: `config ${dir}: cannot read` });
  let expected;
  try {
    fs.readFileSync(dir, 'latin1');
  } catch (err) {
    expected = err.code;
  }
  assert.match(expected, /^E[A-Z]+$/);
  let thrown;
  try {
    readConfig(dir);
  } catch (err) {
    thrown = err;
  }
  assert.ok(thrown.cause instanceof Error);
  assert.equal(thrown.cause.code, expected);
});

test('parseArgs: --port N and --no-open, each at most once, nothing else', () => {
  assert.deepEqual(parseArgs([]), { port: null, open: true });
  assert.deepEqual(parseArgs(['--no-open']), { port: null, open: false });
  assert.deepEqual(parseArgs(['--port', '8080', '--no-open']), { port: 8080, open: false });
  assert.deepEqual(parseArgs(['--no-open', '--port', '65535']), { port: 65535, open: false });
  for (const argv of [['--frob'], ['--port'], ['--no-open', '--no-open'], ['--port', '8080', '--port', '8081'], ['8080']]) {
    assert.throws(() => parseArgs(argv), { message: USAGE }, argv.join(' '));
  }
  for (const v of ['80', '1023', '65536', 'abc', '']) {
    assert.throws(() => parseArgs(['--port', v]), { message: '--port must be an integer from 1024 to 65535' }, v);
  }
  assert.equal(USAGE, 'usage: tmuxkeep ui [--port N] [--no-open]');
});
