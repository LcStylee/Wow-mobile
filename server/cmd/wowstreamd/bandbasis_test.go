package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/install"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// fakeUserConfig points os.UserConfigDir at a temp dir (via the XDG/APPDATA
// env var the current OS honors) and optionally writes a wowstreamd store
// remembering gameExe there.
func fakeUserConfig(t *testing.T, gameExe string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir) // Unix os.UserConfigDir
	t.Setenv("AppData", dir)         // Windows os.UserConfigDir
	if gameExe == "" {
		return
	}
	store := install.LoadStore(filepath.Join(dir, "wowstreamd"))
	store.Set(install.KeyGameExe, gameExe)
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}
}

func TestLocateConfigWTF(t *testing.T) {
	t.Run("game-exe flag wins", func(t *testing.T) {
		fakeUserConfig(t, filepath.Join(t.TempDir(), "elsewhere", "WoW.exe"))
		exe := filepath.Join("some", "dir", "WoW.exe")
		want := filepath.Join("some", "dir", "WTF", "Config.wtf")
		if got := locateConfigWTF(&config.Config{GameExe: exe}); got != want {
			t.Fatalf("got %q, want %q", got, want)
		}
	})
	t.Run("remembered store exe", func(t *testing.T) {
		exe := filepath.Join(t.TempDir(), "TurtleWoW", "WoW.exe")
		fakeUserConfig(t, exe)
		want := install.ConfigWTFPath(exe)
		if got := locateConfigWTF(&config.Config{}); got != want {
			t.Fatalf("got %q, want %q", got, want)
		}
	})
	t.Run("wow-dir distrusts an unrelated store exe and probes the dir", func(t *testing.T) {
		fakeUserConfig(t, filepath.Join(t.TempDir(), "other", "WoW.exe"))
		wowDir := t.TempDir()
		cfgPath := filepath.Join(wowDir, "WTF", "Config.wtf")
		if err := os.MkdirAll(filepath.Dir(cfgPath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(cfgPath, []byte("SET gxWindow \"1\"\r\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := locateConfigWTF(&config.Config{WowDir: wowDir}); got != cfgPath {
			t.Fatalf("got %q, want %q", got, cfgPath)
		}
	})
	t.Run("nothing locatable", func(t *testing.T) {
		fakeUserConfig(t, "")
		if got := locateConfigWTF(&config.Config{}); got != "" {
			t.Fatalf("got %q, want empty", got)
		}
	})
}

func TestNewBandBasisReader(t *testing.T) {
	fakeUserConfig(t, "")
	gameDir := t.TempDir()
	exe := filepath.Join(gameDir, "WoW.exe")
	cfgPath := filepath.Join(gameDir, "WTF", "Config.wtf")
	if err := os.MkdirAll(filepath.Dir(cfgPath), 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(content string) {
		t.Helper()
		if err := os.WriteFile(cfgPath, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("SET gxWindow \"1\"\r\nSET gxResolution \"3840x2160\"\r\n")

	read := newBandBasisReader(&config.Config{GameExe: exe})
	if w, h, ok := read(); !ok || w != 3840 || h != 2160 {
		t.Fatalf("read() = %d, %d, %v; want 3840, 2160, true", w, h, ok)
	}
	// WoW rewrites Config.wtf on exit: a changed value must be seen on the
	// next capture launch (the file is re-read per call, only the path is
	// cached).
	write("SET gxResolution \"1920x1080\"\r\n")
	if w, h, ok := read(); !ok || w != 1920 || h != 1080 {
		t.Fatalf("after rewrite: read() = %d, %d, %v; want 1920, 1080, true", w, h, ok)
	}
	// No gxResolution at all: not locatable as a basis.
	write("SET gxWindow \"1\"\r\n")
	if _, _, ok := read(); ok {
		t.Fatal("read() ok for a Config.wtf without gxResolution")
	}
}

// A brand-new install: --wow-dir points at a game dir whose WTF\Config.wtf
// does not exist yet at the first capture launch (the wizard runs later,
// mid-session). The reader must keep re-locating while unresolved — only a
// FOUND path is cached — so the basis check comes alive as soon as the file
// appears, without a process restart.
func TestNewBandBasisReaderResolvesLateConfigWTF(t *testing.T) {
	fakeUserConfig(t, "")
	wowDir := t.TempDir()
	read := newBandBasisReader(&config.Config{WowDir: wowDir})
	if _, _, ok := read(); ok {
		t.Fatal("read() ok before Config.wtf exists")
	}
	cfgPath := filepath.Join(wowDir, "WTF", "Config.wtf")
	if err := os.MkdirAll(filepath.Dir(cfgPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfgPath, []byte("SET gxResolution \"3840x2160\"\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if w, h, ok := read(); !ok || w != 3840 || h != 2160 {
		t.Fatalf("after Config.wtf appears: read() = %d, %d, %v; want 3840, 2160, true", w, h, ok)
	}
}

// basisSink records every reporter side effect for the assertions below.
type basisSink struct {
	warningRow []string // status.SetWarning calls, in order
	warns      []string // warn-log lines
	infos      []string // info-log lines
}

func (s *basisSink) reporter(basis func() (int, int, bool)) func(int, int, window.BandFrame) {
	return newBandBasisReporter(basis,
		func(msg string) { s.warningRow = append(s.warningRow, msg) },
		func(msg string) { s.warns = append(s.warns, msg) },
		func(msg string) { s.infos = append(s.infos, msg) })
}

func fixedBasis(w, h int) func() (int, int, bool) {
	return func() (int, int, bool) { return w, h, true }
}

func bandFrame(t *testing.T, w, h int) window.BandFrame {
	t.Helper()
	f, ok := window.ComputeBandFrame(w, h)
	if !ok {
		t.Fatalf("ComputeBandFrame(%d, %d) not ok", w, h)
	}
	return f
}

// The reporter around window.BandBasisCheck: dedup, severity routing, and
// clearing — the glue run() installs for every band-layout capture launch.
func TestBandBasisReporter(t *testing.T) {
	t.Run("nil basis reader is inert", func(t *testing.T) {
		s := &basisSink{}
		report := s.reporter(nil)
		report(3840, 2160, bandFrame(t, 3840, 2160))
		if len(s.warningRow)+len(s.warns)+len(s.infos) != 0 {
			t.Fatalf("nil-basis reporter acted: %+v", s)
		}
	})
	t.Run("repeated identical warning logs once and clears on reconcile", func(t *testing.T) {
		// 3855x2160 passes the addon's 0.4% aspect gate against 3840x2160 but
		// shifts the fraction-mapped band past the pixel tolerance: a genuine
		// warning (see window.TestBandBasisCheck).
		s := &basisSink{}
		basis := fixedBasis(3855, 2160)
		report := s.reporter(func() (int, int, bool) { return basis() })
		live := bandFrame(t, 3840, 2160)
		report(3840, 2160, live)
		report(3840, 2160, live) // unchanged state: once per change, not per launch
		if len(s.warns) != 1 || len(s.warningRow) != 1 || s.warningRow[0] != s.warns[0] {
			t.Fatalf("want one warning on the row and the log, got %+v", s)
		}
		if len(s.infos) != 0 {
			t.Fatalf("a genuine warning must not also log a note: %+v", s.infos)
		}
		// Reconciliation (WoW restarted, CVar now matches the window): the
		// row clears, nothing is logged.
		basis = fixedBasis(3840, 2160)
		report(3840, 2160, live)
		if len(s.warningRow) != 2 || s.warningRow[1] != "" || len(s.warns) != 1 {
			t.Fatalf("reconcile must clear the warning row silently: %+v", s)
		}
	})
	t.Run("non-band frame clears a standing warning", func(t *testing.T) {
		s := &basisSink{}
		report := s.reporter(fixedBasis(3855, 2160))
		report(3840, 2160, bandFrame(t, 3840, 2160))
		// The window went portrait: full-window mode, no basis to compare —
		// the standing warning must clear.
		report(1080, 1920, bandFrame(t, 1080, 1920))
		if n := len(s.warningRow); n != 2 || s.warningRow[n-1] != "" {
			t.Fatalf("portrait live must clear the warning row: %+v", s.warningRow)
		}
	})
	t.Run("stale-aspect basis is an info note, never the warning row", func(t *testing.T) {
		// The primary field configuration: desktop-sized CVar, window
		// maximized above the taskbar. An up-to-date addon compensates, so
		// the user must NOT see a red warning on a pixel-perfect stream.
		s := &basisSink{}
		report := s.reporter(fixedBasis(3840, 2160))
		live := bandFrame(t, 3840, 2069)
		report(3840, 2069, live)
		report(3840, 2069, live) // dedup applies to notes too
		if len(s.infos) != 1 || len(s.warns) != 0 {
			t.Fatalf("want exactly one info note and no warnings, got %+v", s)
		}
		for _, row := range s.warningRow {
			if row != "" {
				t.Fatalf("a stale-CVar note occupied the warning row: %q", row)
			}
		}
	})
	t.Run("unreadable basis clears", func(t *testing.T) {
		s := &basisSink{}
		readable := true
		report := s.reporter(func() (int, int, bool) { return 3855, 2160, readable })
		live := bandFrame(t, 3840, 2160)
		report(3840, 2160, live)
		readable = false // Config.wtf deleted / unreadable mid-session
		report(3840, 2160, live)
		if n := len(s.warningRow); n != 2 || s.warningRow[n-1] != "" {
			t.Fatalf("unreadable basis must clear the warning row: %+v", s.warningRow)
		}
	})
}

// targetInstallDir mirrors locateConfigWTF's source-of-truth ladder (flag,
// trusted store, bare --wow-dir) but feeds the window tracker; this pins the
// two against silent divergence (e.g. dropping the store-trust guard would
// re-bind capture and input to a stale install).
func TestTargetInstallDir(t *testing.T) {
	t.Run("game-exe flag wins", func(t *testing.T) {
		fakeUserConfig(t, filepath.Join(t.TempDir(), "elsewhere", "WoW.exe"))
		exe := filepath.Join("some", "dir", "WoW.exe")
		want := window.CanonDir(filepath.Join("some", "dir"))
		if got := targetInstallDir(&config.Config{GameExe: exe}); got != want {
			t.Fatalf("got %q, want %q", got, want)
		}
	})
	t.Run("remembered store exe", func(t *testing.T) {
		exe := filepath.Join(t.TempDir(), "TurtleWoW", "WoW.exe")
		fakeUserConfig(t, exe)
		want := window.CanonDir(filepath.Dir(exe))
		if got := targetInstallDir(&config.Config{}); got != want {
			t.Fatalf("got %q, want %q", got, want)
		}
	})
	t.Run("wow-dir distrusts an unrelated store exe", func(t *testing.T) {
		fakeUserConfig(t, filepath.Join(t.TempDir(), "other", "WoW.exe"))
		wowDir := t.TempDir()
		want := window.CanonDir(wowDir)
		if got := targetInstallDir(&config.Config{WowDir: wowDir}); got != want {
			t.Fatalf("got %q, want %q", got, want)
		}
	})
	t.Run("missing wow-dir yields no binding", func(t *testing.T) {
		fakeUserConfig(t, "")
		gone := filepath.Join(t.TempDir(), "never-created")
		if got := targetInstallDir(&config.Config{WowDir: gone}); got != "" {
			t.Fatalf("got %q, want empty", got)
		}
	})
	t.Run("nothing configured yields no binding", func(t *testing.T) {
		fakeUserConfig(t, "")
		if got := targetInstallDir(&config.Config{}); got != "" {
			t.Fatalf("got %q, want empty", got)
		}
	})
}
