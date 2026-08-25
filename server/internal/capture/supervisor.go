package capture

import (
	"bufio"
	"context"
	"io"
	"log/slog"
	"os/exec"
	"sync"
	"time"
)

// Consumer processes a running ffmpeg's stdout until EOF or error. It is
// called once per process lifetime; returning ends that lifetime.
type Consumer func(stdout io.Reader) error

// Supervisor runs one ffmpeg process, restarting it with exponential backoff
// when it dies, and hands its stdout to a Consumer. Start/Stop are idempotent
// and may be called repeatedly as streaming sessions come and go.
type Supervisor struct {
	name    string // for logs: "video" / "audio"
	consume Consumer
	log     *slog.Logger

	mu        sync.Mutex
	cfg       Config
	argv      func(Config) []string
	cancel    context.CancelFunc
	done      chan struct{} // closed when the run loop has fully exited
	gen       int           // bumped by SetBitrate/ForceKeyframe to signal "restart wanted"
	procStart time.Time     // when the current ffmpeg process was spawned
}

// NewSupervisor creates a supervisor for one pipeline. argv maps the current
// Config to an ffmpeg argument vector (Config.VideoArgs or Config.AudioArgs).
func NewSupervisor(name string, cfg Config, argv func(Config) []string, consume Consumer, log *slog.Logger) *Supervisor {
	return &Supervisor{name: name, cfg: cfg, argv: argv, consume: consume, log: log.With("pipeline", name)}
}

// Start launches the supervision loop. No-op if already running.
func (s *Supervisor) Start() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancel != nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.done = make(chan struct{})
	go s.run(ctx, s.done)
	s.log.Info("capture started")
}

// Stop kills ffmpeg and waits for the loop to exit. No-op if not running.
func (s *Supervisor) Stop() {
	s.mu.Lock()
	if s.cancel == nil {
		s.mu.Unlock()
		return
	}
	cancel, done := s.cancel, s.done
	s.cancel, s.done = nil, nil
	s.mu.Unlock()

	cancel()
	<-done
	s.log.Info("capture stopped")
}

// SetBitrate applies a new bitrate. If ffmpeg is running it is restarted —
// none of the supported encoders can be retuned through a pipe mid-stream, so
// a restart (one IDR + roughly a process-spawn of stream gap) is the honest
// implementation.
func (s *Supervisor) SetBitrate(kbps int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cfg.BitrateKbps == kbps {
		return
	}
	s.cfg = s.cfg.WithBitrate(kbps)
	s.gen++ // run loop notices and restarts the process
	s.log.Info("bitrate change requested", "kbps", kbps)
}

// keyframeRestartMinUptime exempts freshly spawned processes from
// ForceKeyframe: their opening IDR is at most this old (or still in flight),
// so restarting again would only widen the stream gap. A request that lands
// in this window and still misses is retried by the client (browsers repeat
// PLI until a keyframe arrives), which triggers a restart once eligible.
const keyframeRestartMinUptime = 500 * time.Millisecond

// ForceKeyframe makes the delivered stream open with a fresh IDR + SPS/PPS by
// restarting ffmpeg. As with SetBitrate, a restart is the honest mechanism:
// none of the supported encoders accept an IDR command through a pipe
// (-forced-idr only upgrades encoder-scheduled keyframes to true IDRs). No-op
// when not running — the next Start opens with an IDR anyway.
func (s *Supervisor) ForceKeyframe() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancel == nil || time.Since(s.procStart) < keyframeRestartMinUptime {
		return
	}
	s.gen++ // run loop notices and restarts the process
	s.log.Info("keyframe demanded; restarting encoder for a fresh IDR")
}

func (s *Supervisor) snapshot() (Config, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cfg, s.gen
}

func (s *Supervisor) run(ctx context.Context, done chan struct{}) {
	defer close(done)
	const (
		backoffMin   = 500 * time.Millisecond
		backoffMax   = 10 * time.Second
		stableUptime = 30 * time.Second // uptime that resets the backoff
	)
	backoff := backoffMin
	for ctx.Err() == nil {
		cfg, gen := s.snapshot()
		started := time.Now()
		err := s.runOnce(ctx, cfg, gen)
		if ctx.Err() != nil {
			return
		}
		if _, g := s.snapshot(); g != gen {
			// Deliberate restart (bitrate change): no backoff.
			backoff = backoffMin
			continue
		}
		if time.Since(started) >= stableUptime {
			backoff = backoffMin
		}
		s.log.Warn("ffmpeg exited, restarting", "err", err, "backoff", backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, backoffMax)
	}
}

// runOnce runs a single ffmpeg process until it exits, the context is
// cancelled, or the config generation changes.
func (s *Supervisor) runOnce(ctx context.Context, cfg Config, gen int) error {
	// Child context so a generation change can kill just this process.
	pctx, cancelProc := context.WithCancel(ctx)
	defer cancelProc()
	go func() {
		t := time.NewTicker(200 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-pctx.Done():
				return
			case <-t.C:
				if _, g := s.snapshot(); g != gen {
					cancelProc()
					return
				}
			}
		}
	}()

	// argv is evaluated per launch: it may re-snapshot live state (window
	// rect, resolved title) so every restart captures the current geometry.
	args := s.argv(cfg)
	cmd := exec.CommandContext(pctx, cfg.FFmpegPath, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	tail := newTailBuffer(30)
	var stderrWG sync.WaitGroup
	stderrWG.Add(1)
	go func() {
		defer stderrWG.Done()
		sc := bufio.NewScanner(stderr)
		sc.Buffer(make([]byte, 0, 4096), 1<<16)
		for sc.Scan() {
			tail.add(sc.Text())
		}
	}()

	s.log.Info("launching ffmpeg", "path", cfg.FFmpegPath, "args", args)
	if err := cmd.Start(); err != nil {
		return err
	}
	s.mu.Lock()
	s.procStart = time.Now() // ForceKeyframe's fresh-process exemption
	s.mu.Unlock()
	consumeErr := s.consume(stdout)
	// Sample "was this a requested stop/restart?" BEFORE the kill below, or
	// our own cancellation would suppress the post-mortem stderr tail on a
	// genuine ffmpeg death.
	requestedStop := pctx.Err() != nil
	// A returning consumer does not imply ffmpeg exited: e.g. ConsumeOgg
	// bails on a malformed Ogg page while ffmpeg keeps encoding. Kill the
	// process now — otherwise it would block on a full stdout pipe, stderr
	// would stay open, and the stderrWG.Wait()/cmd.Wait() below would hang
	// this pipeline forever instead of restarting it.
	cancelProc()
	stderrWG.Wait()
	waitErr := cmd.Wait()
	if !requestedStop { // real death, not a requested stop/restart
		for _, line := range tail.lines() {
			s.log.Warn("ffmpeg stderr", "line", line)
		}
	}
	if consumeErr != nil && consumeErr != io.EOF {
		return consumeErr
	}
	return waitErr
}

// tailBuffer keeps the last n lines of ffmpeg stderr for post-mortem logs.
type tailBuffer struct {
	mu    sync.Mutex
	max   int
	buf   []string
	start int
	n     int
}

func newTailBuffer(n int) *tailBuffer {
	return &tailBuffer{max: n, buf: make([]string, n)}
}

func (t *tailBuffer) add(line string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf[(t.start+t.n)%t.max] = line
	if t.n < t.max {
		t.n++
	} else {
		t.start = (t.start + 1) % t.max
	}
}

func (t *tailBuffer) lines() []string {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]string, 0, t.n)
	for i := 0; i < t.n; i++ {
		out = append(out, t.buf[(t.start+i)%t.max])
	}
	return out
}
