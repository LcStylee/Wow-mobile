// Test-pattern capture mode (--capture test): a first-class, portable mode
// that streams ffmpeg's testsrc2 synthetic pattern through the IDENTICAL
// encoder flags, Annex-B parser, and WebRTC sample path as production. It is
// how the video delivery pipeline is verified end to end (the e2e suite drives
// it headlessly) on any OS, without a game, a GPU, or SendInput.
package main

import (
	"log/slog"

	"github.com/LcStylee/Wow-mobile/server/internal/capture"
	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/input"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
	"github.com/LcStylee/Wow-mobile/server/internal/wininput"
)

// newTestPlatform is the --capture test stand-in for the Windows window/input
// platform: the "window" client area is exactly the configured resolution
// (there is no real window; under band layout main then crops the centered
// 9:16 band out of the synthetic frame, exactly like production), the ddagrab
// path is disabled (lavfi feeds the encoder directly), and injected input is
// logged instead of synthesized — including the WINDOW coordinates the real
// injector would target, computed through the same portable band mapping
// (wininput.TargetRect/MapNormalized), so a test client (or the e2e harness)
// can verify the full input path, band offset included, by watching the
// server log.
func newTestPlatform(cfg *config.Config, band bool, log *slog.Logger) *platform {
	target := wininput.TargetRect(window.Rect{W: cfg.Width, H: cfg.Height}, band)
	return &platform{
		newInjector: func() (input.Injector, error) {
			return &logInjector{
				log:    log.With("component", "test-injector"),
				target: target,
			}, nil
		},
		clientRect:  func() (window.Rect, bool) { return window.Rect{W: cfg.Width, H: cfg.Height}, true },
		captureRect: func(int, int, *capture.Rect) (*capture.Rect, int) { return nil, 0 },
		windowTitle: func() string { return "testsrc2" },
	}
}

// logInjector implements input.Injector by logging each event — the honest
// terminal for injected input on a machine with no game window. Every pointer
// line carries both the normalized protocol coordinates and the mapped window
// coordinates (winX/winY, band offset applied under band layout). The e2e
// harness asserts on these lines to prove the input path end to end.
type logInjector struct {
	log    *slog.Logger
	target window.Rect // the rect normalized coordinates map onto
}

func (l *logInjector) PointerMove(x, y uint16) error {
	px, py := wininput.MapNormalized(x, y, l.target)
	l.log.Info("input: pointer move", "x", x, "y", y, "winX", px, "winY", py)
	return nil
}

func (l *logInjector) PointerButton(btn input.Button, down bool, x, y uint16) error {
	px, py := wininput.MapNormalized(x, y, l.target)
	l.log.Info("input: pointer button", "button", int(btn), "down", down, "x", x, "y", y, "winX", px, "winY", py)
	return nil
}

func (l *logInjector) Wheel(x, y uint16, delta int16) error {
	px, py := wininput.MapNormalized(x, y, l.target)
	l.log.Info("input: wheel", "x", x, "y", y, "delta", delta, "winX", px, "winY", py)
	return nil
}

func (l *logInjector) Key(vk uint16, down bool) error {
	l.log.Info("input: key", "vk", vk, "down", down)
	return nil
}
