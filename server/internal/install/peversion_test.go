package install

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

// fixedInfo builds a synthetic VS_FIXEDFILEINFO at a DWORD-aligned offset
// inside padding, the way it sits inside real .rsrc data.
func fixedInfo(prefix int, major, minor uint16) []byte {
	buf := make([]byte, prefix+16)
	binary.LittleEndian.PutUint32(buf[prefix:], fixedFileInfoSignature)
	binary.LittleEndian.PutUint32(buf[prefix+4:], 0x00010000) // dwStrucVersion
	binary.LittleEndian.PutUint32(buf[prefix+8:], uint32(major)<<16|uint32(minor))
	binary.LittleEndian.PutUint32(buf[prefix+12:], 0x00000001) // dwFileVersionLS
	return buf
}

func TestFixedFileVersion(t *testing.T) {
	cases := []struct {
		name   string
		data   []byte
		want   GameVersion
		wantOK bool
	}{
		{"vanilla 1.12 stamp", fixedInfo(64, 1, 12), GameVersion{1, 12}, true},
		{"classic era 1.15 stamp", fixedInfo(0, 1, 15), GameVersion{1, 15}, true},
		{"no signature", make([]byte, 128), GameVersion{}, false},
		{"truncated at signature", fixedInfo(64, 1, 12)[:68], GameVersion{}, false},
		{"empty", nil, GameVersion{}, false},
	}
	for _, tc := range cases {
		got, ok := fixedFileVersion(tc.data)
		if got != tc.want || ok != tc.wantOK {
			t.Errorf("%s: fixedFileVersion = (%v, %v), want (%v, %v)", tc.name, got, ok, tc.want, tc.wantOK)
		}
	}
}

func TestPEFileVersionRejectsNonPE(t *testing.T) {
	path := filepath.Join(t.TempDir(), "not-a-pe.exe")
	if err := os.WriteFile(path, []byte("MZ but not really a PE file"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, ok := PEFileVersion(path); ok {
		t.Error("PEFileVersion accepted a non-PE file")
	}
	if _, ok := PEFileVersion(filepath.Join(t.TempDir(), "missing.exe")); ok {
		t.Error("PEFileVersion accepted a missing file")
	}
}

func TestClientTypeFromVersion(t *testing.T) {
	cases := []struct {
		v      GameVersion
		want   ClientType
		wantOK bool
	}{
		{GameVersion{1, 0}, ClientTypeLegacy, true},
		{GameVersion{1, 12}, ClientTypeLegacy, true},
		{GameVersion{1, 13}, ClientTypeClassicEra, true},
		{GameVersion{1, 14}, ClientTypeClassicEra, true},
		{GameVersion{1, 15}, ClientTypeClassicEra, true},
		// Official Classic Era stamps stop at 1.15: a higher 1.x stamp is a
		// vanilla-plus custom client's own content version (1.12 engine) and
		// must NOT be classified — heuristics and finally the user decide
		// (v0.3.2 field report: OctoWow "1.18.1" misfiled as Classic Era).
		{GameVersion{1, 16}, "", false},
		{GameVersion{1, 17}, "", false}, // Turtle WoW
		{GameVersion{1, 18}, "", false}, // OctoWow
		{GameVersion{2, 4}, "", false},  // TBC private client: heuristics/user decide
		{GameVersion{3, 3}, "", false},  // WotLK
		{GameVersion{11, 0}, "", false}, // retail
	}
	for _, tc := range cases {
		got, ok := ClientTypeFromVersion(tc.v)
		if got != tc.want || ok != tc.wantOK {
			t.Errorf("ClientTypeFromVersion(%v) = (%q, %v), want (%q, %v)", tc.v, got, ok, tc.want, tc.wantOK)
		}
	}
}

func TestIsVanillaPlusStamp(t *testing.T) {
	cases := []struct {
		v    GameVersion
		want bool
	}{
		{GameVersion{1, 12}, false},
		{GameVersion{1, 15}, false},
		{GameVersion{1, 16}, true},
		{GameVersion{1, 17}, true},
		{GameVersion{1, 18}, true},
		{GameVersion{2, 18}, false}, // major must be 1
	}
	for _, tc := range cases {
		if got := isVanillaPlusStamp(tc.v); got != tc.want {
			t.Errorf("isVanillaPlusStamp(%v) = %v, want %v", tc.v, got, tc.want)
		}
	}
}
