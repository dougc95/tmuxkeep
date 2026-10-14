// protocol.js - words to ssh arguments, exactly as laptop/tmuxkeep.ps1 and laptop/tmuxkeep.sh build
// them (spec 6.4): the literal word b64, then each word as standard, padded base64 of its UTF-8
// bytes, so nothing ever reaches a remote shell. The dashboard never asks ssh for a terminal (-t).

export const SSH_PREFIX = Object.freeze(['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', 'tmuxkeep', 'b64']);

// encodeWord(word): the token for one word.
export function encodeWord(word) {
  return Buffer.from(word, 'utf8').toString('base64');
}

// sshArgs(words): the whole ssh argument list for these words.
export function sshArgs(words) {
  return [...SSH_PREFIX, ...words.map(encodeWord)];
}
