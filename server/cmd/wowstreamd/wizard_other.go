//go:build !windows

package main

import (
	"log/slog"

	"github.com/LcStylee/Wow-mobile/server/internal/config"
)

// runFirstRunWizard is a no-op off Windows: the installer wizard configures a
// Windows gaming PC, and newPlatform refuses to stream elsewhere anyway.
func runFirstRunWizard(_ *config.Config, _ *slog.Logger) error { return nil }

// setupConsole is Windows-only (ANSI/VT enablement); Unix terminals need
// nothing.
func setupConsole() {}

// holdConsoleOnFatal is Windows-only (double-clicked consoles vanish on
// exit); on Unix the shell keeps the error visible.
func holdConsoleOnFatal() {}
