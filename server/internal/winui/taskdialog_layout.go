// TASKDIALOGCONFIG packed-buffer assembly, kept portable so the byte layout
// is unit-tested on every OS (taskdialog_layout_test.go) — the actual
// TaskDialogIndirect call sits in taskdialog_windows.go.
//
// WHY BYTES INSTEAD OF A GO STRUCT: commctrl.h wraps the task-dialog types in
// `#pragma pack(1)` (via pshpack1.h), so TASKDIALOGCONFIG and
// TASKDIALOG_BUTTON have NO alignment padding. Go structs always use natural
// alignment — a Go mirror of TASKDIALOGCONFIG would silently insert 4-byte
// holes after cbSize, dwCommonButtons, cButtons, … and every field beyond the
// first hole would land at the wrong offset, which TaskDialogIndirect
// answers with E_INVALIDARG at best and memory corruption at worst. The
// config is therefore assembled into a manually packed byte buffer, with
// every offset documented against the SDK header below and locked down by
// the portable test.
//
// Offsets: x64 (all pointers/handles 8 bytes), pack(1). Field order from the
// Windows SDK commctrl.h TASKDIALOGCONFIG declaration:
//
//	off  size  field
//	  0     4  UINT      cbSize
//	  4     8  HWND      hwndParent
//	 12     8  HINSTANCE hInstance
//	 20     4  TASKDIALOG_FLAGS dwFlags
//	 24     4  TASKDIALOG_COMMON_BUTTON_FLAGS dwCommonButtons
//	 28     8  PCWSTR    pszWindowTitle
//	 36     8  union { HICON hMainIcon; PCWSTR pszMainIcon; }
//	 44     8  PCWSTR    pszMainInstruction
//	 52     8  PCWSTR    pszContent
//	 60     4  UINT      cButtons
//	 64     8  const TASKDIALOG_BUTTON *pButtons
//	 72     4  int       nDefaultButton
//	 76     4  UINT      cRadioButtons
//	 80     8  const TASKDIALOG_BUTTON *pRadioButtons
//	 88     4  int       nDefaultRadioButton
//	 92     8  PCWSTR    pszVerificationText
//	100     8  PCWSTR    pszExpandedInformation
//	108     8  PCWSTR    pszExpandedControlText
//	116     8  PCWSTR    pszCollapsedControlText
//	124     8  union { HICON hFooterIcon; PCWSTR pszFooterIcon; }
//	132     8  PCWSTR    pszFooter
//	140     8  PFTASKDIALOGCALLBACK pfCallback
//	148     8  LONG_PTR  lpCallbackData
//	156     4  UINT      cxWidth
//	160        total (== cbSize)
//
// TASKDIALOG_BUTTON, same pack(1) x64 rule:
//
//	off  size  field
//	  0     4  int    nButtonID
//	  4     8  PCWSTR pszButtonText
//	 12        total  (stride in the pButtons array — NOT the 16 a naturally
//	                   aligned Go struct would occupy)
package winui

import "encoding/binary"

// TASKDIALOGCONFIG field offsets (x64, pack(1)) — see the header table.
const (
	tdcOffCbSize               = 0
	tdcOffHwndParent           = 4
	tdcOffHInstance            = 12
	tdcOffFlags                = 20
	tdcOffCommonButtons        = 24
	tdcOffWindowTitle          = 28
	tdcOffMainIcon             = 36
	tdcOffMainInstruction      = 44
	tdcOffContent              = 52
	tdcOffCButtons             = 60
	tdcOffPButtons             = 64
	tdcOffDefaultButton        = 72
	tdcOffCRadioButtons        = 76
	tdcOffPRadioButtons        = 80
	tdcOffDefaultRadioButton   = 88
	tdcOffVerificationText     = 92
	tdcOffExpandedInformation  = 100
	tdcOffExpandedControlText  = 108
	tdcOffCollapsedControlText = 116
	tdcOffFooterIcon           = 124
	tdcOffFooter               = 132
	tdcOffCallback             = 140
	tdcOffCallbackData         = 148
	tdcOffCxWidth              = 156
	tdcSize                    = 160 // sizeof(TASKDIALOGCONFIG), pack(1) x64
)

// TASKDIALOG_BUTTON layout (pack(1) x64).
const (
	tdBtnOffID   = 0
	tdBtnOffText = 4
	tdBtnStride  = 12 // sizeof(TASKDIALOG_BUTTON): 4-byte id + 8-byte PCWSTR, no padding
)

// Task-dialog flags and common-button bits used by the game picker
// (commctrl.h values).
const (
	tdfAllowDialogCancellation  = 0x0008
	tdfUseCommandLinks          = 0x0010
	tdfPositionRelativeToWindow = 0x1000
	tdfSizeToContent            = 0x0100_0000

	tdcbfCancelButton = 0x0008 // TDCBF_CANCEL_BUTTON — also enables Esc / the X
)

// tdcValues carries everything the game picker fills into TASKDIALOGCONFIG.
// Pointer-typed fields (PCWSTR, pButtons) travel as uint64 so this file
// stays portable; the Windows caller supplies real pointer values and keeps
// the pointed-to memory alive across the TaskDialogIndirect call.
type tdcValues struct {
	flags           uint32
	commonButtons   uint32
	windowTitle     uint64 // PCWSTR
	mainInstruction uint64 // PCWSTR
	content         uint64 // PCWSTR
	buttonCount     uint32
	buttonsPtr      uint64 // const TASKDIALOG_BUTTON *
	defaultButton   int32
}

// packTaskDialogConfig assembles the packed TASKDIALOGCONFIG byte image.
// Unset fields (parent window, icons, radio buttons, footer, callback,
// width) stay zero, which is their documented "none" value.
func packTaskDialogConfig(v tdcValues) []byte {
	buf := make([]byte, tdcSize)
	putU32(buf, tdcOffCbSize, tdcSize)
	putU32(buf, tdcOffFlags, v.flags)
	putU32(buf, tdcOffCommonButtons, v.commonButtons)
	putU64(buf, tdcOffWindowTitle, v.windowTitle)
	putU64(buf, tdcOffMainInstruction, v.mainInstruction)
	putU64(buf, tdcOffContent, v.content)
	putU32(buf, tdcOffCButtons, v.buttonCount)
	putU64(buf, tdcOffPButtons, v.buttonsPtr)
	putU32(buf, tdcOffDefaultButton, uint32(v.defaultButton))
	return buf
}

// packTaskDialogButtons assembles the packed TASKDIALOG_BUTTON array
// (12-byte stride). ids and textPtrs must be the same length; textPtrs are
// PCWSTR pointer values the caller keeps alive.
func packTaskDialogButtons(ids []int32, textPtrs []uint64) []byte {
	buf := make([]byte, len(ids)*tdBtnStride)
	for i := range ids {
		off := i * tdBtnStride
		putU32(buf, off+tdBtnOffID, uint32(ids[i]))
		putU64(buf, off+tdBtnOffText, textPtrs[i])
	}
	return buf
}

func putU32(buf []byte, off int, v uint32) { binary.LittleEndian.PutUint32(buf[off:], v) }
func putU64(buf []byte, off int, v uint64) { binary.LittleEndian.PutUint64(buf[off:], v) }
