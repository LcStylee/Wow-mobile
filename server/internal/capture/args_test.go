package capture

import (
	"slices"
	"strings"
	"testing"
)

func baseConfig(enc Encoder) Config {
	return Config{
		FFmpegPath:  "ffmpeg",
		WindowTitle: "World of Warcraft",
		Width:       1080,
		Height:      1920,
		FPS:         60,
		BitrateKbps: 8000,
		Encoder:     enc,
	}
}

// argValue returns the argument following the first occurrence of flag.
func argValue(t *testing.T, args []string, flag string) string {
	t.Helper()
	i := slices.Index(args, flag)
	if i < 0 || i+1 >= len(args) {
		t.Fatalf("flag %q not found in %v", flag, args)
	}
	return args[i+1]
}

func requireAll(t *testing.T, args []string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !slices.Contains(args, w) {
			t.Errorf("argv missing %q: %v", w, args)
		}
	}
}

func TestVideoArgsCommon(t *testing.T) {
	for _, enc := range []Encoder{NVENC, AMF, QSV, X264} {
		t.Run(string(enc), func(t *testing.T) {
			args := baseConfig(enc).VideoArgs()
			requireAll(t, args, "-nostdin", "nobuffer", "low_delay")
			// No CaptureRect in baseConfig, so every encoder captures via gdigrab.
			if argValue(t, args, "-f") != "gdigrab" {
				t.Errorf("first -f should be the gdigrab input for %s: %v", enc, args)
			}
			// Raw Annex-B to stdout, flushed per packet.
			if args[len(args)-1] != "-" {
				t.Errorf("argv must end with stdout: %v", args)
			}
			requireAll(t, args, "-flush_packets")
			i := slices.Index(args, "-flush_packets")
			if args[i+1] != "1" || args[i-1] != "h264" {
				t.Errorf("want ... -f h264 -flush_packets 1 -, got %v", args[i-2:])
			}
			// No B-frames on any encoder.
			if argValue(t, args, "-bf") != "0" {
				t.Errorf("-bf must be 0: %v", args)
			}
			// 2 s GOP at 60 fps.
			if argValue(t, args, "-g") != "120" {
				t.Errorf("-g must be 120: %v", args)
			}
			if argValue(t, args, "-b:v") != "8000k" || argValue(t, args, "-maxrate") != "8000k" {
				t.Errorf("CBR at 8000k expected: %v", args)
			}
			// Two-frame VBV: 2*8000/60 = 266k.
			if argValue(t, args, "-bufsize") != "266k" {
				t.Errorf("bufsize = %s, want 266k", argValue(t, args, "-bufsize"))
			}
		})
	}
}

func TestVideoArgsNVENCDdagrab(t *testing.T) {
	cfg := baseConfig(NVENC)
	// Output-local rect on a non-zero output index: a window on a secondary
	// monitor must address THAT output, never a hard-coded output 0. W/H
	// equal Width/Height per the CaptureRect invariant, and video_size must
	// be built from the rect (the crop is the frame; there is no scaler).
	cfg.CaptureRect = &Rect{X: 100, Y: 50, W: 1080, H: 1920}
	cfg.CaptureOutput = 1
	args := cfg.VideoArgs()

	fc := argValue(t, args, "-filter_complex")
	for _, want := range []string{"ddagrab=", "output_idx=1", "framerate=60", "draw_mouse=0", "offset_x=100", "offset_y=50", "video_size=1080x1920"} {
		if !strings.Contains(fc, want) {
			t.Errorf("filter_complex %q missing %q", fc, want)
		}
	}
	requireAll(t, args, "-init_hw_device", "d3d11va", "h264_nvenc", "-zerolatency", "-forced-idr")
	if argValue(t, args, "-preset") != "p1" || argValue(t, args, "-tune") != "ull" {
		t.Errorf("nvenc must use -preset p1 -tune ull: %v", args)
	}
	if argValue(t, args, "-rc") != "cbr" {
		t.Errorf("nvenc must use -rc cbr: %v", args)
	}
	if slices.Contains(args, "gdigrab") || slices.Contains(args, "-vf") {
		t.Errorf("ddagrab path must not carry gdigrab input or a software -vf: %v", args)
	}
}

func TestVideoArgsNVENCFallsBackToGdigrab(t *testing.T) {
	args := baseConfig(NVENC).VideoArgs() // no CaptureRect
	requireAll(t, args, "gdigrab", "h264_nvenc")
	if argValue(t, args, "-i") != "title=World of Warcraft" {
		t.Errorf("gdigrab must capture by window title: %v", args)
	}
	if !strings.Contains(argValue(t, args, "-vf"), "format=nv12") {
		t.Errorf("system-memory frames need nv12 for nvenc: %v", args)
	}
}

func TestVideoArgsX264(t *testing.T) {
	args := baseConfig(X264).VideoArgs()
	requireAll(t, args, "libx264", "gdigrab")
	if argValue(t, args, "-preset") != "ultrafast" || argValue(t, args, "-tune") != "zerolatency" {
		t.Errorf("x264 must use -preset ultrafast -tune zerolatency: %v", args)
	}
	if argValue(t, args, "-framerate") != "60" {
		t.Errorf("gdigrab framerate must be 60: %v", args)
	}
	vf := argValue(t, args, "-vf")
	if !strings.Contains(vf, "scale=1080:1920") || !strings.Contains(vf, "format=yuv420p") {
		t.Errorf("x264 -vf must normalize geometry and pix_fmt: %q", vf)
	}
	if argValue(t, args, "-profile:v") != "baseline" {
		t.Errorf("SDP advertises constrained baseline; -profile:v = %q", argValue(t, args, "-profile:v"))
	}
}

func TestVideoArgsAMFAndQSV(t *testing.T) {
	amf := baseConfig(AMF).VideoArgs()
	requireAll(t, amf, "h264_amf", "ultralowlatency")
	if argValue(t, amf, "-rc") != "cbr" {
		t.Errorf("amf must use -rc cbr: %v", amf)
	}
	qsv := baseConfig(QSV).VideoArgs()
	requireAll(t, qsv, "h264_qsv")
	if argValue(t, qsv, "-async_depth") != "1" {
		t.Errorf("qsv must disable pipelining with -async_depth 1: %v", qsv)
	}
}

func TestWithBitrate(t *testing.T) {
	cfg := baseConfig(X264)
	args := cfg.WithBitrate(3000).VideoArgs()
	if argValue(t, args, "-b:v") != "3000k" {
		t.Errorf("WithBitrate not reflected: %v", args)
	}
	if cfg.BitrateKbps != 8000 {
		t.Error("WithBitrate mutated the receiver")
	}
	// VBV floor for very low bitrates.
	low := cfg.WithBitrate(500)
	low.FPS = 60
	if argValue(t, low.VideoArgs(), "-bufsize") != "64k" {
		t.Errorf("bufsize floor of 64k not applied: %v", low.VideoArgs())
	}
}

func TestAudioArgs(t *testing.T) {
	args := baseConfig(X264).AudioArgs()
	requireAll(t, args, "dshow", "audio=virtual-audio-capturer", "libopus", "lowdelay")
	if argValue(t, args, "-frame_duration") != "20" || argValue(t, args, "-page_duration") != "20000" {
		t.Errorf("one 20 ms Opus packet per Ogg page is required: %v", args)
	}
	if args[len(args)-1] != "-" {
		t.Errorf("audio argv must end with stdout: %v", args)
	}
}

func TestPickEncoder(t *testing.T) {
	const ffmpegOutput = `Encoders:
 V..... = Video
 A..... = Audio
 ------
 V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC (codec h264)
 V....D h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
 A....D aac                  AAC (Advanced Audio Coding)
`
	enc, ok := pickEncoder(ffmpegOutput)
	if !ok || enc != NVENC {
		t.Fatalf("pickEncoder = %v,%v, want nvenc (preferred over x264)", enc, ok)
	}

	enc, ok = pickEncoder(strings.ReplaceAll(ffmpegOutput, "h264_nvenc", "h264_qsv"))
	if !ok || enc != QSV {
		t.Fatalf("pickEncoder = %v,%v, want qsv", enc, ok)
	}

	// Audio-only line must not count as a video encoder.
	if _, ok := pickEncoder(" A....D libx264   fake\n"); ok {
		t.Fatal("audio-flagged line was accepted as a video encoder")
	}
	if _, ok := pickEncoder("Encoders:\n V....D mjpeg  something\n"); ok {
		t.Fatal("no H.264 encoder present but pickEncoder succeeded")
	}
}
