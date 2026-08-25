//go:build windows

package wininput

import (
	"fmt"
	"log/slog"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/LcStylee/Wow-mobile/server/internal/input"
	"github.com/LcStylee/Wow-mobile/server/internal/window"
)

var (
	user32               = windows.NewLazySystemDLL("user32.dll")
	procSendInput        = user32.NewProc("SendInput")
	procMapVirtualKeyW   = user32.NewProc("MapVirtualKeyW")
	procGetSystemMetrics = user32.NewProc("GetSystemMetrics")
)

// Win32 constants used below (winuser.h).
const (
	inputMouse    = 0
	inputKeyboard = 1

	mouseeventfMove        = 0x0001
	mouseeventfLeftDown    = 0x0002
	mouseeventfLeftUp      = 0x0004
	mouseeventfRightDown   = 0x0008
	mouseeventfRightUp     = 0x0010
	mouseeventfMiddleDown  = 0x0020
	mouseeventfMiddleUp    = 0x0040
	mouseeventfWheel       = 0x0800
	mouseeventfVirtualDesk = 0x4000
	mouseeventfAbsolute    = 0x8000

	keyeventfExtendedKey = 0x0001
	keyeventfKeyUp       = 0x0002

	mapvkVKToVSC = 0

	smXVirtualScreen  = 76
	smYVirtualScreen  = 77
	smCXVirtualScreen = 78
	smCYVirtualScreen = 79
)

// mouseInput / keybdInput mirror MOUSEINPUT / KEYBDINPUT. The wrapper structs
// below reproduce the winuser.h INPUT layout for windows/amd64: 4-byte type,
// 4 bytes of alignment padding (the union starts pointer-aligned), then the
// union sized to its largest member (MOUSEINPUT, 32 bytes) => 40 bytes total.
type mouseInput struct {
	dx          int32
	dy          int32
	mouseData   uint32
	dwFlags     uint32
	time        uint32
	_           uint32 // pad so dwExtraInfo is 8-byte aligned
	dwExtraInfo uintptr
}

type keybdInput struct {
	wVk         uint16
	wScan       uint16
	dwFlags     uint32
	time        uint32
	_           uint32 // same alignment padding as in mouseInput
	dwExtraInfo uintptr
}

type mouseInputW struct {
	typ uint32
	_   uint32
	mi  mouseInput
}

type keybdInputW struct {
	typ uint32
	_   uint32
	ki  keybdInput
	_   [8]byte // pad the union up to sizeof(MOUSEINPUT)
}

// Compile-time layout assertions: SendInput silently misbehaves if cbSize
// disagrees with the OS struct, so fail the build instead. (This also pins
// the package to 64-bit Windows; windows/386 would need different padding.)
const win32InputSize = 40

var (
	_ [win32InputSize]byte = [unsafe.Sizeof(mouseInputW{})]byte{}
	_ [win32InputSize]byte = [unsafe.Sizeof(keybdInputW{})]byte{}
)

// extendedVKs are the virtual keys whose scancode requires the E0 prefix
// (KEYEVENTF_EXTENDEDKEY); without it e.g. Right Ctrl injects as Left Ctrl
// and the arrow keys act as the numpad.
var extendedVKs = map[uint16]bool{
	0x21: true, // VK_PRIOR (PgUp)
	0x22: true, // VK_NEXT (PgDn)
	0x23: true, // VK_END
	0x24: true, // VK_HOME
	0x25: true, // VK_LEFT
	0x26: true, // VK_UP
	0x27: true, // VK_RIGHT
	0x28: true, // VK_DOWN
	0x2C: true, // VK_SNAPSHOT
	0x2D: true, // VK_INSERT
	0x2E: true, // VK_DELETE
	0x5B: true, // VK_LWIN
	0x5C: true, // VK_RWIN
	0x6F: true, // VK_DIVIDE
	0x90: true, // VK_NUMLOCK
	0xA3: true, // VK_RCONTROL
	0xA5: true, // VK_RMENU
}

// Injector maps normalized protocol coordinates to the tracked WoW window and
// injects via SendInput. It enforces PROTOCOL.md safety rule 1: events that
// create state (downs, moves, wheel) require the game window to be
// foreground — otherwise it requests focus and reports the event dropped.
// Releases always inject so nothing can stay stuck.
type Injector struct {
	win *window.Tracker
	log *slog.Logger

	mu          sync.Mutex
	lastDropLog time.Time // throttles the not-foreground log line
}

func New(win *window.Tracker, log *slog.Logger) *Injector {
	return &Injector{win: win, log: log}
}

// requireForeground implements the focus-or-drop rule for state-entering
// events. SetForegroundWindow takes effect asynchronously, so the current
// event is always dropped when focus was missing; the client's next event
// lands in the now-focused window.
func (inj *Injector) requireForeground() error {
	if inj.win.IsForeground() {
		return nil
	}
	inj.win.Focus()
	inj.mu.Lock()
	if time.Since(inj.lastDropLog) > time.Second {
		inj.lastDropLog = time.Now()
		inj.mu.Unlock()
		inj.log.Warn("game window not foreground; requested focus and dropped event")
	} else {
		inj.mu.Unlock()
	}
	return input.ErrDropped
}

func (inj *Injector) PointerMove(x, y uint16) error {
	if err := inj.requireForeground(); err != nil {
		return err
	}
	dx, dy, err := inj.absoluteCoords(x, y)
	if err != nil {
		return err
	}
	return sendMouse(mouseInput{
		dx: dx, dy: dy,
		dwFlags: mouseeventfMove | mouseeventfAbsolute | mouseeventfVirtualDesk,
	})
}

func (inj *Injector) PointerButton(btn input.Button, down bool, x, y uint16) error {
	if down {
		if err := inj.requireForeground(); err != nil {
			return err
		}
	}
	var flag uint32
	switch btn {
	case input.ButtonLeft:
		flag = mouseeventfLeftDown
		if !down {
			flag = mouseeventfLeftUp
		}
	case input.ButtonRight:
		flag = mouseeventfRightDown
		if !down {
			flag = mouseeventfRightUp
		}
	case input.ButtonMiddle:
		flag = mouseeventfMiddleDown
		if !down {
			flag = mouseeventfMiddleUp
		}
	default:
		return fmt.Errorf("wininput: button %d out of range", btn)
	}
	dx, dy, err := inj.absoluteCoords(x, y)
	if err != nil {
		if !down {
			// Window gone mid-release: emit the button-up at the current
			// pointer position rather than losing the release.
			return sendMouse(mouseInput{dwFlags: flag})
		}
		return err
	}
	// Position and button transition in one atomic injection.
	return sendMouse(mouseInput{
		dx: dx, dy: dy,
		dwFlags: flag | mouseeventfMove | mouseeventfAbsolute | mouseeventfVirtualDesk,
	})
}

func (inj *Injector) Wheel(x, y uint16, delta int16) error {
	if err := inj.requireForeground(); err != nil {
		return err
	}
	dx, dy, err := inj.absoluteCoords(x, y)
	if err != nil {
		return err
	}
	// Move first so the wheel lands on the intended UI element, then scroll.
	// mouseData is documented as a signed value stored in a DWORD.
	return sendMouse(mouseInput{
		dx: dx, dy: dy,
		dwFlags: mouseeventfMove | mouseeventfAbsolute | mouseeventfVirtualDesk,
	}, mouseInput{
		mouseData: uint32(int32(delta)),
		dwFlags:   mouseeventfWheel,
	})
}

func (inj *Injector) Key(vk uint16, down bool) error {
	if down {
		if err := inj.requireForeground(); err != nil {
			return err
		}
	}
	scan, _, _ := procMapVirtualKeyW.Call(uintptr(vk), mapvkVKToVSC)
	var flags uint32
	if !down {
		flags |= keyeventfKeyUp
	}
	if extendedVKs[vk] {
		flags |= keyeventfExtendedKey
	}
	in := keybdInputW{
		typ: inputKeyboard,
		ki: keybdInput{
			wVk:     vk,
			wScan:   uint16(scan), // games often read scancodes, not VKs
			dwFlags: flags,
		},
	}
	return callSendInput(1, unsafe.Pointer(&in))
}

// absoluteCoords converts normalized client-area coordinates (0..65535 per
// PROTOCOL.md) to MOUSEEVENTF_ABSOLUTE|VIRTUALDESK coordinates (0..65535
// across the whole virtual desktop, which may span monitors and have a
// negative origin).
func (inj *Injector) absoluteCoords(nx, ny uint16) (int32, int32, error) {
	rc, err := inj.win.ClientRect()
	if err != nil {
		return 0, 0, err
	}
	if rc.W < 2 || rc.H < 2 {
		return 0, 0, fmt.Errorf("wininput: degenerate client rect %+v", rc)
	}
	// Inverse of the client's x = round(px/(clientWidth-1)*65535).
	px := rc.X + int(uint32(nx)*uint32(rc.W-1)+32767)/65535
	py := rc.Y + int(uint32(ny)*uint32(rc.H-1)+32767)/65535

	vx := getSystemMetrics(smXVirtualScreen)
	vy := getSystemMetrics(smYVirtualScreen)
	vw := getSystemMetrics(smCXVirtualScreen)
	vh := getSystemMetrics(smCYVirtualScreen)
	if vw < 2 || vh < 2 {
		return 0, 0, fmt.Errorf("wininput: virtual screen metrics unavailable")
	}
	// Windows maps absolute coordinate c to pixel floor(c*width/65536), so
	// pixel p is hit by the coordinate band starting at ceil(p*65536/width);
	// adding half a band keeps the value centered and rounding-safe.
	ax := clamp65535((int64(px-vx)*65536 + 32768) / int64(vw))
	ay := clamp65535((int64(py-vy)*65536 + 32768) / int64(vh))
	return ax, ay, nil
}

func clamp65535(v int64) int32 {
	if v < 0 {
		return 0
	}
	if v > 65535 {
		return 65535
	}
	return int32(v)
}

func getSystemMetrics(index int) int {
	v, _, _ := procGetSystemMetrics.Call(uintptr(index))
	return int(int32(v))
}

// sendMouse injects one or more mouse INPUT records in a single SendInput
// call so they cannot be interleaved with other injected input.
func sendMouse(inputs ...mouseInput) error {
	batch := make([]mouseInputW, len(inputs))
	for i, mi := range inputs {
		batch[i] = mouseInputW{typ: inputMouse, mi: mi}
	}
	return callSendInput(len(batch), unsafe.Pointer(&batch[0]))
}

func callSendInput(n int, ptr unsafe.Pointer) error {
	sent, _, callErr := procSendInput.Call(uintptr(n), uintptr(ptr), win32InputSize)
	if int(sent) != n {
		return fmt.Errorf("wininput: SendInput injected %d/%d events: %w", sent, n, callErr)
	}
	return nil
}
