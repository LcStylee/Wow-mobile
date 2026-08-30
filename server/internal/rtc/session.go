package rtc

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"

	"github.com/LcStylee/Wow-mobile/server/internal/capture"
	"github.com/LcStylee/Wow-mobile/server/internal/input"
)

// connectTimeout bounds how long a created session may exist without a live
// peer connection. Capture starts at POST /api/session (hiding the ffmpeg
// spawn latency from the connect path), so a client that never follows up
// with an offer must not leave the encoder running for nobody.
const connectTimeout = 30 * time.Second

// session is one phone connection: peer connection, input processor, and the
// three client-created data channels.
type session struct {
	id  string
	mgr *Manager
	log *slog.Logger

	mu        sync.Mutex
	pc        *webrtc.PeerConnection
	ctrl      *webrtc.DataChannel
	proc      *input.Processor
	helloSeen bool
	closed    bool
	stopBG    chan struct{} // closes the dead-man/stats/watchdog goroutines

	connected     chan struct{} // closed when the peer connection connects
	connectedOnce sync.Once
}

func newSession(id string, mgr *Manager) *session {
	return &session{
		id:        id,
		mgr:       mgr,
		log:       mgr.opts.Logger.With("session", id),
		stopBG:    make(chan struct{}),
		connected: make(chan struct{}),
	}
}

// negotiate builds the peer connection for the client's SDP offer and returns
// the answer with ICE candidates already gathered (non-trickle, per the
// WHEP-style single POST exchange).
func (s *session) negotiate(offerSDP string) (_ string, retErr error) {
	inj, err := s.mgr.opts.NewInjector()
	if err != nil {
		return "", fmt.Errorf("creating input injector: %w", err)
	}

	// LAN-only by design: host candidates suffice, no STUN/TURN.
	pc, err := s.mgr.api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		return "", fmt.Errorf("creating peer connection: %w", err)
	}

	s.mu.Lock()
	switch {
	case s.closed:
		s.mu.Unlock()
		pc.Close() //nolint:errcheck
		return "", ErrNoSession
	case s.pc != nil:
		// WHEP is one offer/answer per session. Silently replacing the pair
		// here would orphan the previous processor's held-input ledger (its
		// channels stay live but close() only acts on the current processor),
		// violating safety rule 2 — so a repeat offer is rejected instead.
		s.mu.Unlock()
		pc.Close() //nolint:errcheck
		return "", ErrSessionNegotiated
	}
	s.pc = pc
	proc := input.NewProcessor(inj, nil)
	s.proc = proc
	s.mu.Unlock()

	// A failed negotiation must not strand a half-built peer connection: the
	// pc is closed and the slots cleared so the client may retry the offer.
	defer func() {
		if retErr != nil {
			s.mu.Lock()
			s.pc, s.proc = nil, nil
			s.mu.Unlock()
			pc.Close() //nolint:errcheck
		}
	}()

	videoSender, err := pc.AddTrack(s.mgr.videoTrack)
	if err != nil {
		return "", fmt.Errorf("adding video track: %w", err)
	}
	// A session's track starting mid-stream must get an IDR immediately, not
	// after up to a 2 s GOP: demand one right when the track is added, on top
	// of the peer-connected demand below. Both funnel through
	// requestKeyframe's cooldown (keyframeMinInterval) and the supervisor's
	// fresh-process exemption, so the pair can never become a restart storm —
	// and a demand suppressed by either guard is retried by the browser's PLI.
	s.mgr.requestKeyframe("video track added")
	go forwardRTCP(videoSender, func() { s.mgr.requestKeyframe("client PLI/FIR") })
	if s.mgr.audioTrack != nil {
		audioSender, err := pc.AddTrack(s.mgr.audioTrack)
		if err != nil {
			return "", fmt.Errorf("adding audio track: %w", err)
		}
		go forwardRTCP(audioSender, nil)
	}

	// The client creates all three channels (PROTOCOL.md); we only accept.
	pc.OnDataChannel(s.onDataChannel)

	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		s.log.Info("connection state", "state", state.String())
		switch state {
		case webrtc.PeerConnectionStateConnected:
			s.connectedOnce.Do(func() { close(s.connected) })
			// The client joins an already-running stream: mid-GOP on a session
			// replace, or having missed ffmpeg's opening IDR (written before
			// the track was bound) on a first connect. Without a fresh IDR the
			// screen would stay black for up to one GOP (2 s).
			s.mgr.requestKeyframe("peer connected")
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
			s.close("", "")
		}
	})

	if err := pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer, SDP: offerSDP,
	}); err != nil {
		return "", fmt.Errorf("applying offer: %w", err)
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return "", fmt.Errorf("creating answer: %w", err)
	}
	gathered := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(answer); err != nil {
		return "", fmt.Errorf("applying answer: %w", err)
	}
	<-gathered

	go s.deadmanLoop(proc)
	return pc.LocalDescription().SDP, nil
}

// connectWatchdog tears the session down if no peer connection materializes
// within connectTimeout. Started at session creation, i.e. before negotiate.
func (s *session) connectWatchdog() {
	select {
	case <-s.connected:
	case <-s.stopBG:
	case <-time.After(connectTimeout):
		s.log.Warn("no WebRTC connection established, tearing session down",
			"timeout", connectTimeout)
		s.close("timeout", "no WebRTC connection was established in time")
	}
}

func (s *session) onDataChannel(dc *webrtc.DataChannel) {
	// Snapshot the processor: handlers must keep routing to the processor
	// that was current when the channel appeared, even if a failed
	// renegotiation clears s.proc afterwards.
	s.mu.Lock()
	proc := s.proc
	s.mu.Unlock()
	if proc == nil {
		// The channel raced a failed (and cleaned-up) negotiation.
		dc.Close() //nolint:errcheck
		return
	}
	switch dc.Label() {
	case "input":
		dc.OnMessage(func(msg webrtc.DataChannelMessage) {
			s.handleBinary(msg, proc.HandleReliable)
		})
		dc.OnClose(proc.ReleaseAllHeld) // safety rule 2
	case "move":
		dc.OnMessage(func(msg webrtc.DataChannelMessage) {
			s.handleBinary(msg, proc.HandleLossy)
		})
		dc.OnClose(proc.ReleaseAllHeld)
	case "ctrl":
		s.mu.Lock()
		s.ctrl = dc
		s.mu.Unlock()
		dc.OnMessage(func(msg webrtc.DataChannelMessage) { s.handleCtrl(msg.Data) })
	default:
		s.log.Warn("unexpected data channel", "label", dc.Label())
		dc.Close() //nolint:errcheck
	}
}

// handleBinary routes an input/move message into the processor and applies
// the spec's error contract: a protocol violation is fatal — the error is
// sent and the whole session closes (PROTOCOL.md: "fatal; connection closes
// after"); the processor has already released everything. Injection failures
// are logged only.
func (s *session) handleBinary(msg webrtc.DataChannelMessage, handle func([]byte) error) {
	if err := handle(msg.Data); err != nil {
		if errors.Is(err, input.ErrProtocol) {
			s.log.Error("input protocol violation, closing session", "err", err)
			s.close("protocol", err.Error())
			return
		}
		s.log.Warn("input injection failed", "err", err)
	}
}

// Control messages (PROTOCOL.md "JSON control messages").
type ctrlEnvelope struct {
	T     string `json:"t"`
	Proto []int  `json:"proto,omitempty"`
	Kbps  int    `json:"kbps,omitempty"`
}

type ctrlHello struct {
	T      string    `json:"t"`
	Proto  [2]int    `json:"proto"`
	Server string    `json:"server"`
	Video  ctrlVideo `json:"video"`
}

type ctrlVideo struct {
	W   int `json:"w"`
	H   int `json:"h"`
	FPS int `json:"fps"`
}

type ctrlStats struct {
	T string `json:"t"`
	// EncodeMs carries capture.Stats.PipelineDelayMs: an EWMA of how late
	// each access unit left ffmpeg versus the nominal frame interval — the
	// closest measurable proxy for encode cost over a pipe (ffmpeg exposes no
	// per-frame encoder timing there). The wire name is fixed by PROTOCOL.md;
	// clients should read it as "encode-side pipeline delay".
	EncodeMs   float64 `json:"encodeMs"`
	CaptureFPS float64 `json:"captureFps"`
	Kbps       float64 `json:"kbps"`
}

type ctrlError struct {
	T    string `json:"t"`
	Code string `json:"code"`
	Msg  string `json:"msg"`
}

func (s *session) handleCtrl(raw []byte) {
	var env ctrlEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		s.log.Warn("malformed ctrl message", "err", err)
		return
	}
	switch env.T {
	case "hello":
		if len(env.Proto) < 1 || env.Proto[0] > protoMajor {
			// Normative: a higher major version than we speak => disconnect.
			s.close("proto", fmt.Sprintf("unsupported protocol version %v (server speaks %d.%d)", env.Proto, protoMajor, protoMinor))
			return
		}
		s.mu.Lock()
		first := !s.helloSeen
		s.helloSeen = true
		s.mu.Unlock()
		// Advertise the geometry the encoder is actually producing, not the
		// configured one: when WoW ignored the configured resolution the
		// capture self-heals to the real window (capture.EncodeSize), and a
		// hello claiming the configured size would make the phone letterbox
		// and gesture-map against a frame that never arrives.
		vw, vh := s.mgr.opts.VideoWidth, s.mgr.opts.VideoHeight
		if s.mgr.opts.VideoGeometry != nil {
			vw, vh = s.mgr.opts.VideoGeometry()
		}
		s.sendCtrl(ctrlHello{
			T:      "hello",
			Proto:  [2]int{protoMajor, protoMinor},
			Server: serverName,
			Video:  ctrlVideo{W: vw, H: vh, FPS: s.mgr.opts.FPS},
		})
		if first {
			go s.statsLoop()
		}
	case "latencyProbe":
		// Echoed byte-for-byte: the client compares tSent against arrival.
		// Must go out via SendText: every ctrl message is JSON text, and pion
		// v4's DataChannel.Send transmits a *binary* message (the browser
		// would receive a Blob its JSON.parse cannot touch), while SendText
		// keeps the WebRTC string framing the contract requires.
		s.mu.Lock()
		ctrl := s.ctrl
		s.mu.Unlock()
		if ctrl != nil {
			if err := ctrl.SendText(string(raw)); err != nil {
				s.log.Warn("latencyProbe echo failed", "err", err)
			}
		}
	case "bitrate":
		// Honest contract: applied by restarting ffmpeg with the new rate —
		// none of the supported encoders can be retuned through a pipe — so
		// the stream hiccups for roughly a process spawn plus one IDR.
		// Same limits as --bitrate-kbps: the client can request the full
		// configurable range, no more.
		if env.Kbps < capture.MinBitrateKbps || env.Kbps > capture.MaxBitrateKbps {
			s.log.Warn("ignoring out-of-range bitrate request", "kbps", env.Kbps)
			return
		}
		s.mgr.opts.SetBitrate(env.Kbps)
	default:
		s.log.Warn("unknown ctrl message", "t", env.T)
	}
}

func (s *session) sendCtrl(v any) {
	s.mu.Lock()
	ctrl := s.ctrl
	s.mu.Unlock()
	if ctrl == nil {
		return
	}
	raw, err := json.Marshal(v)
	if err != nil {
		s.log.Error("marshalling ctrl message", "err", err)
		return
	}
	if err := ctrl.SendText(string(raw)); err != nil {
		s.log.Warn("ctrl send failed", "err", err)
	}
}

// statsLoop emits the 1 Hz stats message after hello.
func (s *session) statsLoop() {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-s.stopBG:
			return
		case <-t.C:
			st := s.mgr.opts.VideoStats()
			s.sendCtrl(ctrlStats{
				T:          "stats",
				EncodeMs:   round1(st.PipelineDelayMs),
				CaptureFPS: round1(st.CaptureFPS),
				Kbps:       round1(st.Kbps),
			})
		}
	}
}

// deadmanLoop enforces the 3 s held-input timeout. 250 ms polling bounds the
// worst-case release at 3.25 s, well inside "the frozen client's W key stops
// promptly".
func (s *session) deadmanLoop(proc *input.Processor) {
	t := time.NewTicker(250 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-s.stopBG:
			return
		case <-t.C:
			if proc.CheckDeadman() {
				s.log.Warn("dead-man timeout: released all held inputs")
			}
		}
	}
}

func round1(v float64) float64 {
	return float64(int(v*10+0.5)) / 10
}

// close tears the session down exactly once. A non-empty code is sent as a
// fatal ctrl error first (e.g. "replaced").
func (s *session) close(code, msg string) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	pc, proc := s.pc, s.proc
	s.mu.Unlock()

	if code != "" {
		s.sendCtrl(ctrlError{T: "error", Code: code, Msg: msg})
		// SCTP gives no flush primitive; a short grace period lets the error
		// reach the client before the transport is torn down.
		time.Sleep(150 * time.Millisecond)
	}
	close(s.stopBG)
	if proc != nil {
		proc.ReleaseAllHeld() // safety rule 2: never leave inputs stuck
	}
	if pc != nil {
		pc.Close() //nolint:errcheck
	}
	s.mgr.sessionEnded(s)
	s.log.Info("session closed", "code", code)
}

// forwardRTCP consumes one sender's RTCP stream (keeping the interceptor
// feedback path — NACK loss recovery — pumped) and, when onPLI is set,
// reports PLI/FIR: the client saying it holds no decodable picture and needs
// an IDR. "nack pli" is negotiated by RegisterDefaultInterceptors, so
// browsers do send these.
func forwardRTCP(sender *webrtc.RTPSender, onPLI func()) {
	for {
		pkts, _, err := sender.ReadRTCP()
		if err != nil {
			return
		}
		if onPLI == nil {
			continue
		}
		for _, pkt := range pkts {
			switch pkt.(type) {
			case *rtcp.PictureLossIndication, *rtcp.FullIntraRequest:
				onPLI()
			}
		}
	}
}
