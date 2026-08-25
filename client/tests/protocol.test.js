// Byte-layout tests for js/protocol.js against hand-written expected buffers
// taken straight from protocol/PROTOCOL.md. Every multi-byte value uses a
// distinct hi/lo byte pattern so an endianness slip cannot pass.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  BUTTON,
  BUTTONS_BIT,
  MOD,
  MoveSequencer,
  PROTO_VERSION,
  TYPE,
  WHEEL_NOTCH,
  encodeKey,
  encodePointerDown,
  encodePointerMove,
  encodePointerUp,
  encodeReleaseAll,
  encodeWheel,
  norm16,
} from '../js/protocol.js';

function bytes(buf) {
  return Array.from(new Uint8Array(buf));
}

test('constants match PROTOCOL.md', () => {
  assert.deepEqual(PROTO_VERSION, [1, 0]);
  assert.deepEqual(TYPE, {
    POINTER_DOWN: 0x01,
    POINTER_MOVE: 0x02,
    POINTER_UP: 0x03,
    KEY: 0x04,
    WHEEL: 0x05,
    RELEASE_ALL: 0x06,
  });
  assert.deepEqual(BUTTON, { LEFT: 0, RIGHT: 1, MIDDLE: 2 });
  assert.deepEqual(BUTTONS_BIT, { LEFT: 1, RIGHT: 2, MIDDLE: 4 });
  assert.deepEqual(MOD, { NONE: 0, SHIFT: 1, CTRL: 2, ALT: 4 });
  assert.equal(WHEEL_NOTCH, 120);
});

test('POINTER_DOWN: type, button, LE coords, zero reserved', () => {
  // x = 0x1234 -> 34 12; y = 0xABCD -> CD AB
  assert.deepEqual(
    bytes(encodePointerDown(BUTTON.RIGHT, 0x1234, 0xabcd)),
    [0x01, 0x01, 0x34, 0x12, 0xcd, 0xab, 0x00, 0x00],
  );
  assert.deepEqual(
    bytes(encodePointerDown(BUTTON.LEFT, 0, 0xffff)),
    [0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00],
  );
});

test('POINTER_UP: identical body layout with type 0x03', () => {
  assert.deepEqual(
    bytes(encodePointerUp(BUTTON.MIDDLE, 0x00ff, 0xff00)),
    [0x03, 0x02, 0xff, 0x00, 0x00, 0xff, 0x00, 0x00],
  );
});

test('POINTER_MOVE: buttons mask, LE coords, LE seq', () => {
  assert.deepEqual(
    bytes(encodePointerMove(BUTTONS_BIT.RIGHT, 0x0102, 0x0304, 0xbeef)),
    [0x02, 0x02, 0x02, 0x01, 0x04, 0x03, 0xef, 0xbe],
  );
});

test('KEY: down flag, LE vk, LE mods, zero reserved', () => {
  // VK 0x57 = 'W'
  assert.deepEqual(
    bytes(encodeKey(true, 0x57)),
    [0x04, 0x01, 0x57, 0x00, 0x00, 0x00, 0x00, 0x00],
  );
  assert.deepEqual(
    bytes(encodeKey(false, 0x0d, MOD.SHIFT | MOD.ALT)),
    [0x04, 0x00, 0x0d, 0x00, 0x05, 0x00, 0x00, 0x00],
  );
});

test('WHEEL: reserved byte, LE coords, signed LE delta', () => {
  assert.deepEqual(
    bytes(encodeWheel(0x1111, 0x2222, 120)),
    [0x05, 0x00, 0x11, 0x11, 0x22, 0x22, 0x78, 0x00],
  );
  // -120 = 0xFF88 two's complement -> 88 FF
  assert.deepEqual(
    bytes(encodeWheel(0, 0, -120)),
    [0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x88, 0xff],
  );
});

test('RELEASE_ALL: exactly two bytes', () => {
  assert.deepEqual(bytes(encodeReleaseAll()), [0x06, 0x00]);
});

test('MoveSequencer wraps 0xffff -> 0 and lands in the wire bytes', () => {
  const seq = new MoveSequencer(0xfffe);
  assert.equal(seq.next(), 0xfffe);
  assert.equal(seq.next(), 0xffff);
  assert.equal(seq.next(), 0x0000);
  assert.equal(seq.next(), 0x0001);

  const wrap = new MoveSequencer(0xffff);
  assert.deepEqual(
    bytes(encodePointerMove(0, 0, 0, wrap.next())).slice(6),
    [0xff, 0xff],
  );
  assert.deepEqual(
    bytes(encodePointerMove(0, 0, 0, wrap.next())).slice(6),
    [0x00, 0x00],
  );
});

test('norm16 maps 0..1 to 0..65535 with clamping and rounding', () => {
  assert.equal(norm16(0), 0);
  assert.equal(norm16(1), 0xffff);
  assert.equal(norm16(0.5), 32768); // round(32767.5)
  assert.equal(norm16(-0.25), 0);
  assert.equal(norm16(1.25), 0xffff);
});

test('encoders reject out-of-range fields', () => {
  assert.throws(() => encodePointerDown(3, 0, 0), RangeError);
  assert.throws(() => encodePointerDown(0, -1, 0), RangeError);
  assert.throws(() => encodePointerDown(0, 0, 0x10000), RangeError);
  assert.throws(() => encodePointerMove(8, 0, 0, 0), RangeError);
  assert.throws(() => encodePointerMove(0, 0, 0, 0x10000), RangeError);
  assert.throws(() => encodeKey(1, 0x57), RangeError); // down must be boolean
  assert.throws(() => encodeKey(true, 0x57, 8), RangeError);
  assert.throws(() => encodeWheel(0, 0, 0x8000), RangeError);
  assert.throws(() => encodeWheel(0, 0, -0x8001), RangeError);
  assert.throws(() => new MoveSequencer(-1), RangeError);
});
