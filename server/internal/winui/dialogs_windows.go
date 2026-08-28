//go:build windows

package winui

import (
	"errors"
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Title is the caption used on every dialog.
const Title = "WoW Mobile"

var (
	shell32                 = windows.NewLazySystemDLL("shell32.dll")
	comdlg32                = windows.NewLazySystemDLL("comdlg32.dll")
	procSHBrowseForFolder   = shell32.NewProc("SHBrowseForFolderW")
	procSHGetPathFromIDList = shell32.NewProc("SHGetPathFromIDListW")
	procILFree              = shell32.NewProc("ILFree")
	procGetOpenFileName     = comdlg32.NewProc("GetOpenFileNameW")
)

// MessageBox flag/result values not exported by x/sys/windows.
const (
	idOK     = 1
	idCancel = 2
	idYes    = 6
	idNo     = 7
)

// utf16Ptr converts s, replacing interior NULs instead of failing — dialog
// text comes from error strings that must never make the dialog itself fail.
func utf16Ptr(s string) *uint16 {
	p, err := windows.UTF16PtrFromString(s)
	if err != nil {
		p, _ = windows.UTF16PtrFromString("(text unavailable)")
	}
	return p
}

// messageBox shows a MessageBoxW with the standard caption, always topmost so
// a first-run user cannot lose the dialog behind other windows.
func messageBox(text string, flags uint32) int32 {
	ret, _ := windows.MessageBox(0, utf16Ptr(text), utf16Ptr(Title), flags|windows.MB_TOPMOST|windows.MB_SETFOREGROUND)
	return ret
}

// AskYesNo shows a yes/no question dialog and reports whether Yes was chosen.
// def selects the pre-focused button.
func AskYesNo(text string, def bool) bool {
	flags := uint32(windows.MB_YESNO | windows.MB_ICONQUESTION)
	if !def {
		flags |= windows.MB_DEFBUTTON2
	}
	return messageBox(text, flags) == idYes
}

// Info shows an information dialog (OK only).
func Info(text string) {
	messageBox(text, windows.MB_OK|windows.MB_ICONINFORMATION)
}

// Error shows an error dialog (OK only) — GUI mode's replacement for a fatal
// message on stderr; never a silent death.
func Error(text string) {
	messageBox(text, windows.MB_OK|windows.MB_ICONERROR)
}

// retryChoice is the three-way answer to a failed folder pick.
type retryChoice int

const (
	retryFolder retryChoice = iota // pick a folder again
	retryExe                       // pick the game .exe directly
	retryCancel                    // give up
)

// askRetry presents the invalid-selection follow-up: Yes = choose the folder
// again, No = pick the game program (.exe) yourself, Cancel = stop.
func askRetry(text string) retryChoice {
	switch messageBox(text, windows.MB_YESNOCANCEL|windows.MB_ICONQUESTION) {
	case idYes:
		return retryFolder
	case idNo:
		return retryExe
	default:
		return retryCancel
	}
}

// SHBrowseForFolder plumbing.
type browseInfo struct {
	hwndOwner      windows.HWND
	pidlRoot       uintptr
	pszDisplayName *uint16
	lpszTitle      *uint16
	ulFlags        uint32
	lpfn           uintptr
	lParam         uintptr
	iImage         int32
}

const (
	bifReturnOnlyFSDirs = 0x00000001
	bifNewDialogStyle   = 0x00000040
)

// ErrCancelled is returned when the user dismisses a picker dialog.
var ErrCancelled = errors.New("cancelled by user")

// coInit enters an apartment for the shell dialogs (BIF_NEWDIALOGSTYLE
// requires OLE) and returns the matching cleanup. Callers must be locked to
// an OS thread. S_OK and S_FALSE (already initialized) both require
// CoUninitialize; a mode mismatch means COM is already up and needs nothing.
func coInit() func() {
	const sFalse = syscall.Errno(1)
	err := windows.CoInitializeEx(0, windows.COINIT_APARTMENTTHREADED|windows.COINIT_DISABLE_OLE1DDE)
	if err == nil || errors.Is(err, sFalse) {
		return windows.CoUninitialize
	}
	return func() {}
}

// BrowseForFolder shows the shell folder picker and returns the chosen
// directory, or ErrCancelled.
func BrowseForFolder(title string) (string, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	defer coInit()()

	display := make([]uint16, windows.MAX_PATH)
	bi := browseInfo{
		pszDisplayName: &display[0],
		lpszTitle:      utf16Ptr(title),
		ulFlags:        bifReturnOnlyFSDirs | bifNewDialogStyle,
	}
	pidl, _, _ := procSHBrowseForFolder.Call(uintptr(unsafe.Pointer(&bi)))
	if pidl == 0 {
		return "", ErrCancelled
	}
	// The PIDL is task memory owned by us: ILFree (== CoTaskMemFree for
	// whole ID lists) releases it whatever happens next.
	defer procILFree.Call(pidl) //nolint:errcheck

	buf := make([]uint16, windows.MAX_PATH)
	ok, _, _ := procSHGetPathFromIDList.Call(pidl, uintptr(unsafe.Pointer(&buf[0])))
	if ok == 0 {
		return "", errors.New("selected item has no filesystem path")
	}
	return windows.UTF16ToString(buf), nil
}

// GetOpenFileNameW plumbing.
type openFileName struct {
	lStructSize       uint32
	hwndOwner         windows.HWND
	hInstance         windows.Handle
	lpstrFilter       *uint16
	lpstrCustomFilter *uint16
	nMaxCustFilter    uint32
	nFilterIndex      uint32
	lpstrFile         *uint16
	nMaxFile          uint32
	lpstrFileTitle    *uint16
	nMaxFileTitle     uint32
	lpstrInitialDir   *uint16
	lpstrTitle        *uint16
	flags             uint32
	nFileOffset       uint16
	nFileExtension    uint16
	lpstrDefExt       *uint16
	lCustData         uintptr
	lpfnHook          uintptr
	lpTemplateName    *uint16
	pvReserved        uintptr
	dwReserved        uint32
	flagsEx           uint32
}

const (
	ofnFileMustExist = 0x00001000
	ofnPathMustExist = 0x00000800
	ofnNoChangeDir   = 0x00000008
)

// utf16Filter builds the double-NUL-terminated filter string pairs.
func utf16Filter(pairs ...string) []uint16 {
	var out []uint16
	for _, s := range pairs {
		u, _ := windows.UTF16FromString(s) // includes the terminating NUL
		out = append(out, u...)
	}
	return append(out, 0) // final extra NUL ends the filter list
}

// PickExeFile shows the open-file dialog filtered to programs; any .exe can
// be chosen (private servers launch through arbitrary names). Returns
// ErrCancelled when dismissed.
func PickExeFile(title string) (string, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	defer coInit()()

	file := make([]uint16, 32*1024)
	filter := utf16Filter("Programs (*.exe)", "*.exe", "All files (*.*)", "*.*")
	ofn := openFileName{
		lpstrFilter: &filter[0],
		lpstrFile:   &file[0],
		nMaxFile:    uint32(len(file)),
		lpstrTitle:  utf16Ptr(title),
		flags:       ofnFileMustExist | ofnPathMustExist | ofnNoChangeDir,
	}
	ofn.lStructSize = uint32(unsafe.Sizeof(ofn))
	ok, _, _ := procGetOpenFileName.Call(uintptr(unsafe.Pointer(&ofn)))
	if ok == 0 {
		return "", ErrCancelled
	}
	return windows.UTF16ToString(file), nil
}

// SelectGameLocation runs the full GUI game-picking flow: an explanation, the
// folder browser, and — after an invalid pick (prevInvalid != "") — a
// retry/pick-the-exe/cancel loop. It returns a path for the wizard to
// validate, or ErrCancelled.
func SelectGameLocation(prevInvalid string) (string, error) {
	if prevInvalid == "" {
		Info("WoW Mobile could not find your World of Warcraft installation automatically.\n\n" +
			"Next, pick the folder World of Warcraft is installed in.\n" +
			"The \"World of Warcraft\" folder itself is fine — WoW Mobile finds the right game inside it.")
		dir, err := BrowseForFolder("Select your World of Warcraft folder")
		if err != nil {
			return "", err
		}
		return dir, nil
	}
	choice := askRetry("That folder does not seem to contain World of Warcraft:\n\n" + prevInvalid + "\n\n" +
		"Yes — choose a different folder\n" +
		"No — pick the game program (.exe) yourself (private servers: Wow.exe, VanillaFixes.exe, …)\n" +
		"Cancel — stop here")
	switch choice {
	case retryFolder:
		return BrowseForFolder("Select your World of Warcraft folder")
	case retryExe:
		return PickExeFile("Pick your game program (.exe)")
	default:
		return "", ErrCancelled
	}
}
