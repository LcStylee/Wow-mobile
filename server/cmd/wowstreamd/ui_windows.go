//go:build windows

package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/LcStylee/Wow-mobile/server/internal/winui"
)

// chooseGameDialogOpen keeps the tray's "Choose game…" help dialog single-
// instance: each modal pins an OS thread until dismissed, so repeated tray
// clicks must not stack copies.
var chooseGameDialogOpen atomic.Bool

// Windows console/GUI mode detection. The released exe is linked with
// -H=windowsgui, so a double-click starts it with NO console at all — the
// clean consumer experience. Someone typing wowstreamd.exe in cmd/PowerShell
// still expects the classic text wizard, so at startup we try to attach to
// the parent process's console:
//
//   - AttachConsole succeeds (launched from a shell), or stdout was already a
//     valid handle (piped/redirected)  =>  CONSOLE mode, output byte-for-byte
//     the old behavior;
//   - neither  =>  GUI mode: dialogs, browser dashboard, tray icon.
//
// --console / --gui force the decision either way.
//
// One caveat on ATTACHED consoles: cmd/PowerShell do not wait for a GUI-
// subsystem exe, so the shell has already re-prompted and has its own pending
// read on the SAME console input buffer — anything the user types races the
// shell and usually feeds it, not us. Output-only attach is fine; interactive
// reads are not. So an attach that merely SHARES the shell's console is
// treated as non-interactive stdin (prompts take their defaults, with a
// printed hint), and --console gets the fully interactive wizard by
// relaunching once into a console of its own (the relaunched child, marked
// via ownConsoleEnv, skips AttachConsole and AllocConsole-s an owned one).

var (
	uiKernel32              = windows.NewLazySystemDLL("kernel32.dll")
	procAttachConsole       = uiKernel32.NewProc("AttachConsole")
	procAllocConsole        = uiKernel32.NewProc("AllocConsole")
	procGetConsoleProcCount = uiKernel32.NewProc("GetConsoleProcessList")
)

// attachParentProcess is ATTACH_PARENT_PROCESS ((DWORD)-1).
const attachParentProcess = ^uintptr(0)

// ownConsoleEnv marks a relaunch that must own a fresh console (see the
// header comment): the child skips AttachConsole and allocates its own.
const ownConsoleEnv = "WOWSTREAMD_OWN_CONSOLE"

// stdinSharesShellConsole is set when stdin is a console we merely attached
// to and the launching shell still owns it: typed input races the shell's own
// pending read, so stdinIsTerminal() reports non-interactive.
var stdinSharesShellConsole bool

func initUI(args []string) *appUI {
	forceConsole := hasModeFlag(args, "console")
	forceGUI := hasModeFlag(args, "gui")

	if os.Getenv(ownConsoleEnv) != "" && !forceGUI {
		// Relaunched child of the --console-from-a-shell case: never attach
		// to the (shared) parent console — allocate one this process owns, so
		// the wizard's stdin reads are raced by nobody. The env var must not
		// leak further (a re-relaunch loop), and note the exec.Cmd-provided
		// NUL std handles are valid, so every stream is re-pointed here.
		os.Unsetenv(ownConsoleEnv) //nolint:errcheck
		if r, _, _ := procAllocConsole.Call(); r != 0 {
			reopenConsoleFile("CONOUT$", windows.STD_OUTPUT_HANDLE, &os.Stdout)
			reopenConsoleFile("CONOUT$", windows.STD_ERROR_HANDLE, &os.Stderr)
			reopenConsoleFile("CONIN$", windows.STD_INPUT_HANDLE, &os.Stdin)
			return consoleAppUI()
		}
		// AllocConsole refused (should not happen): fall through to the
		// normal detection below rather than die mutely.
	}

	stdoutWasValid := stdHandleUsable(windows.STD_OUTPUT_HANDLE)
	stderrWasValid := stdHandleUsable(windows.STD_ERROR_HANDLE)
	stdinWasValid := stdHandleUsable(windows.STD_INPUT_HANDLE)

	attached := false
	if !forceGUI {
		r, _, _ := procAttachConsole.Call(attachParentProcess)
		attached = r != 0
	}
	console := forceConsole || attached || stdoutWasValid
	if forceGUI {
		console = false
	}
	allocedOwn := false
	if console && !attached && !stdoutWasValid && forceConsole {
		// --console on a double-click of the windowsgui exe: there is no
		// console anywhere, so make one rather than run a mute wizard.
		if r, _, _ := procAllocConsole.Call(); r != 0 {
			attached = true
			allocedOwn = true
		}
	}
	if attached {
		// The process had no std handles (windowsgui start) or only some
		// (redirection): point every still-invalid stream at the console we
		// just gained. Valid (piped) handles are left untouched.
		if !stdoutWasValid {
			reopenConsoleFile("CONOUT$", windows.STD_OUTPUT_HANDLE, &os.Stdout)
		}
		if !stderrWasValid {
			reopenConsoleFile("CONOUT$", windows.STD_ERROR_HANDLE, &os.Stderr)
		}
		if !stdinWasValid {
			reopenConsoleFile("CONIN$", windows.STD_INPUT_HANDLE, &os.Stdin)
		}
		// The shell already printed its prompt on this line; start clean.
		fmt.Println()
	}

	// Attached to a console the shell still owns, with our stdin pointing at
	// it: interactive reads would race the shell's pending read (see header
	// comment). The check is whether stdin IS a console handle on a shared
	// console — not whether the handle was inherited: 'wowstreamd.exe >
	// log.txt' redirects only stdout, and cmd then passes its own console
	// input handle as our stdin via STARTF_USESTDHANDLES (stdinWasValid is
	// true), which races the shell exactly like the reopened-CONIN$ case.
	// A genuinely redirected stdin (pipe/file) is not a console handle, so it
	// is left alone. --console answers with a console of our own; otherwise
	// stdin is demoted to non-interactive so prompts take defaults instead of
	// fighting cmd/PowerShell for keystrokes.
	if attached && !allocedOwn && stdinIsConsoleHandle() && !ownsConsole() {
		// --yes and --skip-setup promise no stdin reads, so those runs stay
		// in the shell's console instead of relaunching into a new window.
		wantsStdin := !hasModeFlag(args, "yes") && !hasModeFlag(args, "skip-setup")
		if forceConsole && wantsStdin && relaunchInOwnConsole() {
			fmt.Println("wowstreamd: opening its own console window for the interactive wizard" +
				" (this shell keeps its input)...")
			os.Exit(0)
		}
		stdinSharesShellConsole = true
		if wantsStdin {
			fmt.Println("note: sharing this shell's console, so typed input would reach the shell —" +
				" any setup prompts take their defaults. Run 'wowstreamd.exe --console' for an" +
				" interactive wizard window.")
		}
	}

	if console {
		return consoleAppUI()
	}
	return &appUI{
		gui: true,
		fatal: func(err error) {
			// Never a silent death in GUI mode: the error plus one actionable
			// hint, in a dialog.
			winui.Error("WoW Mobile could not start:\n\n" + err.Error() +
				"\n\nTip: run wowstreamd.exe from a terminal (or with --console) to see the full log.")
		},
		openURL: func(url string) {
			if err := winui.OpenURL(url); err != nil {
				winui.Info("Open this address in your browser to see the WoW Mobile dashboard:\n\n" + url)
			}
		},
		newTray: func(dashboardURL string, onQuit func()) (func(string), func(), error) {
			tray, err := winui.NewTray(winui.TrayOptions{
				Tooltip: "WoW Mobile — waiting for phone",
				// dashboardURL is "" on a non-loopback --addr bind (main.go):
				// the dashboard is unreachable there, so opening is a no-op
				// but the tray keeps providing Quit.
				OnOpen: func() {
					if dashboardURL != "" {
						_ = winui.OpenURL(dashboardURL)
					}
				},
				// Honest and simple: the picker runs inside the setup wizard,
				// which only runs at startup, so this item explains the
				// restart-with---choose-game path instead of pretending an
				// in-place switch (which would need the whole game-dependent
				// pipeline re-run) happened. The dialog is modal — spawn it
				// off the tray's message-loop thread so tooltips keep
				// updating behind it — and at most one at a time: repeated
				// clicks must not stack identical modals (each pins an OS
				// thread until dismissed).
				OnChooseGame: func() {
					if !chooseGameDialogOpen.CompareAndSwap(false, true) {
						return
					}
					go func() {
						defer chooseGameDialogOpen.Store(false)
						winui.Info(chooseGameHelp())
					}()
				},
				OnQuit: onQuit,
			})
			if err != nil {
				return nil, nil, err
			}
			return tray.SetTooltip, tray.Close, nil
		},
	}
}

// chooseGameHelp is the tray "Choose game…" dialog text: how to re-open the
// game-install picker. The picker is a setup-wizard step, so the honest path
// is a restart with --choose-game; the exact command (with this exe's real
// path) is included so it can be typed into Win+R or a terminal verbatim.
func chooseGameHelp() string {
	cmd := "wowstreamd.exe --choose-game"
	if exe, err := os.Executable(); err == nil {
		cmd = "\"" + exe + "\" --choose-game"
	}
	return "To play a different World of Warcraft install:\n\n" +
		"1. Quit WoW Mobile (tray icon → Quit WoW Mobile).\n" +
		"2. Start it again with the --choose-game option — press Win+R (or open a terminal) and run:\n\n" +
		cmd + "\n\n" +
		"Setup then lists the installs it finds (with detected versions) and remembers your new choice."
}

// consoleAppUI is the console-mode appUI (text wizard, stderr errors).
func consoleAppUI() *appUI {
	return &appUI{
		gui: false,
		fatal: func(err error) {
			fmt.Fprintln(os.Stderr, "\nwowstreamd: error:", err)
			holdConsoleOnFatal()
		},
	}
}

// relaunchInOwnConsole starts this exe again with the same arguments, marked
// (ownConsoleEnv) to allocate a console of its own instead of attaching to
// the shell's. The GUI-subsystem child inherits no console; its AllocConsole
// opens a fresh window whose input nobody else reads. Returns false if the
// relaunch could not be started (the caller then falls back to the shared
// console).
func relaunchInOwnConsole() bool {
	exe, err := os.Executable()
	if err != nil {
		return false
	}
	cmd := exec.Command(exe, os.Args[1:]...)
	cmd.Env = append(os.Environ(), ownConsoleEnv+"=1")
	return cmd.Start() == nil
}

// hasModeFlag reports whether args force the given mode flag (--name, -name,
// or the =true forms). Config.Parse remains the authority; this pre-scan only
// steers console attachment, which must happen before flags are parsed.
func hasModeFlag(args []string, name string) bool {
	for _, a := range args {
		trimmed := strings.TrimLeft(a, "-")
		if len(a) == len(trimmed) {
			continue // not a flag
		}
		if trimmed == name || trimmed == name+"=true" || trimmed == name+"=1" {
			return true
		}
	}
	return false
}

// stdHandleUsable reports whether the std handle exists and refers to a real
// file object (console, pipe, or disk file).
func stdHandleUsable(which uint32) bool {
	h, err := windows.GetStdHandle(which)
	if err != nil || h == 0 || h == windows.InvalidHandle {
		return false
	}
	t, err := windows.GetFileType(h)
	return err == nil && t != windows.FILE_TYPE_UNKNOWN
}

// reopenConsoleFile opens CONIN$/CONOUT$ and installs it as both the Go-level
// std file and the Win32 std handle (so child processes inherit it too).
func reopenConsoleFile(name string, which uint32, target **os.File) {
	f, err := os.OpenFile(name, os.O_RDWR, 0)
	if err != nil {
		return
	}
	*target = f
	_ = windows.SetStdHandle(which, windows.Handle(f.Fd()))
}

// setupConsole enables ANSI/VT processing on the console so escape sequences
// render instead of leaking as text; when the console refuses (very old
// Windows, redirected output) everything degrades to plain text — the wizard
// and banner are plain text by construction.
func setupConsole() {
	for _, f := range []*os.File{os.Stdout, os.Stderr} {
		h := windows.Handle(f.Fd())
		var mode uint32
		if windows.GetConsoleMode(h, &mode) == nil {
			_ = windows.SetConsoleMode(h, mode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
		}
	}
}

// stdinIsConsoleHandle reports whether os.Stdin currently refers to a console
// input buffer (only real console handles answer GetConsoleMode; pipes and
// files do not). Used by initUI to decide the shared-console demotion: it is
// true both when stdin was re-pointed at CONIN$ after an attach and when the
// launching shell handed us its own console input handle directly
// (STARTF_USESTDHANDLES with partial redirection).
func stdinIsConsoleHandle() bool {
	var mode uint32
	return windows.GetConsoleMode(windows.Handle(os.Stdin.Fd()), &mode) == nil
}

// stdinIsTerminal reports whether stdin is an interactive console (a real
// console handle answers GetConsoleMode; pipes and files do not). A console
// merely attached from a shell that still owns it does NOT count: the shell's
// pending read would swallow the user's input (see initUI), so prompting on
// it would be interactive in appearance only.
func stdinIsTerminal() bool {
	if stdinSharesShellConsole {
		return false
	}
	return stdinIsConsoleHandle()
}

// holdConsoleOnFatal keeps the console window alive after a fatal error when
// this process is the console's only owner — i.e. the user double-clicked a
// console-subsystem build (or forced --console) and the window would vanish
// before the error could be read. Started from an existing terminal
// (cmd/PowerShell), it exits immediately as usual.
func holdConsoleOnFatal() {
	if !stdinIsTerminal() || !ownsConsole() {
		return
	}
	fmt.Fprint(os.Stderr, "\nPress Enter to exit...")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
}

// ownsConsole reports whether this process is the only one attached to its
// console (the double-click case: the console dies with the process).
func ownsConsole() bool {
	var pids [2]uint32
	n, _, _ := procGetConsoleProcCount.Call(
		uintptr(unsafe.Pointer(&pids[0])), uintptr(len(pids)))
	return n == 1
}
