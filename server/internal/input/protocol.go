// Package input implements the binary input-event side of
// protocol/PROTOCOL.md: decoding, ordering, the held-input ledger, and the
// dead-man safety timeout. It is fully portable; actual injection happens
// behind the Injector interface (implemented by internal/wininput on Windows).
package input

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// Message types (PROTOCOL.md "Binary input events").
const (
	TypePointerDown = 0x01
	TypePointerMove = 0x02
	TypePointerUp   = 0x03
	TypeKey         = 0x04
	TypeWheel       = 0x05
	TypeReleaseAll  = 0x06
)

// Button identifies a pointer button per the wire encoding.
type Button uint8

const (
	ButtonLeft   Button = 0
	ButtonRight  Button = 1
	ButtonMiddle Button = 2
	numButtons          = 3
)

// Mods is the KEY message modifier bitmask.
type Mods uint16

const (
	ModShift Mods = 1 << 0
	ModCtrl  Mods = 1 << 1
	ModAlt   Mods = 1 << 2
	modsMask      = ModShift | ModCtrl | ModAlt
)

// ErrProtocol marks violations of the wire contract. Per PROTOCOL.md there is
// no length prefix, so an unknown or malformed message makes the rest of the
// channel unparseable: the receiver must release all inputs and close the
// channel. Every error returned by Decode wraps ErrProtocol.
var ErrProtocol = errors.New("input protocol error")

// Event is one decoded wire message.
type Event interface{ isEvent() }

type PointerDown struct {
	Button Button
	X, Y   uint16
}

type PointerMove struct {
	Buttons uint8 // informational held-button mask; server state is authoritative
	X, Y    uint16
	Seq     uint16
}

type PointerUp struct {
	Button Button
	X, Y   uint16
}

type Key struct {
	Down bool
	VK   uint16 // Windows virtual-key code
	Mods Mods
}

type Wheel struct {
	X, Y  uint16
	Delta int16 // multiples of 120, positive = up
}

type ReleaseAll struct{}

func (PointerDown) isEvent() {}
func (PointerMove) isEvent() {}
func (PointerUp) isEvent()   {}
func (Key) isEvent()         {}
func (Wheel) isEvent()       {}
func (ReleaseAll) isEvent()  {}

// Decode parses exactly one wire message (one data-channel message = one
// event; there is no framing). Strictness follows the spec: length and type
// and enumerated fields are hard errors; informational/reserved fields are
// tolerated so a well-formed peer is never rejected over padding bytes.
func Decode(b []byte) (Event, error) {
	if len(b) == 0 {
		return nil, fmt.Errorf("%w: empty message", ErrProtocol)
	}
	typ := b[0]
	wantLen := 8
	if typ == TypeReleaseAll {
		wantLen = 2
	}
	switch typ {
	case TypePointerDown, TypePointerMove, TypePointerUp, TypeKey, TypeWheel, TypeReleaseAll:
	default:
		return nil, fmt.Errorf("%w: unknown message type 0x%02x", ErrProtocol, typ)
	}
	if len(b) != wantLen {
		return nil, fmt.Errorf("%w: type 0x%02x message is %d bytes, want %d", ErrProtocol, typ, len(b), wantLen)
	}

	le := binary.LittleEndian
	switch typ {
	case TypePointerDown, TypePointerUp:
		btn := Button(b[1])
		if btn >= numButtons {
			return nil, fmt.Errorf("%w: pointer button %d out of range", ErrProtocol, btn)
		}
		if typ == TypePointerDown {
			return PointerDown{Button: btn, X: le.Uint16(b[2:]), Y: le.Uint16(b[4:])}, nil
		}
		return PointerUp{Button: btn, X: le.Uint16(b[2:]), Y: le.Uint16(b[4:])}, nil
	case TypePointerMove:
		return PointerMove{Buttons: b[1], X: le.Uint16(b[2:]), Y: le.Uint16(b[4:]), Seq: le.Uint16(b[6:])}, nil
	case TypeKey:
		switch b[1] {
		case 0, 1:
		default:
			return nil, fmt.Errorf("%w: key down field %d, want 0 or 1", ErrProtocol, b[1])
		}
		// Undefined high mods bits are masked, not rejected: additive protocol
		// changes require new message types, never new bits in old ones.
		return Key{Down: b[1] == 1, VK: le.Uint16(b[2:]), Mods: Mods(le.Uint16(b[4:])) & modsMask}, nil
	case TypeWheel:
		return Wheel{X: le.Uint16(b[2:]), Y: le.Uint16(b[4:]), Delta: int16(le.Uint16(b[6:]))}, nil
	default: // TypeReleaseAll
		return ReleaseAll{}, nil
	}
}

// SeqNewer reports whether wrapping counter a is strictly newer than b
// (RFC 1982 serial-number arithmetic over 16 bits): the lossy move channel
// drops any move whose seq is not newer than the last applied one.
func SeqNewer(a, b uint16) bool {
	return a != b && int16(a-b) > 0
}
