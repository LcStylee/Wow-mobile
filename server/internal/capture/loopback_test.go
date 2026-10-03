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

func TestSilencePad(t *testing.T) {
	t0 := time.Unix(1000, 0)
	// Audio flowing (last packet 10 ms ago): never pad, whatever the clock.
	if n, _ := silencePad(t0.Add(10*time.Millisecond), t0, t0, 48000); n != 0 {
		t.Fatalf("pad during playback: %d", n)
	}
	// Idle 100 ms: pad the whole gap since the last data, move the mark.
	n, mark := silencePad(t0.Add(100*time.Millisecond), t0, t0, 48000)
	if n != 4800 || !mark.Equal(t0.Add(100*time.Millisecond)) {
		t.Fatalf("idle pad: %d %v", n, mark)
	}
	// Still idle 15 ms later: only the new 15 ms.
	if n, _ := silencePad(mark.Add(15*time.Millisecond), t0, mark, 48000); n != 720 {
		t.Fatalf("continued pad: %d", n)
	}
}

func TestParseMixFormat(t *testing.T) {
	// The usual shared-mode mix format: WAVEFORMATEXTENSIBLE, 32-bit IEEE
	// float, stereo 48 kHz — exactly as Windows lays out the bytes (packed).
	ext := []byte{
		0xFE, 0xFF, // wFormatTag = WAVE_FORMAT_EXTENSIBLE
		0x02, 0x00, // nChannels = 2
		0x80, 0xBB, 0x00, 0x00, // nSamplesPerSec = 48000
		0x00, 0xDC, 0x05, 0x00, // nAvgBytesPerSec = 384000
		0x08, 0x00, // nBlockAlign = 8
		0x20, 0x00, // wBitsPerSample = 32
		0x16, 0x00, // cbSize = 22
		0x20, 0x00, // wValidBitsPerSample = 32 (offset 18)
		0x03, 0x00, 0x00, 0x00, // dwChannelMask (offset 20)
		// SubFormat (offset 24) = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
		0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
	}
	f, ba, err := parseMixFormat(ext)
	if err != nil || f != (LoopbackFormat{SampleFmt: "f32le", Rate: 48000, Channels: 2}) || ba != 8 {
		t.Fatalf("float mix: %+v %d %v", f, ba, err)
	}
	// Same header, PCM sub-format: integer samples.
	pcm := append([]byte(nil), ext...)
	pcm[24] = 0x01
	if f, _, err := parseMixFormat(pcm); err != nil || f.SampleFmt != "s32le" {
		t.Fatalf("pcm mix: %+v %v", f, err)
	}
	// Plain WAVEFORMATEX, 16-bit PCM.
	plain := []byte{0x01, 0x00, 0x02, 0x00, 0x44, 0xAC, 0x00, 0x00, 0x10, 0xB1, 0x02, 0x00, 0x04, 0x00, 0x10, 0x00, 0x00, 0x00}
	if f, ba, err := parseMixFormat(plain); err != nil || f != (LoopbackFormat{SampleFmt: "s16le", Rate: 44100, Channels: 2}) || ba != 4 {
		t.Fatalf("plain pcm: %+v %d %v", f, ba, err)
	}
	// Unknown sub-format: refuse rather than guess (guessing made noise).
	odd := append([]byte(nil), ext...)
	odd[24] = 0x07
	if _, _, err := parseMixFormat(odd); err == nil {
		t.Fatal("unknown sub-format accepted")
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
