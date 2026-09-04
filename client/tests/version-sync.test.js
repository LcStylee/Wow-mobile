// Addon version-sync guard. Stock vanilla 1.12 has no GetAddOnMetadata (it
// arrived in 2.0), so WowMobile_Vanilla/Core.lua carries WM.VERSION as a
// hand-synced mirror of its TOC's "## Version:" — the runtime source of truth
// for /wm status and the login line on stock clients. Nothing in the game
// enforces the sync, so this test does: a TOC-only bump would otherwise ship
// an addon that REPORTS the old version, which is precisely the stale-code
// ambiguity the visible-version feature exists to remove. Both TOCs are also
// held equal so the two addon variants can never drift apart silently.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const read = (rel) =>
  readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');

function tocVersion(rel) {
  const m = read(rel).match(/^## Version:[ \t]*(\S+)[ \t]*$/m);
  assert.ok(m, `${rel}: no "## Version:" line`);
  return m[1];
}

test('vanilla WM.VERSION matches WowMobile_Vanilla.toc ## Version', () => {
  const toc = tocVersion('../../addon/WowMobile_Vanilla/WowMobile_Vanilla.toc');
  const core = read('../../addon/WowMobile_Vanilla/Core.lua');
  const m = core.match(/^WM\.VERSION[ \t]*=[ \t]*"([^"]*)"/m);
  assert.ok(m, 'WowMobile_Vanilla/Core.lua: no WM.VERSION = "..." constant');
  assert.equal(
    m[1],
    toc,
    'WowMobile_Vanilla/Core.lua WM.VERSION must equal the TOC ## Version — ' +
      'stock 1.12 clients report WM.VERSION (no GetAddOnMetadata there)',
  );
});

test('both addon TOCs carry the same ## Version', () => {
  assert.equal(
    tocVersion('../../addon/WowMobile/WowMobile.toc'),
    tocVersion('../../addon/WowMobile_Vanilla/WowMobile_Vanilla.toc'),
    'the two addon variants ship as one release and must version together',
  );
});
