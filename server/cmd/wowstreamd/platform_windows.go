//go:build windows

package main

import (
	"fmt"
	"log/slog"

	"golang.org/x/sys/windows"

	"github.com/LcStylee/Wow-mobile/server/internal/capture"
	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/input"
	"github.com/LcStylee/Wow-mobile/server/internal/install"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
	"github.com/LcStylee/Wow-mobile/server/internal/wininput"
)

var (
	user32                            = windows.NewLazySystemDLL("user32.dll")
	procSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	procSetProcessDPIAware            = user32.NewProc("SetProcessDPIAware")
	procIsProcessDPIAware             = user32.NewProc("IsProcessDPIAware")
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
//
// Note that every windows/amd64 build already starts per-monitor-v2 aware:
// the application manifest in rsrc_windows_amd64.syso (which sits in this
// package directory, so plain `go build` picks it up too) declares
// PerMonitorV2, and process DPI awareness is set-once — the runtime setters
// below then fail with ERROR_ACCESS_DENIED ("the default API awareness mode
// ... has already been set ... within the application manifest"). That is
// success, not a problem, so it must not be warned about; the setters are a
// fallback for a build whose .syso was stripped or is missing.
func makeProcessDPIAware(log *slog.Logger) {
	// Per-monitor-v2 (Windows 10 1703+) also keeps mixed-DPI multi-monitor
	// setups consistent. SetProcessDpiAwarenessContext returns nonzero on
	// success; ERROR_ACCESS_DENIED means awareness was already fixed at
	// process creation (the manifest's PerMonitorV2) — aware either way.
	if procSetProcessDpiAwarenessContext.Find() == nil {
		ret, _, callErr := procSetProcessDpiAwarenessContext.Call(dpiAwarenessContextPerMonitorAwareV2)
		if ret != 0 || callErr == windows.ERROR_ACCESS_DENIED {
			return
		}
	}
	// Older Windows: system-DPI awareness still stops virtualization on
	// single-monitor setups (SetProcessDPIAware, user32, Vista+).
	if ret, _, _ := procSetProcessDPIAware.Call(); ret != 0 {
		return
	}
	// Both setters refused. Warn only when the process genuinely ends up
	// DPI-unaware — with the manifest applied (or a pre-1703 Windows where
	// its dpiAware element set awareness) the setters fail even though the
	// process is aware, and IsProcessDPIAware (user32, Vista+; true for
	// system- and per-monitor-aware alike) tells the two cases apart.
	if ret, _, _ := procIsProcessDPIAware.Call(); ret != 0 {
		return
	}
	log.Warn("could not make process DPI-aware; capture rect and input mapping will be wrong on scaled displays")
}

// measureFitResolution measures the primary monitor's work area and window
// decorations (the same install.System calls the wizard uses) and returns the
// largest fitting 9:16 portrait client area — the --resolution fit fallback
// for runs that skipped the wizard. makeProcessDPIAware has not necessarily
// run yet, but the manifest already makes the process per-monitor-v2 aware,
// so the metrics are physical pixels either way.
func measureFitResolution() (w, h, workW, workH int, ok bool) {
	sys := install.NewSystem()
	workW, workH, ok = sys.PrimaryWorkArea()
	if !ok {
		return 0, 0, 0, 0, false
	}
	dw, dh := sys.WindowDecorationExtents()
	w, h, ok = window.FitPortraitClient(workW, workH, dw, dh)
	return w, h, workW, workH, ok
}

// newPlatform locates the WoW window up front (failing fast with guidance if
// the game is not running) and wires the Win32 injector. band selects the
// band-contract input mapping (phone coordinates land in the centered 9:16
// band of a landscape client area — the exact rect the capture crops).
func newPlatform(cfg *config.Config, band bool, log *slog.Logger) (*platform, error) {
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
	// A client-size/--resolution mismatch is NOT warned about here: main's
	// per-launch geometry check (capture.EncodeSize via plat.clientRect) owns
	// that — it adapts the encode to the actual window, updates the hello
	// geometry, and surfaces the mismatch once on the log and the dashboard
	// warning row, staying accurate across mid-run resizes.

	// The ddagrab decision is re-evaluated before every ffmpeg launch (crash
	// recovery, bitrate/keyframe restarts — and the geometry watchdog's
	// relaunch, which notices a moved or resized window within seconds and
	// forces exactly such a restart, so a ddagrab crop never keeps framing
	// stale desktop pixels for long). lastReason makes the closure log only
	// when the decision changes, not on every routine restart; it needs no
	// lock because the closure's sole caller is the video supervisor's run
	// goroutine (keyframe restarts would otherwise spam identical lines).
	lastReason := "\x00never-logged" // sentinel unequal to any real reason
	return &platform{
		newInjector: func() (input.Injector, error) {
			return wininput.New(tracker, band, log), nil
		},
		clientRect: func() (window.Rect, bool) {
			rc, err := tracker.ClientRect()
			if err != nil {
				return window.Rect{}, false
			}
			return rc, true
		},
		captureRect: func(encW, encH int, subRect *capture.Rect) (*capture.Rect, int) {
			crop, idx, reason := ddagrabTarget(tracker, encW, encH, subRect)
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
		bandBasis:         newBandBasisReader(cfg),
		enforceWindowSize: newWindowSizeEnforcer(tracker, log),
	}, nil
}

// newWindowSizeEnforcer wraps Tracker.EnforceClientSize with attempt
// limiting: a resize is (re-)attempted only when the (target, actual window)
// pair changed since the last attempt — so per-ffmpeg-launch calls are free,
// a game that re-asserts its size is fought exactly the once-plus-retry that
// EnforceClientSize itself performs, and a user manually resizing the window
// later re-arms enforcement naturally. Not concurrency-safe by design: the
// sole callers are main's startup path and the video supervisor's argv
// callback, which never run concurrently (Supervisor.Start happens after
// startup completes).
func newWindowSizeEnforcer(tracker *window.Tracker, log *slog.Logger) func(int, int) (string, window.EnforceOutcome, bool) {
	type sig struct{ wantW, wantH, actualW, actualH int }
	var lastAttempt *sig
	return func(wantW, wantH int) (string, window.EnforceOutcome, bool) {
		rc, err := tracker.ClientRect()
		if err != nil {
			return "", window.EnforceAlready, false // no window: the capture path reports that itself
		}
		if window.SizeMatches(rc.W, rc.H, wantW, wantH) {
			lastAttempt = nil // healthy; re-arm for any future drift
			return "", window.EnforceAlready, false
		}
		cur := sig{wantW, wantH, rc.W, rc.H}
		if lastAttempt != nil && *lastAttempt == cur {
			return "", window.EnforceAlready, false // same situation we already tried; don't fight
		}
		lastAttempt = &cur
		res := tracker.EnforceClientSize(wantW, wantH)
		log.Info("direct window resize attempted",
			"want", fmt.Sprintf("%dx%d", wantW, wantH),
			"outcome", res.Outcome.String(), "result", res.Message)
		// Record the post-attempt actual size so a reverting game does not
		// get re-fought on the next launch (its revert changed rc).
		if w, h := res.FinalW, res.FinalH; w > 0 && h > 0 {
			lastAttempt.actualW, lastAttempt.actualH = w, h
		}
		return res.Message, res.Outcome, true
	}
}

// ddagrabTarget decides whether NVENC's zero-copy ddagrab path is usable for
// the window's current geometry against the encW x encH frame the encoder
// will produce (already adapted to the live client rect by capture.EncodeSize
// — or the band crop, delivered here as subRect — in main's argv callback, so
// a mismatched-but-even window still gets the zero-copy path at its own
// size). subRect, when non-nil, is a CLIENT-LOCAL sub-rectangle (band mode's
// centered 9:16 band): ddagrab crops at grab time, so a band matching the
// encode size exactly rides the zero-copy path too — a scaled or odd-width
// band falls back to gdigrab's crop+scale chain. On success it returns the
// crop rect in the containing DXGI output's local coordinate space plus that
// output's ddagrab output_idx and an empty reason; otherwise a human-readable
// reason for taking the gdigrab fallback (crop is then nil).
//
// All the crop-coordinate arithmetic lives in the pure, portably unit-tested
// halves (ddagrabrect.go): ddagrabScreenRect folds the band into the
// client's screen rect and enforces the no-scaler size invariant;
// outputLocalRect translates into the captured output's local space. This
// function only contributes the live measurements: the client rect and the
// monitor output actually containing it — any monitor of the default
// adapter, primary or not (window.LocateOutput).
func ddagrabTarget(tracker *window.Tracker, encW, encH int, subRect *capture.Rect) (crop *capture.Rect, outputIdx int, reason string) {
	rc, err := tracker.ClientRect()
	if err != nil {
		return nil, 0, "window geometry unavailable: " + err.Error()
	}
	eff, reason := ddagrabScreenRect(rc, encW, encH, subRect)
	if reason != "" {
		return nil, 0, reason
	}
	idx, desktop, err := window.LocateOutput(eff)
	if err != nil {
		return nil, 0, err.Error()
	}
	return outputLocalRect(eff, desktop), idx, ""
}
