// InputSender dead-man keepalive tests: while keys/buttons are held the
// sender must re-assert them every second (PROTOCOL.md gives the server a
// 3 s dead-man release), and must stop the instant nothing is held. Data
// channels are stubbed; time is driven with node:test mock timers.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { InputSender } from '../js/net.js';
import { BUTTON, MOD } from '../js/protocol.js';

const VK_W = 0x57;

function fakeChannel() {
  return {
    readyState: 'open',
    sent: [],
    send(buf) {
      this.sent.push(Array.from(new Uint8Array(buf)));
    },
  };
}

function attachedSender() {
  const input = fakeChannel();
  const move = fakeChannel();
  const sender = new InputSender();
  sender.attach(input, move);
  return { sender, input, move };
}

test('held key is re-asserted as KEY-down every second', (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const { sender, input } = attachedSender();

  sender.key(VK_W, true);
  assert.equal(input.sent.length, 1); // the original down

  t.mock.timers.tick(1000);
  t.mock.timers.tick(1000);
  assert.equal(input.sent.length, 3);
  // Each re-assert is byte-identical to the original KEY-down.
  assert.deepEqual(input.sent[1], [0x04, 0x01, VK_W, 0x00, 0x00, 0x00, 0x00, 0x00]);
  assert.deepEqual(input.sent[2], input.sent[1]);

  sender.key(VK_W, false);
  const after = input.sent.length;
  t.mock.timers.tick(5000);
  assert.equal(input.sent.length, after); // nothing held → loop stopped
});

test('re-asserted keys carry their original mods', (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const { sender, input } = attachedSender();

  sender.key(VK_W, true, MOD.SHIFT);
  t.mock.timers.tick(1000);
  assert.deepEqual(input.sent[1], [0x04, 0x01, VK_W, 0x00, 0x01, 0x00, 0x00, 0x00]);
});

test('held button keeps alive via reliable POINTER_MOVE, never a repeat down', (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const { sender, input, move } = attachedSender();

  sender.pointerDown(BUTTON.RIGHT, 0x1234, 0xabcd);
  t.mock.timers.tick(1000);
  assert.equal(input.sent.length, 2);
  // POINTER_MOVE, buttons mask bit1 (RIGHT), last position, seq 0 — on the
  // reliable channel so a stalled link still delivers it (late but counted).
  assert.deepEqual(input.sent[1], [0x02, 0x02, 0x34, 0x12, 0xcd, 0xab, 0x00, 0x00]);
  assert.equal(move.sent.length, 0);
  assert.ok(!input.sent.some((m, i) => i > 0 && m[0] === 0x01), 'no duplicate downs');

  sender.pointerUp(BUTTON.RIGHT, 0x1234, 0xabcd);
  const after = input.sent.length;
  t.mock.timers.tick(5000);
  assert.equal(input.sent.length, after);
});

test('releaseAll clears the held ledger and stops the loop', (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const { sender, input } = attachedSender();

  sender.key(VK_W, true);
  sender.pointerDown(BUTTON.RIGHT, 0, 0);
  sender.releaseAll();
  assert.deepEqual(input.sent.at(-1), [0x06, 0x00]);
  const after = input.sent.length;
  t.mock.timers.tick(5000);
  assert.equal(input.sent.length, after); // server holds nothing; neither do we
});

test('detach and re-attach start from an empty ledger', (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const { sender } = attachedSender();
  sender.key(VK_W, true);
  sender.detach();

  const input2 = fakeChannel();
  const move2 = fakeChannel();
  sender.attach(input2, move2);
  t.mock.timers.tick(5000);
  assert.equal(input2.sent.length, 0); // stale hold must not leak into a new session
});
