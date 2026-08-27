// Package install is wowstreamd's first-run wizard: it locates the WoW
// Classic Era installation, installs/updates the embedded WowMobile addon,
// fixes Config.wtf for the portrait window, finds (or installs) FFmpeg, and
// makes sure the game is running — each step idempotent and near-instant when
// already satisfied, so the wizard runs on every start.
//
// The wizard logic in this file is portable and tested everywhere; the
// Windows-only operations (registry, drive scan, winget, window checks) sit
// behind the System interface, implemented in sys_windows.go.
package install

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// wizardSteps is the step count in the "[n/5]" progress prefix.
const wizardSteps = 5

// defaultWaitTimeout caps the wizard's window-wait loops (waiting for WoW to
// close, or for its window to appear after launch), so a scripted --yes or
// non-interactive run can never hang forever.
const defaultWaitTimeout = 10 * time.Minute

// GameExeName is the WoW Classic Era executable inside the game directory.
const GameExeName = "WowClassic.exe"

// System abstracts every Windows-only operation the wizard needs, so the
// orchestration logic stays portable and testable with a fake.
type System interface {
	// RegistryWowPath returns Blizzard's InstallPath registry value
	// (HKLM\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft).
	RegistryWowPath() (string, bool)
	// WellKnownWowDirs returns candidate `\World of Warcraft\_classic_era_`
	// directories on fixed drives (existence not yet checked).
	WellKnownWowDirs() []string
	// LookPathFFmpeg finds "ffmpeg" on the current process PATH.
	LookPathFFmpeg() (string, bool)
	// WingetFFmpeg searches %LOCALAPPDATA%\Microsoft\WinGet\Packages for
	// Gyan.FFmpeg*\**\bin\ffmpeg.exe — the winget install location, which is
	// not on this process's (stale) PATH right after an install.
	WingetFFmpeg() (string, bool)
	// HaveWinget reports whether the winget CLI is available.
	HaveWinget() bool
	// RunWingetInstall runs `winget install -e --id Gyan.FFmpeg
	// --accept-source-agreements --accept-package-agreements`, streaming its
	// output to out.
	RunWingetInstall(out io.Writer) error
	// ProbeEncoder returns the best H.264 encoder name (e.g. "h264_nvenc")
	// the given ffmpeg build offers.
	ProbeEncoder(ffmpegPath string) (string, bool)
	// GameWindowPresent reports whether a visible, non-minimized window with
	// titleSubstr in its title exists.
	GameWindowPresent(titleSubstr string) bool
	// LaunchGame starts the game executable without waiting for it.
	LaunchGame(exePath string) error
}

// Prompter asks the user. The console implementation honors --yes and
// non-interactive stdin; tests inject scripted answers.
type Prompter interface {
	// Confirm asks a yes/no question with a default. Implementations must
	// never block when the session is non-interactive — they return def.
	Confirm(question string, def bool) (bool, error)
	// Ask asks for free-form text with no default. Implementations must fail
	// (not block) when the session is non-interactive.
	Ask(question string) (string, error)
}

// Options configures a wizard run.
type Options struct {
	Out    io.Writer
	Prompt Prompter
	Store  *Store // persisted state (config.json); never nil
	Sys    System

	AddonFS fs.FS // embedded addon rooted at the WowMobile folder

	Width, Height int    // --resolution, for Config.wtf
	WindowTitle   string // --window-title, for the game-running check
	WowDirFlag    string // --wow-dir override, "" = auto-detect
	FFmpegFlag    string // --ffmpeg override, "" = search

	Interactive bool // stdin is a terminal
	Yes         bool // --yes: accept every default

	PollInterval time.Duration // wait-loop granularity; 0 = 2s
	WaitTimeout  time.Duration // wait-loop cap before a clear error; 0 = defaultWaitTimeout
}

// Result is what the rest of wowstreamd needs from a completed wizard run.
type Result struct {
	WowDir     string // validated WoW _classic_era_ directory
	FFmpegPath string // located ffmpeg executable
}

// Run executes the five wizard steps in order and returns the located paths.
// Every step is idempotent: on a machine that is already set up it only
// prints its "[n/5] ... OK" line and moves on.
func Run(opts Options) (*Result, error) {
	if opts.PollInterval <= 0 {
		opts.PollInterval = 2 * time.Second
	}
	res := &Result{}

	var err error
	if res.WowDir, err = stepLocateWow(&opts); err != nil {
		return nil, err
	}
	if err := stepInstallAddon(&opts, res.WowDir); err != nil {
		return nil, err
	}
	if err := stepConfigWTF(&opts, res.WowDir); err != nil {
		return nil, err
	}
	if res.FFmpegPath, err = stepFFmpeg(&opts); err != nil {
		return nil, err
	}
	if err := stepGameRunning(&opts, res.WowDir); err != nil {
		return nil, err
	}
	return res, nil
}

// step prints one aligned wizard progress line:
//
//	[1/5] WoW Classic Era ....... found: C:\...
func step(out io.Writer, n int, label, result string) {
	dots := 22 - len(label)
	if dots < 3 {
		dots = 3
	}
	fmt.Fprintf(out, "[%d/%d] %s %s %s\n", n, wizardSteps, label, strings.Repeat(".", dots), result)
}

// ValidWowDir reports whether dir is a usable WoW Classic Era directory:
// WowClassic.exe next to an Interface\ directory.
func ValidWowDir(dir string) bool {
	if dir == "" {
		return false
	}
	if st, err := os.Stat(filepath.Join(dir, GameExeName)); err != nil || st.IsDir() {
		return false
	}
	st, err := os.Stat(filepath.Join(dir, "Interface"))
	return err == nil && st.IsDir()
}

// stepLocateWow finds the game directory: flag, persisted config, registry,
// well-known paths, then a prompt. The result is persisted for next time.
func stepLocateWow(opts *Options) (string, error) {
	const label = "WoW Classic Era"
	if opts.WowDirFlag != "" {
		if !ValidWowDir(opts.WowDirFlag) {
			return "", fmt.Errorf("--wow-dir %q is not a WoW Classic Era directory (need %s and Interface\\ inside it)", opts.WowDirFlag, GameExeName)
		}
		persistWowDir(opts, opts.WowDirFlag)
		step(opts.Out, 1, label, "found: "+opts.WowDirFlag+" (--wow-dir)")
		return opts.WowDirFlag, nil
	}

	if dir := opts.Store.Get(KeyWowPath); ValidWowDir(dir) {
		step(opts.Out, 1, label, "found: "+dir)
		return dir, nil
	}
	if base, ok := opts.Sys.RegistryWowPath(); ok {
		for _, cand := range []string{base, filepath.Join(base, "_classic_era_")} {
			if ValidWowDir(cand) {
				persistWowDir(opts, cand)
				step(opts.Out, 1, label, "found: "+cand)
				return cand, nil
			}
		}
	}
	for _, cand := range opts.Sys.WellKnownWowDirs() {
		if ValidWowDir(cand) {
			persistWowDir(opts, cand)
			step(opts.Out, 1, label, "found: "+cand)
			return cand, nil
		}
	}

	step(opts.Out, 1, label, "not found automatically")
	for attempt := 0; attempt < 5; attempt++ {
		dir, err := opts.Prompt.Ask(`Paste the path to your WoW Classic Era folder (the one containing ` + GameExeName + `), e.g. C:\Program Files (x86)\World of Warcraft\_classic_era_`)
		if err != nil {
			return "", fmt.Errorf("WoW Classic Era was not found; pass its path with --wow-dir (%w)", err)
		}
		dir = strings.Trim(strings.TrimSpace(dir), `"`)
		if ValidWowDir(dir) {
			persistWowDir(opts, dir)
			step(opts.Out, 1, label, "found: "+dir)
			return dir, nil
		}
		fmt.Fprintf(opts.Out, "  %q does not contain %s and Interface\\ — please check the path.\n", dir, GameExeName)
	}
	return "", errors.New("no valid WoW Classic Era directory after 5 attempts; pass it with --wow-dir")
}

func persistWowDir(opts *Options, dir string) {
	if opts.Store.Get(KeyWowPath) != dir {
		opts.Store.Set(KeyWowPath, dir)
		saveStore(opts)
	}
}

func saveStore(opts *Options) {
	if err := opts.Store.Save(); err != nil {
		fmt.Fprintf(opts.Out, "  warning: %v (the wizard will re-detect next run)\n", err)
	}
}

// stepInstallAddon copies the embedded addon into Interface\AddOns\WowMobile,
// writing only files that are missing or differ; nothing else in AddOns is
// ever touched.
func stepInstallAddon(opts *Options, wowDir string) error {
	const label = "WowMobile addon"
	dest := filepath.Join(wowDir, "Interface", "AddOns", "WowMobile")
	plan, err := PlanAddon(opts.AddonFS, dest)
	if err != nil {
		return fmt.Errorf("comparing addon files: %w", err)
	}
	if plan.Changed() {
		if err := ApplyAddon(opts.AddonFS, dest, plan); err != nil {
			return fmt.Errorf("installing addon into %s: %w", dest, err)
		}
	}
	step(opts.Out, 2, label, plan.Summary())
	return nil
}

// stepConfigWTF ensures the portrait-window settings in WTF\Config.wtf,
// with a .bak backup and a minimal edit — but never while WoW is running,
// because the game rewrites the file on exit.
func stepConfigWTF(opts *Options, wowDir string) error {
	const label = "Portrait resolution"
	want := PortraitSettings(opts.Width, opts.Height)
	resolution := fmt.Sprintf("%dx%d", opts.Width, opts.Height)
	path := filepath.Join(wowDir, "WTF", "Config.wtf")

	content, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		ok, perr := opts.Prompt.Confirm("WTF\\Config.wtf does not exist yet (fresh install). Create it with the portrait window settings?", true)
		if perr != nil {
			return perr
		}
		if !ok {
			step(opts.Out, 3, label, "skipped — configure the window manually (see --setup)")
			return nil
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(path, FreshConfig(want), 0o644); err != nil {
			return fmt.Errorf("creating %s: %w", path, err)
		}
		step(opts.Out, 3, label, fmt.Sprintf("Config.wtf created (%s windowed)", resolution))
		return nil
	}
	if err != nil {
		return fmt.Errorf("reading %s: %w", path, err)
	}

	if SettingsSatisfied(content, want) {
		step(opts.Out, 3, label, fmt.Sprintf("Config.wtf OK (%s windowed)", resolution))
		return nil
	}

	if opts.Sys.GameWindowPresent(opts.WindowTitle) {
		fmt.Fprintln(opts.Out, "  Config.wtf needs changes, but WoW is running — the game rewrites the file on exit, which would undo the edit.")
		// Non-interactive sessions default to NOT waiting: nobody is there
		// to close WoW, so the safe default is to skip the edit rather than
		// poll a headless run forever (Prompter.Confirm returns def without
		// blocking when the session is non-interactive).
		wait, perr := opts.Prompt.Confirm("Wait for WoW to close, then apply the settings?", opts.Interactive)
		if perr != nil {
			return perr
		}
		if !wait {
			step(opts.Out, 3, label, "unchanged — close WoW and restart wowstreamd to apply "+resolution)
			return nil
		}
		fmt.Fprintln(opts.Out, "  Waiting for WoW to close (Ctrl+C to abort)...")
		if err := waitForGameWindow(opts, false, "WoW to close"); err != nil {
			return fmt.Errorf("%w; close WoW and restart wowstreamd to apply %s", err, resolution)
		}
	} else {
		ok, perr := opts.Prompt.Confirm(fmt.Sprintf("Update Config.wtf for a %s portrait window? (a Config.wtf%s backup is written first)", resolution, BackupSuffix), true)
		if perr != nil {
			return perr
		}
		if !ok {
			step(opts.Out, 3, label, "skipped — configure the window manually (see --setup)")
			return nil
		}
	}

	changed, err := ApplyConfigWTF(path, want)
	if err != nil {
		return fmt.Errorf("updating %s: %w", path, err)
	}
	if changed {
		step(opts.Out, 3, label, fmt.Sprintf("Config.wtf updated (%s windowed, backup: Config.wtf%s)", resolution, BackupSuffix))
	} else {
		step(opts.Out, 3, label, fmt.Sprintf("Config.wtf OK (%s windowed)", resolution))
	}
	return nil
}

// FFmpegManualInstallHint is printed when winget is unavailable or declined
// (same URLs as docs/SETUP.md).
const FFmpegManualInstallHint = `  Install FFmpeg manually:
    - https://ffmpeg.org/download.html  or a full build from
    - https://www.gyan.dev/ffmpeg/builds/
  then either add its bin folder to PATH or pass --ffmpeg C:\path\to\ffmpeg.exe.`

// stepFFmpeg locates ffmpeg (flag, PATH, persisted path, WinGet packages
// dir) and offers a winget install when absent. The located path is
// persisted, because a winget-installed ffmpeg is not on this (stale)
// process PATH.
func stepFFmpeg(opts *Options) (string, error) {
	const label = "FFmpeg"
	report := func(path string) string {
		if enc, ok := opts.Sys.ProbeEncoder(path); ok {
			return fmt.Sprintf("found: %s available", enc)
		}
		return "found: " + path
	}

	if opts.FFmpegFlag != "" {
		// Validate the explicit override like --wow-dir: a typo'd path must
		// fail here with a targeted error, not later at the encoder probe.
		if st, err := os.Stat(opts.FFmpegFlag); err != nil || st.IsDir() {
			return "", fmt.Errorf("--ffmpeg %q: not an existing file", opts.FFmpegFlag)
		}
		step(opts.Out, 4, label, report(opts.FFmpegFlag)+" (--ffmpeg)")
		return opts.FFmpegFlag, nil
	}
	if path, ok := opts.Sys.LookPathFFmpeg(); ok {
		step(opts.Out, 4, label, report(path))
		return path, nil
	}
	if path := opts.Store.Get(KeyFFmpegPath); path != "" {
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			step(opts.Out, 4, label, report(path))
			return path, nil
		}
	}
	if path, ok := opts.Sys.WingetFFmpeg(); ok {
		persistFFmpeg(opts, path)
		step(opts.Out, 4, label, report(path))
		return path, nil
	}

	step(opts.Out, 4, label, "not found")
	if !opts.Sys.HaveWinget() {
		fmt.Fprintln(opts.Out, "  winget is not available on this system.")
		fmt.Fprintln(opts.Out, FFmpegManualInstallHint)
		return "", errors.New("ffmpeg not found (install it, then restart wowstreamd, or pass --ffmpeg)")
	}
	ok, err := opts.Prompt.Confirm("Install FFmpeg now via winget (winget install -e --id Gyan.FFmpeg)?", true)
	if err != nil {
		return "", err
	}
	if !ok {
		fmt.Fprintln(opts.Out, FFmpegManualInstallHint)
		return "", errors.New("ffmpeg not found (install it, then restart wowstreamd, or pass --ffmpeg)")
	}
	if err := opts.Sys.RunWingetInstall(opts.Out); err != nil {
		fmt.Fprintln(opts.Out, FFmpegManualInstallHint)
		return "", fmt.Errorf("winget install of FFmpeg failed: %w", err)
	}
	// The fresh install is not on this process's PATH — find the binary in
	// the WinGet packages directory and persist it for every future start.
	if path, ok := opts.Sys.WingetFFmpeg(); ok {
		persistFFmpeg(opts, path)
		step(opts.Out, 4, label, report(path)+" (installed via winget)")
		return path, nil
	}
	return "", errors.New("winget reported success but ffmpeg.exe was not found under the WinGet packages directory; restart wowstreamd (new PATH) or pass --ffmpeg")
}

func persistFFmpeg(opts *Options, path string) {
	if opts.Store.Get(KeyFFmpegPath) != path {
		opts.Store.Set(KeyFFmpegPath, path)
		saveStore(opts)
	}
}

// stepGameRunning checks for the game window and offers to launch
// WowClassic.exe, polling until the window (post-login) exists.
func stepGameRunning(opts *Options, wowDir string) error {
	const label = "Game running"
	if opts.Sys.GameWindowPresent(opts.WindowTitle) {
		step(opts.Out, 5, label, "window found")
		return nil
	}

	step(opts.Out, 5, label, "no window matching "+fmt.Sprintf("%q", opts.WindowTitle))
	if !opts.Interactive && !opts.Yes {
		return errors.New("the WoW window was not found and stdin is not interactive; start WoW first, or run with --yes to auto-launch it")
	}
	exe := filepath.Join(wowDir, GameExeName)
	ok, err := opts.Prompt.Confirm("Launch "+exe+" now?", true)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("WoW is not running; start it (windowed, not minimized), then restart wowstreamd")
	}
	if err := opts.Sys.LaunchGame(exe); err != nil {
		return fmt.Errorf("launching %s: %w", exe, err)
	}
	fmt.Fprintln(opts.Out, "  WoW is starting — log in to your character. Waiting for the game window (Ctrl+C to abort)...")
	if err := waitForGameWindow(opts, true, "the WoW window to appear"); err != nil {
		return fmt.Errorf("%w after launching %s; check that the game started (windowed, not minimized), then restart wowstreamd", err, GameExeName)
	}
	step(opts.Out, 5, label, "window found")
	return nil
}

// waitForGameWindow polls GameWindowPresent until it matches present, with a
// hard deadline (Options.WaitTimeout, default defaultWaitTimeout) so a
// scripted or non-interactive run fails with a clear error instead of
// hanging forever when WoW never reaches the expected state.
func waitForGameWindow(opts *Options, present bool, what string) error {
	timeout := opts.WaitTimeout
	if timeout <= 0 {
		timeout = defaultWaitTimeout
	}
	deadline := time.Now().Add(timeout)
	for opts.Sys.GameWindowPresent(opts.WindowTitle) != present {
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out after %s waiting for %s", timeout, what)
		}
		time.Sleep(opts.PollInterval)
	}
	return nil
}
