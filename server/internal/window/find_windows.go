//go:build windows

package window

import (
	"fmt"
	"strings"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	user32                  = windows.NewLazySystemDLL("user32.dll")
	procEnumWindows         = user32.NewProc("EnumWindows")
	procGetWindowTextW      = user32.NewProc("GetWindowTextW")
	procIsWindowVisible     = user32.NewProc("IsWindowVisible")
	procIsWindow            = user32.NewProc("IsWindow")
	procIsIconic            = user32.NewProc("IsIconic")
	procGetClientRect       = user32.NewProc("GetClientRect")
	procClientToScreen      = user32.NewProc("ClientToScreen")
	procGetForegroundWindow = user32.NewProc("GetForegroundWindow")
	procSetForegroundWindow = user32.NewProc("SetForegroundWindow")
)

type point struct{ x, y int32 }

type win32Rect struct{ left, top, right, bottom int32 }

// Tracker resolves and caches the game window by title substring, re-running
// the window enumeration transparently if the cached handle dies (game
// restart). Safe for concurrent use by the injector and the capture setup.
type Tracker struct {
	titleSubstr string // matched case-insensitively

	mu   sync.Mutex
	hwnd windows.HWND
}

// NewTracker creates a tracker and performs the initial lookup so a missing
// window fails fast at startup with actionable guidance.
func NewTracker(titleSubstr string) (*Tracker, error) {
	t := &Tracker{titleSubstr: titleSubstr}
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
	hwnd, err := findByTitle(t.titleSubstr)
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

// enumState carries findByTitle's per-call arguments and result. Go retains
// every windows.NewCallback trampoline forever (hard cap ~2000 per process),
// so the EnumWindows callback is created exactly once and per-call state
// flows through this mutex-guarded package variable instead of a closure.
// The lock is held across the whole EnumWindows call; the callback runs
// synchronously on the calling thread under that lock, so it accesses the
// fields directly (taking the non-reentrant lock there would self-deadlock).
var enumState struct {
	sync.Mutex
	needle string // lower-cased title substring to match
	found  windows.HWND
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
	if minimized, _, _ := procIsIconic.Call(hwnd); minimized != 0 {
		return 1 // a minimized window has an empty client rect; keep looking
	}
	enumState.found = windows.HWND(hwnd)
	return 0 // stop enumeration
}

// findByTitle enumerates top-level windows and returns the first visible,
// non-minimized one whose title contains the substring (case-insensitive).
func findByTitle(titleSubstr string) (windows.HWND, error) {
	enumCallbackOnce.Do(func() { enumCallback = windows.NewCallback(enumWindowsCallback) })
	enumState.Lock()
	defer enumState.Unlock()
	enumState.needle = strings.ToLower(titleSubstr)
	enumState.found = 0
	// EnumWindows returns FALSE when the callback stopped it — not an error.
	procEnumWindows.Call(enumCallback, 0) //nolint:errcheck
	if enumState.found == 0 {
		return 0, fmt.Errorf(
			"no visible window with %q in its title — start WoW (windowed, not minimized) first, or pass the actual title via --window-title",
			titleSubstr)
	}
	return enumState.found, nil
}
