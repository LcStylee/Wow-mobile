// Package config parses and validates the wowstreamd command line.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/LcStylee/Wow-mobile/server/internal/capture"
)

// Encoder names accepted by --encoder. EncoderAuto is resolved to a concrete
// encoder at startup by probing the local ffmpeg build.
const (
	EncoderAuto  = "auto"
	EncoderNVENC = "nvenc"
	EncoderAMF   = "amf"
	EncoderQSV   = "qsv"
	EncoderX264  = "x264"
)

// ResolutionFit is the --resolution value (and default) that sizes the
// window to the largest 9:16 portrait client area fitting the primary
// monitor's work area. A 1080x1920 design window cannot physically fit a
// landscape 1920x1080 monitor — Windows clamps it, the user sees only the
// top rows, and desktop-region capture of the off-screen rest goes black —
// so fitting is the default and an explicit WxH is sanity-checked by the
// wizard.
const ResolutionFit = "fit"

// Config is the fully parsed, validated runtime configuration.
type Config struct {
	Addr             string // listen address for the signaling/https server
	Token            string // pairing token; generated when not supplied
	TokenIsGenerated bool
	// Width/Height are the capture resolution. Zero when ResolutionIsFit and
	// not yet resolved — the wizard (or main's fallback) measures the monitor
	// and fills them before anything consumes the geometry.
	Width  int
	Height int
	// ResolutionIsFit records that --resolution was "fit" (the default): the
	// concrete Width/Height are computed at wizard time from the primary
	// monitor's work area instead of being taken from the flag.
	ResolutionIsFit bool
	FPS             int
	BitrateKbps     int
	Encoder         string // one of the Encoder* constants
	WindowTitle     string
	ClientDir       string // as given on the command line; resolved by the signal server
	NoTLS           bool
	FFmpegPath      string // empty = look up "ffmpeg" in PATH
	Audio           bool
	Setup           bool   // --setup: print WoW configuration help and exit
	WowDir          string // --wow-dir: WoW game directory (skips wizard auto-detection)
	GameExe         string // --game-exe: exact game executable (private servers); beats --wow-dir
	Yes             bool   // --yes: first-run wizard accepts every default without prompting
	ChooseGame      bool   // --choose-game: always show the game-install picker, even over a remembered choice
	SkipSetup       bool   // --skip-setup: skip the first-run wizard entirely
	Version         bool   // --version: print the version and exit
	ForceConsole    bool   // --console: force console mode (Windows GUI builds)
	ForceGUI        bool   // --gui: force GUI mode even from a terminal (Windows)
}

// Parse parses argv (without the program name). Usage/errors go to errOut.
func Parse(args []string, errOut io.Writer) (*Config, error) {
	fs := flag.NewFlagSet("wowstreamd", flag.ContinueOnError)
	fs.SetOutput(errOut)

	cfg := &Config{}
	var resolution string
	fs.StringVar(&cfg.Addr, "addr", ":8443", "listen address for the signaling server")
	fs.StringVar(&cfg.Token, "token", "", "pairing token (default: randomly generated and printed at startup)")
	fs.StringVar(&resolution, "resolution", ResolutionFit, "capture resolution: \"fit\" (default) sizes the WoW window to the largest 9:16 portrait rect that fits the primary monitor; an explicit WIDTHxHEIGHT must match the WoW window client size")
	fs.IntVar(&cfg.FPS, "fps", 60, "capture/encode frame rate")
	fs.IntVar(&cfg.BitrateKbps, "bitrate-kbps", 8000, "video bitrate in kbit/s (CBR)")
	fs.StringVar(&cfg.Encoder, "encoder", EncoderAuto, "video encoder: auto|nvenc|amf|qsv|x264")
	fs.StringVar(&cfg.WindowTitle, "window-title", "World of Warcraft", "substring of the game window title to capture")
	fs.StringVar(&cfg.ClientDir, "client-dir", "", "serve the phone client PWA from this disk directory instead of the copy embedded in the binary (development)")
	fs.BoolVar(&cfg.NoTLS, "no-tls", false, "serve plain HTTP instead of HTTPS with a self-signed certificate")
	fs.StringVar(&cfg.FFmpegPath, "ffmpeg", "", "path to the ffmpeg executable (default: find \"ffmpeg\" in PATH)")
	// Opt-in, not default-on: robust WASAPI loopback needs the third-party
	// "virtual-audio-capturer" DirectShow device (screen-capture-recorder
	// project) — ffmpeg alone cannot tap WASAPI loopback on stock Windows.
	fs.BoolVar(&cfg.Audio, "audio", false, "capture desktop audio via the DirectShow device \"virtual-audio-capturer\" (requires screen-capture-recorder to be installed)")
	fs.BoolVar(&cfg.Setup, "setup", false, "print WoW Config.wtf and addon setup instructions, then exit")
	fs.StringVar(&cfg.WowDir, "wow-dir", "", "path to the WoW game directory (e.g. the _classic_era_ folder, or a private-server folder containing Wow.exe); skips the wizard's auto-detection")
	fs.StringVar(&cfg.GameExe, "game-exe", "", "exact game executable to record and launch (private servers, e.g. VanillaFixes.exe); overrides --wow-dir and every auto-detection")
	fs.BoolVar(&cfg.Yes, "yes", false, "first-run wizard: accept every default without prompting (non-interactive)")
	fs.BoolVar(&cfg.ChooseGame, "choose-game", false, "show the game-install picker at startup (the World of Warcraft installs found, with detected versions), even when a game is already remembered")
	fs.BoolVar(&cfg.SkipSetup, "skip-setup", false, "skip the first-run setup wizard entirely")
	fs.BoolVar(&cfg.Version, "version", false, "print the wowstreamd version and exit")
	// Mode overrides for the Windows GUI build (-H=windowsgui): double-click
	// gets native dialogs + the browser dashboard; a terminal launch is
	// auto-detected. These flags force either way; no-ops off Windows.
	fs.BoolVar(&cfg.ForceConsole, "console", false, "force console mode: the interactive text wizard, never dialogs; from a shell this opens its own console window (Windows)")
	fs.BoolVar(&cfg.ForceGUI, "gui", false, "force GUI mode: native dialogs and the browser dashboard even when started from a terminal (Windows)")

	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	if fs.NArg() > 0 {
		return nil, fmt.Errorf("unexpected positional arguments: %v", fs.Args())
	}

	var err error
	if resolution == ResolutionFit {
		cfg.ResolutionIsFit = true // Width/Height stay 0 until measured
	} else {
		cfg.Width, cfg.Height, err = ParseResolution(resolution)
		if err != nil {
			return nil, err
		}
	}
	if cfg.FPS < 1 || cfg.FPS > 240 {
		return nil, fmt.Errorf("--fps %d out of range 1..240", cfg.FPS)
	}
	// Same limits as the ctrl "bitrate" handler (capture.Min/MaxBitrateKbps),
	// so clients can request every rate the flag accepts.
	if cfg.BitrateKbps < capture.MinBitrateKbps || cfg.BitrateKbps > capture.MaxBitrateKbps {
		return nil, fmt.Errorf("--bitrate-kbps %d out of range %d..%d",
			cfg.BitrateKbps, capture.MinBitrateKbps, capture.MaxBitrateKbps)
	}
	switch cfg.Encoder {
	case EncoderAuto, EncoderNVENC, EncoderAMF, EncoderQSV, EncoderX264:
	default:
		return nil, fmt.Errorf("--encoder %q: must be auto|nvenc|amf|qsv|x264", cfg.Encoder)
	}
	if cfg.WindowTitle == "" {
		return nil, fmt.Errorf("--window-title must not be empty")
	}
	if cfg.ForceConsole && cfg.ForceGUI {
		return nil, fmt.Errorf("--console and --gui are mutually exclusive")
	}
	if cfg.ChooseGame && cfg.SkipSetup {
		return nil, fmt.Errorf("--choose-game and --skip-setup are mutually exclusive (the picker is part of setup)")
	}
	if cfg.Token == "" {
		cfg.Token, err = generateToken()
		if err != nil {
			return nil, fmt.Errorf("generating pairing token: %w", err)
		}
		cfg.TokenIsGenerated = true
	}
	return cfg, nil
}

// ParseResolution parses "WIDTHxHEIGHT". Both dimensions must be even because
// every supported H.264 encoder requires mod-2 frame sizes for 4:2:0.
func ParseResolution(s string) (w, h int, err error) {
	parts := strings.Split(s, "x")
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("--resolution %q: want WIDTHxHEIGHT, e.g. 1080x1920", s)
	}
	w, errW := strconv.Atoi(parts[0])
	h, errH := strconv.Atoi(parts[1])
	if errW != nil || errH != nil || w < 16 || h < 16 || w > 7680 || h > 7680 {
		return 0, 0, fmt.Errorf("--resolution %q: dimensions must be integers in 16..7680", s)
	}
	if w%2 != 0 || h%2 != 0 {
		return 0, 0, fmt.Errorf("--resolution %q: width and height must be even (H.264 4:2:0)", s)
	}
	return w, h, nil
}

// generateToken returns 128 bits of hex from crypto/rand — enough entropy that
// the LAN pairing URL cannot be brute-forced during a session.
func generateToken() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}
