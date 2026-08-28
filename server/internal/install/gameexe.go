// Game-executable resolution and client-type detection. WoW Mobile supports
// two kinds of hosts: the official WoW Classic Era client (WowClassic.exe
// under a _classic_era_ tree) and 1.12-era private-server clients (Wow.exe,
// often launched through VanillaFixes.exe). Everything the wizard does later —
// addon dir, Config.wtf, the launch step — derives from the recorded game
// executable's directory, never from a hardcoded Classic Era layout.
//
// This file is deliberately portable (plain os/filepath) so the descend and
// detection rules are unit-tested on every OS.
package install

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ClientType classifies the game client behind the recorded executable. It
// decides which Config.wtf CVar names apply and whether the WowMobile addon
// (Classic Era 1.15 API, Interface 11507) can be installed.
type ClientType string

const (
	// ClientTypeClassicEra is the official WoW Classic Era client (1.15):
	// full support including the WowMobile touch UI addon.
	ClientTypeClassicEra ClientType = "classicEra"
	// ClientTypeLegacy is a 1.12-era client (private servers: Wow.exe /
	// VanillaFixes.exe): streaming, capture, input injection, dashboard and
	// phone client all work; the addon cannot load there.
	ClientTypeLegacy ClientType = "legacy"
)

// valid reports whether ct is one of the two known values (guards persisted
// strings from older/corrupt config.json files).
func (ct ClientType) valid() bool {
	return ct == ClientTypeClassicEra || ct == ClientTypeLegacy
}

// String returns the human wording used in wizard output and dialogs.
func (ct ClientType) String() string {
	if ct == ClientTypeLegacy {
		return "1.12-era client"
	}
	return "Classic Era"
}

// KnownGameExes are the game executables recognized inside a selected folder,
// in preference order. Matching is case-insensitive everywhere, so "Wow.exe"
// also covers "WoW.exe" and "wow.exe".
var KnownGameExes = []string{"WowClassic.exe", "VanillaFixes.exe", "Wow.exe"}

// classicEraDirName is the Battle.net folder holding the Classic Era client.
const classicEraDirName = "_classic_era_"

// FindKnownGameExe scans dir (non-recursively) for the highest-preference
// known game executable, case-insensitively, and returns its real on-disk
// path.
func FindKnownGameExe(dir string) (string, bool) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", false
	}
	byLower := make(map[string]string, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			byLower[strings.ToLower(e.Name())] = e.Name()
		}
	}
	for _, want := range KnownGameExes {
		if actual, ok := byLower[strings.ToLower(want)]; ok {
			return filepath.Join(dir, actual), true
		}
	}
	return "", false
}

// classicEraChild returns dir's _classic_era_ subdirectory (any casing) if it
// exists — the "picked the parent 'World of Warcraft' folder" case.
func classicEraChild(dir string) (string, bool) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", false
	}
	for _, e := range entries {
		if e.IsDir() && strings.EqualFold(e.Name(), classicEraDirName) {
			return filepath.Join(dir, e.Name()), true
		}
	}
	return "", false
}

// ResolveGameExe turns a user-supplied location — a folder OR the game
// executable itself — into the game executable to record:
//
//   - a file is accepted verbatim, whatever its name (private servers launch
//     through arbitrary exes; the user knows best);
//   - a folder containing a known game exe (KnownGameExes, case-insensitive)
//     resolves to the highest-preference one;
//   - a folder with a _classic_era_ subfolder (the parent "World of Warcraft"
//     install dir) descends into it and applies the same rule.
//
// Surrounding whitespace and quotes (pasted Explorer "Copy as path") are
// stripped. The returned path always names an existing file.
func ResolveGameExe(path string) (string, error) {
	path = strings.Trim(strings.TrimSpace(path), `"`)
	if path == "" {
		return "", fmt.Errorf("no path given")
	}
	st, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("%q does not exist", path)
	}
	if !st.IsDir() {
		return path, nil
	}
	if exe, ok := FindKnownGameExe(path); ok {
		return exe, nil
	}
	if sub, ok := classicEraChild(path); ok {
		if exe, ok := FindKnownGameExe(sub); ok {
			return exe, nil
		}
	}
	return "", fmt.Errorf("%q contains no game program (looked for %s, and inside a %s subfolder) — pick the WoW folder or the game .exe itself",
		path, strings.Join(KnownGameExes, ", "), classicEraDirName)
}

// DetectClientType classifies the client behind exePath. ok is false for an
// executable name the table does not know outside a _classic_era_ tree — the
// wizard then asks (or applies DefaultClientType under --yes).
//
// Order matters: anything inside a _classic_era_ tree is Classic Era even if
// launched through a Wow.exe/VanillaFixes.exe found there; the legacy names
// only classify as 1.12-era OUTSIDE such a tree.
func DetectClientType(exePath string) (ClientType, bool) {
	base := strings.ToLower(filepath.Base(exePath))
	if base == "wowclassic.exe" {
		return ClientTypeClassicEra, true
	}
	if strings.Contains(strings.ToLower(exePath), classicEraDirName) {
		return ClientTypeClassicEra, true
	}
	switch base {
	case "wow.exe", "vanillafixes.exe":
		return ClientTypeLegacy, true
	}
	return "", false
}

// DefaultClientType is the non-guessing default used when the type cannot be
// detected and nobody can be asked (--yes / non-interactive): Classic Era only
// when _classic_era_ appears in the path, otherwise a legacy 1.12 client —
// documented in docs/SETUP.md ("Private servers"). The choice is logged by the
// wizard either way.
func DefaultClientType(exePath string) ClientType {
	if strings.Contains(strings.ToLower(exePath), classicEraDirName) {
		return ClientTypeClassicEra
	}
	return ClientTypeLegacy
}
