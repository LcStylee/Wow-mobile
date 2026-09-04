package window

import (
	"errors"
	"strings"
	"testing"
)

func TestPathUnderDir(t *testing.T) {
	tests := []struct {
		name string
		exe  string
		dir  string
		want bool
	}{
		{"direct child", `C:\Games\WoW\Wow.exe`, `C:\Games\WoW`, true},
		{"case-insensitive", `c:\games\wow\WOW.EXE`, `C:\Games\WoW`, true},
		{"trailing separator on dir", `C:\Games\WoW\Wow.exe`, `C:\Games\WoW\`, true},
		{"multiple trailing separators", `C:\Games\WoW\Wow.exe`, `C:\Games\WoW\\`, true},
		{"subdirectory counts as inside", `C:\Games\WoW\Utils\VanillaFixes.exe`, `C:\Games\WoW`, true},
		{"deep subdirectory", `C:\Games\WoW\a\b\c\Wow.exe`, `C:\Games\WoW`, true},
		{"forward slashes in exe path", `C:/Games/WoW/Wow.exe`, `C:\Games\WoW`, true},
		{"forward slashes in dir", `C:\Games\WoW\Wow.exe`, `C:/Games/WoW/`, true},
		{"drive root install", `C:\Wow.exe`, `C:\`, true},

		// The load-bearing negative: a SIBLING install whose name shares a
		// prefix must never match (C:\Games\WoW2 is not inside C:\Games\WoW).
		{"sibling with shared prefix", `C:\Games\WoW2\Wow.exe`, `C:\Games\WoW`, false},
		{"sibling with shared prefix, reversed", `C:\Games\WoW\Wow.exe`, `C:\Games\WoW2`, false},
		{"unrelated directory", `C:\Other\Wow.exe`, `C:\Games\WoW`, false},
		{"other drive", `D:\Games\WoW\Wow.exe`, `C:\Games\WoW`, false},
		{"path equals dir", `C:\Games\WoW`, `C:\Games\WoW`, false},
		{"parent of dir", `C:\Games\Wow.exe`, `C:\Games\WoW`, false},
		{"empty exe path", ``, `C:\Games\WoW`, false},
		{"empty dir", `C:\Games\WoW\Wow.exe`, ``, false},
		{"both empty", ``, ``, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := PathUnderDir(tt.exe, tt.dir); got != tt.want {
				t.Errorf("PathUnderDir(%q, %q) = %v, want %v", tt.exe, tt.dir, got, tt.want)
			}
		})
	}
}

// fakeProcs is the injected stand-in for the Win32 process-path lookup: one
// entry per enumerated window, either a path or an error.
type fakeProcs []struct {
	path string
	err  error
}

func (f fakeProcs) look(i int) (string, error) { return f[i].path, f[i].err }

func TestPickWindow(t *testing.T) {
	denied := errors.New("OpenProcess: access denied")
	target := `C:\Games\TurtleWoW`

	tests := []struct {
		name     string
		procs    fakeProcs
		noTarget bool // pass "" as targetDir (title-only mode)
		wantIdx  int
		wantNote string // "" = no note; otherwise a substring the note must contain
	}{
		{
			name:     "no target dir keeps title-only behavior",
			procs:    fakeProcs{{path: `C:\Elsewhere\Wow.exe`}},
			noTarget: true,
			wantIdx:  0,
		},
		{
			name:    "single install, path matches",
			procs:   fakeProcs{{path: `C:\Games\TurtleWoW\Wow.exe`}},
			wantIdx: 0,
		},
		{
			name: "second window is the chosen install",
			procs: fakeProcs{
				{path: `C:\Games\WoW\Wow.exe`},
				{path: `C:\Games\TurtleWoW\Wow.exe`},
			},
			wantIdx: 1,
		},
		{
			name: "first matching window wins among several matches",
			procs: fakeProcs{
				{path: `C:\Games\TurtleWoW\Wow.exe`},
				{path: `C:\Games\TurtleWoW\Utils\VanillaFixes.exe`},
			},
			wantIdx: 0,
		},
		{
			name: "launcher-launched exe in a subdir still matches the dir",
			procs: fakeProcs{
				{path: `C:\Games\TurtleWoW\Utils\Wow.exe`},
			},
			wantIdx: 0,
		},
		{
			name: "all windows definitively foreign: none picked",
			procs: fakeProcs{
				{path: `C:\Games\WoW\Wow.exe`},
				{path: `C:\Games\TurtleWoW2\Wow.exe`}, // sibling prefix must not match
			},
			wantIdx:  -1,
			wantNote: "different WoW install",
		},
		{
			name: "unknowable path falls back to that window, with a note",
			procs: fakeProcs{
				{path: `C:\Games\WoW\Wow.exe`}, // resolved and foreign: excluded
				{err: denied},                  // unknowable: fallback target
			},
			wantIdx:  1,
			wantNote: "title-only",
		},
		{
			name: "a real match beats an earlier unknowable window",
			procs: fakeProcs{
				{err: denied},
				{path: `C:\Games\TurtleWoW\Wow.exe`},
			},
			wantIdx: 1,
		},
		{
			name: "first unknowable wins when nothing matches",
			procs: fakeProcs{
				{err: denied},
				{err: errors.New("process gone")},
			},
			wantIdx:  0,
			wantNote: "cannot read",
		},
		{
			name:    "zero candidates",
			procs:   fakeProcs{},
			wantIdx: -1,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := target
			if tt.noTarget {
				dir = ""
			}
			idx, note := pickWindow(len(tt.procs), dir, tt.procs.look)
			if idx != tt.wantIdx {
				t.Errorf("pickWindow idx = %d, want %d (note %q)", idx, tt.wantIdx, note)
			}
			if tt.wantNote == "" && idx >= 0 && note != "" {
				t.Errorf("unexpected note %q", note)
			}
			if tt.wantNote != "" && !strings.Contains(note, tt.wantNote) {
				t.Errorf("note %q must contain %q", note, tt.wantNote)
			}
		})
	}
}
