# WoW Mobile

Play **your own World of Warcraft Classic Era** on your phone — streamed live from
your Windows gaming PC, with the entire UI rebuilt for portrait touch.

Your PC runs the game in a portrait 1080x1920 window. The `WowMobile` addon
reshapes the interface into a phone layout: the 3D world in a square viewport up
top, and a "control deck" of thumb-sized action bars, unit frames, bags, and
panels below. `wowstreamd` captures that window with FFmpeg, streams it over
WebRTC on your LAN, and injects your touches back into the game as ordinary
mouse and keyboard input. The phone side is a zero-install web app you add to
your home screen.

```
PC:    WoW Classic (portrait window) + WowMobile addon
       └─ wowstreamd: FFmpeg capture → H.264 → WebRTC ⇄ touch input → SendInput
Phone: browser PWA — fullscreen video + gesture layer (joystick, camera drag, taps)
```

The full picture — component boundaries, the portrait/square rationale, the
encoder pipeline, and the touch-mapping table — is in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The client⇄server wire format is
specified in [protocol/PROTOCOL.md](protocol/PROTOCOL.md).

## Features

- **Portrait touch UI, not a shrunken desktop.** The addon anchors the 3D world
  to a 1080x1080 square and rebuilds everything else in a bottom control deck:
  large `SecureActionButtonTemplate` action bars, unit frames, cast bar, XP bar,
  minimap, chat, and fullscreen touch panels for spellbook, character sheet,
  quest log, talents, bags, and the world map. NPC dialogue (gossip, quests,
  merchants, trainers) opens as full-width bottom sheets with big touch targets.
- **Low-latency WebRTC streaming.** Zero-copy `ddagrab` desktop-duplication
  capture into `h264_nvenc` on NVIDIA GPUs (frames never leave the GPU before
  encode); automatic fallback chain to AMD AMF, Intel QSV, or software x264 via
  `gdigrab`. CBR, no B-frames, 2 s GOP with on-demand IDR recovery.
- **Touch controls tuned for WoW.** Virtual joystick → WASD movement, one-finger
  world drag → right-mouse camera, tap to target/interact, long-press to
  right-click, pinch to zoom, plus a floating quick rail (Space / Esc / chat /
  Map / Bags) and an on-screen chat keyboard. Below the world square, every
  addon button is simply tapped.
- **Installable PWA client.** Add to Home Screen, fullscreen with portrait lock,
  screen wake lock, live HUD (RTT, bitrate, fps, encode time), on-the-fly
  quality switching (4/8/16 Mbps), and automatic reconnect with backoff after
  Wi-Fi blips.
- **Optional game audio.** Opt-in low-delay Opus desktop-audio capture
  (`--audio`, requires the screen-capture-recorder loopback device).
- **Safe by construction.** LAN-only pairing with a random 128-bit token
  (printed + QR at startup), HTTPS with a persisted self-signed certificate,
  DTLS-SRTP encrypted media, one session at a time, and a dead-man switch: any
  disconnect, backgrounded phone, or 3 s input silence releases every held key
  and button — a pocketed phone can never leave you auto-running.

## Quickstart

1. Set WoW Classic Era to a windowed 1080x1920 portrait window
   (`wowstreamd --setup` prints the exact `Config.wtf` lines).
2. Copy `addon/WowMobile/` into WoW's `Interface\AddOns\` folder and enable it.
3. Install [FFmpeg](https://ffmpeg.org/download.html) and make sure `ffmpeg` is
   in your `PATH`.
4. Build and start the host from the repo root:
   `cd server && go build -o ..\wowstreamd.exe .\cmd\wowstreamd && cd .. && .\wowstreamd.exe`
5. On your phone (same Wi-Fi), scan the QR code the server prints, accept the
   self-signed certificate, and tap to play.

Full walkthrough with troubleshooting: [docs/SETUP.md](docs/SETUP.md).

## Requirements

- **Windows 10 or later** on the gaming PC (Desktop Duplication capture and
  `SendInput` injection are Windows APIs).
- **FFmpeg in `PATH`** (or point at it with `--ffmpeg`).
- **A hardware H.264 encoder is strongly recommended** — NVIDIA NVENC gets the
  premium zero-copy path; AMF/QSV work; software x264 is the fallback and costs
  CPU and latency.
- **Go 1.24+** to build `wowstreamd` (no prebuilt binaries yet).
- **5 GHz Wi-Fi** (or better) with phone and PC on the same LAN. There is no
  STUN/TURN — this is deliberately LAN-only.
- **WoW Classic Era** (the addon targets Interface `11507`).
- A modern phone browser: Safari 16+ on iOS, Chrome/Edge on Android.

## Latency, honestly

The pipeline is built for **roughly 30–60 ms glass-to-glass** on an uncongested
5 GHz network with NVENC: ~3 ms capture, ~5 ms encode, 5–15 ms network, ~10 ms
phone decode/display. That is the design target, not a guarantee. Expect worse
with software x264 (add one CPU-bound encode), on busy 2.4 GHz Wi-Fi (add
jitter, sometimes a lot), or on older phones. The HUD shows live RTT and server
encode time so you can see exactly where your milliseconds go. It feels great
for questing, dungeons, professions, and the auction house; if you are a
top-parse raider, keep expectations calibrated.

## FAQ

**Is this a mobile WoW client?**
No. WoW runs entirely on *your* PC, on *your* account, rendered by *your* GPU.
The phone is a remote display and touch input device — the same model as Steam
Link or Moonlight, with a UI overhaul on top.

**Is this botting / automation / a hack?**
No. Nothing reads or writes game memory, and nothing plays the game for you.
The server injects plain OS-level mouse and keyboard events via `SendInput`,
and it only does so while your paired phone session is connected. The design is
strictly **one human touch → one input**: a tap becomes one click, a held
joystick becomes held WASD keys, released the instant you lift your finger. The
addon uses only the official addon API within Blizzard's sandbox
(`SecureActionButtonTemplate`, out-of-combat layout, no protected-action
automation).

**Is it allowed?**
Blizzard's Terms of Service govern your account, and you should read them and
decide for yourself. What this project does — streaming your own screen and
relaying your own inputs 1:1 — is the established remote-play category
(Steam Link, Moonlight, GeForce NOW-style local streaming), and the
one-touch-one-input rule exists precisely to keep it there. No warranty is made
about how any third party treats your account.

**Can I play over the internet / on mobile data?**
Not out of the box, and on purpose. The signaling server binds to your LAN,
WebRTC uses host candidates only, and the latency budget assumes a LAN. If you
must, a VPN into your home network (e.g. WireGuard/Tailscale) makes the phone
"local" — latency will follow your tunnel.

**Does sound work?**
Yes, opt-in: run with `--audio` after installing the
[screen-capture-recorder](https://github.com/rdp/screen-capture-recorder-to-video-windows-free)
loopback device (FFmpeg cannot tap WASAPI loopback by itself), then unmute with
the HUD sound button on the phone.

**Why a square world viewport instead of full-portrait 3D?**
Full-portrait 3D would give an absurdly narrow field of view and waste encoder
bitrate on UI. The 1:1 square keeps a sane FoV, cuts world rendering by ~44%,
and leaves the bottom 44% of the screen — natural thumb territory — for pure-2D
controls that cost the encoder almost nothing. The square's height is tunable
per phone (`/wm viewport`, mirrored by the client's **World viewport** setting
in the HUD — set both to the same value, see the
[setup guide](docs/SETUP.md#6-first-run-in-game)).

**Can someone else on my network hijack the stream?**
They would need the pairing token (128 random bits, shown only on your PC), and
media is DTLS-SRTP encrypted. One session at a time: pairing a second device
cleanly replaces the first, never mirrors it.

## Repository layout

| Path | What |
|---|---|
| `addon/WowMobile/` | WoW Classic Era addon (Lua): portrait UI overhaul, control deck, touch panels |
| `server/` | `wowstreamd` — Go streaming host for Windows: capture, WebRTC, input injection, signaling |
| `client/` | Zero-build PWA phone client: video, gesture layer, joystick, HUD, chat keyboard |
| `protocol/` | Binding wire-protocol spec for the client⇄server data channels |
| `docs/` | [Architecture](docs/ARCHITECTURE.md) and [setup guide](docs/SETUP.md) |

## License

[MIT](LICENSE). World of Warcraft is a trademark of Blizzard Entertainment,
Inc. This project is not affiliated with or endorsed by Blizzard.
