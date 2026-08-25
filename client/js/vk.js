// Windows virtual-key codes used by the client, plus a char -> key map for
// the chat keyboard. DOM-free (unit-tested under node:test).
//
// LAYOUT LIMITATION: the char map assumes the HOST keyboard layout is US
// (QWERTY). The wire protocol carries VK codes, not characters; on a host
// with a non-US layout the OEM punctuation keys (0xBA..0xDE) produce that
// layout's characters instead. Letters, digits and space are layout-safe.

export const VK = Object.freeze({
  RETURN: 0x0d,
  SHIFT: 0x10,
  ESCAPE: 0x1b,
  SPACE: 0x20,
  A: 0x41,
  B: 0x42,
  D: 0x44,
  M: 0x4d,
  S: 0x53,
  W: 0x57,
});

// US-layout OEM punctuation keys (unshifted character -> VK).
const OEM = Object.freeze({
  ';': 0xba, // VK_OEM_1
  '=': 0xbb, // VK_OEM_PLUS
  ',': 0xbc, // VK_OEM_COMMA
  '-': 0xbd, // VK_OEM_MINUS
  '.': 0xbe, // VK_OEM_PERIOD
  '/': 0xbf, // VK_OEM_2
  '`': 0xc0, // VK_OEM_3
  '[': 0xdb, // VK_OEM_4
  '\\': 0xdc, // VK_OEM_5
  ']': 0xdd, // VK_OEM_6
  "'": 0xde, // VK_OEM_7
});

// Shifted character -> the unshifted character on the same US key.
const SHIFTED = Object.freeze({
  '!': '1', '@': '2', '#': '3', '$': '4', '%': '5',
  '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
  ':': ';', '+': '=', '<': ',', '_': '-', '>': '.',
  '?': '/', '~': '`', '{': '[', '|': '\\', '}': ']', '"': "'",
});

/**
 * Map one character to its US-layout key.
 * @returns {{vk:number, shift:boolean}|null} null when the character has no
 *   US-layout key (e.g. accented letters, emoji) — callers skip it.
 */
export function charToKey(ch) {
  if (ch.length !== 1) return null;
  const code = ch.charCodeAt(0);
  if (code >= 0x61 && code <= 0x7a) return { vk: code - 0x20, shift: false }; // a-z
  if (code >= 0x41 && code <= 0x5a) return { vk: code, shift: true }; // A-Z
  if (code >= 0x30 && code <= 0x39) return { vk: code, shift: false }; // 0-9
  if (ch === ' ') return { vk: VK.SPACE, shift: false };
  const base = SHIFTED[ch];
  if (base !== undefined) {
    const key = charToKey(base); // base is always a digit or OEM char
    return { vk: key.vk, shift: true };
  }
  const oem = OEM[ch];
  if (oem !== undefined) return { vk: oem, shift: false };
  return null;
}
