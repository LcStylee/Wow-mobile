package install

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// mkTree builds a temp tree: dirs end with "/", everything else becomes an
// empty file. Returns the root.
func mkTree(t *testing.T, paths ...string) string {
	t.Helper()
	root := t.TempDir()
	for _, p := range paths {
		full := filepath.Join(root, filepath.FromSlash(strings.TrimSuffix(p, "/")))
		if strings.HasSuffix(p, "/") {
			if err := os.MkdirAll(full, 0o755); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte("MZ"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestResolveGameExe(t *testing.T) {
	tests := []struct {
		name  string
		tree  []string // relative paths; "/" suffix = dir
		input string   // relative to root; "" = root itself
		want  string   // expected exe relative to root; "" = error expected
	}{
		{
			name:  "classic era dir itself",
			tree:  []string{"_classic_era_/WowClassic.exe"},
			input: "_classic_era_",
			want:  "_classic_era_/WowClassic.exe",
		},
		{
			name:  "parent World of Warcraft dir descends into _classic_era_",
			tree:  []string{"_classic_era_/WowClassic.exe", "Battle.net/x"},
			input: "",
			want:  "_classic_era_/WowClassic.exe",
		},
		{
			name:  "case-insensitive _Classic_Era_ descent",
			tree:  []string{"_Classic_Era_/WOWCLASSIC.EXE"},
			input: "",
			want:  "_Classic_Era_/WOWCLASSIC.EXE",
		},
		{
			name:  "private server dir with Wow.exe",
			tree:  []string{"Wow.exe", "Data/x"},
			input: "",
			want:  "Wow.exe",
		},
		{
			name:  "lowercase wow.exe found case-insensitively",
			tree:  []string{"wow.exe"},
			input: "",
			want:  "wow.exe",
		},
		{
			name: "preference order: WowClassic beats VanillaFixes beats Wow",
			tree: []string{"Wow.exe", "VanillaFixes.exe", "WowClassic.exe"},
			want: "WowClassic.exe",
		},
		{
			name: "VanillaFixes preferred over Wow.exe",
			tree: []string{"Wow.exe", "VanillaFixes.exe"},
			want: "VanillaFixes.exe",
		},
		{
			name:  "exe path accepted verbatim even with unknown name",
			tree:  []string{"TurtleWoW.exe"},
			input: "TurtleWoW.exe",
			want:  "TurtleWoW.exe",
		},
		{
			name:  "known exe as direct file path",
			tree:  []string{"sub/VanillaFixes.exe"},
			input: "sub/VanillaFixes.exe",
			want:  "sub/VanillaFixes.exe",
		},
		{
			name: "dir without any game exe fails",
			tree: []string{"readme.txt", "Interface/"},
			want: "",
		},
		{
			name: "known exe name as a directory is not a match",
			tree: []string{"Wow.exe/"},
			want: "",
		},
		{
			name:  "nonexistent path fails",
			tree:  []string{"x"},
			input: "missing",
			want:  "",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			root := mkTree(t, tc.tree...)
			in := filepath.Join(root, filepath.FromSlash(tc.input))
			got, err := ResolveGameExe(in)
			if tc.want == "" {
				if err == nil {
					t.Fatalf("expected error, got %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("ResolveGameExe(%q): %v", in, err)
			}
			if want := filepath.Join(root, filepath.FromSlash(tc.want)); got != want {
				t.Fatalf("got %q, want %q", got, want)
			}
		})
	}
}

func TestResolveGameExeStripsQuotesAndSpace(t *testing.T) {
	root := mkTree(t, "_classic_era_/WowClassic.exe")
	got, err := ResolveGameExe(`  "` + root + `"  `)
	if err != nil {
		t.Fatal(err)
	}
	if got != filepath.Join(root, "_classic_era_", "WowClassic.exe") {
		t.Fatalf("quoted path not resolved: %q", got)
	}
}

func TestDetectClientType(t *testing.T) {
	tests := []struct {
		path   string
		want   ClientType
		wantOK bool
	}{
		{`C:\Program Files (x86)\World of Warcraft\_classic_era_\WowClassic.exe`, ClientTypeClassicEra, true},
		{`D:\games\WOWCLASSIC.EXE`, ClientTypeClassicEra, true}, // name alone suffices, case-insensitive
		{`C:\WoW\_Classic_Era_\Wow.exe`, ClientTypeClassicEra, true},
		{`C:\turtle\Wow.exe`, ClientTypeLegacy, true},
		{`C:\turtle\WoW.exe`, ClientTypeLegacy, true},
		{`C:\turtle\wow.exe`, ClientTypeLegacy, true},
		{`C:\turtle\VanillaFixes.exe`, ClientTypeLegacy, true},
		{`C:\turtle\vanillafixes.EXE`, ClientTypeLegacy, true},
		{`C:\turtle\TurtleWoW.exe`, "", false},                        // unknown name => ask
		{`C:\_classic_era_\anything.exe`, ClientTypeClassicEra, true}, // tree wins for unknown names too
	}
	for _, tc := range tests {
		got, ok := DetectClientType(tc.path)
		if got != tc.want || ok != tc.wantOK {
			t.Errorf("DetectClientType(%q) = (%q, %v), want (%q, %v)", tc.path, got, ok, tc.want, tc.wantOK)
		}
	}
}

func TestDefaultClientTypeNeverGuessesClassicWithoutTree(t *testing.T) {
	if got := DefaultClientType(`C:\turtle\TurtleWoW.exe`); got != ClientTypeLegacy {
		t.Fatalf("unknown exe outside _classic_era_ must default legacy, got %q", got)
	}
	if got := DefaultClientType(`C:\wow\_classic_era_\custom.exe`); got != ClientTypeClassicEra {
		t.Fatalf("_classic_era_ path must default classicEra, got %q", got)
	}
}

// Per-client-type Config.wtf line selection: Classic Era uses
// gxWindowedResolution; 1.12-era clients use the old gxResolution CVar and
// must NOT get gxWindowedResolution.
func TestPortraitSettingsForClientType(t *testing.T) {
	classic := PortraitSettingsFor(ClientTypeClassicEra, 1080, 1920)
	legacy := PortraitSettingsFor(ClientTypeLegacy, 1080, 1920)

	names := func(set []Setting) map[string]string {
		m := map[string]string{}
		for _, s := range set {
			m[s.Name] = s.Value
		}
		return m
	}
	c, l := names(classic), names(legacy)

	for _, m := range []map[string]string{c, l} {
		if m["gxWindow"] != "1" || m["gxMaximize"] != "0" {
			t.Fatalf("windowed base settings wrong: %v", m)
		}
	}
	if c["gxWindowedResolution"] != "1080x1920" {
		t.Fatalf("classicEra resolution line wrong: %v", c)
	}
	if _, has := c["gxResolution"]; has {
		t.Fatalf("classicEra must not write gxResolution: %v", c)
	}
	if l["gxResolution"] != "1080x1920" {
		t.Fatalf("legacy resolution line wrong: %v", l)
	}
	if _, has := l["gxWindowedResolution"]; has {
		t.Fatalf("legacy must not write gxWindowedResolution: %v", l)
	}
	// Both generations disable the out-of-date-addon gate: a game patch must
	// never silently turn the touch UI off (SETUP.md documents this line).
	for _, m := range []map[string]string{c, l} {
		if m["checkAddonVersion"] != "0" {
			t.Fatalf("checkAddonVersion \"0\" missing: %v", m)
		}
	}
}
