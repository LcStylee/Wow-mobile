// Quick keys (#rail): the always-available key strip. In the deck layout it
// renders as one horizontal row inside the phone deck (styles.css lays it
// out; the collapse handle is hidden there); in the overlay fallback it is a
// collapsible bar floating over the video. Every key is a true hold —
// KEY-down on touch, KEY-up on release — so Space can be held for a long
// jump/swim exactly like a physical spacebar.

import { VK } from './vk.js';

const KEYS = [
  { vk: VK.SPACE, label: 'Spc', hint: 'Jump (hold to keep jumping)' },
  { vk: VK.ESCAPE, label: 'Esc', hint: 'Escape / close panel' },
  { vk: null, label: 'Aa', hint: 'Open chat keyboard' }, // handled by overlay
  { vk: VK.M, label: 'M', hint: 'Map' },
  { vk: VK.B, label: 'B', hint: 'Bags' },
];

export class QuickRail {
  #el;
  #strip;
  #handle;
  #sender;
  #collapsed = false;
  // One silent-clear function per hold-key button, for reset() below.
  #holdClears = [];

  constructor({ element, sender, onOpenKeyboard, settings }) {
    this.#el = element;
    this.#sender = sender;

    this.#handle = document.createElement('button');
    this.#handle.className = 'rail-handle';
    this.#handle.setAttribute('aria-label', 'Collapse quick keys');
    this.#handle.textContent = '›';
    this.#handle.addEventListener('click', () => this.#setCollapsed(!this.#collapsed));
    element.appendChild(this.#handle);

    this.#strip = document.createElement('div');
    this.#strip.className = 'rail-strip';
    element.appendChild(this.#strip);

    for (const key of KEYS) {
      const btn = document.createElement('button');
      btn.className = 'rail-key';
      btn.textContent = key.label;
      btn.title = key.hint;
      if (key.vk === null) {
        btn.addEventListener('click', () => onOpenKeyboard());
      } else {
        this.#wireHoldKey(btn, key.vk);
      }
      this.#strip.appendChild(btn);
    }

    this.setVisible(settings.get('showRail'));
    settings.onChange((k, v) => {
      if (k === 'showRail') this.setVisible(v);
    });
  }

  #wireHoldKey(btn, vk) {
    let held = false;
    const release = () => {
      if (!held) return;
      held = false;
      btn.classList.remove('held');
      this.#sender.key(vk, false);
    };
    btn.addEventListener('pointerdown', (e) => {
      e.preventDefault(); // no focus ring / synthetic mouse events
      btn.setPointerCapture(e.pointerId);
      held = true;
      btn.classList.add('held');
      this.#sender.key(vk, true);
    });
    btn.addEventListener('pointerup', release);
    btn.addEventListener('pointercancel', release);
    this.#holdClears.push(() => {
      held = false;
      btn.classList.remove('held');
    });
  }

  /**
   * Forget every held rail key WITHOUT sending KEY-ups. Called after the app
   * sends RELEASE_ALL (visibility loss / teardown): the server has already
   * released everything, so the pointerup/pointercancel that follows must not
   * re-inject a stray KEY-up. Mirrors TouchLayer.reset() / Joystick.reset().
   */
  reset() {
    for (const clear of this.#holdClears) clear();
  }

  setVisible(visible) {
    this.#el.hidden = !visible;
  }

  // Collapse is an overlay-layout affordance: styles.css scopes the
  // .collapsed rule to body.layout-overlay, so the class can safely survive a
  // flip into deck mode (where the handle is hidden) without leaving an empty
  // gap, and the choice is remembered when the overlay layout returns.
  #setCollapsed(collapsed) {
    this.#collapsed = collapsed;
    this.#el.classList.toggle('collapsed', collapsed);
    this.#handle.textContent = collapsed ? '‹' : '›';
    this.#handle.setAttribute(
      'aria-label',
      collapsed ? 'Expand quick keys' : 'Collapse quick keys',
    );
  }
}
