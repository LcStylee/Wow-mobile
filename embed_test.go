package embedded

import (
	"bytes"
	"io/fs"
	"os"
	"strings"
	"testing"
)

// Drift guard: the embedded trees must match the canonical on-disk sources
// byte-for-byte in both directions. If this fails, rebuild (go:embed snapshots
// at compile time) or investigate which side changed.
//
// The client tree carries dev-only files (tests/, package.json) that exist on
// disk but must never be embedded — they would be shipped in and publicly
// served by every released wowstreamd.exe (embed.go scopes them out). The
// host dashboard (client/host) is likewise excluded from the PUBLIC ClientFS:
// it displays the pairing token, so it ships only via the separate HostFS,
// served through loopback-guarded routes.
func TestEmbeddedClientMatchesDisk(t *testing.T) {
	assertFSEqualsDisk(t, ClientFS, "client", "client/tests", "client/package.json", "client/host")
}

func TestEmbeddedAddonMatchesDisk(t *testing.T) {
	assertFSEqualsDisk(t, AddonFS, "addon/WowMobile")
}

func TestEmbeddedVanillaAddonMatchesDisk(t *testing.T) {
	assertFSEqualsDisk(t, VanillaAddonFS, "addon/WowMobile_Vanilla")
}

func TestEmbeddedHostDashboardMatchesDisk(t *testing.T) {
	assertFSEqualsDisk(t, HostFS, "client/host")
}

// Both shipped TOCs must carry the ownership marker RemoveInstalledAddon
// (server/internal/install, which this root package cannot import) verifies
// before it will delete a wrongly installed variant during the client-type
// migration — lose the line and the cleanup silently degrades to "left
// untouched". install's TestShippedTOCsCarryOwnershipMarker binds the same
// files to the actual constant.
func TestAddonTOCsCarryOwnershipMarker(t *testing.T) {
	const marker = "## Author: WoW Mobile project" // == install.AddonOwnershipMarker
	for _, path := range []string{
		"addon/WowMobile/WowMobile.toc",
		"addon/WowMobile_Vanilla/WowMobile_Vanilla.toc",
	} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("reading %s: %v", path, err)
		}
		if !bytes.Contains(data, []byte(marker)) {
			t.Errorf("%s lacks the ownership marker %q", path, marker)
		}
	}
}

// assertFSEqualsDisk compares the embedded tree with the on-disk dir in both
// directions. devOnly names files or directories that are expected on disk
// but asserted ABSENT from the embedded FS.
func assertFSEqualsDisk(t *testing.T, embeddedFS fs.FS, dir string, devOnly ...string) {
	t.Helper()
	diskFS := os.DirFS(".")
	isDevOnly := func(path string) bool {
		for _, ex := range devOnly {
			if path == ex || strings.HasPrefix(path, ex+"/") {
				return true
			}
		}
		return false
	}

	files := map[string]bool{}
	err := fs.WalkDir(diskFS, dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if isDevOnly(path) {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		files[path] = true
		disk, err := fs.ReadFile(diskFS, path)
		if err != nil {
			return err
		}
		emb, err := fs.ReadFile(embeddedFS, path)
		if err != nil {
			t.Errorf("%s exists on disk but not in the embedded FS: %v", path, err)
			return nil
		}
		if !bytes.Equal(disk, emb) {
			t.Errorf("%s: embedded bytes differ from disk (%d vs %d bytes)", path, len(emb), len(disk))
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walking disk %s: %v", dir, err)
	}
	if len(files) == 0 {
		t.Fatalf("no files found on disk under %s", dir)
	}

	// Reverse direction: nothing embedded that disk no longer has.
	err = fs.WalkDir(embeddedFS, dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		if isDevOnly(path) {
			t.Errorf("%s is dev-only and must not be embedded", path)
			return nil
		}
		if !files[path] {
			t.Errorf("%s is embedded but missing on disk", path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walking embedded %s: %v", dir, err)
	}

	// Dev-only paths exist on disk (so the exclusion list cannot go stale)
	// but must be absent from the embedded FS.
	for _, ex := range devOnly {
		if _, err := fs.Stat(diskFS, ex); err != nil {
			t.Errorf("dev-only path %s no longer on disk — update the exclusion list: %v", ex, err)
		}
		if _, err := fs.Stat(embeddedFS, ex); err == nil {
			t.Errorf("%s is dev-only and must not be embedded", ex)
		}
	}
}
