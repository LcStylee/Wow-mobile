package install

import (
	"os"
	"path/filepath"
	"testing"
	"testing/fstest"
)

func addonSrc() fstest.MapFS {
	return fstest.MapFS{
		"WowMobile.toc": {Data: []byte("## Interface: 11507\nCore.lua\n")},
		"Core.lua":      {Data: []byte("-- core\n")},
		"sub/Extra.lua": {Data: []byte("-- extra\n")},
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

func mustPlan(t *testing.T, src fstest.MapFS, dest string) *AddonPlan {
	t.Helper()
	plan, err := PlanAddon(src, dest)
	if err != nil {
		t.Fatal(err)
	}
	return plan
}
