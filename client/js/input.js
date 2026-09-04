// TouchLayer: converts raw pointer events over the video into wire input per
// the ARCHITECTURE.md gesture table. Every concurrent finger is tracked by
// pointerId so the joystick and a camera drag work simultaneously.
//
// Regions (computed from the letterboxed content rect):
//   world square  — top captureW x (worldViewportPx/1080 · captureW) of the
//                   frame; exactly square at the default 1080 viewport
//     bottom-left corner        → virtual joystick (WASD, handled by Joystick)
//     one-finger drag elsewhere → RMB-down + proportional moves + RMB-up
//     tap                       → LMB click at position
//     long-press (still)        → RMB click at position
//     two-finger pinch          → WHEEL (zoom)
//   control deck  — below the square: plain tap / long-press passthrough
//   letterbox bars — ignored entirely

import { BUTTON, BUTTONS_BIT, WHEEL_NOTCH, norm16 } from './protocol.js';
import { clamp, fitContain, worldSquareFrac } from './geometry.js';

const TAP_SLOP_PX = 12; // CSS px of travel that still counts as a tap
const LONG_PRESS_MS = 450;
const PINCH_STEP_PX = 30; // finger-distance change per one wheel detent
// Joystick zone: bottom-left corner of the world square, as fractions of the
// square's side. Generous on purpose — a miss means the character stops.
const JOY_ZONE_FRAC = 0.45;

export class TouchLayer {
  #el;
  #video;
  #sender;
  #settings;
  #joystick;
  #capture = null; // {w,h} from the server hello (pre-first-frame fallback)
  #geom = null; // cached mapping; invalidated on any layout change
  #pointers = new Map(); // pointerId -> gesture record
  #pinch = null; // {ids:[a,b], refDist}

  constructor({ element, video, sender, settings, joystick }) {
    this.#el = element;
    this.#video = video;
    this.#sender = sender;
    this.#settings = settings;
    this.#joystick = joystick;

    element.addEventListener('pointerdown', (e) => this.#onDown(e));
    element.addEventListener('pointermove', (e) => this.#onMove(e));
    element.addEventListener('pointerup', (e) => this.#onUp(e, false));
    element.addEventListener('pointercancel', (e) => this.#onUp(e, true));

    const invalidate = () => {
      this.#geom = null;
    };
    window.addEventListener('resize', invalidate);
    // Fires when videoWidth/videoHeight change (stream (re)negotiation).
    video.addEventListener('resize', invalidate);
    screen.orientation?.addEventListener?.('change', invalidate);
    // layout.js announces deck⇄overlay flips that move the #video/#touch
    // boxes without a resize event (e.g. the focusout-held re-evaluation).
    window.addEventListener('wm-layout-change', invalidate);
    // The world/deck split depends on the configured viewport height
    // (mirrors the addon's /wm viewport — see #geometry); re-split live when
    // the user changes it in the settings sheet.
    settings.onChange((key) => {
      if (key === 'worldViewportPx') invalidate();
    });
  }

  /** Store the capture geometry from the server hello. */
  setVideoGeometry({ w, h }) {
    this.#capture = { w, h };
    this.#geom = null;
  }

  /**
   * Drop all in-flight gestures WITHOUT emitting wire events. Called around
   * RELEASE_ALL (visibility loss, reconnect): the server state is already
   * clean, so sending ups here would desync it.
   */
  reset() {
    for (const rec of this.#pointers.values()) {
      if (rec.timer) clearTimeout(rec.timer);
    }
    this.#pointers.clear();
    this.#pinch = null;
    this.#joystick.reset();
  }

  // ---- geometry -----------------------------------------------------------

  #geometry() {
    if (this.#geom) return this.#geom;
    // The element's intrinsic dimensions win once frames decode: a capture
    // self-heal restart can adopt a NEW client rect mid-session without a new
    // hello, and only videoWidth/Height track it (the video 'resize' listener
    // invalidates this cache when they change). The hello snapshot bridges
    // just the pre-first-frame window, when the intrinsics still read 0.
    const vw = this.#video.videoWidth || this.#capture?.w;
    const vh = this.#video.videoHeight || this.#capture?.h;
    if (!vw || !vh) return null; // no frame yet — nothing to map onto
    // The layer is positioned exactly over the video element, so its own box
    // is the video box.
    const box = this.#el.getBoundingClientRect();
    if (box.width === 0 || box.height === 0) return null;
    const content = fitContain(box.width, box.height, vw, vh);
    this.#geom = {
      left: box.left,
      top: box.top,
      content,
      // The addon's viewport height has no protocol field; the user-synced
      // worldViewportPx setting (default 1080 = square) supplies it so the
      // world/deck boundary matches the addon's actual layout.
      worldFrac: worldSquareFrac(vw, vh, this.#settings.get('worldViewportPx')),
      squareSidePx: content.w, // square side on screen = content width
    };
    return this.#geom;
  }

  /**
   * Screen point -> capture fractions {fx, fy} in 0..1, or null when the
   * point lies in a letterbox bar (those touches are ignored).
   */
  #mapPoint(clientX, clientY) {
    const g = this.#geometry();
    if (!g) return null;
    const x = clientX - g.left - g.content.x;
    const y = clientY - g.top - g.content.y;
    if (x < 0 || y < 0 || x > g.content.w || y > g.content.h) return null;
    return { fx: x / g.content.w, fy: y / g.content.h };
  }

  #wire(frac) {
    return { x: norm16(frac.fx), y: norm16(frac.fy) };
  }

  // ---- pointerdown --------------------------------------------------------

  #onDown(e) {
    // Desktop debugging aid: secondary mouse buttons are not gestures.
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    const g = this.#geometry();
    const frac = this.#mapPoint(e.clientX, e.clientY);
    if (!g || !frac) return; // letterbox or no video yet
    this.#el.setPointerCapture(e.pointerId);

    const inWorld = frac.fy <= g.worldFrac;
    if (inWorld && !this.#joystick.active && this.#inJoystickZone(frac, g)) {
      this.#pointers.set(e.pointerId, { kind: 'joystick' });
      this.#joystick.begin(e.clientX, e.clientY, g.squareSidePx);
      return;
    }

    if (inWorld) {
      // A second world finger while one is pending/dragging forms a pinch.
      const partner = this.#findPinchPartner();
      if (partner !== null) {
        this.#beginPinch(partner, e);
        return;
      }
    }

    const rec = {
      kind: 'pending',
      inWorld,
      start: { x: e.clientX, y: e.clientY },
      startFrac: frac,
      client: { x: e.clientX, y: e.clientY },
      geom: g, // frozen for the gesture so a mid-drag relayout can't warp it
      timer: setTimeout(() => this.#longPress(e.pointerId), LONG_PRESS_MS),
    };
    this.#pointers.set(e.pointerId, rec);
  }

  #inJoystickZone(frac, g) {
    // Square-local coordinates 0..1.
    const sx = frac.fx;
    const sy = frac.fy / g.worldFrac;
    return sx <= JOY_ZONE_FRAC && sy >= 1 - JOY_ZONE_FRAC;
  }

  #findPinchPartner() {
    for (const [id, rec] of this.#pointers) {
      if ((rec.kind === 'pending' && rec.inWorld) || rec.kind === 'camera') return id;
    }
    return null;
  }

  // ---- long-press ---------------------------------------------------------

  #longPress(pointerId) {
    const rec = this.#pointers.get(pointerId);
    if (!rec || rec.kind !== 'pending') return;
    rec.timer = null;
    rec.kind = 'consumed'; // the rest of this touch does nothing
    this.#click(BUTTON.RIGHT, rec.startFrac);
  }

  /** Reliable move (position guarantee) + down + up: one clean click. */
  #click(button, frac) {
    const { x, y } = this.#wire(frac);
    this.#sender.movePrecise(0, x, y);
    this.#sender.pointerDown(button, x, y);
    this.#sender.pointerUp(button, x, y);
  }

  // ---- pointermove --------------------------------------------------------

  #onMove(e) {
    const rec = this.#pointers.get(e.pointerId);
    if (!rec) return;
    rec.client = { x: e.clientX, y: e.clientY };
    switch (rec.kind) {
      case 'joystick':
        this.#joystick.move(e.clientX, e.clientY);
        break;
      case 'pending': {
        const travel = Math.hypot(e.clientX - rec.start.x, e.clientY - rec.start.y);
        if (travel <= TAP_SLOP_PX) break;
        clearTimeout(rec.timer);
        rec.timer = null;
        if (rec.inWorld) {
          this.#becomeCamera(rec);
          this.#cameraMove(rec);
        } else {
          // Deck drags are neither taps nor camera: swallow the touch.
          rec.kind = 'consumed';
        }
        break;
      }
      case 'camera':
        this.#cameraMove(rec);
        break;
      case 'pinch':
        this.#pinchMove();
        break;
      default: // consumed
        break;
    }
  }

  // ---- camera drag --------------------------------------------------------

  #becomeCamera(rec) {
    rec.kind = 'camera';
    rec.virtualFrac = { ...rec.startFrac };
    const { x, y } = this.#wire(rec.startFrac);
    this.#sender.movePrecise(0, x, y);
    this.#sender.pointerDown(BUTTON.RIGHT, x, y);
  }

  #cameraMove(rec) {
    const sens = this.#settings.get('cameraSensitivity');
    const g = rec.geom;
    // Proportional: the injected pointer travels sensitivity x the thumb's
    // travel (in capture fractions), anchored at the gesture start, clamped
    // to the world square so the drag never wanders into the control deck.
    const fx = clamp(
      rec.startFrac.fx + ((rec.client.x - rec.start.x) / g.content.w) * sens,
      0,
      1,
    );
    const fy = clamp(
      rec.startFrac.fy + ((rec.client.y - rec.start.y) / g.content.h) * sens,
      0,
      g.worldFrac,
    );
    rec.virtualFrac = { fx, fy };
    this.#sender.moveLossy(BUTTONS_BIT.RIGHT, norm16(fx), norm16(fy));
  }

  #endCamera(rec) {
    const { x, y } = this.#wire(rec.virtualFrac);
    this.#sender.movePrecise(BUTTONS_BIT.RIGHT, x, y);
    this.#sender.pointerUp(BUTTON.RIGHT, x, y);
  }

  // ---- pinch zoom ---------------------------------------------------------

  #beginPinch(partnerId, e) {
    const partner = this.#pointers.get(partnerId);
    if (partner.kind === 'camera') {
      this.#endCamera(partner); // hand the RMB back before zooming
    } else {
      clearTimeout(partner.timer);
      partner.timer = null;
    }
    partner.kind = 'pinch';
    const rec = {
      kind: 'pinch',
      client: { x: e.clientX, y: e.clientY },
    };
    this.#pointers.set(e.pointerId, rec);
    this.#pinch = {
      ids: [partnerId, e.pointerId],
      refDist: dist(partner.client, rec.client),
    };
  }

  #pinchMove() {
    const p = this.#pinch;
    if (!p) return;
    const a = this.#pointers.get(p.ids[0]);
    const b = this.#pointers.get(p.ids[1]);
    if (!a || !b) return;
    const d = dist(a.client, b.client);
    // Whole detents only; the remainder stays banked in refDist so slow
    // pinches still accumulate into zoom steps.
    const steps = Math.trunc((d - p.refDist) / PINCH_STEP_PX);
    if (steps === 0) return;
    p.refDist += steps * PINCH_STEP_PX;
    const g = this.#geometry();
    const midFrac = this.#mapPoint(
      (a.client.x + b.client.x) / 2,
      (a.client.y + b.client.y) / 2,
    );
    if (!g || !midFrac) return;
    midFrac.fy = clamp(midFrac.fy, 0, g.worldFrac);
    const { x, y } = this.#wire(midFrac);
    // Spread (distance grows) = zoom in = scroll up = positive delta.
    this.#sender.wheel(x, y, steps * WHEEL_NOTCH);
  }

  #endPinch() {
    if (!this.#pinch) return;
    for (const id of this.#pinch.ids) {
      const rec = this.#pointers.get(id);
      if (rec) rec.kind = 'consumed'; // the surviving finger goes inert
    }
    this.#pinch = null;
  }

  // ---- pointerup / pointercancel ------------------------------------------

  #onUp(e, cancelled) {
    const rec = this.#pointers.get(e.pointerId);
    if (!rec) return;
    this.#pointers.delete(e.pointerId);
    if (rec.timer) clearTimeout(rec.timer);
    switch (rec.kind) {
      case 'joystick':
        this.#joystick.end();
        break;
      case 'pending':
        // Below both thresholds: a tap. Cancelled touches never click.
        if (!cancelled) this.#click(BUTTON.LEFT, rec.startFrac);
        break;
      case 'camera':
        this.#endCamera(rec);
        break;
      case 'pinch':
        this.#endPinch();
        break;
      default: // consumed
        break;
    }
  }
}

function dist(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y);
}
