// Playwright config for the wowstreamd streaming pipeline gate.
//
// Browser resolution: CI runs `npx playwright install --with-deps chromium`,
// so the default registry browser exists. Locally (and in sandboxes) a
// preinstalled Chromium can be pointed at via PLAYWRIGHT_BROWSERS_PATH, or an
// explicit executable via WOWMOBILE_CHROMIUM; when the pinned @playwright/test
// build is absent but a `chromium` symlink exists under
// PLAYWRIGHT_BROWSERS_PATH, that binary is used directly.
//
// CI additionally guarantees a real Google Chrome exists (see the workflows'
// e2e step) and sets WOWMOBILE_REQUIRE_H264=1 so the decode gate hard-fails
// instead of skipping if this resolution ever lands on an H264-less browser.
import { defineConfig } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';

function chromiumExecutablePath() {
  const candidates = [];
  if (process.env.WOWMOBILE_CHROMIUM) candidates.push(process.env.WOWMOBILE_CHROMIUM);
  // Prefer a real Chrome when one is installed (GitHub ubuntu runners ship
  // one): Playwright's Chromium is built WITHOUT proprietary codecs and can
  // NOT decode H264, which would skip the decode assertions — the core of
  // this suite. Verified empirically; the spec still gates on the live
  // getCapabilities answer, never on this guess.
  candidates.push('/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/opt/google/chrome/chrome');
  if (process.env.PLAYWRIGHT_BROWSERS_PATH) {
    candidates.push(path.join(process.env.PLAYWRIGHT_BROWSERS_PATH, 'chromium'));
  }
  for (const p of candidates) {
    try {
      fs.accessSync(p, fs.constants.X_OK);
      return p;
    } catch {
      /* try the next candidate */
    }
  }
  return undefined; // let Playwright resolve its own managed browser
}

export default defineConfig({
  testDir: './tests',
  // The suite drives one real server + one real browser; parallel workers
  // would fight over the single-session server (safety rule 3).
  workers: 1,
  fullyParallel: false,
  timeout: 120_000,
  expect: { timeout: 20_000 },
  reporter: [['list']],
  use: {
    launchOptions: {
      executablePath: chromiumExecutablePath(),
      // Autoplay policy is disabled so <video>.play() never blocks on a
      // synthetic gesture race. (A future camera-path test would also need
      // --use-fake-device-for-media-stream/--use-fake-ui-for-media-stream —
      // deliberately not passed today.)
      args: ['--autoplay-policy=no-user-gesture-required'],
    },
  },
});
