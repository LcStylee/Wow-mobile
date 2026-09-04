// Band-mode pipeline gate (the BAND CONTRACT, docs/ARCHITECTURE.md): the
// server runs with --layout band and a LANDSCAPE 1280x720 "window" (the
// --capture test platform reports the configured resolution as the live
// client area), so the whole band chain runs for real:
//
//   testsrc2 1280x720 (the simulated window)
//     -> crop=405:720:438:0    (the centered 9:16 band, contract formula)
//     -> scale=404:720         (even-floored encode)
//     -> H.264 -> WebRTC -> browser
//
// Assertions, deliberately end-to-end honest:
//   1. the browser DECODES the band: videoWidth x videoHeight == 404x720 —
//      the hello geometry and the encoder agreed on the band, not the window;
//   2. the picture is not black (the crop landed on live testsrc2 content);
//   3. a synthesized tap at the phone's horizontal center is logged by the
//      server's injector at the BAND-OFFSET window coordinate: winX ~= 640 —
//      the window's center column, i.e. bandX(438) + half the band — proving
//      the input mapping uses the same band the capture cropped.
//
// The H.264-capability gating mirrors stream.spec.js (see the discussion
// there): CI sets WOWMOBILE_REQUIRE_H264=1 to hard-fail on a codec-less
// browser; local runs skip loudly.

import { test, expect } from '@playwright/test';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

// The simulated game window: landscape 720p.
const WINDOW_W = 1280;
const WINDOW_H = 720;
// The band contract for that window: bandW = roundHalfToEven(720*9/16) = 405
// at bandX = roundHalfToEven((1280-405)/2) = 438; encode = even-floored band.
const BAND_X = 438;
const BAND_W = 405;
const ENC_W = 404;
const ENC_H = 720;
const FPS = 30;
const TOKEN = 'e2e-band';

let server;
let serverLog = '';
let baseURL;

function log(...args) {
  console.log('[e2e-band]', ...args);
}

function serverBinary() {
  if (process.env.WOWSTREAMD_BIN) return process.env.WOWSTREAMD_BIN;
  const bin = path.join(os.tmpdir(), 'wowstreamd-e2e' + (process.platform === 'win32' ? '.exe' : ''));
  log('building wowstreamd →', bin);
  const res = spawnSync('go', ['build', '-o', bin, './server/cmd/wowstreamd'], {
    cwd: repoRoot,
    stdio: 'inherit',
  });
  if (res.status !== 0) throw new Error('go build failed');
  return bin;
}

async function waitForPortFile(portFile, child, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`server exited early (code ${child.exitCode}):\n${serverLog}`);
    }
    try {
      const txt = fs.readFileSync(portFile, 'utf8').trim();
      if (txt) return Number(txt);
    } catch {
      /* not yet */
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`server did not write ${portFile} in time:\n${serverLog}`);
}

test.beforeAll(async () => {
  const bin = serverBinary();
  const portFile = path.join(os.tmpdir(), `wowstreamd-e2e-band-port-${process.pid}.txt`);
  fs.rmSync(portFile, { force: true });
  server = spawn(bin, [
    '--capture', 'test',
    '--layout', 'band',
    '--no-tls',
    '--token', TOKEN,
    '--addr', '127.0.0.1:0',
    '--port-file', portFile,
    '--encoder', 'auto',
    // The LANDSCAPE simulated window — the band is derived from it live.
    '--resolution', `${WINDOW_W}x${WINDOW_H}`,
    '--fps', String(FPS),
  ]);
  server.stdout.on('data', (d) => { serverLog += d; });
  server.stderr.on('data', (d) => { serverLog += d; });
  const port = await waitForPortFile(portFile, server);
  baseURL = `http://127.0.0.1:${port}`;
  log('server ready at', baseURL);
});

test.afterAll(async () => {
  if (server && server.exitCode === null) {
    server.kill('SIGTERM');
    await new Promise((r) => {
      server.once('exit', r);
      setTimeout(r, 3000);
    });
  }
});

// The phone shows the band: use a viewport of exactly the encoded band so the
// video content fills it 1:1 and tap coordinates need no letterbox math.
test.use({ viewport: { width: ENC_W, height: ENC_H } });

test('landscape window streams the centered 9:16 band and taps land band-offset', async ({ page }) => {
  await page.addInitScript(() => {
    window.__pcs = [];
    const Orig = window.RTCPeerConnection;
    window.RTCPeerConnection = class extends Orig {
      constructor(...a) {
        super(...a);
        window.__pcs.push(this);
      }
    };
  });
  page.on('console', (msg) => log('page console:', msg.type(), msg.text()));
  page.on('pageerror', (err) => log('page error:', String(err)));

  await page.goto(`${baseURL}/?token=${TOKEN}`);

  const videoCodecs = await page.evaluate(() =>
    RTCRtpReceiver.getCapabilities('video').codecs.map((c) => `${c.mimeType} ${c.sdpFmtpLine ?? ''}`.trim()),
  );
  const h264Capable = videoCodecs.some((c) => c.startsWith('video/H264'));
  log('H264 receive capability:', h264Capable);
  if (process.env.WOWMOBILE_REQUIRE_H264) {
    expect(
      h264Capable,
      'WOWMOBILE_REQUIRE_H264 is set: this run must use an H264-capable browser; launched browser only offers: ' +
        JSON.stringify(videoCodecs),
    ).toBe(true);
  }
  test.skip(!h264Capable, 'browser has no H264 receive support (Playwright Chromium lacks proprietary codecs)');

  // Peer connection up, frames decoding.
  await expect
    .poll(async () => page.evaluate(() => window.__pcs.at(-1)?.connectionState ?? 'none'), {
      message: 'peer connection state',
      timeout: 20000,
    })
    .toBe('connected');
  await expect
    .poll(async () => page.evaluate(async () => {
      const pc = window.__pcs.at(-1);
      if (!pc) return 0;
      const report = await pc.getStats();
      for (const s of report.values()) {
        if (s.type === 'inbound-rtp' && s.kind === 'video') return s.framesDecoded ?? 0;
      }
      return 0;
    }), { message: 'inbound video framesDecoded', timeout: 25000 })
    .toBeGreaterThan(0);

  // 1. The decoded stream IS the band, not the window: the hello geometry and
  // the encoder both said 404x720 (crop + even-floor of the 1280x720 window's
  // centered 405-wide band).
  await expect
    .poll(async () => page.evaluate(() => {
      const v = document.getElementById('video');
      return `${v.videoWidth}x${v.videoHeight}`;
    }), { message: 'video intrinsic size (the encoded band)', timeout: 10000 })
    .toBe(`${ENC_W}x${ENC_H}`);

  // 2. The band shows live testsrc2 content, not black bars: mean luma and
  // pixel variance must both be substantial.
  const px = await page.evaluate(() => {
    const v = document.getElementById('video');
    const c = document.createElement('canvas');
    c.width = v.videoWidth;
    c.height = v.videoHeight;
    const ctx = c.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(v, 0, 0);
    const { data } = ctx.getImageData(0, 0, c.width, c.height);
    let n = 0;
    let sum = 0;
    let sumSq = 0;
    for (let i = 0; i < data.length; i += 4) {
      const luma = 0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2];
      n += 1;
      sum += luma;
      sumSq += luma * luma;
    }
    const mean = sum / n;
    const variance = sumSq / n - mean * mean;
    return { mean, stddev: Math.sqrt(Math.max(variance, 0)) };
  });
  log('canvas luma:', JSON.stringify(px));
  expect(px.mean, 'mean luma of a black frame is ~0').toBeGreaterThan(10);
  expect(px.stddev, 'the cropped band must show real pixel variance').toBeGreaterThan(20);

  // 3. Input path with the band offset: dismiss the start overlay, tap the
  // control deck at the phone's HORIZONTAL CENTER, and require the server's
  // injector to log the mapped window coordinate at the window's center
  // column — bandX + round(0.5 * (bandW-1)) = 438 + 202 = 640 — proving the
  // tap was mapped into the band, not the full window (full-window mapping
  // would log ~640 too ONLY by coincidence of centering, so also require it
  // strictly inside the band's x-range while a full-window left-edge tap
  // check pins the offset below).
  await expect
    .poll(async () => page.evaluate(() => {
      const o = document.getElementById('overlay-start');
      return !o.hidden || document.getElementById('overlay-connect').hidden;
    }), { message: 'hello handled (start overlay or connected UI)', timeout: 15000 })
    .toBe(true);
  const startOverlay = page.locator('#overlay-start');
  if (await startOverlay.isVisible()) await startOverlay.click();

  // Center tap (deck region: bottom 10% of the portrait band).
  await page.mouse.click(ENC_W / 2, Math.round(ENC_H * 0.9));
  const buttonLine = /msg="input: pointer button".*?winX=(\d+) winY=(\d+)/;
  await expect
    .poll(() => buttonLine.test(serverLog), {
      message: 'server logs the injected tap with window coordinates',
      timeout: 10000,
    })
    .toBe(true);
  let m = serverLog.match(buttonLine);
  const centerX = Number(m[1]);
  const centerY = Number(m[2]);
  log('center tap mapped to window', centerX, centerY);
  const windowCenter = (WINDOW_W - 1) / 2; // 639.5
  expect(Math.abs(centerX - windowCenter), 'phone center tap must land at the window center column').toBeLessThanOrEqual(2);
  expect(centerY, 'tap row must map into the full-height band').toBeGreaterThan(ENC_H * 0.8);
  expect(centerY).toBeLessThan(ENC_H);

  // A tap at the phone's LEFT edge pins the band offset itself: it must land
  // at ~bandX (438) — far from window x=0, where full-window mapping would
  // put it.
  const before = serverLog.length;
  await page.mouse.click(1, Math.round(ENC_H * 0.9));
  await expect
    .poll(() => buttonLine.test(serverLog.slice(before)), {
      message: 'server logs the left-edge tap',
      timeout: 10000,
    })
    .toBe(true);
  m = serverLog.slice(before).match(buttonLine);
  const leftX = Number(m[1]);
  log('left-edge tap mapped to window x =', leftX);
  expect(Math.abs(leftX - BAND_X), `left-edge tap must land at bandX=${BAND_X}`).toBeLessThanOrEqual(3);
  expect(leftX + BAND_W, 'sanity: the band fits the window').toBeLessThanOrEqual(WINDOW_W);
  log('band input mapping verified: taps land band-offset');
});
