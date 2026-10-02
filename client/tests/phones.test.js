// Phone-frame contract on the client side: the generated table matches the
// shared vectors (frame placement ported verbatim from tools/genphones.js),
// the layout decision follows the stream aspect, and the phone identification
// / aspect notice behave (docs/PHONE_FRAME.md §7).

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { PHONES, CONTRACT_VECTORS, RING_PX, DEFAULT_PHONE_ID } from '../js/phones.js';
import { identifyPhones, aspectMismatch, aspectNotice } from '../js/phonematch.js';

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

test('identifyPhones picks same-panel models, most popular first', () => {
  const hits = identifyPhones(402, 874, 3); // 1206x2622
  assert.equal(hits[0].id, 'iphone-17');
  assert.ok(hits.some((p) => p.id === 'iphone-17-pro'));
  assert.deepEqual(identifyPhones(874, 402, 3).map((p) => p.id), hits.map((p) => p.id), 'landscape screen');
  assert.deepEqual(identifyPhones(1000, 1000, 1), []);
});

test('aspect notice only on a real mismatch', () => {
  const p17 = PHONES.find((x) => x.id === 'iphone-17');
  // Streaming for the iPhone 17 itself (the 4K vector's encode).
  const own = CONTRACT_VECTORS.find((v) => v.phone === 'iphone-17' && v.clientW === 3840);
  assert.equal(aspectNotice(own.encW, own.encH, 402, 874, 3), '');
  assert.ok(aspectMismatch(own.encW, own.encH, p17) < 0.02);
  // Streaming for a Galaxy A07 on an iPhone 17.
  const a07 = CONTRACT_VECTORS.find((v) => v.phone === 'galaxy-a07' && v.clientW === 1280);
  const text = aspectNotice(a07.encW, a07.encH, 402, 874, 3);
  // (Several phones share nearly that aspect; the notice names the closest.)
  assert.match(text, /^Streaming for .+; this phone looks like Apple iPhone 17/);
  // Unknown device: nothing to compare against.
  assert.equal(aspectNotice(a07.encW, a07.encH, 999, 1999, 1.5), '');
});
