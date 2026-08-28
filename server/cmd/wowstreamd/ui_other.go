//go:build !windows

package main

import (
	"fmt"
	"os"
)

// initUI on non-Windows systems is console mode only: the native-dialog GUI,
// the tray icon, and the browser dashboard auto-open are Windows features
// (the streaming host itself refuses to run elsewhere anyway; --console and
// --gui parse but change nothing here).
func initUI([]string) *appUI {
	return &appUI{
		gui: false,
		fatal: func(err error) {
			fmt.Fprintln(os.Stderr, "\nwowstreamd: error:", err)
		},
	}
}

// setupConsole is Windows-only (ANSI/VT enablement); Unix terminals need
// nothing.
func setupConsole() {}
