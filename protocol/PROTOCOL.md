# WoW Mobile — Wire Protocol v1

Contract between `client/` (phone PWA) and `server/` (Windows host). Both sides
must implement exactly this. Version is negotiated in the `hello` control
message; a side receiving a higher major version than it supports must
disconnect with an error.

## Transports

One WebRTC peer connection per session, created via WHEP-style HTTP signaling:

- `POST /api/session` — body: `{"token": "<pairing token>"}` → `201` with
  `{"sessionId": "..."}`; sets an auth cookie/bearer for subsequent calls.
- `POST /api/session/{id}/offer` — body: SDP offer (`application/sdp`) →
  `201` with SDP answer. Server includes one sendonly H.264 video track
  (`packetization-mode=1`, baseline/constrained-baseline) and optionally one
  sendonly Opus audio track.
- `DELETE /api/session/{id}` — teardown.

Data channels (created by the **client**, negotiated in-band):

| Label | Ordered | Reliability | Direction | Payload |
|---|---|---|---|---|
| `input` | yes | reliable | client → server | binary input events (below) |
| `move` | no | maxRetransmits: 0 | client → server | binary `POINTER_MOVE` only |
| `ctrl` | yes | reliable | both | JSON control messages |

High-rate pointer motion goes on `move` (lossy, never head-of-line blocks);
every state-changing event (down/up/key/wheel) goes on `input` (reliable,
ordered). A `POINTER_MOVE` may appear on `input` immediately before a
`POINTER_DOWN`/`POINTER_UP` to guarantee position at the transition.

## Binary input events (`input`, `move` channels)

All integers little-endian. Every message starts with:

```
offset 0  u8   type
offset 1  ...  type-specific body
```

Coordinates are **normalized to the captured window's client area** as
`u16` in `0..65535` (`x = round(px / (clientWidth - 1) * 65535)`). The server
maps them back to screen pixels for `SendInput`. Normalized coordinates make
the client independent of capture resolution.

### 0x01 POINTER_DOWN — 8 bytes
```
u8  type = 0x01
u8  button      // 0 = left, 1 = right, 2 = middle
u16 x
u16 y
u16 reserved = 0
```

### 0x02 POINTER_MOVE — 8 bytes
```
u8  type = 0x02
u8  buttons     // bitmask of held buttons: bit0 L, bit1 R, bit2 M (informational)
u16 x
u16 y
u16 seq         // wrapping counter; server drops out-of-order moves (lossy channel)
```

### 0x03 POINTER_UP — 8 bytes
Body identical to `POINTER_DOWN` (button being released, position at release).

### 0x04 KEY — 8 bytes
```
u8  type = 0x04
u8  down        // 1 = press, 0 = release
u16 vk          // Windows virtual-key code (VK_*), e.g. 0x57 = 'W'
u16 mods        // bit0 Shift, bit1 Ctrl, bit2 Alt (server syncs modifier state)
u16 reserved = 0
```

### 0x05 WHEEL — 8 bytes
```
u8  type = 0x05
u8  reserved = 0
u16 x
u16 y
i16 delta       // multiples of 120, positive = scroll up
```

### 0x06 RELEASE_ALL — 2 bytes
```
u8  type = 0x06
u8  reserved = 0
```
Server releases every held button/key it injected. Client sends it on
visibility loss, disconnect intent, or gesture-layer reset. Server also
self-triggers this on data-channel close or 3 s without any message while
inputs are held (dead-man safety — a frozen client must never leave W held).

Unknown types: skip is impossible (no length prefix), so receivers must treat
an unknown type as a protocol error and request `RELEASE_ALL` semantics +
close the channel. Additive changes therefore bump the minor version and may
only use new types after `hello` confirms both sides support them.

## JSON control messages (`ctrl` channel)

Every message: `{"t": "<type>", ...}`.

client → server:

- `{"t":"hello","proto":[1,0],"client":"wowmobile-pwa/1.0"}` — first message.
- `{"t":"bitrate","kbps":8000}` — request encoder bitrate change.
- `{"t":"latencyProbe","id":123,"tSent":<ms>}` — echo request.

server → client:

- `{"t":"hello","proto":[1,0],"server":"wowstreamd/1.0",
   "video":{"w":1080,"h":1920,"fps":60}}` — reply to hello; capture geometry
   (clients may use it for aspect fitting; input stays normalized).
- `{"t":"latencyProbe","id":123,"tSent":<ms>}` — echoed unchanged.
- `{"t":"stats","encodeMs":4.2,"captureFps":60,"kbps":7800}` — 1 Hz.
- `{"t":"error","code":"...","msg":"..."}` — fatal; connection closes after.

## Safety rules (server-side, normative)

1. Inject input only while the WoW window exists; if it is not the foreground
   window, focus it first (`SetForegroundWindow`) or drop the event.
2. Track every injected down (buttons, keys). On session end, channel close,
   `RELEASE_ALL`, or dead-man timeout: release all.
3. One session at a time; a new authenticated session replaces the old one
   (old gets `error{code:"replaced"}`).
