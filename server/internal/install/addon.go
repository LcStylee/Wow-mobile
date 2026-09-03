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
	"sort"
	"strings"
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

// AddonOwnershipMarker is the TOC line every WowMobile addon variant this app
// ships carries (addon/WowMobile/WowMobile.toc and the Vanilla port alike).
// RemoveInstalledAddon requires it in the installed TOC before deleting
// anything: an AddOns folder that merely shares our folder name but was not
// installed by this app must never be touched.
const AddonOwnershipMarker = "## Author: WoW Mobile project"

// AddonRemoval is RemoveInstalledAddon's outcome.
type AddonRemoval int

const (
	// AddonRemovalNone: nothing was installed there (no folder, or no TOC).
	AddonRemovalNone AddonRemoval = iota
	// AddonRemovalDone: the TOC carried this app's ownership marker and the
	// variant's files were deleted (the folder too, unless foreign files
	// kept it alive — those are always left in place).
	AddonRemovalDone
	// AddonRemovalForeign: a TOC exists but lacks the ownership marker — the
	// folder was NOT installed by this app and nothing was touched.
	AddonRemovalForeign
)

// RemoveInstalledAddon deletes a previously installed addon variant from
// destDir — used only by the misclassification migration (a Classic Era
// addon planted into what turned out to be a 1.12-engine vanilla-plus
// client, where it cannot load). It is the exact inverse of ApplyAddon's
// safety posture:
//
//   - it verifies destDir really holds OUR addon first: the variant's .toc
//     (looked up in the embedded src) must exist there and carry
//     AddonOwnershipMarker — otherwise nothing is touched (AddonRemovalForeign);
//   - only files the embedded variant ships are deleted; anything else in the
//     folder survives, and directories are removed only once empty, so a
//     folder holding foreign files stays (with them) rather than being
//     RemoveAll'd.
func RemoveInstalledAddon(src fs.FS, destDir string) (AddonRemoval, error) {
	tocName := ""
	entries, err := fs.ReadDir(src, ".")
	if err != nil {
		return AddonRemovalNone, fmt.Errorf("reading embedded addon: %w", err)
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".toc") {
			tocName = e.Name()
			break
		}
	}
	if tocName == "" {
		return AddonRemovalNone, fmt.Errorf("embedded addon ships no .toc file")
	}
	toc, err := os.ReadFile(filepath.Join(destDir, tocName))
	switch {
	case os.IsNotExist(err):
		return AddonRemovalNone, nil // not installed (or already gone)
	case err != nil:
		return AddonRemovalNone, fmt.Errorf("reading installed %s: %w", tocName, err)
	case !bytes.Contains(toc, []byte(AddonOwnershipMarker)):
		return AddonRemovalForeign, nil // shares the name, not ours: hands off
	}

	// Delete exactly the files the embedded variant ships, collecting the
	// directories they lived in for the bottom-up empty-dir sweep.
	dirs := map[string]bool{destDir: true}
	err = fs.WalkDir(src, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		target := filepath.Join(destDir, filepath.FromSlash(path))
		if d.IsDir() {
			dirs[target] = true
			return nil
		}
		if rmErr := os.Remove(target); rmErr != nil && !os.IsNotExist(rmErr) {
			return fmt.Errorf("removing %s: %w", target, rmErr)
		}
		return nil
	})
	if err != nil {
		return AddonRemovalNone, err
	}
	// Deepest directories first; os.Remove refuses non-empty directories, so
	// foreign files automatically keep their whole path alive.
	sorted := make([]string, 0, len(dirs))
	for d := range dirs {
		sorted = append(sorted, d)
	}
	sort.Slice(sorted, func(i, j int) bool { return len(sorted[i]) > len(sorted[j]) })
	for _, d := range sorted {
		_ = os.Remove(d) // fails harmlessly while non-empty
	}
	return AddonRemovalDone, nil
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
