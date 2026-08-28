// Install scanning: instead of stopping at the first game executable found,
// the wizard builds the complete list of WoW installs on the machine — the
// persisted choice, the Blizzard registry location, every Battle.net product
// directory (_classic_era_, _classic_, _retail_, and their _ptr_/_beta_
// variants) under every "World of Warcraft" folder at the well-known
// locations and fixed-drive roots — and lets the USER pick, because multi-
// install machines are common and guessing between installs picks wrong.
//
// The scan is bounded by construction: only known roots and one directory
// listing per root, never a recursive disk walk. Everything in this file is
// portable (plain os/filepath) so assembly, dedupe and labeling are
// unit-tested on every OS; the Windows-only enumeration of drive roots lives
// behind System.WowInstallRoots (sys_windows.go).
package install

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// GameCandidate is one discovered game install, ready for a picker.
type GameCandidate struct {
	ExePath string      // resolved game executable (existing file)
	Version GameVersion // PE FileVersion stamp; zero when absent/unreadable
	Type    ClientType  // classified type; "" when unknown
	Label   string      // human picker line, e.g. "WoW Classic Era (1.15) — C:\...\_classic_era_"
}

// GameSelection is the outcome of Prompter.ChooseGame: exactly one of the
// three fields is meaningful — a candidate index, a manually supplied path
// (folder or exe, still to be validated), or the wish to browse manually.
type GameSelection struct {
	Index  int    // >= 0: use the candidate at this index; pass -1 otherwise
	Path   string // non-empty: the user picked/pasted this folder or .exe instead
	Browse bool   // the user wants the manual browse flow (no path chosen yet)
}

// ErrGameChoiceCancelled is returned by Prompter.ChooseGame when the user
// dismissed the picker — the wizard then stops cleanly ("quit setup") instead
// of proceeding with a game the user never confirmed.
var ErrGameChoiceCancelled = errors.New("game selection cancelled")

// GameScanSources are the raw locations the scanner examines, in priority
// order (the persisted choice first, so it is the picker's default). Tests
// inject fake lists; ScanGameCandidates assembles the real ones.
type GameScanSources struct {
	Exes  []string // exact executables (the persisted game_exe)
	Dirs  []string // directories resolved with the full ResolveGameExe rules
	Roots []string // "World of Warcraft" base dirs; product subdirs are enumerated
}

// wowProductDirNames are the Battle.net per-product subdirectories of a
// "World of Warcraft" base folder, in preference order (the supported Classic
// Era client first, so it becomes the picker default on a multi-product
// install). Matched case-insensitively.
var wowProductDirNames = []string{
	"_classic_era_", "_classic_era_ptr_", "_classic_era_beta_",
	"_classic_", "_classic_ptr_", "_classic_beta_",
	"_retail_", "_ptr_", "_xptr_", "_beta_",
}

// isWowProductDirName reports whether name is a known Battle.net product
// subdirectory (any casing).
func isWowProductDirName(name string) bool {
	for _, p := range wowProductDirNames {
		if strings.EqualFold(name, p) {
			return true
		}
	}
	return false
}

// ScanGameCandidates builds the deduplicated candidate list from every
// zero-question source: the persisted game exe, the persisted (pre-upgrade)
// wow_path, the Blizzard registry, the well-known product dirs, and the
// product subdirs of every "World of Warcraft" root the system reports.
func ScanGameCandidates(store *Store, sys System) []GameCandidate {
	var src GameScanSources
	if exe := store.Get(KeyGameExe); exe != "" {
		if st, err := os.Stat(exe); err == nil && !st.IsDir() {
			src.Exes = append(src.Exes, exe)
		}
	}
	if dir := store.Get(KeyWowPath); dir != "" { // recorded by older versions
		src.Dirs = append(src.Dirs, dir)
	}
	if base, ok := sys.RegistryWowPath(); ok {
		// The registry value may point at the base "World of Warcraft" folder
		// or directly at a product dir: examine it as a dir either way, and as
		// a product root (its parent too, when it IS a product dir).
		src.Dirs = append(src.Dirs, base)
		src.Roots = append(src.Roots, base)
		if isWowProductDirName(filepath.Base(base)) {
			src.Roots = append(src.Roots, filepath.Dir(base))
		}
	}
	src.Dirs = append(src.Dirs, sys.WellKnownWowDirs()...)
	src.Roots = append(src.Roots, sys.WowInstallRoots()...)
	return assembleCandidates(src, PEFileVersion)
}

// assembleCandidates resolves every source location to a game executable,
// dedupes by cleaned path (case-insensitive — Windows filesystems are), and
// classifies + labels each survivor. versionOf is PEFileVersion in
// production and a fake in tests.
func assembleCandidates(src GameScanSources, versionOf func(string) (GameVersion, bool)) []GameCandidate {
	var exes []string
	seen := map[string]bool{}
	add := func(exe string) {
		key := strings.ToLower(filepath.Clean(exe))
		if seen[key] {
			return
		}
		seen[key] = true
		exes = append(exes, filepath.Clean(exe))
	}

	for _, exe := range src.Exes {
		add(exe)
	}
	for _, dir := range src.Dirs {
		if exe, err := ResolveGameExe(dir); err == nil {
			add(exe)
		}
	}
	for _, root := range src.Roots {
		if exe, ok := FindKnownGameExe(root); ok {
			add(exe)
		}
		for _, sub := range productSubdirs(root) {
			if exe, ok := FindKnownGameExe(sub); ok {
				add(exe)
			}
		}
	}

	cands := make([]GameCandidate, 0, len(exes))
	for _, exe := range exes {
		v, ok := versionOf(exe)
		if !ok {
			v = GameVersion{}
		}
		ct := classifyCandidate(exe, v)
		cands = append(cands, GameCandidate{
			ExePath: exe,
			Version: v,
			Type:    ct,
			Label:   candidateLabel(exe, v, ct),
		})
	}
	return cands
}

// productSubdirs lists root's existing Battle.net product subdirectories in
// wowProductDirNames order (one ReadDir, no recursion), preserving on-disk
// casing.
func productSubdirs(root string) []string {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	byProduct := map[string]string{} // lowercased product name -> actual name
	for _, e := range entries {
		if e.IsDir() && isWowProductDirName(e.Name()) {
			byProduct[strings.ToLower(e.Name())] = e.Name()
		}
	}
	var subs []string
	for _, p := range wowProductDirNames {
		if actual, ok := byProduct[p]; ok {
			subs = append(subs, filepath.Join(root, actual))
		}
	}
	return subs
}

// classifyCandidate applies the same trust order the wizard uses: the PE
// version stamp first (rename-proof), then the name/path heuristics. A
// stamped non-1.x major (retail 11.x, an expansion client) is deliberately
// NOT run through the 1.x name heuristics — its Wow.exe would be misread as
// a vanilla client — and stays unknown here; the label carries the truth.
func classifyCandidate(exe string, v GameVersion) ClientType {
	if v != (GameVersion{}) {
		if ct, ok := ClientTypeFromVersion(v); ok {
			return ct
		}
		return "" // non-1.x major: neither supported type
	}
	if ct, ok := DetectClientType(exe); ok {
		return ct
	}
	return ""
}

// clientTypeForModernMajor maps a stamped non-1.x version to the nearer of
// the two supported client types once such an install IS chosen: 8.0+ (BfA
// through retail 11.x) uses the modern gxWindowedResolution CVar family like
// Classic Era; 2.x–7.x expansion clients predate it and take the legacy
// gxResolution path. Streaming and touch input work either way; only the
// touch UI addon is Classic-Era/1.12-only, which the picker label says.
func clientTypeForModernMajor(v GameVersion) ClientType {
	if v.Major >= 8 {
		return ClientTypeClassicEra
	}
	return ClientTypeLegacy
}

// candidateLabel renders the human picker line. Known installs show their
// product folder; an unidentifiable exe shows its full path so the user can
// tell twins apart.
func candidateLabel(exe string, v GameVersion, ct ClientType) string {
	dir := filepath.Dir(exe)
	switch {
	case v != (GameVersion{}) && v.Major != 1:
		name := fmt.Sprintf("WoW %d.%d", v.Major, v.Minor)
		if v.Major >= 10 {
			name = fmt.Sprintf("Retail %d.x", v.Major)
		}
		return fmt.Sprintf("%s — %s (stream only: touch UI addon unavailable)", name, dir)
	case ct == ClientTypeClassicEra:
		if v.Major == 1 {
			return fmt.Sprintf("WoW Classic Era (%d.%d) — %s", v.Major, v.Minor, dir)
		}
		return "WoW Classic Era — " + dir
	case ct == ClientTypeLegacy:
		ver := "1.12"
		if v.Major == 1 {
			ver = fmt.Sprintf("%d.%d", v.Major, v.Minor)
		}
		return fmt.Sprintf("Vanilla %s private client — %s", ver, dir)
	default:
		return "World of Warcraft (version unknown) — " + exe
	}
}

// candidateListing renders the labels as an indented bullet list for error
// messages (the --yes multi-install refusal).
func candidateListing(cands []GameCandidate) string {
	var b strings.Builder
	for _, c := range cands {
		b.WriteString("  - ")
		b.WriteString(c.Label)
		b.WriteString("\n")
	}
	return strings.TrimRight(b.String(), "\n")
}
