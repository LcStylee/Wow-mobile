// Pure letterbox / world-square math (DOM-free).
//
// The <video> uses object-fit: contain, so the decoded frame is centered in
// the element with symmetric bars. Touch handling needs the on-screen rect of
// the actual frame content to (a) reject touches in the bars and (b) convert
// screen points to capture-normalized fractions (PROTOCOL.md coordinates).

/**
 * Rect of srcW x srcH content fitted (contain) inside a boxW x boxH box.
 * @returns {{x:number, y:number, w:number, h:number}} offsets are from the
 *   box's top-left corner.
 */
export function fitContain(boxW, boxH, srcW, srcH) {
  const scale = Math.min(boxW / srcW, boxH / srcH);
  const w = srcW * scale;
  const h = srcH * scale;
  return { x: (boxW - w) / 2, y: (boxH - h) / 2, w, h };
}

// Design width the addon's `viewport.height` knob is expressed against
// (ARCHITECTURE.md §1): a viewport of 1080 design px in a 1080-wide window is
// an exact square.
export const DESIGN_WIDTH = 1080;

/**
 * Height of the world region as a fraction of capture height. Per
 * ARCHITECTURE.md §1/§5 the region is `viewportPx` design px tall in a
 * DESIGN_WIDTH-wide window, anchored top — at the default 1080 that is the
 * top (width x width) square, 0.5625 of a 1080x1920 frame. `viewportPx` must
 * mirror the addon's `/wm viewport` value (the client `worldViewportPx`
 * setting); there is no protocol field carrying it, so the two are kept in
 * sync by the user per SETUP.md. Clamped for the degenerate case where the
 * region would exceed the frame.
 */
export function worldSquareFrac(captureW, captureH, viewportPx = DESIGN_WIDTH) {
  return Math.min(1, (viewportPx / DESIGN_WIDTH) * (captureW / captureH));
}

export function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}
