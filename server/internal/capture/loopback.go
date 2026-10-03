package capture

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strconv"
	"time"
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

// idleAfter is how long the loopback may deliver nothing before silence is
// padded in. WASAPI loopback delivers NO packets while no application
// renders audio; without padding ffmpeg would stall and the phone would hear
// the backlog late.
const idleAfter = 60 * time.Millisecond

// silencePad decides the silence to write at time now: none while real
// audio flows (lastData within idleAfter) — padding in step with the wall
// clock during playback would slip zeros between packets whenever the sound
// card's clock runs a hair slow, an audible click every tick (v0.6.3) —
// and, once idle, exactly the wall time since mark (the last data or the
// last pad). Returns the frames to write and the new mark. Pure.
func silencePad(now, lastData, mark time.Time, rate int) (int64, time.Time) {
	if now.Sub(lastData) < idleAfter || !now.After(mark) {
		return 0, mark
	}
	return int64(now.Sub(mark).Seconds() * float64(rate)), now
}

// Wave format tags and the KSDATAFORMAT_SUBTYPE GUID tail shared by the
// PCM ({00000001-...}) and IEEE float ({00000003-...}) sub-formats.
const (
	waveFormatPCM        = 1
	waveFormatIEEEFloat  = 3
	waveFormatExtensible = 0xFFFE
)

var ksSubtypeTail = [12]byte{0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}

// parseMixFormat decodes a WAVEFORMATEX / WAVEFORMATEXTENSIBLE (the device
// mix format, raw little-endian bytes as Windows lays them out — PACKED, so
// SubFormat sits at byte 24) into the ffmpeg raw format plus the bytes per
// frame. Pure (unit-tested): the v0.6.3 bug read SubFormat through a padded
// Go struct, missed "float", and streamed float samples as s32le noise.
func parseMixFormat(b []byte) (LoopbackFormat, int, error) {
	if len(b) < 18 {
		return LoopbackFormat{}, 0, fmt.Errorf("mix format: %d bytes, want at least 18", len(b))
	}
	tag := binary.LittleEndian.Uint16(b[0:])
	channels := int(binary.LittleEndian.Uint16(b[2:]))
	rate := int(binary.LittleEndian.Uint32(b[4:]))
	blockAlign := int(binary.LittleEndian.Uint16(b[12:]))
	bits := int(binary.LittleEndian.Uint16(b[14:]))
	cb := int(binary.LittleEndian.Uint16(b[16:]))

	isFloat := tag == waveFormatIEEEFloat
	known := tag == waveFormatIEEEFloat || tag == waveFormatPCM
	if tag == waveFormatExtensible && cb >= 22 && len(b) >= 40 {
		sub := binary.LittleEndian.Uint32(b[24:])
		var tail [12]byte
		copy(tail[:], b[28:40])
		if tail == ksSubtypeTail && (sub == waveFormatIEEEFloat || sub == waveFormatPCM) {
			isFloat = sub == waveFormatIEEEFloat
			known = true
		}
	}
	sampleFmt := ""
	switch {
	case !known:
	case isFloat && bits == 32:
		sampleFmt = "f32le"
	case isFloat && bits == 64:
		sampleFmt = "f64le"
	case !isFloat && bits == 16:
		sampleFmt = "s16le"
	case !isFloat && bits == 24:
		sampleFmt = "s24le"
	case !isFloat && bits == 32:
		sampleFmt = "s32le"
	}
	if sampleFmt == "" || channels <= 0 || rate <= 0 || blockAlign <= 0 {
		return LoopbackFormat{}, 0, fmt.Errorf("unsupported mix format: tag %#x, %d bits, %d ch, %d Hz", tag, bits, channels, rate)
	}
	return LoopbackFormat{SampleFmt: sampleFmt, Rate: rate, Channels: channels}, blockAlign, nil
}
