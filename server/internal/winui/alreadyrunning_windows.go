//go:build windows

package winui

import (
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The "WoW Mobile is already running" dialog a second launch shows in GUI
// mode: a native task dialog with three command links (open the running
// copy's dashboard / replace it / exit), reusing the packed-buffer plumbing
// the game picker uses (taskdialog_layout.go). Where task dialogs are
// unavailable (comctl32 without v6 — effectively never with the shipped
// manifest), a plain Yes/No/Cancel message box carries the same choices.

// AlreadyRunningChoice is the dialog's outcome.
type AlreadyRunningChoice int

const (
	// AlreadyRunningExit leaves the running copy in charge (also the answer
	// for Esc/the X/Cancel — the safe default).
	AlreadyRunningExit AlreadyRunningChoice = iota
	// AlreadyRunningOpenDashboard opens the running copy's dashboard.
	AlreadyRunningOpenDashboard
	// AlreadyRunningReplace quits the running copy and starts this one.
	AlreadyRunningReplace
)

// Command-link button IDs, outside the game picker's ranges.
const (
	alreadyRunningOpenID    = 2100
	alreadyRunningReplaceID = 2101
	alreadyRunningExitID    = 2102
)

// AskAlreadyRunning shows the small already-running dialog and returns the
// user's choice. It never fails: any dialog-machinery problem degrades to
// the message-box fallback, and any dismissal means Exit.
func AskAlreadyRunning(dashboardURL string) AlreadyRunningChoice {
	if choice, ok := askAlreadyRunningTaskDialog(dashboardURL); ok {
		return choice
	}
	switch messageBox("WoW Mobile is already running.\n\n"+
		"Yes — open the running copy's dashboard\n"+
		"No — replace it: quit the running copy and start this one\n"+
		"Cancel — exit and leave it running", windows.MB_YESNOCANCEL|windows.MB_ICONINFORMATION|windows.MB_DEFBUTTON3) {
	case idYes:
		return AlreadyRunningOpenDashboard
	case idNo:
		return AlreadyRunningReplace
	}
	return AlreadyRunningExit
}

// askAlreadyRunningTaskDialog is the command-link variant; ok=false sends
// the caller to the message-box fallback.
func askAlreadyRunningTaskDialog(dashboardURL string) (AlreadyRunningChoice, bool) {
	if procTaskDialogIndirect.Find() != nil {
		return AlreadyRunningExit, false
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	// UTF-16 string pool kept alive across the raw call (the packed buffers
	// hold raw pointers Go's GC does not trace inside a []byte).
	var pool [][]uint16
	pin := func(s string) uint64 {
		u, err := windows.UTF16FromString(s)
		if err != nil {
			u, _ = windows.UTF16FromString("(text unavailable)")
		}
		pool = append(pool, u)
		return uint64(uintptr(unsafe.Pointer(&u[0])))
	}

	ids := []int32{alreadyRunningOpenID, alreadyRunningReplaceID, alreadyRunningExitID}
	texts := []uint64{
		pin("Open dashboard\nShow the running copy's status page in your browser"),
		pin("Replace it\nQuit the running copy, then start this one"),
		pin("Exit\nLeave the running copy as it is"),
	}
	buttons := packTaskDialogButtons(ids, texts)

	cfg := packTaskDialogConfig(tdcValues{
		flags: tdfUseCommandLinks | tdfAllowDialogCancellation |
			tdfPositionRelativeToWindow | tdfSizeToContent,
		commonButtons:   tdcbfCancelButton,
		windowTitle:     pin(Title),
		mainInstruction: pin("WoW Mobile is already running"),
		content: pin("Only one copy of WoW Mobile can run at a time.\n" +
			"Running copy's dashboard: " + dashboardURL),
		buttonCount:   uint32(len(ids)),
		buttonsPtr:    uint64(uintptr(unsafe.Pointer(&buttons[0]))),
		defaultButton: alreadyRunningOpenID,
	})

	var pressed int32
	hr, _, _ := procTaskDialogIndirect.Call(
		uintptr(unsafe.Pointer(&cfg[0])),
		uintptr(unsafe.Pointer(&pressed)),
		0, // radio buttons unused
		0, // verification checkbox unused
	)
	runtime.KeepAlive(pool)
	runtime.KeepAlive(buttons)
	runtime.KeepAlive(cfg)
	if int32(hr) != 0 { // not S_OK: let the message box try instead
		return AlreadyRunningExit, false
	}
	switch pressed {
	case alreadyRunningOpenID:
		return AlreadyRunningOpenDashboard, true
	case alreadyRunningReplaceID:
		return AlreadyRunningReplace, true
	}
	return AlreadyRunningExit, true // Exit link, Cancel, Esc, the X
}
