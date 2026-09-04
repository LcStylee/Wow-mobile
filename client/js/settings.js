// Tiny persisted settings store (localStorage) with change subscribers.
//
// PERSISTENCE MODEL (v2): only keys the user EXPLICITLY set are stored — the
// stored blob is a delta over DEFAULTS, stamped with `_v`. That way a later
// release can change a default (as v2 did for cameraSensitivity) and every
// user who never touched the knob adopts the new value, while explicit
// choices survive verbatim. v1 blobs stored every key including untouched
// defaults, so the v1→v2 migration prunes values equal to the v1 defaults.

const STORAGE_KEY = 'wowmobile.settings.v1';
// Schema version stamped into the stored blob (`_v`; absent = 1).
// v2: cameraSensitivity default lowered 1.6 → 0.8 (field feedback: default
//     camera drag far too sensitive), storage became explicit-deltas-only.
const SCHEMA_VERSION = 2;

export const DEFAULTS = Object.freeze({
  // Capture-fraction per touch-fraction multiplier for the camera drag.
  // 0.8 — half the original 1.6, which field users found twitchy: a
  // full-width thumb swipe now pans ~80% of the world square instead of
  // overshooting it 1.6x. The settings slider (0.2–3) covers both tastes.
  cameraSensitivity: 0.8,
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
  showRail: true, // quick-keys row visible
  hudVisible: true, // stats expanded (overlay layout: strip shown at all)
  audio: false, // stream audio unmuted
  // Deck-vs-overlay escape hatch ("Controls below the game"): 'auto' lets
  // layout.js measure, 'always'/'never' pin the mode for devices the
  // measurement misdetects (layout.js applyOverride; unknown values = auto).
  deckLayout: 'auto',
});

// What DEFAULTS held before SCHEMA_VERSION 2 — needed to tell "stored because
// v1 persisted everything" from "stored because the user chose it".
const V1_DEFAULTS = Object.freeze({ ...DEFAULTS, cameraSensitivity: 1.6 });

export class Settings {
  #values;
  // Only the keys the user explicitly set (this is what gets persisted).
  #userValues = {};
  #listeners = new Set();

  constructor() {
    let stored = {};
    try {
      stored = JSON.parse(localStorage.getItem(STORAGE_KEY)) ?? {};
    } catch {
      // Corrupt/absent storage falls back to defaults.
    }
    const storedVersion = typeof stored._v === 'number' ? stored._v : 1;
    if (storedVersion < 2) {
      // v1 persisted the full settings object, so an untouched default is
      // indistinguishable from an explicit choice by presence alone. Prune
      // every value still equal to its v1 default: those users adopt current
      // (and future) defaults — most importantly cameraSensitivity 1.6 → 0.8.
      // A user who deliberately chose the old default loses that one choice;
      // there is no marker in v1 data that could tell the two apart.
      for (const k of Object.keys(V1_DEFAULTS)) {
        if (stored[k] === V1_DEFAULTS[k]) delete stored[k];
      }
    }
    // Only known keys of the right type survive, so stale schema versions
    // (and the _v stamp itself) can't leak in.
    this.#values = { ...DEFAULTS };
    for (const k of Object.keys(DEFAULTS)) {
      if (typeof stored[k] === typeof DEFAULTS[k]) {
        this.#values[k] = stored[k];
        this.#userValues[k] = stored[k];
      }
    }
    // Rewrite migrated (or unstamped) storage once, so the pruning above and
    // the version stamp stick even if the user never changes a setting again.
    if (storedVersion !== SCHEMA_VERSION) this.#persist();
  }

  get(key) {
    return this.#values[key];
  }

  set(key, value) {
    if (!(key in DEFAULTS)) throw new RangeError(`unknown setting: ${key}`);
    if (this.#values[key] === value) {
      // Same value, but still an EXPLICIT choice: record it so a user who
      // deliberately lands a slider on the current default keeps that value
      // across any future default change (listeners are skipped — nothing
      // observable changed).
      if (this.#userValues[key] !== value) {
        this.#userValues[key] = value;
        this.#persist();
      }
      return;
    }
    this.#values[key] = value;
    this.#userValues[key] = value; // explicit choice: persists over defaults
    this.#persist();
    for (const fn of this.#listeners) fn(key, value);
  }

  #persist() {
    try {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({ _v: SCHEMA_VERSION, ...this.#userValues }),
      );
    } catch {
      // Private mode / quota: settings become session-only, which is fine.
    }
  }

  /** @param fn (key, value) => void; returns an unsubscribe function. */
  onChange(fn) {
    this.#listeners.add(fn);
    return () => this.#listeners.delete(fn);
  }
}
