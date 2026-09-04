// Command wowstreamd is the WoW Mobile streaming host: it captures the WoW
// window with ffmpeg, streams it over WebRTC to the phone client, and injects
// the phone's touch input back into the game. See docs/ARCHITECTURE.md and
// protocol/PROTOCOL.md for the binding contracts.
//
// On Windows the released exe is built with -H=windowsgui and runs in one of
// two modes, decided at startup (ui_windows.go):
//
//   - CONSOLE mode — started from cmd/PowerShell (or with --console, or with
//     stdout piped): the parent console is attached and output behaves exactly
//     like the classic terminal build: text wizard, banner, ASCII QR. Because
//     the shell does not wait for a windowsgui exe and keeps reading the shared
//     console's input itself, a merely-attached console counts as
//     non-interactive stdin (prompts take defaults); --console relaunches into
//     a console of its own for the fully interactive wizard (ui_windows.go).
//   - GUI mode — double-clicked (or --gui): no console ever appears; the
//     wizard speaks through native dialogs, the status dashboard opens in the
//     default browser, and a tray icon offers "Open dashboard" /
//     "Choose game…" / "Quit".
//
// Non-Windows builds are console-only.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"io/fs"

	embedded "github.com/LcStylee/Wow-mobile"
	"github.com/LcStylee/Wow-mobile/server/internal/capture"
	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/hoststatus"
	"github.com/LcStylee/Wow-mobile/server/internal/input"
	"github.com/LcStylee/Wow-mobile/server/internal/install"
	"github.com/LcStylee/Wow-mobile/server/internal/rtc"
	sig "github.com/LcStylee/Wow-mobile/server/internal/signal"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// version identifies this build in the startup banner and --version. Releases
// stamp it via -ldflags "-X main.version=v1.2.3" (.github/workflows/release.yml).
var version = "dev"

// appUI is the console-vs-GUI seam, filled in by the platform initUI:
// console mode on every OS, plus a native-dialog GUI mode on Windows.
type appUI struct {
	// gui is true when no console is involved: prompts are dialogs, fatal
	// errors are message boxes, and nothing may ever block on stdin.
	gui bool
	// fatal reports err to the user (stderr + optional console hold, or an
	// error dialog) — never a silent death in GUI mode.
	fatal func(err error)
	// openURL opens the default browser (GUI mode; nil elsewhere).
	openURL func(url string)
	// newTray creates the tray icon (GUI mode; nil elsewhere) and returns a
	// tooltip updater and a remover that is safe to call multiple times.
	newTray func(dashboardURL string, onQuit func()) (setTooltip func(string), remove func(), err error)
}

// platform is the OS seam: real on Windows, unavailable elsewhere so the
// portable packages still build and test on any OS.
type platform struct {
	// newInjector creates the SendInput-backed injector for a session.
	newInjector func() (input.Injector, error)
	// clientRect returns the game window's CURRENT client rect (screen
	// position + size), ok=false when it cannot be read (window vanished).
	// Called before every ffmpeg launch — the encode adapts to the real
	// window when WoW ignored the configured resolution (capture.EncodeSize),
	// instead of producing the black-frames-with-working-clicks failure a
	// fixed assumed size gives — and polled by the geometry watchdog
	// (geowatch.go), which relaunches the pipeline when the rect drifts from
	// the running launch's record (position matters only on the ddagrab path,
	// whose crop is a fixed screen rect).
	clientRect func() (window.Rect, bool)
	// captureRect returns the game window's client rect — or, when crop is
	// non-nil, that CLIENT-LOCAL sub-rectangle of it (band mode's centered
	// 9:16 band) — translated into the local coordinates of the DXGI output
	// (monitor) fully containing it, plus that output's ddagrab output_idx,
	// when the rect is usable for the zero-copy ddagrab path: exactly the
	// encW x encH the encoder will produce (the ddagrab graph has no
	// scaler), entirely on one unrotated monitor of the default adapter.
	// Returns nil to fall back to gdigrab-by-title (with the crop expressed
	// as a filter instead). Called before every ffmpeg launch so restarts
	// pick up the window's current position, and only for NVENC — the sole
	// ddagrab consumer.
	captureRect func(encW, encH int, crop *capture.Rect) (*capture.Rect, int)
	// windowTitle returns the game window's exact full title for gdigrab's
	// FindWindow-based `title=` input (the --window-title flag is only a
	// substring). Also called before every ffmpeg launch.
	windowTitle func() string
	// enforceWindowSize (optional; Windows window capture only) resizes the
	// game window's client area to the configured resolution when it is a
	// plain windowed (non-maximized, non-fullscreen) window of a different
	// size — windowed 1.12 clients ignore the gxResolution CVar entirely, so
	// SetWindowPos is the only tool that works on every client. Called before
	// each ffmpeg launch; the implementation self-limits (it never re-attempts
	// while the window and target are unchanged, so a client that re-asserts
	// its size is fought at most twice, then adapted to). Returns a
	// human-readable outcome message, the classified outcome (so the caller
	// can map it to an honest dashboard step state), and whether an attempt
	// was made.
	enforceWindowSize func(wantW, wantH int) (msg string, outcome window.EnforceOutcome, acted bool)
}

// enforceStepState maps a window-resize outcome to the dashboard step state
// shown next to its message on the "Game running" step: green ONLY when the
// window really has (or already had) the wanted client size. Skips
// (fullscreen/maximized/minimized — deliberately not touched) render as
// skipped; a game that re-asserted its own size and outright Win32 failures
// render as failed — an ok-state step must never carry a failure message.
func enforceStepState(o window.EnforceOutcome) string {
	switch o {
	case window.EnforceResized, window.EnforceAlready:
		return hoststatus.StateOK
	case window.EnforceSkipFullscreen, window.EnforceSkipMaximized, window.EnforceSkipMinimized:
		return hoststatus.StateSkipped
	default: // EnforceReverted, EnforceFailed
		return hoststatus.StateFailed
	}
}

func main() {
	ui := initUI(os.Args[1:])
	if err := run(ui); err != nil {
		if !errors.Is(err, flag.ErrHelp) {
			ui.fatal(err)
		}
		os.Exit(1)
	}
}

func run(ui *appUI) error {
	// GUI mode has no console: flag-parse noise goes nowhere useful, and the
	// error itself carries the message for the fatal dialog.
	errOut := io.Writer(os.Stderr)
	if ui.gui {
		errOut = io.Discard
	}
	cfg, err := config.Parse(os.Args[1:], errOut)
	if err != nil {
		return err
	}
	if cfg.Version {
		fmt.Println("wowstreamd", version)
		return nil
	}
	if cfg.Setup {
		// Resolve --layout auto the same way a real run without a wizard
		// would (explicit flag, --client-type, remembered client type), so
		// `--setup` on a band-mode setup prints the band instructions — the
		// portrait steps (a forced 1080x1920-ish window) are exactly what
		// band mode exists to avoid on a 1.12 client.
		setupBand := fallbackLayout(cfg, nil) == config.LayoutBand
		resolveFitResolution(cfg, setupBand, nil) // fill Width/Height for the printout
		window.PrintSetup(os.Stdout, cfg.Width, cfg.Height, setupBand)
		return nil
	}

	setupConsole() // Windows: enable ANSI/VT output processing (no-op elsewhere)
	fmt.Printf("wowstreamd %s — WoW Mobile streaming host\n", version)

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	// One running copy per machine (Windows; no-op elsewhere). The common
	// second launch is right after installing over a running version: the old
	// instance still sits in the tray, and without this guard the new one
	// died with "bind: Only one usage of each socket address" (v0.3.2 field
	// report). Instead the user chooses: open the running instance's
	// dashboard, replace it (loopback quit + bounded wait), or exit — never
	// an error for the app merely already running.
	release, proceed, err := ensureSingleInstance(cfg, ui, log)
	if err != nil {
		return err
	}
	if !proceed {
		return nil // the running instance stays in charge; this copy exits cleanly
	}
	defer release()

	// Dashboard state: the wizard fills the checklist as it runs, the signal
	// server serves it loopback-only at /host/api/status.
	status := hoststatus.New(version, install.Steps()...)

	// First-run wizard (Windows): locate the game (Classic Era or a private-
	// server client), install the embedded addon where it works, fix
	// Config.wtf, find/install ffmpeg, make sure the game is running.
	// --skip-setup restores the pre-wizard behavior; every step is
	// idempotent and near-instant when already satisfied. --capture test
	// needs no game at all (synthetic source), so the wizard is skipped
	// there too — otherwise the "portable diagnostic mode" would stall on
	// the locate-game/game-running steps on Windows.
	layout := ""
	if cfg.Capture != config.CaptureTest {
		if layout, err = runFirstRunWizard(cfg, ui, status, log); err != nil {
			return err
		}
	}
	// The wizard resolves --layout auto by the located client type (band for
	// legacy 1.12-engine clients, portrait for Classic Era); runs without a
	// wizard (--skip-setup, --capture test, non-Windows dev) resolve it from
	// the flags and the remembered client type instead.
	if layout == "" {
		layout = fallbackLayout(cfg, log)
	}
	bandMode := layout == config.LayoutBand
	// --resolution fit is normally resolved inside the wizard; --skip-setup
	// (and non-Windows dev runs) still need concrete numbers for capture and
	// the hello geometry, so measure here as the fallback. In band mode the
	// numbers are only the no-window fallback frame — the live band decides
	// the real encode geometry.
	resolveFitResolution(cfg, bandMode, log)
	if bandMode {
		status.SetResolution("native landscape (9:16 band)")
	} else {
		status.SetResolution(fmt.Sprintf("%dx%d", cfg.Width, cfg.Height))
	}

	// --capture test replaces the Windows window platform with the portable
	// test-pattern stand-in: same encoder/parser/WebRTC path, synthetic input.
	var plat *platform
	if cfg.Capture == config.CaptureTest {
		log.Info("capture source: testsrc2 synthetic pattern (--capture test)")
		plat = newTestPlatform(cfg, bandMode, log)
	} else {
		plat, err = newPlatform(cfg, bandMode, log)
		if err != nil {
			return err
		}
	}

	ffmpegPath := cfg.FFmpegPath
	if ffmpegPath == "" {
		ffmpegPath, err = exec.LookPath("ffmpeg")
		if err != nil {
			return fmt.Errorf("ffmpeg not found in PATH (install it or pass --ffmpeg): %w", err)
		}
	}
	encoder, err := resolveEncoder(cfg, ffmpegPath, log)
	if err != nil {
		return err
	}
	status.SetEncoder(encoderDisplay(encoder))

	// CaptureRect and the exact WindowTitle are live values (the window can
	// move, its title is only known by substring), so they are re-resolved by
	// the argv callback below at every ffmpeg launch rather than frozen here —
	// otherwise crash/bitrate/keyframe restarts would keep a stale crop while
	// input injection follows the live window.
	capCfg := capture.Config{
		FFmpegPath:  ffmpegPath,
		WindowTitle: cfg.WindowTitle,
		Width:       cfg.Width,
		Height:      cfg.Height,
		FPS:         cfg.FPS,
		BitrateKbps: cfg.BitrateKbps,
		Encoder:     encoder,
		TestSource:  cfg.Capture == config.CaptureTest,
	}
	// geom is the geometry the encoder is currently producing — normally the
	// configured resolution, but the capture SELF-HEALS to the game window's
	// actual client area when WoW ignored the configured size (Config.wtf
	// overwritten because the game was running during setup, DPI
	// virtualization, or the client restoring its own rect). The hello reply
	// reads it so the phone always letterboxes the frame it really receives;
	// input injection already follows the live rect independently.
	geom := newLiveGeometry(cfg.Width, cfg.Height)
	// reportGeometry surfaces a window/resolution mismatch LOUDLY (log line +
	// dashboard warning row) but only on change, so keyframe/bitrate restarts
	// do not spam identical lines. Single caller (the supervisor's run
	// goroutine, plus one pre-stream check below before it starts): no lock.
	lastWarning := "\x00never-reported" // sentinel unequal to any real state
	reportGeometry := func(actualW, actualH, encW, encH int, mismatch bool) {
		// The dashboard's layout line stays truthful in portrait mode too.
		status.SetLayout(fmt.Sprintf("portrait window %dx%d", encW, encH))
		warning := ""
		if mismatch {
			warning = capture.MismatchWarning(actualW, actualH, cfg.Width, cfg.Height, encW, encH)
		}
		if warning == lastWarning {
			return
		}
		lastWarning = warning
		status.SetWarning(warning)
		if warning != "" {
			log.Warn(warning)
		} else {
			log.Info("game window matches the configured resolution",
				"resolution", fmt.Sprintf("%dx%d", encW, encH))
		}
	}
	// reportBand is band mode's counterpart: no size to enforce, nothing to
	// warn about — the live layout line ("center band 1215x2160 of
	// 3840x2160") goes to the log and the dashboard, and a portrait window
	// under band layout is called out as the full-window fallback it is.
	lastBandDesc := "\x00never-reported"
	reportBand := func(aw, ah int, f window.BandFrame) {
		desc := window.BandLayoutDescription(aw, ah, f)
		if desc == lastBandDesc {
			return
		}
		lastBandDesc = desc
		status.SetLayout(desc)
		if f.Banded {
			log.Info("stream layout", "layout", desc)
		} else {
			log.Warn("band layout: the game window is portrait — streaming the full window (the band contract only applies to landscape windows)",
				"window", fmt.Sprintf("%dx%d", aw, ah))
		}
	}
	// enforceSize runs the direct-window-resize path (Windows window capture,
	// PORTRAIT layout only): a windowed game at the wrong size is resized to
	// the configured resolution BEFORE the geometry self-heal reads it —
	// CVars cannot size a windowed 1.12 client, SetWindowPos can. Outcomes
	// surface on the log and the dashboard's "Game running" step detail; the
	// implementation self-limits re-attempts, so calling it per launch cannot
	// become a fight. Band mode retires enforcement outright: any landscape
	// window is welcome, the band adapts to it.
	enforceSize := func() {
		if bandMode || plat.enforceWindowSize == nil {
			return
		}
		if msg, outcome, acted := plat.enforceWindowSize(cfg.Width, cfg.Height); acted {
			log.Info("window size enforcement", "result", msg)
			status.SetStep(install.StepRunning, enforceStepState(outcome), msg)
		}
	}
	// updateFrame re-reads the live client rect and decides the frame for one
	// ffmpeg launch: the encode must frame the ACTUAL window — a fixed crop
	// of the assumed size grabs desktop (or off-screen, i.e. black) pixels;
	// degraded-but-visible beats black. Portrait layout self-heals the whole
	// frame to the real client area (capture.EncodeSize); band layout
	// recomputes the centered 9:16 band per the band contract
	// (window.ComputeBandFrame) and crops it before encoding, scaling down to
	// the 1080x1920 design cap when the band exceeds it. Either way the hello
	// geometry (geom) follows the encoder's real output. Returns the observed
	// client rect (ok=false when the window was unreadable) so the argv
	// callback can record what this launch was built from.
	updateFrame := func(c *capture.Config) (window.Rect, bool) {
		rc, ok := plat.clientRect()
		if !ok {
			return window.Rect{}, false // no window to measure: keep the configured fallback frame
		}
		aw, ah := rc.W, rc.H
		if bandMode {
			f, fok := window.ComputeBandFrame(aw, ah)
			if !fok {
				return rc, true // degenerate rect (mid-resize): keep the fallback frame
			}
			c.Width, c.Height = f.EncW, f.EncH
			c.CropRect, c.SourceW, c.SourceH = nil, 0, 0
			if f.Banded {
				c.CropRect = &capture.Rect{X: f.Band.X, Y: f.Band.Y, W: f.Band.W, H: f.Band.H}
				c.SourceW, c.SourceH = aw, ah
			}
			geom.set(f.EncW, f.EncH)
			reportBand(aw, ah, f)
			return rc, true
		}
		encW, encH, mismatch := capture.EncodeSize(aw, ah, cfg.Width, cfg.Height)
		c.Width, c.Height = encW, encH
		geom.set(encW, encH)
		reportGeometry(aw, ah, encW, encH, mismatch)
		return rc, true
	}
	// launchGeom records the client rect each ffmpeg launch was built from —
	// the geometry watchdog (started below) compares the live rect against it
	// and relaunches the pipeline on drift, so a mid-session resize (or, on
	// the ddagrab screen-rect path, a move) heals within seconds instead of
	// waiting for the next incidental restart.
	launchGeom := &launchGeometry{}
	videoArgv := func(c capture.Config) []string {
		enforceSize()
		rc, rcOK := updateFrame(&c)
		if c.Encoder == capture.NVENC {
			// Only NVENC consumes the ddagrab target; skipping the DXGI
			// probe elsewhere keeps the other encoders' launches quiet. The
			// band crop is folded into the ddagrab rect when usable (ddagrab
			// crops at grab time and has no filter stage), so a matching
			// band takes the zero-copy path too.
			c.CaptureRect, c.CaptureOutput = plat.captureRect(c.Width, c.Height, c.CropRect)
			if c.CaptureRect != nil {
				c.CropRect, c.SourceW, c.SourceH = nil, 0, 0
			}
		}
		c.WindowTitle = plat.windowTitle()
		if rcOK {
			launchGeom.set(rc, c.CaptureRect != nil)
		} else {
			launchGeom.invalidate() // vanished window: the supervisor's retry loop owns it
		}
		return c.VideoArgs()
	}
	// Check once before any phone connects, too: the dashboard must show the
	// layout line (or the mismatch warning) while the user is still staring
	// at the QR code, not only after the first capture launch — and in
	// portrait mode the window is sized right away, not only when the first
	// session starts capture.
	enforceSize()
	{
		scratch := capCfg
		updateFrame(&scratch)
	}

	meter := capture.NewMeter(cfg.FPS)
	var mgr *rtc.Manager // assigned below; the consumer closure needs it

	videoSup := capture.NewSupervisor("video", capCfg, videoArgv,
		func(stdout io.Reader) error {
			parser := capture.NewAnnexBParser(func(au capture.AccessUnit) {
				meter.Add(len(au.Data), au.Keyframe)
				mgr.WriteVideoAU(au)
			})
			defer parser.Flush()
			buf := make([]byte, 64<<10)
			for {
				n, err := stdout.Read(buf)
				if n > 0 {
					parser.Write(buf[:n])
				}
				if err != nil {
					return err
				}
			}
		}, log)

	var audioSup *capture.Supervisor
	var captureActive atomic.Bool // read by the capture-stall watchdog below
	setActive := func(active bool) {
		captureActive.Store(active)
		if active {
			videoSup.Start()
			if audioSup != nil {
				audioSup.Start()
			}
		} else {
			videoSup.Stop()
			if audioSup != nil {
				audioSup.Stop()
			}
		}
	}

	mgr, err = rtc.NewManager(rtc.Options{
		VideoWidth:    cfg.Width,
		VideoHeight:   cfg.Height,
		VideoGeometry: geom.get,
		FPS:           cfg.FPS,
		Audio:         cfg.Audio,
		NewInjector:   plat.newInjector,
		SetActive:     setActive,
		SetBitrate:    videoSup.SetBitrate,
		ForceKeyframe: videoSup.ForceKeyframe,
		VideoStats:    meter.Snapshot,
		Logger:        log,
	})
	if err != nil {
		return err
	}
	if cfg.Audio {
		audioSup = capture.NewSupervisor("audio", capCfg, capture.Config.AudioArgs, mgr.ConsumeOgg, log)
	}

	// Startup self-check: ~2 s of testsrc2 through the SELECTED encoder and
	// the production Annex-B parser (no WebRTC), so "can this machine encode
	// at all?" is answered on the dashboard before any phone connects. In a
	// goroutine — it must never delay the listener.
	go func() {
		res := capture.SelfCheck(ffmpegPath, encoder, 256, 256, cfg.FPS)
		status.SetSelfCheck(res.OK, res.Detail)
		if res.OK {
			log.Info("video pipeline self-check passed", "frames", res.Frames)
		} else {
			log.Warn("video pipeline self-check FAILED", "detail", res.Detail)
		}
	}()

	// Ctrl+C / SIGTERM: release inputs, close the peer, kill ffmpeg — in
	// that order, so a mid-fight disconnect never leaves keys held. The
	// dashboard's Quit button and the tray menu cancel the same context.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	runCtx, quit := context.WithCancel(ctx)
	defer quit()

	// Capture-stall watchdog: while a session wants video but ffmpeg delivers
	// ZERO frames for several seconds, put ffmpeg's stderr tail on the
	// dashboard — the user must be able to READ why the stream is black.
	go captureStallWatchdog(runCtx, captureStall{
		active: captureActive.Load,
		frames: meter.TotalFrames,
		stderr: videoSup.StderrTail,
		warn:   status.SetCaptureWarning,
		log:    log,
	})

	// Geometry watchdog: while capture is active, poll the live client rect
	// and relaunch the video pipeline when the window settled on a different
	// rect than the running ffmpeg was launched with (band mode deliberately
	// un-pins the window, so mid-session resizes/moves are expected; input
	// injection follows the live window per event, and the stream must not be
	// left cropping stale pixels until a phone reconnect).
	go geometryWatchdog(runCtx, geometryWatch{
		active:     captureActive.Load,
		clientRect: plat.clientRect,
		launched:   launchGeom.get,
		restart:    videoSup.Restart,
		log:        log,
	})

	// The phone client PWA ships inside the binary; --client-dir overrides it
	// with a disk directory for development. Either way the binary no longer
	// cares what directory it is started from.
	clientFS, err := fs.Sub(embedded.ClientFS, "client")
	if err != nil {
		return fmt.Errorf("embedded client missing: %w", err)
	}
	server := sig.New(cfg.Addr, cfg.Token, cfg.NoTLS, clientFS, cfg.ClientDir, version, mgr, log)

	// Host dashboard: embedded separately from the public client tree and
	// served loopback-only (it shows the pairing token).
	hostFS, err := fs.Sub(embedded.HostFS, "client/host")
	if err != nil {
		return fmt.Errorf("embedded host dashboard missing: %w", err)
	}
	server.EnableHostUI(sig.HostUI{FS: hostFS, Status: status, Quit: quit})

	// Bind before the banner: a port-in-use failure must surface as the error,
	// never after a full "ready" message. The single-instance mutex rules out
	// another CURRENT wowstreamd, but a pre-0.3.3 instance claimed no mutex —
	// handleBindConflict probes for that exact case (its dashboard answers on
	// the port) and runs the open/replace/exit choice; anything else falls
	// through to describeListenError's plain-words message.
	if err := server.Listen(); err != nil {
		retry, done, herr := handleBindConflict(cfg, ui, log, err)
		if herr != nil {
			return herr
		}
		if done {
			return nil // resolved: dashboard opened, or the running copy stays in charge
		}
		if !retry {
			return describeListenError(cfg.Addr, err)
		}
		if err := server.Listen(); err != nil {
			return describeListenError(cfg.Addr, err)
		}
	}
	// Remember the successfully bound port: a future second launch reads it
	// to reach THIS instance's loopback dashboard (open it, or ask it to
	// quit for "Replace it") even under a non-default --addr. Best-effort.
	persistBoundPort(server.Port(), log)
	// Harness support: with --addr :0 the kernel picks the port; publish the
	// real one. The file is written atomically-enough (tmp+rename) so a reader
	// polling for it never sees a partial write.
	if cfg.PortFile != "" {
		if err := writePortFile(cfg.PortFile, server.Port()); err != nil {
			return fmt.Errorf("writing --port-file: %w", err)
		}
	}
	log.Info("listening", "port", server.Port())
	status.SetPairingURL(server.PairingURL(cfg.Token))
	status.SetConnectedFunc(mgr.SessionConnected)
	status.SetStatsFunc(func() hoststatus.Stream {
		st := meter.Snapshot()
		return hoststatus.Stream{
			Kbps: st.Kbps, FPS: st.CaptureFPS, EncodeMs: st.PipelineDelayMs,
			// Capture diagnostics: a black phone screen is diagnosable at a
			// glance — 0 captured = capture dead; captured but not sent =
			// write path; stale keyframe = IDR path.
			FramesCaptured:    st.FramesCaptured,
			FramesSent:        mgr.FramesSent(),
			LastKeyframeAgeMs: st.LastKeyframeAgeMs,
		}
	})
	status.SetRunning(true)

	// Console mode prints the banner + ASCII QR and the dashboard URL (it
	// does NOT auto-open a browser); GUI mode opens the dashboard and puts
	// the icon in the tray instead.
	server.PrintBanner(os.Stdout, cfg.Token, cfg.TokenIsGenerated)
	if ui.gui {
		// HostURL is "" when --addr binds a specific non-loopback address:
		// the loopback-only dashboard is unreachable then, so don't auto-open
		// a dead page — the tray still provides Quit (its "Open dashboard"
		// becomes a no-op; ui_windows.go guards the empty URL).
		dashboardURL := server.HostURL()
		if dashboardURL == "" {
			log.Warn("host dashboard unreachable: --addr binds a non-loopback address; skipping browser auto-open (use a wildcard or loopback bind to enable the dashboard)", "addr", cfg.Addr)
		}
		if ui.newTray != nil {
			setTooltip, removeTray, trayErr := ui.newTray(dashboardURL, quit)
			if trayErr != nil {
				log.Warn("tray icon unavailable", "err", trayErr)
			} else {
				// Remove the icon on every shutdown path.
				defer removeTray()
				go trayTooltipLoop(runCtx, setTooltip, mgr.SessionConnected)
			}
		}
		if ui.openURL != nil && dashboardURL != "" {
			ui.openURL(dashboardURL)
		}
	}

	defer func() {
		mgr.Shutdown()
		videoSup.Stop()
		if audioSup != nil {
			audioSup.Stop()
		}
	}()
	return server.Serve(runCtx)
}

// describeListenError turns the opaque address-in-use bind failure into an
// actionable message naming the culprit class and both ways out. Every other
// listen error passes through untouched. The mutex guard and
// handleBindConflict (which catches mutex-less pre-0.3.3 instances whose
// dashboard answers) run first, so by the time this fires the holder is some
// other program — or an old WoW Mobile too wedged to answer its own status
// endpoint, which the message admits.
func describeListenError(addr string, err error) error {
	if !isAddrInUse(err) {
		return err
	}
	port := "8443"
	if _, p, splitErr := net.SplitHostPort(addr); splitErr == nil && p != "" {
		port = p
	}
	alt := ":8444"
	if n, convErr := strconv.Atoi(port); convErr == nil && n > 0 && n < 65535 {
		alt = fmt.Sprintf(":%d", n+1)
	}
	return fmt.Errorf("port %s is in use by another program — possibly an unresponsive older WoW Mobile (check the system tray / Task Manager for wowstreamd.exe). Close it, or pass --addr %s to use a different port (%w)", port, alt, err)
}

// persistBoundPort records the bound port in the config store (KeyLastPort)
// for the single-instance guard of a FUTURE launch. Best-effort: a failure
// only costs that guard its non-default-port discovery (it falls back to
// 8443), so it is logged, never fatal.
func persistBoundPort(port int, log *slog.Logger) {
	// Only the Windows single-instance guard ever reads KeyLastPort
	// (singleinstance_other.go is a no-op), so Linux dev runs and the e2e
	// harness must not write it into the developer's real config store.
	if runtime.GOOS != "windows" {
		return
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return
	}
	store := install.LoadStore(filepath.Join(dir, "wowstreamd"))
	val := strconv.Itoa(port)
	if store.Get(install.KeyLastPort) == val {
		return
	}
	store.Set(install.KeyLastPort, val)
	if err := store.Save(); err != nil {
		log.Warn("could not remember the bound port for the already-running guard", "err", err)
	}
}

// writePortFile publishes the bound TCP port for test harnesses (--port-file):
// write-to-temp + rename so a polling reader never observes a partial file.
func writePortFile(path string, port int) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(fmt.Sprintf("%d\n", port)), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// liveGeometry is the concurrency-safe holder for the geometry the encoder is
// currently producing: written by the capture argv callback at every ffmpeg
// launch (self-healing to the actual window client area — in band layout, to
// the encoded band cropped from it), read by the rtc hello reply. Seeded with
// the configured resolution so a hello racing the very first capture launch
// still advertises a sane frame.
type liveGeometry struct {
	mu   sync.Mutex
	w, h int
}

func newLiveGeometry(w, h int) *liveGeometry { return &liveGeometry{w: w, h: h} }

func (g *liveGeometry) set(w, h int) {
	g.mu.Lock()
	g.w, g.h = w, h
	g.mu.Unlock()
}

func (g *liveGeometry) get() (int, int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.w, g.h
}

// trayTooltipLoop keeps the tray hover text honest: "streaming" while a phone
// is connected, "waiting for phone" otherwise.
func trayTooltipLoop(ctx context.Context, setTooltip func(string), connected func() bool) {
	last := ""
	update := func() {
		tip := "WoW Mobile — waiting for phone"
		if connected() {
			tip = "WoW Mobile — streaming"
		}
		if tip != last {
			last = tip
			setTooltip(tip)
		}
	}
	update()
	t := time.NewTicker(2 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			update()
		}
	}
}

// fallbackLayout resolves --layout auto for runs the wizard did not settle
// (--setup, --skip-setup, --capture test, non-Windows dev): an explicit flag
// wins; otherwise the client type — the --client-type flag, or on Windows the
// remembered choice in the config store — picks band for legacy 1.12-engine
// clients; with no known client type the classic portrait mode stands. log
// may be nil (the --setup printout path).
func fallbackLayout(cfg *config.Config, log *slog.Logger) string {
	if cfg.Layout != config.LayoutAuto {
		return cfg.Layout
	}
	ct := cfg.ClientType
	if ct == config.ClientTypeAuto && runtime.GOOS == "windows" && cfg.Capture != config.CaptureTest {
		// Same store the wizard writes; read-only here. KeyClientType
		// describes the game recorded in KeyGameExe (Store semantics), so
		// when --game-exe/--wow-dir select an install explicitly, the
		// remembered type is honored only if it describes that same install
		// — otherwise a stale legacy record would silently pick band layout
		// for an unrelated Era client (and vice versa).
		if dir, err := os.UserConfigDir(); err == nil {
			store := install.LoadStore(filepath.Join(dir, "wowstreamd"))
			if storedClientTypeTrusted(store, cfg.GameExe, cfg.WowDir) &&
				install.ClientType(store.Get(install.KeyClientType)) == install.ClientTypeLegacy {
				ct = config.ClientTypeLegacy
			}
		}
	}
	layout := config.LayoutPortrait
	if ct == config.ClientTypeLegacy {
		layout = config.LayoutBand
	}
	if log != nil {
		log.Info("layout resolved", "layout", layout, "reason", "--layout auto without a wizard run")
	}
	return layout
}

// storedClientTypeTrusted reports whether the store's remembered
// KeyClientType may stand in for THIS run's client type: with no explicit
// install flags the run targets the remembered game itself, so yes; with
// --game-exe the remembered type only applies when it was recorded for that
// exact executable; with --wow-dir, when the recorded executable lives under
// that directory. Anything else is an unknown client type — the soft portrait
// default (and the --layout/--client-type flags) covers it.
func storedClientTypeTrusted(store *install.Store, gameExe, wowDir string) bool {
	if gameExe == "" && wowDir == "" {
		return true
	}
	stored := store.Get(install.KeyGameExe)
	if stored == "" {
		return false
	}
	if gameExe != "" {
		return normPath(stored) == normPath(gameExe)
	}
	dir := normPath(wowDir)
	return strings.HasPrefix(normPath(stored), dir+string(filepath.Separator))
}

// normPath canonicalizes a path for identity comparison: cleaned, and
// case-folded on Windows (the only OS whose store this code reads), whose
// filesystems are case-insensitive.
func normPath(p string) string {
	p = filepath.Clean(p)
	if runtime.GOOS == "windows" {
		p = strings.ToLower(p)
	}
	return p
}

// resolveFitResolution fills cfg.Width/Height when --resolution fit was not
// resolved by the wizard (--skip-setup, --setup, or a non-Windows dev run):
// the same monitor-fit math the wizard uses, or the 1080x1920 design
// resolution where nothing can be measured. Band mode skips the monitor fit
// outright — the live band decides the encode; the design resolution is only
// the no-window fallback frame. No-op once the numbers are set. log may be
// nil (the --setup printout path).
func resolveFitResolution(cfg *config.Config, band bool, log *slog.Logger) {
	if cfg.Width != 0 || !cfg.ResolutionIsFit {
		return
	}
	if band {
		cfg.Width, cfg.Height = window.DesignW, window.DesignH
		if log != nil {
			log.Info("band layout: no portrait fit; the 1080x1920 design space is only the no-window fallback frame")
		}
		return
	}
	if w, h, workW, workH, ok := measureFitResolution(); ok {
		cfg.Width, cfg.Height = w, h
		if log != nil {
			log.Info("monitor-fit resolution", "resolution", fmt.Sprintf("%dx%d", w, h),
				"work_area", fmt.Sprintf("%dx%d", workW, workH))
		}
		fmt.Println(window.FitDescription(w, h, workW, workH))
		return
	}
	cfg.Width, cfg.Height = window.DesignW, window.DesignH
	if log != nil {
		log.Info("monitor work area not measurable; using the 1080x1920 design resolution")
	}
}

// resolveEncoder turns --encoder=auto into a concrete choice via ffmpeg probe.
func resolveEncoder(cfg *config.Config, ffmpegPath string, log *slog.Logger) (capture.Encoder, error) {
	if cfg.Encoder != config.EncoderAuto {
		return capture.Encoder(cfg.Encoder), nil
	}
	enc, err := capture.ProbeEncoder(ffmpegPath)
	if err != nil {
		return "", err
	}
	log.Info("encoder auto-selected", "encoder", string(enc))
	return enc, nil
}

// encoderDisplay is the human/dashboard name for a concrete encoder choice.
func encoderDisplay(enc capture.Encoder) string {
	switch enc {
	case capture.NVENC:
		return "h264_nvenc"
	case capture.AMF:
		return "h264_amf"
	case capture.QSV:
		return "h264_qsv"
	case capture.X264:
		return "libx264 (software)"
	}
	return string(enc)
}
