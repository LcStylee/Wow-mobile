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

Client area `clientW x clientH` (physical px, from the window on the server,
from the addon's basis on the addon side — `Band.lua`'s chosen-basis rules
carry over unchanged).

```
frameH = clientH
frameW = roundHalfToEven(clientH * streamW, streamH)
if frameW > clientW:                     # portrait or very narrow window
    frameW = clientW
    frameH = roundHalfToEven(clientW * streamH, streamW)
frameX = roundHalfToEven(clientW - frameW, 2)
frameY = 0
```

`roundHalfToEven(num, den)` is the v0.4.x band rounding (banker's rounding on
exact halves), unchanged and shared. `frameW`/`frameH` are the crop; the
encode scales it to fit `1080 x 1920` preserving aspect with even dimensions
(the existing cap, generalized from 9:16). The `hello` reports the encoded
size, as today; the wire protocol does not change.

## 5. The red outline (human + machine readable)

Drawn by the addon **outside** the frame rect, so it is never part of the
stream: a 6 px ring — **outer 4 px pure red `#FF0000`**, **inner 2 px pure
cyan `#00FFFF`** (the machine tag; the ring still reads as red). Shown
whenever the frame is smaller than the window. Mouse-transparent.

The server locates the frame by **reading the outline off the window**: a
`BitBlt` probe of the client area at every capture (re)launch and once per
second while streaming (cheap: one copy + a linear scan). Detection requires
all four edges with the exact two-colour pattern, matching lengths, a frame at
least 30% of the client height, per-channel tolerance ±2. The crop is the
ring's interior. A change in the detected frame (the user picked another
phone) relaunches the capture like a window resize does. Fallback ladder when
no marker is found: the phone selected on the **dashboard** (same table) →
the last detected frame this session → `iphone-17`. The dashboard's Layout
line names the source ("frame: addon outline / dashboard phone / default").

## 6. The selector panel (addon)

Native game UI anchored to the right of the outline (left if the right rail
is narrower than the panel): search box (substring on brand+model), the list
ordered by `popularity` then brand/model, a "Custom W x H" entry, the current
PC resolution and frame px, and a close button. `/wm phone <id|search>` does
the same from chat. Persisted in SavedVariables (falls back to `iphone-17`
where they do not load — the Forever beta). Hidden in combat on clients with
combat lockdown; never inside the frame.

## 7. Phone client

The video box height is `width * encodedH / encodedW` from the hello — no
16/9 constant anywhere. The client identifies its own phone from
`screen.width/height x devicePixelRatio` against the same table and shows a
one-line notice when the stream's aspect differs from its own entry by more
than 2% ("Streaming for iPhone 17 Pro Max; this phone looks like an iPhone 16
— pick your phone in-game"). Everything else stays as in v0.4.x.

## 8. Layouts

`--layout auto|frame|portrait`: `frame` (this document) is the default for
every client type; `portrait` remains available for the old forced-portrait
window; `band` is accepted as an alias of `frame` with the `generic-9-16`
phone.
