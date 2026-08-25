// Command wowstreamd is the WoW Mobile streaming host: it captures the WoW
// Classic window with ffmpeg, streams it over WebRTC to the phone client, and
// injects the phone's touch input back into the game. See docs/ARCHITECTURE.md
// and protocol/PROTOCOL.md for the binding contracts.
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

	"github.com/LcStylee/Wow-mobile/server/internal/capture"
	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/input"
	"github.com/LcStylee/Wow-mobile/server/internal/rtc"
	sig "github.com/LcStylee/Wow-mobile/server/internal/signal"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

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
	if err := run(); err != nil {
		if !errors.Is(err, flag.ErrHelp) {
			fmt.Fprintln(os.Stderr, "wowstreamd:", err)
		}
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Parse(os.Args[1:], os.Stderr)
	if err != nil {
		return err
	}
	if cfg.Setup {
		window.PrintSetup(os.Stdout, cfg.Width, cfg.Height)
		return nil
	}

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

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

	server := sig.New(cfg.Addr, cfg.Token, cfg.NoTLS, cfg.ClientDir, mgr, log)
	// Bind before the banner: a port-in-use failure must surface as the error,
	// never after a full "ready" message.
	if err := server.Listen(); err != nil {
		return err
	}
	server.PrintBanner(os.Stdout, cfg.Token, cfg.TokenIsGenerated)

	// Ctrl+C / SIGTERM: release inputs, close the peer, kill ffmpeg — in
	// that order, so a mid-fight disconnect never leaves keys held.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	defer func() {
		mgr.Shutdown()
		videoSup.Stop()
		if audioSup != nil {
			audioSup.Stop()
		}
	}()
	return server.Serve(ctx)
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
