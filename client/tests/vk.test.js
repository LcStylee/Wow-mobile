// Tests for the US-layout char -> VK map used by the chat keyboard.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { VK, charToKey } from '../js/vk.js';

test('quick-rail VK codes are the Windows values', () => {
  assert.equal(VK.RETURN, 0x0d);
  assert.equal(VK.ESCAPE, 0x1b);
  assert.equal(VK.SPACE, 0x20);
  assert.equal(VK.M, 0x4d);
  assert.equal(VK.B, 0x42);
  // WASD for the joystick
  assert.equal(VK.W, 0x57);
  assert.equal(VK.A, 0x41);
  assert.equal(VK.S, 0x53);
  assert.equal(VK.D, 0x44);
});

test('letters map case to shift on the same key', () => {
  assert.deepEqual(charToKey('a'), { vk: 0x41, shift: false });
  assert.deepEqual(charToKey('z'), { vk: 0x5a, shift: false });
  assert.deepEqual(charToKey('A'), { vk: 0x41, shift: true });
  assert.deepEqual(charToKey('Z'), { vk: 0x5a, shift: true });
});

test('digits and space are unshifted', () => {
  assert.deepEqual(charToKey('0'), { vk: 0x30, shift: false });
  assert.deepEqual(charToKey('9'), { vk: 0x39, shift: false });
  assert.deepEqual(charToKey(' '), { vk: 0x20, shift: false });
});

test('US punctuation maps to OEM keys, shifted symbols to their base key', () => {
  assert.deepEqual(charToKey('/'), { vk: 0xbf, shift: false });
  assert.deepEqual(charToKey('?'), { vk: 0xbf, shift: true });
  assert.deepEqual(charToKey(';'), { vk: 0xba, shift: false });
  assert.deepEqual(charToKey(':'), { vk: 0xba, shift: true });
  assert.deepEqual(charToKey("'"), { vk: 0xde, shift: false });
  assert.deepEqual(charToKey('"'), { vk: 0xde, shift: true });
  assert.deepEqual(charToKey('!'), { vk: 0x31, shift: true }); // shift+1
  assert.deepEqual(charToKey(')'), { vk: 0x30, shift: true }); // shift+0
  assert.deepEqual(charToKey('\\'), { vk: 0xdc, shift: false });
  assert.deepEqual(charToKey('|'), { vk: 0xdc, shift: true });
});

test('characters without a US key are rejected (caller skips them)', () => {
  assert.equal(charToKey('é'), null);
  assert.equal(charToKey('€'), null);
  assert.equal(charToKey('あ'), null);
  assert.equal(charToKey('ab'), null); // not a single character
});
