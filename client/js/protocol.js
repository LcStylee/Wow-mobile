// Byte-exact encoders for protocol/PROTOCOL.md "Binary input events" (v1).
// All integers little-endian; one ArrayBuffer per data-channel message.
// This module is deliberately DOM-free so tests/protocol.test.js can run it
// under `node --test` unchanged.

/** Protocol version sent in the ctrl `hello` message: [major, minor]. */
export const PROTO_VERSION = Object.freeze([1, 0]);

/** Wire message type bytes. */
export const TYPE = Object.freeze({
  POINTER_DOWN: 0x01,
  POINTER_MOVE: 0x02,
  POINTER_UP: 0x03,
  KEY: 0x04,
  WHEEL: 0x05,
  RELEASE_ALL: 0x06,
});

/** POINTER_DOWN / POINTER_UP button field. */
export const BUTTON = Object.freeze({ LEFT: 0, RIGHT: 1, MIDDLE: 2 });

/** POINTER_MOVE informational held-buttons bitmask. */
export const BUTTONS_BIT = Object.freeze({ LEFT: 1, RIGHT: 2, MIDDLE: 4 });

/** KEY modifier bitmask (server syncs modifier state from these bits). */
export const MOD = Object.freeze({ NONE: 0, SHIFT: 1, CTRL: 2, ALT: 4 });

/** WHEEL delta unit: one detent per PROTOCOL.md ("multiples of 120"). */
export const WHEEL_NOTCH = 120;

function checkInt(name, v, lo, hi) {
  if (!Number.isInteger(v) || v < lo || v > hi) {
    throw new RangeError(`${name} must be an integer in ${lo}..${hi}, got ${v}`);
  }
}

/**
 * Map a 0..1 fraction of the capture client area to the wire's u16 range.
 * Clamps first: gesture math may momentarily land epsilon outside the frame.
 */
export function norm16(frac) {
  const f = frac < 0 ? 0 : frac > 1 ? 1 : frac;
  return Math.round(f * 0xffff);
}

/** 0x01 POINTER_DOWN — 8 bytes. */
export function encodePointerDown(button, x, y) {
  return pointerButtonMessage(TYPE.POINTER_DOWN, button, x, y);
}

/** 0x03 POINTER_UP — 8 bytes (body identical to POINTER_DOWN). */
export function encodePointerUp(button, x, y) {
  return pointerButtonMessage(TYPE.POINTER_UP, button, x, y);
}

function pointerButtonMessage(type, button, x, y) {
  checkInt('button', button, 0, 2);
  checkInt('x', x, 0, 0xffff);
  checkInt('y', y, 0, 0xffff);
  const buf = new ArrayBuffer(8);
  const v = new DataView(buf);
  v.setUint8(0, type);
  v.setUint8(1, button);
  v.setUint16(2, x, true);
  v.setUint16(4, y, true);
  v.setUint16(6, 0, true); // reserved
  return buf;
}

/** 0x02 POINTER_MOVE — 8 bytes. Prefer MoveSequencer over hand-fed seq. */
export function encodePointerMove(buttons, x, y, seq) {
  checkInt('buttons', buttons, 0, 7);
  checkInt('x', x, 0, 0xffff);
  checkInt('y', y, 0, 0xffff);
  checkInt('seq', seq, 0, 0xffff);
  const buf = new ArrayBuffer(8);
  const v = new DataView(buf);
  v.setUint8(0, TYPE.POINTER_MOVE);
  v.setUint8(1, buttons);
  v.setUint16(2, x, true);
  v.setUint16(4, y, true);
  v.setUint16(6, seq, true);
  return buf;
}

/** 0x04 KEY — 8 bytes. */
export function encodeKey(down, vk, mods = MOD.NONE) {
  if (typeof down !== 'boolean') throw new RangeError('down must be a boolean');
  checkInt('vk', vk, 0, 0xffff);
  checkInt('mods', mods, 0, 7);
  const buf = new ArrayBuffer(8);
  const v = new DataView(buf);
  v.setUint8(0, TYPE.KEY);
  v.setUint8(1, down ? 1 : 0);
  v.setUint16(2, vk, true);
  v.setUint16(4, mods, true);
  v.setUint16(6, 0, true); // reserved
  return buf;
}

/** 0x05 WHEEL — 8 bytes; delta i16 in multiples of 120, positive = up. */
export function encodeWheel(x, y, delta) {
  checkInt('x', x, 0, 0xffff);
  checkInt('y', y, 0, 0xffff);
  checkInt('delta', delta, -0x8000, 0x7fff);
  const buf = new ArrayBuffer(8);
  const v = new DataView(buf);
  v.setUint8(0, TYPE.WHEEL);
  v.setUint8(1, 0); // reserved
  v.setUint16(2, x, true);
  v.setUint16(4, y, true);
  v.setInt16(6, delta, true);
  return buf;
}

/** 0x06 RELEASE_ALL — 2 bytes. */
export function encodeReleaseAll() {
  const buf = new ArrayBuffer(2);
  const v = new DataView(buf);
  v.setUint8(0, TYPE.RELEASE_ALL);
  v.setUint8(1, 0); // reserved
  return buf;
}

/**
 * Wrapping u16 counter for POINTER_MOVE seq. The server keeps ONE seq horizon
 * across both channels (a reliable move advances it too), so a session must
 * route every move — lossy or reliable — through a single sequencer.
 */
export class MoveSequencer {
  #next;

  /** @param start first value to hand out (tests use this to hit the wrap). */
  constructor(start = 0) {
    checkInt('start', start, 0, 0xffff);
    this.#next = start;
  }

  /** Returns the current value and advances, wrapping 0xffff -> 0. */
  next() {
    const v = this.#next;
    this.#next = (v + 1) & 0xffff;
    return v;
  }
}
