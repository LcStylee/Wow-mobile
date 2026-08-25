package input

import (
	"errors"
	"fmt"
	"sync"
	"time"
)

// Windows virtual-key codes for the modifier keys the mods field controls.
// Defined here (portable) so the processor can sync modifier state itself.
const (
	VKShift   = 0x10
	VKControl = 0x11
	VKMenu    = 0x12 // Alt
)

// ErrDropped is returned by an Injector when it deliberately did not inject —
// e.g. the game window is not foreground (PROTOCOL.md safety rule 1). The
// processor then skips the ledger update: an input that never went down must
// never be recorded as held.
var ErrDropped = errors.New("input dropped")

// Injector performs the platform injection primitives. Implementations must
// honor safety rule 1 for state-*entering* events (down/move/wheel): focus
// the game window or return ErrDropped. Releases (up events) must always be
// injected — releasing into the wrong foreground window is harmless, while a
// stuck W key is not.
type Injector interface {
	PointerMove(x, y uint16) error
	PointerButton(btn Button, down bool, x, y uint16) error
	Wheel(x, y uint16, delta int16) error
	Key(vk uint16, down bool) error
}

// DeadmanTimeout is normative (PROTOCOL.md): 3 s without any message while
// inputs are held releases everything.
const DeadmanTimeout = 3 * time.Second

// Processor applies decoded events to an Injector while tracking every
// injected down so it can always get back to a clean state. One Processor per
// streaming session. Safe for concurrent use — the reliable and lossy
// channels deliver on separate goroutines.
type Processor struct {
	inj Injector
	now func() time.Time // injectable clock for dead-man tests

	mu          sync.Mutex
	lastMsg     time.Time
	lastSeq     uint16
	haveSeq     bool
	lastX       uint16 // last known pointer position, for button events
	lastY       uint16
	heldButtons [numButtons]bool
	heldKeys    map[uint16]bool // includes modifiers held via mods sync
}

// NewProcessor creates a processor. now may be nil for the real clock.
func NewProcessor(inj Injector, now func() time.Time) *Processor {
	if now == nil {
		now = time.Now
	}
	return &Processor{
		inj:      inj,
		now:      now,
		heldKeys: make(map[uint16]bool),
		lastMsg:  now(),
	}
}

// HandleReliable processes one message from the ordered `input` channel.
// A returned error wrapping ErrProtocol means the caller must close the
// channel; ReleaseAllHeld has already been invoked (spec: unknown message =>
// RELEASE_ALL semantics + close).
func (p *Processor) HandleReliable(msg []byte) error {
	ev, err := Decode(msg)
	if err != nil {
		p.ReleaseAllHeld()
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.lastMsg = p.now()

	switch e := ev.(type) {
	case PointerDown:
		p.lastX, p.lastY = e.X, e.Y
		if err := p.inj.PointerButton(e.Button, true, e.X, e.Y); err != nil {
			return injectionResult(err)
		}
		p.heldButtons[e.Button] = true
	case PointerUp:
		p.lastX, p.lastY = e.X, e.Y
		// Injected unconditionally (see Injector contract) and always cleared
		// from the ledger — even on injector failure the intent is "not held".
		err := p.inj.PointerButton(e.Button, false, e.X, e.Y)
		p.heldButtons[e.Button] = false
		if err != nil {
			return injectionResult(err)
		}
	case PointerMove:
		// A move on the reliable channel guarantees position right before a
		// down/up; it also advances the seq horizon so a stale lossy move
		// arriving later cannot yank the pointer back.
		p.noteSeqLocked(e.Seq)
		p.lastX, p.lastY = e.X, e.Y
		if err := p.inj.PointerMove(e.X, e.Y); err != nil {
			return injectionResult(err)
		}
	case Key:
		if err := p.syncModifiersLocked(e); err != nil {
			return injectionResult(err)
		}
		err := p.inj.Key(e.VK, e.Down)
		if e.Down {
			if err == nil {
				p.heldKeys[e.VK] = true
			}
		} else {
			delete(p.heldKeys, e.VK) // ups always clear the ledger, as above
		}
		if err != nil {
			return injectionResult(err)
		}
	case Wheel:
		p.lastX, p.lastY = e.X, e.Y
		if err := p.inj.Wheel(e.X, e.Y, e.Delta); err != nil {
			return injectionResult(err)
		}
	case ReleaseAll:
		p.releaseAllLocked()
	}
	return nil
}

// HandleLossy processes one message from the unordered `move` channel, which
// per PROTOCOL.md carries POINTER_MOVE only. Out-of-order moves are silently
// dropped; anything else is a protocol error (caller closes the channel).
func (p *Processor) HandleLossy(msg []byte) error {
	ev, err := Decode(msg)
	if err != nil {
		p.ReleaseAllHeld()
		return err
	}
	mv, ok := ev.(PointerMove)
	if !ok {
		p.ReleaseAllHeld()
		return fmt.Errorf("%w: move channel carried message type other than POINTER_MOVE", ErrProtocol)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.lastMsg = p.now()
	if p.haveSeq && !SeqNewer(mv.Seq, p.lastSeq) {
		return nil // stale or duplicate; expected on a lossy channel
	}
	p.noteSeqLocked(mv.Seq)
	p.lastX, p.lastY = mv.X, mv.Y
	if err := p.inj.PointerMove(mv.X, mv.Y); err != nil {
		return injectionResult(err)
	}
	return nil
}

// CheckDeadman releases everything if inputs are held and no message has
// arrived for DeadmanTimeout (a frozen client must never leave W held).
// Returns true when it fired. Call it from a coarse ticker.
func (p *Processor) CheckDeadman() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.anyHeldLocked() || p.now().Sub(p.lastMsg) < DeadmanTimeout {
		return false
	}
	p.releaseAllLocked()
	return true
}

// ReleaseAllHeld releases every held button and key. Used on RELEASE_ALL,
// channel close, session teardown, and protocol errors.
func (p *Processor) ReleaseAllHeld() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.releaseAllLocked()
}

// HeldCounts reports (buttons, keys) currently recorded as held.
func (p *Processor) HeldCounts() (buttons, keys int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, h := range p.heldButtons {
		if h {
			buttons++
		}
	}
	return buttons, len(p.heldKeys)
}

func (p *Processor) anyHeldLocked() bool {
	if len(p.heldKeys) > 0 {
		return true
	}
	for _, h := range p.heldButtons {
		if h {
			return true
		}
	}
	return false
}

func (p *Processor) releaseAllLocked() {
	// Ledger entries are cleared even if an injection call fails: after
	// release-all the session state is authoritatively "nothing held", and
	// retrying a failing injector forever would be worse than a logged error.
	for b := Button(0); b < numButtons; b++ {
		if p.heldButtons[b] {
			_ = p.inj.PointerButton(b, false, p.lastX, p.lastY)
			p.heldButtons[b] = false
		}
	}
	for vk := range p.heldKeys {
		_ = p.inj.Key(vk, false)
		delete(p.heldKeys, vk)
	}
}

func (p *Processor) noteSeqLocked(seq uint16) {
	if !p.haveSeq || SeqNewer(seq, p.lastSeq) {
		p.lastSeq = seq
		p.haveSeq = true
	}
}

// syncModifiersLocked reconciles injected modifier state with the mods field
// of a KEY message before its main key event, so e.g. Shift+click macros work
// even when the phone never sends discrete Shift key events.
func (p *Processor) syncModifiersLocked(e Key) error {
	for _, m := range [...]struct {
		bit Mods
		vk  uint16
	}{{ModShift, VKShift}, {ModCtrl, VKControl}, {ModAlt, VKMenu}} {
		// If the message *is* this modifier key, its own down/up handling
		// owns the state; syncing here would double-inject.
		if e.VK == m.vk {
			continue
		}
		want := e.Mods&m.bit != 0
		if want == p.heldKeys[m.vk] {
			continue
		}
		if err := p.inj.Key(m.vk, want); err != nil {
			if want { // failed press: not held
				return err
			}
			// Failed release still clears the ledger below.
		}
		if want {
			p.heldKeys[m.vk] = true
		} else {
			delete(p.heldKeys, m.vk)
		}
	}
	return nil
}

// injectionResult maps injector errors for callers: a deliberate drop is not
// an error at the session level, only a per-event outcome.
func injectionResult(err error) error {
	if errors.Is(err, ErrDropped) {
		return nil
	}
	return err
}
