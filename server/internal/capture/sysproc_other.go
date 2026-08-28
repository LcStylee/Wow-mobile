//go:build !windows

package capture

import "os/exec"

// hideConsole is Windows-only (see sysproc_windows.go): elsewhere child
// processes have no console window to suppress.
func hideConsole(*exec.Cmd) {}
