package capture

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"os/exec"
	"strings"
	"time"
)

// encoderPreference orders hardware encoders by expected latency/quality on a
// gaming PC; libx264 is the universal software fallback.
var encoderPreference = []struct {
	enc  Encoder
	name string // ffmpeg encoder name as listed by `ffmpeg -encoders`
}{
	{NVENC, "h264_nvenc"},
	{AMF, "h264_amf"},
	{QSV, "h264_qsv"},
	{X264, "libx264"},
}

// ProbeEncoder resolves --encoder=auto. Being compiled into ffmpeg proves
// nothing — full ffmpeg builds (the ones the wizard installs) compile in
// NVENC, AMF and QSV unconditionally, and picking one whose GPU runtime is
// absent (e.g. h264_nvenc on an AMD box: "Cannot load libcuda.so.1") makes
// every capture launch die instantly, which is a permanent black stream while
// signaling and input keep working. So each compiled-in candidate is
// FUNCTIONALLY trialed, most-preferred first: a few testsrc2 frames are pushed
// through the exact production encoder flags, and the first encoder that
// actually produces H.264 bytes wins. See chooseEncoder for what happens when
// every trial fails — notably the unverified best-effort fallback for an
// ffmpeg that cannot run the trial's lavfi/testsrc2 input at all.
func ProbeEncoder(ffmpegPath string) (Encoder, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, ffmpegPath, "-hide_banner", "-encoders")
	hideConsole(cmd) // Windows: no console flash from the probe in GUI mode
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("probing %s for encoders: %w", ffmpegPath, err)
	}
	candidates := compiledEncoders(string(out))
	if len(candidates) == 0 {
		return "", fmt.Errorf("%s has no usable H.264 encoder (need one of h264_nvenc/h264_amf/h264_qsv/libx264)", ffmpegPath)
	}
	return chooseEncoder(candidates, func(enc Encoder) error {
		return trialEncoder(ffmpegPath, enc)
	})
}

// chooseEncoder trials each compiled-in candidate, most-preferred first, and
// returns the first that passes. When every trial fails, the FAILURE KIND
// decides the outcome:
//
//   - at least one failure implicates an encoder itself → hard error: none of
//     the encoders demonstrably works, refusing to start (with a readable
//     aggregate and the --encoder escape hatch) beats streaming black;
//   - every failure implicates the synthetic lavfi/testsrc2 INPUT instead
//     (a minimal custom ffmpeg built without the lavfi device cannot run the
//     trial at all, which proves nothing about its encoders) → best-effort
//     fallback to the most-preferred compiled-in candidate, UNVERIFIED, with
//     a loud warning — a probe that cannot run must not turn a working setup
//     into a refused startup.
func chooseEncoder(candidates []Encoder, trial func(Encoder) error) (Encoder, error) {
	var failures []string
	sourceFailures := 0
	for _, cand := range candidates {
		if err := trial(cand); err != nil {
			slog.Info("encoder probe: candidate failed a trial encode, trying the next",
				"encoder", string(cand), "err", err)
			if isTestSourceFailure(err) {
				sourceFailures++
			}
			failures = append(failures, fmt.Sprintf("%s: %v", cand, err))
			continue
		}
		return cand, nil
	}
	if sourceFailures == len(candidates) {
		first := candidates[0]
		slog.Warn("encoder probe: this ffmpeg cannot run the trial encode at all (no lavfi/testsrc2 input) — "+
			"falling back to the most-preferred compiled-in encoder UNVERIFIED; "+
			"if the stream is black, pin a known-good one with --encoder",
			"encoder", string(first), "failures", strings.Join(failures, "; "))
		return first, nil
	}
	return "", fmt.Errorf("every compiled-in H.264 encoder failed a trial encode (pin one with --encoder <name> to skip the trial):\n  %s",
		strings.Join(failures, "\n  "))
}

// isTestSourceFailure reports whether a trial-encode error points at the
// synthetic lavfi/testsrc2 INPUT rather than the encoder under trial. Only the
// two specific messages a lavfi-less ffmpeg emits qualify: "Unknown input
// format: 'lavfi'" (the lavfi demuxer is not compiled in) and a "No such
// filter"-class message naming testsrc2 (lavfi present, filter missing).
// Deliberately NOT a bare substring match on "lavfi"/"testsrc2": ffmpeg
// prefixes ordinary warnings/errors with component contexts like
// "[lavfi @ 0x...]" or "[Parsed_testsrc2_0 @ 0x...]", and misclassifying a
// genuine encoder failure (e.g. "Cannot load libcuda.so.1") as an input
// failure would silently unlock chooseEncoder's unverified fallback — landing
// right back on the broken encoder the probe exists to reject.
func isTestSourceFailure(err error) bool {
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "unknown input format: 'lavfi'") {
		return true
	}
	return strings.Contains(msg, "no such filter") && strings.Contains(msg, "testsrc2")
}

// compiledEncoders parses `ffmpeg -encoders` output and returns the supported
// encoders that are compiled in, in preference order.
func compiledEncoders(encodersOutput string) []Encoder {
	available := map[string]bool{}
	for _, line := range strings.Split(encodersOutput, "\n") {
		// Lines look like: " V....D h264_nvenc   NVIDIA NVENC H.264 encoder ..."
		fields := strings.Fields(line)
		if len(fields) >= 2 && strings.HasPrefix(fields[0], "V") {
			available[fields[1]] = true
		}
	}
	var out []Encoder
	for _, cand := range encoderPreference {
		if available[cand.name] {
			out = append(out, cand.enc)
		}
	}
	return out
}

// trialFrames is how many testsrc2 frames an encoder trial pushes through a
// candidate: enough to prove the encoder initializes AND emits bitstream, few
// enough (0.1 s of paced input at the trial's 30 fps) that a full probe of
// every candidate stays fast.
const trialFrames = 3

// trialEncoder proves one encoder actually works on THIS machine by encoding
// a few synthetic frames with the production flag set (Config.VideoArgs with
// TestSource — identical encoder arguments to the real capture). Returns nil
// when the encoder produced H.264 output; otherwise an error carrying the
// tail of ffmpeg's stderr.
func trialEncoder(ffmpegPath string, enc Encoder) error {
	cfg := Config{
		FFmpegPath:  ffmpegPath,
		Width:       256,
		Height:      256,
		FPS:         30,
		BitrateKbps: 1000,
		Encoder:     enc,
		TestSource:  true,
		TestFrames:  trialFrames,
	}
	out, _, err := runTestEncode(cfg, 15*time.Second)
	if err != nil {
		return err
	}
	if len(out) == 0 {
		return fmt.Errorf("encoder %s produced no output", enc)
	}
	return nil
}

// runTestEncode runs one bounded TestSource encode and returns ffmpeg's raw
// stdout (the Annex-B stream) plus the tail of its stderr. Shared by the
// encoder trials above and the startup self-check (selfcheck.go).
func runTestEncode(cfg Config, timeout time.Duration) (stdout []byte, stderrTail []string, err error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, cfg.FFmpegPath, cfg.VideoArgs()...)
	hideConsole(cmd)
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	runErr := cmd.Run()
	tail := stderrTailLines(errBuf.String(), 8)
	if runErr != nil {
		msg := strings.Join(tail, " | ")
		if msg == "" {
			msg = runErr.Error()
		}
		return nil, tail, fmt.Errorf("%s", msg)
	}
	return outBuf.Bytes(), tail, nil
}

// stderrTailLines returns the last n non-empty lines of s.
func stderrTailLines(s string, n int) []string {
	var lines []string
	for _, line := range strings.Split(s, "\n") {
		if t := strings.TrimSpace(line); t != "" {
			lines = append(lines, t)
		}
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}
