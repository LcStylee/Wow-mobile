// In-app QR scanner for the connect screen: rear-camera preview via
// getUserMedia, decoded with the native BarcodeDetector where the browser has
// one (Android Chrome), else with the vendored jsQR (Apache-2.0,
// client/vendor/jsQR.js) sampling frames through a canvas — the universal
// path, and the only one on iOS Safari, which has no BarcodeDetector.
// jsQR is ~250 KB, so it is loaded lazily, only when scanning actually starts
// AND the native detector is unavailable.
//
// Failure honesty: every unavailability (no camera API, permission denied, no
// camera device, insecure context) resolves to a plain-language message via
// onError so the connect screen can fall back to paste — never a dead button.

const SCAN_INTERVAL_MS = 200; // 5 Hz decode: plenty for a phone aiming at a QR

let jsQRLoad = null; // lazy singleton: the vendored decoder loads at most once

/** Load the vendored jsQR UMD build (defines window.jsQR). */
function loadJsQR() {
  if (window.jsQR) return Promise.resolve(window.jsQR);
  if (!jsQRLoad) {
    jsQRLoad = new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = 'vendor/jsQR.js';
      s.onload = () =>
        window.jsQR ? resolve(window.jsQR) : reject(new Error('jsQR did not initialize'));
      s.onerror = () => {
        jsQRLoad = null; // allow a retry on transient load failure
        reject(new Error('failed to load the QR decoder'));
      };
      document.head.append(s);
    });
  }
  return jsQRLoad;
}

export class QrScanner {
  #video;
  #onResult;
  #onError;
  #stream = null;
  #timer = null;
  #detector = null;
  #jsqr = null;
  #canvas = null;
  #running = false;

  /**
   * @param video    <video> element used for the live camera preview
   * @param onResult called once with the decoded string; the scanner stops
   * @param onError  called with a user-facing message when scanning cannot
   *                 run (permission denied, no camera, …); the scanner stops
   */
  constructor({ video, onResult, onError }) {
    this.#video = video;
    this.#onResult = onResult;
    this.#onError = onError;
  }

  get running() {
    return this.#running;
  }

  async start() {
    if (this.#running) return;
    this.#running = true;
    if (!navigator.mediaDevices?.getUserMedia) {
      this.#fail(
        window.isSecureContext
          ? 'This browser has no camera API — paste the token instead.'
          : 'Camera needs a secure (HTTPS) connection — paste the token instead.',
      );
      return;
    }
    try {
      // Rear camera preferred; plain video constraint as fallback keeps
      // laptops/desktops (single front camera) working for testing.
      this.#stream = await navigator.mediaDevices
        .getUserMedia({ video: { facingMode: { ideal: 'environment' } }, audio: false })
        .catch((err) => {
          if (err.name === 'OverconstrainedError') {
            return navigator.mediaDevices.getUserMedia({ video: true, audio: false });
          }
          throw err;
        });
    } catch (err) {
      this.#fail(cameraErrorMessage(err));
      return;
    }
    if (!this.#running) {
      // stop() raced the permission prompt: release the camera immediately.
      this.#releaseStream();
      return;
    }

    // Decoder: native BarcodeDetector when it really supports QR, else jsQR.
    try {
      if ('BarcodeDetector' in window) {
        const formats = await window.BarcodeDetector.getSupportedFormats?.() ?? [];
        if (formats.includes('qr_code')) {
          this.#detector = new window.BarcodeDetector({ formats: ['qr_code'] });
        }
      }
    } catch {
      this.#detector = null; // detector construction failed: use jsQR
    }
    if (!this.#detector) {
      try {
        this.#jsqr = await loadJsQR();
      } catch (err) {
        this.#fail(`${err.message} — paste the token instead.`);
        return;
      }
    }
    if (!this.#running) {
      this.#releaseStream();
      return;
    }

    this.#video.srcObject = this.#stream;
    try {
      await this.#video.play();
    } catch {
      /* autoplay of a muted camera preview is universally allowed; a failed
         play still leaves scanning working off the stream frames */
    }
    this.#timer = setInterval(() => this.#tick(), SCAN_INTERVAL_MS);
  }

  /** Stop scanning and release the camera. Safe to call repeatedly. */
  stop() {
    this.#running = false;
    if (this.#timer) {
      clearInterval(this.#timer);
      this.#timer = null;
    }
    this.#releaseStream();
    this.#video.srcObject = null;
    this.#detector = null;
  }

  #releaseStream() {
    if (this.#stream) {
      for (const track of this.#stream.getTracks()) track.stop();
      this.#stream = null;
    }
  }

  #fail(message) {
    this.stop();
    this.#onError(message);
  }

  #found(text) {
    if (!this.#running) return;
    this.stop();
    this.#onResult(text);
  }

  async #tick() {
    const v = this.#video;
    if (!this.#running || v.readyState < 2 || !v.videoWidth) return;
    if (this.#detector) {
      try {
        const codes = await this.#detector.detect(v);
        if (codes.length > 0 && codes[0].rawValue) this.#found(codes[0].rawValue);
      } catch {
        // Detector hiccup (e.g. detached frame): fall back to jsQR for good.
        this.#detector = null;
        try {
          this.#jsqr = await loadJsQR();
        } catch {
          this.#fail('QR decoding failed — paste the token instead.');
        }
      }
      return;
    }
    if (!this.#jsqr) return;
    // Canvas path: downscale to keep the per-frame decode cheap on phones.
    const maxDim = 640;
    const scale = Math.min(1, maxDim / Math.max(v.videoWidth, v.videoHeight));
    const w = Math.max(1, Math.round(v.videoWidth * scale));
    const h = Math.max(1, Math.round(v.videoHeight * scale));
    if (!this.#canvas) this.#canvas = document.createElement('canvas');
    const c = this.#canvas;
    if (c.width !== w || c.height !== h) {
      c.width = w;
      c.height = h;
    }
    const ctx = c.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(v, 0, 0, w, h);
    let image;
    try {
      image = ctx.getImageData(0, 0, w, h);
    } catch {
      return; // canvas tainted/blocked this frame; try again next tick
    }
    const code = this.#jsqr(image.data, w, h, { inversionAttempts: 'dontInvert' });
    if (code?.data) this.#found(code.data);
  }
}

/** Map getUserMedia failures to actionable, plain-language messages. */
export function cameraErrorMessage(err) {
  switch (err?.name) {
    case 'NotAllowedError':
    case 'SecurityError':
      return 'Camera permission was denied — allow camera access or paste the token instead.';
    case 'NotFoundError':
    case 'OverconstrainedError':
      return 'No camera found on this device — paste the token instead.';
    case 'NotReadableError':
      return 'The camera is in use by another app — close it or paste the token instead.';
    default:
      return `Camera unavailable (${err?.message ?? err}) — paste the token instead.`;
  }
}

// Well-known QR payload schemes that are definitely NOT a pairing: Wi-Fi
// share cards, contacts/calendars (BEGIN:VCARD / BEGIN:VEVENT parse as a
// "begin:" URL), phone/SMS/mail links, app-store and payment links, TOTP
// enrollments. Scanning one of these must read as "some other QR code" and
// keep the scanner running — never become a bogus bare token.
const NON_PAIRING_SCHEMES = new Set([
  'wifi', 'mailto', 'tel', 'sms', 'smsto', 'mms', 'mmsto', 'facetime',
  'callto', 'sip', 'skype', 'whatsapp', 'geo', 'begin', 'mecard', 'matmsg',
  'vcard', 'market', 'itms', 'itms-apps', 'intent', 'bitcoin', 'ethereum',
  'otpauth', 'upi',
]);

/**
 * Interpret a scanned QR payload: a full pairing URL (…/?token=xyz) yields
 * its token; any other non-empty string is treated as a bare token — except
 * recognizable non-pairing QR payloads (http(s) URLs without a token
 * parameter, and well-known schemes like wifi:/mailto:/tel:), which return
 * null so the scanner keeps scanning instead of destroying a saved pairing
 * with garbage.
 */
export function tokenFromScan(text) {
  const raw = (text ?? '').trim();
  if (!raw) return null;
  try {
    const url = new URL(raw);
    const token = url.searchParams.get('token')?.trim();
    if (token) return token;
    // A URL without a token parameter is some other QR code, not a pairing.
    if (url.protocol === 'http:' || url.protocol === 'https:') return null;
    // Same for the common non-web QR schemes (url.protocol is normalized to
    // lowercase with a trailing colon). Unrecognized schemes still fall
    // through: a bare token containing a colon must keep working.
    if (NON_PAIRING_SCHEMES.has(url.protocol.slice(0, -1))) return null;
  } catch {
    /* not a URL: fall through to bare-token handling */
  }
  // Bare token: tolerate accidental whitespace, reject anything with spaces
  // inside (clearly not a token).
  return /\s/.test(raw) ? null : raw;
}
