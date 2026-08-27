# WoW Mobile — Setup Guide

End-to-end setup: from a stock WoW Classic Era install to playing on your
phone. Every command, path, and flag below matches the code in this repo.

Prerequisites (see the [README](../README.md#requirements) for details):
Windows 10+ gaming PC, WoW Classic Era, a phone on the same Wi-Fi (5 GHz
strongly recommended).

## Easy setup

1. **Download** the latest `wowstreamd.exe` from
   [GitHub Releases](https://github.com/LcStylee/Wow-mobile/releases) onto the
   gaming PC. It is a single self-contained file — the phone client and the
   WowMobile addon are embedded inside it.
2. **Double-click `wowstreamd.exe`** and follow the first-run wizard.

   *Windows SmartScreen:* the binary is unsigned, so SmartScreen may warn
   about an unknown publisher. Click **More info → Run anyway** (or build from
   source, [below](#manual-setup-advanced)). Also allow it through Windows
   Defender Firewall (**private networks**) when prompted, or the phone can't
   reach port 8443.
3. **Scan the QR code** the server prints with your phone — see
   [Pair the phone](#pair-the-phone).

### What the wizard does

The wizard runs on every start, before streaming; each step is idempotent and
near-instant when already satisfied:

```
[1/5] WoW Classic Era ....... found: C:\Program Files (x86)\World of Warcraft\_classic_era_
[2/5] WowMobile addon ....... installed (24 files, up to date)
[3/5] Portrait resolution ... Config.wtf OK (1080x1920 windowed)
[4/5] FFmpeg ................ found: h264_nvenc available
[5/5] Game running .......... window found
```

1. **Locates WoW Classic Era** — remembered path
   (`%APPDATA%\wowstreamd\config.json`), then the Blizzard registry key, then
   well-known paths on fixed drives. If none work it asks you to paste the
   path (or pass `--wow-dir`).
2. **Installs/updates the WowMobile addon** from the copy embedded in the exe
   into `<wow>\Interface\AddOns\WowMobile`, writing only files that are
   missing or changed. Nothing else in `AddOns` is ever touched. (Your addon
   settings are safe — they live in `WTF\`, not in the addon folder.)
3. **Sets the portrait window** in `<wow>\WTF\Config.wtf`
   (`SET gxWindow "1"`, `SET gxMaximize "0"`,
   `SET gxWindowedResolution "1080x1920"` — following `--resolution`), after
   writing a `Config.wtf.bak` backup and preserving every other line. WoW
   rewrites this file on exit, so if the game is running the wizard offers to
   wait for it to close first.
4. **Finds FFmpeg** — `--ffmpeg` flag, `PATH`, remembered path, or winget's
   package directory. If absent, it offers to run
   `winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements`
   and remembers where the binary landed (no `PATH` restart needed).
5. **Checks the game is running** — if no window matches `--window-title`, it
   offers to launch `<wow>\WowClassic.exe` and waits while you log in.

Every prompt has a default; `--yes` accepts all defaults non-interactively,
and `--skip-setup` skips the wizard entirely (the pre-wizard behavior). When
stdin is not a terminal the wizard never blocks on a prompt — it takes safe
defaults or fails with a clear message.

The first run enables the addon: at WoW's character select, open **AddOns**
and make sure **WoW Mobile** is checked (once; if flagged out-of-date after a
game patch, check **Load out of date AddOns**).

### Pair the phone

On startup the server prints pairing URLs and a QR code:

```
wowstreamd ready — open on your phone (same Wi-Fi):
  https://192.168.1.20:8443/?token=3f9c...

Scan to pair:
  [QR code]
```

1. On the phone — same Wi-Fi network — scan the QR code or type the printed
   URL. The token rides in the URL, so scanning pairs in one step; opening the
   bare URL instead shows a token entry screen.
2. **Accept the certificate warning.** The server uses a self-signed HTTPS
   certificate (Safari: *Show Details → visit this website*; Chrome:
   *Advanced → Proceed*). It is generated once and reused across restarts —
   stored in `%APPDATA%\wowstreamd\` on the PC — so you accept it a single
   time per phone, not per session.
3. **Add to Home Screen** for the real fullscreen experience:
   - **iOS**: Safari → Share → **Add to Home Screen**. (Must be Safari; and do
     this *after* accepting the certificate.)
   - **Android**: Chrome → menu (⋮) → **Add to Home screen** / **Install app**.
4. Open the installed app and **tap to play** — it goes fullscreen, locks
   portrait, keeps the screen awake, and starts streaming. The token is
   remembered on the phone; the pairing screen only reappears if the token
   changes (it's random per server run unless you pin `--token`).

Video starts muted (browser autoplay rules). If you ran with `--audio`, tap
**Snd off** in the HUD to unmute.

## Manual setup (advanced)

Everything the wizard does, by hand — useful for development, unusual
installs, or running with `--skip-setup`.

### 1. Put WoW in a portrait window

WoW must run **windowed** at exactly the resolution `wowstreamd` captures
(default `1080x1920`) so touch coordinates map 1:1 onto the game.

1. **Quit WoW completely** — the game rewrites `Config.wtf` on exit and would
   overwrite your edits.
2. Open this file in a text editor (default install path; your drive letter may
   differ):

   ```
   C:\Program Files (x86)\World of Warcraft\_classic_era_\WTF\Config.wtf
   ```

3. Add these lines — or replace them if a `SET gx...` line already exists:

   ```
   SET gxWindow "1"
   SET gxMaximize "0"
   SET gxWindowedResolution "1080x1920"
   ```

If you later run the server with a different `--resolution`, change
`gxWindowedResolution` to match. `wowstreamd --setup` prints these same
instructions (with your chosen resolution filled in) any time you need them.

The window will be a tall sliver on a landscape monitor — that's expected. You
play on the phone; the PC window just needs to exist, stay visible, and not be
minimized.

### 2. Install the WowMobile addon

Copy the addon folder from this repo into WoW's AddOns directory:

```
copy from:  <repo>\addon\WowMobile
copy to:    C:\Program Files (x86)\World of Warcraft\_classic_era_\Interface\AddOns\WowMobile
```

The result must be `...\Interface\AddOns\WowMobile\WowMobile.toc` — the folder
name `WowMobile` matters. Launch WoW, and at character select open **AddOns**
and make sure **WoW Mobile** is checked.

### 3. Install FFmpeg

`wowstreamd` drives FFmpeg as a subprocess for capture and encoding.

```
winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements
```

(or download from [ffmpeg.org](https://ffmpeg.org/download.html) / a full
build from [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) and add its `bin`
folder to your `PATH`). Verify from a **new** terminal:

```
ffmpeg -version
ffmpeg -hide_banner -encoders | findstr h264
```

The second command should list your hardware encoder (`h264_nvenc`,
`h264_amf`, or `h264_qsv`); `--encoder auto` probes this same list at startup
and picks the best one, falling back to software `libx264`. If FFmpeg can't go
in `PATH`, pass its location with `--ffmpeg C:\path\to\ffmpeg.exe`.

### 4. Build and run wowstreamd

With [Go 1.24+](https://go.dev/dl/) installed, from the repo root (the repo
root is the Go module):

```
go build -o wowstreamd.exe ./server/cmd/wowstreamd
.\wowstreamd.exe
```

To cross-compile from macOS/Linux instead:
`GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -o wowstreamd.exe ./server/cmd/wowstreamd`,
then copy the `.exe` to the PC — it is self-contained: the phone client and
the addon are embedded at build time, so it can be started from anywhere.
During client development, `--client-dir <path>` serves the PWA from disk
instead of the embedded copy.

Start WoW *before* the server (or let wizard step 5 launch it) — with
`--skip-setup` it locates the game window at startup and exits with guidance
if none is found.

The defaults are right for most setups. All flags:

| Flag | Default | Meaning |
|---|---|---|
| `--addr` | `:8443` | Listen address for the HTTPS signaling server |
| `--token` | random per run | Pairing token; pass your own to keep it stable across restarts |
| `--resolution` | `1080x1920` | Capture size; **must equal** the WoW window client size |
| `--fps` | `60` | Capture/encode frame rate (1–240) |
| `--bitrate-kbps` | `8000` | Video bitrate, CBR (500–100000) |
| `--encoder` | `auto` | `auto` \| `nvenc` \| `amf` \| `qsv` \| `x264` |
| `--window-title` | `World of Warcraft` | Substring of the game window title to capture |
| `--client-dir` | embedded client | Serve the phone client PWA from a disk directory (development) |
| `--wow-dir` | auto-detect | WoW Classic Era directory (the one containing `WowClassic.exe`); skips wizard detection |
| `--yes` | off | Wizard: accept every default without prompting (non-interactive) |
| `--skip-setup` | off | Skip the first-run wizard entirely |
| `--no-tls` | off | Plain HTTP instead of HTTPS (breaks PWA install; debugging only) |
| `--ffmpeg` | find in `PATH` | Path to the ffmpeg executable |
| `--audio` | off | Desktop audio via the `virtual-audio-capturer` DirectShow device (requires [screen-capture-recorder](https://github.com/rdp/screen-capture-recorder-to-video-windows-free)) |
| `--setup` | — | Print the Config.wtf/addon instructions from step 1–2 and exit |
| `--version` | — | Print the wowstreamd version and exit |

Then pair the phone exactly as in [Pair the phone](#pair-the-phone).

### 5. First run in-game

With the addon enabled you'll see the world in a square up top and the control
deck below. Everything in the deck is tap-and-go; inside the world square use
the joystick (bottom-left) to move, drag to look, tap to target, long-press to
right-click, pinch to zoom.

Type `/wm` in chat (phone quick rail: **Aa** opens the keyboard) for the
addon's commands:

```
/wm viewport <px>   — world-square height in design px (1080 = full-width square)
/wm scale <0.64..1.0> — UI scale override (mainly affects Blizzard text size)
/wm settings        — open the touch settings panel
/wm reset           — restore defaults
/wm reload          — reload the UI
```

If your phone is taller or shorter than 9:19.5, nudge `/wm viewport` until the
deck fills your thumb zone comfortably — the bounds are printed by `/wm`. The
addon clamps out-of-range values and prints the height it actually applied
(`world viewport height set to <px>`).
**Then enter that printed number on the phone** (HUD **Set** → *World
viewport*) — the printed value, not what you typed, is what the addon uses:
the stream carries no viewport information, so the client splits its gesture
zones (joystick and camera drag vs. tap-through deck) by this setting. If the
two values disagree, taps near the world/deck boundary start the joystick or
drag the camera instead of pressing buttons. One trade-off to know: the
joystick claims the bottom-left 45% of the world region, so heights well below
1080 bring that zone up toward the lowest stance/pet buttons.

On the phone, **Set** in the HUD opens client settings: camera sensitivity,
joystick size, world viewport (keep equal to `/wm viewport`), stream quality
(Auto/4/8/16 Mbps — applies live), and the quick rail toggle.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Windows SmartScreen blocks `wowstreamd.exe` | The release binary is unsigned. Click **More info → Run anyway**, or build from source ([step 4](#4-build-and-run-wowstreamd)). |
| Wizard: `[1/5] WoW Classic Era ....... not found automatically` | Non-standard install location. Paste the full path to the `_classic_era_` folder (the one containing `WowClassic.exe`) at the prompt, or pass it with `--wow-dir` — it is remembered in `%APPDATA%\wowstreamd\config.json`. |
| Wizard: winget is not available | The wizard prints manual instructions: install FFmpeg from [ffmpeg.org](https://ffmpeg.org/download.html) or [gyan.dev](https://www.gyan.dev/ffmpeg/builds/), then add its `bin` to `PATH` or pass `--ffmpeg C:\path\to\ffmpeg.exe`. |
| Wizard: Config.wtf changes not applied | WoW was running (it rewrites `Config.wtf` on exit). Close WoW, restart `wowstreamd`, and accept the update — the original is kept as `Config.wtf.bak`. |
| Black or frozen video, connection fine | The WoW window is minimized or on a locked/secure desktop — capture needs it visible. Restore the window and leave it on-screen. If it just launched or moved monitors, the encoder restarts within a few seconds. |
| `no visible window with "World of Warcraft" in its title` at startup | WoW isn't running, is minimized, or has a different title. Start WoW first (windowed, not minimized) or let wizard step 5 launch it. If the title truly differs, pass the actual text via `--window-title`. |
| Phone can't reach the URL at all | Phone on cellular or a guest/isolated SSID, or the firewall is blocking port 8443. Same Wi-Fi network, and allow `wowstreamd.exe` for private networks in Windows Defender Firewall. |
| High latency or stutter | Check the HUD: high **ms** = network (move to 5 GHz, get the PC on Ethernet, reduce Wi-Fi congestion); high **enc** = encoder (use `--encoder nvenc`/`amf`/`qsv` instead of software x264). Lowering quality to 4 Mbps in settings helps on weak links. Console log line `encoder auto-selected encoder=x264` means no hardware encoder was found in your FFmpeg build. |
| Certificate warning on every connect | Normal exactly once per phone. If it reappears: the PC's LAN IP changed (DHCP — the cert regenerates to cover it; re-accept once, or give the PC a static IP), the server logged a cert-persistence warning, or the 90-day cert renewed. |
| `Pairing token rejected` | The server generates a fresh token each run unless you pass `--token`. Re-scan the current QR code, or pin a token: `.\wowstreamd.exe --token mysecret`. |
| `Session replaced by another device` | Only one phone at a time; pairing a second device disconnects the first by design. Reconnect from the device you want. |
| Addon not loading / stock UI shows | The folder must be exactly `Interface\AddOns\WowMobile` with `WowMobile.toc` directly inside (no doubled `WowMobile\WowMobile` nesting) — the wizard's step 2 guarantees this. Enable it at character select; if flagged out-of-date after a game patch, check **Load out of date AddOns**. |
| UI misaligned, taps land in the wrong place | `gxWindowedResolution` and `--resolution` disagree, or the window got resized. They must match exactly; re-run the wizard (it fixes `Config.wtf` to match `--resolution`) and restart both WoW and the server. |
| Taps near the world/deck boundary move the character or drag the camera | The addon's `/wm viewport` and the phone's **World viewport** setting disagree (both default 1080). Set them to the same number — [step 5](#5-first-run-in-game). |
| No sound | Audio is opt-in: install screen-capture-recorder, run with `--audio`, and unmute via the HUD **Snd** button. Verify the device exists: `ffmpeg -list_devices true -f dshow -i dummy` should list `virtual-audio-capturer`. |
| PWA won't install / no fullscreen | Installation requires HTTPS — don't use `--no-tls`. On iOS only Safari can Add to Home Screen; on Android use Chrome. |
