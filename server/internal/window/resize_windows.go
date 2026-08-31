//go:build windows

package window

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	procGetWindowLongW           = user32.NewProc("GetWindowLongW")
	procGetWindowRect            = user32.NewProc("GetWindowRect")
	procSetWindowPos             = user32.NewProc("SetWindowPos")
	procAdjustWindowRectEx       = user32.NewProc("AdjustWindowRectEx")
	procAdjustWindowRectExForDpi = user32.NewProc("AdjustWindowRectExForDpi")
	procGetDpiForWindow          = user32.NewProc("GetDpiForWindow")
	procMonitorFromWindow        = user32.NewProc("MonitorFromWindow")
	procGetMonitorInfoW          = user32.NewProc("GetMonitorInfoW")
)

const (
	gwlStyle   = ^uintptr(15) // GWL_STYLE   = -16, as a pointer-sized value
	gwlExStyle = ^uintptr(19) // GWL_EXSTYLE = -20

	swpNoZOrder   = 0x0004
	swpNoActivate = 0x0010

	monitorDefaultToNearest = 0x2
)

// monitorInfo mirrors MONITORINFO.
type monitorInfo struct {
	cbSize    uint32
	rcMonitor win32Rect
	rcWork    win32Rect
}

// EnforceResult reports what EnforceClientSize did, with a ready log line.
type EnforceResult struct {
	Outcome EnforceOutcome
	// FinalW/FinalH is the client area after the attempt (or the current one
	// for skips), 0 when unreadable.
	FinalW, FinalH int
	// Message is the honest, human-readable summary for log/dashboard.
	Message string
}

// EnforceClientSize resizes the tracked window so its CLIENT area becomes
// wantW x wantH — the direct-window-resize path that makes the portrait size
// work on every WINDOWED client regardless of CVars (windowed 1.12 ignores
// gxResolution entirely; see resize.go). Fullscreen/maximized/minimized
// windows are never touched. The outer rect is computed with
// AdjustWindowRectExForDpi (plain AdjustWindowRectEx pre-1607) for the
// window's ACTUAL style bits, and the origin is clamped so the window stays
// on its monitor's work area. After each SetWindowPos the client rect is
// re-verified; one retry covers clients that re-assert their size once; a
// game that still reverts is reported honestly (the capture then adapts to
// the actual window as before).
func (t *Tracker) EnforceClientSize(wantW, wantH int) EnforceResult {
	hwnd, err := t.handle()
	if err != nil {
		return EnforceResult{Outcome: EnforceFailed, Message: "game window not found: " + err.Error()}
	}
	style32, _, _ := procGetWindowLongW.Call(uintptr(hwnd), gwlStyle)
	style := uint32(style32)
	exStyle32, _, _ := procGetWindowLongW.Call(uintptr(hwnd), gwlExStyle)
	exStyle := uint32(exStyle32)

	rc, err := t.ClientRect()
	if err != nil {
		return EnforceResult{Outcome: EnforceFailed, Message: "client rect unreadable: " + err.Error()}
	}

	apply := func(int) error { return setClientSize(hwnd, style, exStyle, wantW, wantH) }
	measure := func() (int, int, bool) {
		r, err := t.ClientRect()
		if err != nil {
			return 0, 0, false
		}
		return r.W, r.H, true
	}
	outcome := EnforceClientSizeWith(style, rc.W, rc.H, wantW, wantH, apply, measure)

	res := EnforceResult{Outcome: outcome, FinalW: rc.W, FinalH: rc.H}
	if w, h, ok := measure(); ok {
		res.FinalW, res.FinalH = w, h
	}
	switch outcome {
	case EnforceResized:
		res.Message = fmt.Sprintf("resized WoW window to %dx%d", res.FinalW, res.FinalH)
	case EnforceAlready:
		res.Message = fmt.Sprintf("WoW window already %dx%d", res.FinalW, res.FinalH)
	case EnforceSkipFullscreen:
		res.Message = "WoW is running fullscreen — cannot resize it; switch the game to windowed mode (gxWindow 1) for the portrait layout"
	case EnforceSkipMaximized:
		res.Message = "WoW window is maximized — not resizing it; un-maximize the window for the portrait layout"
	case EnforceSkipMinimized:
		res.Message = "WoW window is minimized — cannot size it now"
	case EnforceReverted:
		res.Message = fmt.Sprintf("WoW re-asserted its own window size (%dx%d) after two resize attempts — streaming the actual size instead", res.FinalW, res.FinalH)
	case EnforceFailed:
		res.Message = "window resize failed (SetWindowPos/GetClientRect error) — streaming the actual size instead"
	}
	return res
}

// setClientSize performs one SetWindowPos round: outer rect from the wanted
// client area for the window's actual style at its actual DPI, origin clamped
// to the containing monitor's work area.
func setClientSize(hwnd windows.HWND, style, exStyle uint32, clientW, clientH int) error {
	rect := win32Rect{left: 0, top: 0, right: int32(clientW), bottom: int32(clientH)}
	var ok uintptr
	if procAdjustWindowRectExForDpi.Find() == nil && procGetDpiForWindow.Find() == nil {
		dpi, _, _ := procGetDpiForWindow.Call(uintptr(hwnd))
		if dpi != 0 {
			ok, _, _ = procAdjustWindowRectExForDpi.Call(
				uintptr(unsafe.Pointer(&rect)), uintptr(style), 0, uintptr(exStyle), dpi)
		}
	}
	if ok == 0 {
		var err error
		ok, _, err = procAdjustWindowRectEx.Call(
			uintptr(unsafe.Pointer(&rect)), uintptr(style), 0, uintptr(exStyle))
		if ok == 0 {
			return fmt.Errorf("AdjustWindowRectEx: %w", err)
		}
	}
	outerW := int(rect.right - rect.left)
	outerH := int(rect.bottom - rect.top)

	// Current origin (outer rect) and the containing monitor's work area.
	var cur win32Rect
	if ok, _, err := procGetWindowRect.Call(uintptr(hwnd), uintptr(unsafe.Pointer(&cur))); ok == 0 {
		return fmt.Errorf("GetWindowRect: %w", err)
	}
	x, y := int(cur.left), int(cur.top)
	if work, ok := monitorWorkArea(hwnd); ok {
		x, y = ClampOrigin(x, y, outerW, outerH, work)
	}

	if ok, _, err := procSetWindowPos.Call(uintptr(hwnd), 0,
		uintptr(int32(x)), uintptr(int32(y)), uintptr(int32(outerW)), uintptr(int32(outerH)),
		swpNoZOrder|swpNoActivate); ok == 0 {
		return fmt.Errorf("SetWindowPos: %w", err)
	}
	return nil
}

// monitorWorkArea returns the work area (desktop minus taskbar) of the
// monitor containing the window.
func monitorWorkArea(hwnd windows.HWND) (Rect, bool) {
	hmon, _, _ := procMonitorFromWindow.Call(uintptr(hwnd), monitorDefaultToNearest)
	if hmon == 0 {
		return Rect{}, false
	}
	mi := monitorInfo{cbSize: uint32(unsafe.Sizeof(monitorInfo{}))}
	if ok, _, _ := procGetMonitorInfoW.Call(hmon, uintptr(unsafe.Pointer(&mi))); ok == 0 {
		return Rect{}, false
	}
	return Rect{
		X: int(mi.rcWork.left),
		Y: int(mi.rcWork.top),
		W: int(mi.rcWork.right - mi.rcWork.left),
		H: int(mi.rcWork.bottom - mi.rcWork.top),
	}, true
}
