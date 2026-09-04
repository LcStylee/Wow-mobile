// Settings store tests for js/settings.js — the v1→v2 migration contract:
// the camera-sensitivity default dropped 1.6 → 0.8, and a stored v1 value
// still equal to the old default (v1 persisted every key, chosen or not)
// must adopt the new default, while explicit choices survive.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { DEFAULTS, Settings } from '../js/settings.js';

const KEY = 'wowmobile.settings.v1';

/** Minimal localStorage stand-in (node has none); returns its backing map. */
function stubStorage(t, initial) {
  const map = new Map();
  if (initial !== undefined) map.set(KEY, JSON.stringify(initial));
  globalThis.localStorage = {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  };
  t.after(() => delete globalThis.localStorage);
  return map;
}

function storedBlob(map) {
  return JSON.parse(map.get(KEY));
}

test('camera sensitivity defaults to 0.8', () => {
  assert.equal(DEFAULTS.cameraSensitivity, 0.8);
});

test('fresh install: defaults, storage stamped with the schema version', (t) => {
  const map = stubStorage(t);
  const s = new Settings();
  assert.equal(s.get('cameraSensitivity'), 0.8);
  assert.equal(storedBlob(map)._v, 2);
});

test('v1 blob at the old 1.6 default migrates to the new default', (t) => {
  // v1 persisted the full object on any set(); this user changed only audio,
  // so cameraSensitivity 1.6 is the untouched old default → adopt 0.8.
  const map = stubStorage(t, { cameraSensitivity: 1.6, audio: true });
  const s = new Settings();
  assert.equal(s.get('cameraSensitivity'), 0.8);
  assert.equal(s.get('audio'), true); // the explicit choice survives
  const blob = storedBlob(map);
  assert.equal(blob._v, 2);
  assert.ok(!('cameraSensitivity' in blob)); // pruned: tracks future defaults
  assert.equal(blob.audio, true);
});

test('v1 blob with a non-default sensitivity keeps the explicit choice', (t) => {
  stubStorage(t, { cameraSensitivity: 1.2 });
  assert.equal(new Settings().get('cameraSensitivity'), 1.2);
});

test('v1 values equal to their old defaults are pruned, others kept', (t) => {
  const map = stubStorage(t, {
    cameraSensitivity: 1.6,
    joystickScale: 1.0, // v1 default → pruned
    worldViewportPx: 900, // explicit → kept
  });
  const s = new Settings();
  assert.equal(s.get('worldViewportPx'), 900);
  const blob = storedBlob(map);
  assert.ok(!('joystickScale' in blob));
  assert.equal(blob.worldViewportPx, 900);
});

test('a v2 blob with sensitivity 1.6 is an explicit choice and sticks', (t) => {
  stubStorage(t, { _v: 2, cameraSensitivity: 1.6 });
  assert.equal(new Settings().get('cameraSensitivity'), 1.6);
});

test('set() persists only explicit deltas plus the version stamp', (t) => {
  const map = stubStorage(t);
  const s = new Settings();
  s.set('joystickScale', 1.3);
  const blob = storedBlob(map);
  assert.deepEqual(blob, { _v: 2, joystickScale: 1.3 });
  // A later default change would therefore reach every untouched key.
});

test('set() round-trips through a fresh Settings instance', (t) => {
  stubStorage(t);
  new Settings().set('cameraSensitivity', 0.55);
  assert.equal(new Settings().get('cameraSensitivity'), 0.55);
});

test('unknown keys still throw', (t) => {
  stubStorage(t);
  assert.throws(() => new Settings().set('nope', 1), RangeError);
});
