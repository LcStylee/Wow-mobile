// Addon installation: byte-compare planning between the embedded addon tree
// and <wow>\Interface\AddOns\WowMobile, then a copy of only what differs.
// Files already in the destination that the source does not know about are
// never touched, let alone deleted.
package install

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// AddonPlan is the result of comparing the addon source against a
// destination directory. Paths are slash-separated and relative to both
// roots.
type AddonPlan struct {
	Install  []string // missing in the destination
	Update   []string // present but different bytes
	UpToDate []string // present and identical
}

// Total is the number of files the addon ships.
func (p *AddonPlan) Total() int { return len(p.Install) + len(p.Update) + len(p.UpToDate) }

// Changed reports whether applying the plan would write anything.
func (p *AddonPlan) Changed() bool { return len(p.Install) > 0 || len(p.Update) > 0 }

// Summary is the wizard's one-line report for the addon step.
func (p *AddonPlan) Summary() string {
	switch {
	case !p.Changed():
		return fmt.Sprintf("installed (%d files, up to date)", p.Total())
	case len(p.UpToDate) == 0 && len(p.Update) == 0:
		return fmt.Sprintf("installed %d files", p.Total())
	default:
		return fmt.Sprintf("updated %d of %d files", len(p.Install)+len(p.Update), p.Total())
	}
}

// PlanAddon walks every file in src and byte-compares it against
// destDir/<same path>. It never lists destDir itself, so unknown files there
// are invisible to the plan (and thus can never be deleted or rewritten).
func PlanAddon(src fs.FS, destDir string) (*AddonPlan, error) {
	plan := &AddonPlan{}
	err := fs.WalkDir(src, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		want, err := fs.ReadFile(src, path)
		if err != nil {
			return fmt.Errorf("reading embedded %s: %w", path, err)
		}
		have, err := os.ReadFile(filepath.Join(destDir, filepath.FromSlash(path)))
		switch {
		case os.IsNotExist(err):
			plan.Install = append(plan.Install, path)
		case err != nil:
			return fmt.Errorf("reading installed %s: %w", path, err)
		case bytes.Equal(have, want):
			plan.UpToDate = append(plan.UpToDate, path)
		default:
			plan.Update = append(plan.Update, path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return plan, nil
}

// ApplyAddon writes the plan's Install and Update files from src into
// destDir, creating directories as needed. Overwriting is safe by design:
// the addon ships no user data (SavedVariables live under WTF\), and nothing
// outside the plan is touched.
func ApplyAddon(src fs.FS, destDir string, plan *AddonPlan) error {
	for _, path := range append(append([]string{}, plan.Install...), plan.Update...) {
		data, err := fs.ReadFile(src, path)
		if err != nil {
			return fmt.Errorf("reading embedded %s: %w", path, err)
		}
		target := filepath.Join(destDir, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(target, data, 0o644); err != nil {
			return err
		}
	}
	return nil
}
