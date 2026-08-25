package capture

import (
	"context"
	"fmt"
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

// ProbeEncoder resolves --encoder=auto by asking the local ffmpeg build which
// H.264 encoders it was compiled with. Compiled-in does not guarantee the GPU
// runtime is present, but a failed hardware encoder surfaces immediately via
// supervisor restart logs, and the user can pin --encoder explicitly.
func ProbeEncoder(ffmpegPath string) (Encoder, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, ffmpegPath, "-hide_banner", "-encoders").Output()
	if err != nil {
		return "", fmt.Errorf("probing %s for encoders: %w", ffmpegPath, err)
	}
	enc, ok := pickEncoder(string(out))
	if !ok {
		return "", fmt.Errorf("%s has no usable H.264 encoder (need one of h264_nvenc/h264_amf/h264_qsv/libx264)", ffmpegPath)
	}
	return enc, nil
}

// pickEncoder parses `ffmpeg -encoders` output and returns the most preferred
// available encoder. Split out from ProbeEncoder for testability.
func pickEncoder(encodersOutput string) (Encoder, bool) {
	available := map[string]bool{}
	for _, line := range strings.Split(encodersOutput, "\n") {
		// Lines look like: " V....D h264_nvenc   NVIDIA NVENC H.264 encoder ..."
		fields := strings.Fields(line)
		if len(fields) >= 2 && strings.HasPrefix(fields[0], "V") {
			available[fields[1]] = true
		}
	}
	for _, cand := range encoderPreference {
		if available[cand.name] {
			return cand.enc, true
		}
	}
	return "", false
}
