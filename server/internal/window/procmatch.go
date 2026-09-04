// Process-path window filtering: every game-window decision must bind to the
// CHOSEN install only, so a second, unrelated WoW install may run alongside
// (the v0.4.2 field report: a running unrelated instance made the wizard say
// "wait for WoW to close", and — worse — capture and input could land on it).
// A window title alone cannot tell two WoW installs apart; the owning
// process's executable path can. This file is the pure, portable half —
// unit-tested everywhere with fake data; the Windows finder
// (find_windows.go) feeds it live titles and process paths.
package window

import (
	"path/filepath"
	"strings"
)

// CanonDir resolves symlink/junction/subst aliases best-effort so the
// textual PathUnderDir comparison sees the same final form Win32 process
// queries (QueryFullProcessImageNameW) return. The original path stands when
// resolution fails — a wrong-but-consistent alias still matches itself.
func CanonDir(dir string) string {
	if dir == "" {
		return ""
	}
	if r, err := filepath.EvalSymlinks(dir); err == nil && r != "" {
		return r
	}
	return dir
}

// PathUnderDir reports whether exePath lies inside dir — directly or in any
// subdirectory (…\<dir>\Utils\Helper.exe counts). Windows path semantics:
// comparison is case-insensitive, both separators are accepted, and trailing
// separators on dir are ignored. A SIBLING directory sharing a name prefix
// (C:\Games\WoW2\Wow.exe against C:\Games\WoW) does NOT match — the check is
// prefix-plus-separator, never a bare string prefix.
//
// Deliberately OUT of scope — the comparison is textual only: 8.3 short
// names (PROGRA~1), symlinks/junctions/subst aliases of the same directory,
// \\?\ long-path prefixes, and Unicode case pairs beyond simple lowering.
// Both inputs come from Win32 long-path APIs in practice
// (QueryFullProcessImageNameW vs. the recorded install path), which agree on
// the long form. When they do NOT — an install recorded through a
// junction/subst alias while the process path resolves to the final form —
// the mismatch reads as "foreign", not as unknowable, so pickWindow's
// fallback does NOT cover it: the tracker side therefore canonicalizes the
// recorded dir first (CanonDir in targetInstallDir), and the wizard side
// fails toward the SAFE direction (it merely waits/skips a Config.wtf write
// it would otherwise have made).
func PathUnderDir(exePath, dir string) bool {
	norm := func(p string) string {
		return strings.ToLower(strings.ReplaceAll(p, "/", `\`))
	}
	e := norm(exePath)
	d := strings.TrimRight(norm(dir), `\`)
	if e == "" || d == "" {
		return false
	}
	return len(e) > len(d)+1 && strings.HasPrefix(e, d+`\`)
}

// pickWindow selects, among n title-matching candidate windows (indices in
// enumeration order — index 0 is what title-only matching would pick), the
// one belonging to the install at targetDir. lookPath(i) returns candidate
// i's owning process executable path; a lookPath error means the path is
// UNKNOWABLE for that window (access denied on an elevated game, process
// already gone), which is different from a path that resolved and mismatched.
//
// Rules, in order:
//   - no targetDir: index 0 — exactly the title-only behavior, no process
//     queries at all;
//   - the first candidate whose path resolved under targetDir wins;
//   - none matched but some path was unknowable: fall back to the FIRST
//     unknowable candidate (title-only behavior for exactly the windows we
//     cannot judge — a single-install user whose game runs elevated keeps
//     working), with a log-worthy note;
//   - every path resolved and none is under targetDir: idx -1 — those
//     windows are definitively other installs' (the field bug), and treating
//     one as the chosen game is precisely the wrong-instance failure.
func pickWindow(n int, targetDir string, lookPath func(int) (string, error)) (idx int, note string) {
	if n <= 0 {
		return -1, ""
	}
	if targetDir == "" {
		return 0, ""
	}
	firstUnknown := -1
	var firstUnknownErr error
	for i := 0; i < n; i++ {
		p, err := lookPath(i)
		if err != nil {
			if firstUnknown < 0 {
				firstUnknown, firstUnknownErr = i, err
			}
			continue
		}
		if PathUnderDir(p, targetDir) {
			return i, ""
		}
	}
	if firstUnknown >= 0 {
		return firstUnknown, "cannot read the owning process path of a title-matching window (" +
			firstUnknownErr.Error() + ") — falling back to title-only matching for it; the configured install (" +
			targetDir + ") cannot be verified"
	}
	return -1, "every title-matching window belongs to a different WoW install than the configured " + targetDir
}
