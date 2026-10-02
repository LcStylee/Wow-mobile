// Screen layout: one video box from below the top safe-area inset (camera
// cutout / status bar) to the bottom edge of the screen, with the native
// chrome as a single floating menu button over the game.
//
// The stream's aspect is whatever phone frame the server crops (the hello's
// encoded size — docs/PHONE_FRAME.md; 16:9 until the first hello). Each
// phone's stream is shaped to exactly that box (physH minus the top inset),
// so on the phone it was picked for it fills the box edge to edge; any other
// shape is letterboxed (object-fit: contain, measured by input.js).
//
// History: until v0.6.1 a "deck" mode parked a control strip below a
// top-anchored video. Since the phone layout moved every control into the
// addon UI and one menu button, the strip was only ever an empty bar — and a
// soft-keyboard guard kept it alive after the hello changed the aspect
// (field report v0.6.1: "I cannot get rid of that bottom bar"). It is gone;
// body.layout-overlay is now always set, and the geometry is pure CSS
// (styles.css #video/#touch), so the video and #touch boxes can never
// disagree with it.

export const FADE_AFTER_MS = 4000; // floating chrome fades after this idle time

// Stream aspect as height/width. 16/9 until the first hello reports the
// encoded size; setVideoAspect updates it and the --video-ratio CSS variable.
export const DEFAULT_VIDEO_RATIO = 16 / 9;
let videoRatio = DEFAULT_VIDEO_RATIO;

/**
 * Adopt the stream's encoded size (from the hello). Portrait only — anything
 * else keeps the previous ratio. Fires 'wm-video-aspect' so the touch layer
 * drops its cached geometry.
 */
export function setVideoAspect(w, h) {
  if (!(w > 0) || !(h > w)) return;
  const ratio = h / w;
  if (Math.abs(ratio - videoRatio) < 1e-6) return;
  videoRatio = ratio;
  if (typeof document !== 'undefined') {
    document.documentElement.style.setProperty('--video-ratio', String(ratio));
    window.dispatchEvent(new Event('wm-video-aspect'));
  }
}

export function videoAspect() {
  return videoRatio;
}

/**
 * Height of the video box (CSS px) from below the top safe-area inset to the
 * bottom of the screen. Pure (unit-tested).
 *
 * iOS home-screen apps with the black-translucent status bar draw the page
 * from the very top of the screen but report a viewport (innerHeight, the
 * initial containing block, 100vh/dvh) that is a status bar SHORT: page
 * height + top inset == screen height. Detected exactly that way; then the
 * box is the whole reported height (it starts below the inset and runs to
 * the real bottom edge). Everywhere else the viewport is honest and the box
 * is the viewport minus the inset.
 * @param innerH   window.innerHeight
 * @param screenH  screen.height (portrait-locked app: the long side)
 * @param safeTop  env(safe-area-inset-top) px
 */
export function videoBoxHeight(innerH, screenH, safeTop) {
  if (!(innerH > 0)) return 0;
  if (safeTop > 0 && screenH > innerH && Math.abs(innerH + safeTop - screenH) <= 2) {
    return innerH;
  }
  return Math.max(0, innerH - safeTop);
}

function measureSafeTop(doc) {
  const probe = doc.createElement('div');
  probe.style.cssText =
    'position:fixed;top:0;left:0;visibility:hidden;pointer-events:none;' +
    'width:1px;height:env(safe-area-inset-top,0px)';
  doc.body.appendChild(probe);
  const h = probe.getBoundingClientRect().height;
  probe.remove();
  return h;
}

/**
 * Apply the (single) layout and run the chrome auto-fade: the floating bar
 * dims after FADE_AFTER_MS idle and wakes on any touch of it or of the game
 * surface (buttons stay tappable while dimmed — opacity only).
 */
export function initLayout() {
  const body = document.body;
  const hud = document.getElementById('hud');

  let fadeTimer = null;
  const wakeFade = () => {
    clearTimeout(fadeTimer);
    hud.classList.remove('faded');
    fadeTimer = setTimeout(() => hud.classList.add('faded'), FADE_AFTER_MS);
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

  body.classList.add('layout-overlay');
  const sizeBox = () => {
    const h = videoBoxHeight(
      window.innerHeight,
      Math.max(screen.height || 0, screen.width || 0),
      measureSafeTop(document),
    );
    if (h > 0) document.documentElement.style.setProperty('--video-box-h', `${h}px`);
    window.dispatchEvent(new Event('wm-layout-change'));
  };
  sizeBox();
  window.addEventListener('resize', sizeBox);
  window.visualViewport?.addEventListener?.('resize', sizeBox);
  screen.orientation?.addEventListener?.('change', sizeBox);
  // A new stream aspect moves the letterbox: the touch layer drops its
  // cached geometry like on any other layout change.
  window.addEventListener('wm-video-aspect', () => {
    window.dispatchEvent(new Event('wm-layout-change'));
  });
  wakeFade();
}
