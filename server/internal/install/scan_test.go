package install

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// buildTree creates a fake "World of Warcraft" root with the given product
// subdirs, each containing the named exe, and returns the root.
func buildTree(t *testing.T, products map[string]string) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "World of Warcraft")
	for product, exe := range products {
		dir := filepath.Join(root, product)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, exe), []byte("MZ"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// The scanner assembles from every source kind, enumerates Battle.net
// product dirs under roots in preference order (Classic Era first), dedupes
// by cleaned case-insensitive path, and labels each candidate.
func TestAssembleCandidatesDedupeOrderAndLabels(t *testing.T) {
	root := buildTree(t, map[string]string{
		"_retail_":      "Wow.exe",
		"_classic_era_": "WowClassic.exe",
		"_ptr_":         "Wow.exe",
	})
	private := makeGameDir(t, "VanillaFixes.exe", false)
	classicEraExe := filepath.Join(root, "_classic_era_", "WowClassic.exe")
	retailExe := filepath.Join(root, "_retail_", "Wow.exe")
	ptrExe := filepath.Join(root, "_ptr_", "Wow.exe")
	privateExe := filepath.Join(private, "VanillaFixes.exe")
	unknown := makeGameDir(t, "MysteryLauncher.exe", false)
	unknownExe := filepath.Join(unknown, "MysteryLauncher.exe")

	versions := map[string]GameVersion{
		classicEraExe: {Major: 1, Minor: 15},
		retailExe:     {Major: 11, Minor: 2},
		// ptrExe and privateExe deliberately unstamped -> heuristics.
	}
	probe := func(exe string) (GameVersion, bool) {
		v, ok := versions[exe]
		return v, ok
	}

	src := GameScanSources{
		// The persisted exe is FIRST and also reachable through the root —
		// the duplicate (with redundant path elements and different casing
		// in the exe name) must collapse onto the persisted entry.
		Exes:  []string{filepath.Join(root, "_classic_era_", ".", "WowClassic.exe")},
		Dirs:  []string{private},
		Roots: []string{root},
	}
	cands := assembleCandidates(src, probe)

	wantExes := []string{classicEraExe, privateExe, retailExe, ptrExe}
	if len(cands) != len(wantExes) {
		t.Fatalf("want %d candidates, got %+v", len(wantExes), cands)
	}
	for i, want := range wantExes {
		if cands[i].ExePath != want {
			t.Errorf("candidate %d: want %s, got %s", i, want, cands[i].ExePath)
		}
	}

	wantLabels := []string{
		"WoW Classic Era (1.15) — " + filepath.Join(root, "_classic_era_"),
		"Vanilla 1.12 private client — " + private,
		"Retail 11.x — " + filepath.Join(root, "_retail_") + " (stream only: touch UI addon unavailable)",
		// _ptr_\Wow.exe is unstamped and outside a _classic_era_ tree: the
		// name heuristic calls it a vanilla client, honestly reflecting what
		// the wizard would do with it.
		"Vanilla 1.12 private client — " + filepath.Join(root, "_ptr_"),
	}
	for i, want := range wantLabels {
		if cands[i].Label != want {
			t.Errorf("label %d:\nwant %q\ngot  %q", i, want, cands[i].Label)
		}
	}
	if cands[0].Type != ClientTypeClassicEra || cands[1].Type != ClientTypeLegacy {
		t.Fatalf("types wrong: %+v", cands)
	}
	if cands[2].Type != "" {
		t.Fatalf("retail 11.x must stay unclassified in the scan, got %q", cands[2].Type)
	}

	// An unidentifiable exe labels with its full path so twins stay
	// distinguishable.
	unkCands := assembleCandidates(GameScanSources{Exes: []string{unknownExe}}, probe)
	if len(unkCands) != 1 || unkCands[0].Label != "World of Warcraft (version unknown) — "+unknownExe {
		t.Fatalf("unknown label wrong: %+v", unkCands)
	}
	if unkCands[0].Type != "" || unkCands[0].Version != (GameVersion{}) {
		t.Fatalf("unknown candidate must have zero version and type: %+v", unkCands[0])
	}
}

// Vanilla-plus stamps (1.16+ — Turtle 1.17, OctoWow 1.18) are inconclusive:
// the scanner classifies through the name heuristics like an unstamped exe,
// and the labels say what was found instead of pretending Classic Era.
func TestAssembleCandidatesVanillaPlusStamps(t *testing.T) {
	turtle := makeGameDir(t, "Wow.exe", false)
	turtleExe := filepath.Join(turtle, "Wow.exe")
	octo := makeGameDir(t, "OctoWow.exe", false)
	octoExe := filepath.Join(octo, "OctoWow.exe")
	versions := map[string]GameVersion{
		turtleExe: {Major: 1, Minor: 17},
		octoExe:   {Major: 1, Minor: 18},
	}
	probe := func(exe string) (GameVersion, bool) {
		v, ok := versions[exe]
		return v, ok
	}

	cands := assembleCandidates(GameScanSources{Exes: []string{turtleExe, octoExe}}, probe)
	if len(cands) != 2 {
		t.Fatalf("want 2 candidates, got %+v", cands)
	}
	// Wow.exe: the name heuristic settles it — legacy, engine named honestly.
	if cands[0].Type != ClientTypeLegacy {
		t.Errorf("1.17-stamped Wow.exe must classify legacy via heuristics, got %q", cands[0].Type)
	}
	if want := "Vanilla-plus 1.17 custom client (1.12 engine) — " + turtle; cands[0].Label != want {
		t.Errorf("turtle label:\nwant %q\ngot  %q", want, cands[0].Label)
	}
	// OctoWow.exe: no heuristic knows the name — unclassified (the wizard
	// asks), but the label still reports the stamp and the real engine.
	if cands[1].Type != "" {
		t.Errorf("1.18-stamped unknown exe must stay unclassified in the scan, got %q", cands[1].Type)
	}
	if want := "Vanilla-plus 1.18 custom client (1.12 engine) — " + octoExe; cands[1].Label != want {
		t.Errorf("octo label:\nwant %q\ngot  %q", want, cands[1].Label)
	}
}

func TestClientTypeForModernMajor(t *testing.T) {
	cases := []struct {
		v    GameVersion
		want ClientType
	}{
		{GameVersion{Major: 2, Minor: 4}, ClientTypeLegacy}, // TBC: pre-gxWindowedResolution
		{GameVersion{Major: 3, Minor: 3}, ClientTypeLegacy}, // WotLK
		{GameVersion{Major: 8, Minor: 0}, ClientTypeClassicEra},
		{GameVersion{Major: 11, Minor: 2}, ClientTypeClassicEra}, // retail
	}
	for _, c := range cases {
		if got := clientTypeForModernMajor(c.v); got != c.want {
			t.Errorf("clientTypeForModernMajor(%d.%d) = %q, want %q", c.v.Major, c.v.Minor, got, c.want)
		}
	}
}

// ScanGameCandidates pulls the persisted exe, registry (base and product
// subdirs), well-known dirs, and install roots together.
func TestScanGameCandidatesSources(t *testing.T) {
	regRoot := buildTree(t, map[string]string{"_classic_era_": "WowClassic.exe"})
	private := makeGameDir(t, "Wow.exe", false)
	storeDir := t.TempDir()
	store := LoadStore(storeDir)
	store.Set(KeyGameExe, filepath.Join(private, "Wow.exe"))
	sys := &fakeSys{registry: regRoot}

	cands := ScanGameCandidates(store, sys)
	if len(cands) != 2 {
		t.Fatalf("want persisted + registry candidates, got %+v", cands)
	}
	if cands[0].ExePath != filepath.Join(private, "Wow.exe") {
		t.Fatalf("persisted exe must come first (picker default): %+v", cands)
	}
	if cands[1].ExePath != filepath.Join(regRoot, "_classic_era_", "WowClassic.exe") {
		t.Fatalf("registry product dir not scanned: %+v", cands)
	}
}

// A single find still asks — never auto-proceed, even with exactly one
// candidate (the v0.2.0 field report: four installs, wrong one grabbed).
func TestSingleCandidateStillShowsPicker(t *testing.T) {
	wow := makeWowDir(t, true)
	sys := &fakeSys{wellKnown: []string{wow}, pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, chooses: []scriptChoice{{sel: GameSelection{Index: 0}}}}
	opts := baseOpts(t, "", sys, p)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.GameExe != filepath.Join(wow, GameExeName) {
		t.Fatalf("candidate not used: %q", res.GameExe)
	}
	if len(p.offered) != 1 {
		t.Fatalf("picker must be shown exactly once for a single candidate: %v", p.asked)
	}
	text := opts.Out.(*bytes.Buffer).String()
	if !strings.Contains(text, "chosen: "+res.GameExe+" (Classic Era) — from 1 found") {
		t.Fatalf("step line must report the choice:\n%s", text)
	}
}

// Multiple installs: the picker lists all of them and the user's pick (not
// the first found) wins.
func TestPickerChoosesSecondInstall(t *testing.T) {
	first := makeWowDir(t, true)
	second := makeGameDir(t, "Wow.exe", true) // 1.12 private client
	sys := &fakeSys{wellKnown: []string{first, second}, pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, chooses: []scriptChoice{{sel: GameSelection{Index: 1}}}}
	storeDir := t.TempDir()
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.GameExe != filepath.Join(second, "Wow.exe") || res.ClientType != ClientTypeLegacy {
		t.Fatalf("second candidate not chosen: %+v", res)
	}
	if len(p.offered) != 1 || len(p.offered[0]) != 2 {
		t.Fatalf("picker must list both installs: %+v", p.offered)
	}
	text := opts.Out.(*bytes.Buffer).String()
	if !strings.Contains(text, "— from 2 found") {
		t.Fatalf("step line must report the scan size:\n%s", text)
	}
	if got := LoadStore(storeDir).Get(KeyGameExe); got != res.GameExe {
		t.Fatalf("choice not persisted: %q", got)
	}
}

// The picker's browse escape hatch drops into the manual SelectGamePath flow.
func TestPickerBrowseFallsBackToManualPath(t *testing.T) {
	found := makeWowDir(t, true)
	manual := makeGameDir(t, "VanillaFixes.exe", true)
	sys := &fakeSys{wellKnown: []string{found}, pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t,
		chooses: []scriptChoice{{sel: GameSelection{Index: -1, Browse: true}}},
		asks:    []string{manual},
	}
	opts := baseOpts(t, "", sys, p)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.GameExe != filepath.Join(manual, "VanillaFixes.exe") {
		t.Fatalf("browsed path not used: %+v", res)
	}
	text := opts.Out.(*bytes.Buffer).String()
	if strings.Contains(text, "from 1 found") {
		t.Fatalf("a manually browsed path must not claim to be a scan pick:\n%s", text)
	}
}

// A picker-returned path (GUI folder/exe dialogs) is validated; an invalid
// one re-prompts via SelectGamePath with the cleaned previous answer.
func TestPickerPathValidatedWithRetry(t *testing.T) {
	found := makeWowDir(t, true)
	manual := makeWowDir(t, true)
	sys := &fakeSys{wellKnown: []string{found}, pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t,
		chooses: []scriptChoice{{sel: GameSelection{Index: -1, Path: filepath.Join(t.TempDir(), "empty")}}},
		asks:    []string{manual},
	}
	opts := baseOpts(t, "", sys, p)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.GameExe != filepath.Join(manual, GameExeName) {
		t.Fatalf("retry path not used: %+v", res)
	}
}

// Cancelling the picker stops setup cleanly.
func TestPickerCancelStopsSetup(t *testing.T) {
	wow := makeWowDir(t, true)
	sys := &fakeSys{wellKnown: []string{wow}, pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, chooses: []scriptChoice{{err: ErrGameChoiceCancelled}}}
	opts := baseOpts(t, "", sys, p)

	_, err := Run(opts)
	if err == nil || !strings.Contains(err.Error(), "cancelled") {
		t.Fatalf("expected clean cancel error, got %v", err)
	}
}

// --choose-game forces the picker even over a valid remembered choice, and
// the remembered install is the first (default) candidate.
func TestChooseGameFlagForcesPicker(t *testing.T) {
	remembered := makeWowDir(t, true)
	other := makeGameDir(t, "Wow.exe", true)
	storeDir := t.TempDir()
	store := LoadStore(storeDir)
	store.Set(KeyGameExe, filepath.Join(remembered, GameExeName))
	store.Set(KeyClientType, string(ClientTypeClassicEra))
	store.Set(KeyGameChosen, "1") // an explicitly confirmed prior choice
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}
	sys := &fakeSys{wellKnown: []string{other}, pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t, chooses: []scriptChoice{{sel: GameSelection{Index: 1}}}}
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)
	opts.ChooseGame = true

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(p.offered) != 1 || len(p.offered[0]) != 2 {
		t.Fatalf("picker must list remembered + scanned installs: %+v", p.offered)
	}
	if p.offered[0][0].ExePath != filepath.Join(remembered, GameExeName) {
		t.Fatalf("remembered install must be the picker default: %+v", p.offered[0])
	}
	if res.GameExe != filepath.Join(other, "Wow.exe") {
		t.Fatalf("new choice not applied: %+v", res)
	}
	if got := LoadStore(storeDir).Get(KeyGameExe); got != res.GameExe {
		t.Fatalf("new choice not persisted: %q", got)
	}
}

// Without --choose-game, a valid remembered EXPLICIT choice (carrying the
// game_chosen marker) never prompts (fast path).
func TestRememberedChoiceSkipsPicker(t *testing.T) {
	remembered := makeWowDir(t, true)
	other := makeGameDir(t, "Wow.exe", true)
	storeDir := t.TempDir()
	store := LoadStore(storeDir)
	store.Set(KeyGameExe, filepath.Join(remembered, GameExeName))
	store.Set(KeyClientType, string(ClientTypeClassicEra))
	store.Set(KeyGameChosen, "1")
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}
	// Make sure the addon is already in place so no prompt fires at all.
	dest := filepath.Join(remembered, "Interface", "AddOns", "WowMobile")
	src := addonSrc()
	if err := ApplyAddon(src, dest, mustPlan(t, src, dest)); err != nil {
		t.Fatal(err)
	}
	sys := &fakeSys{wellKnown: []string{other}, pathFFmpeg: "ff", windowPresent: true}
	p := &scriptPrompter{t: t} // zero scripted answers: any prompt fails
	opts := baseOpts(t, "", sys, p)
	opts.Store = LoadStore(storeDir)

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.GameExe != filepath.Join(remembered, GameExeName) {
		t.Fatalf("remembered choice not used silently: %+v", res)
	}
}

// --yes with several installs refuses to guess: the error lists every
// candidate and points at --game-exe.
func TestYesMultiCandidateRefuses(t *testing.T) {
	first := makeWowDir(t, true)
	second := makeGameDir(t, "Wow.exe", true)
	sys := &fakeSys{wellKnown: []string{first, second}, pathFFmpeg: "ff", windowPresent: true}
	p := NewConsolePrompter(blockingReader{}, io.Discard, true, true)
	opts := baseOpts(t, "", sys, p)
	opts.Yes = true

	_, err := Run(opts)
	if err == nil {
		t.Fatal("--yes must not guess between 2 installs")
	}
	msg := err.Error()
	for _, want := range []string{"2 World of Warcraft installs", "--game-exe",
		"WoW Classic Era — " + first, "Vanilla 1.12 private client — " + second} {
		if !strings.Contains(msg, want) {
			t.Errorf("refusal error missing %q:\n%s", want, msg)
		}
	}
}

// --yes with exactly one install uses it without prompting.
func TestYesSingleCandidateUsed(t *testing.T) {
	wow := makeWowDir(t, true)
	sys := &fakeSys{wellKnown: []string{wow}, pathFFmpeg: "ff", windowPresent: true}
	p := NewConsolePrompter(blockingReader{}, io.Discard, true, true)
	opts := baseOpts(t, "", sys, p)
	opts.Yes = true

	res, err := Run(opts)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.GameExe != filepath.Join(wow, GameExeName) {
		t.Fatalf("sole candidate not used under --yes: %+v", res)
	}
}

// Console picker: numbered choice, default on Enter, cancel on EOF (never a
// silent pick), browse, cancel, and re-ask on junk.
func TestConsoleChooseGame(t *testing.T) {
	cands := []GameCandidate{
		{ExePath: `C:\a\WowClassic.exe`, Label: "A"},
		{ExePath: `C:\b\Wow.exe`, Label: "B"},
	}
	run := func(input string) (GameSelection, error, string) {
		var out bytes.Buffer
		p := NewConsolePrompter(strings.NewReader(input), &out, true, false)
		sel, err := p.ChooseGame(cands)
		return sel, err, out.String()
	}

	if sel, err, _ := run("2\n"); err != nil || sel.Index != 1 {
		t.Fatalf("numbered pick: %+v %v", sel, err)
	}
	if sel, err, _ := run("\n"); err != nil || sel.Index != 0 {
		t.Fatalf("Enter must take the default: %+v %v", sel, err)
	}
	if _, err, _ := run(""); !errors.Is(err, ErrGameChoiceCancelled) {
		t.Fatalf("EOF must cancel — never hang, never silently pick and persist a candidate: %v", err)
	}
	if sel, err, _ := run("b\n"); err != nil || !sel.Browse {
		t.Fatalf("B must select browse: %+v %v", sel, err)
	}
	if _, err, _ := run("x\n"); !errors.Is(err, ErrGameChoiceCancelled) {
		t.Fatalf("X must cancel: %v", err)
	}
	if sel, err, out := run("9\nzz\n1\n"); err != nil || sel.Index != 0 ||
		!strings.Contains(out, "Please answer") {
		t.Fatalf("junk must re-ask then accept: %+v %v\n%s", sel, err, out)
	}
	// The menu itself lists every candidate and the escape hatches.
	_, _, out := run("1\n")
	for _, want := range []string{"1. A", "2. B", "B. Somewhere else", "X. Cancel"} {
		if !strings.Contains(out, want) {
			t.Errorf("menu missing %q:\n%s", want, out)
		}
	}

	// Non-interactive console sessions must fail, never block.
	p := NewConsolePrompter(blockingReader{}, io.Discard, false, false)
	if _, err := p.ChooseGame(cands); err == nil {
		t.Fatal("non-interactive ChooseGame must fail, not block")
	}
}
