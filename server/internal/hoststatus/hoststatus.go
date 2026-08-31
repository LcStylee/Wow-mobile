// Package hoststatus is the shared, concurrency-safe state behind the host
// dashboard (GET /host/api/status): the wizard records its step states here as
// it runs, the signal server records phone pairing info, and main wires in
// live callbacks (session connected, stream stats). The package is portable
// and has no Windows or HTTP dependencies — the signal server serializes it.
//
// Every method is nil-safe on the receiver so callers (the wizard in
// particular) never need to guard "is a dashboard attached?".
package hoststatus

import (
	"encoding/json"
	"sync"
)

// Step states shown on the dashboard checklist.
const (
	StatePending = "pending" // not reached yet
	StateRunning = "running" // in progress (e.g. "installing FFmpeg…")
	StateOK      = "ok"      // satisfied
	StateSkipped = "skipped" // deliberately not done (e.g. addon on 1.12)
	StateFailed  = "failed"  // errored; detail carries the message
)

// Step is one wizard checklist entry.
type Step struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	State  string `json:"state"`
	Detail string `json:"detail"`
}

// Phone describes the paired phone as far as the host knows.
type Phone struct {
	Connected bool   `json:"connected"`
	Remote    string `json:"remote"`
	UserAgent string `json:"userAgent"`
}

// Stream is the live capture/encode reading, including the capture
// diagnostics that make a black phone screen debuggable at a glance: total
// access units out of ffmpeg vs. samples handed to the WebRTC track, and how
// stale the last keyframe is (a healthy 2 s GOP keeps it under ~2000 ms;
// "no keyframe yet" is -1).
type Stream struct {
	Kbps     float64 `json:"kbps"`
	FPS      float64 `json:"fps"`
	EncodeMs float64 `json:"encodeMs"`
	// FramesCaptured counts access units delivered by ffmpeg since startup.
	FramesCaptured uint64 `json:"framesCaptured"`
	// FramesSent counts video samples written to the WebRTC track.
	FramesSent uint64 `json:"framesSent"`
	// LastKeyframeAgeMs is the age of the newest captured IDR; -1 until one
	// has been seen (0 frames + -1 here = capture never produced anything).
	LastKeyframeAgeMs float64 `json:"lastKeyframeAgeMs"`
}

// Status aggregates everything the dashboard shows. Create with New.
type Status struct {
	mu         sync.Mutex
	version    string
	steps      []Step
	encoder    string
	resolution string // decided capture resolution "WxH" (monitor-fitted or explicit)
	clientType string
	addonNote  string
	warning    string // loud misconfiguration banner (e.g. window/resolution mismatch); "" = none
	// captureWarning is the live capture-health banner: set while the running
	// capture yields no frames (with ffmpeg's stderr tail), cleared when
	// frames flow again. Kept separate from warning so a geometry mismatch
	// and a dead encoder can both be shown.
	captureWarning string
	// selfCheck is the startup video-pipeline probe verdict: "video pipeline
	// OK (N frames)" or the ffmpeg stderr tail explaining the failure.
	selfCheck   string
	selfCheckOK bool
	pairingURL  string
	running     bool // serving (the wizard finished and the listener is up)
	phone       Phone

	// Live callbacks, optional. Called (unlocked) at snapshot time.
	connectedFn func() bool
	statsFn     func() Stream
}

// New creates a Status pre-populated with the wizard checklist in order, all
// pending.
func New(version string, steps ...Step) *Status {
	s := &Status{version: version, steps: make([]Step, len(steps))}
	copy(s.steps, steps)
	for i := range s.steps {
		if s.steps[i].State == "" {
			s.steps[i].State = StatePending
		}
	}
	return s
}

// SetStep updates one checklist entry by id (unknown ids are ignored — the
// wizard cannot crash the dashboard).
func (s *Status) SetStep(id, state, detail string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.steps {
		if s.steps[i].ID == id {
			s.steps[i].State = state
			s.steps[i].Detail = detail
			return
		}
	}
}

// SetEncoder records the chosen FFmpeg encoder (e.g. "h264_nvenc").
func (s *Status) SetEncoder(encoder string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.encoder = encoder
}

// SetResolution records the decided capture resolution ("590x1048") — the
// monitor-fitted portrait window, or the explicit --resolution value.
func (s *Status) SetResolution(res string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.resolution = res
}

// SetClientType records "classicEra"/"legacy" for the dashboard.
func (s *Status) SetClientType(ct string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.clientType = ct
}

// SetAddonNote sets the persistent dashboard note (legacy 1.12 clients: the
// WowMobile_Vanilla port was installed — enable it at character select); ""
// clears it.
func (s *Status) SetAddonNote(note string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.addonNote = note
}

// SetWarning sets (or, with "", clears) the dashboard's warning row — the
// loud surface for a live misconfiguration the stream is working around,
// e.g. "WoW window is 1080x1040 but 1080x1920 is configured". Distinct from
// a failed step: the host keeps running, degraded but visible.
func (s *Status) SetWarning(msg string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.warning = msg
}

// SetCaptureWarning sets (or, with "", clears) the live capture-health
// banner: shown while the running capture produces no video frames, carrying
// ffmpeg's stderr tail so the user can READ why video is missing.
func (s *Status) SetCaptureWarning(msg string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.captureWarning = msg
}

// SetSelfCheck records the startup video-pipeline probe verdict.
func (s *Status) SetSelfCheck(ok bool, detail string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.selfCheckOK = ok
	s.selfCheck = detail
}

// SetPairingURL records the phone pairing URL (token included). The /host
// routes that expose it are loopback-only — see signal.LoopbackOnly.
func (s *Status) SetPairingURL(url string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pairingURL = url
}

// PairingURL returns the recorded pairing URL ("" until the listener is up).
func (s *Status) PairingURL() string {
	if s == nil {
		return ""
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.pairingURL
}

// SetRunning marks the server as up and serving.
func (s *Status) SetRunning(running bool) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.running = running
}

// SetPhoneInfo records the most recent successful pairing's request metadata.
func (s *Status) SetPhoneInfo(remote, userAgent string) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.phone.Remote = remote
	s.phone.UserAgent = userAgent
}

// SetConnectedFunc wires the live "is a phone session connected" probe.
func (s *Status) SetConnectedFunc(fn func() bool) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.connectedFn = fn
}

// SetStatsFunc wires the live stream-stats probe (only consulted while a
// phone is connected).
func (s *Status) SetStatsFunc(fn func() Stream) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.statsFn = fn
}

// snapshot is the JSON shape of GET /host/api/status.
type snapshot struct {
	Version    string `json:"version"`
	Running    bool   `json:"running"`
	Steps      []Step `json:"steps"`
	Encoder    string `json:"encoder"`
	Resolution string `json:"resolution"`
	ClientType string `json:"clientType"`
	AddonNote  string `json:"addonNote"`
	Warning    string `json:"warning"`
	// CaptureWarning is the live capture-health banner (dead encoder / no
	// frames), with ffmpeg's stderr tail; "" = healthy.
	CaptureWarning string `json:"captureWarning"`
	// SelfCheck is the startup pipeline probe verdict line; SelfCheckOK
	// distinguishes "OK" from a probe that failed (and from "still running",
	// when SelfCheck is empty).
	SelfCheck   string `json:"selfCheck"`
	SelfCheckOK bool   `json:"selfCheckOk"`
	PairingURL  string `json:"pairingUrl"`
	Phone       Phone  `json:"phone"`
	Stream      Stream `json:"stream"`
}

// JSON serializes the current state for GET /host/api/status.
func (s *Status) JSON() []byte {
	if s == nil {
		return []byte("{}")
	}
	s.mu.Lock()
	snap := snapshot{
		Version:        s.version,
		Running:        s.running,
		Steps:          append([]Step(nil), s.steps...),
		Encoder:        s.encoder,
		Resolution:     s.resolution,
		ClientType:     s.clientType,
		AddonNote:      s.addonNote,
		Warning:        s.warning,
		CaptureWarning: s.captureWarning,
		SelfCheck:      s.selfCheck,
		SelfCheckOK:    s.selfCheckOK,
		PairingURL:     s.pairingURL,
		Phone:          s.phone,
	}
	connectedFn, statsFn := s.connectedFn, s.statsFn
	s.mu.Unlock()

	// Probes run unlocked: they reach into other subsystems (rtc, capture)
	// whose locks must never nest under ours.
	if connectedFn != nil {
		snap.Phone.Connected = connectedFn()
	}
	if snap.Phone.Connected && statsFn != nil {
		snap.Stream = statsFn()
	}
	data, err := json.Marshal(snap)
	if err != nil {
		return []byte("{}") // cannot happen for this shape
	}
	return data
}
