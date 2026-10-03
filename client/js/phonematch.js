// Stream fit (docs/PHONE_FRAME.md §7): the stream is shaped for the phone
// picked in-game (the addon's red outline). This module checks it against
// the video box THIS screen can actually show and, on a mismatch, builds
// the one-tap in-game command that reshapes the frame to it. Pure functions
// (unit-tested).

/** Box-vs-stream mismatch (relative) above which the fit notice shows. */
export const FIT_TOLERANCE = 0.01;

/**
 * The fit notice for a hello's video size on THIS screen: compares the
 * stream aspect with the video box the phone can actually show (measured —
 * layout.js videoBox — not the phone table: an iOS home-screen app loses a
 * strip at the bottom that no table can know about, field report v0.6.3).
 * Pure (unit-tested).
 * @param encW,encH  the stream's encoded size (hello)
 * @param boxW,boxH  the visible video box, CSS px
 * @param dpr        window.devicePixelRatio
 * @returns null when the stream fits, else {text, cmd} where cmd is the
 *   in-game command that shapes the red frame to exactly this box.
 */
export function fitNotice(encW, encH, boxW, boxH, dpr) {
  if (!(encW > 0) || !(encH > 0) || !(boxW > 0) || !(boxH > 0) || !(dpr > 0)) return null;
  const box = boxH / boxW;
  if (Math.abs(encH / encW - box) / box <= FIT_TOLERANCE) return null;
  const w = Math.round(boxW * dpr);
  const h = Math.round(boxH * dpr);
  // The addon's custom-size rules: portrait, 100..8000 px each.
  if (!(h > w) || w < 100 || h > 8000) return null;
  const cmd = `/wm phone ${w}x${h}`;
  return {
    cmd,
    text: `The stream doesn't fit this screen. Tap here to fit it (sends ${cmd} to the game).`,
  };
}
