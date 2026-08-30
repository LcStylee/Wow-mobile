// App orchestration: pairing, WHEP signaling, the RTCPeerConnection and its
// three data channels, the ctrl protocol (hello / latencyProbe / stats /
// error), reconnect with backoff, wake lock, fullscreen, and lifecycle
// safety (RELEASE_ALL on hide/leave — a pocketed phone must never leave W held).

import { AuthError, createSession, deleteSession, sendOffer } from './signaling.js';
import { PROTO_VERSION } from './protocol.js';
import { InputSender } from './net.js';
import { Settings } from './settings.js';
import { Joystick } from './joystick.js';
import { TouchLayer } from './input.js';
import { QuickRail } from './quickbar.js';
import { ChatKeyboard } from './keyboard.js';
import { Hud } from './hud.js';

const TOKEN_KEY = 'wowmobile.token';
const CLIENT_ID = 'wowmobile-pwa/1.0';
const PROBE_INTERVAL_MS = 2000;
const STATS_INTERVAL_MS = 1000;
const ICE_GATHER_TIMEOUT_MS = 2500; // LAN host candidates arrive well within this
const DISCONNECT_GRACE_MS = 3500; // let a Wi-Fi blip recover before reconnecting
const BACKOFF_MS = [1000, 2000, 4000, 8000, 15000];

class App {
  #settings = new Settings();
  #sender = new InputSender();
  #hud;
  #joystick;
  #touch;
  #rail;
  #keyboard;
  #video = document.getElementById('video');

  // Connection state. #wanted gates every async continuation: it is true
  // from start() until an explicit stop, so a late promise resolution after
  // disconnect can never resurrect a torn-down session.
  #wanted = false;
  #token = null;
  #session = null;
  #pc = null;
  #ctrl = null; // current session's ctrl channel (bitrate requests ride it)
  #stream = null;
  #started = false; // user gesture consumed (autoplay unlocked)
  #fatalError = false; // e.g. replaced by another phone: do not reconnect

  #probeTimer = null;
  #statsTimer = null;
  // Stream-health counters (seconds, from the 1 Hz stats loop): consecutive
  // intervals with video bytes flowing but zero decoded frames (codec
  // mismatch class), and with zero bytes at all (capture-dead class).
  #stalledDecodeSecs = 0;
  #noDataSecs = 0;
  #reconnectTimer = null;
  #disconnectGraceTimer = null;
  #backoffIndex = 0;
  #probeId = 0;
  #lastStats = null;
  #wakeLock = null;
  #wakeLockRequest = null; // in-flight wakeLock.request; concurrent acquires share it

  constructor() {
    this.#hud = new Hud({
      settings: this.#settings,
      actions: {
        // No message: a user-initiated End is not an error, and the connect
        // screen's note element renders in the danger style.
        onDisconnect: () => this.stop(),
        onToggleAudio: () => this.#toggleAudio(),
      },
    });
    const touchEl = document.getElementById('touch');
    this.#joystick = new Joystick({
      container: touchEl,
      sender: this.#sender,
      settings: this.#settings,
    });
    this.#touch = new TouchLayer({
      element: touchEl,
      video: this.#video,
      sender: this.#sender,
      settings: this.#settings,
      joystick: this.#joystick,
    });
    this.#keyboard = new ChatKeyboard({
      element: document.getElementById('kb'),
      sender: this.#sender,
      onUnavailable: (msg) => this.#hud.toast(msg),
    });
    this.#rail = new QuickRail({
      element: document.getElementById('rail'),
      sender: this.#sender,
      settings: this.#settings,
      onOpenKeyboard: () => this.#keyboard.open(),
    });

    // Quality changes apply live; App owns the ctrl channel, the HUD only
    // owns the select control that writes the setting.
    this.#settings.onChange((key) => {
      if (key === 'bitrateKbps') this.#sendBitrate();
    });

    this.#wireLifecycle();
    this.#wireConnectScreen();
    this.#wireStartOverlay();
  }

  // ---- boot ---------------------------------------------------------------

  boot() {
    // Token priority: URL (fresh pairing) > localStorage (return visit).
    // The URL copy is scrubbed so screenshots/history don't leak it.
    const url = new URL(location.href);
    const fromUrl = url.searchParams.get('token')?.trim();
    if (fromUrl) {
      url.searchParams.delete('token');
      history.replaceState(null, '', url);
      this.#persistToken(fromUrl);
    }
    // With site data blocked (Chrome setting, some embedded webviews) the
    // localStorage accessor itself throws SecurityError — guard the read like
    // Settings/#persistToken guard theirs, or boot dies before the connect
    // screen ever shows and the app is a dead black page.
    let saved = null;
    try {
      saved = localStorage.getItem(TOKEN_KEY);
    } catch {
      // Storage blocked: pairing still works via URL token or manual entry.
    }
    const token = fromUrl ?? saved;
    // Return visits with a stored token also rebind the manifest, so a later
    // Add to Home Screen still captures the self-pairing launch URL
    // (#persistToken already bound it on the fresh-pairing path).
    if (token && !fromUrl) this.#bindManifestToToken(token);
    if (token) this.start(token);
    else this.#showConnectScreen();
  }

  start(token) {
    // Re-entrancy guard: a double-tap on Connect can dispatch two submit
    // events before the overlay hides. A second concurrent #connect() would
    // overwrite #pc/#session and abandon the first RTCPeerConnection without
    // closing it. #wanted is true exactly while an attempt/session is live,
    // and every path back to the connect screen clears it first — so "already
    // wanted" can only mean a duplicate submit: drop it.
    if (this.#wanted) return;
    this.#token = token;
    this.#wanted = true;
    this.#fatalError = false;
    this.#backoffIndex = 0;
    document.getElementById('overlay-connect').hidden = true;
    this.#connect().catch((err) => this.#onConnectFailure(err));
  }

  /**
   * User-intended teardown: RELEASE_ALL, DELETE the session, connect screen.
   * `message` (optional) is shown in the connect screen's error note — omit it
   * for normal, user-initiated stops.
   */
  stop(message) {
    this.#wanted = false;
    this.#teardown({ deleteSession: true });
    this.#hud.setState('idle');
    this.#showConnectScreen(message);
  }

  // ---- connection ---------------------------------------------------------

  async #connect() {
    this.#hud.setState('connecting');
    this.#hud.setRtt(null);
    this.#hud.setStreamStats({});

    const session = await createSession(this.#token);
    if (!this.#wanted) {
      // The user ended the attempt (or a fatal ran) while the POST was in
      // flight, so #teardown already ran with #session still null — delete
      // the session we just created or it would linger server-side until the
      // dead-man/replace rules collect it.
      deleteSession(session);
      return;
    }
    this.#session = session;

    // No STUN/TURN: phone and PC share a LAN, host candidates suffice.
    const pc = new RTCPeerConnection();
    this.#pc = pc;
    this.#stream = new MediaStream();

    // Channels must exist before createOffer so they negotiate in-band.
    // Labels and options are exact per PROTOCOL.md.
    const input = pc.createDataChannel('input', { ordered: true });
    const move = pc.createDataChannel('move', { ordered: false, maxRetransmits: 0 });
    const ctrl = pc.createDataChannel('ctrl', { ordered: true });
    this.#sender.attach(input, move);
    this.#ctrl = ctrl;

    pc.addTransceiver('video', { direction: 'recvonly' });
    pc.addTransceiver('audio', { direction: 'recvonly' });

    pc.ontrack = (ev) => this.#onTrack(ev);
    pc.onconnectionstatechange = () => this.#onConnectionState(pc);
    const onChannelClose = () => {
      if (this.#pc === pc) this.#scheduleReconnect('data channel closed');
    };
    // All three channels: a move-only close would silently degrade camera
    // motion with no reconnect if it went unhandled.
    input.onclose = onChannelClose;
    move.onclose = onChannelClose;
    ctrl.onclose = onChannelClose;
    ctrl.onopen = () => {
      // First ctrl message must be our hello.
      ctrl.send(JSON.stringify({ t: 'hello', proto: PROTO_VERSION, client: CLIENT_ID }));
    };
    ctrl.onmessage = (ev) => this.#onCtrlMessage(ctrl, ev.data);

    await pc.setLocalDescription(await pc.createOffer());
    await waitIceGatheringComplete(pc, ICE_GATHER_TIMEOUT_MS);
    if (this.#pc !== pc) return; // torn down while gathering

    const answerSdp = await sendOffer(session, pc.localDescription.sdp);
    if (this.#pc !== pc) return;
    await pc.setRemoteDescription({ type: 'answer', sdp: answerSdp });
  }

  #onConnectFailure(err) {
    if (!this.#wanted) return;
    if (err instanceof AuthError) {
      this.#wanted = false;
      this.#teardown({ deleteSession: false });
      this.#hud.setState('idle');
      this.#showConnectScreen('Pairing token rejected — check the token on your PC.');
      return;
    }
    this.#scheduleReconnect(err.message);
  }

  #onTrack(ev) {
    if (!this.#stream) return; // track event raced a teardown
    this.#stream.addTrack(ev.track);
    if (this.#video.srcObject !== this.#stream) this.#video.srcObject = this.#stream;
    // Latency knobs: both are hints, availability varies per browser.
    try {
      ev.receiver.playoutDelayHint = 0;
    } catch { /* unsupported */ }
    try {
      ev.receiver.jitterBufferTarget = 0;
    } catch { /* unsupported */ }
    if (this.#started) this.#video.play().catch(() => {});
  }

  #onConnectionState(pc) {
    if (this.#pc !== pc) return;
    switch (pc.connectionState) {
      case 'failed':
        this.#scheduleReconnect('connection failed');
        break;
      case 'disconnected':
        // ICE may recover on its own; only reconnect if it doesn't.
        if (!this.#disconnectGraceTimer) {
          this.#disconnectGraceTimer = setTimeout(() => {
            this.#disconnectGraceTimer = null;
            if (this.#pc === pc && pc.connectionState === 'disconnected') {
              this.#scheduleReconnect('connection lost');
            }
          }, DISCONNECT_GRACE_MS);
        }
        break;
      case 'connected':
        if (this.#disconnectGraceTimer) {
          clearTimeout(this.#disconnectGraceTimer);
          this.#disconnectGraceTimer = null;
        }
        break;
      default:
        break;
    }
  }

  // ---- ctrl protocol ------------------------------------------------------

  #onCtrlMessage(ctrl, data) {
    let msg;
    try {
      msg = JSON.parse(data);
    } catch {
      return; // not ours to crash on; server errors close the connection
    }
    switch (msg.t) {
      case 'hello': {
        if (msg.proto?.[0] > PROTO_VERSION[0]) {
          // Higher major than we speak: disconnect per PROTOCOL.md.
          this.#fatal(`Server protocol v${msg.proto[0]} is newer than this client.`);
          return;
        }
        if (msg.video) this.#touch.setVideoGeometry(msg.video);
        this.#backoffIndex = 0; // healthy session: future failures back off from 1 s
        this.#hud.setState('connected');
        // Re-apply the quality choice after every hello so it survives
        // reconnects and server restarts (the encoder starts from its own
        // config on each new session).
        this.#sendBitrate();
        this.#startProbes(ctrl);
        this.#startStatsLoop();
        if (!this.#started) document.getElementById('overlay-start').hidden = false;
        break;
      }
      case 'latencyProbe':
        this.#hud.setRtt(performance.now() - msg.tSent);
        break;
      case 'stats':
        this.#hud.setServerStats(msg);
        break;
      case 'error':
        if (msg.code === 'replaced') {
          // Another phone paired; yielding is correct, retrying is a fight.
          this.#fatal('Session replaced by another device.');
        } else {
          this.#hud.toast(`Server error: ${msg.msg ?? msg.code}`);
          // Fatal per spec — the server closes; reconnect kicks in from the
          // resulting channel/connection close events.
        }
        break;
      default:
        break; // unknown ctrl types are ignorable (JSON is self-framing)
    }
  }

  #startProbes(ctrl) {
    clearInterval(this.#probeTimer);
    this.#probeTimer = setInterval(() => {
      if (ctrl.readyState !== 'open') return;
      this.#probeId = (this.#probeId + 1) % 0x7fffffff;
      ctrl.send(
        JSON.stringify({ t: 'latencyProbe', id: this.#probeId, tSent: performance.now() }),
      );
    }, PROBE_INTERVAL_MS);
  }

  /**
   * Request the user's chosen encoder bitrate (ctrl `bitrate`, PROTOCOL.md).
   * 0 means Auto: keep the server's configured bitrate and send nothing.
   * v1 has no "reset to default" message, so switching back to Auto mid-
   * session leaves the last explicit request active until the next session.
   */
  #sendBitrate() {
    const kbps = this.#settings.get('bitrateKbps');
    if (kbps === 0) return;
    const ctrl = this.#ctrl;
    if (ctrl?.readyState !== 'open') return; // re-sent from the next hello
    ctrl.send(JSON.stringify({ t: 'bitrate', kbps }));
  }

  #startStatsLoop() {
    clearInterval(this.#statsTimer);
    this.#lastStats = null;
    this.#stalledDecodeSecs = 0;
    this.#noDataSecs = 0;
    this.#statsTimer = setInterval(async () => {
      const pc = this.#pc;
      if (!pc || pc.connectionState !== 'connected') return;
      let report;
      try {
        report = await pc.getStats();
      } catch {
        return;
      }
      if (this.#pc !== pc) return;
      for (const stat of report.values()) {
        if (stat.type !== 'inbound-rtp' || stat.kind !== 'video') continue;
        const prev = this.#lastStats;
        if (prev && stat.timestamp > prev.timestamp) {
          const dtSec = (stat.timestamp - prev.timestamp) / 1000;
          const bytesDelta = stat.bytesReceived - prev.bytesReceived;
          const framesDelta = stat.framesDecoded - prev.framesDecoded;
          this.#hud.setStreamStats({
            kbps: (bytesDelta * 8) / dtSec / 1000,
            fps: framesDelta / dtSec,
          });
          this.#updateVideoDiagnostic(bytesDelta, framesDelta);
        }
        this.#lastStats = {
          timestamp: stat.timestamp,
          bytesReceived: stat.bytesReceived,
          framesDecoded: stat.framesDecoded,
        };
        break;
      }
    }, STATS_INTERVAL_MS);
  }

  /**
   * Black-screen triage from getStats deltas, in plain language. Bytes
   * flowing while decoded frames stay 0 for >3 s means the phone cannot
   * decode what it receives (codec/profile mismatch); no bytes at all for
   * >3 s means nothing is being captured/sent. A single decoded frame clears
   * the banner. Thresholds are in whole 1 Hz stats intervals.
   */
  #updateVideoDiagnostic(bytesDelta, framesDelta) {
    if (framesDelta > 0) {
      this.#stalledDecodeSecs = 0;
      this.#noDataSecs = 0;
      this.#hud.setVideoDiagnostic(null);
      return;
    }
    if (bytesDelta > 0) {
      this.#stalledDecodeSecs += 1;
      this.#noDataSecs = 0;
    } else {
      this.#noDataSecs += 1;
      this.#stalledDecodeSecs = 0;
    }
    if (this.#stalledDecodeSecs > 3) {
      this.#hud.setVideoDiagnostic(
        "Receiving video data but your phone can't decode it — codec mismatch; update the PC app.",
      );
    } else if (this.#noDataSecs > 3) {
      this.#hud.setVideoDiagnostic(
        'No video data arriving — check the PC app: is the WoW window visible and capture running?',
      );
    }
  }

  // ---- teardown / reconnect ----------------------------------------------

  /** Fatal: tear down and surface the reason; no reconnect. */
  #fatal(message) {
    this.#fatalError = true;
    this.#wanted = false;
    this.#teardown({ deleteSession: true });
    this.#hud.setState('idle');
    this.#showConnectScreen(message);
  }

  #teardown({ deleteSession: doDelete }) {
    clearInterval(this.#probeTimer);
    clearInterval(this.#statsTimer);
    clearTimeout(this.#reconnectTimer);
    clearTimeout(this.#disconnectGraceTimer);
    this.#probeTimer = this.#statsTimer = null;
    this.#reconnectTimer = this.#disconnectGraceTimer = null;

    // Order matters: RELEASE_ALL while the input channel may still be open,
    // then silence the local gesture/rail layers, then close.
    this.#sender.releaseAll();
    this.#touch.reset();
    this.#rail.reset();
    this.#sender.detach();

    this.#ctrl = null;
    if (this.#pc) {
      const pc = this.#pc;
      this.#pc = null;
      pc.ontrack = null;
      pc.onconnectionstatechange = null;
      pc.close();
    }

    // #wanted is false here exactly on stop()/#fatal() teardowns: release the
    // wake lock — it only auto-releases on page hide, which never happens
    // while we hold the screen on, so an idle connect screen would otherwise
    // burn the battery forever. Reconnect teardowns (#wanted still true) keep
    // it, or the screen could dim mid-backoff.
    if (!this.#wanted) this.#releaseWakeLock();
    this.#video.srcObject = null;
    this.#stream = null;
    this.#lastStats = null;
    this.#stalledDecodeSecs = 0;
    this.#noDataSecs = 0;
    this.#hud.setRtt(null);
    this.#hud.setStreamStats({});
    this.#hud.setVideoDiagnostic(null);

    if (doDelete && this.#session) deleteSession(this.#session);
    this.#session = null;
  }

  #scheduleReconnect(reason) {
    if (!this.#wanted || this.#fatalError || this.#reconnectTimer) return;
    this.#teardown({ deleteSession: true });
    this.#hud.setState('reconnecting');
    this.#hud.toast(`Reconnecting: ${reason}`);
    const base = BACKOFF_MS[Math.min(this.#backoffIndex, BACKOFF_MS.length - 1)];
    this.#backoffIndex += 1;
    const delay = base * (0.85 + Math.random() * 0.3); // jitter avoids thundering herd
    this.#reconnectTimer = setTimeout(() => {
      this.#reconnectTimer = null;
      if (!this.#wanted) return;
      this.#connect().catch((err) => this.#onConnectFailure(err));
    }, delay);
  }

  // ---- lifecycle safety ---------------------------------------------------

  #wireLifecycle() {
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') {
        // Backgrounded: drop every held key/button NOW (safety over latency).
        this.#sender.releaseAll();
        this.#touch.reset();
        this.#rail.reset();
      } else {
        if (this.#wanted) this.#acquireWakeLock();
        if (this.#started) this.#video.play().catch(() => {});
      }
    });

    window.addEventListener('pagehide', (e) => {
      this.#sender.releaseAll();
      this.#touch.reset();
      this.#rail.reset();
      if (this.#session && !e.persisted) {
        // Real navigation away: best-effort teardown that survives unload.
        deleteSession(this.#session, { keepalive: true });
        this.#session = null;
      }
    });

    window.addEventListener('pageshow', (e) => {
      // Restored from bfcache after we tore the session down: reconnect.
      if (e.persisted && this.#wanted && !this.#session) {
        this.#scheduleReconnect('page restored');
      }
    });

    // The stream is the page; there is never text to select or zoom.
    document.addEventListener('contextmenu', (e) => e.preventDefault());
  }

  #acquireWakeLock() {
    if (this.#wakeLock || !navigator.wakeLock) return Promise.resolve();
    // Single-flight: visibilitychange and the start overlay can both call
    // this before the first request resolves; two resolved locks would
    // orphan the overwritten sentinel, which could then never be released.
    if (!this.#wakeLockRequest) {
      this.#wakeLockRequest = navigator.wakeLock
        .request('screen')
        .then((lock) => {
          if (!this.#wanted) {
            // The user ended the session while the request was in flight —
            // keeping the lock would pin the connect screen awake.
            lock.release().catch(() => {});
            return;
          }
          this.#wakeLock = lock;
          lock.addEventListener('release', () => {
            if (this.#wakeLock === lock) this.#wakeLock = null;
          });
        })
        .catch(() => {
          // Denied (low battery etc.) — the stream still works, screen may dim.
        })
        .finally(() => {
          this.#wakeLockRequest = null;
        });
    }
    return this.#wakeLockRequest;
  }

  #releaseWakeLock() {
    this.#wakeLock?.release().catch(() => {});
    this.#wakeLock = null; // the sentinel's release event is identity-guarded
  }

  // ---- UI: connect screen & start overlay ---------------------------------

  #wireConnectScreen() {
    const form = document.getElementById('connect-form');
    const input = document.getElementById('connect-token');
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const token = input.value.trim();
      if (!token) return;
      // Belt to start()'s braces: no further submits while an attempt is
      // pending. Re-enabled whenever the connect screen is shown again.
      document.getElementById('connect-submit').disabled = true;
      this.#persistToken(token);
      this.start(token);
    });
    // Big PASTE affordance: the 32-char token is miserable to type on glass.
    // clipboard.readText needs a secure context + permission; every failure
    // path degrades to focusing the field so the OS paste menu works.
    document.getElementById('connect-paste').addEventListener('click', async () => {
      try {
        const text = (await navigator.clipboard.readText()).trim();
        if (text) {
          input.value = text;
          input.focus();
          return;
        }
      } catch {
        // Unsupported or denied — fall through to the manual hint.
      }
      input.focus();
      this.#hud.toast('Clipboard unavailable — long-press the field and Paste.');
    });
  }

  #persistToken(token) {
    try {
      localStorage.setItem(TOKEN_KEY, token);
    } catch {
      // Private mode: pairing works for this visit only.
    }
    this.#bindManifestToToken(token);
  }

  /**
   * Point the manifest link at the token-bound variant. The server, seeing a
   * matching ?token, serves the manifest with start_url "/?token=<token>"
   * (no-store), so Add to Home Screen captures a launch URL that self-pairs —
   * installed PWAs (iOS especially) run in their own storage partition where
   * the localStorage token saved in the browser does not exist, which is why
   * the home-screen app used to open on the token entry screen.
   */
  #bindManifestToToken(token) {
    const link = document.querySelector('link[rel="manifest"]');
    if (link && token) {
      link.href = `manifest.webmanifest?token=${encodeURIComponent(token)}`;
    }
  }

  #showConnectScreen(message) {
    const overlay = document.getElementById('overlay-connect');
    overlay.hidden = false;
    document.getElementById('connect-submit').disabled = false;
    document.getElementById('overlay-start').hidden = true;
    const note = document.getElementById('connect-note');
    note.textContent = message ?? '';
    note.hidden = !message;
    const input = document.getElementById('connect-token');
    if (this.#token) input.value = this.#token;
  }

  #wireStartOverlay() {
    const overlay = document.getElementById('overlay-start');
    overlay.addEventListener('click', async () => {
      overlay.hidden = true;
      this.#started = true;
      this.#video.muted = !this.#settings.get('audio');
      this.#video.play().catch(() => {});
      // Fullscreen must precede orientation lock (Android requirement);
      // iOS Safari supports neither on <html> — both fail soft.
      try {
        await document.documentElement.requestFullscreen({ navigationUI: 'hide' });
        await screen.orientation?.lock?.('portrait');
      } catch { /* not supported here */ }
      this.#acquireWakeLock();
    });
  }

  #toggleAudio() {
    const on = !this.#settings.get('audio');
    this.#settings.set('audio', on);
    this.#video.muted = !on;
    this.#hud.setAudio(on);
    if (on && this.#started) this.#video.play().catch(() => {});
  }
}

/**
 * WHEP signaling is non-trickle: wait for gathering to complete so the offer
 * carries every candidate. The timeout keeps a broken mDNS/interface from
 * hanging pairing — whatever gathered by then is sent.
 */
function waitIceGatheringComplete(pc, timeoutMs) {
  if (pc.iceGatheringState === 'complete') return Promise.resolve();
  return new Promise((resolve) => {
    const done = () => {
      clearTimeout(timer);
      pc.removeEventListener('icegatheringstatechange', check);
      resolve();
    };
    const check = () => {
      if (pc.iceGatheringState === 'complete') done();
    };
    const timer = setTimeout(done, timeoutMs);
    pc.addEventListener('icegatheringstatechange', check);
  });
}

const app = new App();
app.boot();

// Install/offline shell only; never touches /api/ (see sw.js).
if ('serviceWorker' in navigator && window.isSecureContext) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').catch(() => {});
  });
}
