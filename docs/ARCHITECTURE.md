# WoW Mobile — Architecture

Play World of Warcraft Classic on a phone by streaming it from your own PC, with a
UI rebuilt for portrait touch. Three components, one repo:

```
┌─────────────────────────── Windows Gaming PC ───────────────────────────┐
│                                                                         │
│  WoW Classic (windowed, 1080x1920 portrait)                             │
│  └─ addon/WowMobile  → portrait touch UI, 1080x1080 world viewport      │
│                                                                         │
│  server/ (wowstreamd.exe, Go)                                           │
│  ├─ capture:  FFmpeg subprocess (ddagrab → h264_nvenc, zero-latency)    │
│  ├─ webrtc:   pion/webrtc — H.264 video track + input data channels     │
│  ├─ input:    SendInput injection (mouse/keyboard) into the WoW window  │
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

### 1. Portrait 1080x1920 with a 1080x1080 world viewport

WoW runs **windowed** at `1080x1920` (set via `Config.wtf`:
`SET gxWindowedResolution "1080x1920"`, or the server's `--setup` helper). The
addon then shrinks the 3D world (`WorldFrame`) to a **1080x1080 square anchored
to the top** of the window. The bottom **1080x840 strip is the "control deck"**:
a pure-2D region owned entirely by the addon (action bars, unit frames, bags,
panels) over a black background.

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
default 1080); the two must be changed together (see SETUP.md §6) or the
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
from the client triggers an encoder restart, whose first frame is a fresh
IDR + SPS/PPS. Intra-refresh was deliberately rejected — a browser (re)joining
mid-stream cannot decode a rolling refresh wavefront at all; it needs a full
IDR, so intra-refresh would break mid-join and PLI recovery outright.

Fallbacks: `gdigrab + libx264 -tune zerolatency` when no NVIDIA GPU;
AMF/QSV selectable via `--encoder`. Target: ≤ 3 ms capture + ~5 ms encode +
~5–15 ms LAN + ~10 ms decode/display ≈ **30–60 ms glass-to-glass on 5 GHz
Wi-Fi**.

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
computes the world-square rect from the `hello` video geometry after
object-fit letterboxing (`square height = (worldViewportPx / 1080) × video
content width, anchored top` — width times height fraction, since the hello
carries no viewport field and the client's World viewport setting stands in
for the addon's `/wm viewport`).

## Repository layout

The repo root is the Go module (`github.com/LcStylee/Wow-mobile`, `go.mod` at
the root); `go build ./server/cmd/wowstreamd` from the root produces the
single distributable exe. `client/` and `addon/WowMobile/` stay the canonical
sources on disk and are additionally embedded into the binary by the root
`embed.go` (`go:embed`): the signal server serves the PWA from the embedded FS
(`--client-dir` overrides with a disk directory for development) and the
first-run wizard (`server/internal/install`) installs the addon from it, so
the released `wowstreamd.exe` is fully self-contained.

| Path | What | Validated by |
|---|---|---|
| `addon/WowMobile/` | WoW Classic Era addon (Lua, `## Interface: 11507`); embedded, wizard-installed | luaparse syntax check (CI) + critic review |
| `server/` | Go streaming host for Windows + first-run wizard | `GOOS=windows go vet ./...`, `go test ./...` (portable packages), CI |
| `client/` | Zero-build PWA touch client; embedded, served by the exe | `node --test tests/` (CI), critic review |
| `protocol/` | Data-channel wire protocol spec | shared contract for server + client |
| `embed.go` | Root embed package (`ClientFS`, `AddonFS`) | `embed_test.go` drift guard: embedded trees == disk trees byte-for-byte |
| `.github/workflows/` | CI on every push/PR; tag-triggered release build of `wowstreamd.exe` | workflow runs on GitHub Actions |
| `docs/` | This document, setup guide | — |

## Trust & security model

- Signaling server binds to LAN, requires a pairing token (printed + QR at
  startup); WebRTC media is DTLS-SRTP encrypted end-to-end.
- The host injects input only into the WoW window and only while a paired,
  authenticated session is connected.
