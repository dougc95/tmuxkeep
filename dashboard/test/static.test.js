import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

test('every dashboard file is ASCII with LF line endings and no byte order mark', () => {
  const files = walk(ROOT);
  assert.ok(files.length >= 5, `found ${files.length} files`);
  for (const f of files) {
    const b = fs.readFileSync(f);
    const name = path.relative(ROOT, f);
    assert.ok(!(b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf), `${name} starts with a BOM`);
    assert.equal(b.indexOf(13), -1, `${name} has a CR`);
    assert.equal(b.findIndex((x) => x > 127), -1, `${name} has a non-ASCII byte`);
  }
});

test('package.json: an ES module package with no dependencies at all', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
  assert.equal(pkg.type, 'module');
  for (const k of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies', 'bundledDependencies']) {
    assert.equal(pkg[k], undefined, k);
  }
  assert.equal(pkg.engines.node, '>=20');
  assert.ok(!fs.existsSync(path.join(ROOT, 'node_modules')));
});

test('library and server code import only node: built-ins and relative files', () => {
  for (const f of walk(ROOT).filter((x) => x.endsWith('.js'))) {
    const text = fs.readFileSync(f, 'utf8');
    for (const m of text.matchAll(/(?:^|\n)\s*import\s[^'"]*['"]([^'"]+)['"]/g)) {
      assert.ok(m[1].startsWith('node:') || m[1].startsWith('./') || m[1].startsWith('../'), `${path.relative(ROOT, f)} imports ${m[1]}`);
    }
    assert.ok(!/\brequire\(/.test(text), `${path.relative(ROOT, f)} calls require`);
  }
});
