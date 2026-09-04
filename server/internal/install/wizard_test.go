package install

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// fakeSys is a scriptable System.
type fakeSys struct {
	registry      string
	wellKnown     []string
	installRoots  []string
	pathFFmpeg    string
	wingetFFmpeg  string
	haveWinget    bool
	wingetErr     error
	wingetRan     bool
	afterWinget   string // WingetFFmpeg result once RunWingetInstall ran
	encoder       string
	windowPresent bool
	presentDirs   []string // install dirs passed to GameWindowPresent, in order
	resizeMsg     string   // EnforceGameWindowSize result; "" = nothing to do
	resizeCalls   []string
	resizeDirs    []string // install dirs passed to EnforceGameWindowSize
	launched      []string
	launchShows   bool // LaunchGame makes the window appear
	workW, workH  int  // PrimaryWorkArea; 0,0 = not measurable (the default)
	decorW        int  // WindowDecorationExtents; 0 = the conservative fallback
	decorH        int
	deskW, deskH  int // PrimaryDesktopResolution; 0,0 = not measurable (the default)
}

func (f *fakeSys) RegistryWowPath() (string, bool) { return f.registry, f.registry != "" }
func (f *fakeSys) WellKnownWowDirs() []string      { return f.wellKnown }
func (f *fakeSys) WowInstallRoots() []string       { return f.installRoots }
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
func (f *fakeSys) PrimaryWorkArea() (int, int, bool) {
	return f.workW, f.workH, f.workW > 0 && f.workH > 0
}
func (f *fakeSys) PrimaryDesktopResolution() (int, int, bool) {
	return f.deskW, f.deskH, f.deskW > 0 && f.deskH > 0
}
func (f *fakeSys) WindowDecorationExtents() (int, int) {
	if f.decorW > 0 || f.decorH > 0 {
		return f.decorW, f.decorH
	}
	return window.FallbackDecorationW, window.FallbackDecorationH
}
func (f *fakeSys) GameWindowPresent(installDir, _ string) bool {
	f.presentDirs = append(f.presentDirs, installDir)
	return f.windowPresent
}
func (f *fakeSys) EnforceGameWindowSize(installDir, _ string, w, h int) (string, bool) {
	f.resizeCalls = append(f.resizeCalls, fmt.Sprintf("%dx%d", w, h))
	f.resizeDirs = append(f.resizeDirs, installDir)
	return f.resizeMsg, f.resizeMsg != ""
}
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
	chooses  []scriptChoice // scripted ChooseGame outcomes
	offered  [][]GameCandidate
	asked    []string
	notices  []string
}

// scriptChoice is one scripted ChooseGame answer.
type scriptChoice struct {
	sel GameSelection
	err error
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

func (p *scriptPrompter) SelectGamePath(prevInvalid string) (string, error) {
	return p.Ask("select game path (prev invalid: " + prevInvalid + ")")
}

func (p *scriptPrompter) ChooseGame(cands []GameCandidate) (GameSelection, error) {
	p.asked = append(p.asked, fmt.Sprintf("choose: %d candidates", len(cands)))
	p.offered = append(p.offered, cands)
	if len(p.chooses) == 0 {
		p.t.Fatalf("unexpected ChooseGame with %d candidates — the picker should have been skipped", len(cands))
	}
	c := p.chooses[0]
	p.chooses = p.chooses[1:]
	return c.sel, c.err
}

func (p *scriptPrompter) Notice(title, message string) {
	p.notices = append(p.notices, message)
}

// makeWowDir builds a valid fake WoW Classic Era dir.
func makeWowDir(t *testing.T, withConfig bool) string {
	t.Helper()
	return makeGameDir(t, GameExeName, withConfig)
}

// makeGameDir builds a fake game dir around the given executable name. When
// withConfig is set, Config.wtf is pre-satisfied for the client type the
// wizard will assign to that exe (Classic Era for WowClassic.exe, legacy for
// everything else in these tests).
func makeGameDir(t *testing.T, exeName string, withConfig bool) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, exeName), []byte("MZ"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "Interface", "AddOns"), 0o755); err != nil {
		t.Fatal(err)
	}
	if withConfig {
		ct := ClientTypeClassicEra
		if exeName != GameExeName {
			ct = ClientTypeLegacy
		}
		if err := os.MkdirAll(filepath.Join(dir, "WTF"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "WTF", "Config.wtf"), FreshConfig(PortraitSettingsFor(ct, 1080, 1920)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func baseOpts(t *testing.T, wow string, sys *fakeSys, p Prompter) Options {
	t.Helper()
	return Options{
		Out:            &bytes.Buffer{},
		Prompt:         p,
		Store:          LoadStore(t.TempDir()),
		Sys:            sys,
		AddonFS:        addonSrc(),
		VanillaAddonFS: vanillaAddonSrc(),
		Width:          1080,
		Height:         1920,
		WindowTitle:    "World of Warcraft",
		WowDirFlag:     wow,
		Interactive:    true,
		PollInterval:   time.Millisecond,
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
	wantExe := filepath.Join(wow, GameExeName)
	if res.GameExe != wantExe || res.GameDir != wow || res.ClientType != ClientTypeClassicEra || res.FFmpegPath != sys.pathFFmpeg {
		t.Fatalf("result wrong: %+v", res)
	}
	text := out.String()
	for _, wantLine := range []string{
		"[1/5] World of Warcraft ..... found: " + wantExe + " (Classic Era)",
		"[2/5] WowMobile addon ....... installed (3 files, up to date)",
		"[3/5] Window settings ....... Config.wtf OK (1080x1920 windowed)",
		"[4/5] FFmpeg ................ found: h264_nvenc available",
		"[5/5] Game running .......... window found",
	} {
		if !strings.Contains(text, wantLine) {
			t.Errorf("missing %q in:\n%s", wantLine, text)
		}
	}
	// Every game-window check must bind to the CHOSEN install's directory —
	// an unrelated WoW install running alongside must never satisfy or block
	// a wizard step (v0.4.2 field report).
	if len(sys.presentDirs) == 0 {
		t.Fatal("GameWindowPresent never called")
	}
	for _, dir := range sys.presentDirs {
		if dir != wow {
			t.Errorf("GameWindowPresent got install dir %q, want the chosen %q", dir, wow)
		}
	}
}

// The game-running step resizes the found window to the decided resolution
// (windowed 1.12 ignores gxResolution, so the wizard sizes the window
// directly) and reports the outcome in its step line — honestly, including
// reverts, and never fatally.
func TestGameRunningStepEnforcesWindowSize(t *testing.T) {
	wow := makeWowDir(t, true)
	dest := filepath.Join(wow, "Interface", "AddOns", "WowMobile")
	src := addonSrc()
	if err := ApplyAddon(src, dest, mustPlan(t, src, dest)); err != nil {
		t.Fatal(err)
	}
	sys := &fakeSys{
		pathFFmpeg:    `C:\ffmpeg\bin\ffmpeg.exe`,
		encoder:       "h264_nvenc",
		windowPresent: true,
		resizeMsg:     "resized WoW window to 1080x1920",
	}
	opts := baseOpts(t, wow, sys, &scriptPrompter{t: t})
	out := opts.Out.(*bytes.Buffer)
	if _, err := Run(opts); err != nil {
		t.Fatalf("Run: %v\n%s", err, out.String())
	}
	if len(sys.resizeCalls) != 1 || sys.resizeCalls[0] != "1080x1920" {
		t.Errorf("EnforceGameWindowSize calls = %v, want exactly [1080x1920]", sys.resizeCalls)
	}
	if len(sys.resizeDirs) != 1 || sys.resizeDirs[0] != wow {
		t.Errorf("EnforceGameWindowSize install dirs = %v, want the chosen [%q] — a second install's window must never be the one resized", sys.resizeDirs, wow)
	}
	if !strings.Contains(out.String(), "window found — resized WoW window to 1080x1920") {
		t.Errorf("resize outcome missing from the step line:\n%s", out.String())
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

// Locate order: a stale persisted path falls through to the scan, whose
// registry candidate is offered in the picker; the confirmed find is
// persisted as the recorded game exe.
func TestLocateWowPersistedThenRegistry(t *testing.T) {
	wow := makeWowDir(t, true)
	storeDir := t.TempDir()
	store := LoadStore(storeDir)
	store.Set(KeyWowPath, filepath.Join(t.TempDir(), "gone"))
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}

	sys := &fakeSys{registry: wow, pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, chooses: []scriptChoice{{sel: GameSelection{Index: 0}}}}
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	wantExe := filepath.Join(wow, GameExeName)
	if res.GameExe != wantExe {
		t.Fatalf("registry candidate not used: %q", res.GameExe)
	}
	if len(p.offered) != 1 || len(p.offered[0]) != 1 || p.offered[0][0].ExePath != wantExe {
		t.Fatalf("picker not shown the registry candidate: %+v", p.offered)
	}
	after := LoadStore(storeDir)
	if got := after.Get(KeyGameExe); got != wantExe {
		t.Fatalf("fresh find not persisted as game_exe: %q", got)
	}
	if got := after.Get(KeyClientType); got != string(ClientTypeClassicEra) {
		t.Fatalf("client type not persisted: %q", got)
	}
}

// The pre-game_exe wow_path key was persisted by releases that auto-detected
// without asking, so it must NOT take the silent fast path: the scan runs
// once with the remembered install as the picker's first/default candidate,
// and the confirmed pick is marked chosen — later runs are then silent.
func TestLocateWowMigratesLegacyWowPathKey(t *testing.T) {
	wow := makeWowDir(t, true)
	storeDir := t.TempDir()
	store := LoadStore(storeDir)
	store.Set(KeyWowPath, wow)
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, chooses: []scriptChoice{{sel: GameSelection{Index: 0}}}}
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	wantExe := filepath.Join(wow, GameExeName)
	if res.GameExe != wantExe {
		t.Fatalf("wow_path migration failed: %+v", res)
	}
	if len(p.offered) != 1 || p.offered[0][0].ExePath != wantExe {
		t.Fatalf("unconfirmed wow_path must go through the picker with itself as default: %+v", p.offered)
	}
	after := LoadStore(storeDir)
	if after.Get(KeyGameExe) != wantExe || after.Get(KeyGameChosen) != "1" {
		t.Fatalf("confirmed migration not persisted with the chosen marker: exe=%q chosen=%q",
			after.Get(KeyGameExe), after.Get(KeyGameChosen))
	}

	// Second run: the now-confirmed choice is reused with zero prompts.
	sys2 := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	opts2 := baseOpts(t, "", sys2, &scriptPrompter{t: t})
	opts2.Store = LoadStore(storeDir)
	res2, err := Run(opts2)
	if err != nil {
		t.Fatalf("second Run: %v", err)
	}
	if res2.GameExe != wantExe {
		t.Fatalf("confirmed choice not reused silently: %+v", res2)
	}
}

// A game_exe persisted by a pre-picker release carries no explicit-choice
// marker (those releases auto-detected and persisted without asking — the
// v0.2.0 field report: wrong install grabbed on a multi-install PC). After
// upgrading, that store must NOT keep the wrong install silently: the scan
// runs, the remembered exe is only the picker's default, and the user's pick
// of the other install wins and is marked chosen.
func TestUnmarkedPersistedGameExeRescans(t *testing.T) {
	remembered := makeWowDir(t, true)
	other := makeGameDir(t, "Wow.exe", true)
	storeDir := t.TempDir()
	store := LoadStore(storeDir)
	store.Set(KeyGameExe, filepath.Join(remembered, GameExeName))
	store.Set(KeyClientType, string(ClientTypeClassicEra))
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}
	sys := &fakeSys{wellKnown: []string{other}, pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, chooses: []scriptChoice{{sel: GameSelection{Index: 1}}}}
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(p.offered) != 1 || len(p.offered[0]) != 2 ||
		p.offered[0][0].ExePath != filepath.Join(remembered, GameExeName) {
		t.Fatalf("unmarked game_exe must re-scan with itself as the picker default: %+v", p.offered)
	}
	if res.GameExe != filepath.Join(other, "Wow.exe") {
		t.Fatalf("user's corrective pick not applied: %+v", res)
	}
	after := LoadStore(storeDir)
	if after.Get(KeyGameExe) != res.GameExe || after.Get(KeyGameChosen) != "1" {
		t.Fatalf("corrective pick not persisted with the chosen marker: exe=%q chosen=%q",
			after.Get(KeyGameExe), after.Get(KeyGameChosen))
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
	if res.GameExe != filepath.Join(wow, GameExeName) {
		t.Fatalf("pasted (quoted) path not accepted: %q", res.GameExe)
	}
}

// The pasted path may also be the exe itself — private servers pick the
// program directly, whatever its name; an unknown name asks for the client
// type once and persists the answer.
func TestLocateWowAcceptsPastedExeAndAsksClientType(t *testing.T) {
	dir := makeGameDir(t, "TurtleWoW.exe", true)
	exe := filepath.Join(dir, "TurtleWoW.exe")
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	// Confirm #1: "Is this a Classic Era client?" answered NO => legacy.
	p := &scriptPrompter{t: t, asks: []string{exe}, confirms: []bool{false}}
	storeDir := t.TempDir()
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.GameExe != exe || res.ClientType != ClientTypeLegacy {
		t.Fatalf("custom exe flow wrong: %+v", res)
	}
	if got := LoadStore(storeDir).Get(KeyClientType); got != string(ClientTypeLegacy) {
		t.Fatalf("answered client type not persisted: %q", got)
	}
	// The 1.12 port must have been installed, its note printed, and the
	// one-time GUI notice offered.
	if _, err := os.Stat(filepath.Join(dir, "Interface", "AddOns", "WowMobile_Vanilla", "WowMobile_Vanilla.toc")); err != nil {
		t.Fatalf("vanilla addon not installed: %v", err)
	}
	text := opts.Out.(*bytes.Buffer).String()
	if !strings.Contains(text, "WowMobile_Vanilla, 1.12 port") {
		t.Fatalf("legacy addon install line missing:\n%s", text)
	}
	if len(p.notices) != 1 || !strings.Contains(p.notices[0], "WowMobile_Vanilla") {
		t.Fatalf("GUI notice wrong: %v", p.notices)
	}

	// Second run: the persisted answer is reused — no client-type prompt, no
	// repeated notice.
	sys2 := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p2 := &scriptPrompter{t: t}
	opts2 := baseOpts(t, "", sys2, p2)
	opts2.Store = LoadStore(storeDir)
	res2, err := Run(opts2)
	if err != nil {
		t.Fatalf("second Run: %v", err)
	}
	if res2.ClientType != ClientTypeLegacy {
		t.Fatalf("persisted client type not reused: %+v", res2)
	}
	if len(p2.notices) != 0 {
		t.Fatalf("legacy notice repeated: %v", p2.notices)
	}
}

// A 1.12 private-server dir (Wow.exe): the WowMobile_Vanilla port is
// installed (never the Classic Era addon), --layout auto resolves to BAND —
// Config.wtf gets the native landscape session (gxResolution = the desktop
// resolution; never a portrait fit), the window is NEVER resized, and the
// launch step starts the recorded exe.
func TestLegacyClientFlow(t *testing.T) {
	dir := makeGameDir(t, "Wow.exe", false)
	sys := &fakeSys{pathFFmpeg: "ff", launchShows: true, deskW: 1920, deskH: 1080}
	p := &scriptPrompter{t: t, confirms: []bool{true, true}} // create Config.wtf, launch
	opts := baseOpts(t, dir, sys, p)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.ClientType != ClientTypeLegacy {
		t.Fatalf("Wow.exe not detected as legacy: %+v", res)
	}
	if res.Layout != config.LayoutBand {
		t.Fatalf("auto layout for a legacy client must resolve to band, got %q", res.Layout)
	}
	if _, err := os.Stat(filepath.Join(dir, "Interface", "AddOns", "WowMobile")); !os.IsNotExist(err) {
		t.Fatal("Classic Era addon must not be installed for a 1.12 client")
	}
	data, err := os.ReadFile(filepath.Join(dir, "Interface", "AddOns", "WowMobile_Vanilla", "WowMobile_Vanilla.toc"))
	if err != nil || !bytes.Contains(data, []byte("## Interface: 11200")) {
		t.Fatalf("WowMobile_Vanilla not installed for a 1.12 client: %q err=%v", data, err)
	}
	cfg, err := os.ReadFile(filepath.Join(dir, "WTF", "Config.wtf"))
	if err != nil {
		t.Fatal(err)
	}
	if !SettingsSatisfied(cfg, BandSettingsFor(ClientTypeLegacy, 1920, 1080, true)) {
		t.Fatalf("legacy band Config.wtf wrong: %q", cfg)
	}
	// Band contract: the NATIVE landscape desktop resolution lands in
	// gxResolution ONLY — never gxWindowedResolution (custom builds that honor
	// it would get a window guaranteed not to fit the work area, pushing the
	// band's bottom rows off-screen); no portrait size anywhere, and no
	// gxMaximize forcing.
	if !bytes.Contains(cfg, []byte(`SET gxResolution "1920x1080"`)) {
		t.Fatalf("legacy band Config.wtf must carry the desktop resolution in gxResolution: %q", cfg)
	}
	if bytes.Contains(cfg, []byte("1080x1920")) || bytes.Contains(cfg, []byte("gxMaximize")) ||
		bytes.Contains(cfg, []byte("gxWindowedResolution")) {
		t.Fatalf("band layout must not force a portrait size, gxMaximize, or a windowed resolution: %q", cfg)
	}
	// Band layout retires window-size enforcement entirely.
	if len(sys.resizeCalls) != 0 {
		t.Fatalf("band layout must never resize the window, got %v", sys.resizeCalls)
	}
	if len(sys.launched) != 1 || sys.launched[0] != filepath.Join(dir, "Wow.exe") {
		t.Fatalf("launch wrong: %v", sys.launched)
	}
	text := opts.Out.(*bytes.Buffer).String()
	if !strings.Contains(text, "WowMobile_Vanilla, 1.12 port") {
		t.Fatalf("vanilla addon install line missing:\n%s", text)
	}
	if !strings.Contains(text, LegacyAddonNote) {
		t.Fatalf("legacy addon note missing:\n%s", text)
	}
	if !strings.Contains(text, "band layout") {
		t.Fatalf("band layout line missing from the wizard output:\n%s", text)
	}
}

// --layout portrait on a legacy client keeps the classic behavior: the
// portrait fit is written to Config.wtf (both CVar spellings) and the window
// is resized after launch.
func TestLegacyClientExplicitPortraitLayout(t *testing.T) {
	dir := makeGameDir(t, "Wow.exe", false)
	sys := &fakeSys{pathFFmpeg: "ff", launchShows: true, resizeMsg: "resized WoW window to 1080x1920"}
	p := &scriptPrompter{t: t, confirms: []bool{true, true}} // create Config.wtf, launch
	opts := baseOpts(t, dir, sys, p)
	opts.Layout = config.LayoutPortrait

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Layout != config.LayoutPortrait {
		t.Fatalf("explicit portrait layout must stand, got %q", res.Layout)
	}
	cfg, err := os.ReadFile(filepath.Join(dir, "WTF", "Config.wtf"))
	if err != nil {
		t.Fatal(err)
	}
	if !SettingsSatisfied(cfg, PortraitSettingsFor(ClientTypeLegacy, 1080, 1920)) {
		t.Fatalf("legacy portrait Config.wtf wrong: %q", cfg)
	}
	if !bytes.Contains(cfg, []byte(`SET gxResolution "1080x1920"`)) ||
		!bytes.Contains(cfg, []byte(`SET gxWindowedResolution "1080x1920"`)) {
		t.Fatalf("legacy portrait Config.wtf must carry both resolution CVars: %q", cfg)
	}
	if len(sys.resizeCalls) != 1 || sys.resizeCalls[0] != "1080x1920" {
		t.Fatalf("portrait layout must enforce the window size, got %v", sys.resizeCalls)
	}
}

// --layout band on a Classic Era client (band is only the default for
// legacy): Config.wtf gets a maximized landscape window and no portrait fit,
// with no resize enforcement.
func TestEraExplicitBandLayout(t *testing.T) {
	wow := makeWowDir(t, false)
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true, deskW: 2560, deskH: 1440}
	p := &scriptPrompter{t: t, confirms: []bool{true}} // create Config.wtf
	opts := baseOpts(t, wow, sys, p)
	opts.Layout = config.LayoutBand

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Layout != config.LayoutBand || res.ClientType != ClientTypeClassicEra {
		t.Fatalf("unexpected result: %+v", res)
	}
	// Band mode leaves Width/Height as the design fallback frame only.
	if res.Width != window.DesignW || res.Height != window.DesignH {
		t.Fatalf("band fallback frame = %dx%d, want the design space", res.Width, res.Height)
	}
	cfg, err := os.ReadFile(filepath.Join(wow, "WTF", "Config.wtf"))
	if err != nil {
		t.Fatal(err)
	}
	if !SettingsSatisfied(cfg, BandSettingsFor(ClientTypeClassicEra, 2560, 1440, true)) {
		t.Fatalf("era band Config.wtf wrong: %q", cfg)
	}
	if !bytes.Contains(cfg, []byte(`SET gxMaximize "1"`)) || bytes.Contains(cfg, []byte("gxWindowedResolution")) {
		t.Fatalf("era band must maximize and not pin a windowed resolution: %q", cfg)
	}
	if len(sys.resizeCalls) != 0 {
		t.Fatalf("band layout must never resize the window, got %v", sys.resizeCalls)
	}
}

// Band layout with an unmeasurable desktop omits the resolution CVars — the
// client keeps its own remembered landscape mode, which the band adapts to.
func TestLegacyBandUnmeasurableDesktop(t *testing.T) {
	dir := makeGameDir(t, "Wow.exe", false)
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, confirms: []bool{true}} // create Config.wtf
	opts := baseOpts(t, dir, sys, p)

	if _, err := Run(opts); err != nil {
		t.Fatalf("Run: %v", err)
	}
	cfg, err := os.ReadFile(filepath.Join(dir, "WTF", "Config.wtf"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(cfg, []byte("gxResolution")) || bytes.Contains(cfg, []byte("gxWindowedResolution")) {
		t.Fatalf("unmeasurable desktop must omit resolution CVars: %q", cfg)
	}
	if !bytes.Contains(cfg, []byte(`SET gxWindow "1"`)) || !bytes.Contains(cfg, []byte(`SET checkAddonVersion "0"`)) {
		t.Fatalf("band Config.wtf must still keep windowed mode and out-of-date addons: %q", cfg)
	}
}

// --game-exe overrides everything and is validated like --ffmpeg.
func TestGameExeFlag(t *testing.T) {
	dir := makeGameDir(t, "VanillaFixes.exe", true)
	exe := filepath.Join(dir, "VanillaFixes.exe")
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	opts := baseOpts(t, "", sys, &scriptPrompter{t: t})
	opts.GameExeFlag = exe

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.GameExe != exe || res.ClientType != ClientTypeLegacy {
		t.Fatalf("--game-exe flow wrong: %+v", res)
	}

	opts2 := baseOpts(t, "", sys, &scriptPrompter{t: t})
	opts2.GameExeFlag = filepath.Join(dir, "missing.exe")
	if _, err := Run(opts2); err == nil || !strings.Contains(err.Error(), "--game-exe") {
		t.Fatalf("invalid --game-exe not rejected: %v", err)
	}
}

// A chosen install stamped with a non-1.x version ("stream only: touch UI
// addon unavailable" in the picker) must get NO addon: neither variant can
// load on a 2.x+ client, and the "Private-server 1.12 client detected"
// notice must not fire for a client that is not a 1.12 client. The addon
// step reports skipped instead; window settings still follow the nearer
// family (legacy for 2.x–7.x, modern for 8.0+).
func TestStreamOnlyClientSkipsAddon(t *testing.T) {
	// TBC-era 2.4 client: legacy window settings, no addon, no 1.12 notice.
	dir := makeGameDir(t, "Wow.exe", true) // legacy Config.wtf pre-satisfied
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t} // zero scripted answers: any prompt fails
	opts := baseOpts(t, "", sys, p)
	opts.GameExeFlag = filepath.Join(dir, "Wow.exe")
	opts.versionProbe = func(string) (GameVersion, bool) { return GameVersion{Major: 2, Minor: 4}, true }

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.ClientType != ClientTypeLegacy {
		t.Fatalf("2.4 client must use the legacy settings family: %+v", res)
	}
	for _, folder := range []string{"WowMobile", "WowMobile_Vanilla"} {
		if _, err := os.Stat(filepath.Join(dir, "Interface", "AddOns", folder)); !os.IsNotExist(err) {
			t.Errorf("%s must not be installed into a stream-only 2.4 client (err=%v)", folder, err)
		}
	}
	text := opts.Out.(*bytes.Buffer).String()
	if !strings.Contains(text, "skipped — stream only") {
		t.Fatalf("addon step must report the stream-only skip:\n%s", text)
	}
	if strings.Contains(text, "Private-server 1.12 client detected") {
		t.Fatalf("1.12 notice must not fire for a 2.4 client:\n%s", text)
	}
	if len(p.notices) != 0 {
		t.Fatalf("GUI notice must not fire for a stream-only client: %v", p.notices)
	}

	// Retail 11.x client: modern settings family, addon equally skipped.
	dir2 := makeWowDir(t, true)
	sys2 := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	opts2 := baseOpts(t, "", sys2, &scriptPrompter{t: t})
	opts2.GameExeFlag = filepath.Join(dir2, GameExeName)
	opts2.versionProbe = func(string) (GameVersion, bool) { return GameVersion{Major: 11, Minor: 2}, true }

	res2, err := Run(opts2)
	if err != nil {
		t.Fatalf("Run (11.x): %v", err)
	}
	if res2.ClientType != ClientTypeClassicEra {
		t.Fatalf("11.x client must use the modern settings family: %+v", res2)
	}
	if _, err := os.Stat(filepath.Join(dir2, "Interface", "AddOns", "WowMobile")); !os.IsNotExist(err) {
		t.Errorf("WowMobile must not be installed into a stream-only 11.x client (err=%v)", err)
	}
}

// A vanilla-plus stamp (1.18 on a Wow.exe — OctoWow-style, the v0.3.2 field
// report) is NOT conclusive: it falls through to the name heuristics, which
// classify Wow.exe as legacy — the 1.12 addon port is installed, no prompt.
func TestVanillaPlusStampFallsThroughToHeuristics(t *testing.T) {
	dir := makeGameDir(t, "Wow.exe", true) // legacy Config.wtf pre-satisfied
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t} // zero scripted answers: any prompt fails
	opts := baseOpts(t, "", sys, p)
	opts.GameExeFlag = filepath.Join(dir, "Wow.exe")
	opts.versionProbe = func(string) (GameVersion, bool) { return GameVersion{Major: 1, Minor: 18}, true }

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v\n%s", err, opts.Out.(*bytes.Buffer).String())
	}
	if res.ClientType != ClientTypeLegacy {
		t.Fatalf("1.18-stamped Wow.exe must classify legacy via heuristics: %+v", res)
	}
	if _, err := os.Stat(filepath.Join(dir, "Interface", "AddOns", "WowMobile_Vanilla", "WowMobile_Vanilla.toc")); err != nil {
		t.Fatalf("vanilla addon not installed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "Interface", "AddOns", "WowMobile")); !os.IsNotExist(err) {
		t.Fatal("Classic Era addon must not be installed for a vanilla-plus client")
	}
}

// A vanilla-plus stamp on an exe the heuristics don't know either: the ask
// fires with wording that names the found stamp and defaults to the 1.12
// engine — also the non-interactive/--yes default.
func TestVanillaPlusStampCustomExeAsksDefaultLegacy(t *testing.T) {
	dir := makeGameDir(t, "OctoWow.exe", true) // legacy Config.wtf pre-satisfied
	exe := filepath.Join(dir, "OctoWow.exe")
	probe := func(string) (GameVersion, bool) { return GameVersion{Major: 1, Minor: 18}, true }

	// Interactive: the question describes the vanilla-plus find; answering
	// the default (No) lands on legacy.
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, confirms: []bool{false}}
	opts := baseOpts(t, "", sys, p)
	opts.GameExeFlag = exe
	opts.versionProbe = probe
	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.ClientType != ClientTypeLegacy {
		t.Fatalf("declined Classic Era must mean legacy: %+v", res)
	}
	question := ""
	for _, q := range p.asked {
		if strings.HasPrefix(q, "confirm: ") {
			question = q
			break
		}
	}
	for _, want := range []string{"1.18", "vanilla-plus", "1.12 engine"} {
		if !strings.Contains(question, want) {
			t.Errorf("ask wording must mention %q, got %q", want, question)
		}
	}

	// --yes: never guesses Classic Era for a vanilla-plus stamp — the
	// default is the 1.12 engine, and no prompt may block.
	sys2 := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p2 := NewConsolePrompter(blockingReader{}, io.Discard, true, true)
	opts2 := baseOpts(t, "", sys2, p2)
	opts2.Store = LoadStore(t.TempDir())
	opts2.GameExeFlag = exe
	opts2.versionProbe = probe
	opts2.Yes = true
	done := make(chan struct{})
	var res2 *Result
	var err2 error
	go func() { res2, err2 = Run(opts2); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("--yes run blocked on the vanilla-plus client-type prompt")
	}
	if err2 != nil {
		t.Fatalf("Run (--yes): %v", err2)
	}
	if res2.ClientType != ClientTypeLegacy {
		t.Fatalf("--yes must default a vanilla-plus stamp to legacy, got %q", res2.ClientType)
	}
}

// --client-type beats every detection (here: the WowClassic.exe name and a
// Classic Era stamp both say era; the flag forces legacy) and is persisted
// with the game like a prompted answer.
func TestClientTypeFlagBeatsDetection(t *testing.T) {
	dir := makeGameDir(t, GameExeName, false)
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, confirms: []bool{true}} // create Config.wtf only
	storeDir := t.TempDir()
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)
	opts.GameExeFlag = filepath.Join(dir, GameExeName)
	opts.ClientTypeFlag = ClientTypeLegacy
	opts.versionProbe = func(string) (GameVersion, bool) { return GameVersion{Major: 1, Minor: 15}, true }

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v\n%s", err, opts.Out.(*bytes.Buffer).String())
	}
	if res.ClientType != ClientTypeLegacy {
		t.Fatalf("--client-type legacy must beat the era detection: %+v", res)
	}
	if _, err := os.Stat(filepath.Join(dir, "Interface", "AddOns", "WowMobile_Vanilla", "WowMobile_Vanilla.toc")); err != nil {
		t.Fatalf("forced legacy type must install the vanilla addon: %v", err)
	}
	after := LoadStore(storeDir)
	if after.Get(KeyClientType) != string(ClientTypeLegacy) {
		t.Fatalf("--client-type not persisted: %q", after.Get(KeyClientType))
	}
	if !strings.Contains(opts.Out.(*bytes.Buffer).String(), "client type forced to 1.12-era client (--client-type)") {
		t.Fatalf("forced type not logged:\n%s", opts.Out.(*bytes.Buffer).String())
	}
}

// migrationStore seeds the persisted state releases <= 0.3.2 left behind for
// a vanilla-plus client: exe recorded and chosen, classified classicEra by
// the old >=1.13 stamp rule.
func migrationStore(t *testing.T, exe string) string {
	t.Helper()
	storeDir := t.TempDir()
	store := LoadStore(storeDir)
	store.Set(KeyGameExe, exe)
	store.Set(KeyClientType, string(ClientTypeClassicEra))
	store.Set(KeyGameChosen, "1")
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}
	return storeDir
}

// The bad-classification migration: a remembered classicEra for a
// vanilla-plus-stamped custom exe is re-resolved once at wizard time; on the
// corrected answer the 1.12 addon is installed AND the wrongly installed
// Classic Era addon is removed from AddOns (verified as ours first).
func TestVanillaPlusMigrationReclassifiesAndRemovesWrongAddon(t *testing.T) {
	dir := makeGameDir(t, "OctoWow.exe", true) // legacy Config.wtf pre-satisfied
	exe := filepath.Join(dir, "OctoWow.exe")
	// The prior (misclassified) run installed the Classic Era addon.
	src := addonSrc()
	wrongDir := filepath.Join(dir, "Interface", "AddOns", "WowMobile")
	if err := ApplyAddon(src, wrongDir, mustPlan(t, src, wrongDir)); err != nil {
		t.Fatal(err)
	}
	storeDir := migrationStore(t, exe)

	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, confirms: []bool{false}} // re-ask: No -> 1.12 engine
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)
	opts.versionProbe = func(string) (GameVersion, bool) { return GameVersion{Major: 1, Minor: 18}, true }

	res, err := Run(opts)
	out := opts.Out.(*bytes.Buffer).String()
	if err != nil {
		t.Fatalf("Run: %v\n%s", err, out)
	}
	if res.GameExe != exe || res.ClientType != ClientTypeLegacy {
		t.Fatalf("migration must correct the type to legacy: %+v", res)
	}
	if _, err := os.Stat(wrongDir); !os.IsNotExist(err) {
		t.Fatalf("wrongly installed Classic Era addon not removed (err=%v)", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "Interface", "AddOns", "WowMobile_Vanilla", "WowMobile_Vanilla.toc")); err != nil {
		t.Fatalf("correct 1.12 addon not installed: %v", err)
	}
	for _, want := range []string{
		"corrected to 1.12-era client",
		"removed the wrongly installed WowMobile",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("migration report missing %q:\n%s", want, out)
		}
	}
	after := LoadStore(storeDir)
	if after.Get(KeyClientType) != string(ClientTypeLegacy) || after.Get(KeyVanillaPlusResolvedFor) != exe {
		t.Fatalf("migration outcome not persisted: type=%q resolved=%q",
			after.Get(KeyClientType), after.Get(KeyVanillaPlusResolvedFor))
	}

	// Second run: settled — the persisted legacy answer is reused silently.
	sys2 := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	opts2 := baseOpts(t, "", sys2, &scriptPrompter{t: t})
	opts2.Store = LoadStore(storeDir)
	opts2.versionProbe = func(string) (GameVersion, bool) { return GameVersion{Major: 1, Minor: 18}, true }
	res2, err := Run(opts2)
	if err != nil {
		t.Fatalf("second Run: %v", err)
	}
	if res2.ClientType != ClientTypeLegacy {
		t.Fatalf("corrected type not reused: %+v", res2)
	}
}

// The migration asks once and respects a user who INSISTS on Classic Era:
// the answer is recorded (KeyVanillaPlusResolvedFor), nothing is removed,
// and later runs never re-ask.
func TestVanillaPlusMigrationUserKeepsEra(t *testing.T) {
	dir := makeGameDir(t, "OctoWow.exe", true)
	exe := filepath.Join(dir, "OctoWow.exe")
	// Era Config.wtf so no config prompt interferes.
	if err := os.WriteFile(filepath.Join(dir, "WTF", "Config.wtf"),
		FreshConfig(PortraitSettingsFor(ClientTypeClassicEra, 1080, 1920)), 0o644); err != nil {
		t.Fatal(err)
	}
	src := addonSrc()
	eraDir := filepath.Join(dir, "Interface", "AddOns", "WowMobile")
	if err := ApplyAddon(src, eraDir, mustPlan(t, src, eraDir)); err != nil {
		t.Fatal(err)
	}
	storeDir := migrationStore(t, exe)
	probe := func(string) (GameVersion, bool) { return GameVersion{Major: 1, Minor: 18}, true }

	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, confirms: []bool{true}} // re-ask: Yes -> keep era
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)
	opts.versionProbe = probe
	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v\n%s", err, opts.Out.(*bytes.Buffer).String())
	}
	if res.ClientType != ClientTypeClassicEra {
		t.Fatalf("insisted era answer not honored: %+v", res)
	}
	if _, err := os.Stat(filepath.Join(eraDir, "WowMobile.toc")); err != nil {
		t.Fatalf("era addon must stay installed: %v", err)
	}
	if LoadStore(storeDir).Get(KeyVanillaPlusResolvedFor) != exe {
		t.Fatal("insisted answer must be marked resolved so it is never re-asked")
	}

	// Second run: zero prompts.
	sys2 := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	opts2 := baseOpts(t, "", sys2, &scriptPrompter{t: t})
	opts2.Store = LoadStore(storeDir)
	opts2.versionProbe = probe
	if res2, err := Run(opts2); err != nil || res2.ClientType != ClientTypeClassicEra {
		t.Fatalf("settled era answer not reused silently: %+v err=%v", res2, err)
	}
}

// The migration's cleanup must never delete a WowMobile folder this app did
// not install: a TOC without the ownership marker is left byte-for-byte
// alone, reported plainly.
func TestVanillaPlusMigrationLeavesForeignFolder(t *testing.T) {
	dir := makeGameDir(t, "OctoWow.exe", true)
	exe := filepath.Join(dir, "OctoWow.exe")
	foreign := filepath.Join(dir, "Interface", "AddOns", "WowMobile")
	if err := os.MkdirAll(foreign, 0o755); err != nil {
		t.Fatal(err)
	}
	foreignTOC := []byte("## Title: Not Ours\n")
	if err := os.WriteFile(filepath.Join(foreign, "WowMobile.toc"), foreignTOC, 0o644); err != nil {
		t.Fatal(err)
	}
	storeDir := migrationStore(t, exe)

	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, confirms: []bool{false}} // re-ask: No -> legacy
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)
	opts.versionProbe = func(string) (GameVersion, bool) { return GameVersion{Major: 1, Minor: 18}, true }

	if _, err := Run(opts); err != nil {
		t.Fatalf("Run: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(foreign, "WowMobile.toc"))
	if err != nil || !bytes.Equal(data, foreignTOC) {
		t.Fatalf("foreign folder touched: %q err=%v", data, err)
	}
	if !strings.Contains(opts.Out.(*bytes.Buffer).String(), "untouched") {
		t.Fatalf("foreign-folder outcome not reported:\n%s", opts.Out.(*bytes.Buffer).String())
	}
}

// --yes with an unrecognized exe must not guess Classic Era: outside a
// _classic_era_ tree the logged default is legacy.
func TestYesUnknownExeDefaultsLegacy(t *testing.T) {
	dir := makeGameDir(t, "CustomServer.exe", true)
	exe := filepath.Join(dir, "CustomServer.exe")
	sys := &fakeSys{pathFFmpeg: "ff", windowPresent: true}
	p := NewConsolePrompter(blockingReader{}, io.Discard, true, true)
	opts := baseOpts(t, "", sys, p)
	opts.GameExeFlag = exe
	opts.Yes = true
	out := opts.Out.(*bytes.Buffer)

	done := make(chan *Result, 1)
	errCh := make(chan error, 1)
	go func() {
		res, err := Run(opts)
		done <- res
		errCh <- err
	}()
	select {
	case res := <-done:
		if err := <-errCh; err != nil {
			t.Fatalf("Run: %v\n%s", err, out.String())
		}
		if res.ClientType != ClientTypeLegacy {
			t.Fatalf("--yes guessed %q for unknown exe; must default legacy", res.ClientType)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("--yes run blocked on the client-type prompt")
	}
	if !strings.Contains(out.String(), "treating it as a 1.12-era client") {
		t.Fatalf("client-type default not logged:\n%s", out.String())
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
	// The "is WoW running" guard must have asked about THIS install's window
	// only — an unrelated install running must not trigger the wait prompt.
	for _, dir := range sys.presentDirs {
		if dir != wow {
			t.Errorf("Config.wtf guard checked install dir %q, want the chosen %q", dir, wow)
		}
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
	stepLine(&b, 4, "FFmpeg", "found: h264_nvenc available")
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

func TestRememberedGameExeIgnoresStaleWowPathUnderMarker(t *testing.T) {
	store := LoadStore(t.TempDir())
	// A pre-picker upgrade scenario: the user's explicit choice (marker set)
	// whose exe has since vanished, alongside a stale auto-detected wow_path
	// pointing at a different, never-confirmed install. The fast path must
	// NOT silently substitute the stale install — it must return "" so the
	// wizard falls through to a fresh scan-and-ask.
	staleDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(staleDir, "WowClassic.exe"), []byte("mz"), 0o644); err != nil {
		t.Fatal(err)
	}
	store.Set(KeyGameChosen, "1")
	store.Set(KeyGameExe, filepath.Join(t.TempDir(), "gone", "WowClassic.exe"))
	store.Set(KeyWowPath, staleDir)
	opts := &Options{Store: store}
	if got := rememberedGameExe(opts); got != "" {
		t.Fatalf("rememberedGameExe = %q, want \"\": a stale wow_path must never stand in for a vanished explicit choice", got)
	}
}

// --- monitor-fit resolution (resolveResolution) -----------------------------

// --resolution fit: the wizard measures the work area, computes the largest
// 9:16 client area, feeds it to every consumer (Result + Config.wtf), prints
// it plainly, and persists it.
func TestResolutionFitComputedFromWorkArea(t *testing.T) {
	wow := makeWowDir(t, false)
	sys := &fakeSys{pathFFmpeg: "/usr/bin/ffmpeg", windowPresent: true,
		workW: 1920, workH: 1032} // 1080p monitor with a 48 px taskbar
	p := &scriptPrompter{t: t, confirms: []bool{true}} // create Config.wtf
	opts := baseOpts(t, wow, sys, p)
	opts.ResolutionFit = true
	opts.Width, opts.Height = 0, 0
	out := opts.Out.(*bytes.Buffer)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v\n%s", err, out.String())
	}
	// FitPortraitClient(1920, 1032, 16, 48) = 552x984 (see window/fit_test.go).
	if res.Width != 552 || res.Height != 984 {
		t.Fatalf("fitted resolution = %dx%d, want 552x984", res.Width, res.Height)
	}
	if !strings.Contains(out.String(), "portrait window 552x984 — the largest 9:16 window that fits your 1920x1032 work area") {
		t.Fatalf("fit not announced plainly:\n%s", out.String())
	}
	cfg, err := os.ReadFile(filepath.Join(wow, "WTF", "Config.wtf"))
	if err != nil || !SettingsSatisfied(cfg, PortraitSettings(552, 984)) {
		t.Fatalf("Config.wtf not written with the fitted resolution: %q err=%v", cfg, err)
	}
	if got := opts.Store.Get(KeyResolution); got != "552x984" {
		t.Fatalf("fitted resolution not persisted: %q", got)
	}
}

// A 4K monitor (the field-reported hardware) holds the 1080x1920 design
// window with room to spare: fit must yield EXACTLY the design resolution —
// larger only raises encode cost with zero phone benefit — and the printout
// must say the cap is deliberate.
func TestResolutionFitCappedAtDesignOn4K(t *testing.T) {
	wow := makeWowDir(t, false)
	sys := &fakeSys{pathFFmpeg: "/usr/bin/ffmpeg", windowPresent: true,
		workW: 3840, workH: 2112} // 4K with a 48 px taskbar
	p := &scriptPrompter{t: t, confirms: []bool{true}} // create Config.wtf
	opts := baseOpts(t, wow, sys, p)
	opts.ResolutionFit = true
	opts.Width, opts.Height = 0, 0
	out := opts.Out.(*bytes.Buffer)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v\n%s", err, out.String())
	}
	if res.Width != 1080 || res.Height != 1920 {
		t.Fatalf("4K fit = %dx%d, want exactly the 1080x1920 design cap", res.Width, res.Height)
	}
	if !strings.Contains(out.String(), "portrait window 1080x1920 (the design resolution — fits your 3840x2112 work area with room to spare)") {
		t.Fatalf("capped fit not announced plainly:\n%s", out.String())
	}
	cfg, err := os.ReadFile(filepath.Join(wow, "WTF", "Config.wtf"))
	if err != nil || !SettingsSatisfied(cfg, PortraitSettings(1080, 1920)) {
		t.Fatalf("Config.wtf not written with the capped resolution: %q err=%v", cfg, err)
	}
}

// DPI-scaled decorations: WindowDecorationExtents answers for the monitor's
// CURRENT DPI (AdjustWindowRectExForDpi — see sys_windows.go), so on a
// 125-150%-scaled display the frame is ~20x60 to ~24x72, not the 100%-scale
// 16x48. The fitted client area plus those REAL extents must still sit inside
// the work area — an under-measured frame is exactly the silent
// deck-rows-behind-the-taskbar bug (the client area still matches the
// configured size, so no mismatch warning ever fires).
func TestResolutionFitScaledDecorationsStayInsideWorkArea(t *testing.T) {
	cases := []struct {
		name                         string
		workW, workH, decorW, decorH int
	}{
		{"1080p laptop at 150%", 1920, 1032, 24, 72},
		{"1440p at 125%", 2560, 1380, 20, 60},
		{"4K at 150% (mid-session scale change)", 3840, 2088, 24, 72},
	}
	for _, tc := range cases {
		sys := &fakeSys{workW: tc.workW, workH: tc.workH, decorW: tc.decorW, decorH: tc.decorH}
		p := &scriptPrompter{t: t}
		opts := baseOpts(t, "", sys, p)
		opts.ResolutionFit = true
		opts.Width, opts.Height = 0, 0
		if err := resolveResolution(&opts); err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if opts.Width <= 0 || opts.Height <= 0 {
			t.Fatalf("%s: no resolution resolved", tc.name)
		}
		if opts.Width+tc.decorW > tc.workW || opts.Height+tc.decorH > tc.workH {
			t.Errorf("%s: fitted client %dx%d + real frame %dx%d overshoots the %dx%d work area (taskbar overlap)",
				tc.name, opts.Width, opts.Height, tc.decorW, tc.decorH, tc.workW, tc.workH)
		}
	}
}

// Declining to keep an oversized explicit resolution when NO fitting
// alternative exists keeps the value out of necessity — and must say so
// honestly instead of claiming the user "confirmed" what they declined.
func TestResolutionExplicitOversizedDeclineNoAlternative(t *testing.T) {
	sys := &fakeSys{workW: 300, workH: 400}             // too small for even a 270x480 fit
	p := &scriptPrompter{t: t, confirms: []bool{false}} // keep it anyway? -> no
	opts := baseOpts(t, "", sys, p)
	out := opts.Out.(*bytes.Buffer)

	if err := resolveResolution(&opts); err != nil {
		t.Fatal(err)
	}
	if opts.Width != 1080 || opts.Height != 1920 {
		t.Fatalf("with no alternative the explicit value must stand, got %dx%d", opts.Width, opts.Height)
	}
	text := out.String()
	if !strings.Contains(text, "no fitting portrait window exists for this monitor; keeping --resolution 1080x1920 — expect a cut-off window") {
		t.Fatalf("declined keep without an alternative must be reported honestly:\n%s", text)
	}
	if strings.Contains(text, "as confirmed") {
		t.Fatalf("nothing was confirmed — the message must not claim it was:\n%s", text)
	}
}

// An explicit --resolution that cannot fit the monitor warns loudly, names
// the fitted alternative, and — on a declined keep — switches to it.
func TestResolutionExplicitOversizedSwitchesOnDecline(t *testing.T) {
	wow := makeWowDir(t, false)
	sys := &fakeSys{pathFFmpeg: "/usr/bin/ffmpeg", windowPresent: true,
		workW: 1920, workH: 1032}
	// Confirm #1: keep the oversized value? -> no. #2: create Config.wtf.
	p := &scriptPrompter{t: t, confirms: []bool{false, true}}
	opts := baseOpts(t, wow, sys, p) // Width/Height = 1080x1920 explicit
	out := opts.Out.(*bytes.Buffer)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v\n%s", err, out.String())
	}
	text := out.String()
	if !strings.Contains(text, "WARNING: --resolution 1080x1920 cannot fit your 1920x1032 work area") {
		t.Fatalf("missing loud warning:\n%s", text)
	}
	if !strings.Contains(text, "552x984") {
		t.Fatalf("warning must name the fitted alternative:\n%s", text)
	}
	if res.Width != 552 || res.Height != 984 {
		t.Fatalf("declined keep must switch to the fit, got %dx%d", res.Width, res.Height)
	}
}

// --yes keeps the explicit flag value (logged), never silently substituting.
func TestResolutionExplicitOversizedYesKeeps(t *testing.T) {
	wow := makeWowDir(t, true) // Config.wtf pre-satisfied at 1080x1920
	sys := &fakeSys{pathFFmpeg: "/usr/bin/ffmpeg", windowPresent: true,
		workW: 1920, workH: 1032}
	p := &scriptPrompter{t: t} // no prompts allowed under --yes
	opts := baseOpts(t, wow, sys, p)
	opts.Yes = true
	out := opts.Out.(*bytes.Buffer)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v\n%s", err, out.String())
	}
	if res.Width != 1080 || res.Height != 1920 {
		t.Fatalf("--yes must keep the explicit resolution, got %dx%d", res.Width, res.Height)
	}
	if !strings.Contains(out.String(), "keeping --resolution 1080x1920 (--yes") {
		t.Fatalf("--yes keep not logged:\n%s", out.String())
	}
}

// An explicit resolution that fits is used silently — no warning, no prompt.
func TestResolutionExplicitFittingIsSilent(t *testing.T) {
	wow := makeGameDir(t, GameExeName, false)
	if err := os.MkdirAll(filepath.Join(wow, "WTF"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(wow, "WTF", "Config.wtf"),
		FreshConfig(PortraitSettings(540, 960)), 0o644); err != nil {
		t.Fatal(err)
	}
	sys := &fakeSys{pathFFmpeg: "/usr/bin/ffmpeg", windowPresent: true,
		workW: 1920, workH: 1032}
	p := &scriptPrompter{t: t} // any prompt fails the test
	opts := baseOpts(t, wow, sys, p)
	opts.Width, opts.Height = 540, 960

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Width != 540 || res.Height != 960 {
		t.Fatalf("fitting explicit resolution changed: %dx%d", res.Width, res.Height)
	}
	if strings.Contains(opts.Out.(*bytes.Buffer).String(), "WARNING") {
		t.Fatalf("fitting resolution must not warn:\n%s", opts.Out.(*bytes.Buffer).String())
	}
}

// Fit with an unmeasurable monitor: the persisted previous fit wins, then the
// 1080x1920 design default.
func TestResolutionFitUnmeasurableFallsBack(t *testing.T) {
	sys := &fakeSys{} // workW/workH zero: not measurable
	p := &scriptPrompter{t: t}
	opts := baseOpts(t, "", sys, p)
	opts.ResolutionFit = true
	opts.Width, opts.Height = 0, 0
	if err := resolveResolution(&opts); err != nil {
		t.Fatal(err)
	}
	if opts.Width != 1080 || opts.Height != 1920 {
		t.Fatalf("design fallback wrong: %dx%d", opts.Width, opts.Height)
	}

	opts2 := baseOpts(t, "", sys, p)
	opts2.ResolutionFit = true
	opts2.Width, opts2.Height = 0, 0
	opts2.Store.Set(KeyResolution, "600x1066")
	if err := resolveResolution(&opts2); err != nil {
		t.Fatal(err)
	}
	if opts2.Width != 600 || opts2.Height != 1066 {
		t.Fatalf("persisted fit fallback wrong: %dx%d", opts2.Width, opts2.Height)
	}
}
