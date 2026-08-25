// Package rtc owns the WebRTC side of a streaming session: the pion peer
// connection, the H.264/Opus sample tracks, the three client-created data
// channels, and the JSON control protocol. One session at a time, per
// PROTOCOL.md safety rule 3.
package rtc

import (
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"

	"github.com/LcStylee/Wow-mobile/server/internal/capture"
	"github.com/LcStylee/Wow-mobile/server/internal/input"
)

// serverName is sent in the hello reply.
const serverName = "wowstreamd/1.0"

// Protocol version implemented by this server (PROTOCOL.md v1).
const (
	protoMajor = 1
	protoMinor = 0
)

// Options wires the manager to the rest of the host.
type Options struct {
	VideoWidth  int
	VideoHeight int
	FPS         int
	Audio       bool

	// NewInjector creates the platform injector for a session.
	NewInjector func() (input.Injector, error)
	// SetActive is invoked with true when a session exists and false when
	// none does; the host starts/stops the ffmpeg pipelines accordingly.
	SetActive func(bool)
	// SetBitrate applies a client-requested bitrate (via encoder restart).
	SetBitrate func(kbps int)
	// ForceKeyframe makes the video stream deliver a fresh IDR as soon as
	// possible (via encoder restart; see capture.Supervisor.ForceKeyframe).
	// Invoked, rate-limited, on client PLI/FIR and on peer connect.
	ForceKeyframe func()
	// VideoStats feeds the 1 Hz stats message.
	VideoStats func() capture.Stats

	Logger *slog.Logger
}

// Manager holds the single current session and the shared media tracks.
type Manager struct {
	opts Options
	api  *webrtc.API

	videoTrack *webrtc.TrackLocalStaticSample
	audioTrack *webrtc.TrackLocalStaticSample // nil when audio is disabled
	frameDur   time.Duration

	mu      sync.Mutex
	current *session

	kfMu            sync.Mutex
	lastKeyframeReq time.Time
}

// ErrNoSession is returned for operations on an unknown/replaced session id.
var ErrNoSession = errors.New("rtc: no such session")

// ErrSessionNegotiated is returned for a repeat offer on a session that
// already completed its (single, WHEP-style) SDP exchange.
var ErrSessionNegotiated = errors.New("rtc: session already negotiated")

// keyframeMinInterval rate-limits keyframe-on-demand. Each request restarts
// ffmpeg — the only IDR mechanism available over a pipe — so a PLI storm on a
// lossy link must never become a restart storm.
const keyframeMinInterval = time.Second

// requestKeyframe forwards a keyframe demand to the capture pipeline, at most
// once per keyframeMinInterval. Browsers repeat PLI until a keyframe arrives,
// so a suppressed request is retried by the client, not lost.
func (m *Manager) requestKeyframe(reason string) {
	m.kfMu.Lock()
	if time.Since(m.lastKeyframeReq) < keyframeMinInterval {
		m.kfMu.Unlock()
		return
	}
	m.lastKeyframeReq = time.Now()
	m.kfMu.Unlock()
	m.opts.Logger.Info("keyframe requested", "reason", reason)
	m.opts.ForceKeyframe()
}

func NewManager(opts Options) (*Manager, error) {
	m := &Manager{opts: opts, frameDur: time.Second / time.Duration(opts.FPS)}

	// Register exactly what we send. H.264 constrained baseline with
	// packetization-mode=1 per the protocol; the ffmpeg pipelines are built
	// to emit matching bitstreams.
	engine := &webrtc.MediaEngine{}
	if err := engine.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeH264,
			ClockRate:   90000,
			SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
		},
		PayloadType: 102,
	}, webrtc.RTPCodecTypeVideo); err != nil {
		return nil, fmt.Errorf("registering H.264: %w", err)
	}
	if opts.Audio {
		if err := engine.RegisterCodec(webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:    webrtc.MimeTypeOpus,
				ClockRate:   48000,
				Channels:    2,
				SDPFmtpLine: "minptime=10;useinbandfec=1",
			},
			PayloadType: 111,
		}, webrtc.RTPCodecTypeAudio); err != nil {
			return nil, fmt.Errorf("registering Opus: %w", err)
		}
	}
	// Default interceptors provide NACK/RTCP feedback — WebRTC's loss
	// recovery on flaky Wi-Fi.
	registry := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(engine, registry); err != nil {
		return nil, fmt.Errorf("registering interceptors: %w", err)
	}
	m.api = webrtc.NewAPI(webrtc.WithMediaEngine(engine), webrtc.WithInterceptorRegistry(registry))

	var err error
	m.videoTrack, err = webrtc.NewTrackLocalStaticSample(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264},
		"video", "wowstream")
	if err != nil {
		return nil, fmt.Errorf("creating video track: %w", err)
	}
	if opts.Audio {
		m.audioTrack, err = webrtc.NewTrackLocalStaticSample(
			webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus},
			"audio", "wowstream")
		if err != nil {
			return nil, fmt.Errorf("creating audio track: %w", err)
		}
	}
	return m, nil
}

// WriteVideoAU feeds one H.264 access unit to the connected client (no-op
// when the track is unbound). Duration paces the RTP timestamps at 1/fps.
func (m *Manager) WriteVideoAU(au capture.AccessUnit) {
	if err := m.videoTrack.WriteSample(media.Sample{Data: au.Data, Duration: m.frameDur}); err != nil {
		m.opts.Logger.Warn("video WriteSample failed", "err", err)
	}
}

// WriteAudio feeds one Opus packet.
func (m *Manager) WriteAudio(packet []byte, duration time.Duration) {
	if m.audioTrack == nil {
		return
	}
	if err := m.audioTrack.WriteSample(media.Sample{Data: packet, Duration: duration}); err != nil {
		m.opts.Logger.Warn("audio WriteSample failed", "err", err)
	}
}

// Create registers a new session id, replacing (and erroring out) any
// existing session per safety rule 3. On a replace the capture pipelines are
// already running mid-GOP; the new client gets a decodable stream via the
// keyframe forced when its peer connection reaches Connected (session.go).
func (m *Manager) Create(id string) {
	m.mu.Lock()
	old := m.current
	sess := newSession(id, m)
	m.current = sess
	m.mu.Unlock()
	if old != nil {
		old.close("replaced", "another client connected")
	}
	m.opts.SetActive(true)
	go sess.connectWatchdog()
	m.opts.Logger.Info("session created", "id", id, "replaced", old != nil)
}

// Offer performs the WHEP-style SDP exchange for session id.
func (m *Manager) Offer(id, offerSDP string) (string, error) {
	m.mu.Lock()
	sess := m.current
	m.mu.Unlock()
	if sess == nil || sess.id != id {
		return "", ErrNoSession
	}
	return sess.negotiate(offerSDP)
}

// Close tears down session id (client DELETE or HTTP-layer teardown).
func (m *Manager) Close(id string) error {
	m.mu.Lock()
	sess := m.current
	m.mu.Unlock()
	if sess == nil || sess.id != id {
		return ErrNoSession
	}
	sess.close("", "")
	return nil
}

// Shutdown tears down any live session; used on process exit so all held
// inputs are released before ffmpeg dies.
func (m *Manager) Shutdown() {
	m.mu.Lock()
	sess := m.current
	m.mu.Unlock()
	if sess != nil {
		sess.close("shutdown", "server shutting down")
	}
}

// sessionEnded is called by a session once it is fully closed.
func (m *Manager) sessionEnded(s *session) {
	m.mu.Lock()
	wasCurrent := m.current == s
	if wasCurrent {
		m.current = nil
	}
	m.mu.Unlock()
	if wasCurrent {
		m.opts.SetActive(false)
	}
}
