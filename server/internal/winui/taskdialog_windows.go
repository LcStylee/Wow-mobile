//go:build windows

package winui

import (
	"errors"
	"fmt"
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The game-install picker: a native task dialog with one command link per
// discovered install plus "Browse for a folder…" / "Pick the game program
// (.exe)…" escape hatches. TaskDialogIndirect lives in comctl32 v6, which
// the application manifest (cmd/wowstreamd/wowstreamd.manifest, baked into
// the .syso) activates for every windows/amd64 build; on the off-chance a
// stripped build loads the pre-v6 comctl32, ErrTaskDialogUnavailable is
// returned and the caller falls back to the plain folder browser.
//
// The TASKDIALOGCONFIG is assembled as a manually packed byte buffer
// (taskdialog_layout.go) because the struct is #pragma pack(1) and a Go
// struct mirror would be laid out wrong — see that file's header.

var procTaskDialogIndirect = windows.NewLazySystemDLL("comctl32.dll").NewProc("TaskDialogIndirect")

// ErrTaskDialogUnavailable reports that this process's comctl32 predates
// task dialogs (no v6 activation context) — callers use a simpler dialog.
var ErrTaskDialogUnavailable = errors.New("task dialogs unavailable (comctl32 v6 not loaded)")

// Command-link button IDs. Candidate links are gameChoiceBaseID+index; the
// escape hatches sit far outside that range. IDCANCEL (2) is reserved by the
// dialog itself for Esc/the X/the Cancel button.
const (
	gameChoiceBaseID    = 1000
	gameChoiceBrowseID  = 1900
	gameChoicePickExeID = 1901
)

// GameInstallChoice is the picker outcome: a candidate index, or one of the
// escape hatches.
type GameInstallChoice struct {
	Index   int  // >= 0: the chosen label's index; -1 otherwise
	Browse  bool // "Browse for a folder…"
	PickExe bool // "Pick the game program (.exe)…"
}

// ChooseGameInstall shows the picker over the given candidate labels (the
// caller caps how many are listed) out of total discovered installs.
// Returns ErrCancelled when dismissed and ErrTaskDialogUnavailable when the
// task-dialog API is missing.
func ChooseGameInstall(labels []string, total int) (GameInstallChoice, error) {
	if len(labels) == 0 {
		return GameInstallChoice{Index: -1}, errors.New("no candidates to choose from")
	}
	if procTaskDialogIndirect.Find() != nil {
		return GameInstallChoice{Index: -1}, ErrTaskDialogUnavailable
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	instruction := fmt.Sprintf("Which World of Warcraft should WoW Mobile use? (%d found)", total)
	if total == 1 {
		instruction = "Found this World of Warcraft install — use it?"
	}
	content := "Your choice is remembered; the addon, window settings and stream follow it.\n" +
		"To change it later, restart WoW Mobile with --choose-game (tray icon → \"Choose game…\" shows how)."
	if total > len(labels) {
		content += fmt.Sprintf("\nOnly the first %d installs are listed — use \"Browse for a folder…\" for another one.", len(labels))
	}

	// UTF-16 string pool. The utf16 slices (and the packed buffers holding
	// pointers into them) must stay alive across the raw call — Go's GC does
	// not trace pointers embedded in a []byte — hence the KeepAlives below.
	var pool [][]uint16
	pin := func(s string) uint64 {
		u, err := windows.UTF16FromString(s)
		if err != nil {
			u, _ = windows.UTF16FromString("(text unavailable)")
		}
		pool = append(pool, u)
		return uint64(uintptr(unsafe.Pointer(&u[0])))
	}

	ids := make([]int32, 0, len(labels)+2)
	texts := make([]uint64, 0, len(labels)+2)
	for i, l := range labels {
		ids = append(ids, int32(gameChoiceBaseID+i))
		texts = append(texts, pin(l))
	}
	ids = append(ids, gameChoiceBrowseID, gameChoicePickExeID)
	texts = append(texts,
		pin("Browse for a folder…\nPick the World of Warcraft folder yourself"),
		pin("Pick the game program (.exe)…\nPrivate servers: Wow.exe, VanillaFixes.exe, or any custom launcher"))
	buttons := packTaskDialogButtons(ids, texts)

	cfg := packTaskDialogConfig(tdcValues{
		flags: tdfUseCommandLinks | tdfAllowDialogCancellation |
			tdfPositionRelativeToWindow | tdfSizeToContent,
		commonButtons:   tdcbfCancelButton,
		windowTitle:     pin(Title),
		mainInstruction: pin(instruction),
		content:         pin(content),
		buttonCount:     uint32(len(ids)),
		buttonsPtr:      uint64(uintptr(unsafe.Pointer(&buttons[0]))),
		defaultButton:   gameChoiceBaseID, // the first (remembered/best) install
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
	if int32(hr) != 0 { // S_OK
		return GameInstallChoice{Index: -1}, fmt.Errorf("TaskDialogIndirect failed: HRESULT 0x%08x", uint32(hr))
	}

	switch {
	case pressed == idCancel:
		return GameInstallChoice{Index: -1}, ErrCancelled
	case pressed == gameChoiceBrowseID:
		return GameInstallChoice{Index: -1, Browse: true}, nil
	case pressed == gameChoicePickExeID:
		return GameInstallChoice{Index: -1, PickExe: true}, nil
	case pressed >= gameChoiceBaseID && int(pressed) < gameChoiceBaseID+len(labels):
		return GameInstallChoice{Index: int(pressed) - gameChoiceBaseID}, nil
	}
	return GameInstallChoice{Index: -1}, fmt.Errorf("TaskDialogIndirect returned unexpected button id %d", pressed)
}
