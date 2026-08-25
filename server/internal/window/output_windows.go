//go:build windows

package window

import (
	"fmt"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	dxgi                   = windows.NewLazySystemDLL("dxgi.dll")
	procCreateDXGIFactory1 = dxgi.NewProc("CreateDXGIFactory1")
)

// iidIDXGIFactory1 is IID_IDXGIFactory1 {770AAE78-F26F-4DBA-A829-253C83D1B387}.
var iidIDXGIFactory1 = windows.GUID{
	Data1: 0x770aae78, Data2: 0xf26f, Data3: 0x4dba,
	Data4: [8]byte{0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87},
}

const (
	// hrDXGIErrorNotFound (DXGI_ERROR_NOT_FOUND) is how EnumAdapters and
	// EnumOutputs signal the end of enumeration.
	hrDXGIErrorNotFound = 0x887a0002
	// DXGI_MODE_ROTATION values under which an output's desktop coordinates
	// and its Desktop Duplication frames share the same orientation.
	rotationUnspecified = 0
	rotationIdentity    = 1
)

// The COM interfaces below are called through hand-laid vtables instead of a
// COM binding dependency: only three methods are needed. Slot layout per
// dxgi.h — IUnknown occupies slots 0-2, IDXGIObject 3-6, then each
// interface's own methods. Blank fields stand in for the slots not called.

type dxgiFactory1 struct{ vtbl *dxgiFactory1Vtbl }

type dxgiFactory1Vtbl struct {
	_            [2]uintptr // QueryInterface, AddRef
	Release      uintptr
	_            [4]uintptr // IDXGIObject
	EnumAdapters uintptr    // IDXGIFactory slot 7
}

type dxgiAdapter struct{ vtbl *dxgiAdapterVtbl }

type dxgiAdapterVtbl struct {
	_           [2]uintptr
	Release     uintptr
	_           [4]uintptr
	EnumOutputs uintptr // IDXGIAdapter slot 7
}

type dxgiOutput struct{ vtbl *dxgiOutputVtbl }

type dxgiOutputVtbl struct {
	_       [2]uintptr
	Release uintptr
	_       [4]uintptr
	GetDesc uintptr // IDXGIOutput slot 7
}

// dxgiOutputDesc mirrors DXGI_OUTPUT_DESC (dxgi.h).
type dxgiOutputDesc struct {
	deviceName         [32]uint16
	desktopCoordinates win32Rect
	attachedToDesktop  int32   // BOOL
	rotation           uint32  // DXGI_MODE_ROTATION
	monitor            uintptr // HMONITOR
}

// LocateOutput finds the DXGI output (monitor) on adapter 0 whose desktop
// rectangle fully contains rc. It returns the output's EnumOutputs index —
// the exact value ffmpeg's ddagrab filter takes as output_idx — and the
// output's desktop rectangle, so the caller can translate virtual-desktop
// screen coordinates into that output's local space (ddagrab's
// offset_x/offset_y are output-relative).
//
// Adapter 0 here is not a "primary monitor" assumption: ffmpeg's bare
// `-init_hw_device d3d11va` calls D3D11CreateDevice with a NULL adapter,
// which per the D3D11 docs means the default adapter — the one returned by
// IDXGIFactory::EnumAdapters(0) — and ddagrab (libavfilter/vsrc_ddagrab.c)
// then resolves output_idx via EnumOutputs on that same adapter. Replicating
// that exact enumeration, rather than using EnumDisplayMonitors or assuming
// the primary is output 0 (EnumOutputs order is not contractually
// primary-first), is what makes the returned index valid for ddagrab. A
// window on a monitor driven by a different adapter, or straddling monitors,
// is reported as an error and the caller falls back to gdigrab.
func LocateOutput(rc Rect) (outputIdx int, desktop Rect, err error) {
	if err := procCreateDXGIFactory1.Find(); err != nil {
		return 0, Rect{}, fmt.Errorf("dxgi.dll unavailable: %w", err)
	}
	var factory *dxgiFactory1
	hr, _, _ := procCreateDXGIFactory1.Call(
		uintptr(unsafe.Pointer(&iidIDXGIFactory1)),
		uintptr(unsafe.Pointer(&factory)),
	)
	if uint32(hr) != 0 {
		return 0, Rect{}, fmt.Errorf("CreateDXGIFactory1: HRESULT 0x%08x", uint32(hr))
	}
	defer syscall.SyscallN(factory.vtbl.Release, uintptr(unsafe.Pointer(factory))) //nolint:errcheck

	var adapter *dxgiAdapter
	hr, _, _ = syscall.SyscallN(factory.vtbl.EnumAdapters,
		uintptr(unsafe.Pointer(factory)), 0, uintptr(unsafe.Pointer(&adapter)))
	if uint32(hr) != 0 {
		return 0, Rect{}, fmt.Errorf("EnumAdapters(0): HRESULT 0x%08x", uint32(hr))
	}
	defer syscall.SyscallN(adapter.vtbl.Release, uintptr(unsafe.Pointer(adapter))) //nolint:errcheck

	for i := 0; ; i++ {
		var output *dxgiOutput
		hr, _, _ = syscall.SyscallN(adapter.vtbl.EnumOutputs,
			uintptr(unsafe.Pointer(adapter)), uintptr(i), uintptr(unsafe.Pointer(&output)))
		if uint32(hr) == hrDXGIErrorNotFound {
			return 0, Rect{}, fmt.Errorf(
				"no output of DXGI adapter 0 fully contains the window rect %dx%d at (%d,%d) — window straddling monitors, on a rotated display, or on another GPU's monitor",
				rc.W, rc.H, rc.X, rc.Y)
		}
		if uint32(hr) != 0 {
			return 0, Rect{}, fmt.Errorf("EnumOutputs(%d): HRESULT 0x%08x", i, uint32(hr))
		}
		var desc dxgiOutputDesc
		hrDesc, _, _ := syscall.SyscallN(output.vtbl.GetDesc,
			uintptr(unsafe.Pointer(output)), uintptr(unsafe.Pointer(&desc)))
		syscall.SyscallN(output.vtbl.Release, uintptr(unsafe.Pointer(output))) //nolint:errcheck
		if uint32(hrDesc) != 0 || desc.attachedToDesktop == 0 {
			continue
		}
		// On a rotated output, Desktop Duplication frames are in the panel's
		// native (pre-rotation) orientation while DesktopCoordinates are in
		// rotated desktop space, so an output-local crop rect computed here
		// would land on the wrong pixels. Skip such outputs; the containment
		// check then fails and the caller takes the gdigrab path.
		if desc.rotation != rotationUnspecified && desc.rotation != rotationIdentity {
			continue
		}
		d := Rect{
			X: int(desc.desktopCoordinates.left),
			Y: int(desc.desktopCoordinates.top),
			W: int(desc.desktopCoordinates.right - desc.desktopCoordinates.left),
			H: int(desc.desktopCoordinates.bottom - desc.desktopCoordinates.top),
		}
		if rc.X >= d.X && rc.Y >= d.Y && rc.X+rc.W <= d.X+d.W && rc.Y+rc.H <= d.Y+d.H {
			return i, d, nil
		}
	}
}
