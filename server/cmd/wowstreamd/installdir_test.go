package main

import (
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

// targetInstallDir resolves the install the window tracker binds to (flag,
// trusted store, bare --wow-dir); this pins the ladder against silent drift (e.g. dropping the store-trust guard would
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
