package main

import (
	"context"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// geoHarness drives geometryWatchdog deterministically: every callback reads
// shared state under a mutex, active() counts ticks so the test can wait for
// "N more polls have run" instead of sleeping wall-clock intervals.
type geoHarness struct {
	mu           sync.Mutex
	activeVal    bool
	rect         window.Rect
	rectOK       bool
	rectFn       func(h *geoHarness) (window.Rect, bool) // overrides rect/rectOK when set
	launchRect   window.Rect
	posSensitive bool
	launchValid  bool
	restarts     []string
	restartTicks []int // h.ticks at the moment each restart fired
	ticks        int
	cancel       context.CancelFunc
	done         chan struct{}
}

func startGeoHarness(t *testing.T) *geoHarness {
	t.Helper()
	h := &geoHarness{done: make(chan struct{})}
	ctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	gw := geometryWatch{
		active: func() bool {
			h.mu.Lock()
			defer h.mu.Unlock()
			h.ticks++
			return h.activeVal
		},
		clientRect: func() (window.Rect, bool) {
			h.mu.Lock()
			defer h.mu.Unlock()
			if h.rectFn != nil {
				return h.rectFn(h)
			}
			return h.rect, h.rectOK
		},
		launched: func() (window.Rect, bool, bool) {
			h.mu.Lock()
			defer h.mu.Unlock()
			return h.launchRect, h.posSensitive, h.launchValid
		},
		restart: func(reason string) {
			h.mu.Lock()
			defer h.mu.Unlock()
			h.restarts = append(h.restarts, reason)
			h.restartTicks = append(h.restartTicks, h.ticks)
		},
		log:      slog.Default(),
		interval: time.Millisecond,
	}
	go func() {
		defer close(h.done)
		geometryWatchdog(ctx, gw)
	}()
	t.Cleanup(func() {
		cancel()
		<-h.done
	})
	return h
}

func (h *geoHarness) set(fn func(*geoHarness)) {
	h.mu.Lock()
	fn(h)
	h.mu.Unlock()
}

// waitTicks blocks until the watchdog has polled n more times since the call.
func (h *geoHarness) waitTicks(t *testing.T, n int) {
	t.Helper()
	h.mu.Lock()
	target := h.ticks + n
	h.mu.Unlock()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		h.mu.Lock()
		reached := h.ticks >= target
		h.mu.Unlock()
		if reached {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("watchdog stopped ticking")
}

func (h *geoHarness) restartCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.restarts)
}

func TestGeowatchResizeRestartsOnceAfterSettling(t *testing.T) {
	h := startGeoHarness(t)
	launch := window.Rect{X: 100, Y: 100, W: 1920, H: 1080}
	h.set(func(h *geoHarness) {
		h.activeVal, h.rect, h.rectOK = true, launch, true
		h.launchRect, h.launchValid = launch, true
	})
	h.waitTicks(t, 4)
	if h.restartCount() != 0 {
		t.Fatalf("restart with unchanged rect: %v", h.restarts)
	}
	// Resize. The first tick that sees the new rect must NOT restart (no
	// settled prior observation yet); the second consecutive tick must.
	h.set(func(h *geoHarness) { h.rect = window.Rect{X: 100, Y: 100, W: 1600, H: 900} })
	h.waitTicks(t, 6)
	if got := h.restartCount(); got != 1 {
		t.Fatalf("settled resize: want exactly 1 restart, got %d (%v)", got, h.restarts)
	}
	// Restart pending: the launch record still holds the old rect (slow
	// relaunch) — further ticks must not stack a second restart.
	h.waitTicks(t, 6)
	if got := h.restartCount(); got != 1 {
		t.Fatalf("pending relaunch: restart stacked to %d (%v)", got, h.restarts)
	}
	// The relaunch lands and records the fresh rect: watchdog disarms…
	h.set(func(h *geoHarness) { h.launchRect = window.Rect{X: 100, Y: 100, W: 1600, H: 900} })
	h.waitTicks(t, 4)
	if got := h.restartCount(); got != 1 {
		t.Fatalf("after record refresh: unexpected restart, got %d", got)
	}
	// …and a LATER second resize must fire again (suppression re-armed).
	h.set(func(h *geoHarness) { h.rect = window.Rect{X: 100, Y: 100, W: 1280, H: 720} })
	h.waitTicks(t, 6)
	if got := h.restartCount(); got != 2 {
		t.Fatalf("second settled resize: want 2 restarts, got %d (%v)", got, h.restarts)
	}
}

func TestGeowatchContinuousDragNeverRestarts(t *testing.T) {
	h := startGeoHarness(t)
	launch := window.Rect{X: 0, Y: 0, W: 1920, H: 1080}
	h.set(func(h *geoHarness) {
		h.activeVal, h.rect, h.rectOK = true, launch, true
		h.launchRect, h.launchValid = launch, true
	})
	// The rect differs from the launch record on every tick but never holds
	// still for two consecutive polls: a drag in progress must not be fought.
	// The drag advances INSIDE the callback, so every poll deterministically
	// observes a fresh rect no matter how ticks interleave with the test.
	drag := 0
	h.set(func(h *geoHarness) {
		h.rectFn = func(h *geoHarness) (window.Rect, bool) {
			drag++
			return window.Rect{X: 0, Y: 0, W: 1920 - drag, H: 1080 - drag}, true
		}
	})
	h.waitTicks(t, 12)
	if h.restartCount() != 0 {
		t.Fatalf("restart during continuous drag: %v", h.restarts)
	}
}

func TestGeowatchMoveOnlyRespectsPosSensitivity(t *testing.T) {
	for _, posSensitive := range []bool{false, true} {
		launch := window.Rect{X: 100, Y: 100, W: 1920, H: 1080}
		h := startGeoHarness(t)
		h.set(func(h *geoHarness) {
			h.activeVal, h.rect, h.rectOK = true, launch, true
			h.launchRect, h.launchValid = launch, true
			h.posSensitive = posSensitive
		})
		h.waitTicks(t, 2)
		// Same size, new position: stales only a screen-space (ddagrab) crop.
		h.set(func(h *geoHarness) { h.rect = window.Rect{X: 500, Y: 300, W: 1920, H: 1080} })
		h.waitTicks(t, 6)
		if posSensitive && h.restartCount() != 1 {
			t.Fatalf("ddagrab move: want 1 restart, got %d", h.restartCount())
		}
		if !posSensitive && h.restartCount() != 0 {
			t.Fatalf("gdigrab move: want no restart, got %v", h.restarts)
		}
	}
}

func TestGeowatchNeverRestartsWithoutValidState(t *testing.T) {
	h := startGeoHarness(t)
	changed := window.Rect{X: 0, Y: 0, W: 800, H: 600}
	// Invalid launch record: rect differs and holds, but there is nothing to
	// compare against — the supervisor's own retry loop owns this state.
	h.set(func(h *geoHarness) {
		h.activeVal, h.rect, h.rectOK = true, changed, true
		h.launchRect = window.Rect{X: 0, Y: 0, W: 1920, H: 1080}
		h.launchValid = false
	})
	h.waitTicks(t, 6)
	if h.restartCount() != 0 {
		t.Fatalf("restart with invalid launch record: %v", h.restarts)
	}
	// Unreadable client rect (window vanished): also never a restart.
	h.set(func(h *geoHarness) { h.launchValid, h.rectOK = true, false })
	h.waitTicks(t, 6)
	if h.restartCount() != 0 {
		t.Fatalf("restart with unreadable client rect: %v", h.restarts)
	}
}

func TestGeowatchInactiveResetsDebounce(t *testing.T) {
	h := startGeoHarness(t)
	launch := window.Rect{X: 0, Y: 0, W: 1920, H: 1080}
	changed := window.Rect{X: 0, Y: 0, W: 1600, H: 900}
	h.set(func(h *geoHarness) {
		h.activeVal, h.rect, h.rectOK = true, changed, true
		h.launchRect, h.launchValid = launch, true
	})
	h.waitTicks(t, 1)
	// Observations of the changed rect are in the debounce. Going inactive
	// must drop them: the next active tick starts over and must not treat its
	// FIRST observation as already settled — so the restart can only fire on
	// the SECOND tick after reactivation or later (tick number proves it, no
	// wall-clock timing involved).
	h.set(func(h *geoHarness) { h.activeVal = false })
	h.waitTicks(t, 2)
	var t0 int
	h.set(func(h *geoHarness) { h.activeVal = true; t0 = h.ticks })
	h.waitTicks(t, 6)
	h.mu.Lock()
	restarts, restartTicks := len(h.restarts), h.restartTicks
	h.mu.Unlock()
	if restarts != 1 {
		t.Fatalf("settled change after reactivation: want 1 restart, got %d", restarts)
	}
	if restartTicks[0] <= t0+1 {
		t.Fatalf("restart fired on the first tick after reactivation (tick %d, reactivated before tick %d): debounce not reset", restartTicks[0], t0+1)
	}
}
