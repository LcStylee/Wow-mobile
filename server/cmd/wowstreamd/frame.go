// Frame resolution for the phone-frame layout (docs/PHONE_FRAME.md §5): the
// crop the stream uses and the rect touch input maps onto come from ONE
// object, so the two can never disagree.
//
// Source ladder, per decision:
//  1. the addon's red outline, read off the live window (probe);
//  2. the last detected outline, while the client size is unchanged — a
//     loading screen, a cinematic or an occluding window hides the outline
//     for a moment and must not make the stream jump;
//  3. the phone picked on the dashboard (or --phone, or the remembered
//     choice), placed by the contract math;
//  4. phones.DefaultID.
package main

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"sync"

	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/install"
	"github.com/LcStylee/Wow-mobile/server/internal/phones"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// frameDecision is one resolved frame plus where it came from.
type frameDecision struct {
	frame  window.BandFrame
	source window.FrameSource
	phone  phones.Phone // the phone used when source is dashboard/default
}

type frameResolver struct {
	// probe reads the outline off the live window, client-local; nil when the
	// platform cannot (capture test, non-Windows).
	probe func() (window.Rect, bool)
	// persist stores a dashboard phone choice (nil = don't).
	persist func(id string)

	mu       sync.Mutex
	phone    phones.Phone
	explicit bool // phone came from --phone / the dashboard / the store
	// last detected outline and the client size it was seen at
	last         window.Rect
	lastW, lastH int
	haveLast     bool
	current      window.Rect // crop of the most recent decision (client-local)
	curW, curH   int
	haveCurrent  bool
	pendingDrift string // debounce: drift signature seen on the previous tick
}

func newFrameResolver(phoneID string, probe func() (window.Rect, bool), persist func(string)) *frameResolver {
	fr := &frameResolver{probe: probe, persist: persist, phone: phones.Default()}
	if p, ok := phones.ByID(phoneID); ok {
		fr.phone, fr.explicit = p, true
	}
	return fr
}

// Phone returns the dashboard phone.
func (fr *frameResolver) Phone() phones.Phone {
	fr.mu.Lock()
	defer fr.mu.Unlock()
	return fr.phone
}

// SetPhone changes the dashboard phone (validated id), persisting it.
func (fr *frameResolver) SetPhone(id string) error {
	p, ok := phones.ByID(id)
	if !ok {
		return fmt.Errorf("unknown phone %q", id)
	}
	fr.mu.Lock()
	fr.phone, fr.explicit = p, true
	fr.mu.Unlock()
	if fr.persist != nil {
		fr.persist(id)
	}
	return nil
}

// decide runs the ladder for a client size without touching the cached
// "current" crop. probeOK/probed carry an already-taken probe result.
func (fr *frameResolver) decideLocked(clientW, clientH int, probed window.Rect, probeOK bool) (frameDecision, bool) {
	if probeOK && probed.X >= 0 && probed.Y >= 0 && probed.X+probed.W <= clientW && probed.Y+probed.H <= clientH {
		if f, ok := window.FrameForCrop(probed); ok {
			fr.last, fr.lastW, fr.lastH, fr.haveLast = probed, clientW, clientH, true
			return frameDecision{frame: f, source: window.SourceOutline}, true
		}
	}
	if fr.haveLast && fr.lastW == clientW && fr.lastH == clientH {
		if f, ok := window.FrameForCrop(fr.last); ok {
			return frameDecision{frame: f, source: window.SourceLast}, true
		}
	}
	src := window.SourceDashboard
	if !fr.explicit {
		src = window.SourceDefault
	}
	f, ok := window.ComputePhoneFrame(clientW, clientH, fr.phone.StreamW, fr.phone.StreamH)
	if !ok {
		return frameDecision{}, false
	}
	return frameDecision{frame: f, source: src, phone: fr.phone}, true
}

func (fr *frameResolver) runProbe() (window.Rect, bool) {
	if fr.probe == nil {
		return window.Rect{}, false
	}
	return fr.probe()
}

// Resolve decides the frame for one capture launch and records it as the
// current crop (the one input maps onto).
func (fr *frameResolver) Resolve(clientW, clientH int) (frameDecision, bool) {
	r, ok := fr.runProbe()
	fr.mu.Lock()
	defer fr.mu.Unlock()
	d, dok := fr.decideLocked(clientW, clientH, r, ok)
	if dok {
		fr.current, fr.curW, fr.curH, fr.haveCurrent = d.frame.Band, clientW, clientH, true
		fr.pendingDrift = ""
	}
	return d, dok
}

// Crop is the wininput.CropFunc: the running capture's crop when the client
// size matches it, else a fresh probe-free decision (the watchdog relaunches
// the capture onto the same rect within seconds).
func (fr *frameResolver) Crop(clientW, clientH int) (window.Rect, bool) {
	fr.mu.Lock()
	defer fr.mu.Unlock()
	if fr.haveCurrent && fr.curW == clientW && fr.curH == clientH {
		return fr.current, true
	}
	d, ok := fr.decideLocked(clientW, clientH, window.Rect{}, false)
	return d.frame.Band, ok
}

// Drift is polled by the geometry watchdog (~1 Hz while streaming): it
// re-probes and reports a relaunch reason once the decision for the SAME
// client size has differed from the running crop on two consecutive polls
// (the user picked another phone in-game or on the dashboard). Client-size
// changes are the watchdog's own rect check.
func (fr *frameResolver) Drift(clientW, clientH int) (string, bool) {
	r, ok := fr.runProbe()
	fr.mu.Lock()
	defer fr.mu.Unlock()
	if !fr.haveCurrent || fr.curW != clientW || fr.curH != clientH {
		fr.pendingDrift = ""
		return "", false
	}
	d, dok := fr.decideLocked(clientW, clientH, r, ok)
	if !dok || d.frame.Band == fr.current {
		fr.pendingDrift = ""
		return "", false
	}
	sig := fmt.Sprintf("%v/%s", d.frame.Band, d.source)
	if fr.pendingDrift != sig {
		fr.pendingDrift = sig
		return "", false
	}
	fr.pendingDrift = ""
	return fmt.Sprintf("phone frame changed (%s): %dx%d at (%d,%d) -> %dx%d at (%d,%d)", d.source,
		fr.current.W, fr.current.H, fr.current.X, fr.current.Y,
		d.frame.Band.W, d.frame.Band.H, d.frame.Band.X, d.frame.Band.Y), true
}

// frameDriftFunc adapts the resolver to the geometry watchdog (nil outside
// frame layout).
func frameDriftFunc(frameMode bool, fr *frameResolver) func(int, int) (string, bool) {
	if !frameMode {
		return nil
	}
	return fr.Drift
}

// initialPhone picks the dashboard's starting phone: --phone, else the
// remembered dashboard choice (Windows store), else "" (phones.Default).
func initialPhone(cfg *config.Config) string {
	if cfg.Phone != "" {
		return cfg.Phone
	}
	if runtime.GOOS != "windows" || cfg.Capture == config.CaptureTest {
		return ""
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return install.LoadStore(filepath.Join(dir, "wowstreamd")).Get(install.KeyPhone)
}

// persistPhone remembers a dashboard phone choice for the next run
// (Windows only, like the rest of the store; best-effort).
func persistPhone(log *slog.Logger) func(string) {
	return func(id string) {
		if runtime.GOOS != "windows" {
			return
		}
		dir, err := os.UserConfigDir()
		if err != nil {
			return
		}
		store := install.LoadStore(filepath.Join(dir, "wowstreamd"))
		store.Set(install.KeyPhone, id)
		if err := store.Save(); err != nil {
			log.Warn("could not remember the dashboard phone", "err", err)
		}
	}
}
