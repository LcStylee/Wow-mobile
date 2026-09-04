package capture

import (
	"fmt"
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

func TestCompiledEncoders(t *testing.T) {
	const ffmpegOutput = `Encoders:
 V..... = Video
 A..... = Audio
 ------
 V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC (codec h264)
 V....D h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
 A....D aac                  AAC (Advanced Audio Coding)
`
	// Preference order: nvenc first, x264 as the software fallback — and BOTH
	// must be returned, because compiled-in nvenc may still fail its trial
	// encode (no NVIDIA runtime) and the probe then needs the next candidate.
	got := compiledEncoders(ffmpegOutput)
	if len(got) != 2 || got[0] != NVENC || got[1] != X264 {
		t.Fatalf("compiledEncoders = %v, want [nvenc x264]", got)
	}

	got = compiledEncoders(strings.ReplaceAll(ffmpegOutput, "h264_nvenc", "h264_qsv"))
	if len(got) != 2 || got[0] != QSV || got[1] != X264 {
		t.Fatalf("compiledEncoders = %v, want [qsv x264]", got)
	}

	// Audio-only line must not count as a video encoder.
	if got := compiledEncoders(" A....D libx264   fake\n"); len(got) != 0 {
		t.Fatalf("audio-flagged line was accepted as a video encoder: %v", got)
	}
	if got := compiledEncoders("Encoders:\n V....D mjpeg  something\n"); len(got) != 0 {
		t.Fatalf("no H.264 encoder present but compiledEncoders returned %v", got)
	}
}

// Band mode: the crop runs FIRST (window client pixels — the band contract's
// coordinate space), then the scale to the encode geometry, then the pixel
// format — on every software-frame encoder.
func TestVideoArgsBandCrop(t *testing.T) {
	for enc, pixfmt := range map[Encoder]string{NVENC: "nv12", AMF: "nv12", QSV: "nv12", X264: "yuv420p"} {
		cfg := baseConfig(enc)
		cfg.Width, cfg.Height = 404, 720
		cfg.CropRect = &Rect{X: 438, Y: 0, W: 405, H: 720}
		args := cfg.VideoArgs()
		vf := argValue(t, args, "-vf")
		want := "crop=405:720:438:0,scale=404:720:flags=fast_bilinear,format=" + pixfmt
		if vf != want {
			t.Errorf("%s band -vf = %q, want %q", enc, vf, want)
		}
		if slices.Contains(args, "-filter_complex") {
			t.Errorf("%s band crop must ride the gdigrab path: %v", enc, args)
		}
	}
	// The design-cap case: a 4K desktop's 1215x2160 band encoded at 1080x1920.
	cfg := baseConfig(X264)
	cfg.Width, cfg.Height = 1080, 1920
	cfg.CropRect = &Rect{X: 1312, Y: 0, W: 1215, H: 2160}
	if vf := argValue(t, cfg.VideoArgs(), "-vf"); vf != "crop=1215:2160:1312:0,scale=1080:1920:flags=fast_bilinear,format=yuv420p" {
		t.Errorf("capped band -vf = %q", vf)
	}
}

// Decorated/borderless/maximized windows: the band CropRect reaches the
// gdigrab -vf chain UNMODIFIED — no window-decoration offset is ever added.
// Both grab paths deliver frames whose (0,0) is the CLIENT AREA's top-left
// (gdigrab `title=` BitBlts GetDC(hwnd)'s client-area DC sized by
// GetClientRect; the ddagrab rect is ClientToScreen-translated), so the
// client-local band rect applies verbatim — audited after the v0.4.0 field
// report, whose band-edge UI cut traced to the addon-side gxResolution basis
// mismatch (window.BandBasisCheck), not to a shifted crop. The vector is the
// field case itself: a 4K window maximized above the taskbar (client area
// 3840x2069, band 1164x2069 at x=1338, encoded at the 1080x1920 design cap).
func TestVideoArgsBandCropClientAreaVerbatim(t *testing.T) {
	cfg := baseConfig(X264)
	cfg.Width, cfg.Height = 1080, 1920
	cfg.CropRect = &Rect{X: 1338, Y: 0, W: 1164, H: 2069}
	if vf := argValue(t, cfg.VideoArgs(), "-vf"); vf != "crop=1164:2069:1338:0,scale=1080:1920:flags=fast_bilinear,format=yuv420p" {
		t.Errorf("maximized-window band -vf = %q", vf)
	}
}

// Window-style invariance: whatever shape the live client area takes — an
// odd-sized window mid-drag, a borderless-fullscreen desktop, a decorated
// window (client area already excludes the title bar/borders), decorations
// scaled by 125% DPI, or a DPI-virtualized client — the band CropRect is
// CLIENT-LOCAL and reaches the -vf chain verbatim, with no per-style offset
// term anywhere in the argv (no gdigrab offset_x/offset_y, no crop
// adjustment). The window styles differ only in the client rects they
// produce; each row's band/encode values are the band contract's output for
// that client area (precomputed window.ComputeBandFrame results — the
// contract itself is pinned in window/band_test.go), so this table pins the
// pass-through invariant across the styles explicitly.
func TestVideoArgsBandCropWindowStyles(t *testing.T) {
	cases := []struct {
		name       string
		clientW    int
		clientH    int // live client area (the only input any style contributes)
		band       Rect
		encW, encH int
	}{
		// A decorated window resized by hand to an odd size.
		{"odd-sized", 1367, 769, Rect{X: 467, Y: 0, W: 433, H: 769}, 432, 768},
		// Borderless fullscreen: client area == the whole 1080p desktop.
		{"borderless-desktop", 1920, 1080, Rect{X: 656, Y: 0, W: 608, H: 1080}, 608, 1080},
		// Decorated window on that desktop: the client area is what remains
		// inside the 100%-DPI title bar and borders.
		{"decorated", 1904, 1041, Rect{X: 659, Y: 0, W: 586, H: 1041}, 586, 1040},
		// The same window with decorations scaled by 125% DPI on a 1440p
		// desktop: thicker chrome, smaller physical client area.
		{"decorated-125dpi", 2546, 1387, Rect{X: 883, Y: 0, W: 780, H: 1387}, 780, 1386},
		// A DPI-virtualized client rect (1920x1080 desktop read at 125%
		// scaling by a DPI-unaware reader): still just a client area.
		{"dpi-virtualized", 1536, 864, Rect{X: 525, Y: 0, W: 486, H: 864}, 486, 864},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := baseConfig(X264)
			cfg.Width, cfg.Height = tc.encW, tc.encH
			band := tc.band
			cfg.CropRect = &band
			args := cfg.VideoArgs()
			want := fmt.Sprintf("crop=%d:%d:%d:0,scale=%d:%d:flags=fast_bilinear,format=yuv420p",
				tc.band.W, tc.band.H, tc.band.X, tc.encW, tc.encH)
			if vf := argValue(t, args, "-vf"); vf != want {
				t.Errorf("%dx%d client band -vf = %q, want %q", tc.clientW, tc.clientH, vf, want)
			}
			// No offset options anywhere: gdigrab grabs the client area whole
			// (title=, client-DC origin) and the crop above is the only
			// coordinate arithmetic in the argv.
			for _, forbidden := range []string{"-offset_x", "-offset_y", "offset_x", "offset_y"} {
				if slices.Contains(args, forbidden) {
					t.Errorf("argv must carry no grab offset for a client-area crop: %v", args)
				}
			}
			if argValue(t, args, "-i") != "title=World of Warcraft" {
				t.Errorf("band crop must ride the full-title gdigrab input: %v", args)
			}
		})
	}
}

// Band mode with --capture test: testsrc2 must generate the full simulated
// WINDOW (SourceW x SourceH), not the encode size, so the crop/scale chain is
// exercised for real — the e2e band scenario depends on this.
func TestVideoArgsTestSourceBand(t *testing.T) {
	cfg := baseConfig(X264)
	cfg.TestSource = true
	cfg.Width, cfg.Height = 404, 720
	cfg.SourceW, cfg.SourceH = 1280, 720
	cfg.CropRect = &Rect{X: 438, Y: 0, W: 405, H: 720}
	args := cfg.VideoArgs()
	requireAll(t, args, "testsrc2=size=1280x720:rate=60")
	if vf := argValue(t, args, "-vf"); vf != "crop=405:720:438:0,scale=404:720:flags=fast_bilinear,format=yuv420p" {
		t.Errorf("band test-source -vf = %q", vf)
	}
}

func TestVideoArgsTestSource(t *testing.T) {
	cfg := baseConfig(X264)
	cfg.TestSource = true
	cfg.TestFrames = 3
	args := cfg.VideoArgs()
	// lavfi testsrc2 input, paced to real time, bounded to 3 frames — and the
	// encoder half must stay EXACTLY production (that is the point of the
	// test-pattern mode).
	requireAll(t, args, "lavfi", "-re", "testsrc2=size=1080x1920:rate=60", "libx264")
	if argValue(t, args, "-frames:v") != "3" {
		t.Errorf("TestFrames not applied: %v", args)
	}
	if argValue(t, args, "-tune") != "zerolatency" || argValue(t, args, "-preset") != "ultrafast" {
		t.Errorf("test source must keep the production encoder flags: %v", args)
	}
	if slices.Contains(args, "gdigrab") {
		t.Errorf("test source must not carry the window grabber: %v", args)
	}

	// Unbounded (streaming) test mode has no -frames:v; NVENC keeps its
	// system-memory -vf (lavfi frames are not D3D11 textures) and never the
	// ddagrab graph, even when a CaptureRect is set.
	cfg = baseConfig(NVENC)
	cfg.TestSource = true
	cfg.CaptureRect = &Rect{X: 0, Y: 0, W: 1080, H: 1920}
	args = cfg.VideoArgs()
	if slices.Contains(args, "-frames:v") {
		t.Errorf("no frame bound expected: %v", args)
	}
	if slices.Contains(args, "-filter_complex") {
		t.Errorf("test source must not use ddagrab: %v", args)
	}
	requireAll(t, args, "lavfi", "h264_nvenc")
	if !strings.Contains(argValue(t, args, "-vf"), "format=nv12") {
		t.Errorf("nvenc test source needs the nv12 -vf: %v", args)
	}
}
