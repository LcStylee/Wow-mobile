// End-to-end pipeline gate: a real wowstreamd (--capture test: ffmpeg testsrc2
// through the production libx264 low-latency flags, the production Annex-B
// parser, and the production pion sample path) streamed into a real Chromium
// over real WebRTC. The assertions are deliberately honest:
//
//   1. the peer connection reaches "connected";
//   2. inbound-rtp video stats show packets AND framesDecoded increasing;
//   3. the <video> intrinsic size equals the hello geometry;
//   4. a canvas sample of the playing video is NOT uniformly black
//      (testsrc2 is colorful — pixel variance must be high);
//   5. a synthesized tap reaches the server's injector (input path).
//
// H.264 caveat: Playwright's Chromium is built without proprietary codecs and
// has NO H264 in RTCRtpReceiver.getCapabilities('video') — verified
// empirically, not assumed. With no H264 in the offer the SDP exchange itself
// fails (also verified: pion answers 500, no channels open), so nothing can
// be asserted there; the config therefore prefers a Google Chrome/system
// browser (H264-capable), and if the launched browser genuinely lacks H264
// the whole test is SKIPPED with a loud explanation rather than greenwashed.
//
// Skips must not neuter CI, though: a skipped decode test exits 0, so an
// unnoticed loss of the runner's Chrome would silently evaporate this whole
// regression gate. CI therefore sets WOWMOBILE_REQUIRE_H264=1 (see
// .github/workflows/ci.yml and release.yml, which also install a real Chrome
// rather than trusting the runner image), turning "no H264 browser" into a
// HARD FAILURE there; the skip remains only for local/dev runs.

import { test, expect } from '@playwright/test';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

// Modest geometry keeps CI fast; the shape (portrait 9:16, even dims) and the
// full 1080x1920@60 case were both verified during bring-up — the pipeline is
// geometry-independent, the assertions below are not weaker for it.
const VIDEO_W = 432;
const VIDEO_H = 768;
const FPS = 30;
const TOKEN = 'e2e';

let server; // child process
let serverLog = ''; // accumulated stdout+stderr, for input-path assertions
let baseURL;

function log(...args) {
  console.log('[e2e]', ...args);
}

/** Build (or locate) the server binary for this OS. */
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
  const portFile = path.join(os.tmpdir(), `wowstreamd-e2e-port-${process.pid}.txt`);
  fs.rmSync(portFile, { force: true });
  server = spawn(bin, [
    '--capture', 'test',
    '--no-tls',
    '--token', TOKEN,
    '--addr', '127.0.0.1:0',
    '--port-file', portFile,
    // auto, deliberately: the functional encoder probe must land on a WORKING
    // encoder. The original field black-screen was --encoder auto picking
    // compiled-in h264_nvenc on a machine that cannot run it (every capture
    // launch died instantly, zero frames forever) — this line keeps that
    // failure mode reproducible and gated.
    '--encoder', 'auto',
    '--resolution', `${VIDEO_W}x${VIDEO_H}`,
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

test.use({ viewport: { width: VIDEO_W, height: VIDEO_H } });

test('served shell is version-stamped (service-worker cache busting)', async ({ request }) => {
  // The server must stamp its own version into sw.js (cache name) and
  // js/version.js (client HUD identity): a stale cached shell was a live
  // field failure, so the placeholder must never reach a browser.
  for (const file of ['/sw.js', '/js/version.js']) {
    const res = await request.get(`${baseURL}${file}`);
    expect(res.status(), file).toBe(200);
    const body = await res.text();
    expect(body, `${file} must not leak the template placeholder`).not.toContain('__WM_VERSION__');
    // Deliberately NOT hardcoded to 'dev': an unstamped local build stamps
    // 'dev', but WOWSTREAMD_BIN (see README.md) may point at a release binary
    // built with -X main.version=vX.Y.Z — any non-empty single-quoted VERSION
    // literal proves the server replaced the placeholder.
    expect(body, `${file} must carry a stamped VERSION literal`).toMatch(/VERSION = '[^']+'/);
  }
});

test('test pattern decodes end to end and input round-trips', async ({ page }) => {
  // Observe the app's own RTCPeerConnection (no shadow pipeline).
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

  // Environment verdict, verified empirically per run — never assumed.
  const videoCodecs = await page.evaluate(() =>
    RTCRtpReceiver.getCapabilities('video').codecs.map((c) => `${c.mimeType} ${c.sdpFmtpLine ?? ''}`.trim()),
  );
  const h264Capable = videoCodecs.some((c) => c.startsWith('video/H264'));
  log('browser video receive codecs:', JSON.stringify(videoCodecs));
  log('H264 receive capability:', h264Capable);
  test.info().annotations.push({
    type: 'h264-capability',
    description: h264Capable ? 'present' : 'ABSENT — suite skipped',
  });
  // CI must never soft-skip the decode gate: with WOWMOBILE_REQUIRE_H264 set
  // (both workflows set it), a browser without H264 receive support FAILS the
  // run outright — otherwise the loss of the runner's Chrome would quietly
  // turn this suite's core assertions into a green no-op, exactly the class
  // of self-deception it exists to prevent.
  if (process.env.WOWMOBILE_REQUIRE_H264) {
    expect(
      h264Capable,
      'WOWMOBILE_REQUIRE_H264 is set: this run must use an H264-capable browser ' +
        '(real Google Chrome — the workflows install one); launched browser only offers: ' +
        JSON.stringify(videoCodecs),
    ).toBe(true);
  }
  // Without H264 the offer carries no codec the server can use, so the SDP
  // exchange itself fails (verified empirically: pion answers 500, no
  // channels ever open) — NOTHING below can run, and pretending otherwise
  // would be a fake pass. Skip loudly (local/dev runs only — CI hard-fails
  // above instead); the Playwright config prefers a real Chrome exactly so
  // this branch stays theoretical.
  if (!h264Capable) {
    log('SKIPPING: this browser build cannot receive H264 at all —');
    log('point WOWMOBILE_CHROMIUM at a Google Chrome binary for the real gate.');
  }
  test.skip(!h264Capable, 'browser has no H264 receive support (Playwright Chromium lacks proprietary codecs)');

  // 1. Peer connection reaches "connected".
  await expect
    .poll(async () => page.evaluate(() => window.__pcs.at(-1)?.connectionState ?? 'none'), {
      message: 'peer connection state',
      timeout: 20000,
    })
    .toBe('connected');

  const inboundVideo = () =>
    page.evaluate(async () => {
      const pc = window.__pcs.at(-1);
      if (!pc) return null;
      const report = await pc.getStats();
      for (const s of report.values()) {
        if (s.type === 'inbound-rtp' && s.kind === 'video') {
          return {
            packetsReceived: s.packetsReceived ?? 0,
            framesDecoded: s.framesDecoded ?? 0,
            bytesReceived: s.bytesReceived ?? 0,
          };
        }
      }
      return null;
    });

  {
    // 2a. RTP packets arrive.
    await expect
      .poll(async () => (await inboundVideo())?.packetsReceived ?? 0, {
        message: 'inbound video packetsReceived',
        timeout: 20000,
      })
      .toBeGreaterThan(0);

    // 2b. Frames actually DECODE, and keep decoding (increasing, not a
    // one-off): sample twice, 2 s apart.
    await expect
      .poll(async () => (await inboundVideo())?.framesDecoded ?? 0, {
        message: 'inbound video framesDecoded',
        timeout: 25000,
      })
      .toBeGreaterThan(0);
    const s1 = await inboundVideo();
    await page.waitForTimeout(2000);
    const s2 = await inboundVideo();
    log('stats t0:', JSON.stringify(s1), 't+2s:', JSON.stringify(s2));
    expect(s2.framesDecoded, 'framesDecoded must keep increasing').toBeGreaterThan(s1.framesDecoded);
    expect(s2.packetsReceived, 'packets must keep flowing').toBeGreaterThan(s1.packetsReceived);

    // 3. Intrinsic video size equals the hello geometry.
    await expect
      .poll(async () => page.evaluate(() => {
        const v = document.getElementById('video');
        return `${v.videoWidth}x${v.videoHeight}`;
      }), { message: 'video intrinsic size', timeout: 10000 })
      .toBe(`${VIDEO_W}x${VIDEO_H}`);

    // 4. The picture is not uniformly black: testsrc2 is colorful, so the
    // luma standard deviation across a canvas sample must be substantial.
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
    expect(px.stddev, 'testsrc2 must show real pixel variance').toBeGreaterThan(20);
  }

  // 5. Input path: dismiss the start overlay if it appeared (hello arrived),
  // then tap the control deck region — TouchLayer turns it into
  // move+down+up, the server's test injector logs it.
  await expect
    .poll(async () => page.evaluate(() => {
      const o = document.getElementById('overlay-start');
      return !o.hidden || document.getElementById('overlay-connect').hidden;
    }), { message: 'hello handled (start overlay or connected UI)', timeout: 15000 })
    .toBe(true);
  const startOverlay = page.locator('#overlay-start');
  if (await startOverlay.isVisible()) await startOverlay.click();

  // Tap the deck area (bottom quarter, horizontally centered): TouchLayer
  // maps it against the decoded video geometry and sends move+down+up.
  await page.mouse.click(VIDEO_W / 2, Math.round(VIDEO_H * 0.9));

  await expect
    .poll(() => serverLog.includes('input: pointer button'), {
      message: 'server logs the injected tap',
      timeout: 10000,
    })
    .toBe(true);
  log('input path verified: server received the tap');
});
