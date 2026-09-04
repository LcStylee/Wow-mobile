//go:build windows

package window

import (
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	user32                       = windows.NewLazySystemDLL("user32.dll")
	procEnumWindows              = user32.NewProc("EnumWindows")
	procGetWindowTextW           = user32.NewProc("GetWindowTextW")
	procIsWindowVisible          = user32.NewProc("IsWindowVisible")
	procIsWindow                 = user32.NewProc("IsWindow")
	procIsIconic                 = user32.NewProc("IsIconic")
	procGetClientRect            = user32.NewProc("GetClientRect")
	procClientToScreen           = user32.NewProc("ClientToScreen")
	procGetForegroundWindow      = user32.NewProc("GetForegroundWindow")
	procSetForegroundWindow      = user32.NewProc("SetForegroundWindow")
	procGetWindowThreadProcessId = user32.NewProc("GetWindowThreadProcessId")
)

type point struct{ x, y int32 }

type win32Rect struct{ left, top, right, bottom int32 }

// Tracker resolves and caches the game window by title substring — filtered,
// when an install directory is known, to windows whose owning process
// executable lives under that directory (procmatch.go: with several WoW
// installs the title alone cannot tell them apart, and capture/injection
// binding to the wrong instance is the v0.4.2 field failure). It re-runs the
// window enumeration transparently if the cached handle dies (game restart).
// Safe for concurrent use by the injector and the capture setup.
type Tracker struct {
	titleSubstr string // matched case-insensitively
	installDir  string // "" = title-only matching (no process-path filter)

	mu   sync.Mutex
	hwnd windows.HWND
}

// NewTracker creates a title-only tracker (no install-dir filter) and
// performs the initial lookup so a missing window fails fast at startup with
// actionable guidance.
func NewTracker(titleSubstr string) (*Tracker, error) {
	return NewTrackerFor(titleSubstr, "")
}

// NewTrackerFor creates a tracker bound to the install at installDir: among
// title-matching windows, only one whose owning process executable sits under
// installDir (any depth — VanillaFixes.exe launches Wow.exe from the same
// tree, so the DIRECTORY is matched, never an exact exe name) is accepted.
// installDir "" disables the filter (title-only, the pre-v0.4.3 behavior);
// a window whose process path cannot be read (elevated game) is matched by
// title alone with a logged note — never a regression to "no window found"
// for single-install users.
func NewTrackerFor(titleSubstr, installDir string) (*Tracker, error) {
	t := &Tracker{titleSubstr: titleSubstr, installDir: installDir}
	if _, err := t.handle(); err != nil {
		return nil, err
	}
	return t, nil
}

// handle returns a live window handle, re-finding the window if needed.
func (t *Tracker) handle() (windows.HWND, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.hwnd != 0 {
		alive, _, _ := procIsWindow.Call(uintptr(t.hwnd))
		if alive != 0 {
			return t.hwnd, nil
		}
		t.hwnd = 0
	}
	hwnd, err := findWindow(t.titleSubstr, t.installDir)
	if err != nil {
		return 0, err
	}
	t.hwnd = hwnd
	return hwnd, nil
}

// ClientRect returns the window's client area in screen coordinates.
func (t *Tracker) ClientRect() (Rect, error) {
	hwnd, err := t.handle()
	if err != nil {
		return Rect{}, err
	}
	var rc win32Rect
	if ok, _, callErr := procGetClientRect.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&rc))); ok == 0 {
		return Rect{}, fmt.Errorf("GetClientRect: %w", callErr)
	}
	origin := point{} // client (0,0)
	if ok, _, callErr := procClientToScreen.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&origin))); ok == 0 {
		return Rect{}, fmt.Errorf("ClientToScreen: %w", callErr)
	}
	return Rect{
		X: int(origin.x),
		Y: int(origin.y),
		W: int(rc.right - rc.left),
		H: int(rc.bottom - rc.top),
	}, nil
}

// Title returns the tracked window's current full title (GetWindowTextW).
// gdigrab's `title=` input resolves via FindWindow — an exact full-title
// match — while the tracker itself matches a substring; this bridges the two
// so a substring --window-title still yields a working gdigrab argv.
func (t *Tracker) Title() (string, error) {
	hwnd, err := t.handle()
	if err != nil {
		return "", err
	}
	var buf [256]uint16
	n, _, callErr := procGetWindowTextW.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 {
		return "", fmt.Errorf("GetWindowTextW: %w", callErr)
	}
	return windows.UTF16ToString(buf[:n]), nil
}

// TitleCollisions reports the tracked window's exact full title and how many
// visible top-level windows currently carry EXACTLY that title (minimized
// ones included — FindWindow finds those too). gdigrab's `title=` input
// resolves by exact title, so a count >= 2 means gdigrab cannot be steered to
// the tracked window and may grab another same-titled instance — the caller
// warns instead of silently streaming the wrong game (the ddagrab path is
// immune: it addresses a screen rect, not a title).
func (t *Tracker) TitleCollisions() (title string, count int, err error) {
	title, err = t.Title()
	if err != nil {
		return "", 0, err
	}
	for _, e := range enumTitleMatches(t.titleSubstr) {
		if e.title == title {
			count++
		}
	}
	return title, count, nil
}

// IsForeground reports whether the game window currently has focus.
func (t *Tracker) IsForeground() bool {
	hwnd, err := t.handle()
	if err != nil {
		return false
	}
	fg, _, _ := procGetForegroundWindow.Call()
	return windows.HWND(fg) == hwnd
}

// Focus asks Windows to bring the game window to the foreground. Windows may
// deny this (foreground lock) and only flash the taskbar; callers treat the
// event as dropped either way per the protocol's safety rule 1.
func (t *Tracker) Focus() {
	if hwnd, err := t.handle(); err == nil {
		procSetForegroundWindow.Call(uintptr(hwnd)) //nolint:errcheck // best effort by design
	}
}

// enumEntry is one visible window whose title matched the needle.
type enumEntry struct {
	hwnd      windows.HWND
	title     string
	minimized bool
}

// enumState carries the enumeration's per-call arguments and result. Go
// retains every windows.NewCallback trampoline forever (hard cap ~2000 per
// process), so the EnumWindows callback is created exactly once and per-call
// state flows through this mutex-guarded package variable instead of a
// closure. The lock is held across the whole EnumWindows call; the callback
// runs synchronously on the calling thread under that lock, so it accesses
// the fields directly (taking the non-reentrant lock there would
// self-deadlock).
var enumState struct {
	sync.Mutex
	needle string // lower-cased title substring to match
	found  []enumEntry
}

var (
	enumCallbackOnce sync.Once
	enumCallback     uintptr
)

func enumWindowsCallback(hwnd uintptr, _ uintptr) uintptr {
	if vis, _, _ := procIsWindowVisible.Call(hwnd); vis == 0 {
		return 1 // continue
	}
	var buf [256]uint16
	n, _, _ := procGetWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 {
		return 1
	}
	title := windows.UTF16ToString(buf[:n])
	if !strings.Contains(strings.ToLower(title), enumState.needle) {
		return 1
	}
	minimized, _, _ := procIsIconic.Call(hwnd)
	enumState.found = append(enumState.found, enumEntry{
		hwnd:      windows.HWND(hwnd),
		title:     title,
		minimized: minimized != 0,
	})
	return 1 // collect ALL matches: several WoW installs may be running
}

// enumTitleMatches enumerates top-level windows and returns every visible one
// whose title contains the substring (case-insensitive), in Z order.
func enumTitleMatches(titleSubstr string) []enumEntry {
	enumCallbackOnce.Do(func() { enumCallback = windows.NewCallback(enumWindowsCallback) })
	enumState.Lock()
	defer enumState.Unlock()
	enumState.needle = strings.ToLower(titleSubstr)
	enumState.found = nil
	procEnumWindows.Call(enumCallback, 0) //nolint:errcheck // enumerating to the end returns TRUE; either way found holds the matches
	return append([]enumEntry(nil), enumState.found...)
}

// findWindow returns the first visible, non-minimized window whose title
// contains the substring (case-insensitive) AND — when installDir is not ""
// — whose owning process executable sits under installDir (pickWindow holds
// the selection rules, including the title-only fallback for windows whose
// process cannot be queried).
func findWindow(titleSubstr, installDir string) (windows.HWND, error) {
	var cands []enumEntry
	for _, e := range enumTitleMatches(titleSubstr) {
		if e.minimized {
			continue // a minimized window has an empty client rect; keep looking
		}
		cands = append(cands, e)
	}
	if len(cands) == 0 {
		return 0, fmt.Errorf(
			"no visible window with %q in its title — start WoW (windowed, not minimized) first, or pass the actual title via --window-title",
			titleSubstr)
	}
	idx, note := pickWindow(len(cands), installDir, func(i int) (string, error) {
		return windowProcessPath(cands[i].hwnd)
	})
	logSelectionNote(note, idx >= 0)
	if idx < 0 {
		return 0, fmt.Errorf(
			"found %d visible window(s) with %q in the title, but none belongs to the configured install %s — an unrelated WoW instance may keep running; start the game from %s (or re-run setup / pass --game-exe to change the install)",
			len(cands), titleSubstr, installDir, installDir)
	}
	return cands[idx].hwnd, nil
}

// windowProcessPath returns the full executable path of the process owning
// hwnd: GetWindowThreadProcessId -> OpenProcess with
// PROCESS_QUERY_LIMITED_INFORMATION (succeeds across integrity levels far
// more often than PROCESS_QUERY_INFORMATION) -> QueryFullProcessImageNameW.
// An error (access denied on a protected/elevated process on hardened
// setups) means UNKNOWABLE — the caller must fall back to title matching for
// that window, never conclude "not the game".
func windowProcessPath(hwnd windows.HWND) (string, error) {
	var pid uint32
	procGetWindowThreadProcessId.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&pid))) //nolint:errcheck // pid==0 below is the failure signal
	if pid == 0 {
		return "", fmt.Errorf("GetWindowThreadProcessId: no process for window")
	}
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return "", fmt.Errorf("OpenProcess(pid %d): %w", pid, err)
	}
	defer windows.CloseHandle(h) //nolint:errcheck // query-only handle
	buf := make([]uint16, 4096)  // long-form paths; \\?\ prefixes fit too
	size := uint32(len(buf))
	if err := windows.QueryFullProcessImageName(h, 0, &buf[0], &size); err != nil {
		return "", fmt.Errorf("QueryFullProcessImageName(pid %d): %w", pid, err)
	}
	return windows.UTF16ToString(buf[:size]), nil
}

// logSelectionNote logs a window-selection fallback/exclusion note once per
// distinct message. The finder runs on every poll of the wizard's wait loops
// and before every capture launch, so an unchanged situation must not spam
// the log; a changed one (different error, filter back in force) logs again.
var selectionNoteState struct {
	sync.Mutex
	last string
}

func logSelectionNote(note string, picked bool) {
	selectionNoteState.Lock()
	defer selectionNoteState.Unlock()
	if note == selectionNoteState.last {
		return
	}
	selectionNoteState.last = note
	if note == "" {
		return
	}
	if picked {
		slog.Warn("game-window filter fallback", "detail", note)
	} else {
		slog.Info("game-window filter", "detail", note)
	}
}
