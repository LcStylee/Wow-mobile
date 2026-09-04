// Layout-mode decision tests for js/layout.js — the deck-vs-overlay split:
// deck layout needs enough dead zone below a top-anchored full-width 9:16
// video (above the home-indicator inset) to fit the deck's two chrome rows.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { MIN_DECK_PX, layoutMode, resolveMode } from '../js/layout.js';

test('modern notched iPhones get the deck layout', () => {
  // iPhone 15 Pro class: 393x852, Dynamic Island inset 59, home bar 34.
  // Video 393·16/9 ≈ 698.7 → dead zone ≈ 94.3, ≈ 60.3 above the home bar.
  assert.equal(layoutMode(393, 852, 59, 34), 'deck');
  // iPhone 14 class: 390x844, insets 47/34 → ≈ 69.7 usable.
  assert.equal(layoutMode(390, 844, 47, 34), 'deck');
});

test('tall inset-less Android phones get the deck layout', () => {
  // 412x915 (20:9-ish), browser viewport already excludes system bars.
  assert.equal(layoutMode(412, 915, 0, 0), 'deck');
});

test('16:9-and-shorter screens fall back to the overlay layout', () => {
  assert.equal(layoutMode(360, 640, 0, 0), 'overlay'); // exact 16:9
  assert.equal(layoutMode(375, 667, 0, 0), 'overlay'); // iPhone SE
  assert.equal(layoutMode(768, 1024, 0, 0), 'overlay'); // 3:4 tablet
  assert.equal(layoutMode(852, 393, 0, 0), 'overlay'); // landscape
});

test('a dead zone only slightly over 16:9 is still too small for the deck', () => {
  // The deck needs MIN_DECK_PX of content PLUS the 5px bottom-padding floor
  // (styles.css pads the deck bottom by max(5px, safe-bottom)).
  const w = 390;
  const videoH = (w * 16) / 9;
  assert.equal(layoutMode(w, Math.ceil(videoH) + 5 + MIN_DECK_PX - 1, 0, 0), 'overlay');
  // At/above the threshold the deck wins.
  assert.equal(layoutMode(w, Math.ceil(videoH) + 5 + MIN_DECK_PX + 1, 0, 0), 'deck');
});

test('the bottom inset counts against the usable dead zone', () => {
  const w = 390;
  const h = Math.ceil((w * 16) / 9) + 5 + MIN_DECK_PX + 10;
  assert.equal(layoutMode(w, h, 0, 0), 'deck');
  assert.equal(layoutMode(w, h, 0, 34), 'overlay'); // home bar eats the margin
});

test('the deck bottom padding floors at 5px even without an inset', () => {
  // styles.css pads the deck bottom by max(5px, safe-bottom): a dead zone
  // that fits the rows only with a 0px bottom pad must NOT pick the deck (it
  // would clip the stats line), and a sub-floor inset changes nothing.
  const w = 390;
  const base = Math.ceil((w * 16) / 9);
  assert.equal(layoutMode(w, base + MIN_DECK_PX + 1, 0, 0), 'overlay');
  assert.equal(layoutMode(w, base + 5 + MIN_DECK_PX + 1, 0, 3), 'deck');
  assert.equal(layoutMode(w, base + 5 + MIN_DECK_PX + 1, 0, 5), 'deck');
});

test('degenerate viewports fall back to the overlay layout', () => {
  assert.equal(layoutMode(0, 852, 0, 0), 'overlay');
  assert.equal(layoutMode(393, 0, 0, 0), 'overlay');
  assert.equal(layoutMode(NaN, NaN, 0, 0), 'overlay');
});

test('minDeck override is honored', () => {
  const w = 390;
  const h = Math.ceil((w * 16) / 9) + 40;
  assert.equal(layoutMode(w, h, 0, 0, 30), 'deck');
  assert.equal(layoutMode(w, h, 0, 0, 50), 'overlay');
});

// resolveMode: the soft-keyboard flip guard. The Android keyboard (chat Aa)
// shrinks the viewport HEIGHT only, so a height-only deck→overlay candidate
// is a keyboard artifact and must not flip the page mid-chat; rotation and
// docking change the width too and flip normally.

test('keyboard-height shrink never flips deck to overlay', () => {
  // Deck applied at width 412; the keyboard drops innerHeight below the deck
  // threshold — same width, so the deck holds through open AND the close
  // animation's stale-height resize.
  assert.equal(resolveMode('deck', 'overlay', 412, 412), 'deck');
});

test('a width change makes the deck→overlay flip real', () => {
  // Rotation (412x915 → 915x412) or docking: the width moved, honor the flip.
  assert.equal(resolveMode('deck', 'overlay', 412, 915), 'overlay');
});

test('all other transitions apply unconditionally', () => {
  // overlay→deck (keyboard closed on an overlay-native screen, fold opened):
  // never held, whatever the width did.
  assert.equal(resolveMode('overlay', 'deck', 360, 360), 'deck');
  assert.equal(resolveMode('overlay', 'deck', 360, 720), 'deck');
  // Steady states stay put.
  assert.equal(resolveMode('deck', 'deck', 412, 412), 'deck');
  assert.equal(resolveMode('overlay', 'overlay', 360, 360), 'overlay');
});

test('the boot decision is never guarded', () => {
  // First apply: no previous mode/width — the candidate always wins.
  assert.equal(resolveMode(null, 'overlay', null, 360), 'overlay');
  assert.equal(resolveMode(null, 'deck', null, 412), 'deck');
});
