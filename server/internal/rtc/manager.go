// Package rtc owns the WebRTC side of a streaming session: the pion peer
// connection, the H.264/Opus sample tracks, the three client-created data
// channels, and the JSON control protocol. One session at a time, per
// PROTOCOL.md safety rule 3.
package rtc

import (
	"errors"
	"fmt"
	"log/slog"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/ice/v4"
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

	// VideoGeometry, when set, returns the geometry the encoder is CURRENTLY
	// producing — the game window's actual client area when it differs from
	// the configured resolution (the capture self-heals to the real window
	// rather than going black; see capture.EncodeSize). The hello reply uses
	// it so the phone always letterboxes the frame it really receives; nil
	// falls back to the static VideoWidth/VideoHeight.
	VideoGeometry func() (w, h int)

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

	// ICEUDPPort, when > 0, carries ALL WebRTC media and data over this one
	// UDP port (an ICE UDP mux) instead of a random port per session — the
	// precondition for remote play, where the router forwards exactly this
	// port. 0 keeps pion's ephemeral ports. If the port cannot be bound the
	// manager logs it and falls back to ephemeral ports.
	ICEUDPPort int

	Logger *slog.Logger
}

// Manager holds the single current session and the shared media tracks.
type Manager struct {
	opts Options

	apiMu    sync.Mutex
	api      *webrtc.API
	udpMux   ice.UDPMux // nil: ephemeral ports
	publicIP string     // advertised in addition to the LAN addresses (remote play)

	videoTrack *webrtc.TrackLocalStaticSample
	audioTrack *webrtc.TrackLocalStaticSample // nil when audio is disabled
	frameDur   time.Duration

	mu      sync.Mutex
	current *session

	kfMu            sync.Mutex
	lastKeyframeReq time.Time

	// framesSent counts video samples handed to the track (capture
	// diagnostics: captured-but-not-sent means the write path is broken).
	framesSent atomic.Uint64
}

// sctpRTOMax caps SCTP's retransmission backoff (see NewManager).
const sctpRTOMax = 2 * time.Second

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

	if opts.ICEUDPPort > 0 {
		conn, err := net.ListenUDP("udp4", &net.UDPAddr{Port: opts.ICEUDPPort})
		if err != nil {
			opts.Logger.Warn("WebRTC UDP port unavailable; using random ports (remote play needs it)",
				"port", opts.ICEUDPPort, "err", err)
		} else {
			m.udpMux = webrtc.NewICEUDPMux(nil, conn)
		}
	}
	api, err := m.buildAPI("")
	if err != nil {
		return nil, err
	}
	m.api = api

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

// buildAPI assembles the pion API: codecs, interceptors, SCTP tuning, the
// shared UDP port and — when publicIP is set — that public address
// advertised NEXT TO every LAN host candidate on the same port (remote
// play: the router forwards the port to this PC, so the phone on mobile data
// reaches it there, while a phone at home still pairs on the LAN address).
// A fresh MediaEngine per API: pion does not share them between APIs.
func (m *Manager) buildAPI(publicIP string) (*webrtc.API, error) {
	opts := m.opts
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
	// SCTP (every data channel: input, move, ctrl) backs its retransmission
	// timer off exponentially up to 60 s by default. After a Wi-Fi gap —
	// roaming between access points — that left the server answering
	// nothing for up to a minute while video (SRTP, not SCTP) played on
	// (field report v0.6.5). On a LAN, 2 s is still far above any real RTT.
	var se webrtc.SettingEngine
	se.SetSCTPRTOMax(sctpRTOMax)
	if m.udpMux != nil {
		se.SetICEUDPMux(m.udpMux)
		if publicIP != "" {
			if err := se.SetICEAddressRewriteRules(webrtc.ICEAddressRewriteRule{
				External:        []string{publicIP},
				AsCandidateType: webrtc.ICECandidateTypeHost,
				Mode:            webrtc.ICEAddressRewriteAppend,
			}); err != nil {
				return nil, fmt.Errorf("advertising the public address: %w", err)
			}
		}
	}
	return webrtc.NewAPI(webrtc.WithMediaEngine(engine), webrtc.WithInterceptorRegistry(registry),
		webrtc.WithSettingEngine(se)), nil
}

// SetPublicIP advertises ip (remote play) to every session created from now
// on; "" stops advertising it. Running sessions keep what they negotiated.
// No-op without the shared UDP port: a public address is only reachable
// through the one port the router forwards.
func (m *Manager) SetPublicIP(ip string) error {
	if m.udpMux == nil && ip != "" {
		return errors.New("remote play needs the fixed WebRTC UDP port, which could not be opened")
	}
	m.apiMu.Lock()
	defer m.apiMu.Unlock()
	if ip == m.publicIP {
		return nil
	}
	api, err := m.buildAPI(ip)
	if err != nil {
		return err
	}
	m.api, m.publicIP = api, ip
	return nil
}

// newPeerConnection creates a peer connection from the current API.
func (m *Manager) newPeerConnection() (*webrtc.PeerConnection, error) {
	m.apiMu.Lock()
	api := m.api
	m.apiMu.Unlock()
	return api.NewPeerConnection(webrtc.Configuration{})
}

// WriteVideoAU feeds one H.264 access unit to the connected client (no-op
// when the track is unbound). Duration paces the RTP timestamps at 1/fps.
func (m *Manager) WriteVideoAU(au capture.AccessUnit) {
	if err := m.videoTrack.WriteSample(media.Sample{Data: au.Data, Duration: m.frameDur}); err != nil {
		m.opts.Logger.Warn("video WriteSample failed", "err", err)
		return
	}
	m.framesSent.Add(1)
}

// FramesSent is the total video samples successfully written to the track —
// the "sent" half of the capture diagnostics on the host dashboard.
func (m *Manager) FramesSent() uint64 { return m.framesSent.Load() }

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

// SessionConnected reports whether the current phone session's peer
// connection has reached Connected (and not yet ended) — the host dashboard's
// "phone connected" light. A session that disconnects clears itself via
// sessionEnded, so a stale true is impossible.
func (m *Manager) SessionConnected() bool {
	m.mu.Lock()
	sess := m.current
	m.mu.Unlock()
	if sess == nil {
		return false
	}
	select {
	case <-sess.connected:
		return true
	default:
		return false
	}
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
