package install

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var want1080 = PortraitSettings(1080, 1920)

func TestEnsureSettingsPreservesUnrelatedLinesAndOrder(t *testing.T) {
	in := "SET hwDetect \"0\"\nSET gxWindow \"0\"\nSET textLocale \"enUS\"\nSET gxMaximize \"1\"\n"
	out, changed := EnsureSettings([]byte(in), want1080)
	if !changed {
		t.Fatal("expected changes")
	}
	got := string(out)
	wantOut := "SET hwDetect \"0\"\nSET gxWindow \"1\"\nSET textLocale \"enUS\"\nSET gxMaximize \"0\"\nSET gxWindowedResolution \"1080x1920\"\nSET checkAddonVersion \"0\"\n"
	if got != wantOut {
		t.Fatalf("minimal edit violated:\n got: %q\nwant: %q", got, wantOut)
	}
}

func TestEnsureSettingsCRLFPreserved(t *testing.T) {
	in := "SET hwDetect \"0\"\r\nSET gxWindow \"0\"\r\n"
	out, changed := EnsureSettings([]byte(in), want1080)
	if !changed {
		t.Fatal("expected changes")
	}
	got := string(out)
	if strings.Contains(strings.ReplaceAll(got, "\r\n", ""), "\n") {
		t.Fatalf("mixed line endings introduced: %q", got)
	}
	wantOut := "SET hwDetect \"0\"\r\nSET gxWindow \"1\"\r\nSET gxMaximize \"0\"\r\nSET gxWindowedResolution \"1080x1920\"\r\nSET checkAddonVersion \"0\"\r\n"
	if got != wantOut {
		t.Fatalf("CRLF edit wrong:\n got: %q\nwant: %q", got, wantOut)
	}
}

func TestEnsureSettingsNoTrailingNewlineAppend(t *testing.T) {
	in := "SET textLocale \"enUS\"" // no trailing newline
	out, _ := EnsureSettings([]byte(in), want1080)
	got := string(out)
	if !strings.HasPrefix(got, "SET textLocale \"enUS\"\nSET gxWindow") {
		t.Fatalf("append after missing trailing newline broken: %q", got)
	}
	if !strings.HasSuffix(got, "SET gxWindowedResolution \"1080x1920\"\nSET checkAddonVersion \"0\"\n") {
		t.Fatalf("appended block wrong: %q", got)
	}
}

func TestEnsureSettingsIdempotent(t *testing.T) {
	out, changed := EnsureSettings(FreshConfig(want1080), want1080)
	if changed {
		t.Fatalf("fresh config re-reported as changed: %q", out)
	}
	if !SettingsSatisfied(out, want1080) {
		t.Fatal("SettingsSatisfied disagrees with EnsureSettings")
	}
}

func TestFreshConfigIsCRLFOnlyWantedLines(t *testing.T) {
	got := string(FreshConfig(want1080))
	wantOut := "SET gxWindow \"1\"\r\nSET gxMaximize \"0\"\r\nSET gxWindowedResolution \"1080x1920\"\r\nSET checkAddonVersion \"0\"\r\n"
	if got != wantOut {
		t.Fatalf("fresh config:\n got: %q\nwant: %q", got, wantOut)
	}
}

// The edit path is atomic (same-directory temp file renamed over Config.wtf)
// and cleans up after itself: nothing but the file and its backup remain.
func TestApplyConfigWTFLeavesNoTempFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "Config.wtf")
	if err := os.WriteFile(path, []byte("SET gxWindow \"0\"\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if changed, err := ApplyConfigWTF(path, want1080); err != nil || !changed {
		t.Fatalf("ApplyConfigWTF: changed=%v err=%v", changed, err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if name := e.Name(); name != "Config.wtf" && name != "Config.wtf"+BackupSuffix {
			t.Errorf("unexpected leftover file: %s", name)
		}
	}
}

func TestApplyConfigWTFWritesBackupOnlyWhenChanging(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "Config.wtf")
	orig := []byte("SET gxWindow \"0\"\r\nSET realmName \"Whitemane\"\r\n")
	if err := os.WriteFile(path, orig, 0o644); err != nil {
		t.Fatal(err)
	}

	changed, err := ApplyConfigWTF(path, want1080)
	if err != nil || !changed {
		t.Fatalf("ApplyConfigWTF: changed=%v err=%v", changed, err)
	}
	backup, err := os.ReadFile(path + BackupSuffix)
	if err != nil {
		t.Fatalf("backup missing: %v", err)
	}
	if !bytes.Equal(backup, orig) {
		t.Fatalf("backup is not the original bytes: %q", backup)
	}
	now, _ := os.ReadFile(path)
	if !SettingsSatisfied(now, want1080) || !bytes.Contains(now, []byte("realmName")) {
		t.Fatalf("edited file wrong: %q", now)
	}

	// Second run: already satisfied — no rewrite, and the backup must keep
	// the pre-edit original (never overwritten with current content).
	if err := os.WriteFile(path+BackupSuffix, orig, 0o644); err != nil {
		t.Fatal(err)
	}
	changed, err = ApplyConfigWTF(path, want1080)
	if err != nil || changed {
		t.Fatalf("idempotent rerun: changed=%v err=%v", changed, err)
	}
	backup2, _ := os.ReadFile(path + BackupSuffix)
	if !bytes.Equal(backup2, orig) {
		t.Fatal("no-op run touched the backup")
	}
}

// Band layout settings (the band contract): legacy clients get the native
// desktop resolution in gxResolution ONLY — never gxWindowedResolution (on
// patched builds that honor it, a desktop-sized client area plus decorations
// cannot fit the work area and the band's bottom rows land off-screen) and
// never a maximize toggle; era clients get a maximized landscape window; an
// unmeasurable desktop omits the resolution CVars entirely. All variants stay
// windowed (gxWindow "1" — exclusive fullscreen cannot be captured) and keep
// out-of-date addons loadable.
func TestBandSettingsFor(t *testing.T) {
	legacy := BandSettingsFor(ClientTypeLegacy, 3840, 2160, true)
	wantLegacy := []Setting{
		{Name: "gxWindow", Value: "1"},
		{Name: "gxResolution", Value: "3840x2160"},
		{Name: "checkAddonVersion", Value: "0"},
	}
	if len(legacy) != len(wantLegacy) {
		t.Fatalf("legacy band settings = %+v, want %+v", legacy, wantLegacy)
	}
	for i, w := range wantLegacy {
		if legacy[i] != w {
			t.Errorf("legacy[%d] = %+v, want %+v", i, legacy[i], w)
		}
	}

	era := BandSettingsFor(ClientTypeClassicEra, 3840, 2160, true)
	wantEra := []Setting{
		{Name: "gxWindow", Value: "1"},
		{Name: "gxMaximize", Value: "1"},
		{Name: "checkAddonVersion", Value: "0"},
	}
	if len(era) != len(wantEra) {
		t.Fatalf("era band settings = %+v, want %+v", era, wantEra)
	}
	for i, w := range wantEra {
		if era[i] != w {
			t.Errorf("era[%d] = %+v, want %+v", i, era[i], w)
		}
	}

	blind := BandSettingsFor(ClientTypeLegacy, 0, 0, false)
	for _, s := range blind {
		if s.Name == "gxResolution" || s.Name == "gxWindowedResolution" {
			t.Errorf("unmeasurable desktop must not write %s", s.Name)
		}
	}
}
