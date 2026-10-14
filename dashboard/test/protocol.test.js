import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { encodeWord, sshArgs, SSH_PREFIX } from '../lib/protocol.js';

// tests/fixtures/b64-words is shared with tests/bats/laptop-wrapper.bats and tests/pester/tmuxkeep.Tests.ps1.
const FIXTURE = new URL('../../tests/fixtures/b64-words', import.meta.url);

function fixtureCases() {
  return fs.readFileSync(FIXTURE, 'utf8').split('\n')
    .filter((line) => line !== '' && !line.startsWith('#'))
    .map((line) => {
      const [label, hex, token] = line.split(' ');
      return { label, word: Buffer.from(hex, 'hex').toString('utf8'), token };
    });
}

test('the shared fixture holds the fifteen agreed cases', () => {
  const labels = fixtureCases().map((c) => c.label);
  assert.deepEqual(labels, ['verb', 'name', 'spaces', 'shell-specials', 'quotes', 'double-dash', 'short-option',
    'tombstone', 'slash', 'tab', 'latin1', 'cjk', 'emoji', 'url', 'long-120']);
});

test('every fixture word encodes to its token, bit for bit', () => {
  for (const c of fixtureCases()) assert.equal(encodeWord(c.word), c.token, c.label);
});

test('sshArgs is the fixed prefix, then one token per word, and never -t', () => {
  assert.deepEqual(SSH_PREFIX, ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'tmuxkeep', 'b64']);
  assert.deepEqual(sshArgs(['send', 'api', 'run the tests']),
    ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'tmuxkeep', 'b64', 'c2VuZA==', 'YXBp', 'cnVuIHRoZSB0ZXN0cw==']);
  for (const words of [['go', 'api'], ['auth', '--end'], ['new', 'api'], ['status']]) {
    assert.ok(!sshArgs(words).includes('-t'), words.join(' '));
  }
});

test('a lone surrogate never reaches the encoder as a surprise: it encodes as U+FFFD, which validate.js refuses earlier', () => {
  assert.equal(encodeWord(String.fromCharCode(0xd800)),Buffer.from([0xef, 0xbf, 0xbd]).toString('base64'));
});
