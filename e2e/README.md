# WoW Mobile — end-to-end streaming pipeline gate

Boots a real `wowstreamd` in `--capture test` mode (ffmpeg `testsrc2` through
the production encoder flags, Annex-B parser, and pion sample path) and drives
a real Chromium against it over real WebRTC. Honest assertions:

1. the app's own RTCPeerConnection reaches `connected`;
2. `inbound-rtp` video stats show packets **and** `framesDecoded` increasing;
3. the `<video>` intrinsic size equals the hello geometry;
4. a canvas sample of the playing video is **not** uniformly black
   (testsrc2 is colorful — luma mean and standard deviation are asserted);
5. a synthesized tap on the touch layer reaches the server's injector
   (`input: pointer button` in the server log);
6. the served `sw.js` / `js/version.js` are version-stamped (cache busting).

The server runs with `--encoder auto` on purpose: the functional encoder
probe must land on an encoder that actually works on the machine (the
original field black-screen was `auto` picking compiled-in-but-unrunnable
`h264_nvenc`; this suite keeps that failure mode gated).

## Running

```
cd e2e
npm ci
npm test
```

- `WOWSTREAMD_BIN` — path to a prebuilt server binary; unset, the suite runs
  `go build ./server/cmd/wowstreamd` itself.
- `WOWMOBILE_CHROMIUM` — explicit browser executable. Unset, the config
  prefers an installed Google Chrome (`/usr/bin/google-chrome`, present on
  GitHub runners), then `PLAYWRIGHT_BROWSERS_PATH/chromium`, then
  Playwright's managed Chromium.
- `WOWMOBILE_REQUIRE_H264=1` — turn the decode test's no-H264-browser skip
  into a **hard failure**. Both CI workflows set this (and install a real
  Chrome themselves), so the decode gate can never silently evaporate into a
  green skip when the runner image changes; leave it unset for local runs.
- `ffmpeg` must be on PATH (CI installs it via apt).

## The H264 caveat (verified, not assumed)

Playwright's own Chromium is built **without proprietary codecs**:
`RTCRtpReceiver.getCapabilities('video')` lists VP8/VP9/AV1 only — and with
no H264 in the offer the SDP exchange itself fails (pion has only H264
registered), so nothing downstream can be asserted. The spec checks the live
capability and **skips loudly** on such a build instead of greenwashing;
point `WOWMOBILE_CHROMIUM` at a Google Chrome binary for the real gate.
In CI the skip is forbidden outright: `WOWMOBILE_REQUIRE_H264=1` makes an
H264-less browser fail the job, so the gate provably ran on every green build.
