//go:build windows

package winui

import (
	"errors"
	"runtime"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The notification-area icon: a hidden top-level window (WS_POPUP, never
// shown) owns it and pumps a real message loop on its own locked OS thread.
// It is deliberately NOT a message-only window (parent HWND_MESSAGE):
// message-only windows never receive broadcast messages, and the icon must
// see the shell's "TaskbarCreated" broadcast to re-add itself after an
// explorer.exe crash or restart — otherwise the tray icon (GUI mode's primary
// control surface) would be lost until wowstreamd restarts. A top-level
// window is also findable by class name ("WowMobileTray") with a plain
// FindWindow, which the NSIS installer/uninstaller running-instance checks
// rely on (installer/wowmobile.nsi). Left-click (or the menu's "Open
// dashboard") opens the dashboard; "Choose game…" (when wired) explains how
// to re-open the game-install picker; "Quit" runs the same graceful shutdown
// as the dashboard's Quit button and Ctrl+C.

var (
	user32   = windows.NewLazySystemDLL("user32.dll")
	kernel32 = windows.NewLazySystemDLL("kernel32.dll")

	procRegisterClassEx   = user32.NewProc("RegisterClassExW")
	procCreateWindowEx    = user32.NewProc("CreateWindowExW")
	procDestroyWindow     = user32.NewProc("DestroyWindow")
	procDefWindowProc     = user32.NewProc("DefWindowProcW")
	procGetMessage        = user32.NewProc("GetMessageW")
	procTranslateMessage  = user32.NewProc("TranslateMessage")
	procDispatchMessage   = user32.NewProc("DispatchMessageW")
	procPostMessage       = user32.NewProc("PostMessageW")
	procPostQuitMessage   = user32.NewProc("PostQuitMessage")
	procCreatePopupMenu   = user32.NewProc("CreatePopupMenu")
	procDestroyMenu       = user32.NewProc("DestroyMenu")
	procAppendMenu        = user32.NewProc("AppendMenuW")
	procTrackPopupMenu    = user32.NewProc("TrackPopupMenu")
	procGetCursorPos      = user32.NewProc("GetCursorPos")
	procSetForegroundWin  = user32.NewProc("SetForegroundWindow")
	procLoadImage         = user32.NewProc("LoadImageW")
	procLoadIcon          = user32.NewProc("LoadIconW")
	procRegisterWindowMsg = user32.NewProc("RegisterWindowMessageW")
	procGetModuleHandle   = kernel32.NewProc("GetModuleHandleW")
	procShellNotifyIcon   = shell32.NewProc("Shell_NotifyIconW")
)

const (
	wmDestroy      = 0x0002
	wmClose        = 0x0010
	wmCommand      = 0x0111
	wmApp          = 0x8000
	wmTrayCallback = wmApp + 1

	wmLButtonUp = 0x0202
	wmRButtonUp = 0x0205

	wsPopup = 0x80000000 // WS_POPUP without WS_VISIBLE: a hidden top-level window

	nimAdd    = 0x0
	nimModify = 0x1
	nimDelete = 0x2

	nifMessage = 0x1
	nifIcon    = 0x2
	nifTip     = 0x4

	mfString     = 0x0
	tpmReturnCmd = 0x0100
	tpmNoNotify  = 0x0080

	imageIcon = 1
	lrShared  = 0x8000 // LR_SHARED: system-cached handle, no leak on reloads

	idiApplication = 32512

	menuOpenID       = 1
	menuQuitID       = 2
	menuChooseGameID = 3
)

type wndClassEx struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     windows.Handle
	hIcon         windows.Handle
	hCursor       windows.Handle
	hbrBackground windows.Handle
	lpszMenuName  *uint16
	lpszClassName *uint16
	hIconSm       windows.Handle
}

type point struct{ x, y int32 }

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      point
}

type notifyIconData struct {
	cbSize           uint32
	hWnd             uintptr
	uID              uint32
	uFlags           uint32
	uCallbackMessage uint32
	hIcon            windows.Handle
	szTip            [128]uint16
	dwState          uint32
	dwStateMask      uint32
	szInfo           [256]uint16
	uVersion         uint32 // union with uTimeout
	szInfoTitle      [64]uint16
	dwInfoFlags      uint32
	guidItem         windows.GUID
	hBalloonIcon     windows.Handle
}

// TrayOptions configures the icon and its menu actions. Callbacks run on the
// tray's message-loop goroutine and must not block.
type TrayOptions struct {
	Tooltip      string
	OnOpen       func() // left-click / "Open dashboard"
	OnChooseGame func() // "Choose game…" menu item; nil hides the item
	OnQuit       func() // "Quit" menu item
}

// Tray is a live notification-area icon.
type Tray struct {
	opts TrayOptions

	mu    sync.Mutex
	hwnd  uintptr
	tip   string // current tooltip, for the TaskbarCreated re-add
	gone  bool
	ready chan error
}

// taskbarCreatedMsg is the registered "TaskbarCreated" broadcast message id —
// the shell sends it to all top-level windows when the taskbar (re)starts, and
// every tray app must answer it with a fresh NIM_ADD or its icon stays lost
// after an explorer.exe crash/restart. 0 until registered (a message id of 0
// is WM_NULL, which the wndproc never treats as TaskbarCreated).
var taskbarCreatedMsg uint32

// The WndProc callback is created once per process (NewCallback slots are a
// finite resource); it routes to the single active tray.
var (
	activeTrayMu sync.Mutex
	activeTray   *Tray
	wndProcOnce  sync.Once
	wndProcPtr   uintptr
)

// NewTray creates the icon and starts its message loop. Call Close to remove
// the icon (also happens on WM_CLOSE/Quit).
func NewTray(opts TrayOptions) (*Tray, error) {
	t := &Tray{opts: opts, tip: opts.Tooltip, ready: make(chan error, 1)}
	activeTrayMu.Lock()
	if activeTray != nil {
		activeTrayMu.Unlock()
		return nil, errors.New("tray icon already active")
	}
	activeTray = t
	activeTrayMu.Unlock()

	go t.loop()
	if err := <-t.ready; err != nil {
		activeTrayMu.Lock()
		activeTray = nil
		activeTrayMu.Unlock()
		return nil, err
	}
	return t, nil
}

// loop owns the window and the icon for their whole lifetime, on one locked
// OS thread — Win32 window affinity requires it.
func (t *Tray) loop() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	// The active-tray slot is released only when this loop is really over —
	// clearing it any earlier (e.g. in Close) would make trayWndProc route
	// WM_CLOSE/WM_DESTROY to DefWindowProc, so PostQuitMessage would never
	// run and this thread would leak. Idempotent with NewTray's own clearing
	// on startup failure.
	defer func() {
		activeTrayMu.Lock()
		if activeTray == t {
			activeTray = nil
		}
		activeTrayMu.Unlock()
	}()

	wndProcOnce.Do(func() {
		wndProcPtr = windows.NewCallback(trayWndProc)
	})

	// Register the shell's TaskbarCreated broadcast before the window exists,
	// so no early broadcast can slip by unrecognized. RegisterWindowMessageW
	// is idempotent (same atom for the same string), so re-running for a new
	// tray is fine; 0 (failure) simply disables the re-add handling.
	msgName := utf16Ptr("TaskbarCreated")
	tc, _, _ := procRegisterWindowMsg.Call(uintptr(unsafe.Pointer(msgName)))
	taskbarCreatedMsg = uint32(tc)

	hInst, _, _ := procGetModuleHandle.Call(0)
	className := utf16Ptr("WowMobileTray")
	wc := wndClassEx{
		lpfnWndProc:   wndProcPtr,
		hInstance:     windows.Handle(hInst),
		lpszClassName: className,
	}
	wc.cbSize = uint32(unsafe.Sizeof(wc))
	// A previous tray in this process already registered the class; that
	// registration (with the same WndProc) is fine to reuse.
	if atom, _, err := procRegisterClassEx.Call(uintptr(unsafe.Pointer(&wc))); atom == 0 &&
		err != windows.ERROR_CLASS_ALREADY_EXISTS {
		t.ready <- errors.New("RegisterClassExW failed: " + err.Error())
		return
	}
	// A hidden TOP-LEVEL window (WS_POPUP, never shown), not a message-only
	// one: message-only windows receive no broadcasts, and this window must
	// get TaskbarCreated (see the header comment). It also keeps the class
	// findable by the installer's plain-FindWindow running check.
	hwnd, _, err := procCreateWindowEx.Call(0, uintptr(unsafe.Pointer(className)), 0, wsPopup,
		0, 0, 0, 0, 0, 0, hInst, 0)
	if hwnd == 0 {
		t.ready <- errors.New("CreateWindowExW failed: " + err.Error())
		return
	}
	t.mu.Lock()
	t.hwnd = hwnd
	t.mu.Unlock()

	if err := t.notify(nimAdd, t.opts.Tooltip); err != nil {
		procDestroyWindow.Call(hwnd) //nolint:errcheck
		t.ready <- err
		return
	}
	t.ready <- nil

	var m msg
	for {
		r, _, _ := procGetMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 { // WM_QUIT or error
			break
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m))) //nolint:errcheck
		procDispatchMessage.Call(uintptr(unsafe.Pointer(&m)))  //nolint:errcheck
	}
	// The loop only exits through WM_DESTROY (Close/quit), where the icon
	// was already deleted; delete again defensively — NIM_DELETE on an
	// already-gone icon is a harmless failure.
	t.removeIcon()
}

// trayWndProc handles the icon callbacks on the loop thread.
func trayWndProc(hwnd uintptr, message uint32, wParam, lParam uintptr) uintptr {
	activeTrayMu.Lock()
	t := activeTray
	activeTrayMu.Unlock()
	if t == nil {
		ret, _, _ := procDefWindowProc.Call(hwnd, uintptr(message), wParam, lParam)
		return ret
	}
	if taskbarCreatedMsg != 0 && message == taskbarCreatedMsg {
		// The shell (re)started: every icon it was showing is gone, so add
		// ours back (unless it was intentionally removed for shutdown).
		t.reAddIcon()
		return 0
	}
	switch message {
	case wmTrayCallback:
		switch lParam {
		case wmLButtonUp:
			if t.opts.OnOpen != nil {
				t.opts.OnOpen()
			}
		case wmRButtonUp:
			t.showMenu(hwnd)
		}
		return 0
	case wmCommand:
		switch wParam & 0xffff {
		case menuOpenID:
			if t.opts.OnOpen != nil {
				t.opts.OnOpen()
			}
		case menuChooseGameID:
			if t.opts.OnChooseGame != nil {
				t.opts.OnChooseGame()
			}
		case menuQuitID:
			t.removeIcon()
			if t.opts.OnQuit != nil {
				t.opts.OnQuit()
			}
		}
		return 0
	case wmClose:
		procDestroyWindow.Call(hwnd) //nolint:errcheck
		return 0
	case wmDestroy:
		t.removeIcon()
		procPostQuitMessage.Call(0) //nolint:errcheck
		return 0
	}
	ret, _, _ := procDefWindowProc.Call(hwnd, uintptr(message), wParam, lParam)
	return ret
}

// showMenu pops the context menu at the cursor. TrackPopupMenu with
// TPM_RETURNCMD returns the chosen id directly; SetForegroundWindow first is
// the documented dance so the menu dismisses on outside clicks.
func (t *Tray) showMenu(hwnd uintptr) {
	menu, _, _ := procCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer procDestroyMenu.Call(menu)                                                                     //nolint:errcheck
	procAppendMenu.Call(menu, mfString, menuOpenID, uintptr(unsafe.Pointer(utf16Ptr("Open dashboard")))) //nolint:errcheck
	if t.opts.OnChooseGame != nil {
		procAppendMenu.Call(menu, mfString, menuChooseGameID, uintptr(unsafe.Pointer(utf16Ptr("Choose game…")))) //nolint:errcheck
	}
	procAppendMenu.Call(menu, mfString, menuQuitID, uintptr(unsafe.Pointer(utf16Ptr("Quit WoW Mobile")))) //nolint:errcheck

	var pt point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt))) //nolint:errcheck
	procSetForegroundWin.Call(hwnd)                     //nolint:errcheck
	cmd, _, _ := procTrackPopupMenu.Call(menu, tpmReturnCmd|tpmNoNotify,
		uintptr(pt.x), uintptr(pt.y), 0, hwnd, 0)
	// The other half of the documented dance (KB135788): post any message
	// after TrackPopupMenu returns, or the NEXT menu can refuse to dismiss
	// when the user clicks outside it. WM_NULL (0) is the canonical no-op.
	procPostMessage.Call(hwnd, 0 /* WM_NULL */, 0, 0) //nolint:errcheck
	switch cmd {
	case menuOpenID:
		if t.opts.OnOpen != nil {
			t.opts.OnOpen()
		}
	case menuChooseGameID:
		if t.opts.OnChooseGame != nil {
			t.opts.OnChooseGame()
		}
	case menuQuitID:
		t.removeIcon()
		if t.opts.OnQuit != nil {
			t.opts.OnQuit()
		}
	}
}

// appIcon loads the exe's own icon from the linked .syso, with the stock
// application icon as the fallback. The RT_GROUP_ICON's resource id is NOT 1:
// rsrc emits the manifest first, so the manifest takes id 1 and the icon
// group gets id 2 (with the RT_ICON frames following). LoadImageW only looks
// up RT_GROUP_ICON ids, so scanning the first few ids finds the group icon
// wherever a regenerated .syso puts it, without hard-coding today's layout.
// LR_SHARED hands back the system-cached handle, so the repeated NIM_MODIFY
// tooltip updates never accumulate HICONs.
func appIcon() windows.Handle {
	hInst, _, _ := procGetModuleHandle.Call(0)
	for id := uintptr(1); id <= 8; id++ {
		if h, _, _ := procLoadImage.Call(hInst, id, imageIcon, 0, 0, lrShared); h != 0 {
			return windows.Handle(h)
		}
	}
	h, _, _ := procLoadIcon.Call(0, idiApplication)
	return windows.Handle(h)
}

// notify issues one Shell_NotifyIconW call for this tray's icon.
func (t *Tray) notify(op uintptr, tooltip string) error {
	t.mu.Lock()
	hwnd, gone := t.hwnd, t.gone
	t.mu.Unlock()
	if hwnd == 0 || (gone && op != nimDelete) {
		return errors.New("tray window not available")
	}
	nid := notifyIconData{
		hWnd:             hwnd,
		uID:              1,
		uFlags:           nifMessage | nifIcon | nifTip,
		uCallbackMessage: wmTrayCallback,
		hIcon:            appIcon(),
	}
	nid.cbSize = uint32(unsafe.Sizeof(nid))
	tip, _ := windows.UTF16FromString(tooltip)
	copy(nid.szTip[:len(nid.szTip)-1], tip)
	ok, _, err := procShellNotifyIcon.Call(op, uintptr(unsafe.Pointer(&nid)))
	if ok == 0 {
		return errors.New("Shell_NotifyIconW failed: " + err.Error())
	}
	return nil
}

// SetTooltip updates the hover text ("WoW Mobile — streaming" / "— waiting
// for phone"). Safe from any goroutine. A failed NIM_MODIFY usually means the
// icon no longer exists (the shell restarted before its TaskbarCreated
// broadcast was processed), so it falls back to re-adding the icon rather
// than silently losing both the update and the icon.
func (t *Tray) SetTooltip(tip string) {
	t.mu.Lock()
	t.tip = tip
	t.mu.Unlock()
	if t.notify(nimModify, tip) != nil {
		t.reAddIcon()
	}
}

// reAddIcon re-issues NIM_ADD with the current tooltip after the shell lost
// the icon (TaskbarCreated broadcast, or a failed modify). A no-op once the
// icon was intentionally removed (shutdown), and harmless if the icon in fact
// still exists (the duplicate NIM_ADD just fails).
func (t *Tray) reAddIcon() {
	t.mu.Lock()
	gone, tip := t.gone, t.tip
	t.mu.Unlock()
	if gone {
		return
	}
	_ = t.notify(nimAdd, tip)
}

// removeIcon deletes the icon exactly once (all shutdown paths funnel here).
func (t *Tray) removeIcon() {
	t.mu.Lock()
	if t.gone {
		t.mu.Unlock()
		return
	}
	t.gone = true
	hwnd := t.hwnd
	t.mu.Unlock()
	if hwnd != 0 {
		nid := notifyIconData{hWnd: hwnd, uID: 1}
		nid.cbSize = uint32(unsafe.Sizeof(nid))
		procShellNotifyIcon.Call(nimDelete, uintptr(unsafe.Pointer(&nid))) //nolint:errcheck
	}
}

// Close removes the icon and stops the message loop. Idempotent; safe from
// any goroutine and from deferred shutdown paths. The active-tray slot is
// released by the loop itself once it has processed the WM_CLOSE below —
// clearing it here would race the loop thread out of its own shutdown
// (trayWndProc needs the tray to still be active to run PostQuitMessage).
func (t *Tray) Close() {
	t.removeIcon()
	t.mu.Lock()
	hwnd := t.hwnd
	t.mu.Unlock()
	if hwnd != 0 {
		procPostMessage.Call(hwnd, wmClose, 0, 0) //nolint:errcheck
	}
}
