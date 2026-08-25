// Chat keyboard overlay. Flow on submit (all on the reliable channel, so the
// server injects strictly in order):
//   VK_RETURN press/release      — opens the WoW chat edit box
//   per-character KEY pairs      — typed via the US-layout map (see vk.js;
//                                  characters with no US key are skipped)
//   VK_RETURN press/release      — sends the line
// Shift is carried in the KEY mods field; the server syncs modifier state.

import { VK, charToKey } from './vk.js';
import { MOD } from './protocol.js';

export class ChatKeyboard {
  #root;
  #input;
  #sender;
  #onUnavailable;

  /** @param onUnavailable called (with a user-facing message) when a submit
   *    is refused because the input channel is not open. */
  constructor({ element, sender, onUnavailable }) {
    this.#root = element;
    this.#sender = sender;
    this.#onUnavailable = onUnavailable;
    this.#input = element.querySelector('#kb-input');

    element.querySelector('#kb-form').addEventListener('submit', (e) => {
      e.preventDefault();
      this.#submit();
    });
    element.querySelector('#kb-cancel').addEventListener('click', () => this.close());
    // A tap on the dimmed backdrop (not the form) also cancels.
    element.addEventListener('pointerdown', (e) => {
      if (e.target === element) this.close();
    });
  }

  get isOpen() {
    return !this.#root.hidden;
  }

  open() {
    this.#root.hidden = false;
    this.#input.value = '';
    this.#input.focus();
  }

  close() {
    this.#root.hidden = true;
    this.#input.blur();
  }

  #submit() {
    // Checked BEFORE closing: during a reconnect blip the typed line must not
    // silently vanish. Keep the overlay (and the text) up and tell the user;
    // they can retry once the HUD shows "live" again, or Esc out themselves.
    if (!this.#sender.ready) {
      this.#onUnavailable('Not connected — message not sent');
      return;
    }
    const text = this.#input.value;
    this.close();
    this.#tapKey(VK.RETURN, MOD.NONE); // open chat box
    for (const ch of text) {
      const key = charToKey(ch);
      if (!key) continue; // not representable on a US layout — skipped
      this.#tapKey(key.vk, key.shift ? MOD.SHIFT : MOD.NONE);
    }
    this.#tapKey(VK.RETURN, MOD.NONE); // send the line
  }

  #tapKey(vk, mods) {
    this.#sender.key(vk, true, mods);
    this.#sender.key(vk, false, mods);
  }
}
