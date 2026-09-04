// Geometry watchdog: the frame decision (band crop, portrait self-heal,
// ddagrab screen rect) is resolved per ffmpeg LAUNCH, but band mode
// deliberately retires window-size enforcement — the landscape window is
// freely resizable and movable — so nothing used to notice a mid-session
// change until the next incidental relaunch. That desynchronizes stream and
// touch indefinitely: the encode keeps a stale crop (on the zero-copy ddagrab
// path a fixed SCREEN rect, so a mere window move captures desktop pixels)
// while input injection follows the live window per event, and a
// garbled-but-valid stream never triggers a PLI. The watchdog polls the live
// client rect while capture is active and relaunches the pipeline (the same
// generation bump a bitrate change uses) once the rect settles on something
// different from what the running process was launched with.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// geometryPollInterval is the watchdog's cadence. With the one-tick stability
// debounce below, a resize/move is picked up within ~2 s of the user letting
// go — and a continuous drag never causes restart churn.
const geometryPollInterval = time.Second

// launchGeometry is the concurrency-safe record of the client rect the
// running ffmpeg's frame decision was built from: written by the video argv
// callback at every launch, read by the geometry watchdog to detect drift.
type launchGeometry struct {
	mu   sync.Mutex
	rect window.Rect
	// posSensitive marks a launch on the zero-copy ddagrab path, whose crop
	// is a fixed rect in SCREEN space: a window MOVE alone stales it. The
	// gdigrab path grabs the window wherever it sits, so only size matters
	// there and a move must not cost a restart's stream gap.
	posSensitive bool
	valid        bool
}

func (g *launchGeometry) set(rect window.Rect, posSensitive bool) {
	g.mu.Lock()
	g.rect, g.posSensitive, g.valid = rect, posSensitive, true
	g.mu.Unlock()
}

// invalidate clears the record when a launch could not read the window at
// all: the supervisor's own retry loop owns that failure mode, and the
// watchdog must not spin restarts against a vanished window.
func (g *launchGeometry) invalidate() {
	g.mu.Lock()
	g.valid = false
	g.mu.Unlock()
}

func (g *launchGeometry) get() (rect window.Rect, posSensitive, valid bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.rect, g.posSensitive, g.valid
}

// geometryWatch wires the watchdog to the live pipeline (all callbacks are
// concurrency-safe on their own).
type geometryWatch struct {
	active     func() bool                // a session currently wants video
	clientRect func() (window.Rect, bool) // the game window's live client rect
	launched   func() (rect window.Rect, posSensitive, valid bool)
	restart    func(reason string) // relaunch the video pipeline (Supervisor.Restart)
	log        *slog.Logger
	// interval overrides geometryPollInterval when non-zero (tests only).
	interval time.Duration
}

// geometryWatchdog polls the live client rect while capture is active and
// requests a pipeline relaunch when it has settled (unchanged for one full
// tick — so a drag-in-progress is not fought) on a rect that differs from the
// running launch's record: a new size always, a new position only on the
// position-sensitive ddagrab path. After the relaunch the argv callback
// records the fresh rect, which naturally disarms the watchdog.
func geometryWatchdog(ctx context.Context, gw geometryWatch) {
	interval := gw.interval
	if interval <= 0 {
		interval = geometryPollInterval
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	var (
		prev   window.Rect
		prevOK bool
		// firedFor remembers the launch record a restart was already requested
		// against. Until the relaunch's argv callback records a DIFFERENT rect
		// (or invalidates the record), further ticks must not re-fire: a
		// relaunch slower than one poll tick would otherwise be charged a
		// second back-to-back restart — a doubled IDR gap for the same change.
		firedFor   window.Rect
		firedValid bool
	)
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if !gw.active() {
			prevOK, firedValid = false, false
			continue
		}
		cur, ok := gw.clientRect()
		if !ok {
			// Window unreadable (vanished, mid-destroy): ffmpeg dies on its
			// own and the supervisor retries; nothing for the watchdog to do.
			prevOK = false
			continue
		}
		launched, posSensitive, valid := gw.launched()
		if !valid {
			// The pending restart (if any) ran and could not read the window:
			// the record was invalidated, so the next valid launch re-arms —
			// even one that re-records the very rect that fired.
			firedValid = false
		} else {
			if firedValid && launched != firedFor {
				firedValid = false // relaunch landed: record refreshed, re-arm
			}
			differs := cur.W != launched.W || cur.H != launched.H ||
				(posSensitive && (cur.X != launched.X || cur.Y != launched.Y))
			// firedValid true here implies launched == firedFor (the re-arm
			// check above just ran): a restart is still pending, don't stack.
			if differs && prevOK && cur == prev && !firedValid {
				firedFor, firedValid = launched, true
				gw.restart(fmt.Sprintf(
					"game window changed under a running capture: %dx%d at (%d,%d) -> %dx%d at (%d,%d)",
					launched.W, launched.H, launched.X, launched.Y, cur.W, cur.H, cur.X, cur.Y))
			}
		}
		prev, prevOK = cur, true
	}
}
