// Service worker: install/offline shell ONLY. Signaling (/api/) and WebRTC
// are always live — /api/ requests are never intercepted, let alone cached.
// Bump CACHE on any shell change; activation drops older caches.

const CACHE = 'wowmobile-shell-v2';

const SHELL = [
  './',
  './index.html',
  './styles.css',
  './manifest.webmanifest',
  './icons/icon.svg',
  './icons/icon-maskable.svg',
  './icons/apple-touch-icon.png',
  './js/app.js',
  './js/geometry.js',
  './js/hud.js',
  './js/input.js',
  './js/joystick.js',
  './js/keyboard.js',
  './js/net.js',
  './js/protocol.js',
  './js/quickbar.js',
  './js/settings.js',
  './js/signaling.js',
  './js/vk.js',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  // Never touch signaling, cross-origin requests, or non-GETs.
  if (
    event.request.method !== 'GET' ||
    url.origin !== self.location.origin ||
    url.pathname.startsWith('/api/')
  ) {
    return;
  }
  // Cache-first for the shell; network for anything uncached. A navigation
  // that misses both (offline cold start) falls back to the cached shell.
  event.respondWith(
    caches.match(event.request, { ignoreSearch: true }).then(
      (hit) =>
        hit ??
        fetch(event.request).catch(() => {
          if (event.request.mode === 'navigate') return caches.match('./index.html');
          return Response.error();
        }),
    ),
  );
});
