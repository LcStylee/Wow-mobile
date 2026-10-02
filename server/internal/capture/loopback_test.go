package capture

import (
	"context"
	"io"
	"log/slog"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestSilenceFill(t *testing.T) {
	// Keeping pace (or ahead): nothing to pad.
	if got := silenceFill(48000, 48000, 2400); got != 0 {
		t.Fatalf("on pace: %d", got)
	}
	if got := silenceFill(50000, 48000, 2400); got != 0 {
		t.Fatalf("ahead: %d", got)
	}
	// Lag inside the slack (a burst still in flight): wait.
	if got := silenceFill(46000, 48000, 2400); got != 0 {
		t.Fatalf("inside slack: %d", got)
	}
	// Nothing playing for a second: pad up to the slack line only.
	if got := silenceFill(0, 48000, 2400); got != 45600 {
		t.Fatalf("silence: %d", got)
	}
}

func TestLoopbackArgs(t *testing.T) {
	args := baseConfig(X264).LoopbackArgs(LoopbackFormat{SampleFmt: "f32le", Rate: 44100, Channels: 6})
	joined := strings.Join(args, " ")
	for _, want := range []string{
		"-f f32le -ar 44100 -ac 6 -i pipe:0", // raw device PCM in on stdin
		"-ac 2 -ar 48000 -c:a libopus",       // stereo 48 kHz Opus out
		"-page_duration 20000",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %q in %q", want, joined)
		}
	}
	if strings.Contains(joined, "-nostdin") {
		t.Fatal("stdin is the input: -nostdin must not be set")
	}
}

// The feeder path end to end with `cat` standing in for ffmpeg: what the
// feeder writes to stdin comes back to the consumer on stdout.
func TestSupervisorFeeder(t *testing.T) {
	cat, err := exec.LookPath("cat")
	if err != nil {
		t.Skip("no cat on this system")
	}
	cfg := baseConfig(X264)
	cfg.FFmpegPath = cat
	got := make(chan string, 1)
	s := NewSupervisor("audio", cfg, func(Config) []string { return nil }, func(r io.Reader) error {
		b, err := io.ReadAll(r)
		got <- string(b)
		return err
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	s.SetFeeder(func(ctx context.Context, w io.Writer) error {
		_, err := io.WriteString(w, "pcm")
		return err // nil: stdin closes, cat exits
	})
	s.Start()
	defer s.Stop()
	select {
	case v := <-got:
		if v != "pcm" {
			t.Fatalf("consumer read %q", v)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("feeder output never reached the consumer")
	}
}
