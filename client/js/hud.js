// HUD: the phone deck's stats line (connection state, RTT, inbound
// bitrate/fps, server encoder stats), its action buttons, the settings sheet,
// and toasts. All elements live in index.html; this module only wires and
// updates them. Layout (deck vs overlay chrome) is styles.css + layout.js;
// here the same controls simply work in both.

import { displayVersion } from './version.js';

const STATE_LABEL = {
  idle: 'offline',
  connecting: 'connecting',
  connected: 'live',
  reconnecting: 'reconnecting',
};

export class Hud {
  #els;
  #settings;
  #toastTimer = null;

  /**
   * @param actions {onDisconnect, onToggleAudio} — connection-level actions
   *   the HUD cannot perform itself.
   */
  constructor({ settings, actions }) {
    this.#settings = settings;
    const $ = (id) => document.getElementById(id);
    this.#els = {
      hud: $('hud'),
      stats: $('hud-stats'),
      state: $('st-state'),
      rtt: $('st-rtt'),
      bitrate: $('st-bitrate'),
      fps: $('st-fps'),
      enc: $('st-enc'),
      audio: $('btn-audio'),
      sheet: $('sheet'),
      toast: $('toast'),
      diag: $('diag'),
    };

    $('btn-settings').addEventListener('click', () => {
      this.#els.sheet.hidden = !this.#els.sheet.hidden;
    });
    $('sheet-close').addEventListener('click', () => {
      this.#els.sheet.hidden = true;
    });
    $('btn-hud').addEventListener('click', () => {
      settings.set('hudVisible', !settings.get('hudVisible'));
    });
    // Compact stats line ⇄ expanded readout panel. Pure presentation state
    // (not persisted): the compact line is always the resting default.
    this.#els.stats.setAttribute('aria-expanded', 'false');
    this.#els.stats.addEventListener('click', () => {
      const expanded = this.#els.hud.classList.toggle('expanded');
      this.#els.stats.setAttribute('aria-expanded', String(expanded));
    });
    $('btn-disconnect').addEventListener('click', () => actions.onDisconnect());
    this.#els.audio.addEventListener('click', () => actions.onToggleAudio());

    this.#bindRange('set-sensitivity', 'cameraSensitivity');
    this.#bindRange('set-joystick', 'joystickScale');

    // World viewport height (design px) — must match the addon's
    // `/wm viewport` value, since the protocol carries no viewport field
    // (TouchLayer splits world/deck from this). Committed on change, clamped
    // to the input's min/max (the addon's own bounds), reverted if not a
    // number.
    const viewport = $('set-viewport');
    viewport.value = String(settings.get('worldViewportPx'));
    viewport.addEventListener('change', () => {
      let v = Math.round(Number(viewport.value));
      if (!Number.isFinite(v)) v = settings.get('worldViewportPx');
      v = Math.min(Number(viewport.max), Math.max(Number(viewport.min), v));
      viewport.value = String(v);
      settings.set('worldViewportPx', v);
    });

    // Stream quality: value in kbps, 0 = Auto (don't touch the server's
    // encoder config). App listens for this setting and sends the ctrl
    // `bitrate` message — the HUD only owns the control.
    const bitrate = $('set-bitrate');
    bitrate.value = String(settings.get('bitrateKbps'));
    if (bitrate.selectedIndex < 0) {
      // Stored value from a removed preset list: snap UI and setting to Auto.
      bitrate.value = '0';
      settings.set('bitrateKbps', 0);
    }
    bitrate.addEventListener('change', () =>
      settings.set('bitrateKbps', Number(bitrate.value)),
    );

    const rail = $('set-rail');
    rail.checked = settings.get('showRail');
    rail.addEventListener('change', () => settings.set('showRail', rail.checked));

    const applyVisibility = () => {
      const visible = settings.get('hudVisible');
      // Collapsed: only meaningful in the overlay layout, where CSS then
      // keeps just the HUD chip so the top edge of the world square (the
      // addon's buff/target tap region, which the floating bar overlaps)
      // stays tappable. In the deck layout chrome covers no game pixels, so
      // the class has no styled effect there and everything stays reachable.
      this.#els.hud.classList.toggle('collapsed', !visible);
    };
    settings.onChange((key) => {
      if (key === 'hudVisible') applyVisibility();
    });
    applyVisibility();
    this.setAudio(settings.get('audio'));
    this.setState('idle');

    // Version of the shell that is ACTUALLY running (server-stamped, rides
    // the service-worker cache) — the stale-cached-client tripwire.
    $('sheet-version').textContent = `WoW Mobile client ${displayVersion()}`;
  }

  #bindRange(id, key) {
    const input = document.getElementById(id);
    const out = document.querySelector(`output[for="${id}"]`);
    const render = (v) => {
      out.textContent = `${Number(v).toFixed(2).replace(/0$/, '')}×`;
    };
    input.value = String(this.#settings.get(key));
    render(input.value);
    input.addEventListener('input', () => {
      const v = Number(input.value);
      this.#settings.set(key, v);
      render(v);
    });
  }

  setState(state) {
    this.#els.state.dataset.state = state;
    this.#els.state.textContent = STATE_LABEL[state] ?? state;
  }

  setRtt(ms) {
    this.#els.rtt.textContent = ms == null ? '– ms' : `${Math.round(ms)} ms`;
  }

  /** Client-side inbound video stats from getStats deltas. */
  setStreamStats({ kbps, fps }) {
    // Mb/s over ~1 Mb/s: the compact deck line has one small row for all
    // stats, and "6.3 Mb/s" reads faster (and narrower) than "6326 kbps".
    this.#els.bitrate.textContent =
      kbps == null
        ? '– kb/s'
        : kbps >= 1000
          ? `${(kbps / 1000).toFixed(1)} Mb/s`
          : `${Math.round(kbps)} kb/s`;
    this.#els.fps.textContent = fps == null ? '– fps' : `${Math.round(fps)} fps`;
  }

  /** Server 1 Hz stats ctrl message. */
  setServerStats({ encodeMs }) {
    this.#els.enc.textContent =
      encodeMs == null ? 'enc –' : `enc ${encodeMs.toFixed(1)} ms`;
  }

  /**
   * Persistent stream-health banner (black-screen diagnosis from app.js's
   * getStats deltas). Pass a plain-language message to show it, null/'' to
   * clear. Unlike toast() it stays until cleared — a codec mismatch does not
   * fix itself in 3.5 s.
   */
  setVideoDiagnostic(message) {
    this.#els.diag.textContent = message || '';
    this.#els.diag.hidden = !message;
  }

  setAudio(on) {
    // The label stays "Snd": an on/off suffix (~42px at 12px/600) clips in
    // the ~35px button share of a 320px-wide deck. State is the accent color
    // (.active) plus title/aria-pressed for hover text and screen readers.
    this.#els.audio.classList.toggle('active', on);
    this.#els.audio.title = on ? 'Sound: on' : 'Sound: off';
    this.#els.audio.setAttribute('aria-pressed', String(on));
  }

  toast(message, ms = 3500) {
    const el = this.#els.toast;
    el.textContent = message;
    el.hidden = false;
    if (this.#toastTimer) clearTimeout(this.#toastTimer);
    this.#toastTimer = setTimeout(() => {
      el.hidden = true;
      this.#toastTimer = null;
    }, ms);
  }
}
