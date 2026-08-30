// Package capture builds and supervises the ffmpeg capture/encode pipeline and
// splits its Annex-B H.264 output into access units. Everything in this package
// is portable; Windows specifics live only in the argv strings it produces.
package capture

import (
	"fmt"
	"strconv"
)

// Encoder is a concrete (non-auto) encoder choice.
type Encoder string

const (
	NVENC Encoder = "nvenc"
	AMF   Encoder = "amf"
	QSV   Encoder = "qsv"
	X264  Encoder = "x264"
)

// Bitrate limits, shared by --bitrate-kbps validation (config.Parse) and the
// ctrl "bitrate" handler (rtc) so the client-requestable range is always
// exactly the configurable one.
const (
	MinBitrateKbps = 500
	MaxBitrateKbps = 100_000
)

// Rect is a pixel rectangle. For Config.CaptureRect, X/Y are local to the
// captured monitor output's top-left corner, not the virtual desktop.
type Rect struct {
	X, Y, W, H int
}

// Config describes one capture pipeline. It is immutable once handed to a
// Supervisor; bitrate changes clone it via WithBitrate and restart ffmpeg.
type Config struct {
	FFmpegPath string
	// WindowTitle is the gdigrab `-i title=...` value. gdigrab resolves it
	// with FindWindow, i.e. the EXACT full window title — unlike the
	// --window-title flag, which window.Tracker matches as a substring. The
	// caller bridges the two by resolving the tracked window's real title
	// (Tracker.Title) into this field before each ffmpeg launch.
	WindowTitle string
	Width       int // encoded output width; the WoW window client area should match
	Height      int
	FPS         int
	BitrateKbps int
	Encoder     Encoder
	// CaptureRect, when non-nil, enables the zero-copy ddagrab path for
	// NVENC. ddagrab addresses one monitor output, not a window, so the
	// caller (window.LocateOutput on the Windows side) guarantees three
	// invariants: the rect is expressed in that output's LOCAL coordinates
	// (ddagrab's offset_x/offset_y are relative to the captured output, not
	// the virtual desktop) and lies entirely inside it; CaptureOutput is that
	// output's index; and W/H equal Width/Height — the ddagrab filter graph
	// has no scaler, so a window whose client area differs from the
	// advertised geometry must take the gdigrab path, which scales.
	CaptureRect *Rect
	// CaptureOutput is ddagrab's output_idx: CaptureRect's monitor output,
	// as indexed by EnumOutputs on DXGI adapter 0 — the adapter ffmpeg's
	// bare `-init_hw_device d3d11va` opens. Meaningless when CaptureRect is
	// nil.
	CaptureOutput int
}

// WithBitrate returns a copy of c with a new bitrate.
func (c Config) WithBitrate(kbps int) Config {
	c.BitrateKbps = kbps
	return c
}

// VideoArgs builds the complete ffmpeg argv (excluding argv[0]) for the video
// pipeline: window capture -> H.264 -> Annex-B byte stream on stdout.
//
// Latency notes, load-bearing throughout:
//   - "-fflags nobuffer -flags low_delay" disable demuxer/decoder buffering.
//   - CBR with a ~2-frame VBV keeps per-frame size flat so no frame queues
//     behind an oversized predecessor on the Wi-Fi link.
//   - "-bf 0" everywhere: B-frames would add a full frame of encoder delay
//     and break the send-as-you-encode model.
//   - "-g" = 2 s of frames: recovery points without frequent expensive IDRs.
//   - "-flush_packets 1" makes ffmpeg write() each encoded access unit to the
//     pipe immediately instead of coalescing.
func (c Config) VideoArgs() []string {
	args := []string{
		"-hide_banner", "-loglevel", "warning", "-nostdin",
		"-fflags", "nobuffer", "-flags", "low_delay",
	}
	args = append(args, c.inputArgs()...)
	args = append(args, c.encoderArgs()...)
	args = append(args,
		"-f", "h264", // raw Annex-B elementary stream
		"-flush_packets", "1",
		"-", // stdout
	)
	return args
}

// inputArgs selects the capture input. NVENC gets ddagrab (Desktop
// Duplication): frames stay D3D11 textures on the GPU all the way into the
// encoder. The other encoders consume system-memory frames, so they use
// gdigrab, which also supports true window capture by title.
func (c Config) inputArgs() []string {
	if c.Encoder == NVENC && c.CaptureRect != nil {
		return []string{
			"-init_hw_device", "d3d11va",
			// video_size deliberately comes from CaptureRect, not
			// Width/Height: this path has no scaler, so the crop IS the
			// encoded frame. The caller upholds CaptureRect.W/H ==
			// Width/Height (see Config.CaptureRect) — anything else falls
			// back to the scaling gdigrab path before reaching here.
			"-filter_complex", fmt.Sprintf(
				// draw_mouse=0: the phone renders its own touch feedback.
				"ddagrab=output_idx=%d:framerate=%d:draw_mouse=0:offset_x=%d:offset_y=%d:video_size=%dx%d",
				c.CaptureOutput, c.FPS, c.CaptureRect.X, c.CaptureRect.Y, c.CaptureRect.W, c.CaptureRect.H),
		}
	}
	return []string{
		"-f", "gdigrab",
		"-framerate", strconv.Itoa(c.FPS),
		"-draw_mouse", "0",
		"-probesize", "32", // start instantly; gdigrab needs no probing
		"-i", "title=" + c.WindowTitle,
	}
}

// encoderArgs builds the encoder half. All variants share CBR at the requested
// bitrate with a two-frame VBV buffer, a 2 s GOP, and no B-frames, and emit
// constrained-baseline H.264 to match the SDP (packetization-mode=1,
// profile-level-id 42e01f) — phone browsers, iOS Safari above all, hard-reject
// anything above baseline. Per-encoder -profile:v spellings (each verified
// against its ffmpeg option table): h264_nvenc and h264_qsv accept "baseline"
// (with -bf 0 the emitted bitstream is constrained-baseline conformant),
// h264_amf has an explicit "constrained_baseline", libx264's "baseline" IS
// constrained baseline (x264 sets constraint_set1_flag). The level is left to
// the encoder on purpose: pinning the SDP's 3.1 would cap 1080-wide 60 fps
// frames below their real requirement, and the SDP's
// level-asymmetry-allowed=1 already tells the receiver to accept whatever
// level the sender needs.
func (c Config) encoderArgs() []string {
	kbps := strconv.Itoa(c.BitrateKbps) + "k"
	// Two frames of VBV: small enough that a single burst cannot add more
	// than ~33 ms of send delay, large enough for the rate control to work.
	buf := strconv.Itoa(max(2*c.BitrateKbps/c.FPS, 64)) + "k"
	gop := strconv.Itoa(2 * c.FPS)

	switch c.Encoder {
	case NVENC:
		// Recovery points are periodic IDRs (plus on-demand IDRs via
		// Supervisor.ForceKeyframe), not a rolling -intra-refresh wavefront:
		// a browser (re)joining mid-stream cannot decode partial refresh
		// columns at all — it needs a full IDR with SPS/PPS — so intra-refresh
		// would break the PLI-driven keyframe-on-demand path outright.
		// ARCHITECTURE.md's pipeline description documents the same trade-off.
		args := []string{
			"-c:v", "h264_nvenc",
			"-preset", "p1", "-tune", "ull", "-zerolatency", "1",
			"-rc", "cbr", "-b:v", kbps, "-maxrate", kbps, "-bufsize", buf,
			"-g", gop, "-bf", "0",
			"-forced-idr", "1", // requested keyframes become true IDRs, not I-slices
			"-profile:v", "baseline",
		}
		if c.CaptureRect == nil {
			// gdigrab fallback delivers BGRA in system memory; give NVENC NV12.
			args = append(args, "-vf", scaleTo(c.Width, c.Height, "nv12"))
		}
		return args
	case AMF:
		return []string{
			"-vf", scaleTo(c.Width, c.Height, "nv12"),
			"-c:v", "h264_amf",
			"-usage", "ultralowlatency",
			"-rc", "cbr", "-b:v", kbps, "-maxrate", kbps, "-bufsize", buf,
			"-g", gop, "-bf", "0",
			"-profile:v", "constrained_baseline",
		}
	case QSV:
		return []string{
			"-vf", scaleTo(c.Width, c.Height, "nv12"),
			"-c:v", "h264_qsv",
			"-preset", "veryfast",
			"-async_depth", "1", // no frame pipelining inside the encoder
			"-b:v", kbps, "-maxrate", kbps, "-bufsize", buf,
			"-g", gop, "-bf", "0",
			"-profile:v", "baseline",
		}
	case X264:
		return []string{
			"-vf", scaleTo(c.Width, c.Height, "yuv420p"),
			"-c:v", "libx264",
			"-preset", "ultrafast", "-tune", "zerolatency",
			"-b:v", kbps, "-maxrate", kbps, "-bufsize", buf,
			"-g", gop, "-bf", "0",
			"-profile:v", "baseline",
		}
	default:
		// Unreachable: config validation and the auto-probe only produce the
		// four encoders above. Panic beats silently launching a broken argv.
		panic(fmt.Sprintf("capture: unknown encoder %q", c.Encoder))
	}
}

// scaleTo normalizes whatever the grabber delivered (window may be a few px
// off, gdigrab emits BGRA) to the exact advertised geometry and pixel format,
// so the `hello` video geometry is always truthful.
func scaleTo(w, h int, pixfmt string) string {
	return fmt.Sprintf("scale=%d:%d:flags=fast_bilinear,format=%s", w, h, pixfmt)
}

// AudioArgs builds the argv for the separate audio pipeline: DirectShow
// capture of the "virtual-audio-capturer" loopback device (from the
// screen-capture-recorder project — ffmpeg has no native WASAPI loopback,
// which is why --audio is opt-in) encoded to low-delay Opus in an Ogg stream
// on stdout. page_duration == frame_duration puts exactly one Opus packet on
// each Ogg page, so the reader can forward page payloads as RTP samples 1:1.
func (c Config) AudioArgs() []string {
	return []string{
		"-hide_banner", "-loglevel", "warning", "-nostdin",
		"-fflags", "nobuffer", "-flags", "low_delay",
		"-f", "dshow",
		"-audio_buffer_size", "20", // ms; default 500 ms would dwarf video latency
		"-i", "audio=virtual-audio-capturer",
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
