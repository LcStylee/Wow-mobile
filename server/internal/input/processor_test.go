package input

import (
	"errors"
	"fmt"
	"testing"
	"time"
)

// fakeInjector records calls and mirrors held state, and can simulate
// not-foreground drops for state-entering events.
type fakeInjector struct {
	calls       []string
	dropNonUps  bool
	heldButtons map[Button]bool
	heldKeys    map[uint16]bool
	lastMoveX   uint16
	lastMoveY   uint16
}

func newFakeInjector() *fakeInjector {
	return &fakeInjector{heldButtons: map[Button]bool{}, heldKeys: map[uint16]bool{}}
}

func (f *fakeInjector) PointerMove(x, y uint16) error {
	if f.dropNonUps {
		return ErrDropped
	}
	f.lastMoveX, f.lastMoveY = x, y
	f.calls = append(f.calls, fmt.Sprintf("move(%d,%d)", x, y))
	return nil
}

func (f *fakeInjector) PointerButton(btn Button, down bool, x, y uint16) error {
	if down && f.dropNonUps {
		return ErrDropped
	}
	f.heldButtons[btn] = down
	f.calls = append(f.calls, fmt.Sprintf("button(%d,%v)", btn, down))
	return nil
}

func (f *fakeInjector) Wheel(x, y uint16, delta int16) error {
	if f.dropNonUps {
		return ErrDropped
	}
	f.calls = append(f.calls, fmt.Sprintf("wheel(%d)", delta))
	return nil
}

func (f *fakeInjector) Key(vk uint16, down bool) error {
	if down && f.dropNonUps {
		return ErrDropped
	}
	f.heldKeys[vk] = down
	f.calls = append(f.calls, fmt.Sprintf("key(0x%02x,%v)", vk, down))
	return nil
}

// fakeClock is the injectable dead-man clock.
type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time          { return c.t }
func (c *fakeClock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newTestProcessor() (*Processor, *fakeInjector, *fakeClock) {
	inj := newFakeInjector()
	clk := &fakeClock{t: time.Unix(1000, 0)}
	return NewProcessor(inj, clk.now), inj, clk
}

func keyMsg(down byte, vk, mods uint16) []byte {
	b := []byte{TypeKey, down}
	b = le16(b, vk)
	b = le16(b, mods)
	return le16(b, 0)
}

func moveMsg(x, y, seq uint16) []byte {
	b := []byte{TypePointerMove, 0}
	b = le16(b, x)
	b = le16(b, y)
	return le16(b, seq)
}

func TestLedgerAndReleaseAll(t *testing.T) {
	p, inj, _ := newTestProcessor()

	mustHandle(t, p, []byte{TypePointerDown, 1, 0, 0, 0, 0, 0, 0}) // RMB down
	mustHandle(t, p, keyMsg(1, 0x57, 0))                           // W down
	mustHandle(t, p, keyMsg(1, 0x41, 0))                           // A down
	if b, k := p.HeldCounts(); b != 1 || k != 2 {
		t.Fatalf("held = (%d,%d), want (1,2)", b, k)
	}

	mustHandle(t, p, keyMsg(0, 0x41, 0)) // A up
	if b, k := p.HeldCounts(); b != 1 || k != 1 {
		t.Fatalf("held after key up = (%d,%d), want (1,1)", b, k)
	}

	mustHandle(t, p, []byte{TypeReleaseAll, 0})
	if b, k := p.HeldCounts(); b != 0 || k != 0 {
		t.Fatalf("held after RELEASE_ALL = (%d,%d), want (0,0)", b, k)
	}
	if inj.heldButtons[ButtonRight] || inj.heldKeys[0x57] {
		t.Fatal("injector still holds inputs after RELEASE_ALL")
	}
}

func TestLossySeqOrdering(t *testing.T) {
	p, inj, _ := newTestProcessor()

	mustLossy(t, p, moveMsg(10, 10, 100))
	mustLossy(t, p, moveMsg(30, 30, 102)) // gap: 101 was lost, fine
	mustLossy(t, p, moveMsg(20, 20, 101)) // late arrival: dropped
	if inj.lastMoveX != 30 || inj.lastMoveY != 30 {
		t.Fatalf("pointer at (%d,%d), want (30,30) — stale move applied", inj.lastMoveX, inj.lastMoveY)
	}
	mustLossy(t, p, moveMsg(40, 40, 102)) // duplicate seq: dropped
	if inj.lastMoveX != 30 {
		t.Fatal("duplicate seq was applied")
	}
}

func TestLossySeqWrap(t *testing.T) {
	p, inj, _ := newTestProcessor()

	mustLossy(t, p, moveMsg(1, 1, 0xFFFE))
	mustLossy(t, p, moveMsg(2, 2, 0xFFFF))
	mustLossy(t, p, moveMsg(3, 3, 0)) // wraps: newer than 0xFFFF
	if inj.lastMoveX != 3 {
		t.Fatal("wrapped seq 0 after 0xFFFF was dropped")
	}
	mustLossy(t, p, moveMsg(4, 4, 0xFFFF)) // pre-wrap straggler: dropped
	if inj.lastMoveX != 3 {
		t.Fatal("pre-wrap straggler was applied")
	}
}

func TestReliableMoveAdvancesSeqHorizon(t *testing.T) {
	p, inj, _ := newTestProcessor()

	// Position guarantee before a down travels on the reliable channel...
	mustHandle(t, p, moveMsg(50, 50, 10))
	// ...so an older lossy move must not yank the pointer back.
	mustLossy(t, p, moveMsg(1, 1, 9))
	if inj.lastMoveX != 50 {
		t.Fatal("stale lossy move overrode reliable position")
	}
}

func TestLossyChannelRejectsNonMove(t *testing.T) {
	p, _, _ := newTestProcessor()
	mustHandle(t, p, keyMsg(1, 0x57, 0))
	err := p.HandleLossy(keyMsg(1, 0x41, 0))
	if !errors.Is(err, ErrProtocol) {
		t.Fatalf("err = %v, want ErrProtocol", err)
	}
	if b, k := p.HeldCounts(); b != 0 || k != 0 {
		t.Fatalf("held = (%d,%d), want all released on protocol error", b, k)
	}
}

func TestUnknownTypeReleasesAndErrors(t *testing.T) {
	p, inj, _ := newTestProcessor()
	mustHandle(t, p, keyMsg(1, 0x57, 0))
	err := p.HandleReliable([]byte{0x09, 0, 0, 0, 0, 0, 0, 0})
	if !errors.Is(err, ErrProtocol) {
		t.Fatalf("err = %v, want ErrProtocol", err)
	}
	if inj.heldKeys[0x57] {
		t.Fatal("W still held after protocol error")
	}
}

func TestDeadman(t *testing.T) {
	p, inj, clk := newTestProcessor()

	mustHandle(t, p, keyMsg(1, 0x57, 0)) // W held
	clk.advance(2 * time.Second)
	if p.CheckDeadman() {
		t.Fatal("dead-man fired before the 3 s timeout")
	}

	// Any message resets the timer, even a lossy move.
	mustLossy(t, p, moveMsg(5, 5, 1))
	clk.advance(2500 * time.Millisecond)
	if p.CheckDeadman() {
		t.Fatal("dead-man fired 2.5 s after the last message")
	}

	clk.advance(600 * time.Millisecond)
	if !p.CheckDeadman() {
		t.Fatal("dead-man did not fire 3.1 s after the last message")
	}
	if b, k := p.HeldCounts(); b != 0 || k != 0 {
		t.Fatalf("held = (%d,%d) after dead-man, want (0,0)", b, k)
	}
	if inj.heldKeys[0x57] {
		t.Fatal("injector still holds W after dead-man release")
	}
	if p.CheckDeadman() {
		t.Fatal("dead-man refired with nothing held")
	}
}

func TestDeadmanIdleWithoutHeldInputs(t *testing.T) {
	p, _, clk := newTestProcessor()
	clk.advance(time.Hour)
	if p.CheckDeadman() {
		t.Fatal("dead-man fired with no inputs held")
	}
}

func TestModifierSync(t *testing.T) {
	p, inj, _ := newTestProcessor()

	// Key with shift in mods: shift pressed first, then the key.
	mustHandle(t, p, keyMsg(1, 0x57, uint16(ModShift)))
	want := []string{"key(0x10,true)", "key(0x57,true)"}
	if fmt.Sprint(inj.calls) != fmt.Sprint(want) {
		t.Fatalf("calls = %v, want %v", inj.calls, want)
	}
	if _, k := p.HeldCounts(); k != 2 {
		t.Fatalf("held keys = %d, want 2 (W + Shift)", k)
	}

	// Next key without shift: shift released before the key goes down.
	inj.calls = nil
	mustHandle(t, p, keyMsg(1, 0x41, 0))
	want = []string{"key(0x10,false)", "key(0x41,true)"}
	if fmt.Sprint(inj.calls) != fmt.Sprint(want) {
		t.Fatalf("calls = %v, want %v", inj.calls, want)
	}

	// A SHIFT key event itself must not be double-driven by mods sync.
	inj.calls = nil
	mustHandle(t, p, keyMsg(1, VKShift, uint16(ModShift)))
	want = []string{"key(0x10,true)"}
	if fmt.Sprint(inj.calls) != fmt.Sprint(want) {
		t.Fatalf("calls = %v, want %v", inj.calls, want)
	}
}

func TestDroppedEventsNotRecordedHeld(t *testing.T) {
	p, inj, _ := newTestProcessor()
	inj.dropNonUps = true // window not foreground

	if err := p.HandleReliable(keyMsg(1, 0x57, 0)); err != nil {
		t.Fatalf("dropped key down surfaced as error: %v", err)
	}
	if err := p.HandleReliable([]byte{TypePointerDown, 0, 0, 0, 0, 0, 0, 0}); err != nil {
		t.Fatalf("dropped pointer down surfaced as error: %v", err)
	}
	if b, k := p.HeldCounts(); b != 0 || k != 0 {
		t.Fatalf("held = (%d,%d), want (0,0) — dropped downs must not enter the ledger", b, k)
	}

	// An up while unfocused still goes through and clears the ledger.
	inj.dropNonUps = false
	mustHandle(t, p, keyMsg(1, 0x57, 0))
	inj.dropNonUps = true
	if err := p.HandleReliable(keyMsg(0, 0x57, 0)); err != nil {
		t.Fatalf("key up: %v", err)
	}
	if _, k := p.HeldCounts(); k != 0 {
		t.Fatal("key up while unfocused did not clear the ledger")
	}
}

func mustHandle(t *testing.T, p *Processor, msg []byte) {
	t.Helper()
	if err := p.HandleReliable(msg); err != nil {
		t.Fatalf("HandleReliable(% x): %v", msg, err)
	}
}

func mustLossy(t *testing.T, p *Processor, msg []byte) {
	t.Helper()
	if err := p.HandleLossy(msg); err != nil {
		t.Fatalf("HandleLossy(% x): %v", msg, err)
	}
}
