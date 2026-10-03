// Phone-frame contract on the client side: the generated table matches the
// shared vectors (frame placement ported verbatim from tools/genphones.js),
// the layout decision follows the stream aspect, and the phone identification
// / aspect notice behave (docs/PHONE_FRAME.md §7).

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { PHONES, CONTRACT_VECTORS, RING_PX, DEFAULT_PHONE_ID } from '../js/phones.js';

function rhe(num, den) {
  const q = Math.floor(num / den);
  const r = num - q * den;
  if (2 * r > den) return q + 1;
  if (2 * r < den) return q;
  return q + (q % 2);
}

test('generated vectors equal phones/contract_vectors.json', () => {
  const json = JSON.parse(fs.readFileSync(new URL('../../phones/contract_vectors.json', import.meta.url)));
  assert.equal(json.ringPx, RING_PX);
  assert.deepEqual(CONTRACT_VECTORS.map((v) => ({ ...v })), json.vectors);
});

test('frame placement port reproduces every vector', () => {
  const byId = new Map(PHONES.map((p) => [p.id, p]));
  for (const v of CONTRACT_VECTORS) {
    const p = byId.get(v.phone);
    const availW = v.clientW - 2 * RING_PX;
    const availH = v.clientH - 2 * RING_PX;
    let h = availH;
    let w = rhe(availH * p.streamW, p.streamH);
    if (w > availW) {
      w = availW;
      h = rhe(availW * p.streamH, p.streamW);
    }
    assert.deepEqual([rhe(v.clientW - w, 2), rhe(v.clientH - h, 2), w, h], [v.x, v.y, v.w, v.h], v.phone);
  }
});

test('table: 20 most-used first, default present', () => {
  assert.ok(PHONES.some((p) => p.id === DEFAULT_PHONE_ID));
  for (let i = 0; i < 20; i++) assert.equal(PHONES[i].popularity, i + 1);
  assert.ok(PHONES.slice(20).every((p) => p.popularity === 0));
});

test('stream fills the phone it was made for, edge to edge (v0.6.2)', () => {
  // The client's video box runs from below the top inset to the bottom edge
  // (styles.css). Each phone's own stream at full width must be exactly that
  // tall: no bar under the camera cutout, no bar at the bottom.
  for (const [id, cssW, cssH, insetTop] of [
    ['iphone-17', 402, 874, 62],
    ['iphone-16', 393, 852, 59],
  ]) {
    const p = PHONES.find((x) => x.id === id);
    const videoH = cssW * (p.streamH / p.streamW);
    assert.ok(Math.abs(videoH - (cssH - insetTop)) < 1, `${id}: ${videoH}`);
  }
});

