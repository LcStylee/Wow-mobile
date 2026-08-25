// Virtual movement joystick: dynamic-origin (base appears where the thumb
// lands inside its zone), 8-way WASD key holds with angular + radial
// hysteresis so diagonals don't flap at sector borders.

import { VK } from './vk.js';

// Sector 0 = east, counter-clockwise in 45° steps (screen-up = north).
// Note WoW Classic default bindings: A/D are Turn Left/Right, not strafe
// (strafe is Q/E); A/D strafe only while RMB is held. So a pure east push
// turns the character in place, and east + a simultaneous camera drag
// (which holds RMB) strafes — that mixed WASD/mouselook feel is the intended
// spec behavior, matching desktop WoW's own keyboard model.
const SECTOR_KEYS = [
  [VK.D], // E  → turn right (strafes while RMB held)
  [VK.W, VK.D], // NE
  [VK.W], // N  → forward
  [VK.W, VK.A], // NW
  [VK.A], // W  → turn left (strafes while RMB held)
  [VK.S, VK.A], // SW
  [VK.S], // S  → backpedal
  [VK.S, VK.D], // SE
];

const BASE_RADIUS_FRAC = 0.16; // of the world square's on-screen side
const ENGAGE_FRAC = 0.3; // radial deadzone: engage above this…
const RELEASE_FRAC = 0.2; // …release below this (hysteresis band)
const SECTOR_HALF_DEG = 22.5;
const SECTOR_HYST_DEG = 10; // must overshoot the border by this to switch

export class Joystick {
  #sender;
  #settings;
  #base;
  #knob;
  #active = false;
  #engaged = false;
  #origin = { x: 0, y: 0 };
  #radius = 0;
  #sector = -1;
  #held = new Set(); // VK codes with a KEY-down outstanding

  constructor({ container, sender, settings }) {
    this.#sender = sender;
    this.#settings = settings;
    this.#base = document.createElement('div');
    this.#base.className = 'joystick';
    this.#knob = document.createElement('div');
    this.#knob.className = 'joystick-knob';
    this.#base.appendChild(this.#knob);
    this.#base.hidden = true;
    container.appendChild(this.#base);
  }

  get active() {
    return this.#active;
  }

  /** @param squareSidePx on-screen side of the world square (scales the stick). */
  begin(clientX, clientY, squareSidePx) {
    this.#active = true;
    this.#engaged = false;
    this.#sector = -1;
    this.#origin = { x: clientX, y: clientY };
    this.#radius = squareSidePx * BASE_RADIUS_FRAC * this.#settings.get('joystickScale');
    const d = this.#radius * 2;
    this.#base.style.width = `${d}px`;
    this.#base.style.height = `${d}px`;
    this.#base.style.left = `${clientX - this.#radius}px`;
    this.#base.style.top = `${clientY - this.#radius}px`;
    this.#knob.style.transform = 'translate(0px, 0px)';
    this.#base.hidden = false;
  }

  move(clientX, clientY) {
    if (!this.#active) return;
    const dx = clientX - this.#origin.x;
    const dy = clientY - this.#origin.y;
    const r = Math.hypot(dx, dy);

    const vis = Math.min(r, this.#radius); // knob visual clamps to the rim
    const s = r > 0 ? vis / r : 0;
    this.#knob.style.transform = `translate(${dx * s}px, ${dy * s}px)`;

    if (!this.#engaged && r >= this.#radius * ENGAGE_FRAC) this.#engaged = true;
    else if (this.#engaged && r < this.#radius * RELEASE_FRAC) {
      this.#engaged = false;
      this.#sector = -1;
      this.#applyKeys(null);
    }
    if (!this.#engaged) return;

    // Screen y grows downward; negate so north = +90°.
    const angle = (Math.atan2(-dy, dx) * 180) / Math.PI;
    if (this.#sector < 0) {
      this.#sector = ((Math.round(angle / 45) % 8) + 8) % 8;
    } else {
      // Keep the current sector until the angle overshoots its border by the
      // hysteresis margin — a thumb wobbling on N/NE never flaps W+D.
      const off = angularDiff(angle, this.#sector * 45);
      if (Math.abs(off) > SECTOR_HALF_DEG + SECTOR_HYST_DEG) {
        this.#sector = ((Math.round(angle / 45) % 8) + 8) % 8;
      }
    }
    this.#applyKeys(SECTOR_KEYS[this.#sector]);
  }

  /** Thumb lifted: release held keys (KEY-up on the wire) and hide. */
  end() {
    this.#applyKeys(null);
    this.#hide();
  }

  /**
   * Local reset around RELEASE_ALL: the server has already released every
   * key, so only clear our ledger and hide — sending KEY-ups here would
   * re-inject state onto a freshly cleaned server.
   */
  reset() {
    this.#held.clear();
    this.#hide();
  }

  #hide() {
    this.#active = false;
    this.#engaged = false;
    this.#sector = -1;
    this.#base.hidden = true;
  }

  /** Diff wanted vs held keys and send only the transitions. */
  #applyKeys(keys) {
    const want = new Set(keys ?? []);
    for (const vk of this.#held) {
      if (!want.has(vk)) {
        this.#sender.key(vk, false);
        this.#held.delete(vk);
      }
    }
    for (const vk of want) {
      if (!this.#held.has(vk)) {
        this.#sender.key(vk, true);
        this.#held.add(vk);
      }
    }
  }
}

/**
 * Signed smallest difference a-b in degrees, in [-180, 180) — an exact ±180°
 * opposition maps to -180. The caller only compares |diff| to a threshold,
 * so which half-open boundary the formula picks is immaterial there.
 */
function angularDiff(a, b) {
  return ((((a - b) % 360) + 540) % 360) - 180;
}
