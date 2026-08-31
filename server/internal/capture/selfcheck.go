package capture

import (
	"fmt"
	"time"
)

// SelfCheckResult is the outcome of the startup video-pipeline probe, written
// verbatim to the host dashboard so a black stream is diagnosable by READING,
// not by attaching a debugger.
type SelfCheckResult struct {
	OK     bool
	Frames int // access units the Annex-B parser recovered from the probe
	// Detail is the human-readable dashboard line: "video pipeline OK
	// (N frames)" or the ffmpeg stderr tail explaining the failure.
	Detail string
}

// SelfCheck proves the selected encoder + Annex-B parser can produce decodable
// access units on THIS machine: a ~2 s testsrc2 encode through the production
// flags (Config.VideoArgs with TestSource), parsed by the production
// AnnexBParser — everything except WebRTC. Runs at startup; the result goes on
// the dashboard.
func SelfCheck(ffmpegPath string, enc Encoder, w, h, fps int) SelfCheckResult {
	if fps < 1 {
		fps = 30
	}
	cfg := Config{
		FFmpegPath:  ffmpegPath,
		Width:       w,
		Height:      h,
		FPS:         fps,
		BitrateKbps: 2000,
		Encoder:     enc,
		TestSource:  true,
		TestFrames:  2 * fps, // ~2 s of paced frames
	}
	out, tail, err := runTestEncode(cfg, 30*time.Second)
	if err != nil {
		if isTestSourceFailure(err) {
			// This ffmpeg build lacks lavfi/testsrc2 — the probe proves
			// nothing about the pipeline (same distinction chooseEncoder
			// draws). Not a failure verdict: window capture may work fine,
			// and a red false alarm here would defeat the whole purpose of
			// a self-explaining dashboard.
			return SelfCheckResult{OK: true,
				Detail: "self-check unavailable (this ffmpeg cannot generate the test pattern) — window capture is unaffected"}
		}
		return SelfCheckResult{Detail: fmt.Sprintf("video pipeline FAILED (%s encoder): %s", enc, err)}
	}
	frames := 0
	keyframes := 0
	parser := NewAnnexBParser(func(au AccessUnit) {
		frames++
		if au.Keyframe {
			keyframes++
		}
	})
	parser.Write(out)
	parser.Flush()
	if frames == 0 || keyframes == 0 {
		detail := fmt.Sprintf(
			"video pipeline FAILED: %s emitted %d bytes but the parser recovered %d access units (%d keyframes)",
			enc, len(out), frames, keyframes)
		if len(tail) > 0 {
			detail += " — ffmpeg: " + tail[len(tail)-1]
		}
		return SelfCheckResult{Frames: frames, Detail: detail}
	}
	return SelfCheckResult{
		OK:     true,
		Frames: frames,
		Detail: fmt.Sprintf("video pipeline OK (%d frames)", frames),
	}
}
