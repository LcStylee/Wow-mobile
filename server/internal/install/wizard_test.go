package install

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeSys is a scriptable System.
type fakeSys struct {
	registry      string
	wellKnown     []string
	pathFFmpeg    string
	wingetFFmpeg  string
	haveWinget    bool
	wingetErr     error
	wingetRan     bool
	afterWinget   string // WingetFFmpeg result once RunWingetInstall ran
	encoder       string
	windowPresent bool
	launched      []string
	launchShows   bool // LaunchGame makes the window appear
}

func (f *fakeSys) RegistryWowPath() (string, bool) { return f.registry, f.registry != "" }
func (f *fakeSys) WellKnownWowDirs() []string      { return f.wellKnown }
func (f *fakeSys) LookPathFFmpeg() (string, bool)  { return f.pathFFmpeg, f.pathFFmpeg != "" }
func (f *fakeSys) WingetFFmpeg() (string, bool) {
	if f.wingetRan && f.afterWinget != "" {
		return f.afterWinget, true
	}
	return f.wingetFFmpeg, f.wingetFFmpeg != ""
}
func (f *fakeSys) HaveWinget() bool { return f.haveWinget }
func (f *fakeSys) RunWingetInstall(io.Writer) error {
	f.wingetRan = true
	return f.wingetErr
}
func (f *fakeSys) ProbeEncoder(string) (string, bool) { return f.encoder, f.encoder != "" }
func (f *fakeSys) GameWindowPresent(string) bool      { return f.windowPresent }
func (f *fakeSys) LaunchGame(exe string) error {
	f.launched = append(f.launched, exe)
	if f.launchShows {
		f.windowPresent = true
	}
	return nil
}

// scriptPrompter records questions and pops scripted answers; it fails the
// test if asked more than scripted (the step-skipping guarantee).
type scriptPrompter struct {
	t        *testing.T
	confirms []bool
	asks     []string
	asked    []string
}

func (p *scriptPrompter) Confirm(q string, def bool) (bool, error) {
	p.asked = append(p.asked, "confirm: "+q)
	if len(p.confirms) == 0 {
		p.t.Fatalf("unexpected Confirm(%q) — step should have been skipped", q)
	}
	ans := p.confirms[0]
	p.confirms = p.confirms[1:]
	return ans, nil
}

func (p *scriptPrompter) Ask(q string) (string, error) {
	p.asked = append(p.asked, "ask: "+q)
	if len(p.asks) == 0 {
		p.t.Fatalf("unexpected Ask(%q)", q)
	}
	ans := p.asks[0]
	p.asks = p.asks[1:]
	if ans == "<err>" {
		return "", errors.New("non-interactive")
	}
	return ans, nil
}

// makeWowDir builds a valid fake WoW Classic Era dir.
func makeWowDir(t *testing.T, withConfig bool) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, GameExeName), []byte("MZ"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "Interface", "AddOns"), 0o755); err != nil {
		t.Fatal(err)
	}
	if withConfig {
		if err := os.MkdirAll(filepath.Join(dir, "WTF"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "WTF", "Config.wtf"), FreshConfig(PortraitSettings(1080, 1920)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func baseOpts(t *testing.T, wow string, sys *fakeSys, p Prompter) Options {
	t.Helper()
	return Options{
		Out:          &bytes.Buffer{},
		Prompt:       p,
		Store:        LoadStore(t.TempDir()),
		Sys:          sys,
		AddonFS:      addonSrc(),
		Width:        1080,
		Height:       1920,
		WindowTitle:  "World of Warcraft",
		WowDirFlag:   wow,
		Interactive:  true,
		PollInterval: time.Millisecond,
	}
}

// A fully satisfied machine: every step reports and nothing prompts.
func TestRunAllSatisfiedSkipsEveryPrompt(t *testing.T) {
	wow := makeWowDir(t, true)
	dest := filepath.Join(wow, "Interface", "AddOns", "WowMobile")
	src := addonSrc()
	if err := ApplyAddon(src, dest, mustPlan(t, src, dest)); err != nil {
		t.Fatal(err)
	}
	sys := &fakeSys{pathFFmpeg: `C:\ffmpeg\bin\ffmpeg.exe`, encoder: "h264_nvenc", windowPresent: true}
	p := &scriptPrompter{t: t} // zero scripted answers: any prompt fails the test
	opts := baseOpts(t, wow, sys, p)
	out := opts.Out.(*bytes.Buffer)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v\n%s", err, out.String())
	}
	if res.WowDir != wow || res.FFmpegPath != sys.pathFFmpeg {
		t.Fatalf("result wrong: %+v", res)
	}
	text := out.String()
	for _, wantLine := range []string{
		"[1/5] WoW Classic Era ....... found: " + wow,
		"[2/5] WowMobile addon ....... installed (3 files, up to date)",
		"[3/5] Portrait resolution ... Config.wtf OK (1080x1920 windowed)",
		"[4/5] FFmpeg ................ found: h264_nvenc available",
		"[5/5] Game running .......... window found",
	} {
		if !strings.Contains(text, wantLine) {
			t.Errorf("missing %q in:\n%s", wantLine, text)
		}
	}
}

// First run: wizard installs the addon, creates Config.wtf (confirm),
// launches the game (confirm) — exactly the prompted steps prompt.
func TestRunFirstTimeFlow(t *testing.T) {
	wow := makeWowDir(t, false)
	sys := &fakeSys{pathFFmpeg: "/usr/bin/ffmpeg", launchShows: true}
	p := &scriptPrompter{t: t, confirms: []bool{true, true}} // create Config.wtf, launch game
	opts := baseOpts(t, wow, sys, p)

	if _, err := Run(opts); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(p.confirms) != 0 {
		t.Fatalf("not all scripted confirms consumed; asked: %v", p.asked)
	}
	if len(sys.launched) != 1 || sys.launched[0] != filepath.Join(wow, GameExeName) {
		t.Fatalf("launch wrong: %v", sys.launched)
	}
	cfgBytes, err := os.ReadFile(filepath.Join(wow, "WTF", "Config.wtf"))
	if err != nil || !SettingsSatisfied(cfgBytes, PortraitSettings(1080, 1920)) {
		t.Fatalf("Config.wtf not created correctly: %q err=%v", cfgBytes, err)
	}
	if _, err := os.Stat(filepath.Join(wow, "Interface", "AddOns", "WowMobile", "WowMobile.toc")); err != nil {
		t.Fatalf("addon not installed: %v", err)
	}
}

// Locate order: persisted path wins without prompting; a stale persisted path
// falls through to registry, and the fresh find is re-persisted.
func TestLocateWowPersistedThenRegistry(t *testing.T) {
	wow := makeWowDir(t, true)
	storeDir := t.TempDir()
	store := LoadStore(storeDir)
	store.Set(KeyWowPath, filepath.Join(t.TempDir(), "gone"))
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}

	sys := &fakeSys{registry: wow, pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t}
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.WowDir != wow {
		t.Fatalf("registry candidate not used: %q", res.WowDir)
	}
	if got := LoadStore(storeDir).Get(KeyWowPath); got != wow {
		t.Fatalf("fresh find not persisted: %q", got)
	}
}

// Nothing found anywhere: the user pastes a path (with retry on a bad one).
func TestLocateWowPromptsAndRetries(t *testing.T) {
	wow := makeWowDir(t, true)
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, asks: []string{`C:\nope`, `"` + wow + `"`}}
	opts := baseOpts(t, "", sys, p)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.WowDir != wow {
		t.Fatalf("pasted (quoted) path not accepted: %q", res.WowDir)
	}
}

// Config.wtf wrong while WoW runs and the user declines waiting: the file is
// left alone and the wizard continues.
func TestConfigWTFRunningGameDeclineLeavesFile(t *testing.T) {
	wow := makeWowDir(t, true)
	path := filepath.Join(wow, "WTF", "Config.wtf")
	orig := []byte("SET gxWindow \"0\"\r\n")
	if err := os.WriteFile(path, orig, 0o644); err != nil {
		t.Fatal(err)
	}
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, confirms: []bool{false}} // decline waiting
	opts := baseOpts(t, wow, sys, p)

	if _, err := Run(opts); err != nil {
		t.Fatalf("Run: %v", err)
	}
	now, _ := os.ReadFile(path)
	if !bytes.Equal(now, orig) {
		t.Fatalf("file modified while game running: %q", now)
	}
	if _, err := os.Stat(path + BackupSuffix); !os.IsNotExist(err) {
		t.Fatal("backup written despite declined edit")
	}
}

// Config.wtf wrong while WoW runs in a non-interactive session: the safe
// default is NOT to wait (nobody is there to close WoW) — the wizard skips
// the edit with the restart hint and completes instead of polling forever.
func TestConfigWTFRunningGameNonInteractiveSkipsWait(t *testing.T) {
	wow := makeWowDir(t, true)
	path := filepath.Join(wow, "WTF", "Config.wtf")
	orig := []byte("SET gxWindow \"0\"\r\n")
	if err := os.WriteFile(path, orig, 0o644); err != nil {
		t.Fatal(err)
	}
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := NewConsolePrompter(blockingReader{}, io.Discard, false, false)
	opts := baseOpts(t, wow, sys, p)
	opts.Interactive = false
	out := opts.Out.(*bytes.Buffer)

	done := make(chan error, 1)
	go func() {
		_, err := Run(opts)
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run: %v\n%s", err, out.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("non-interactive run hung waiting for WoW to close")
	}
	if !strings.Contains(out.String(), "unchanged — close WoW and restart wowstreamd") {
		t.Fatalf("skip message missing:\n%s", out.String())
	}
	now, _ := os.ReadFile(path)
	if !bytes.Equal(now, orig) {
		t.Fatalf("file modified while game running: %q", now)
	}
}

// --yes auto-launches, but the window never appears (crash, hung login):
// the wait loop must expire with a clear error instead of polling forever.
func TestGameLaunchWaitTimesOut(t *testing.T) {
	wow := makeWowDir(t, true)
	sys := &fakeSys{pathFFmpeg: "ff", launchShows: false}
	p := NewConsolePrompter(blockingReader{}, io.Discard, true, true)
	opts := baseOpts(t, wow, sys, p)
	opts.Yes = true
	opts.WaitTimeout = 10 * time.Millisecond

	done := make(chan error, 1)
	go func() {
		_, err := Run(opts)
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "timed out") {
			t.Fatalf("expected timeout error, got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("launch wait loop did not honor WaitTimeout")
	}
	if len(sys.launched) != 1 {
		t.Fatalf("game not auto-launched under --yes: %v", sys.launched)
	}
}

// FFmpeg absent, winget available and accepted: install runs, the binary is
// found in the packages dir afterwards, and the path is persisted.
func TestFFmpegWingetInstallAndPersist(t *testing.T) {
	wow := makeWowDir(t, true)
	installed := filepath.Join(t.TempDir(), "bin", "ffmpeg.exe")
	sys := &fakeSys{haveWinget: true, afterWinget: installed, windowPresent: true, encoder: "h264_nvenc"}
	p := &scriptPrompter{t: t, confirms: []bool{true}}
	storeDir := t.TempDir()
	opts := baseOpts(t, wow, sys, p)
	opts.Store = LoadStore(storeDir)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !sys.wingetRan || res.FFmpegPath != installed {
		t.Fatalf("winget flow wrong: ran=%v path=%q", sys.wingetRan, res.FFmpegPath)
	}
	if got := LoadStore(storeDir).Get(KeyFFmpegPath); got != installed {
		t.Fatalf("ffmpeg path not persisted: %q", got)
	}
}

// FFmpeg absent and winget missing: manual instructions with both URLs, then
// a clear error.
func TestFFmpegNoWingetFailsWithManualInstructions(t *testing.T) {
	wow := makeWowDir(t, true)
	sys := &fakeSys{windowPresent: true}
	p := &scriptPrompter{t: t}
	opts := baseOpts(t, wow, sys, p)
	out := opts.Out.(*bytes.Buffer)

	_, err := Run(opts)
	if err == nil || !strings.Contains(err.Error(), "ffmpeg not found") {
		t.Fatalf("expected ffmpeg error, got %v", err)
	}
	text := out.String()
	for _, url := range []string{"https://ffmpeg.org/download.html", "https://www.gyan.dev/ffmpeg/builds/"} {
		if !strings.Contains(text, url) {
			t.Errorf("manual instructions missing %s:\n%s", url, text)
		}
	}
}

// Non-interactive without --yes: the game-not-running step must fail with a
// clear message instead of blocking on a prompt or polling forever.
func TestGameNotRunningNonInteractiveFails(t *testing.T) {
	wow := makeWowDir(t, true)
	sys := &fakeSys{pathFFmpeg: "ff"}
	p := NewConsolePrompter(strings.NewReader(""), io.Discard, false, false)
	opts := baseOpts(t, wow, sys, p)
	opts.Interactive = false

	_, err := Run(opts)
	if err == nil || !strings.Contains(err.Error(), "not interactive") {
		t.Fatalf("expected clear non-interactive error, got %v", err)
	}
	if len(sys.launched) != 0 {
		t.Fatal("game launched despite non-interactive session")
	}
}

// --yes: every default is taken without reading stdin (a blocked read would
// hang the test), including auto-launching the game.
func TestYesTakesAllDefaults(t *testing.T) {
	wow := makeWowDir(t, false)
	sys := &fakeSys{pathFFmpeg: "ff", launchShows: true}
	blocking := blockingReader{}
	p := NewConsolePrompter(blocking, io.Discard, true, true)
	opts := baseOpts(t, wow, sys, p)
	opts.Yes = true

	done := make(chan error, 1)
	go func() {
		_, err := Run(opts)
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run with --yes: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("--yes run blocked on a prompt")
	}
	if len(sys.launched) != 1 {
		t.Fatalf("default launch not taken: %v", sys.launched)
	}
}

// blockingReader never returns — any read under --yes is a bug.
type blockingReader struct{}

func (blockingReader) Read([]byte) (int, error) {
	select {} //nolint:staticcheck // deliberate: block forever
}

// The [n/5] progress lines align their results at one column, exactly as
// documented.
func TestStepLineFormat(t *testing.T) {
	var b bytes.Buffer
	step(&b, 4, "FFmpeg", "found: h264_nvenc available")
	if got := b.String(); got != "[4/5] FFmpeg ................ found: h264_nvenc available\n" {
		t.Fatalf("step line: %q", got)
	}
}

// Store round-trip preserves keys this version does not know about.
func TestStorePreservesUnknownKeys(t *testing.T) {
	dir := t.TempDir()
	raw := `{"future_key": {"nested": true}, "wow_path": "old"}`
	if err := os.WriteFile(filepath.Join(dir, StoreFileName), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	s := LoadStore(dir)
	if s.Get(KeyWowPath) != "old" {
		t.Fatalf("existing key lost: %q", s.Get(KeyWowPath))
	}
	s.Set(KeyWowPath, `C:\wow`)
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(filepath.Join(dir, StoreFileName))
	if !strings.Contains(string(data), "future_key") || !strings.Contains(string(data), "nested") {
		t.Fatalf("unknown key dropped: %s", data)
	}
	if LoadStore(dir).Get(KeyWowPath) != `C:\wow` {
		t.Fatal("updated key not persisted")
	}
}
