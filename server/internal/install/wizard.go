// Package install is wowstreamd's first-run wizard: it scans the machine for
// game installs and has the user choose one (official WoW Classic Era or a
// 1.12-era private-server client; see scan.go — a remembered explicit choice
// skips the picker, --choose-game re-opens it), installs or
// updates the embedded addon variant matching the client (WowMobile for
// Classic Era, the WowMobile_Vanilla 1.12 port for legacy), fixes Config.wtf
// for the portrait window, finds (or installs) FFmpeg, and makes sure the
// game is running — each step idempotent and near-instant when already
// satisfied, so the wizard runs on every start.
//
// The wizard logic in this file is portable and tested everywhere; the
// Windows-only operations (registry, drive scan, winget, window checks) sit
// behind the System interface (sys_windows.go), and the user interface sits
// behind Prompter — a console implementation in prompt.go and a native-dialog
// implementation in cmd/wowstreamd (GUI mode), so the wizard logic stays
// single-source.
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

	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/hoststatus"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

// wizardSteps is the step count in the "[n/5]" progress prefix.
const wizardSteps = 5

// defaultWaitTimeout caps the wizard's window-wait loops (waiting for WoW to
// close, or for its window to appear after launch), so a scripted --yes or
// non-interactive run can never hang forever.
const defaultWaitTimeout = 10 * time.Minute

// GameExeName is the official WoW Classic Era executable — the auto-detect
// paths (registry, well-known dirs) look for it via KnownGameExes; private
// servers record whatever executable the user picked instead.
const GameExeName = "WowClassic.exe"

// Checklist step ids/labels, shared with the host dashboard (hoststatus).
const (
	StepGame    = "game"
	StepAddon   = "addon"
	StepConfig  = "config"
	StepFFmpeg  = "ffmpeg"
	StepRunning = "running"
)

// Steps returns the dashboard checklist matching this wizard's steps, in
// order and all pending — the single source for hoststatus.New.
func Steps() []hoststatus.Step {
	return []hoststatus.Step{
		{ID: StepGame, Label: "World of Warcraft"},
		{ID: StepAddon, Label: "WowMobile addon"},
		{ID: StepConfig, Label: "Portrait resolution"},
		{ID: StepFFmpeg, Label: "FFmpeg"},
		{ID: StepRunning, Label: "Game running"},
	}
}

// System abstracts every Windows-only operation the wizard needs, so the
// orchestration logic stays portable and testable with a fake.
type System interface {
	// RegistryWowPath returns Blizzard's InstallPath registry value
	// (HKLM\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft).
	RegistryWowPath() (string, bool)
	// WellKnownWowDirs returns candidate `\World of Warcraft\_classic_era_`
	// directories on fixed drives (existence not yet checked).
	WellKnownWowDirs() []string
	// WowInstallRoots returns existing "World of Warcraft*" base directories
	// found at the well-known locations (Program Files trees) and the top
	// level of every fixed drive — the scan roots whose Battle.net product
	// subdirs the install scanner enumerates. Bounded: one directory listing
	// per candidate parent, never a recursive walk.
	WowInstallRoots() []string
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
	// output to out. The child runs with no console window of its own, so GUI
	// mode never flashes a terminal.
	RunWingetInstall(out io.Writer) error
	// ProbeEncoder returns the best H.264 encoder name (e.g. "h264_nvenc")
	// the given ffmpeg build offers.
	ProbeEncoder(ffmpegPath string) (string, bool)
	// GameWindowPresent reports whether a visible, non-minimized window with
	// titleSubstr in its title exists.
	GameWindowPresent(titleSubstr string) bool
	// EnforceGameWindowSize resizes the game window's CLIENT area to w x h
	// when it is a plain windowed (non-maximized, non-fullscreen) window of a
	// different size — windowed 1.12 clients ignore gxResolution entirely, so
	// after launch the window must be sized directly (SetWindowPos) for the
	// portrait layout to apply on every client. Returns a human-readable
	// outcome and acted=false when nothing needed doing (window already
	// sized, or not found). Never fatal: a revert/skip is reported, and the
	// capture adapts to the actual window regardless.
	EnforceGameWindowSize(titleSubstr string, w, h int) (msg string, acted bool)
	// LaunchGame starts the game executable without waiting for it.
	LaunchGame(exePath string) error
	// PrimaryWorkArea returns the primary monitor's work area (the desktop
	// minus taskbar/appbars, SPI_GETWORKAREA) in physical pixels; ok is false
	// when it cannot be measured (non-Windows, or the call failed).
	PrimaryWorkArea() (w, h int, ok bool)
	// WindowDecorationExtents returns the total width/height the window frame
	// adds around a client area for the overlapped style windowed WoW uses
	// (borders + title bar, via AdjustWindowRectEx), falling back to a
	// documented conservative margin (window.FallbackDecoration*) when the
	// exact measurement is unavailable.
	WindowDecorationExtents() (dw, dh int)
}

// Prompter asks the user. The console implementation honors --yes and
// non-interactive stdin; the GUI implementation (cmd/wowstreamd, Windows)
// shows native dialogs and never touches stdin; tests inject scripted
// answers.
type Prompter interface {
	// Confirm asks a yes/no question with a default. Implementations must
	// never block when the session is non-interactive — they return def.
	Confirm(question string, def bool) (bool, error)
	// Ask asks for free-form text with no default. Implementations must fail
	// (not block) when the session is non-interactive.
	Ask(question string) (string, error)
	// SelectGamePath asks where WoW is — the answer may be a folder or the
	// game .exe itself. prevInvalid is the previously rejected answer ("" on
	// the first ask); the GUI uses it to offer a retry / pick-the-exe-yourself
	// dialog, the console re-prompts. Must fail, not block, when
	// non-interactive.
	SelectGamePath(prevInvalid string) (string, error)
	// ChooseGame presents the scanned game installs (at least one) and
	// returns the user's decision: a candidate index, a manually picked
	// folder/exe path, or the wish to browse (GameSelection). A dismissed
	// picker returns ErrGameChoiceCancelled — the wizard then stops cleanly.
	// Must fail, not block, when non-interactive.
	ChooseGame(cands []GameCandidate) (GameSelection, error)
	// Notice shows a message needing the user's attention once. The GUI shows
	// an information dialog; the console implementation is a no-op because the
	// wizard has already printed the same text to its output.
	Notice(title, message string)
}

// Options configures a wizard run.
type Options struct {
	Out    io.Writer
	Prompt Prompter
	Store  *Store // persisted state (config.json); never nil
	Sys    System

	AddonFS        fs.FS // embedded Classic Era addon rooted at the WowMobile folder
	VanillaAddonFS fs.FS // embedded 1.12 port rooted at the WowMobile_Vanilla folder

	// Width/Height carry an explicit --resolution WxH; zero when
	// ResolutionFit is set — resolveResolution then fills them from the
	// monitor's work area before any step consumes them.
	Width, Height int
	// ResolutionFit mirrors config.Config.ResolutionIsFit: size the window to
	// the largest 9:16 portrait client area fitting the primary monitor.
	ResolutionFit bool
	WindowTitle   string // --window-title, for the game-running check
	WowDirFlag    string // --wow-dir override, "" = auto-detect
	GameExeFlag   string // --game-exe override: exact game executable, beats everything
	FFmpegFlag    string // --ffmpeg override, "" = search
	// ClientTypeFlag carries an explicit --client-type era|legacy override
	// (already mapped to a ClientType); it beats every detection — version
	// stamp, heuristics, remembered answer, ask-dialog — and is persisted
	// with the chosen game exactly like a prompted answer. The escape hatch
	// for any client the detection rules misread. "" = detect.
	ClientTypeFlag ClientType

	Interactive bool // a user can answer prompts (terminal stdin, or GUI dialogs)
	Yes         bool // --yes: accept every default
	ChooseGame  bool // --choose-game: always show the install picker, even with a valid remembered choice

	// Status receives live step states for the host dashboard; nil is fine
	// (all hoststatus methods are nil-safe).
	Status *hoststatus.Status

	PollInterval time.Duration // wait-loop granularity; 0 = 2s
	WaitTimeout  time.Duration // wait-loop cap before a clear error; 0 = defaultWaitTimeout

	// versionProbe overrides PEFileVersion in tests (fake exes carry no PE
	// version resource); nil means the real PEFileVersion.
	versionProbe func(string) (GameVersion, bool)
}

// peVersion reads the exe's PE version stamp via the test override when set.
func (o *Options) peVersion(exe string) (GameVersion, bool) {
	if o.versionProbe != nil {
		return o.versionProbe(exe)
	}
	return PEFileVersion(exe)
}

// Result is what the rest of wowstreamd needs from a completed wizard run.
type Result struct {
	GameExe    string     // recorded game executable (the launch target)
	GameDir    string     // its directory — Interface\ and WTF\ live beneath it
	ClientType ClientType // classicEra or legacy (1.12 private server)
	FFmpegPath string     // located ffmpeg executable
	// Width/Height are the decided capture resolution: the monitor-fitted
	// value under --resolution fit, or the (possibly confirmed-oversized)
	// explicit flag value. Capture, Config.wtf, and the hello geometry all
	// use this one number.
	Width, Height int
}

// LegacyAddonNote is the explanation shown (dashboard note + console print +
// one-time GUI dialog) when a 1.12-era client is detected: such clients get
// WowMobile_Vanilla — the 1.12 (Lua 5.0) port of the touch UI — instead of
// the Classic Era addon, and it must be enabled once at character select.
const LegacyAddonNote = "Private-server 1.12 client detected: the WowMobile_Vanilla addon — the 1.12 port " +
	"of the WoW Mobile touch UI — was installed instead of the Classic Era addon. At WoW's character " +
	"select, open AddOns and make sure \"WoW Mobile (Vanilla)\" is checked (once). Streaming and touch " +
	"input work either way."

// Run executes the five wizard steps in order and returns the located paths.
// Every step is idempotent: on a machine that is already set up it only
// prints its "[n/5] ... OK" line and moves on.
func Run(opts Options) (res *Result, err error) {
	if opts.PollInterval <= 0 {
		opts.PollInterval = 2 * time.Second
	}
	res = &Result{}

	// Any error marks the step being worked on as failed on the dashboard;
	// track it via a tiny helper each step calls on entry.
	current := ""
	begin := func(id string) {
		current = id
		opts.Status.SetStep(id, hoststatus.StateRunning, "")
	}
	defer func() {
		if err != nil && current != "" {
			opts.Status.SetStep(current, hoststatus.StateFailed, err.Error())
		}
	}()

	// The capture resolution is decided before any step consumes it: the
	// Config.wtf step writes it, and the caller feeds it to capture and the
	// hello geometry — one number everywhere.
	if err = resolveResolution(&opts); err != nil {
		return nil, err
	}
	res.Width, res.Height = opts.Width, opts.Height

	begin(StepGame)
	var streamOnly bool
	var staleVariant ClientType // wrongly installed variant to clean up ("" = none)
	if res.GameExe, res.ClientType, streamOnly, staleVariant, err = stepLocateGame(&opts); err != nil {
		return nil, err
	}
	res.GameDir = filepath.Dir(res.GameExe)
	opts.Status.SetClientType(string(res.ClientType))

	begin(StepAddon)
	if err = stepInstallAddon(&opts, res.GameDir, res.ClientType, streamOnly, staleVariant); err != nil {
		return nil, err
	}
	begin(StepConfig)
	if err = stepConfigWTF(&opts, res.GameDir, res.ClientType); err != nil {
		return nil, err
	}
	begin(StepFFmpeg)
	if res.FFmpegPath, err = stepFFmpeg(&opts); err != nil {
		return nil, err
	}
	begin(StepRunning)
	if err = stepGameRunning(&opts, res.GameExe); err != nil {
		return nil, err
	}
	return res, nil
}

// step prints one aligned wizard progress line and mirrors it to the
// dashboard checklist:
//
//	[1/5] World of Warcraft .... found: C:\...
func step(opts *Options, n int, id, label, state, result string) {
	stepLine(opts.Out, n, label, result)
	opts.Status.SetStep(id, state, result)
}

// stepLine renders the aligned "[n/5] label .... result" progress line.
func stepLine(out io.Writer, n int, label, result string) {
	dots := 22 - len(label)
	if dots < 3 {
		dots = 3
	}
	fmt.Fprintf(out, "[%d/%d] %s %s %s\n", n, wizardSteps, label, strings.Repeat(".", dots), result)
}

// resolveResolution decides the capture resolution before the steps run.
//
// --resolution fit (the default): measure the primary monitor's work area,
// subtract the window decoration extents, and take the largest 9:16 portrait
// client area that fits, capped at the 1080x1920 design size
// (window.FitPortraitClient) — a 1080x1920 design window cannot fit a
// landscape 1920x1080 monitor: Windows clamps it, the user sees only the top
// rows, and desktop-region capture of the off-screen remainder goes black;
// while a 1440p/4K monitor that holds the design window gets exactly it,
// never larger. The computed WxH is printed plainly, mirrored to the
// dashboard, and persisted (KeyResolution) so every consumer — Config.wtf,
// the capture pipeline, the hello geometry — agrees on one number.
//
// An explicit --resolution WxH is honored but sanity-checked against the same
// work area: an oversized value gets a loud warning naming the fitted
// alternative and requires confirmation to keep (GUI mode: a message box via
// the dialog Prompter; --yes keeps the explicit flag value, logged).
func resolveResolution(opts *Options) error {
	workW, workH, workOK := opts.Sys.PrimaryWorkArea()
	decorW, decorH := opts.Sys.WindowDecorationExtents()

	if !opts.ResolutionFit {
		// Explicit flag: keep it unless it provably cannot fit the monitor.
		if !workOK || (opts.Width+decorW <= workW && opts.Height+decorH <= workH) {
			opts.Status.SetResolution(fmt.Sprintf("%dx%d", opts.Width, opts.Height))
			return nil
		}
		fitW, fitH, fitOK := window.FitPortraitClient(workW, workH, decorW, decorH)
		alt := "no smaller 9:16 window fits either"
		if fitOK {
			alt = fmt.Sprintf("the largest fitting portrait window is %dx%d", fitW, fitH)
		}
		fmt.Fprintf(opts.Out,
			"WARNING: --resolution %dx%d cannot fit your %dx%d work area (window frame included).\n"+
				"  The WoW window will be cut off at the monitor edge and the capture can go black — %s.\n",
			opts.Width, opts.Height, workW, workH, alt)
		if opts.Yes {
			// --yes promised the explicit flag value; keep it and say so.
			fmt.Fprintf(opts.Out, "  keeping --resolution %dx%d (--yes: explicit flag value wins)\n", opts.Width, opts.Height)
			return nil
		}
		question := fmt.Sprintf("--resolution %dx%d is larger than your monitor. Keep it anyway?", opts.Width, opts.Height)
		if fitOK {
			question = fmt.Sprintf("--resolution %dx%d is larger than your monitor. Keep it anyway? (No switches to the fitted %dx%d)",
				opts.Width, opts.Height, fitW, fitH)
		}
		// Default No: the fitted value is the one that actually works; a
		// non-interactive session without --yes also lands on it safely.
		keep, err := opts.Prompt.Confirm(question, false)
		if err != nil {
			return err
		}
		if keep || !fitOK {
			if keep {
				fmt.Fprintf(opts.Out, "  keeping --resolution %dx%d as confirmed\n", opts.Width, opts.Height)
			} else {
				// Declined, but there is nothing to switch to: be honest that
				// the user's No could not be honored, never claim confirmation.
				fmt.Fprintf(opts.Out,
					"  no fitting portrait window exists for this monitor; keeping --resolution %dx%d — expect a cut-off window\n",
					opts.Width, opts.Height)
			}
			opts.Status.SetResolution(fmt.Sprintf("%dx%d", opts.Width, opts.Height))
			return nil
		}
		opts.Width, opts.Height = fitW, fitH
		fmt.Fprintf(opts.Out, "  using %s\n", window.FitDescription(fitW, fitH, workW, workH))
		opts.Status.SetResolution(fmt.Sprintf("%dx%d", fitW, fitH))
		return nil
	}

	// --resolution fit (default).
	if workOK {
		if w, h, ok := window.FitPortraitClient(workW, workH, decorW, decorH); ok {
			opts.Width, opts.Height = w, h
			fmt.Fprintf(opts.Out, "%s\n", window.FitDescription(w, h, workW, workH))
			opts.Status.SetResolution(fmt.Sprintf("%dx%d", w, h))
			persistResolution(opts, w, h)
			return nil
		}
		fmt.Fprintf(opts.Out, "  work area %dx%d is too small to fit a portrait window; ", workW, workH)
	}
	// No measurable (or usable) work area: reuse the last fitted value if one
	// was persisted, else fall back to the 1080x1920 design resolution.
	if w, h, err := ParseStoredResolution(opts.Store.Get(KeyResolution)); err == nil {
		opts.Width, opts.Height = w, h
		fmt.Fprintf(opts.Out, "using the previously fitted portrait window %dx%d (monitor not measurable right now)\n", w, h)
		opts.Status.SetResolution(fmt.Sprintf("%dx%d", w, h))
		return nil
	}
	opts.Width, opts.Height = window.DesignW, window.DesignH
	fmt.Fprintln(opts.Out, "using the 1080x1920 design resolution (monitor work area not measurable; pass --resolution WxH if the window does not fit)")
	opts.Status.SetResolution(fmt.Sprintf("%dx%d", window.DesignW, window.DesignH))
	return nil
}

// ParseStoredResolution parses a persisted "WxH" value (KeyResolution) with
// the same bounds as the --resolution flag; errors for "" or malformed input.
func ParseStoredResolution(s string) (w, h int, err error) {
	if s == "" {
		return 0, 0, errors.New("no stored resolution")
	}
	return config.ParseResolution(s)
}

func persistResolution(opts *Options, w, h int) {
	val := fmt.Sprintf("%dx%d", w, h)
	if opts.Store.Get(KeyResolution) != val {
		opts.Store.Set(KeyResolution, val)
		saveStore(opts)
	}
}

// stepLocateGame finds the game executable. The flags (--game-exe, --wow-dir)
// and a valid remembered EXPLICIT choice bypass every question; otherwise the
// machine is SCANNED for installs and the user CHOOSES one before anything
// else happens with the game — never auto-proceed, even with a single find,
// because multi-install machines are common and guessing picks wrong
// (--choose-game re-opens the picker over a remembered choice). It then
// resolves the client type (--client-type beats every detection) and persists
// both. streamOnly reports a stamped non-1.x client: streaming works, but no
// addon variant can load there. staleVariant names the addon variant a PRIOR
// run wrongly installed for this same exe ("" = none): when a remembered
// Classic Era classification of a vanilla-plus-stamped exe (the pre-fix
// >=1.13 rule) is corrected to legacy, the Classic Era addon it planted must
// be cleaned out of AddOns — stepInstallAddon does the verified removal.
func stepLocateGame(opts *Options) (string, ClientType, bool, ClientType, error) {
	const label = "World of Warcraft"
	exe := ""
	knownType := ClientType("") // type already classified by the scanner
	chosenFrom := 0             // >0: picked from a scan of that many installs
	streamOnly := false

	switch {
	case opts.GameExeFlag != "":
		// Validated like --ffmpeg: a typo'd path fails here with a targeted
		// error, not later at launch. Accepted verbatim otherwise — any exe
		// name works (private servers).
		if st, err := os.Stat(opts.GameExeFlag); err != nil || st.IsDir() {
			return "", "", false, "", fmt.Errorf("--game-exe %q: not an existing file", opts.GameExeFlag)
		}
		exe = opts.GameExeFlag
	case opts.WowDirFlag != "":
		e, err := ResolveGameExe(opts.WowDirFlag)
		if err != nil {
			return "", "", false, "", fmt.Errorf("--wow-dir: %w", err)
		}
		exe = e
	default:
		if !opts.ChooseGame {
			exe = rememberedGameExe(opts) // fast path: prior explicit choice, no questions
		}
		if exe == "" {
			var err error
			if exe, knownType, chosenFrom, err = chooseGameFromScan(opts); err != nil {
				return "", "", false, "", err
			}
		}
	}

	if exe == "" {
		stepLine(opts.Out, 1, label, "not found automatically")
		var err error
		if exe, err = selectGamePathLoop(opts, ""); err != nil {
			return "", "", false, "", err
		}
	}

	ct := knownType
	explicit := false // the type was forced/answered for a vanilla-plus stamp
	switch {
	case opts.ClientTypeFlag != "":
		// --client-type: the user's word beats every detection — including a
		// scanner classification and any remembered answer — and rules out
		// the stream-only downgrade (they named a supported type on purpose).
		ct, streamOnly, explicit = opts.ClientTypeFlag, false, true
		fmt.Fprintf(opts.Out, "  client type forced to %s (--client-type)\n", ct)
	case ct == "":
		var err error
		if ct, streamOnly, explicit, err = resolveClientType(opts, exe); err != nil {
			return "", "", false, "", err
		}
	}

	// Misclassification migration (v0.3.2 field report): a vanilla-plus
	// stamped exe (OctoWow 1.18, Turtle 1.17) that the old >=1.13 rule
	// recorded as Classic Era just got re-resolved to legacy — say so plainly
	// and have the addon step remove the Classic Era addon that cannot load
	// on its 1.12 engine.
	staleVariant := ClientType("")
	if opts.Store.Get(KeyGameExe) == exe &&
		ClientType(opts.Store.Get(KeyClientType)) == ClientTypeClassicEra &&
		ct == ClientTypeLegacy {
		if v, ok := opts.peVersion(exe); ok && isVanillaPlusStamp(v) {
			staleVariant = ClientTypeClassicEra
			fmt.Fprintf(opts.Out,
				"  note: %s was set up as Classic Era earlier, but its %d.%d version stamp marks a vanilla-plus custom client on the 1.12 engine — corrected to %s.\n",
				filepath.Base(exe), v.Major, v.Minor, ct)
		}
	}

	persistGame(opts, exe, ct, explicit)
	result := fmt.Sprintf("found: %s (%s)", exe, ct)
	if chosenFrom > 0 {
		result = fmt.Sprintf("chosen: %s (%s) — from %d found", exe, ct, chosenFrom)
	}
	step(opts, 1, StepGame, label, hoststatus.StateOK, result)
	return exe, ct, streamOnly, staleVariant, nil
}

// rememberedGameExe returns the persisted prior choice while it is still
// valid: the recorded game exe, or the pre-game_exe wow_path key written by
// older versions. Only a store carrying the KeyGameChosen marker qualifies:
// releases before the install picker persisted registry/well-known
// auto-detections without ever asking the user, so a game_exe (or wow_path)
// lacking the marker is treated as unchosen — the caller then runs the scan,
// which orders the remembered install first as the picker's default, and the
// confirmed pick is persisted with the marker. Returns "" when there is no
// usable remembered explicit choice.
func rememberedGameExe(opts *Options) string {
	if opts.Store.Get(KeyGameChosen) != "1" {
		return "" // pre-picker auto-detection (or nothing): scan and ask once
	}
	if exe := opts.Store.Get(KeyGameExe); exe != "" {
		if st, err := os.Stat(exe); err == nil && !st.IsDir() {
			return exe
		}
	}
	// No KeyWowPath fallback here: the chosen marker is only ever written
	// together with KeyGameExe, so under the marker any surviving wow_path is
	// a stale pre-picker auto-detection the user never confirmed. A vanished
	// chosen exe must fall through to a fresh scan-and-ask, not silently
	// substitute a different install.
	return ""
}

// chooseGameFromScan scans the machine for game installs and resolves the
// choice. Interactive sessions ALWAYS get the picker when anything was found
// (a single candidate asks "use it?" rather than auto-proceeding);
// --yes/non-interactive sessions use a sole candidate but refuse to guess
// between several. Zero candidates return "" and the caller falls back to
// the manual not-found flow. chosenFrom is the scan size when a scanned
// candidate was picked (0 when the user browsed to a path of their own).
func chooseGameFromScan(opts *Options) (exe string, ct ClientType, chosenFrom int, err error) {
	cands := ScanGameCandidates(opts.Store, opts.Sys)
	if len(cands) == 0 {
		return "", "", 0, nil
	}

	if opts.Yes || !opts.Interactive {
		if len(cands) == 1 {
			return cands[0].ExePath, cands[0].Type, 1, nil
		}
		return "", "", 0, fmt.Errorf(
			"found %d World of Warcraft installs but cannot ask which one to use (--yes/non-interactive):\n%s\nrun interactively to pick, or pass --game-exe <program> (or --wow-dir <folder>) — never guessing between installs",
			len(cands), candidateListing(cands))
	}

	opts.Status.SetStep(StepGame, hoststatus.StateRunning, fmt.Sprintf("%d install(s) found — waiting for your choice", len(cands)))
	sel, err := opts.Prompt.ChooseGame(cands)
	if err != nil {
		if errors.Is(err, ErrGameChoiceCancelled) {
			return "", "", 0, errors.New("setup cancelled: no game was chosen (run again to pick, or pass --game-exe / --wow-dir)")
		}
		return "", "", 0, err
	}
	switch {
	case sel.Index >= 0 && sel.Index < len(cands):
		c := cands[sel.Index]
		return c.ExePath, c.Type, len(cands), nil
	case sel.Path != "":
		if e, rerr := ResolveGameExe(sel.Path); rerr == nil {
			return e, "", 0, nil
		} else {
			fmt.Fprintf(opts.Out, "  %v\n", rerr)
			e, perr := selectGamePathLoop(opts, strings.Trim(strings.TrimSpace(sel.Path), `"`))
			return e, "", 0, perr
		}
	default: // browse
		e, perr := selectGamePathLoop(opts, "")
		return e, "", 0, perr
	}
}

// selectGamePathLoop runs the manual location flow (console: pasted
// folder-or-exe path; GUI: folder browser with an exe-picker fallback) with
// up to five validation retries.
func selectGamePathLoop(opts *Options, prevInvalid string) (string, error) {
	for attempt := 0; attempt < 5; attempt++ {
		answer, err := opts.Prompt.SelectGamePath(prevInvalid)
		if err != nil {
			return "", fmt.Errorf("WoW was not found; pass its folder with --wow-dir or the game program with --game-exe (%w)", err)
		}
		if exe, rerr := ResolveGameExe(answer); rerr == nil {
			return exe, nil
		} else {
			prevInvalid = strings.Trim(strings.TrimSpace(answer), `"`)
			fmt.Fprintf(opts.Out, "  %v\n", rerr)
		}
	}
	return "", errors.New("no valid WoW location after 5 attempts; pass --wow-dir <folder> or --game-exe <program>")
}

// resolveClientType classifies the client behind exe: the version stamp read
// out of the executable itself first (rename-proof; see PEFileVersion), then
// the name/path heuristics, then the persisted earlier answer for this same
// exe, then the user. Under --yes / non-interactive, Confirm returns the
// non-guessing default (DefaultClientType: classicEra only for _classic_era_
// paths, else legacy) and the choice is logged either way. streamOnly is
// true for a stamped non-1.x client (expansion/retail): the returned type is
// only the nearer window-settings family — no addon variant can load there.
//
// A vanilla-plus stamp (major 1, minor 1.16+ — Turtle 1.17, OctoWow 1.18:
// custom clients on the 1.12 engine) is NOT conclusive: it falls through to
// the heuristics and, failing those, to the ask — whose text then says what
// was found and defaults to the 1.12 engine. explicit reports that the type
// was answered for such a stamp (KeyVanillaPlusResolvedFor is then recorded,
// so the misclassification migration below never re-asks a settled answer).
// That migration is the persisted-answer guard: a remembered classicEra for a
// vanilla-plus-stamped exe WITHOUT the resolved marker is the pre-fix >=1.13
// rule's doing (v0.3.2 field report) and is re-resolved once instead of
// being trusted.
func resolveClientType(opts *Options, exe string) (ct ClientType, streamOnly, explicit bool, err error) {
	var vpStamp GameVersion
	haveVPStamp := false
	if v, ok := opts.peVersion(exe); ok {
		if ct, ok := ClientTypeFromVersion(v); ok {
			return ct, false, false, nil
		}
		if v.Major != 1 {
			// A stamped non-1.x client (expansion/retail, or a 0.x-stamped
			// custom launcher): the 1.x name heuristics below would misread
			// its Wow.exe as a vanilla client, so pick the nearer supported
			// settings family by version instead (clientTypeForModernMajor)
			// and say so — matching the picker's stream-only label for the
			// same exe. Streaming works; the touch UI addon needs a Classic
			// Era (1.15) or 1.12 client.
			ct := clientTypeForModernMajor(v)
			fmt.Fprintf(opts.Out, "  %s is a %d.%d client — streaming works, but the touch UI addon needs Classic Era (1.15) or 1.12; using %s window settings.\n",
				filepath.Base(exe), v.Major, v.Minor, ct)
			return ct, true, false, nil
		}
		vpStamp, haveVPStamp = v, true // 1.16+: inconclusive, fall through
	}
	if ct, ok := DetectClientType(exe); ok {
		return ct, false, false, nil
	}
	if opts.Store.Get(KeyGameExe) == exe {
		prev := ClientType(opts.Store.Get(KeyClientType))
		stale := haveVPStamp && prev == ClientTypeClassicEra &&
			opts.Store.Get(KeyVanillaPlusResolvedFor) != exe
		if prev.valid() && !stale {
			return prev, false, false, nil
		}
		if stale {
			fmt.Fprintf(opts.Out,
				"  the remembered Classic Era classification for %s predates the corrected vanilla-plus rule — re-checking it once.\n",
				filepath.Base(exe))
		}
	}
	def := DefaultClientType(exe) == ClientTypeClassicEra
	question := "Is " + filepath.Base(exe) + " a WoW Classic Era (1.15) client? Choose No for a 1.12-era private-server client."
	if haveVPStamp {
		// Say what was found; official Classic Era stamps are 1.13–1.15, so a
		// higher 1.x stamp all but names a vanilla-plus client — default to
		// its real engine.
		def = false
		question = fmt.Sprintf(
			"%s reports version %d.%d — this looks like a custom vanilla-plus client (%d.%d), and these run the 1.12 engine (Turtle WoW, OctoWow, …). Treat it as a WoW Classic Era (1.15) client anyway? Choose No for the 1.12 engine (recommended).",
			filepath.Base(exe), vpStamp.Major, vpStamp.Minor, vpStamp.Major, vpStamp.Minor)
	}
	isClassic, err := opts.Prompt.Confirm(question, def)
	if err != nil {
		return "", false, false, err
	}
	ct = ClientTypeLegacy
	if isClassic {
		ct = ClientTypeClassicEra
	}
	if haveVPStamp {
		fmt.Fprintf(opts.Out, "  Treating %s (vanilla-plus %d.%d stamp) as a %s client.\n",
			filepath.Base(exe), vpStamp.Major, vpStamp.Minor, ct)
	} else {
		fmt.Fprintf(opts.Out, "  Unrecognized game program %s — treating it as a %s client.\n", filepath.Base(exe), ct)
	}
	return ct, false, haveVPStamp, nil
}

// persistGame stores the resolved exe and client type together (the type is
// only trusted while it matches the exe), plus the KeyGameChosen marker:
// every call site follows an explicit resolution — a flag, a picker pick, a
// pasted/browsed path, a --yes/non-interactive sole find, or a fast path
// that itself required the marker — never a silent auto-detection.
// vpResolved additionally records KeyVanillaPlusResolvedFor for this exe (an
// explicit answer/flag settled a vanilla-plus stamp's type — never re-ask); a
// marker left behind for a DIFFERENT exe is cleared, since it only ever
// speaks for the exe it was written with.
func persistGame(opts *Options, exe string, ct ClientType, vpResolved bool) {
	marker := opts.Store.Get(KeyVanillaPlusResolvedFor)
	wantMarker := marker
	switch {
	case vpResolved:
		wantMarker = exe
	case marker != "" && marker != exe:
		wantMarker = ""
	}
	if opts.Store.Get(KeyGameExe) != exe || opts.Store.Get(KeyClientType) != string(ct) ||
		opts.Store.Get(KeyGameChosen) != "1" || wantMarker != marker {
		opts.Store.Set(KeyGameExe, exe)
		opts.Store.Set(KeyClientType, string(ct))
		opts.Store.Set(KeyGameChosen, "1")
		opts.Store.Set(KeyVanillaPlusResolvedFor, wantMarker)
		saveStore(opts)
	}
}

func saveStore(opts *Options) {
	if err := opts.Store.Save(); err != nil {
		fmt.Fprintf(opts.Out, "  warning: %v (the wizard will re-detect next run)\n", err)
	}
}

// stepInstallAddon copies the embedded addon matching the client type into
// <gameDir>\Interface\AddOns — the Classic Era addon (WowMobile, Interface
// 11507) for Classic Era clients, its 1.12 port (WowMobile_Vanilla, Interface
// 11200, Lua 5.0) for legacy private-server clients — writing only files that
// are missing or changed; nothing else in AddOns is ever touched. Legacy
// clients additionally get a visible note (dashboard + console + one-time GUI
// dialog) that the Vanilla variant is the one to enable at character select.
// A streamOnly client (stamped non-1.x — the picker labeled it "stream only:
// touch UI addon unavailable") gets NO addon: its ClientType is only the
// nearer window-settings family, and copying either variant into a 2.x+
// client would plant an addon that cannot load there — so the step reports
// skipped instead. The skip also keeps LegacyAddonNote honest: the legacy
// branch below then only ever fires for an actual 1.12-era client, never for
// a 2.x–7.x expansion client that merely shares the legacy settings family.
//
// staleVariant ("" = none) names a variant a PRIOR run installed under a
// classification stepLocateGame just corrected (the vanilla-plus migration):
// that folder is removed — but ONLY after RemoveInstalledAddon verifies it
// really is this app's addon (ownership marker in the TOC, and only the
// variant's own files are deleted); anything else in AddOns stays untouched,
// always. The outcome lands in the step summary so windowed mode (no
// console) sees it on the dashboard too.
func stepInstallAddon(opts *Options, gameDir string, ct ClientType, streamOnly bool, staleVariant ClientType) error {
	const label = "WowMobile addon"
	if streamOnly {
		step(opts, 2, StepAddon, label, hoststatus.StateSkipped,
			"skipped — stream only: the touch UI addon needs a Classic Era (1.15) or 1.12 client")
		return nil
	}
	src, folder := addonVariant(opts, ct)
	dest := filepath.Join(gameDir, "Interface", "AddOns", folder)
	plan, err := PlanAddon(src, dest)
	if err != nil {
		return fmt.Errorf("comparing addon files: %w", err)
	}
	if plan.Changed() {
		if err := ApplyAddon(src, dest, plan); err != nil {
			return fmt.Errorf("installing addon into %s: %w", dest, err)
		}
	}
	summary := plan.Summary()
	if ct == ClientTypeLegacy {
		summary += " (WowMobile_Vanilla, 1.12 port)"
	}
	if staleVariant.valid() && staleVariant != ct {
		if note := removeStaleAddon(opts, gameDir, staleVariant); note != "" {
			summary += "; " + note
		}
	}
	step(opts, 2, StepAddon, label, hoststatus.StateOK, summary)
	if ct == ClientTypeLegacy {
		fmt.Fprintln(opts.Out, "  "+LegacyAddonNote)
		opts.Status.SetAddonNote(LegacyAddonNote)
		// The modal GUI notice must not nag on every start; the dashboard
		// note and the console print above repeat, the dialog shows once.
		if opts.Store.Get(KeyLegacyNoticeShown) != "1" {
			opts.Prompt.Notice("WoW Mobile", LegacyAddonNote)
			opts.Store.Set(KeyLegacyNoticeShown, "1")
			saveStore(opts)
		}
	}
	return nil
}

// addonVariant maps a client type to its embedded addon source and AddOns
// folder name: the Classic Era addon (WowMobile, Interface 11507) or its 1.12
// port (WowMobile_Vanilla, Interface 11200).
func addonVariant(opts *Options, ct ClientType) (fs.FS, string) {
	if ct == ClientTypeLegacy {
		return opts.VanillaAddonFS, "WowMobile_Vanilla"
	}
	return opts.AddonFS, "WowMobile"
}

// removeStaleAddon deletes the wrongly installed addon variant for a
// corrected classification (the vanilla-plus migration) and reports plainly
// what happened — on the console AND, via the returned short note, in the
// addon step's dashboard detail (windowed mode has no console). Never fatal:
// a leftover folder degrades to an honest message, not a failed wizard.
func removeStaleAddon(opts *Options, gameDir string, stale ClientType) string {
	src, folder := addonVariant(opts, stale)
	dest := filepath.Join(gameDir, "Interface", "AddOns", folder)
	removal, err := RemoveInstalledAddon(src, dest)
	switch {
	case err != nil:
		fmt.Fprintf(opts.Out, "  warning: could not remove the wrongly installed %s addon: %v — delete %s by hand.\n", folder, err, dest)
		return fmt.Sprintf("could not remove the old %s folder (delete it by hand)", folder)
	case removal == AddonRemovalDone:
		what := fmt.Sprintf("removed the wrongly installed %s (%s) addon — it cannot load on this client", folder, stale)
		if _, statErr := os.Stat(dest); statErr == nil {
			// Foreign files kept the folder alive; ours are gone, theirs stay.
			what += " (files not belonging to it were kept)"
		}
		fmt.Fprintf(opts.Out, "  %s: %s\n", what, dest)
		return what
	case removal == AddonRemovalForeign:
		fmt.Fprintf(opts.Out, "  left %s untouched: it does not carry this app's addon marker, so WoW Mobile did not install it.\n", dest)
		return fmt.Sprintf("left the existing %s folder untouched (not installed by WoW Mobile)", folder)
	}
	return "" // nothing was installed there — nothing to report
}

// stepConfigWTF ensures the portrait-window settings in <gameDir>\WTF\
// Config.wtf — the CVar names follow the client type (gxWindowedResolution on
// Classic Era, gxResolution on 1.12) — with a .bak backup and a minimal edit,
// but never while WoW is running, because the game rewrites the file on exit.
func stepConfigWTF(opts *Options, gameDir string, ct ClientType) error {
	const label = "Portrait resolution"
	want := PortraitSettingsFor(ct, opts.Width, opts.Height)
	resolution := fmt.Sprintf("%dx%d", opts.Width, opts.Height)
	path := filepath.Join(gameDir, "WTF", "Config.wtf")

	content, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		ok, perr := opts.Prompt.Confirm("WTF\\Config.wtf does not exist yet (fresh install). Create it with the portrait window settings?", true)
		if perr != nil {
			return perr
		}
		if !ok {
			step(opts, 3, StepConfig, label, hoststatus.StateSkipped, "skipped — configure the window manually (see --setup)")
			return nil
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(path, FreshConfig(want), 0o644); err != nil {
			return fmt.Errorf("creating %s: %w", path, err)
		}
		step(opts, 3, StepConfig, label, hoststatus.StateOK, fmt.Sprintf("Config.wtf created (%s windowed)", resolution))
		return nil
	}
	if err != nil {
		return fmt.Errorf("reading %s: %w", path, err)
	}

	if SettingsSatisfied(content, want) {
		step(opts, 3, StepConfig, label, hoststatus.StateOK, fmt.Sprintf("Config.wtf OK (%s windowed)", resolution))
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
			step(opts, 3, StepConfig, label, hoststatus.StateSkipped, "unchanged — close WoW and restart wowstreamd to apply "+resolution)
			return nil
		}
		fmt.Fprintln(opts.Out, "  Waiting for WoW to close (Ctrl+C to abort)...")
		opts.Status.SetStep(StepConfig, hoststatus.StateRunning, "waiting for WoW to close")
		if err := waitForGameWindow(opts, false, "WoW to close"); err != nil {
			return fmt.Errorf("%w; close WoW and restart wowstreamd to apply %s", err, resolution)
		}
	} else {
		ok, perr := opts.Prompt.Confirm(fmt.Sprintf("Update Config.wtf for a %s portrait window? (a Config.wtf%s backup is written first)", resolution, BackupSuffix), true)
		if perr != nil {
			return perr
		}
		if !ok {
			step(opts, 3, StepConfig, label, hoststatus.StateSkipped, "skipped — configure the window manually (see --setup)")
			return nil
		}
	}

	changed, err := ApplyConfigWTF(path, want)
	if err != nil {
		return fmt.Errorf("updating %s: %w", path, err)
	}
	if changed {
		step(opts, 3, StepConfig, label, hoststatus.StateOK, fmt.Sprintf("Config.wtf updated (%s windowed, backup: Config.wtf%s)", resolution, BackupSuffix))
	} else {
		step(opts, 3, StepConfig, label, hoststatus.StateOK, fmt.Sprintf("Config.wtf OK (%s windowed)", resolution))
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
			opts.Status.SetEncoder(enc)
			return fmt.Sprintf("found: %s available", enc)
		}
		return "found: " + path
	}
	found := func(path, suffix string) (string, error) {
		step(opts, 4, StepFFmpeg, label, hoststatus.StateOK, report(path)+suffix)
		return path, nil
	}

	if opts.FFmpegFlag != "" {
		// Validate the explicit override like --wow-dir: a typo'd path must
		// fail here with a targeted error, not later at the encoder probe.
		if st, err := os.Stat(opts.FFmpegFlag); err != nil || st.IsDir() {
			return "", fmt.Errorf("--ffmpeg %q: not an existing file", opts.FFmpegFlag)
		}
		return found(opts.FFmpegFlag, " (--ffmpeg)")
	}
	if path, ok := opts.Sys.LookPathFFmpeg(); ok {
		return found(path, "")
	}
	if path := opts.Store.Get(KeyFFmpegPath); path != "" {
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			return found(path, "")
		}
	}
	if path, ok := opts.Sys.WingetFFmpeg(); ok {
		persistFFmpeg(opts, path)
		return found(path, "")
	}

	step(opts, 4, StepFFmpeg, label, hoststatus.StateRunning, "not found")
	if !opts.Sys.HaveWinget() {
		fmt.Fprintln(opts.Out, "  winget is not available on this system.")
		fmt.Fprintln(opts.Out, FFmpegManualInstallHint)
		return "", errors.New("ffmpeg not found (install it, then restart wowstreamd, or pass --ffmpeg)")
	}
	ok, err := opts.Prompt.Confirm("FFmpeg (the video encoder WoW Mobile uses) is not installed. Install it now via winget? This runs in the background and can take a few minutes.", true)
	if err != nil {
		return "", err
	}
	if !ok {
		fmt.Fprintln(opts.Out, FFmpegManualInstallHint)
		return "", errors.New("ffmpeg not found (install it, then restart wowstreamd, or pass --ffmpeg)")
	}
	opts.Status.SetStep(StepFFmpeg, hoststatus.StateRunning, "installing FFmpeg via winget…")
	if err := opts.Sys.RunWingetInstall(opts.Out); err != nil {
		fmt.Fprintln(opts.Out, FFmpegManualInstallHint)
		return "", fmt.Errorf("winget install of FFmpeg failed: %w", err)
	}
	// The fresh install is not on this process's PATH — find the binary in
	// the WinGet packages directory and persist it for every future start.
	// On success the wizard continues automatically; no further prompt.
	if path, ok := opts.Sys.WingetFFmpeg(); ok {
		persistFFmpeg(opts, path)
		return found(path, " (installed via winget)")
	}
	return "", errors.New("winget reported success but ffmpeg.exe was not found under the WinGet packages directory; restart wowstreamd (new PATH) or pass --ffmpeg")
}

func persistFFmpeg(opts *Options, path string) {
	if opts.Store.Get(KeyFFmpegPath) != path {
		opts.Store.Set(KeyFFmpegPath, path)
		saveStore(opts)
	}
}

// stepGameRunning checks for the game window and offers to launch the
// recorded game executable, polling until the window (post-login) exists.
func stepGameRunning(opts *Options, gameExe string) error {
	const label = "Game running"
	if opts.Sys.GameWindowPresent(opts.WindowTitle) {
		step(opts, 5, StepRunning, label, hoststatus.StateOK, gameWindowDetail(opts))
		return nil
	}

	step(opts, 5, StepRunning, label, hoststatus.StateRunning, "no window matching "+fmt.Sprintf("%q", opts.WindowTitle))
	if !opts.Interactive && !opts.Yes {
		return errors.New("the WoW window was not found and stdin is not interactive; start WoW first, or run with --yes to auto-launch it")
	}
	ok, err := opts.Prompt.Confirm("Launch "+gameExe+" now?", true)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("WoW is not running; start it (windowed, not minimized), then restart wowstreamd")
	}
	if err := opts.Sys.LaunchGame(gameExe); err != nil {
		return fmt.Errorf("launching %s: %w", gameExe, err)
	}
	fmt.Fprintln(opts.Out, "  WoW is starting — log in to your character. Waiting for the game window (Ctrl+C to abort)...")
	opts.Status.SetStep(StepRunning, hoststatus.StateRunning, "waiting for the game window — log in to your character")
	if err := waitForGameWindow(opts, true, "the WoW window to appear"); err != nil {
		return fmt.Errorf("%w after launching %s; check that the game started (windowed, not minimized), then restart wowstreamd", err, filepath.Base(gameExe))
	}
	step(opts, 5, StepRunning, label, hoststatus.StateOK, gameWindowDetail(opts))
	return nil
}

// gameWindowDetail builds the game-running step's result line: "window found"
// plus the direct-resize outcome when one was needed. Windowed 1.12 clients
// ignore the gxResolution CVar (it governs fullscreen only), so the wizard
// resizes the found window to the decided resolution via SetWindowPos — the
// only mechanism that works on every windowed client. Failures/reverts are
// reported in the same line, never fatal: capture adapts to the actual
// window regardless.
func gameWindowDetail(opts *Options) string {
	detail := "window found"
	if msg, acted := opts.Sys.EnforceGameWindowSize(opts.WindowTitle, opts.Width, opts.Height); acted {
		fmt.Fprintln(opts.Out, "  "+msg)
		detail += " — " + msg
	}
	return detail
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
