//go:build windows

package install

import (
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	"github.com/LcStylee/Wow-mobile/server/internal/capture"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// NewSystem returns the real Windows implementation of System.
func NewSystem() System { return winSystem{} }

type winSystem struct{}

// blizzardRegKey is where the Battle.net installer records the WoW install
// location (32-bit view, hence WOW6432Node).
const blizzardRegKey = `SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft`

func (winSystem) RegistryWowPath() (string, bool) {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, blizzardRegKey, registry.QUERY_VALUE)
	if err != nil {
		return "", false
	}
	defer k.Close()
	path, _, err := k.GetStringValue("InstallPath")
	if err != nil || path == "" {
		return "", false
	}
	return filepath.Clean(path), true
}

func (winSystem) WellKnownWowDirs() []string {
	var dirs []string
	for _, root := range fixedDriveRoots() {
		dirs = append(dirs,
			filepath.Join(root, `Program Files (x86)`, `World of Warcraft`, `_classic_era_`),
			filepath.Join(root, `World of Warcraft`, `_classic_era_`),
		)
	}
	return dirs
}

// fixedDriveRoots enumerates local fixed drives ("C:\", "D:\", ...), skipping
// removable/network/optical drives — scanning those would be slow and wrong.
func fixedDriveRoots() []string {
	mask, err := windows.GetLogicalDrives()
	if err != nil {
		return []string{`C:\`}
	}
	var roots []string
	for i := 0; i < 26; i++ {
		if mask&(1<<i) == 0 {
			continue
		}
		root := string(rune('A'+i)) + `:\`
		p, err := windows.UTF16PtrFromString(root)
		if err != nil {
			continue
		}
		if windows.GetDriveType(p) == windows.DRIVE_FIXED {
			roots = append(roots, root)
		}
	}
	return roots
}

func (winSystem) LookPathFFmpeg() (string, bool) {
	path, err := exec.LookPath("ffmpeg")
	return path, err == nil
}

// WingetFFmpeg searches winget's package stores, because a freshly
// winget-installed ffmpeg is on the *new* PATH but not on this already
// running process's PATH. User-scope installs land under
// %LOCALAPPDATA%\Microsoft\WinGet\Packages; machine-scope installs
// (elevated console, --scope machine) under %ProgramFiles%\WinGet\Packages.
func (winSystem) WingetFFmpeg() (string, bool) {
	var pkgDirs []string
	if local := os.Getenv("LOCALAPPDATA"); local != "" {
		dirs, _ := filepath.Glob(filepath.Join(local, "Microsoft", "WinGet", "Packages", "Gyan.FFmpeg*"))
		pkgDirs = append(pkgDirs, dirs...)
		// The Links dir holds a shim/symlink directly named ffmpeg.exe.
		if link := filepath.Join(local, "Microsoft", "WinGet", "Links", "ffmpeg.exe"); fileExists(link) {
			return link, true
		}
	}
	if pf := os.Getenv("ProgramFiles"); pf != "" {
		dirs, _ := filepath.Glob(filepath.Join(pf, "WinGet", "Packages", "Gyan.FFmpeg*"))
		pkgDirs = append(pkgDirs, dirs...)
	}
	for _, dir := range pkgDirs {
		found := ""
		filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error { //nolint:errcheck
			if err != nil || d.IsDir() {
				return nil
			}
			if strings.EqualFold(d.Name(), "ffmpeg.exe") &&
				strings.EqualFold(filepath.Base(filepath.Dir(path)), "bin") {
				found = path
				return filepath.SkipAll
			}
			return nil
		})
		if found != "" {
			return found, true
		}
	}
	return "", false
}

func fileExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir()
}

func (winSystem) HaveWinget() bool {
	_, err := exec.LookPath("winget")
	return err == nil
}

func (winSystem) RunWingetInstall(out io.Writer) error {
	cmd := exec.Command("winget", "install", "-e", "--id", "Gyan.FFmpeg",
		"--accept-source-agreements", "--accept-package-agreements")
	cmd.Stdout = out
	cmd.Stderr = out
	// Output is captured through the pipes above, so the child needs no
	// console of its own: CREATE_NO_WINDOW keeps GUI mode window-free and
	// stops console mode from flashing an extra window either.
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
	return cmd.Run()
}

func (winSystem) ProbeEncoder(ffmpegPath string) (string, bool) {
	enc, err := capture.ProbeEncoder(ffmpegPath)
	if err != nil {
		return "", false
	}
	switch enc {
	case capture.NVENC:
		return "h264_nvenc", true
	case capture.AMF:
		return "h264_amf", true
	case capture.QSV:
		return "h264_qsv", true
	case capture.X264:
		return "libx264 (software)", true
	}
	return string(enc), true
}

func (winSystem) GameWindowPresent(titleSubstr string) bool {
	_, err := window.NewTracker(titleSubstr)
	return err == nil
}

func (winSystem) LaunchGame(exePath string) error {
	cmd := exec.Command(exePath)
	cmd.Dir = filepath.Dir(exePath)
	return cmd.Start()
}
