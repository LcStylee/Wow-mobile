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
//     default browser, and a tray icon offers "Open dashboard" / "Quit".
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
	"os"
	"os/exec"
	"os/signal"
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
	// captureRect returns the game window's client rect translated into the
	// local coordinates of the DXGI output (monitor) fully containing it,
	// plus that output's ddagrab output_idx, when the window is usable for
	// the zero-copy ddagrab path: client area exactly --resolution (the
	// ddagrab graph has no scaler), entirely on one unrotated monitor of the
	// default adapter. Returns nil to fall back to gdigrab-by-title. Called
	// before every ffmpeg launch so restarts pick up the window's current
	// position, and only for NVENC — the sole ddagrab consumer.
	captureRect func() (*capture.Rect, int)
	// windowTitle returns the game window's exact full title for gdigrab's
	// FindWindow-based `title=` input (the --window-title flag is only a
	// substring). Also called before every ffmpeg launch.
	windowTitle func() string
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
		window.PrintSetup(os.Stdout, cfg.Width, cfg.Height)
		return nil
	}

	setupConsole() // Windows: enable ANSI/VT output processing (no-op elsewhere)
	fmt.Printf("wowstreamd %s — WoW Mobile streaming host\n", version)

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	// Dashboard state: the wizard fills the checklist as it runs, the signal
	// server serves it loopback-only at /host/api/status.
	status := hoststatus.New(version, install.Steps()...)

	// First-run wizard (Windows): locate the game (Classic Era or a private-
	// server client), install the embedded addon where it works, fix
	// Config.wtf, find/install ffmpeg, make sure the game is running.
	// --skip-setup restores the pre-wizard behavior; every step is
	// idempotent and near-instant when already satisfied.
	if err := runFirstRunWizard(cfg, ui, status, log); err != nil {
		return err
	}

	plat, err := newPlatform(cfg, log)
	if err != nil {
		return err
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
	}
	videoArgv := func(c capture.Config) []string {
		if c.Encoder == capture.NVENC {
			// Only NVENC consumes the ddagrab target; skipping the DXGI
			// probe elsewhere keeps the other encoders' launches quiet.
			c.CaptureRect, c.CaptureOutput = plat.captureRect()
		}
		c.WindowTitle = plat.windowTitle()
		return c.VideoArgs()
	}

	meter := capture.NewMeter(cfg.FPS)
	var mgr *rtc.Manager // assigned below; the consumer closure needs it

	videoSup := capture.NewSupervisor("video", capCfg, videoArgv,
		func(stdout io.Reader) error {
			parser := capture.NewAnnexBParser(func(au capture.AccessUnit) {
				meter.Add(len(au.Data))
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
	setActive := func(active bool) {
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

	// Ctrl+C / SIGTERM: release inputs, close the peer, kill ffmpeg — in
	// that order, so a mid-fight disconnect never leaves keys held. The
	// dashboard's Quit button and the tray menu cancel the same context.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	runCtx, quit := context.WithCancel(ctx)
	defer quit()

	// The phone client PWA ships inside the binary; --client-dir overrides it
	// with a disk directory for development. Either way the binary no longer
	// cares what directory it is started from.
	clientFS, err := fs.Sub(embedded.ClientFS, "client")
	if err != nil {
		return fmt.Errorf("embedded client missing: %w", err)
	}
	server := sig.New(cfg.Addr, cfg.Token, cfg.NoTLS, clientFS, cfg.ClientDir, mgr, log)

	// Host dashboard: embedded separately from the public client tree and
	// served loopback-only (it shows the pairing token).
	hostFS, err := fs.Sub(embedded.HostFS, "client/host")
	if err != nil {
		return fmt.Errorf("embedded host dashboard missing: %w", err)
	}
	server.EnableHostUI(sig.HostUI{FS: hostFS, Status: status, Quit: quit})

	// Bind before the banner: a port-in-use failure must surface as the error,
	// never after a full "ready" message.
	if err := server.Listen(); err != nil {
		return err
	}
	status.SetPairingURL(server.PairingURL(cfg.Token))
	status.SetConnectedFunc(mgr.SessionConnected)
	status.SetStatsFunc(func() hoststatus.Stream {
		st := meter.Snapshot()
		return hoststatus.Stream{Kbps: st.Kbps, FPS: st.CaptureFPS, EncodeMs: st.PipelineDelayMs}
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
