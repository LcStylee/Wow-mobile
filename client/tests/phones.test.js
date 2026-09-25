// Phone-frame contract on the client side: the generated table matches the
// shared vectors (frame placement ported verbatim from tools/genphones.js),
// the layout decision follows the stream aspect, and the phone identification
// / aspect notice behave (docs/PHONE_FRAME.md §7).

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { PHONES, CONTRACT_VECTORS, RING_PX, DEFAULT_PHONE_ID } from '../js/phones.js';
import { identifyPhones, aspectMismatch, aspectNotice } from '../js/phonematch.js';
import { layoutMode } from '../js/layout.js';

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

test('stream fits the phone it was made for with the deck below', () => {
  // iPhone 17: 402x874 CSS, insets 62/34 — its own stream leaves the deck.
  const p = PHONES.find((x) => x.id === 'iphone-17');
  assert.equal(layoutMode(402, 874, 62, 34, undefined, p.streamH / p.streamW), 'deck');
  // A much taller stream (Galaxy A07's aspect) on a short 16:9 screen: overlay.
  assert.equal(layoutMode(360, 640, 0, 0, undefined, 1400 / 720), 'overlay');
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
  // Streaming for the iPhone 17 itself (encode is the even frame of that aspect).
  assert.equal(aspectNotice(1074, 1920, 402, 874, 3), '');
  assert.ok(aspectMismatch(1074, 1920, p17) < 0.02);
  // Streaming for a Galaxy A07 (720x1400) on an iPhone 17.
  const text = aspectNotice(364, 708, 402, 874, 3);
  assert.match(text, /Galaxy A07/);
  assert.match(text, /iPhone 17/);
  // Unknown device: nothing to compare against.
  assert.equal(aspectNotice(364, 708, 999, 1999, 1.5), '');
});
