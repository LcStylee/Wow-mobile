// Tiny persisted settings store (localStorage) with change subscribers.

const STORAGE_KEY = 'wowmobile.settings.v1';

export const DEFAULTS = Object.freeze({
  cameraSensitivity: 1.6, // capture-fraction per touch-fraction multiplier
  joystickScale: 1.0, // multiplier on the joystick's base radius
  // World-square height in the addon's design px (its `/wm viewport` value,
  // default 1080 = full-width square). The wire protocol carries no viewport
  // field, so the gesture-region math (input.js/geometry.js) relies on this
  // matching the addon's setting — SETUP.md tells users to change both
  // together.
  worldViewportPx: 1080,
  // Requested encoder bitrate, sent as the ctrl `bitrate` message. 0 = auto:
  // leave the server's configured bitrate alone and send nothing.
  bitrateKbps: 0,
  showRail: true, // quick rail visible
  hudVisible: true, // stats strip expanded
  audio: false, // stream audio unmuted
});

export class Settings {
  #values;
  #listeners = new Set();

  constructor() {
    let stored = {};
    try {
      stored = JSON.parse(localStorage.getItem(STORAGE_KEY)) ?? {};
    } catch {
      // Corrupt/absent storage falls back to defaults.
    }
    // Only known keys survive, so stale schema versions can't leak in.
    this.#values = { ...DEFAULTS };
    for (const k of Object.keys(DEFAULTS)) {
      if (typeof stored[k] === typeof DEFAULTS[k]) this.#values[k] = stored[k];
    }
  }

  get(key) {
    return this.#values[key];
  }

  set(key, value) {
    if (!(key in DEFAULTS)) throw new RangeError(`unknown setting: ${key}`);
    if (this.#values[key] === value) return;
    this.#values[key] = value;
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(this.#values));
    } catch {
      // Private mode / quota: settings become session-only, which is fine.
    }
    for (const fn of this.#listeners) fn(key, value);
  }

  /** @param fn (key, value) => void; returns an unsubscribe function. */
  onChange(fn) {
    this.#listeners.add(fn);
    return () => this.#listeners.delete(fn);
  }
}
