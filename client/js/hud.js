// HUD: the thin stats strip (connection state, RTT, inbound bitrate/fps,
// server encoder stats), its action buttons, the settings sheet, and toasts.
// All elements live in index.html; this module only wires and updates them.

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
      this.#els.stats.hidden = !visible;
      // Collapsed: only the HUD chip remains, so the top edge of the world
      // square (the addon's buff/target tap region, which the strip overlaps
      // on exact 9:16 screens) stays tappable.
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
    this.#els.bitrate.textContent = kbps == null ? '– kbps' : `${Math.round(kbps)} kbps`;
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
    this.#els.audio.textContent = on ? 'Snd on' : 'Snd off';
    this.#els.audio.classList.toggle('active', on);
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
