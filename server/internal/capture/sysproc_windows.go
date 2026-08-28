//go:build windows

package capture

import (
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows"
)

// hideConsole marks cmd so the child never gets a console window of its own.
// The released wowstreamd.exe is a windowsgui binary: in GUI mode it has no
// console at all, and a console-subsystem child (ffmpeg) launched from a
// console-less parent allocates a NEW visible console — a window flash at
// startup, a persistent empty ffmpeg window on the taskbar, and focus steal
// from the game on every encoder restart. All ffmpeg output already flows
// through pipes, so the child needs no console: CREATE_NO_WINDOW keeps GUI
// mode window-free (and console mode free of extra flashes), mirroring
// install.RunWingetInstall's treatment of winget.
func hideConsole(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
}
