# The Phone Frame contract (v0.5.0)

Binding for the server (Go), both addons (Lua 5.1 / Lua 5.0), the phone client
(JS), docs and tests. Supersedes the fixed 9:16 "band" of v0.4.x, which becomes
one entry of this contract (`generic-9-16`).

## 1. Idea

The game runs as a **normal widescreen window** at whatever resolution the PC
uses — 4K fullscreen, 1920x1080, or an odd windowed size. The addon confines
the **entire phone UI to a centered portrait "phone frame"** whose aspect is
that of the **phone model the user picks in-game**, draws a **red outline**
around it on the PC screen so the user can arrange their UI inside it, and the
server streams **exactly the interior of that outline**. To the right of the
outline (left if there is no room) the addon shows the **phone selector**: a
searchable list of phone models (20 most-used first, extensible), the PC's
resolution, and the resulting frame size in pixels.

## 2. The phone table (single source of truth)

`phones/phones.json`. `tools/genphones.js` generates, byte-deterministically:

| Target | File |
|---|---|
| Go | `server/internal/phones/phones_gen.go` |
| JS (ES module) | `client/js/phones.js` |
| Lua 5.1 (Classic Era / Forever addon) | `addon/WowMobile/Phones.lua` |
| Lua 5.0 (1.12 addon) | `addon/WowMobile_Vanilla/Phones.lua` |
| Shared test vectors | `phones/contract_vectors.json` |

CI fails if the generated files are stale (`node tools/genphones.js --check`).
Adding a phone is one JSON entry plus a regeneration. Entry fields:
`id, brand, model, year, physW, physH` (native portrait panel px), `dpr`,
`insetTop, insetBottom` (logical px the OS reserves), `popularity`
(1..N = rank in the starting list, `null` = extra), optional
`stream: {w, h}` override.

## 3. Stream size per phone (integer, deterministic)

The phone client keeps a native control strip ("phone deck") **below** the
video — quick keys, stats, Set/End — so the stream must fit the screen minus
the OS insets minus that strip. `DECK_LOGICAL_PX = 60` (the deck's content
height in CSS px; the client's own layout constant).

```
reservedPx = roundHalfToEven((insetTop + insetBottom + DECK_LOGICAL_PX) * dpr)
streamW    = physW
streamH    = physH - reservedPx
```

`stream: {w, h}` in the JSON overrides both. `streamW/streamH` is the frame's
aspect as an **integer ratio** — no floats cross a component boundary.

## 4. Frame placement in the game window

Client area `clientW x clientH` (physical px — the window's client rect on
the server; `GetPhysicalScreenSize` on Classic Era / Forever and the
gxResolution-based basis on 1.12 in the addon). The outline ring (§5) sits
OUTSIDE the frame, so the frame keeps a `RING = 6` px margin on every side:

```
availW, availH = clientW - 2*RING, clientH - 2*RING
frameH = availH
frameW = roundHalfToEven(availH * streamW, streamH)
if frameW > availW:                      # portrait or very narrow window
    frameW = availW
    frameH = roundHalfToEven(availW * streamH, streamW)
frameX = roundHalfToEven(clientW - frameW, 2)
frameY = roundHalfToEven(clientH - frameH, 2)
```

`roundHalfToEven(num, den)` is the v0.4.x band rounding (banker's rounding on
exact halves), unchanged and shared. `frameW`/`frameH` are the crop; the
encode scales it to fit `1080 x 1920` preserving aspect with even dimensions
(`window.EncodeCap`). The `hello` reports the encoded size, as today; the wire
protocol does not change. `phones/contract_vectors.json` pins the math for
the generator, the server (`window.ComputePhoneFrame`), both addons
(`Band.lua`, asserted at load) and the client tests.

Example — iPhone 17 (stream 1206:2154):

| Window | Frame (x, y, w x h) | Encoded |
|---|---|---|
| 3840x2160 (4K fullscreen) | 1318, 6, 1203x2148 | 1074x1920 |
| 2560x1440 | 880, 6, 800x1428 | 800x1428 |
| 1920x1080 | 661, 6, 598x1068 | 598x1068 |
| 1366x768 (windowed) | 472, 6, 423x756 | 422x756 |

## 5. The red outline (human + machine readable)

Drawn by the addon **outside** the frame rect, so it is never part of the
stream: a 6 px ring — **outer 4 px pure red `#FF0000`**, **inner 2 px pure
cyan `#00FFFF`** (the machine tag; the ring still reads as red). Always shown,
mouse-transparent, whole physical pixels (pixel snapping disabled where the
client has it). Outside the ring the addon keeps black rails; the selector
panel (§6) lives there.

The server locates the frame by **reading the outline off the window**
(`window.DetectOutline`): a GDI grab of the client area from the composed
screen (`Tracker.GrabClient` — the same source gdigrab uses, so DirectX
windows read correctly) at every capture (re)launch and once per second while
streaming. Detection: the two outermost column groups with a cyan run of at
least 30% of the client height, the two row groups with cyan across at least
3/4 of the width between them, cyan at all four edge midpoints and red within
5 px outside each — colour classes are tolerant (R<90,G>170,B>170 for cyan;
R>170,G<90,B<90 for red) so a blended edge pixel or HDR tone mapping cannot
break it. The crop is the cyan ring's interior.

Source ladder per decision (`cmd/wowstreamd/frame.go`):

1. the outline, as detected now;
2. the last detected outline while the client size is unchanged (loading
   screens, cinematics and an occluding window hide the outline for a moment
   — the stream must not jump);
3. the phone picked on the **dashboard** (or `--phone`, or the remembered
   dashboard choice);
4. `iphone-17`.

A change in the decision for the same client size (the user picked another
phone, the outline appeared) that holds for two consecutive 1 Hz polls
relaunches the capture, like a window resize does. Touch input maps onto the
very crop the running capture uses (`frameResolver.Crop`), so the two cannot
disagree. The dashboard's Layout line names the source (`frame: addon
outline / last detected outline / dashboard phone / default phone`), and while
no outline is visible the warning row says so.

## 6. The selector panel (addon)

`PhoneSelect.lua` (both addons): native game UI anchored to the right of the
outline (left if the right side is narrower than the panel; hidden with a chat
hint when neither side fits — never inside the frame): search box (every
whitespace-separated term must match brand, model or id), the list ordered by
`popularity` then brand/model (mouse wheel scrolls), a "Custom W x H" entry
(portrait, 100..8000 px), the game window's physical size and the frame's px,
and a close button (a small "Phone" tab reopens it). `/wm phone` toggles it;
`/wm phone <id>`, `/wm phone <search>` (one match selects it, several are
listed) and `/wm phone WxH` do the same from chat.

Picking a phone reshapes the outline and the frame immediately; widgets sized
for the previous width need `/reload`, so the panel shows a "Reload UI"
button and the tap-to-reload banner appears. The choice is stored in
SavedVariables (`WowMobileDB.phone`) and, on clients with addon CVars
(Classic Era / Forever), mirrored into the `wowMobilePhone` CVar — the Forever
beta has been seen dropping SavedVariables. The panel hides in combat.

## 7. Phone client

The video box height is `width * encodedH / encodedW` from the hello (CSS
`--video-ratio`, `layout.js setVideoAspect`) — no 16/9 constant anywhere; the
deck/overlay decision uses the same ratio. The client identifies its own phone
from `screen.width/height x devicePixelRatio` against the same table
(`phonematch.js`) and shows a one-line notice when the stream's aspect differs
from its own entry by more than 2% ("Streaming for Samsung Galaxy A07; this
phone looks like iPhone 17 — pick your phone in-game (/wm phone) for a
perfect fit."). Everything else stays as in v0.4.x.

## 8. Layouts

`--layout auto|frame|portrait`: `frame` (this document) is the default for
every client type; `portrait` remains available for the old forced-portrait
window; `band` is accepted as an alias of `frame` with the `generic-9-16`
phone. `--phone <id>` sets the dashboard's starting phone.

## 9. Adding a phone

1. Add one entry to `phones/phones.json` (`popularity: null` for anything
   outside the ranked starting list; re-rank the list by editing the numbers,
   which must stay 1..N without gaps).
2. `node tools/genphones.js` — regenerates the Go, JS and both Lua tables and
   the contract vectors (CI runs `--check`).
3. Rebuild/reinstall; the addon picks the new entry up at `/reload`.

## 10. WoW: Forever

WoW: Forever (Blizzard; beta from September 2026, live November 4 2026) is
client 1.60.x, interface **16001**, game type `camelot`, and runs the MODERN
(Mainline, 12.x-era) client: its UI API is retail's, including Midnight's
addon restrictions ("secret values"). What this project does about it:

- `addon/WowMobile` lists `## Interface: 11507, 16001`, so it loads on both
  Classic Era and Forever.
- `Compat.lua` polyfills the classic globals Forever removed (spell book,
  quest log, reputation, item info, …) from their namespaced replacements —
  only when missing, so Classic Era is untouched — and `WM.IsSecret` lets the
  health/power bars pass secret values straight to the StatusBar instead of
  doing arithmetic on them.
- `Blizzard.lua` also banishes the modern default-UI frames (MainActionBar,
  MicroMenuContainer, BagsBar, StatusTrackingBarManager,
  PlayerCastingBarFrame, …) where they exist.
- The installer recognizes the 1.60 version stamp as Forever (not as a
  vanilla-plus 1.12 client), finds `WowClassicB.exe`/`WowClassicT.exe` and
  scans `_classic_beta_` (where the beta installs) plus `_forever_` folders,
  and installs `addon/WowMobile`; the dashboard names the client "WoW:
  Forever (1.60)".
- The phone frame itself needs nothing client-specific: the outline is read
  off the screen.

Not verified against a live Forever client from this repository; field
reports should include `/wm status` and `/wm errors`.
