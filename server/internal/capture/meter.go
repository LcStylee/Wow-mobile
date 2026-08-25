package capture

import (
	"sync"
	"time"
)

// Stats is a point-in-time reading of the video pipeline for the 1 Hz ctrl
// stats message.
type Stats struct {
	// PipelineDelayMs is an EWMA of how much later than the nominal frame
	// interval each access unit arrived from ffmpeg. It is reported in the
	// protocol's "encodeMs" field: ffmpeg exposes no per-frame encoder timing
	// over a pipe, so this capture→pipe pacing delay is the closest honest
	// proxy for encode cost.
	PipelineDelayMs float64
	CaptureFPS      float64
	Kbps            float64
}

// Meter accumulates per-access-unit counters and produces rate snapshots.
// Add is called from the capture goroutine, Snapshot from the ctrl-channel
// stats ticker.
type Meter struct {
	frameInterval time.Duration

	mu         sync.Mutex
	frames     uint64
	bytes      uint64
	lastAU     time.Time
	delayEWMA  float64 // ms
	lastSnap   time.Time
	lastFrames uint64
	lastBytes  uint64
}

func NewMeter(fps int) *Meter {
	return &Meter{frameInterval: time.Second / time.Duration(fps), lastSnap: time.Now()}
}

// Add records one delivered access unit.
func (m *Meter) Add(byteLen int) {
	now := time.Now()
	m.mu.Lock()
	defer m.mu.Unlock()
	m.frames++
	m.bytes += uint64(byteLen)
	if !m.lastAU.IsZero() {
		lateBy := float64(now.Sub(m.lastAU)-m.frameInterval) / float64(time.Millisecond)
		if lateBy < 0 {
			lateBy = 0 // early frames are pipe batching, not negative delay
		}
		const alpha = 0.1
		m.delayEWMA += alpha * (lateBy - m.delayEWMA)
	}
	m.lastAU = now
}

// Snapshot returns rates since the previous Snapshot call.
func (m *Meter) Snapshot() Stats {
	now := time.Now()
	m.mu.Lock()
	defer m.mu.Unlock()
	elapsed := now.Sub(m.lastSnap).Seconds()
	if elapsed <= 0 {
		elapsed = 1
	}
	st := Stats{
		PipelineDelayMs: m.delayEWMA,
		CaptureFPS:      float64(m.frames-m.lastFrames) / elapsed,
		Kbps:            float64(m.bytes-m.lastBytes) * 8 / 1000 / elapsed,
	}
	m.lastSnap = now
	m.lastFrames = m.frames
	m.lastBytes = m.bytes
	return st
}
