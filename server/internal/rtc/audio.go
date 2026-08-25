package rtc

import (
	"fmt"
	"io"
	"time"

	"github.com/pion/webrtc/v4/pkg/media/oggreader"
)

// opusClockRate is fixed by RFC 7845: Ogg Opus granule positions always tick
// at 48 kHz regardless of the coded sample rate.
const opusClockRate = 48000

// defaultOpusFrame matches the capture pipeline's -frame_duration 20.
const defaultOpusFrame = 20 * time.Millisecond

// ConsumeOgg reads the audio ffmpeg's Ogg Opus stdout and forwards one Opus
// packet per page to the manager (the pipeline pins page_duration ==
// frame_duration, so pages and packets are 1:1). Runs until read error/EOF;
// used as the audio Supervisor's Consumer.
func (m *Manager) ConsumeOgg(stdout io.Reader) error {
	ogg, _, err := oggreader.NewWith(stdout)
	if err != nil {
		return fmt.Errorf("reading ogg header: %w", err)
	}
	var lastGranule uint64
	for {
		payload, header, err := ogg.ParseNextPage()
		if err != nil {
			return err
		}
		// NewWith consumed the OpusHead page; the OpusTags comment page still
		// comes through here and must not be forwarded as audio.
		if len(payload) >= 8 && string(payload[:8]) == "OpusTags" {
			continue
		}
		// Granule deltas give the true packet duration even if ffmpeg pads
		// the first/last frame; fall back to the nominal 20 ms at start.
		duration := defaultOpusFrame
		if lastGranule != 0 && header.GranulePosition > lastGranule {
			duration = time.Duration(header.GranulePosition-lastGranule) * time.Second / opusClockRate
		}
		lastGranule = header.GranulePosition
		m.WriteAudio(payload, duration)
	}
}
