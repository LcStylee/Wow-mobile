package capture

import (
	"context"
	"errors"
	"io"
	"strconv"
)

// LoopbackFormat is the raw PCM layout the system audio loopback delivers:
// the default playback device's shared-mode mix format, handed to ffmpeg
// as-is (no conversion in Go) — SampleFmt is the ffmpeg raw demuxer name
// (f32le, s16le, ...).
type LoopbackFormat struct {
	SampleFmt string
	Rate      int
	Channels  int
}

// ErrLoopbackUnsupported is returned where the platform has no system audio
// loopback (everything but Windows).
var ErrLoopbackUnsupported = errors.New("system audio loopback is only available on Windows")

// Feeder writes a running ffmpeg's stdin until the context ends or it fails;
// a returned error ends that ffmpeg's lifetime (the supervisor restarts it).
type Feeder func(ctx context.Context, stdin io.Writer) error

// LoopbackArgs builds the argv for the audio pipeline fed by the built-in
// system audio loopback (ProbeLoopback / StreamLoopback): raw PCM in on
// stdin, encoded to low-delay Opus in an Ogg stream on stdout exactly like
// AudioArgs. No -nostdin: stdin IS the input. Downmixed to stereo 48 kHz,
// what WebRTC Opus carries.
func (c Config) LoopbackArgs(f LoopbackFormat) []string {
	return []string{
		"-hide_banner", "-loglevel", "warning",
		"-fflags", "nobuffer", "-flags", "low_delay",
		"-f", f.SampleFmt,
		"-ar", strconv.Itoa(f.Rate),
		"-ac", strconv.Itoa(f.Channels),
		"-i", "pipe:0",
		"-ac", "2",
		"-ar", "48000",
		"-c:a", "libopus",
		"-b:a", "96k",
		"-application", "lowdelay",
		"-frame_duration", "20",
		"-page_duration", "20000", // µs — one 20 ms packet per Ogg page
		"-f", "ogg",
		"-flush_packets", "1",
		"-",
	}
}

// silenceFill decides how many frames of silence to write so the PCM stream
// keeps pace with the wall clock while nothing plays (WASAPI loopback
// delivers no packets at all when no application renders audio; without
// padding ffmpeg would stall and the phone would hear the backlog late).
// written and expected are frame counts since the stream started; slack is
// the lag tolerated before padding (real packets arrive in bursts). Pure.
func silenceFill(written, expected, slack int64) int64 {
	if written >= expected-slack {
		return 0
	}
	return expected - slack - written
}
