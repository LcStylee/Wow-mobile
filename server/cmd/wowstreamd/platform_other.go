//go:build !windows

package main

import (
	"errors"
	"log/slog"

	"github.com/LcStylee/Wow-mobile/server/internal/config"
)

// newPlatform on non-Windows systems refuses to run: capture and SendInput
// are Windows-only. The binary still builds here so the portable packages can
// be developed and tested anywhere; --setup also works everywhere.
func newPlatform(_ *config.Config, _ bool, _ *slog.Logger) (*platform, error) {
	return nil, errors.New("wowstreamd streams a Windows game and must run on the Windows gaming PC (only --setup and --help work on this OS)")
}

// measureFitResolution: no monitors to measure off Windows — --resolution fit
// falls back to the 1080x1920 design resolution (resolveFitResolution).
func measureFitResolution() (w, h, workW, workH int, ok bool) {
	return 0, 0, 0, 0, false
}
