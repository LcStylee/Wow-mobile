# WoW Mobile — Architecture

Play World of Warcraft Classic on a phone by streaming it from your own PC, with a
UI rebuilt for portrait touch. Three components, one repo:

```
┌─────────────────────────── Windows Gaming PC ───────────────────────────┐
│                                                                         │
│  WoW Classic — native LANDSCAPE window; the stream is the CENTERED      │
│  │  9:16 BAND cropped out of it (band layout, the default for 1.12     │
│  │  clients), or a forced portrait window captured whole (portrait      │
│  │  layout, the Classic Era default). 1080x1920 design space either way.│
│  └─ addon/WowMobile  → portrait touch UI in the band, 1080x1080 world  │
│                                                                         │
│  server/ (wowstreamd.exe, Go)                                           │
│  ├─ capture:  FFmpeg subprocess (ddagrab → h264_nvenc, zero-latency;    │
│  │            band layout adds crop→scale before encode)                │
│  ├─ webrtc:   pion/webrtc — H.264 video track + input data channels     │
│  ├─ input:    SendInput injection (mouse/keyboard) into the WoW window  │
│  │            (band layout maps touches into the band)                  │
│  └─ signal:   HTTPS server — WHEP signaling + embedded client PWA       │
│                                                                         │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │  LAN Wi-Fi (WebRTC: SRTP + SCTP)
┌───────────────────────────────┴─────────────────────────────────────────┐
│  Phone (any modern browser, installable PWA)                            │
│  client/ — fullscreen portrait video + touch layer                      │
│  (virtual joystick → WASD, camera drag → RMB-drag, tap → click, …)      │
└─────────────────────────────────────────────────────────────────────────┘
```

## Design decisions

### 1. THE BAND CONTRACT — the primary design

The touch experience is a 9:16 portrait surface. The game window does **not**
have to be: when the game's client area is **LANDSCAPE** (`width > height`),
the stream is the **centered 9:16 portrait band** cropped out of it — the
window itself is never forced portrait. The addon and the server compute the
band **independently from the same window dimensions**, so this formula is
normative, deterministic, and integer-exact on both sides:

```
bandHeight = clientHeight
bandWidth  = roundHalfToEven(clientHeight * 9 / 16)
bandX      = roundHalfToEven((clientWidth - bandWidth) / 2)
bandY      = 0
```

`roundHalfToEven` is banker's rounding: nearest integer, exact `.5` to the
even neighbor (server: `window.ComputeBandFrame`; both addon variants
duplicate it in Lua — `Band.lua` in `addon/WowMobile`, and its Lua 5.0 port
in `addon/WowMobile_Vanilla`, which reads the physical client size from the
`gxResolution` cvar since 1.12 has no `GetPhysicalScreenSize`; each asserts
the shared contract vectors at load, so drift is caught deterministically).
Examples: a 1280x720 window gives a 405x720 band at x=438; a 3840x2160
desktop gives a 1215x2160 band at x=1312. Inside the band, the existing
**1080x1920 design space maps as fractions of the band** — the band IS the
design space, scaled. When the window is **PORTRAIT** (`height >= width`),
behavior is exactly the classic full-window mode; a portrait window under
band layout streams full-window (and says so on the log and dashboard).

The **encode** is the band even-floored for H.264 4:2:0 (405x720 band →
404x720 frame), and **capped at 1080x1920**: a band taller than the design
space (that 1215x2160 4K band) is scaled down to exactly 1080x1920 — more
pixels would only cost bitrate the phone downscales away. The pipeline in
band layout is therefore `grab window → crop band → scale to ≤1080x1920 →
encode` (NVENC's zero-copy ddagrab crops the band at grab time when it
matches the encode size exactly). The **hello reports the encoded band
dimensions** through the same liveGeometry path portrait mode uses, so the
**phone client is completely unchanged** — it sees a 9:16 stream and its
world-square math works as-is. Input injection maps normalized phone
coordinates **into the band** (`px = bandX + n/65535*(bandWidth-1)`), from
the same live client rect the capture used, so a tap at the phone's center
lands on the window's center column.

Why band mode exists — and why it is the **default for legacy (1.12-engine)
clients** (`--layout auto`; `--layout band|portrait` overrides): every WoW
client happily renders native landscape, but the 1.12-engine field client
**rejects portrait render resolutions and stretches** — the whole v0.3.x
fight of CVars, `SetWindowPos` enforcement, and re-assert battles. A centered
band in a landscape window needs **no window forcing at all**: the wizard
writes a native landscape session (legacy: `gxResolution` = the primary
monitor's desktop resolution — a mode every client accepts), window-size
enforcement is retired, and the band is recomputed from the **live** client
rect before every capture (re)launch — with a geometry watchdog that polls
the client rect (~1 s) while streaming and relaunches the encoder once the
window settles on a new size (or, on the zero-copy ddagrab path, a new
position, since its crop is a fixed screen rect), so resizes, moves,
maximization, and odd sizes all just work within seconds, at the cost of the
same brief IDR-restart gap a bitrate change takes. The vanilla addon (`addon/WowMobile_Vanilla`) carries the
band module for exactly this default: `WM.Px` sizes against the band width,
the world square/deck hang off the band frame, and side rails black out the
window outside the crop. Classic Era keeps portrait-window mode as its
server default (its addon ships the same `Band.lua`, inert in a portrait
window — only the default differs); portrait mode remains fully supported
and is documented next.

### 1b. Portrait-window mode (the Classic Era default) — 1080x1920 with a 1080x1080 world viewport

**1080x1920 is the DESIGN space, not necessarily the real window.** A
1080x1920 window physically cannot fit a landscape 1920x1080 monitor: Windows
clamps it, only the top ~1080 rows exist on the desktop, and capturing the
off-screen remainder goes black. The default `--resolution fit` therefore
sizes the actual window to the **largest 9:16 portrait client area that fits
the primary monitor's work area, capped at 1080x1920** (e.g. `552x984` on a
1920x1080 monitor with a taskbar; exactly `1080x1920` on a monitor that can hold it (4K, portrait 1440p) —
the phone renders the design size pixel-for-pixel, so a larger window would
only raise encode cost with zero phone benefit); every layout constant below
stays expressed in 1080x1920 design pixels and scales down uniformly
(`WM.Px`, the client's `DESIGN_WIDTH`). An explicit `--resolution WxH` is
still honored, after a wizard sanity check against the monitor.

Capture additionally **self-heals to the window WoW actually opened**: before
every ffmpeg launch the live client rect is compared to the configured
resolution, and on a mismatch (Config.wtf overwritten because the game was
running during setup, DPI virtualization, the client restoring its own rect)
the encode adopts the real client area, the `hello` advertises that real
geometry, and the mismatch is surfaced loudly on the log and the dashboard's
warning row — a fixed crop of the assumed size is exactly the
black-frames-while-clicks-work failure, and degraded-but-visible beats black.
Input injection independently maps normalized coordinates onto the live
client rect, and the client normalizes touches against the video element's
live intrinsic dimensions (falling back to the `hello` geometry only before
the first frame decodes), so touch stays accurate throughout — including
across a mid-session self-heal to a new size, which changes the stream
without a new `hello`.

WoW runs **windowed** at the fitted resolution (set via `Config.wtf`:
`SET gxWindowedResolution "<WxH>"`, or the server's `--setup` helper). The
addon then shrinks the 3D world (`WorldFrame`) to a **square anchored to the
top** of the window (1080x1080 in design px). The bottom **1080x840 design-px
strip is the "control deck"**: a pure-2D region owned entirely by the addon
(action bars, unit frames, bags, panels) over a black background.

Why:

- **GPU**: the 3D scene renders 1080x1080 instead of 1080x1920 — ~44% fewer
  world pixels.
- **Encoder/bandwidth**: the control deck is flat 2D that changes rarely;
  H.264 spends almost nothing on it. Motion cost is confined to the square.
- **Ergonomics**: everything interactive sits in the bottom 44% of the phone
  screen — natural thumb reach — while the world stays unobstructed.
- **Aspect**: 1:1 world viewport means no absurdly narrow FoV that full
  portrait 3D would give.

The world viewport is configurable (`WowMobile` saved variable
`viewport.height`, default 1080) for phones with different aspect ratios. The
wire protocol carries no viewport field, so the phone client mirrors the value
in its own **World viewport** setting (`worldViewportPx`, settings sheet,
default 1080); the two must be changed together (see SETUP.md §5) or the
client's world/deck gesture split desyncs from the addon's actual layout.

### 2. Streaming: WebRTC, not a custom transport

Sub-frame glass-to-glass latency needs hardware encode, no B-frames, and a
transport with FEC/NACK and jitter management. WebRTC gives all of that plus a
zero-install client (browser/PWA). Pipeline:

```
ddagrab (Desktop Duplication, GPU) → h264_nvenc (zerolatency, no B-frames,
periodic IDR, CBR) → Annex-B NALU splitter → pion TrackLocalStaticSample
→ SRTP → phone <video> with playoutDelayHint = 0
```

Recovery points are periodic IDRs (2 s GOP) plus keyframe-on-demand: a PLI
from the client (or a track being added/connected) triggers an encoder
restart, whose first frame is a fresh IDR + SPS/PPS. The Annex-B splitter
additionally caches the newest SPS/PPS and attaches them to every keyframe
access unit that lacks its own — the supported encoders do not repeat
parameter sets on periodic IDRs, and a browser joining on one would otherwise
stay black. Intra-refresh was deliberately rejected — a browser (re)joining
mid-stream cannot decode a rolling refresh wavefront at all; it needs a full
IDR, so intra-refresh would break mid-join and PLI recovery outright.

Fallbacks: `gdigrab + libx264 -tune zerolatency` when no NVIDIA GPU;
AMF/QSV selectable via `--encoder`. `--encoder auto` resolves by **functional
trial**, not by what ffmpeg was compiled with: full ffmpeg builds compile in
NVENC/AMF/QSV unconditionally, and picking an encoder whose GPU runtime is
absent (`h264_nvenc` on an AMD box) makes every capture launch die instantly —
a permanently black stream while input still works (a real field failure). So
each compiled-in candidate encodes a few `testsrc2` frames with the exact
production flags, most-preferred first, and the first that emits H.264 wins.
Target: ≤ 3 ms capture + ~5 ms encode + ~5–15 ms LAN + ~10 ms decode/display ≈
**30–60 ms glass-to-glass on 5 GHz Wi-Fi**.

The same synthetic source powers three diagnostics layers: `--capture test`
(a first-class portable mode streaming `testsrc2` through the identical
encoder flags, Annex-B parser, and WebRTC path — how the pipeline is
e2e-tested headlessly on any OS), the startup **self-check** (~2 s of test
pattern through the selected encoder + parser; verdict on the dashboard:
"video pipeline OK (N frames)" or ffmpeg's stderr tail), and the
**capture-stall watchdog** (an active capture delivering zero frames for 5 s
puts ffmpeg's stderr tail on the dashboard warning row — a black stream must
always explain itself in readable words).

### 3. Input: forwarded human touch, not automation

Touch events travel over WebRTC data channels (see
[`protocol/PROTOCOL.md`](../protocol/PROTOCOL.md)) and are injected with
`SendInput` as ordinary mouse/keyboard events into the focused WoW window. The
phone is a remote display+input device for a game you run yourself — the same
model as Steam Link / Moonlight. No game memory is read or written, no actions
are automated; one physical input per one human touch.

### 4. Addon: overhaul in-place, respect the sandbox

The addon restyles and repositions Blizzard's UI rather than reimplementing
protected behavior:

- Action buttons use `SecureActionButtonTemplate`; all layout mutation of
  protected frames is deferred out of combat (`InCombatLockdown()` +
  `PLAYER_REGEN_ENABLED` queue).
- Gossip/quest/merchant/trainer interactions are rebuilt as full-width bottom
  sheets with ≥90 px touch targets, driven by the official Classic APIs
  (`C_GossipInfo`, `GetActiveTitle`, etc.).
- Spellbook, character sheet, bags, and map become fullscreen touch panels in
  the control deck.

### 5. Touch mapping: gestures in the world square, taps in the deck

The phone client overlays gestures **only inside the world square** (top
1080x1080 region of the video); the control deck below is pure
tap-passthrough so every addon button is pressed by simply tapping it:

| Region | Gesture | Injected input |
|---|---|---|
| world square, bottom-left corner | virtual joystick (client-rendered, semi-transparent) | WASD key holds (8-way) |
| world square, elsewhere | one-finger drag | hold RMB + proportional move (camera), release on lift |
| world square | tap (below drag threshold) | left click at position (target/interact) |
| world square | long-press | right click at position |
| world square | two-finger pinch | mouse wheel (camera zoom) |
| control deck (anywhere) | tap | left click at position |
| control deck | long-press | right click at position |
| client edge rail (floating, client-rendered) | tap | quick keys: Space (jump), Esc, chat keyboard (Aa), M, B |

Consequences for the addon: the control deck owns all critical UI; anything
the addon places inside the world square (target frame, buffs at the very
top) must be tap/long-press operable only — and left-edge frames must end
above the joystick's capture zone (bottom-left 45% of the square; budget
comments in `Pet.lua`/`ActionBars.lua`). Consequence for the client: it
computes the world-square rect from the live video geometry (the element's
intrinsic dimensions; the `hello` geometry until the first frame) after
object-fit letterboxing (`square height = (worldViewportPx / 1080) × video
content width, anchored top` — width times height fraction, since the hello
carries no viewport field and the client's World viewport setting stands in
for the addon's `/wm viewport`).

## Repository layout

The repo root is the Go module (`github.com/LcStylee/Wow-mobile`, `go.mod` at
the root); `go build ./server/cmd/wowstreamd` from the root produces the
single distributable exe. `client/` and the addon variants (`addon/WowMobile/`
and `addon/WowMobile_Vanilla/`) stay the canonical sources on disk and are
additionally embedded into the binary by the root `embed.go` (`go:embed`): the
signal server serves the PWA from the embedded FS (`--client-dir` overrides
with a disk directory for development) and the first-run wizard
(`server/internal/install`) installs the addon variant matching the detected
client from it, so the released `wowstreamd.exe` is fully self-contained.

| Path | What | Validated by |
|---|---|---|
| `addon/WowMobile/` | WoW Classic Era addon (Lua, `## Interface: 11507`); embedded, wizard-installed on Classic Era clients | luaparse syntax check (CI) + critic review |
| `addon/WowMobile_Vanilla/` | 1.12 port of the addon (Lua 5.0, `## Interface: 11200`); embedded, wizard-installed on 1.12 private-server clients (which the Classic Era addon cannot load on) | luaparse syntax check (CI) + critic review |
| `server/` | Go streaming host for Windows + first-run wizard (console text flow, or native dialogs in the windowed GUI mode of the `-H=windowsgui` release build) | `GOOS=windows go vet ./...`, `go test ./...` (portable packages), CI |
| `client/` | Zero-build PWA touch client; embedded, served by the exe | `node --test tests/` (CI), critic review |
| `client/host/` | Host status dashboard (QR, checklist, quit); embedded separately (`HostFS`) and served **loopback-only** at `/host` | `node --check` (CI), loopback-enforcement unit tests |
| `protocol/` | Data-channel wire protocol spec | shared contract for server + client |
| `e2e/` | Playwright pipeline gate: `wowstreamd --capture test` streamed into a real browser; asserts frames decode, pixels are not black, input round-trips | `npm test` in `e2e/` (CI) |
| `embed.go` | Root embed package (`ClientFS`, `HostFS`, `AddonFS`, `VanillaAddonFS`) | `embed_test.go` drift guard: embedded trees == disk trees byte-for-byte |
| `installer/` | NSIS script producing `WowMobile-Setup.exe` (Start Menu/Desktop shortcuts, uninstaller) | `makensis` compile check (CI) |
| `assets/` | App icon (`wowmobile.ico` + PNG source + generator); baked into the exe via the committed `rsrc_windows_amd64.syso` | — |
| `.github/workflows/` | CI on every push/PR; tag-triggered release of `WowMobile-Setup.exe` + `wowstreamd.exe` | workflow runs on GitHub Actions |
| `docs/` | This document, setup guide, touch UI coverage matrix | — |

## Trust & security model

- Signaling server binds to LAN, requires a pairing token (printed + QR at
  startup); WebRTC media is DTLS-SRTP encrypted end-to-end.
- The host dashboard (`/host`: pairing token QR, status, quit control) is
  **loopback-only**: every `/host` route verifies both the TCP peer address
  and the `Host` header are loopback (`127.0.0.1`, `::1`, or `localhost`) and
  answers 403 otherwise, so the token never reaches other LAN devices through
  it — and, under `--no-tls`, a DNS-rebinding page cannot become same-origin
  with the dashboard either.
- The host injects input only into the WoW window and only while a paired,
  authenticated session is connected.
