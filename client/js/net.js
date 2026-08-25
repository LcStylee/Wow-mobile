// InputSender: the one place that turns semantic input calls into wire bytes
// on the right data channel. Owns the session's single MoveSequencer — the
// server keeps one seq horizon across BOTH channels (a reliable move advances
// it), so lossy and reliable moves must never use independent counters — and
// the held-input ledger that keeps the server's dead-man timer fed (below).

import {
  MOD,
  MoveSequencer,
  encodeKey,
  encodePointerDown,
  encodePointerMove,
  encodePointerUp,
  encodeReleaseAll,
  encodeWheel,
} from './protocol.js';

// PROTOCOL.md dead-man: the server force-releases everything after 3 s
// without ANY message while inputs are held. A motionless hold — static
// joystick (W), parked camera drag (RMB), held rail Space — generates no
// traffic of its own, and the 2 s ctrl latencyProbe leaves only a 1 s margin
// that one Wi-Fi stall can blow through. So while anything is held, re-assert
// it every second: three chances inside the window, and if the dead-man DID
// fire, the next re-sent KEY-down re-presses the key so a held joystick
// self-heals instead of going silently dead.
const REASSERT_INTERVAL_MS = 1000;

export class InputSender {
  #input = null; // reliable/ordered: every state-changing event
  #move = null; // unordered/maxRetransmits 0: high-rate POINTER_MOVE only
  #seq = new MoveSequencer();

  // Held-state ledger, mirrored from the semantic calls that all flow through
  // this class (joystick/rail keys, camera RMB). Drives the re-assert loop.
  #heldKeys = new Map(); // vk -> mods, as sent on the KEY-down
  #heldButtons = new Set(); // BUTTON.* codes currently down
  #lastPos = { x: 0, y: 0 }; // last wire position, for button keepalive moves
  #reassertTimer = null;

  /** Bind the session's channels. Called once per connection attempt. */
  attach(inputChannel, moveChannel) {
    this.#input = inputChannel;
    this.#move = moveChannel;
    this.#seq = new MoveSequencer(); // fresh session, fresh seq horizon
    this.#clearHeld(); // fresh session: server-side held state starts empty
  }

  detach() {
    this.#input = null;
    this.#move = null;
    this.#clearHeld();
  }

  get ready() {
    return this.#input?.readyState === 'open';
  }

  #send(channel, buf) {
    if (channel?.readyState !== 'open') return; // dropped: connection is down/dying
    try {
      channel.send(buf);
    } catch {
      // send() can throw during the close race; the state machine handles it.
    }
  }

  pointerDown(button, x, y) {
    this.#heldButtons.add(button);
    this.#lastPos = { x, y };
    this.#syncReassertTimer();
    this.#send(this.#input, encodePointerDown(button, x, y));
  }

  pointerUp(button, x, y) {
    this.#heldButtons.delete(button);
    this.#lastPos = { x, y };
    this.#syncReassertTimer();
    this.#send(this.#input, encodePointerUp(button, x, y));
  }

  /**
   * POINTER_MOVE on the reliable channel — used immediately before a
   * down/up to guarantee position at the transition (PROTOCOL.md).
   */
  movePrecise(buttons, x, y) {
    this.#lastPos = { x, y };
    this.#send(this.#input, encodePointerMove(buttons, x, y, this.#seq.next()));
  }

  /** High-rate POINTER_MOVE on the lossy channel (camera drags). */
  moveLossy(buttons, x, y) {
    this.#lastPos = { x, y };
    this.#send(this.#move, encodePointerMove(buttons, x, y, this.#seq.next()));
  }

  key(vk, down, mods = MOD.NONE) {
    if (down) this.#heldKeys.set(vk, mods);
    else this.#heldKeys.delete(vk);
    this.#syncReassertTimer();
    this.#send(this.#input, encodeKey(down, vk, mods));
  }

  wheel(x, y, delta) {
    this.#send(this.#input, encodeWheel(x, y, delta));
  }

  releaseAll() {
    this.#clearHeld(); // the server is about to hold nothing; mirror that
    this.#send(this.#input, encodeReleaseAll());
  }

  // ---- dead-man keepalive -------------------------------------------------

  #clearHeld() {
    this.#heldKeys.clear();
    this.#heldButtons.clear();
    this.#syncReassertTimer();
  }

  /** Run the 1 Hz re-assert loop exactly while something is held. */
  #syncReassertTimer() {
    const wantRunning =
      this.#input !== null && (this.#heldKeys.size > 0 || this.#heldButtons.size > 0);
    if (wantRunning && this.#reassertTimer === null) {
      this.#reassertTimer = setInterval(() => this.#reassert(), REASSERT_INTERVAL_MS);
    } else if (!wantRunning && this.#reassertTimer !== null) {
      clearInterval(this.#reassertTimer);
      this.#reassertTimer = null;
    }
  }

  #reassert() {
    if (this.#input?.readyState !== 'open') return; // reconnect path owns recovery
    // Re-sending KEY-down for an already-held key is safe: the server tracks
    // it as one hold (PROTOCOL.md safety rule 2), and the injected repeat
    // keydown is exactly what a physically held key produces via autorepeat.
    // This doubles as the self-heal — after a dead-man RELEASE_ALL the next
    // re-assert re-presses every key the client still considers held.
    for (const [vk, mods] of this.#heldKeys) {
      this.#send(this.#input, encodeKey(true, vk, mods));
    }
    // Held buttons are kept alive with a reliable POINTER_MOVE at the last
    // position (PROTOCOL.md permits POINTER_MOVE on `input`); any delivered
    // message resets the dead-man. Deliberately NOT a repeated POINTER_DOWN:
    // a duplicate WM_RBUTTONDOWN is a game-visible click edge (unlike a
    // repeat keydown), so a held button survives any stall the reliable
    // channel can ride out inside 3 s — beyond that the connection state
    // machine is already tearing the gesture down.
    if (this.#heldButtons.size > 0) {
      let mask = 0;
      // BUTTON codes are bit indices of BUTTONS_BIT (0→L=1, 1→R=2, 2→M=4).
      for (const button of this.#heldButtons) mask |= 1 << button;
      this.#send(
        this.#input,
        encodePointerMove(mask, this.#lastPos.x, this.#lastPos.y, this.#seq.next()),
      );
    }
  }
}
