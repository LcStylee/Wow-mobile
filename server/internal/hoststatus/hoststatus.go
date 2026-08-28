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

// Stream is the live capture/encode reading.
type Stream struct {
	Kbps     float64 `json:"kbps"`
	FPS      float64 `json:"fps"`
	EncodeMs float64 `json:"encodeMs"`
}

// Status aggregates everything the dashboard shows. Create with New.
type Status struct {
	mu         sync.Mutex
	version    string
	steps      []Step
	encoder    string
	clientType string
	addonNote  string
	pairingURL string
	running    bool // serving (the wizard finished and the listener is up)
	phone      Phone

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
	ClientType string `json:"clientType"`
	AddonNote  string `json:"addonNote"`
	PairingURL string `json:"pairingUrl"`
	Phone      Phone  `json:"phone"`
	Stream     Stream `json:"stream"`
}

// JSON serializes the current state for GET /host/api/status.
func (s *Status) JSON() []byte {
	if s == nil {
		return []byte("{}")
	}
	s.mu.Lock()
	snap := snapshot{
		Version:    s.version,
		Running:    s.running,
		Steps:      append([]Step(nil), s.steps...),
		Encoder:    s.encoder,
		ClientType: s.clientType,
		AddonNote:  s.addonNote,
		PairingURL: s.pairingURL,
		Phone:      s.phone,
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
