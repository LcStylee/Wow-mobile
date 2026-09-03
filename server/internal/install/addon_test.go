package install

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"testing/fstest"
)

// The fixture TOCs carry AddonOwnershipMarker exactly like the real
// addon/*.toc files do — RemoveInstalledAddon requires it before touching
// anything.
func addonSrc() fstest.MapFS {
	return fstest.MapFS{
		"WowMobile.toc": {Data: []byte("## Interface: 11507\n" + AddonOwnershipMarker + "\nCore.lua\n")},
		"Core.lua":      {Data: []byte("-- core\n")},
		"sub/Extra.lua": {Data: []byte("-- extra\n")},
	}
}

// vanillaAddonSrc is the fake WowMobile_Vanilla (1.12 port) tree the wizard
// installs for legacy clients.
func vanillaAddonSrc() fstest.MapFS {
	return fstest.MapFS{
		"WowMobile_Vanilla.toc": {Data: []byte("## Interface: 11200\n" + AddonOwnershipMarker + "\nCore.lua\n")},
		"Core.lua":              {Data: []byte("-- vanilla core\n")},
	}
}

func TestPlanAddonFreshInstall(t *testing.T) {
	dest := t.TempDir()
	src := addonSrc()
	plan, err := PlanAddon(src, filepath.Join(dest, "WowMobile"))
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Install) != 3 || plan.Changed() != true || plan.Total() != 3 {
		t.Fatalf("fresh plan wrong: %+v", plan)
	}
	if got := plan.Summary(); got != "installed 3 files" {
		t.Fatalf("summary: %q", got)
	}
	if err := ApplyAddon(src, filepath.Join(dest, "WowMobile"), plan); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dest, "WowMobile", "sub", "Extra.lua"))
	if err != nil || string(data) != "-- extra\n" {
		t.Fatalf("apply wrote wrong bytes: %q err=%v", data, err)
	}
}

func TestPlanAddonUpToDateAndUpdate(t *testing.T) {
	src := addonSrc()
	dest := t.TempDir()
	if err := ApplyAddon(src, dest, mustPlan(t, src, dest)); err != nil {
		t.Fatal(err)
	}

	plan := mustPlan(t, src, dest)
	if plan.Changed() || len(plan.UpToDate) != 3 {
		t.Fatalf("expected all up to date: %+v", plan)
	}
	if got := plan.Summary(); got != "installed (3 files, up to date)" {
		t.Fatalf("summary: %q", got)
	}

	// One file drifts (old addon version), one unknown user file appears.
	if err := os.WriteFile(filepath.Join(dest, "Core.lua"), []byte("-- old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	unknown := filepath.Join(dest, "UserNotes.txt")
	if err := os.WriteFile(unknown, []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	plan = mustPlan(t, src, dest)
	if len(plan.Update) != 1 || plan.Update[0] != "Core.lua" || len(plan.UpToDate) != 2 {
		t.Fatalf("update plan wrong: %+v", plan)
	}
	if got := plan.Summary(); got != "updated 1 of 3 files" {
		t.Fatalf("summary: %q", got)
	}
	if err := ApplyAddon(src, dest, plan); err != nil {
		t.Fatal(err)
	}
	// The unknown file survives untouched — never deleted, never rewritten.
	data, err := os.ReadFile(unknown)
	if err != nil || string(data) != "mine" {
		t.Fatalf("unknown file was touched: %q err=%v", data, err)
	}
	data, _ = os.ReadFile(filepath.Join(dest, "Core.lua"))
	if string(data) != "-- core\n" {
		t.Fatalf("update not applied: %q", data)
	}
}

// RemoveInstalledAddon deletes a verified own install completely, including
// its subdirectories and the folder itself.
func TestRemoveInstalledAddonRemovesOwnInstall(t *testing.T) {
	src := addonSrc()
	dest := filepath.Join(t.TempDir(), "WowMobile")
	if err := ApplyAddon(src, dest, mustPlan(t, src, dest)); err != nil {
		t.Fatal(err)
	}
	removal, err := RemoveInstalledAddon(src, dest)
	if err != nil || removal != AddonRemovalDone {
		t.Fatalf("RemoveInstalledAddon = (%v, %v), want (AddonRemovalDone, nil)", removal, err)
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatalf("addon folder not removed (err=%v)", err)
	}
}

// A folder whose TOC lacks the ownership marker was NOT installed by this
// app: nothing may be deleted, ever.
func TestRemoveInstalledAddonRefusesForeignFolder(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "WowMobile")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "WowMobile.toc"), []byte("## Title: Someone Else's Addon\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "Core.lua"), []byte("-- theirs\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	removal, err := RemoveInstalledAddon(addonSrc(), dest)
	if err != nil || removal != AddonRemovalForeign {
		t.Fatalf("RemoveInstalledAddon = (%v, %v), want (AddonRemovalForeign, nil)", removal, err)
	}
	for _, name := range []string{"WowMobile.toc", "Core.lua"} {
		if _, err := os.Stat(filepath.Join(dest, name)); err != nil {
			t.Errorf("foreign %s was touched: %v", name, err)
		}
	}
}

// Foreign files inside OUR verified install survive: only the variant's own
// files go, and the directories holding leftovers stay.
func TestRemoveInstalledAddonKeepsForeignFiles(t *testing.T) {
	src := addonSrc()
	dest := filepath.Join(t.TempDir(), "WowMobile")
	if err := ApplyAddon(src, dest, mustPlan(t, src, dest)); err != nil {
		t.Fatal(err)
	}
	keeper := filepath.Join(dest, "sub", "UserNotes.txt")
	if err := os.WriteFile(keeper, []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	removal, err := RemoveInstalledAddon(src, dest)
	if err != nil || removal != AddonRemovalDone {
		t.Fatalf("RemoveInstalledAddon = (%v, %v), want (AddonRemovalDone, nil)", removal, err)
	}
	if data, err := os.ReadFile(keeper); err != nil || string(data) != "mine" {
		t.Fatalf("foreign file lost: %q err=%v", data, err)
	}
	for _, gone := range []string{"WowMobile.toc", "Core.lua", filepath.Join("sub", "Extra.lua")} {
		if _, err := os.Stat(filepath.Join(dest, gone)); !os.IsNotExist(err) {
			t.Errorf("our %s not removed (err=%v)", gone, err)
		}
	}
}

// The REAL shipped TOCs must carry AddonOwnershipMarker, or the migration's
// verified removal degrades to "left untouched" for every genuine install.
func TestShippedTOCsCarryOwnershipMarker(t *testing.T) {
	for _, path := range []string{
		filepath.Join("..", "..", "..", "addon", "WowMobile", "WowMobile.toc"),
		filepath.Join("..", "..", "..", "addon", "WowMobile_Vanilla", "WowMobile_Vanilla.toc"),
	} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("reading %s: %v", path, err)
		}
		if !bytes.Contains(data, []byte(AddonOwnershipMarker)) {
			t.Errorf("%s lacks the ownership marker %q", path, AddonOwnershipMarker)
		}
	}
}

// An absent folder (nothing ever installed, or already cleaned) is a quiet
// no-op.
func TestRemoveInstalledAddonAbsentIsNone(t *testing.T) {
	removal, err := RemoveInstalledAddon(addonSrc(), filepath.Join(t.TempDir(), "WowMobile"))
	if err != nil || removal != AddonRemovalNone {
		t.Fatalf("RemoveInstalledAddon = (%v, %v), want (AddonRemovalNone, nil)", removal, err)
	}
}

func mustPlan(t *testing.T, src fstest.MapFS, dest string) *AddonPlan {
	t.Helper()
	plan, err := PlanAddon(src, dest)
	if err != nil {
		t.Fatal(err)
	}
	return plan
}
