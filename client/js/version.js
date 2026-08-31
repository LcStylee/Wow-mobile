// Client build identity. The literal below is a template: the signal server
// stamps it with its own version at serve time (signal.stampVersion), and the
// service worker caches the STAMPED copy — so the value this module exports is
// always the version of the shell actually running, cached or fresh. The HUD
// surfaces it, making "what is running on this phone" verifiable at a glance.
// When served without stamping (e.g. straight from disk in dev tooling), the
// placeholder shows through — which is itself honest: this copy never passed
// through a server.
export const CLIENT_VERSION = '__WM_VERSION__';

/** Human form for UI surfaces: 'dev' builds and raw placeholders read clearly. */
export function displayVersion() {
  return CLIENT_VERSION.startsWith('__') ? 'unstamped' : CLIENT_VERSION;
}
