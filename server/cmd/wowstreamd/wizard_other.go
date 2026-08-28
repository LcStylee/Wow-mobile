//go:build !windows

package main

import (
	"log/slog"

	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/hoststatus"
)

// runFirstRunWizard is a no-op off Windows: the installer wizard configures a
// Windows gaming PC, and newPlatform refuses to stream elsewhere anyway.
func runFirstRunWizard(_ *config.Config, _ *appUI, _ *hoststatus.Status, _ *slog.Logger) error {
	return nil
}
