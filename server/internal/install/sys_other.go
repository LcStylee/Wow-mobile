//go:build !windows

package install

import (
	"errors"
	"io"
	"os/exec"

	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// NewSystem returns a stub System on non-Windows platforms. The wizard only
// runs on Windows (wowstreamd refuses to stream elsewhere); this stub keeps
// the package buildable and vet-clean everywhere.
func NewSystem() System { return stubSystem{} }

type stubSystem struct{}

func (stubSystem) RegistryWowPath() (string, bool) { return "", false }
func (stubSystem) WellKnownWowDirs() []string      { return nil }
func (stubSystem) WowInstallRoots() []string       { return nil }
func (stubSystem) LookPathFFmpeg() (string, bool) {
	path, err := exec.LookPath("ffmpeg")
	return path, err == nil
}
func (stubSystem) WingetFFmpeg() (string, bool) { return "", false }
func (stubSystem) HaveWinget() bool             { return false }
func (stubSystem) RunWingetInstall(io.Writer) error {
	return errors.New("winget is Windows-only")
}
func (stubSystem) ProbeEncoder(string) (string, bool) { return "", false }
func (stubSystem) GameWindowPresent(string) bool      { return false }
func (stubSystem) EnforceGameWindowSize(string, int, int) (string, bool) {
	return "", false
}
func (stubSystem) LaunchGame(string) error {
	return errors.New("launching WoW is Windows-only")
}
func (stubSystem) PrimaryWorkArea() (int, int, bool)          { return 0, 0, false }
func (stubSystem) PrimaryDesktopResolution() (int, int, bool) { return 0, 0, false }
func (stubSystem) WindowDecorationExtents() (int, int) {
	return window.FallbackDecorationW, window.FallbackDecorationH
}
