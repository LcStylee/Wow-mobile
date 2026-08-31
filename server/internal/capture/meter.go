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
	// FramesCaptured is the total access units delivered by ffmpeg since
	// startup — 0 with a connected phone means capture itself is dead.
	FramesCaptured uint64
	// LastKeyframeAgeMs is how old the newest IDR is; -1 before the first
	// one. A healthy 2 s GOP keeps this under ~2000 ms — anything higher with
	// a black phone screen points at the keyframe path, not the network.
	LastKeyframeAgeMs float64
}

// Meter accumulates per-access-unit counters and produces rate snapshots.
// Add is called from the capture goroutine, Snapshot from the ctrl-channel
// stats ticker.
type Meter struct {
	frameInterval time.Duration

	mu           sync.Mutex
	frames       uint64
	bytes        uint64
	lastAU       time.Time
	lastKeyframe time.Time // zero until the first IDR
	delayEWMA    float64   // ms
	lastSnap     time.Time
	lastFrames   uint64
	lastBytes    uint64
}

func NewMeter(fps int) *Meter {
	return &Meter{frameInterval: time.Second / time.Duration(fps), lastSnap: time.Now()}
}

// Add records one delivered access unit; keyframe marks an IDR (feeds the
// last-keyframe-age diagnostic).
func (m *Meter) Add(byteLen int, keyframe bool) {
	now := time.Now()
	m.mu.Lock()
	defer m.mu.Unlock()
	m.frames++
	m.bytes += uint64(byteLen)
	if keyframe {
		m.lastKeyframe = now
	}
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

// TotalFrames returns the monotonic count of access units delivered since
// startup. Unlike Snapshot it perturbs no rate baselines, so watchdogs can
// poll it freely without skewing the stats loops.
func (m *Meter) TotalFrames() uint64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.frames
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
		PipelineDelayMs:   m.delayEWMA,
		CaptureFPS:        float64(m.frames-m.lastFrames) / elapsed,
		Kbps:              float64(m.bytes-m.lastBytes) * 8 / 1000 / elapsed,
		FramesCaptured:    m.frames,
		LastKeyframeAgeMs: -1,
	}
	if !m.lastKeyframe.IsZero() {
		st.LastKeyframeAgeMs = float64(now.Sub(m.lastKeyframe)) / float64(time.Millisecond)
	}
	m.lastSnap = now
	m.lastFrames = m.frames
	m.lastBytes = m.bytes
	return st
}
