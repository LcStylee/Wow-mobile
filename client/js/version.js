// Client build identity. The literal below is a template: the signal server
// stamps it with its own version at serve time (signal.stampVersion), and the
// service worker caches the STAMPED copy — so the value this module exports is
// always the version of the shell actually running, cached or fresh. The HUD
// surfaces it, making "what is running on this phone" verifiable at a glance.
// When served without stamping (e.g. straight from disk in dev tooling), the
// placeholder shows through — which is itself honest: this copy never passed
// through a server.
export const CLIENT_VERSION = '__WM_VERSION__';

/**
 * Human form for UI surfaces: 'dev' builds and raw placeholders read clearly,
 * and numeric stamps get a stable "v" prefix — release ldflags may stamp a
 * bare semver ("0.4.3") or a v-tagged one ("v0.4.3"), and next to labeled
 * stats like "enc 4.2 ms" a bare "0.4.3" lacks context. Non-numeric stamps
 * ("dev", "unstamped") read as-is; "vdev" would not.
 */
export function displayVersion() {
  if (CLIENT_VERSION.startsWith('__')) return 'unstamped';
  return /^\d/.test(CLIENT_VERSION) ? `v${CLIENT_VERSION}` : CLIENT_VERSION;
}
