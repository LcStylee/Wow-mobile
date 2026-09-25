// Phone identification (docs/PHONE_FRAME.md §7): the stream is shaped for the
// phone model picked in-game (the addon's red outline); this module works out
// which table entry THIS device looks like and whether the stream's aspect
// matches it, so a mismatch can be pointed out instead of silently wasting
// screen space. Pure functions (unit-tested) plus the notice text.

import { PHONES } from './phones.js';

/** Aspect mismatch (relative) above which the notice is shown. */
export const ASPECT_TOLERANCE = 0.02;

/**
 * Candidate table entries for a device: CSS screen size (portrait-normalized)
 * times devicePixelRatio within 2 physical px of the entry's panel. Several
 * models share a panel (iPhone 17 / 17 Pro): the most popular one is first.
 * @param screenW,screenH  screen.width/height (CSS px, any orientation)
 * @param dpr              window.devicePixelRatio
 * @param phones           table (defaults to the generated PHONES)
 * @returns matching entries, best first ([] when unknown)
 */
export function identifyPhones(screenW, screenH, dpr, phones = PHONES) {
  if (!(screenW > 0) || !(screenH > 0) || !(dpr > 0)) return [];
  const w = Math.min(screenW, screenH) * dpr;
  const h = Math.max(screenW, screenH) * dpr;
  const hits = phones.filter(
    (p) => p.popularity >= 0 && p.id !== 'generic-9-16' &&
      Math.abs(p.physW - w) <= 2 && Math.abs(p.physH - h) <= 2,
  );
  // Ranked phones (popularity 1..N) before extras (0), then table order.
  return hits.sort((a, b) => (a.popularity || Infinity) - (b.popularity || Infinity));
}

/**
 * Relative difference between the stream aspect (encoded w x h from the
 * hello) and a phone entry's stream aspect.
 */
export function aspectMismatch(encW, encH, phone) {
  if (!(encW > 0) || !(encH > 0) || !phone) return 0;
  const stream = encH / encW;
  const own = phone.streamH / phone.streamW;
  return Math.abs(stream - own) / own;
}

/** Name of the entry whose stream aspect best matches w x h (for the notice). */
export function closestPhoneName(encW, encH, phones = PHONES) {
  let best = null;
  let bestErr = Infinity;
  for (const p of phones) {
    const err = aspectMismatch(encW, encH, p);
    if (err < bestErr) {
      bestErr = err;
      best = p;
    }
  }
  return best ? phoneName(best) : '';
}

export function phoneName(p) {
  return p.model.startsWith(p.brand) || p.brand === 'Generic' ? p.model : `${p.brand} ${p.model}`;
}

/**
 * The one-line notice for a hello's video size on this device, or '' when
 * the stream fits (or this device is not in the table — nothing to compare).
 */
export function aspectNotice(encW, encH, screenW, screenH, dpr, phones = PHONES) {
  const mine = identifyPhones(screenW, screenH, dpr, phones);
  if (mine.length === 0) return '';
  // Any same-panel entry matching is a match (17 vs 17 Pro stream alike).
  if (mine.some((p) => aspectMismatch(encW, encH, p) <= ASPECT_TOLERANCE)) return '';
  const streaming = closestPhoneName(encW, encH, phones);
  return `Streaming for ${streaming}; this phone looks like ${phoneName(mine[0])} — pick your phone in-game (/wm phone) for a perfect fit.`;
}
