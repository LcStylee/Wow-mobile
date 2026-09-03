//go:build !windows

package main

import (
	"errors"
	"log/slog"
	"syscall"

	"github.com/LcStylee/Wow-mobile/server/internal/config"
)

// ensureSingleInstance is a no-op off Windows: the streaming host only runs
// there, and the portable builds (dev, --capture test, the e2e harness) must
// keep starting any number of instances side by side.
func ensureSingleInstance(*config.Config, *appUI, *slog.Logger) (release func(), proceed bool, err error) {
	return func() {}, true, nil
}

// isAddrInUse reports the bind-time "address already in use" failure.
func isAddrInUse(err error) bool {
	return errors.Is(err, syscall.EADDRINUSE)
}

// handleBindConflict is Windows-only recovery for a mutex-less pre-0.3.3
// instance holding the port; elsewhere the plain bind error stands.
func handleBindConflict(*config.Config, *appUI, *slog.Logger, error) (retry, done bool, err error) {
	return false, false, nil
}
