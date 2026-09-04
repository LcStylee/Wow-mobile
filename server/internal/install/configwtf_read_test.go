package install

import (
	"path/filepath"
	"testing"
)

func TestReadSetting(t *testing.T) {
	content := []byte("SET gxWindow \"1\"\r\n" +
		"SET gxResolution \"3840x2160\"\r\n" +
		"SET realmName \"My Cool Realm\"\r\n" +
		"SET gxMaximize 0\r\n" +
		"-- comment line\r\n" +
		"SET gxResolution \"1920x1080\"\r\n")

	tests := []struct {
		name      string
		want      string
		wantFound bool
	}{
		{"gxWindow", "1", true},
		// Duplicated CVar: the LAST line is the one the engine keeps.
		{"gxResolution", "1920x1080", true},
		// Quoted value with spaces survives whole.
		{"realmName", "My Cool Realm", true},
		// Unquoted value.
		{"gxMaximize", "0", true},
		{"gxWindowedResolution", "", false},
	}
	for _, tt := range tests {
		got, found := ReadSetting(content, tt.name)
		if got != tt.want || found != tt.wantFound {
			t.Errorf("ReadSetting(%q) = %q, %v; want %q, %v", tt.name, got, found, tt.want, tt.wantFound)
		}
	}

	// LF-only content works the same.
	if got, found := ReadSetting([]byte("SET gxResolution \"800x600\"\n"), "gxResolution"); !found || got != "800x600" {
		t.Errorf("LF content: got %q, %v", got, found)
	}
}

func TestReadResolutionSetting(t *testing.T) {
	tests := []struct {
		content string
		w, h    int
		ok      bool
	}{
		{"SET gxResolution \"3840x2160\"\r\n", 3840, 2160, true},
		// Odd dimensions are the game's business — reported, not rejected
		// (unlike --resolution, this reads what WoW was told, it does not
		// size an encoder).
		{"SET gxResolution \"1367x769\"\n", 1367, 769, true},
		{"SET gxResolution \"garbage\"\n", 0, 0, false},
		{"SET gxResolution \"1920x\"\n", 0, 0, false},
		{"SET gxResolution \"0x1080\"\n", 0, 0, false},
		{"SET gxResolution \"99999x1080\"\n", 0, 0, false},
		{"SET gxWindow \"1\"\n", 0, 0, false}, // absent
		{"", 0, 0, false},
	}
	for _, tt := range tests {
		w, h, ok := ReadResolutionSetting([]byte(tt.content), "gxResolution")
		if w != tt.w || h != tt.h || ok != tt.ok {
			t.Errorf("ReadResolutionSetting(%q) = %d, %d, %v; want %d, %d, %v",
				tt.content, w, h, ok, tt.w, tt.h, tt.ok)
		}
	}
}

func TestConfigWTFPath(t *testing.T) {
	got := ConfigWTFPath(filepath.Join("C:", "Games", "TurtleWoW", "WoW.exe"))
	want := filepath.Join("C:", "Games", "TurtleWoW", "WTF", "Config.wtf")
	if got != want {
		t.Errorf("ConfigWTFPath = %q; want %q", got, want)
	}
}
