package window

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

// GDI screen grab of the tracked window's client area, for the phone-frame
// outline probe (DetectOutline). It copies from the SCREEN DC at the client
// rect's screen position — the DWM-composed picture, the same source gdigrab
// uses — so DirectX windows (windowed and borderless fullscreen) read
// correctly, where a window-DC BitBlt of a flip-model swap chain would be
// black. The process is per-monitor DPI aware (makeProcessDPIAware), so the
// rect and the pixels are physical.

var (
	gdi32                  = windows.NewLazySystemDLL("gdi32.dll")
	procCreateCompatibleDC = gdi32.NewProc("CreateCompatibleDC")
	procCreateDIBSection   = gdi32.NewProc("CreateDIBSection")
	procSelectObject       = gdi32.NewProc("SelectObject")
	procBitBlt             = gdi32.NewProc("BitBlt")
	procDeleteObject       = gdi32.NewProc("DeleteObject")
	procDeleteDC           = gdi32.NewProc("DeleteDC")
	procGdiFlush           = gdi32.NewProc("GdiFlush")
	procGetDC              = user32.NewProc("GetDC")
	procReleaseDC          = user32.NewProc("ReleaseDC")
)

const (
	srcCopy     = 0x00CC0020
	biRGB       = 0
	dibRGBColor = 0
)

type bitmapInfoHeader struct {
	Size          uint32
	Width         int32
	Height        int32
	Planes        uint16
	BitCount      uint16
	Compression   uint32
	SizeImage     uint32
	XPelsPerMeter int32
	YPelsPerMeter int32
	ClrUsed       uint32
	ClrImportant  uint32
}

// maxGrabPixels bounds one grab (8K x 8K) — a garbage rect must not become
// a multi-gigabyte allocation.
const maxGrabPixels = 8192 * 8192

// GrabClient copies the tracked window's client area off the screen and
// returns top-down BGRA pixels plus the client rect it was taken at.
func (t *Tracker) GrabClient() (pix []byte, rc Rect, err error) {
	rc, err = t.ClientRect()
	if err != nil {
		return nil, Rect{}, err
	}
	if rc.W <= 0 || rc.H <= 0 || rc.W*rc.H > maxGrabPixels {
		return nil, Rect{}, fmt.Errorf("window: client rect %dx%d not grabbable", rc.W, rc.H)
	}
	screen, _, _ := procGetDC.Call(0)
	if screen == 0 {
		return nil, Rect{}, fmt.Errorf("window: GetDC(screen) failed")
	}
	defer procReleaseDC.Call(0, screen) //nolint:errcheck
	mem, _, _ := procCreateCompatibleDC.Call(screen)
	if mem == 0 {
		return nil, Rect{}, fmt.Errorf("window: CreateCompatibleDC failed")
	}
	defer procDeleteDC.Call(mem) //nolint:errcheck
	bi := bitmapInfoHeader{
		Width:       int32(rc.W),
		Height:      -int32(rc.H), // negative: top-down rows
		Planes:      1,
		BitCount:    32,
		Compression: biRGB,
	}
	bi.Size = uint32(unsafe.Sizeof(bi))
	var bits unsafe.Pointer
	bmp, _, _ := procCreateDIBSection.Call(mem, uintptr(unsafe.Pointer(&bi)), dibRGBColor,
		uintptr(unsafe.Pointer(&bits)), 0, 0)
	if bmp == 0 || bits == nil {
		return nil, Rect{}, fmt.Errorf("window: CreateDIBSection %dx%d failed", rc.W, rc.H)
	}
	defer procDeleteObject.Call(bmp) //nolint:errcheck
	old, _, _ := procSelectObject.Call(mem, bmp)
	defer procSelectObject.Call(mem, old) //nolint:errcheck
	ok, _, _ := procBitBlt.Call(mem, 0, 0, uintptr(rc.W), uintptr(rc.H), screen,
		uintptr(int32(rc.X)), uintptr(int32(rc.Y)), srcCopy)
	if ok == 0 {
		return nil, Rect{}, fmt.Errorf("window: BitBlt failed")
	}
	procGdiFlush.Call() //nolint:errcheck
	n := rc.W * rc.H * 4
	pix = make([]byte, n)
	copy(pix, unsafe.Slice((*byte)(bits), n))
	return pix, rc, nil
}
