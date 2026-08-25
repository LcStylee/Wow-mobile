//go:build windows

package main

import (
	"fmt"
	"log/slog"

	"golang.org/x/sys/windows"

	"github.com/LcStylee/Wow-mobile/server/internal/capture"
	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/input"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
	"github.com/LcStylee/Wow-mobile/server/internal/wininput"
)

var (
	user32                            = windows.NewLazySystemDLL("user32.dll")
	procSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	procSetProcessDPIAware            = user32.NewProc("SetProcessDPIAware")
)

// dpiAwarenessContextPerMonitorAwareV2 is the pseudo-handle
// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 ((DPI_AWARENESS_CONTEXT)-4,
// hidpi.h): -4 reinterpreted as a pointer-sized value.
const dpiAwarenessContextPerMonitorAwareV2 = ^uintptr(3)

// makeProcessDPIAware opts the process out of DPI virtualization. Without it,
// on any display scaled above 100% (the default on most laptops/4K panels),
// GetClientRect/ClientToScreen/GetSystemMetrics return virtualized
// coordinates while ffmpeg's ddagrab crop operates in physical desktop
// pixels — the capture rect, the resolution-mismatch check, and the SendInput
// virtual-screen normalization would all be wrong. Must run before the first
// window/metrics query.
func makeProcessDPIAware(log *slog.Logger) {
	// Per-monitor-v2 (Windows 10 1703+) also keeps mixed-DPI multi-monitor
	// setups consistent. SetProcessDpiAwarenessContext returns nonzero on
	// success.
	if procSetProcessDpiAwarenessContext.Find() == nil {
		if ret, _, _ := procSetProcessDpiAwarenessContext.Call(dpiAwarenessContextPerMonitorAwareV2); ret != 0 {
			return
		}
	}
	// Older Windows: system-DPI awareness still stops virtualization on
	// single-monitor setups (SetProcessDPIAware, user32, Vista+).
	if ret, _, callErr := procSetProcessDPIAware.Call(); ret == 0 {
		log.Warn("could not make process DPI-aware; capture rect and input mapping will be wrong on scaled displays", "err", callErr)
	}
}

// newPlatform locates the WoW window up front (failing fast with guidance if
// the game is not running) and wires the Win32 injector.
func newPlatform(cfg *config.Config, log *slog.Logger) (*platform, error) {
	makeProcessDPIAware(log) // before any window geometry is read

	tracker, err := window.NewTracker(cfg.WindowTitle)
	if err != nil {
		return nil, err
	}
	rc, err := tracker.ClientRect()
	if err != nil {
		return nil, fmt.Errorf("reading game window geometry: %w", err)
	}
	log.Info("found game window", "client_rect", fmt.Sprintf("%dx%d at (%d,%d)", rc.W, rc.H, rc.X, rc.Y))
	if rc.W != cfg.Width || rc.H != cfg.Height {
		// Accurate for every capture path: a size mismatch always lands on a
		// gdigrab pipeline whose scale filter resizes to --resolution —
		// ddagrabTarget refuses mismatched geometry precisely because the
		// ddagrab graph has no scaler and would mis-crop instead of scaling.
		log.Warn("game window client size differs from --resolution; the stream will be scaled via gdigrab (NVENC's zero-copy ddagrab path needs an exact match) and touch precision may suffer — fix Config.wtf (see --setup)",
			"window", fmt.Sprintf("%dx%d", rc.W, rc.H),
			"resolution", fmt.Sprintf("%dx%d", cfg.Width, cfg.Height))
	}

	// The ddagrab decision is re-evaluated before every ffmpeg launch (crash
	// recovery, bitrate/keyframe restarts), so a moved or resized window is
	// re-cropped on the next restart; only a move during one process's
	// lifetime shifts the crop until then — a non-issue for the intended
	// borderless fixed-position window. lastReason makes the closure log only
	// when the decision changes, not on every routine restart; it needs no
	// lock because the closure's sole caller is the video supervisor's run
	// goroutine (keyframe restarts would otherwise spam identical lines).
	lastReason := "\x00never-logged" // sentinel unequal to any real reason
	return &platform{
		newInjector: func() (input.Injector, error) {
			return wininput.New(tracker, log), nil
		},
		captureRect: func() (*capture.Rect, int) {
			crop, idx, reason := ddagrabTarget(tracker, cfg)
			if reason != lastReason {
				lastReason = reason
				if reason == "" {
					log.Info("zero-copy ddagrab capture enabled", "output_idx", idx,
						"crop", fmt.Sprintf("%dx%d at output-local (%d,%d)", crop.W, crop.H, crop.X, crop.Y))
				} else {
					log.Info("ddagrab unavailable, capturing via gdigrab", "reason", reason)
				}
			}
			return crop, idx
		},
		windowTitle: func() string {
			// gdigrab needs the exact full title (FindWindow semantics);
			// resolve it from the tracked window. Fall back to the flag value
			// if the window vanished — ffmpeg then fails and the supervisor
			// retries, which is the best available behavior with no window.
			if title, err := tracker.Title(); err == nil {
				return title
			}
			return cfg.WindowTitle
		},
	}, nil
}

// ddagrabTarget decides whether NVENC's zero-copy ddagrab path is usable for
// the window's current geometry. On success it returns the crop rect in the
// containing DXGI output's local coordinate space plus that output's ddagrab
// output_idx and an empty reason; otherwise a human-readable reason for
// taking the gdigrab fallback (crop is then nil).
func ddagrabTarget(tracker *window.Tracker, cfg *config.Config) (crop *capture.Rect, outputIdx int, reason string) {
	rc, err := tracker.ClientRect()
	if err != nil {
		return nil, 0, "window geometry unavailable: " + err.Error()
	}
	// The ddagrab filter graph has no scaler — the crop IS the encoded frame
	// (capture.Config.CaptureRect invariant) — so a client area that differs
	// from --resolution must go through gdigrab, whose scale filter resizes
	// to the advertised geometry. Cropping cfg.Width x cfg.Height here
	// instead would frame desktop pixels around a smaller window, cut a
	// larger one, or run past the monitor edge and fail outright.
	if rc.W != cfg.Width || rc.H != cfg.Height {
		return nil, 0, fmt.Sprintf("window client area %dx%d differs from --resolution %dx%d",
			rc.W, rc.H, cfg.Width, cfg.Height)
	}
	// Resolve the monitor output actually containing the window — on any
	// monitor of the default adapter, primary or not — and translate to its
	// local space: ddagrab's offset_x/offset_y are relative to the captured
	// output's top-left corner, not to the virtual desktop.
	idx, desktop, err := window.LocateOutput(rc)
	if err != nil {
		return nil, 0, err.Error()
	}
	return &capture.Rect{X: rc.X - desktop.X, Y: rc.Y - desktop.Y, W: rc.W, H: rc.H}, idx, ""
}
