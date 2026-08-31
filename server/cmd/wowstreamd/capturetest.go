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
)

// newTestPlatform is the --capture test stand-in for the Windows window/input
// platform: geometry is exactly the configured resolution (there is no window
// to self-heal to), the ddagrab path is disabled (lavfi feeds the encoder
// directly), and injected input is logged instead of synthesized — so a test
// client (or the e2e harness) can verify the full input path by watching the
// server log.
func newTestPlatform(cfg *config.Config, log *slog.Logger) *platform {
	return &platform{
		newInjector: func() (input.Injector, error) {
			return &logInjector{log: log.With("component", "test-injector")}, nil
		},
		clientSize:  func() (int, int, bool) { return cfg.Width, cfg.Height, true },
		captureRect: func(int, int) (*capture.Rect, int) { return nil, 0 },
		windowTitle: func() string { return "testsrc2" },
	}
}

// logInjector implements input.Injector by logging each event — the honest
// terminal for injected input on a machine with no game window. The e2e
// harness asserts on these lines to prove the input path end to end.
type logInjector struct {
	log *slog.Logger
}

func (l *logInjector) PointerMove(x, y uint16) error {
	l.log.Info("input: pointer move", "x", x, "y", y)
	return nil
}

func (l *logInjector) PointerButton(btn input.Button, down bool, x, y uint16) error {
	l.log.Info("input: pointer button", "button", int(btn), "down", down, "x", x, "y", y)
	return nil
}

func (l *logInjector) Wheel(x, y uint16, delta int16) error {
	l.log.Info("input: wheel", "x", x, "y", y, "delta", delta)
	return nil
}

func (l *logInjector) Key(vk uint16, down bool) error {
	l.log.Info("input: key", "vk", vk, "down", down)
	return nil
}
