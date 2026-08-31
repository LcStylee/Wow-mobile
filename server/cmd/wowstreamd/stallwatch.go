package main

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"
)

// captureStallAfter is how long an ACTIVE capture may deliver zero frames
// before the dashboard gets a loud, readable explanation (ffmpeg's stderr
// tail). Long enough to ride out a bitrate/keyframe restart, short enough
// that a user staring at a black phone learns why within seconds.
const captureStallAfter = 5 * time.Second

// captureStall wires the watchdog to the live pipeline (all callbacks are
// concurrency-safe on their own).
type captureStall struct {
	active func() bool     // a session currently wants video
	frames func() uint64   // monotonic access units delivered by ffmpeg
	stderr func() []string // stderr tail of the current/most recent ffmpeg
	warn   func(string)    // dashboard capture-warning row ("" clears)
	log    *slog.Logger
}

// captureStallWatchdog surfaces "capture is running but produces NOTHING" on
// the dashboard: while active and the frame counter does not advance for
// captureStallAfter, the warning row carries ffmpeg's stderr tail; any
// delivered frame (or the session ending) clears it.
func captureStallWatchdog(ctx context.Context, cs captureStall) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	var (
		lastFrames   uint64
		lastProgress = time.Now()
		warned       bool
	)
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if !cs.active() {
			lastProgress = time.Now()
			lastFrames = cs.frames()
			if warned {
				warned = false
				cs.warn("")
			}
			continue
		}
		if f := cs.frames(); f != lastFrames {
			lastFrames = f
			lastProgress = time.Now()
			if warned {
				warned = false
				cs.warn("")
				cs.log.Info("capture recovered: video frames flowing again")
			}
			continue
		}
		if stalled := time.Since(lastProgress); stalled >= captureStallAfter && !warned {
			warned = true
			msg := stallMessage(stalled, cs.stderr())
			cs.warn(msg)
			cs.log.Warn(msg)
		}
	}
}

// stallMessage builds the plain-language dashboard line for a stalled
// capture, quoting ffmpeg's own words when it said any.
func stallMessage(stalled time.Duration, stderrTail []string) string {
	msg := fmt.Sprintf("Capture is producing NO video frames (%d s and counting) — the stream is black.",
		int(stalled.Seconds()))
	if len(stderrTail) > 0 {
		const maxLines = 4
		if len(stderrTail) > maxLines {
			stderrTail = stderrTail[len(stderrTail)-maxLines:]
		}
		msg += " ffmpeg says: " + strings.Join(stderrTail, " | ")
	} else {
		msg += " ffmpeg reported nothing on stderr (is it starting at all?)."
	}
	return msg
}
