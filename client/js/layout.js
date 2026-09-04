// Screen layout: top-anchored 9:16 video with a bottom "phone deck".
//
// Phones are taller than 9:16, so a top-anchored full-width 9:16 video leaves
// a dead strip at the bottom that the stream can never use. The PRIMARY
// layout ("deck") parks ALL native chrome there — quick keys, the compact
// stats line, Snd/Set/End — so nothing overlays the game. The FALLBACK
// ("overlay"), for screens at most ~16:9 tall (old 16:9 phones, landscape
// desktop debugging), keeps the classic full-window letterboxed video with
// the same chrome as a slim auto-fading bar along the top edge.
//
// This module only picks the mode (body.layout-overlay class) and runs the
// overlay fade timer; the geometry itself is pure CSS (--video-h in
// styles.css), so the video and #touch boxes can never disagree with it.
// The pure decision function is exported for unit tests.

// Minimum deck CONTENT height that fits the deck's two rows: 5px top padding
// + 32px keys row + 4px gap + 14px stats line = 55px. The deck additionally
// pads its bottom edge by max(5px, safe-area-inset-bottom) (styles.css #hud),
// which layoutMode accounts for separately — below the sum the rows would
// clip under #hud's overflow:hidden, so the overlay fallback takes over.
export const MIN_DECK_PX = 55;
export const FADE_AFTER_MS = 4000; // overlay chrome fades after this idle time

/**
 * Pick the layout mode for a viewport. Pure (unit-tested).
 * @param w,h        visual viewport CSS px
 * @param safeTop    env(safe-area-inset-top) px — the video sits below it
 * @param safeBottom env(safe-area-inset-bottom) px — unusable deck padding
 * @returns 'deck' | 'overlay'
 */
export function layoutMode(w, h, safeTop, safeBottom, minDeck = MIN_DECK_PX) {
  if (!(w > 0) || !(h > 0)) return 'overlay';
  const videoH = (w * 16) / 9; // the stream is 9:16: height = width·16/9
  const deckH = h - safeTop - videoH;
  // The deck's bottom padding is max(5px, safe-bottom) (styles.css #hud), so
  // an inset below that floor still costs the full 5px — mirroring the CSS
  // keeps boundary-aspect viewports on inset-less devices from picking a deck
  // whose stats line would clip.
  return deckH - Math.max(5, safeBottom) >= minDeck ? 'deck' : 'overlay';
}

/**
 * Soft-keyboard flip guard: decide the mode to APPLY given the freshly
 * computed candidate. Pure (unit-tested).
 *
 * The Android soft keyboard (the deck's Aa chat key, settings fields, token
 * entry) shrinks the viewport HEIGHT only — engines that resize the layout
 * viewport for it drop innerHeight below the deck threshold while typing and
 * again during the close animation, which would flip deck→overlay mid-chat
 * (video jumps to full-height letterbox, chrome floats over the game) and
 * back moments later, invalidating the input geometry cache twice per chat
 * use. A REAL layout change (rotation, docking, split-screen drag) moves the
 * width too, so a deck→overlay flip is only honored when the width changed;
 * every other transition — including overlay→deck when the keyboard closes
 * on an overlay-native screen — applies unconditionally. Trade-off: a
 * height-only shrink with no width change (dragging a desktop window
 * shorter) keeps the deck until the width moves; transient keyboard jumps
 * are worth that corner.
 *
 * @param prevMode  currently applied mode ('deck' | 'overlay' | null at boot)
 * @param candidate mode layoutMode just computed for the new viewport
 * @param prevW     viewport width prevMode was decided at (null at boot)
 * @param w         current viewport width
 * @returns the mode to apply
 */
export function resolveMode(prevMode, candidate, prevW, w) {
  if (prevMode === 'deck' && candidate === 'overlay' && prevW === w) {
    return 'deck';
  }
  return candidate;
}

/**
 * User override from Settings ("Controls below the game"): 'always' forces
 * the deck, 'never' forces the overlay, 'auto' (and any unknown stored
 * value) keeps the measured candidate. Pure (unit-tested). The escape hatch
 * exists because the auto decision reads viewport numbers that engines get
 * wrong in exotic embeddings (webviews, misreported insets) — a misdetected
 * device must not be stuck with chrome floating over the game.
 * @param override 'auto' | 'always' | 'never' (anything else = 'auto')
 * @param candidate the measured mode ('deck' | 'overlay')
 * @returns 'deck' | 'overlay'
 */
export function applyOverride(override, candidate) {
  if (override === 'always') return 'deck';
  if (override === 'never') return 'overlay';
  return candidate;
}

/**
 * Pick the viewport size the layout decision uses. Pure (unit-tested).
 *
 * window.visualViewport is preferred where present: on iOS its height tracks
 * the ACTUAL visible viewport (matching the 100dvh the CSS boxes use) in both
 * Safari tabs (dynamic toolbar) and standalone home-screen PWAs, whereas
 * documentElement.clientHeight is the stable/small layout viewport, which in
 * a Safari tab under-reports by the toolbar height and would deny the deck to
 * phones that fit it. Two exceptions fall back to the layout viewport:
 *   - pinch-zoom (scale ≠ 1): visualViewport reports the zoomed-in window,
 *     but pinch-zoom moves no CSS boxes, so the decision must not change;
 *   - degenerate/absent visualViewport (0x0 during some engine transitions).
 * @param vv        window.visualViewport (or null/undefined)
 * @param fallbackW documentElement.clientWidth (|| innerWidth)
 * @param fallbackH documentElement.clientHeight (|| innerHeight)
 * @returns {w, h} CSS px
 */
export function viewportSize(vv, fallbackW, fallbackH) {
  if (vv && vv.width > 0 && vv.height > 0) {
    const scale = vv.scale || 1;
    if (scale > 0.99 && scale < 1.01) {
      return { w: vv.width, h: vv.height };
    }
  }
  return { w: fallbackW, h: fallbackH };
}

/**
 * Measure the safe-area insets in px. env() is only readable through CSS, so
 * a hidden probe element carries the two values in its box size.
 */
function measureSafeInsets(doc) {
  const probe = doc.createElement('div');
  probe.style.cssText =
    'position:fixed;top:0;left:0;visibility:hidden;pointer-events:none;' +
    'height:env(safe-area-inset-top,0px);width:env(safe-area-inset-bottom,0px)';
  doc.body.appendChild(probe);
  const rect = probe.getBoundingClientRect();
  probe.remove();
  return { top: rect.height, bottom: rect.width };
}

/**
 * Apply the layout mode to the document and keep it current across resizes /
 * orientation changes. Also owns the overlay-mode auto-fade: the chrome bar
 * dims after FADE_AFTER_MS idle and wakes on any touch of it or of the game
 * surface (buttons stay tappable while dimmed — opacity only).
 */
export function initLayout(settings) {
  const body = document.body;
  const hud = document.getElementById('hud');

  let fadeTimer = null;
  const wakeFade = () => {
    clearTimeout(fadeTimer);
    hud.classList.remove('faded');
    if (body.classList.contains('layout-overlay')) {
      fadeTimer = setTimeout(() => hud.classList.add('faded'), FADE_AFTER_MS);
    }
  };
  // In overlay mode #hud is pointer-events:none with only its buttons live,
  // so a pointerdown reaching #hud is always a button press that also ACTS —
  // deliberate for hold keys (Spc must stay holdable through a faded bar),
  // but a destructive control on a 35%-opacity bar is a mis-tap waiting to
  // happen: for #btn-disconnect (End) and #update-pill (instant reload; it
  // hangs below the bar over the world square's top edge and inherits the
  // bar's faded opacity), a tap that lands while the bar is faded wakes the
  // bar and swallows that one click (the now-visible button acts on the next
  // tap).
  const guarded = [
    document.getElementById('btn-disconnect'),
    document.getElementById('update-pill'),
  ];
  hud.addEventListener('pointerdown', (e) => {
    const wasFaded = hud.classList.contains('faded');
    wakeFade();
    if (!wasFaded) return;
    const btn = guarded.find((b) => b && b.contains(e.target));
    if (btn) {
      const swallow = (ev) => {
        ev.stopImmediatePropagation();
        ev.preventDefault();
      };
      btn.addEventListener('click', swallow, { capture: true, once: true });
      // A drag off the button never fires the click: drop the stale guard.
      setTimeout(
        () => btn.removeEventListener('click', swallow, { capture: true }),
        700,
      );
    }
  });
  // Any touch on the game surface wakes the faded bar too — activity means
  // the user is engaged, and the bar then only fades while they are truly
  // idle.
  document.getElementById('touch').addEventListener('pointerdown', wakeFade);

  // Legacy soft-keyboard guard: engines that resize the LAYOUT viewport for
  // the software keyboard (Android Chrome < 108, some WebViews) shrink
  // innerHeight while typing (chat Aa, settings fields, token entry), which
  // would flip deck→overlay mid-typing and back on close. While a text field
  // has focus, hold the current mode and re-decide after the blur.
  // resolveMode (above) backstops the moments this hold cannot see — the
  // keyboard's close animation after the blur, or a keyboard kept up with
  // the field unfocused — by refusing height-only deck→overlay flips.
  let heldWhileTyping = false;
  const isTyping = () => {
    const el = document.activeElement;
    return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA');
  };

  // The applied mode and the width it was decided at, for resolveMode's
  // soft-keyboard flip guard (a keyboard open/close changes the height only;
  // real layout changes move the width too).
  let appliedMode = null;
  let appliedW = null;

  const apply = () => {
    if (isTyping()) {
      heldWhileTyping = true;
      return;
    }
    heldWhileTyping = false;
    const insets = measureSafeInsets(document);
    // visualViewport preferred, documentElement.clientWidth/Height fallback
    // (see viewportSize): on iOS the visual viewport tracks the 100dvh the
    // CSS boxes use — in a Safari tab the layout viewport under-reports by
    // the toolbar height — while pinch-zoom and degenerate readings fall
    // back to the layout viewport, which matches the CSS units more closely
    // than window.inner* (desktop scrollbars).
    const { w, h } = viewportSize(
      window.visualViewport,
      document.documentElement.clientWidth || window.innerWidth,
      document.documentElement.clientHeight || window.innerHeight,
    );
    const candidate = layoutMode(w, h, insets.top, insets.bottom);
    // Settings escape hatch first ('always'/'never' pin the mode outright);
    // in 'auto' the soft-keyboard flip guard arbitrates as before.
    const override = settings ? settings.get('deckLayout') : 'auto';
    const mode = applyOverride(
      override,
      resolveMode(appliedMode, candidate, appliedW, w),
    );
    appliedMode = mode;
    appliedW = w;
    const wasOverlay = body.classList.contains('layout-overlay');
    body.classList.toggle('layout-overlay', mode === 'overlay');
    if (wasOverlay !== (mode === 'overlay')) {
      // A mode flip moves the #video/#touch boxes without any resize event on
      // some paths (the focusout-held re-evaluation): tell the touch layer to
      // drop its cached geometry so the very next tap maps correctly.
      window.dispatchEvent(new Event('wm-layout-change'));
    }
    wakeFade(); // (re)arm in overlay mode, clear any fade in deck mode
  };

  document.addEventListener('focusout', () => {
    // Run any held re-evaluation once focus settles (during focusout the
    // activeElement is not final; a focus hop to another field re-holds).
    if (heldWhileTyping) setTimeout(() => { if (heldWhileTyping) apply(); }, 0);
  });

  window.addEventListener('resize', apply);
  // The visual viewport can resize without a window resize event (iOS
  // toolbar collapse, keyboard geometry) — listen to it directly where it
  // exists, since its size now feeds the decision.
  window.visualViewport?.addEventListener?.('resize', apply);
  screen.orientation?.addEventListener?.('change', apply);
  // The Settings "Controls below the game" select re-decides immediately.
  // The applied-mode memory is dropped first: it exists only for the soft-
  // keyboard flip guard, and holding a previously FORCED mode against a
  // fresh 'auto' decision (deck→overlay refused at unchanged width) would
  // make "back to Auto" appear to do nothing until the next rotation.
  settings?.onChange?.((key) => {
    if (key !== 'deckLayout') return;
    appliedMode = null;
    appliedW = null;
    apply();
  });
  apply();
}
