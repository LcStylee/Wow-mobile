//go:build windows

package winui

import (
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

// StuckInstanceChoice resolves a launch blocked by a WoW Mobile that holds
// the single-instance marker but answers on no dashboard — a copy stuck
// mid-startup (its window may be hidden) or wedged mid-shutdown. "Open
// dashboard" would land on a refused connection here (field report v0.4.1),
// so the choices are different from the healthy already-running dialog.
type StuckInstanceChoice int

const (
	// StuckInstanceExit leaves the stuck copy alone (Esc/X/Cancel default).
	StuckInstanceExit StuckInstanceChoice = iota
	// StuckInstanceForceReplace force-quits the stuck copy and starts this one.
	StuckInstanceForceReplace
)

// Command-link button IDs, outside the other dialogs' ranges.
const (
	stuckForceID = 2200
	stuckExitID  = 2201
)

// AskStuckInstance shows the stuck-instance dialog and returns the user's
// choice. Like AskAlreadyRunning it never fails: dialog-machinery problems
// degrade to a message box, and any dismissal means Exit.
func AskStuckInstance() StuckInstanceChoice {
	if choice, ok := askStuckInstanceTaskDialog(); ok {
		return choice
	}
	switch messageBox("A previous WoW Mobile appears stuck: it is marked as running but its dashboard does not answer.\n\n"+
		"It may still be starting up (check the taskbar and tray for a hidden window) or wedged mid-shutdown.\n\n"+
		"OK — force-quit it and start this copy\n"+
		"Cancel — exit and check the tray / Task Manager yourself", windows.MB_OKCANCEL|windows.MB_ICONWARNING|windows.MB_DEFBUTTON2) {
	case idOK:
		return StuckInstanceForceReplace
	}
	return StuckInstanceExit
}

// askStuckInstanceTaskDialog is the command-link variant; ok=false sends the
// caller to the message-box fallback.
func askStuckInstanceTaskDialog() (StuckInstanceChoice, bool) {
	if procTaskDialogIndirect.Find() != nil {
		return StuckInstanceExit, false
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

	ids := []int32{stuckForceID, stuckExitID}
	texts := []uint64{
		pin("Force-quit it and start\nEnd the stuck copy, then start this one"),
		pin("Exit\nLeave it alone — check the tray or Task Manager yourself"),
	}
	buttons := packTaskDialogButtons(ids, texts)

	cfg := packTaskDialogConfig(tdcValues{
		flags: tdfUseCommandLinks | tdfAllowDialogCancellation |
			tdfPositionRelativeToWindow | tdfSizeToContent,
		commonButtons:   tdcbfCancelButton,
		windowTitle:     pin(Title),
		mainInstruction: pin("A previous WoW Mobile appears stuck"),
		content: pin("It is marked as running, but its dashboard does not answer.\n" +
			"It may still be starting up (its window can be hidden behind others —\n" +
			"check the taskbar and the tray icon) or wedged mid-shutdown."),
		buttonCount:   uint32(len(ids)),
		buttonsPtr:    uint64(uintptr(unsafe.Pointer(&buttons[0]))),
		defaultButton: stuckExitID,
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
		return StuckInstanceExit, false
	}
	if pressed == stuckForceID {
		return StuckInstanceForceReplace, true
	}
	return StuckInstanceExit, true // Exit link, Cancel, Esc, the X
}
