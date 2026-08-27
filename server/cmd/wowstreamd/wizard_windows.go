//go:build windows

package main

import (
	"bufio"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"unsafe"

	"golang.org/x/sys/windows"

	embedded "github.com/LcStylee/Wow-mobile"
	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/install"
)

// runFirstRunWizard runs the five-step installer wizard before streaming.
// It fills cfg.FFmpegPath with the located ffmpeg when the flag was not set,
// so the rest of startup needs no PATH lookup of its own.
func runFirstRunWizard(cfg *config.Config, _ *slog.Logger) error {
	if cfg.SkipSetup {
		return nil
	}
	addonFS, err := fs.Sub(embedded.AddonFS, "addon/WowMobile")
	if err != nil {
		return fmt.Errorf("embedded addon missing: %w", err)
	}
	configDir, err := os.UserConfigDir() // %APPDATA%
	if err != nil {
		return fmt.Errorf("resolving %%APPDATA%%: %w", err)
	}
	interactive := stdinIsTerminal()
	res, err := install.Run(install.Options{
		Out:         os.Stdout,
		Prompt:      install.NewConsolePrompter(os.Stdin, os.Stdout, interactive, cfg.Yes),
		Store:       install.LoadStore(filepath.Join(configDir, "wowstreamd")),
		Sys:         install.NewSystem(),
		AddonFS:     addonFS,
		Width:       cfg.Width,
		Height:      cfg.Height,
		WindowTitle: cfg.WindowTitle,
		WowDirFlag:  cfg.WowDir,
		FFmpegFlag:  cfg.FFmpegPath,
		Interactive: interactive,
		Yes:         cfg.Yes,
	})
	if err != nil {
		return err
	}
	if cfg.FFmpegPath == "" {
		cfg.FFmpegPath = res.FFmpegPath
	}
	return nil
}

// stdinIsTerminal reports whether stdin is an interactive console (a real
// console handle answers GetConsoleMode; pipes and files do not).
func stdinIsTerminal() bool {
	var mode uint32
	return windows.GetConsoleMode(windows.Handle(os.Stdin.Fd()), &mode) == nil
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

// holdConsoleOnFatal keeps the console window alive after a fatal error when
// this process is the console's only owner — i.e. the user double-clicked the
// exe and the window would vanish before the error could be read. Started
// from an existing terminal (cmd/PowerShell), it exits immediately as usual.
func holdConsoleOnFatal() {
	if !stdinIsTerminal() || !ownsConsole() {
		return
	}
	fmt.Fprint(os.Stderr, "\nPress Enter to exit...")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
}

var (
	kernel32                  = windows.NewLazySystemDLL("kernel32.dll")
	procGetConsoleProcessList = kernel32.NewProc("GetConsoleProcessList")
)

// ownsConsole reports whether this process is the only one attached to its
// console (the double-click case: the console dies with the process).
func ownsConsole() bool {
	var pids [2]uint32
	n, _, _ := procGetConsoleProcessList.Call(
		uintptr(unsafe.Pointer(&pids[0])), uintptr(len(pids)))
	return n == 1
}
