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
	"unsafe"

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

// WowInstallRoots finds existing "World of Warcraft*" base directories at
// the well-known parents — both Program Files trees and the top level of
// every fixed drive. One directory listing per parent (top-level only, never
// recursive), so the scan stays bounded however large the drives are.
func (winSystem) WowInstallRoots() []string {
	var roots []string
	for _, drive := range fixedDriveRoots() {
		for _, parent := range []string{
			filepath.Join(drive, `Program Files (x86)`),
			filepath.Join(drive, `Program Files`),
			drive,
		} {
			roots = append(roots, wowDirsUnder(parent)...)
		}
	}
	return roots
}

// wowDirsUnder lists parent's immediate subdirectories whose names start
// with "World of Warcraft" (case-insensitive), preserving on-disk casing.
func wowDirsUnder(parent string) []string {
	entries, err := os.ReadDir(parent)
	if err != nil {
		return nil
	}
	var dirs []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if len(name) >= len("World of Warcraft") &&
			strings.EqualFold(name[:len("World of Warcraft")], "World of Warcraft") {
			dirs = append(dirs, filepath.Join(parent, name))
		}
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

func (winSystem) GameWindowPresent(installDir, titleSubstr string) bool {
	// The install-dir filter (window.NewTrackerFor) binds the check to the
	// CHOSEN install's own window: an unrelated WoW install running alongside
	// must not count as "the game is running" (v0.4.2 field report — it made
	// the wizard wait for a game it was not even configuring).
	_, err := window.NewTrackerFor(titleSubstr, installDir)
	return err == nil
}

func (winSystem) EnforceGameWindowSize(installDir, titleSubstr string, w, h int) (string, bool) {
	tracker, err := window.NewTrackerFor(titleSubstr, installDir)
	if err != nil {
		return "", false // no window: the game-running step handles that
	}
	res := tracker.EnforceClientSize(w, h)
	if res.Outcome == window.EnforceAlready {
		return "", false // nothing to report; the window is already right
	}
	return res.Message, true
}

func (winSystem) LaunchGame(exePath string) error {
	cmd := exec.Command(exePath)
	cmd.Dir = filepath.Dir(exePath)
	return cmd.Start()
}

var (
	sysUser32                 = windows.NewLazySystemDLL("user32.dll")
	procSystemParametersInfoW = sysUser32.NewProc("SystemParametersInfoW")
	procGetSystemMetrics      = sysUser32.NewProc("GetSystemMetrics")
	procAdjustWindowRectEx    = sysUser32.NewProc("AdjustWindowRectEx")
	// DPI-correct decoration measurement (Win10 1607+; Find()-guarded).
	procAdjustWindowRectExForDpi = sysUser32.NewProc("AdjustWindowRectExForDpi")
	procGetDpiForSystem          = sysUser32.NewProc("GetDpiForSystem")
	procMonitorFromPoint         = sysUser32.NewProc("MonitorFromPoint")

	sysShcore            = windows.NewLazySystemDLL("shcore.dll")
	procGetDpiForMonitor = sysShcore.NewProc("GetDpiForMonitor")
)

// winRect mirrors the Win32 RECT (left, top, right, bottom).
type winRect struct{ left, top, right, bottom int32 }

const (
	spiGetWorkArea = 0x0030 // SPI_GETWORKAREA
	smCxScreen     = 0      // SM_CXSCREEN: primary monitor desktop width
	smCyScreen     = 1      // SM_CYSCREEN: primary monitor desktop height
	// WS_OVERLAPPEDWINDOW: the caption + thick-frame style a windowed
	// (gxWindow=1, gxMaximize=0) WoW gets, so AdjustWindowRectEx(ForDpi)
	// measures the decorations of the actual window being fitted.
	wsOverlappedWindow = 0x00CF0000

	monitorDefaultToPrimary = 0x1 // MONITOR_DEFAULTTOPRIMARY
	mdtEffectiveDPI         = 0   // MDT_EFFECTIVE_DPI
)

// PrimaryWorkArea measures the primary monitor's work area — the desktop
// minus the taskbar and app bars, which is exactly the space a non-maximized
// window can occupy. Physical pixels: main.go opts the process into
// per-monitor DPI awareness (and the manifest already declares it) before any
// geometry is read, so no virtualization skews this.
func (winSystem) PrimaryWorkArea() (int, int, bool) {
	var rc winRect
	ret, _, _ := procSystemParametersInfoW.Call(spiGetWorkArea, 0, uintptr(unsafe.Pointer(&rc)), 0)
	if ret == 0 {
		return 0, 0, false
	}
	w := int(rc.right - rc.left)
	h := int(rc.bottom - rc.top)
	if w <= 0 || h <= 0 {
		return 0, 0, false
	}
	return w, h, true
}

// PrimaryDesktopResolution measures the primary monitor's full desktop
// resolution (physical pixels — the process is per-monitor-DPI-aware, so no
// virtualization skews the metrics): the native landscape mode band layout
// writes into a legacy client's gxResolution.
func (winSystem) PrimaryDesktopResolution() (int, int, bool) {
	w, _, _ := procGetSystemMetrics.Call(smCxScreen)
	h, _, _ := procGetSystemMetrics.Call(smCyScreen)
	if int(int32(w)) <= 0 || int(int32(h)) <= 0 {
		return 0, 0, false
	}
	return int(int32(w)), int(int32(h)), true
}

// WindowDecorationExtents measures how much width/height the window frame
// (borders + title bar) adds around a client area for WoW's windowed style,
// by adjusting an empty rect: the adjusted rect IS the decoration.
//
// This process is per-monitor-DPI-aware (manifest + makeProcessDPIAware), and
// in that mode plain AdjustWindowRectEx does NOT scale to the monitor's
// current DPI — it answers for 96 dpi (at best the session-start system DPI),
// under-measuring the frame by ~10-25 px vertically on the 125-150%-scaled
// displays that are the 1080p/1440p-laptop norm. An under-measured frame
// makes the height-limited fit pick a client area whose real outer rect
// overshoots the work area: the deck's bottom rows land behind the taskbar —
// silently, since the client area still matches the configured size. So the
// primary monitor's current effective DPI is fed to AdjustWindowRectExForDpi
// (Win10 1607+ — exactly why Microsoft added it); only where that API or the
// DPI query is unavailable does plain AdjustWindowRectEx answer. If every
// call fails, the documented conservative fallback margins apply — erring a
// few pixels large only makes the fitted window marginally smaller, never
// non-fitting.
func (winSystem) WindowDecorationExtents() (int, int) {
	var rc winRect // zero client rect: the adjusted rect IS the decoration
	var ret uintptr
	if dpi, ok := primaryMonitorDPI(); ok && procAdjustWindowRectExForDpi.Find() == nil {
		ret, _, _ = procAdjustWindowRectExForDpi.Call(
			uintptr(unsafe.Pointer(&rc)), wsOverlappedWindow, 0, 0, uintptr(dpi))
	} else {
		ret, _, _ = procAdjustWindowRectEx.Call(uintptr(unsafe.Pointer(&rc)), wsOverlappedWindow, 0, 0)
	}
	dw := int(rc.right - rc.left)
	dh := int(rc.bottom - rc.top)
	// Plausibility bounds sized for real DPI scaling: 300% (the Windows
	// maximum preset) puts the frame around 48x144, far inside 200x300.
	if ret == 0 || dw <= 0 || dh <= 0 || dw > 200 || dh > 300 {
		// Failure or an implausible measurement: conservative documented
		// margins (8 px borders each side, 32 px title bar + borders).
		return window.FallbackDecorationW, window.FallbackDecorationH
	}
	return dw, dh
}

// primaryMonitorDPI returns the primary monitor's CURRENT effective DPI:
// GetDpiForMonitor(MonitorFromPoint({0,0})) first — it tracks mid-session
// display-scale changes and mixed-DPI setups — then GetDpiForSystem as a
// lesser fallback (session-start system DPI). ok is false when neither API
// exists (pre-1607), and the caller stays on plain AdjustWindowRectEx.
func primaryMonitorDPI() (uint32, bool) {
	if procMonitorFromPoint.Find() == nil && procGetDpiForMonitor.Find() == nil {
		// POINT{0,0} is 8 bytes, passed by value in one register/slot — the
		// primary monitor's origin by definition; the flag is belt and braces.
		hmon, _, _ := procMonitorFromPoint.Call(0, monitorDefaultToPrimary)
		if hmon != 0 {
			var dpiX, dpiY uint32
			hr, _, _ := procGetDpiForMonitor.Call(hmon, mdtEffectiveDPI,
				uintptr(unsafe.Pointer(&dpiX)), uintptr(unsafe.Pointer(&dpiY)))
			if hr == 0 && dpiY != 0 { // S_OK
				return dpiY, true
			}
		}
	}
	if procGetDpiForSystem.Find() == nil {
		if dpi, _, _ := procGetDpiForSystem.Call(); dpi != 0 {
			return uint32(dpi), true
		}
	}
	return 0, false
}
