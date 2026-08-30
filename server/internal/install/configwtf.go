// Config.wtf handling: a minimal, line-preserving editor for WoW's console
// variable file. WoW rewrites this file on exit, so callers must only write
// while the game is closed — the wizard enforces that; this file only knows
// how to edit bytes safely.
package install

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Setting is one `SET <name> "<value>"` console variable.
type Setting struct {
	Name  string
	Value string
}

// checkAddonVersionOff disables the client's out-of-date-addon gate. After
// any game patch the interface number in the addon's .toc lags the client and
// WoW then silently refuses to load the addon (no error, just the stock UI —
// on a phone that reads as "everything broke"). checkAddonVersion "0" is the
// CVar behind the AddOns screen's "Load out of date AddOns" checkbox; writing
// it here means a patch never silently disables the touch UI. Both client
// generations (1.12 and Classic Era) honor the same CVar name.
var checkAddonVersionOff = Setting{Name: "checkAddonVersion", Value: "0"}

// PortraitSettings returns the Config.wtf lines required for streaming a
// windowed portrait WoW Classic Era at width x height (docs/SETUP.md step 1).
func PortraitSettings(width, height int) []Setting {
	return []Setting{
		{Name: "gxWindow", Value: "1"},
		{Name: "gxMaximize", Value: "0"},
		{Name: "gxWindowedResolution", Value: fmt.Sprintf("%dx%d", width, height)},
		checkAddonVersionOff,
	}
}

// PortraitSettingsFor selects the windowed-portrait settings for the client
// type: Classic Era (1.15) uses gxWindowedResolution; 1.12-era clients
// (private servers) predate that CVar and use gxResolution instead — writing
// gxWindowedResolution there would be dead weight, so it is omitted. The
// gxWindow/gxMaximize pair is common to both generations.
func PortraitSettingsFor(ct ClientType, width, height int) []Setting {
	if ct == ClientTypeLegacy {
		return []Setting{
			{Name: "gxWindow", Value: "1"},
			{Name: "gxMaximize", Value: "0"},
			{Name: "gxResolution", Value: fmt.Sprintf("%dx%d", width, height)},
			checkAddonVersionOff,
		}
	}
	return PortraitSettings(width, height)
}

// SettingLine renders a Setting in WoW's canonical form.
func SettingLine(s Setting) string {
	return fmt.Sprintf("SET %s %q", s.Name, s.Value)
}

// settingName extracts the variable name from a `SET name "value"` line
// (surrounding whitespace tolerated); ok is false for any other line.
func settingName(line string) (string, bool) {
	fields := strings.Fields(line)
	if len(fields) >= 2 && fields[0] == "SET" {
		return fields[1], true
	}
	return "", false
}

// EnsureSettings returns content with every wanted setting present at its
// wanted value. The edit is minimal: unrelated lines are preserved verbatim
// (bytes, order, comments), each line keeps its own CRLF/LF ending, and
// missing settings are appended using the file's dominant line ending.
// changed is false when the content already satisfies want.
func EnsureSettings(content []byte, want []Setting) (out []byte, changed bool) {
	eol := "\n"
	if bytes.Contains(content, []byte("\r\n")) {
		eol = "\r\n"
	}
	lines := strings.Split(string(content), "\n")
	seen := make(map[string]bool, len(want))
	for i, line := range lines {
		stripped := strings.TrimSuffix(line, "\r")
		name, ok := settingName(stripped)
		if !ok {
			continue
		}
		for _, w := range want {
			if name != w.Name {
				continue
			}
			seen[w.Name] = true
			if wantLine := SettingLine(w); stripped != wantLine {
				if strings.HasSuffix(line, "\r") {
					lines[i] = wantLine + "\r"
				} else {
					lines[i] = wantLine
				}
				changed = true
			}
		}
	}

	body := strings.Join(lines, "\n")
	var missing []string
	for _, w := range want {
		if !seen[w.Name] {
			missing = append(missing, SettingLine(w))
		}
	}
	if len(missing) > 0 {
		changed = true
		if body != "" && !strings.HasSuffix(body, "\n") {
			body += eol
		}
		body += strings.Join(missing, eol) + eol
	}
	return []byte(body), changed
}

// SettingsSatisfied reports whether content already carries every wanted
// setting at its wanted value.
func SettingsSatisfied(content []byte, want []Setting) bool {
	_, changed := EnsureSettings(content, want)
	return !changed
}

// FreshConfig renders a brand-new Config.wtf containing only the wanted
// settings, CRLF-terminated (the file lives on Windows and is edited with
// Notepad more often than not).
func FreshConfig(want []Setting) []byte {
	var b strings.Builder
	for _, w := range want {
		b.WriteString(SettingLine(w))
		b.WriteString("\r\n")
	}
	return []byte(b.String())
}

// BackupSuffix is appended to Config.wtf's path for the pre-edit backup.
const BackupSuffix = ".bak"

// ApplyConfigWTF edits the Config.wtf at path: the original bytes are first
// copied to path+BackupSuffix, then the minimally edited content is written
// atomically with the original file's permissions. Returns changed=false (and
// writes nothing, not even a backup) when the file already satisfies want.
//
// The atomic replace (temp file + rename, see writeFileAtomic) means no
// crash, power loss, or disk-full error can leave Config.wtf truncated: the
// file either keeps its old bytes or holds the complete new content. That in
// turn keeps the backup safe — a later run can never read corrupted content
// from path and copy it over the good .bak.
func ApplyConfigWTF(path string, want []Setting) (changed bool, err error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	out, changed := EnsureSettings(content, want)
	if !changed {
		return false, nil
	}
	mode := os.FileMode(0o644)
	if info, statErr := os.Stat(path); statErr == nil {
		mode = info.Mode().Perm()
	}
	if err := os.WriteFile(path+BackupSuffix, content, mode); err != nil {
		return false, fmt.Errorf("writing backup: %w", err)
	}
	if err := writeFileAtomic(path, out, mode); err != nil {
		return false, err
	}
	return true, nil
}

// writeFileAtomic replaces path with data without ever truncating path in
// place: data goes to a temp file in the same directory (same volume, so the
// rename cannot degrade to copy+delete), is flushed to disk, and only then
// renamed over path. Any failure before the rename leaves path untouched and
// removes the temp file.
func writeFileAtomic(path string, data []byte, mode os.FileMode) (err error) {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			tmp.Close()           // no-op if already closed
			os.Remove(tmp.Name()) // best-effort cleanup; path is untouched
		}
	}()
	if err = tmp.Chmod(mode); err != nil {
		return err
	}
	if _, err = tmp.Write(data); err != nil {
		return err
	}
	if err = tmp.Sync(); err != nil {
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
