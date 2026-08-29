# WoW Mobile — Setup Guide

End-to-end setup: from a stock WoW Classic Era install to playing on your
phone. Every command, path, and flag below matches the code in this repo.

Prerequisites (see the [README](../README.md#requirements) for details):
Windows 10+ gaming PC, WoW Classic Era, a phone on the same Wi-Fi (5 GHz
strongly recommended).

## Easy setup

1. **Download `WowMobile-Setup.exe`** from
   [GitHub Releases](https://github.com/LcStylee/Wow-mobile/releases) onto the
   gaming PC and run it: a normal Windows installer — welcome page, choose the
   folder (default `C:\Program Files\WoW Mobile`), optional Desktop shortcut,
   done. It installs a single self-contained app: the phone client and both
   addon variants (Classic Era and the 1.12 port) are embedded inside
   `wowstreamd.exe`, and an uninstaller appears in Add/Remove Programs.

   *Windows SmartScreen:* the installer is unsigned, so SmartScreen may warn
   about an unknown publisher. Click **More info → Run anyway** (or build from
   source, [below](#manual-setup-advanced)).
2. **Launch WoW Mobile** from the Start Menu (or tick "Launch WoW Mobile" on
   the installer's finish page). There is **no terminal window** — setup
   happens in ordinary Windows dialogs, and when it finishes your browser
   opens the **status dashboard** with a big QR code. Allow the app through
   Windows Defender Firewall (**private networks**) when prompted, or the
   phone can't reach port 8443.
3. **Scan the QR code** on the dashboard with your phone — see
   [Pair the phone](#pair-the-phone).

While WoW Mobile is running you'll find its icon in the **system tray**
(notification area): left-click opens the dashboard, right-click offers
**Open dashboard**, **Choose game…** and **Quit**. **Choose game…** shows the
exact restart command for picking a different WoW install (the picker runs
during setup, so switching means a restart with `--choose-game` — see
[step 1](#what-the-setup-does)); the dashboard carries the same hint. The
dashboard's Quit button does the same as the tray's — a clean stop that
releases every held key.

*Portable alternative:* the same Releases page also carries the bare
`wowstreamd.exe`. Double-clicking it gives the identical dialogs-and-dashboard
experience with nothing installed; running it **from a terminal** gives the
classic text wizard, banner, and ASCII QR instead (`--console` and `--gui`
force either mode). One Windows quirk when launched plainly from
cmd/PowerShell: the shell does not wait for the windowed exe and keeps
reading the shared console's input itself, so setup prompts take their
defaults there (a printed note says so); pass `--console` and the interactive
wizard opens in a console window of its own.

### What the setup does

Setup runs on every start, before streaming; each step is idempotent and
near-instant when already satisfied. In a terminal it prints the classic
checklist; in windowed mode the same checklist appears on the dashboard:

```
[1/5] World of Warcraft ..... chosen: C:\...\_classic_era_\WowClassic.exe (Classic Era) — from 4 found
[2/5] WowMobile addon ....... installed (38 files, up to date)
[3/5] Portrait resolution ... Config.wtf OK (1080x1920 windowed)
[4/5] FFmpeg ................ found: h264_nvenc available
[5/5] Game running .......... window found
```

1. **Scans for game installs and lets you choose.** A choice you already
   confirmed (remembered in `%APPDATA%\wowstreamd\config.json`) is reused
   silently — an install that an older WoW Mobile version auto-detected
   without asking does not count: after upgrading, it only becomes the
   picker's pre-selected default and you confirm it once. Otherwise the
   wizard **scans** the Blizzard registry key, the well-known locations, and
   every Battle.net product folder (`_classic_era_`, `_classic_`, `_retail_`,
   and their `_ptr_`/`_beta_` variants) under each `World of Warcraft` folder
   at the root of a fixed drive or in either Program Files folder — then
   **you pick**. Machines with several WoW installs are first-class: the
   picker lists the installs found with their detected versions
   ("WoW Classic Era (1.15) — C:\…\_classic_era_",
   "Vanilla 1.12 private client — D:\Games\TurtleWoW",
   "Retail 11.x — … (stream only: touch UI addon unavailable)") and never
   auto-proceeds — even a single find asks "use it?" first. Windowed mode
   shows the list as a native dialog with **Browse for a folder…** and **Pick
   the game program (.exe)…** escape hatches (private servers: any exe) — the
   dialog shows up to 8 installs; any beyond that are reachable through
   **Browse for a folder…**. A terminal shows a numbered menu listing every
   install (`B` to paste a path, `X` to cancel, Enter takes the first entry).
   `--choose-game` re-opens the picker over a remembered choice;
   `--wow-dir <folder>` / `--game-exe <program>` bypass it entirely, and
   under `--yes` (non-interactive) a sole find is used while several installs
   abort with a list and a request for `--game-exe` — it never guesses
   between installs. The chosen executable is recorded and every later step
   derives from its folder.
2. **Installs/updates the WowMobile addon** from the copy embedded in the exe
   into `<game>\Interface\AddOns\WowMobile`, writing only files that are
   missing or changed. Nothing else in `AddOns` is ever touched. (Your addon
   settings are safe — they live in `WTF\`, not in the addon folder.) On a
   1.12-era private-server client the wizard installs `WowMobile_Vanilla`
   (the 1.12/Lua 5.0 port of the same touch UI) instead — see
   [Private servers](#private-servers-112-clients). If you chose a "stream
   only" install (a client that is neither Classic Era 1.15 nor 1.12 —
   retail, an expansion client), this step is skipped: no addon variant can
   load there, so nothing is copied into its `AddOns` folder.
3. **Sets the portrait window** in `<game>\WTF\Config.wtf`
   (`SET gxWindow "1"`, `SET gxMaximize "0"`, and
   `SET gxWindowedResolution "1080x1920"` — following `--resolution`; 1.12
   clients get `SET gxResolution` instead), after writing a `Config.wtf.bak`
   backup and preserving every other line. WoW rewrites this file on exit, so
   if the game is running the wizard offers to wait for it to close first.
4. **Finds FFmpeg** — `--ffmpeg` flag, `PATH`, remembered path, or winget's
   package directory. If absent, it offers to run
   `winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements`
   (hidden, no console flash — in windowed mode the install runs in the
   background with no progress window, and the dashboard opens once setup
   completes) and remembers where the binary landed (no `PATH` restart
   needed). On completion setup continues automatically.
5. **Checks the game is running** — if no window matches `--window-title`, it
   offers to launch the recorded game executable and waits while you log in.

Every prompt has a default; `--yes` accepts all defaults non-interactively,
and `--skip-setup` skips the wizard entirely (the pre-wizard behavior). When
stdin is not a terminal — including a console merely shared with the
launching shell, whose own pending read would swallow your typing — the
console wizard never blocks on a prompt: it takes safe defaults or fails
with a clear message (`--console` gets an interactive console of its own);
the windowed mode never reads stdin at all.

The first run enables the addon: at WoW's character select, open **AddOns**
and make sure **WoW Mobile** is checked — **WoW Mobile (Vanilla)** on a 1.12
private-server client — (once; if flagged out-of-date after a game patch,
check **Load out of date AddOns**).

### The host dashboard

Whenever the server is running, `https://127.0.0.1:8443/host/` (also printed
in the terminal banner; opened automatically in windowed mode) shows a dark
status page, served only to the PC itself — other devices on the network get
`403`:

- the **setup checklist** with live states,
- a **large QR code** of the pairing URL plus the URL itself with a **Copy**
  button,
- live status: chosen encoder, phone connected (with its address and browser),
  and stream stats (kbps / fps / encode ms) while a phone is streaming,
- a **Quit** button (graceful shutdown, same as the tray menu / Ctrl+C).

The page reuses the self-signed certificate, so your browser shows the usual
warning once — proceed, it is your own machine.

The dashboard needs a loopback-reachable bind (the default `--addr :8443` or
any wildcard/loopback bind qualifies). If you point `--addr` at one specific
non-loopback IP, no loopback listener exists: wowstreamd then logs a warning
and skips the browser auto-open instead of advertising an unreachable URL
(the tray icon still offers Quit).

## Private servers (1.12 clients)

WoW Mobile also hosts 1.12-era private-server clients (launched through
`Wow.exe` or `VanillaFixes.exe`, or any custom exe you pick):

- **Selecting the game:** the install picker lists private-server folders it
  can see, and its **Browse for a folder…** hatch accepts any folder
  containing `WowClassic.exe`, `VanillaFixes.exe`, or `Wow.exe` (preference
  in that order, case-insensitive) — or use the "Pick the game program (.exe)
  …" dialog / paste the exe path in the terminal / pass
  `--game-exe C:\path\to\anything.exe`. The recorded exe is what step 5
  launches; addon dir and `Config.wtf` are looked up next to it.
- **Client type — detected automatically:** the wizard first reads the
  version stamp embedded in the exe itself (official clients carry it:
  `1.12.x` means a vanilla client, `1.13`+ the Classic-Era lineage), which
  survives any rename. Only when the stamp is missing or stripped do the
  name/path heuristics apply (`WowClassic.exe` or a `_classic_era_` path
  means Classic Era; `Wow.exe`/`VanillaFixes.exe` outside a `_classic_era_`
  tree means a 1.12 client), and only when those are also inconclusive does
  the wizard ask ("Is this a Classic Era (1.15) client?"). Under `--yes` it
  does **not** guess — it assumes Classic Era only when `_classic_era_`
  appears in the path, otherwise a 1.12 client, and logs the choice.
- **Config.wtf:** 1.12 clients predate `gxWindowedResolution`, so the wizard
  writes the era-correct `SET gxResolution "1080x1920"` (plus
  `gxWindow`/`gxMaximize`), with the same backup and never-while-running
  rules.
- **A dedicated 1.12 addon is installed:** the Classic Era addon targets the
  1.15 API (Interface `11507`, `C_GossipInfo`, …) and cannot load on 1.12, so
  the wizard installs `WowMobile_Vanilla` — the 1.12 (Lua 5.0, Interface
  `11200`) port of the same touch UI, from `addon/WowMobile_Vanilla/` — into
  `<game>\Interface\AddOns\WowMobile_Vanilla` instead. Enable **WoW Mobile
  (Vanilla)** once at character select; the `/wm` commands (viewport, scale,
  settings) work the same as on Classic Era. Streaming, capture, touch input
  injection, the dashboard, and the phone client behave identically either
  way. The dashboard shows a persistent note reminding you which variant was
  installed.
- **Window title:** the default `--window-title "World of Warcraft"` matches
  1.12 clients too; if your server renames the window, `--window-title` is
  the escape hatch.

### Pair the phone

The QR code is on the [host dashboard](#the-host-dashboard) (windowed mode
opens it automatically); in a terminal the server prints the same pairing
URLs and an ASCII QR code:

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
and make sure **WoW Mobile** is checked. (On a 1.12 private-server client copy
`<repo>\addon\WowMobile_Vanilla` to `...\Interface\AddOns\WowMobile_Vanilla`
instead and enable **WoW Mobile (Vanilla)**.)

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
| `--wow-dir` | scan & choose | Game directory — `_classic_era_`, its parent, or any folder containing a known game exe; bypasses the wizard's install picker |
| `--game-exe` | scan & choose | Exact game executable to record and launch (private servers, any name); overrides `--wow-dir` and bypasses the picker |
| `--choose-game` | off | Show the install picker at startup (the WoW installs found, with detected versions) even when a game is already remembered |
| `--yes` | off | Wizard: accept every default without prompting (non-interactive). One found install is used; several abort with a list — pass `--game-exe` to pick |
| `--skip-setup` | off | Skip the first-run wizard entirely |
| `--console` | auto | Force console mode: the interactive text wizard, never dialogs; from a shell it opens its own console window so prompts are not raced by the shell (Windows) |
| `--gui` | auto | Force windowed mode (dialogs + dashboard + tray) even from a terminal (Windows) |
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

What the touch UI covers in play (full per-system matrix:
[COVERAGE.md](COVERAGE.md)):

- **The deck** holds the paged action bars, a second bar, the player/target
  frames (tap = target, long-press = the unit menu), pet bar, cast bar, XP bar,
  chat strip, and a bottom menu row. On Classic Era the row is
  Spells / Talents / Char / Quests / Social / Raid / Map / Config plus a bags
  button; on the 1.12 port the same panels fit six buttons — **long-press**
  "Char" for Social and "Quests" for Raid, as the two-line labels show.
- **NPC and world interactions open by themselves** as full-width touch sheets
  the moment you interact: gossip and quests, merchants (Buy / Sell / Buyback
  tabs + repair-all), trainers, looting (Take all; master-loot picker when you
  are the master looter), need/greed roll rows, the auction house
  (Browse / Sell / My Auctions), professions and enchanting, mail
  (Inbox with Collect-all / Send), the bank, player trades, the hunter stable,
  and readable books, plaques and letters. Closing a sheet (the X) walks away
  from the NPC cleanly.
- **Moving items is long-press based:** long-press a bag item, equipped piece,
  spell or action to pick it up onto the cursor — a carry bar appears above the
  deck with a big Cancel, valid drop targets glow green, and a tap places or
  swaps. Stacks first ask "Take how many?" with a − / + / Max / All stepper.
  The same gesture feeds the auction sell slot, mail attachments and trade
  slots (their sheets also embed your bag list, so you never have to leave
  them). Money amounts are tap steppers, and anything that spends money or
  destroys something asks for a confirming second tap. On Classic Era, item
  moves are blocked during combat (a notice says so); the 1.12 client has no
  such restriction.
- **Typing** (chat, auction search, mail recipient/subject, add-friend) goes
  through the phone keyboard: tap the field, then open the keyboard with the
  edge rail's **Aa** key.
- A few rare flows keep Blizzard's own windows, enlarged for touch instead of
  rebuilt: the flight map, tabard designer, petitions, macro and key-binding
  editors, the BG scoreboard, and the Esc game menu.

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
| Windows SmartScreen blocks `WowMobile-Setup.exe` / `wowstreamd.exe` | The release binaries are unsigned. Click **More info → Run anyway**, or build from source ([step 4](#4-build-and-run-wowstreamd)). |
| Nothing seems to happen after launching / where did it go? | WoW Mobile runs windowed with no terminal: look for the **tray icon** (left-click opens the dashboard) and the dashboard tab at `https://127.0.0.1:8443/host/`. Quit via the tray menu or the dashboard's **Quit** button. `--console` from a terminal gets you the full text log. |
| Wizard: `[1/5] World of Warcraft ..... not found automatically` | Non-standard install location the scan can't see. Use the **folder picker** that appears (the `World of Warcraft` or `_classic_era_` folder both work, as does any folder with `Wow.exe`/`VanillaFixes.exe`), choose "Pick the game program (.exe)…", or pass `--wow-dir`/`--game-exe` — the choice is remembered in `%APPDATA%\wowstreamd\config.json`. |
| WoW Mobile is set up against the **wrong WoW install** (several on this PC) | Restart with `--choose-game`: the picker lists the installs found (with detected versions) and your new choice replaces the remembered one. The tray icon's **Choose game…** item shows the exact command; `--game-exe`/`--wow-dir` pin an install permanently. |
| Dashboard shows 403 / unreachable from another device | By design: `/host` is served **only to the PC itself** (it contains the pairing token). Open it on the gaming PC; phones use the pairing URL/QR instead. |
| Addon step says `... (WowMobile_Vanilla, 1.12 port)` | Normal on a 1.12 private-server client: the wizard installed the 1.12 port of the addon instead of the Classic Era one. Enable **WoW Mobile (Vanilla)** at character select — see [Private servers](#private-servers-112-clients). |
| Wizard: winget is not available | The wizard prints manual instructions: install FFmpeg from [ffmpeg.org](https://ffmpeg.org/download.html) or [gyan.dev](https://www.gyan.dev/ffmpeg/builds/), then add its `bin` to `PATH` or pass `--ffmpeg C:\path\to\ffmpeg.exe`. |
| Wizard: Config.wtf changes not applied | WoW was running (it rewrites `Config.wtf` on exit). Close WoW, restart `wowstreamd`, and accept the update — the original is kept as `Config.wtf.bak`. |
| Black or frozen video, connection fine | The WoW window is minimized or on a locked/secure desktop — capture needs it visible. Restore the window and leave it on-screen. If it just launched or moved monitors, the encoder restarts within a few seconds. |
| `no visible window with "World of Warcraft" in its title` at startup | WoW isn't running, is minimized, or has a different title. Start WoW first (windowed, not minimized) or let wizard step 5 launch it. If the title truly differs, pass the actual text via `--window-title`. |
| Phone can't reach the URL at all | Phone on cellular or a guest/isolated SSID, or the firewall is blocking port 8443. Same Wi-Fi network, and allow `wowstreamd.exe` for private networks in Windows Defender Firewall. |
| High latency or stutter | Check the HUD: high **ms** = network (move to 5 GHz, get the PC on Ethernet, reduce Wi-Fi congestion); high **enc** = encoder (use `--encoder nvenc`/`amf`/`qsv` instead of software x264). Lowering quality to 4 Mbps in settings helps on weak links. The dashboard's **Encoder** line (or console log `encoder auto-selected encoder=x264`) showing software x264 means no hardware encoder was found in your FFmpeg build. |
| Certificate warning on every connect | Normal exactly once per phone. If it reappears: the PC's LAN IP changed (DHCP — the cert regenerates to cover it; re-accept once, or give the PC a static IP), the server logged a cert-persistence warning, or the 90-day cert renewed. |
| `Pairing token rejected` | The server generates a fresh token each run unless you pass `--token`. Re-scan the current QR code, or pin a token: `.\wowstreamd.exe --token mysecret`. |
| `Session replaced by another device` | Only one phone at a time; pairing a second device disconnects the first by design. Reconnect from the device you want. |
| Addon not loading / stock UI shows | The folder must be exactly `Interface\AddOns\WowMobile` with `WowMobile.toc` directly inside (`Interface\AddOns\WowMobile_Vanilla` with `WowMobile_Vanilla.toc` on 1.12; no doubled `WowMobile\WowMobile` nesting) — the wizard's step 2 guarantees this. Enable it at character select; if flagged out-of-date after a game patch, check **Load out of date AddOns**. |
| UI misaligned, taps land in the wrong place | `gxWindowedResolution` and `--resolution` disagree, or the window got resized. They must match exactly; re-run the wizard (it fixes `Config.wtf` to match `--resolution`) and restart both WoW and the server. |
| Taps near the world/deck boundary move the character or drag the camera | The addon's `/wm viewport` and the phone's **World viewport** setting disagree (both default 1080). Set them to the same number — [step 5](#5-first-run-in-game). |
| No sound | Audio is opt-in: install screen-capture-recorder, run with `--audio`, and unmute via the HUD **Snd** button. Verify the device exists: `ffmpeg -list_devices true -f dshow -i dummy` should list `virtual-audio-capturer`. |
| PWA won't install / no fullscreen | Installation requires HTTPS — don't use `--no-tls`. On iOS only Safari can Add to Home Screen; on Android use Chrome. |
