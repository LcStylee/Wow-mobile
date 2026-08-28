//go:build windows

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"

	embedded "github.com/LcStylee/Wow-mobile"
	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/hoststatus"
	"github.com/LcStylee/Wow-mobile/server/internal/install"
	"github.com/LcStylee/Wow-mobile/server/internal/winui"
)

// runFirstRunWizard runs the five-step installer wizard before streaming.
// It fills cfg.FFmpegPath with the located ffmpeg when the flag was not set,
// so the rest of startup needs no PATH lookup of its own. In console mode the
// wizard is the classic text flow on stdin/stdout; in GUI mode the same
// wizard logic speaks through native dialogs (guiPrompter) and never touches
// stdin.
func runFirstRunWizard(cfg *config.Config, ui *appUI, status *hoststatus.Status, _ *slog.Logger) error {
	if cfg.SkipSetup {
		return nil
	}
	addonFS, err := fs.Sub(embedded.AddonFS, "addon/WowMobile")
	if err != nil {
		return fmt.Errorf("embedded addon missing: %w", err)
	}
	vanillaAddonFS, err := fs.Sub(embedded.VanillaAddonFS, "addon/WowMobile_Vanilla")
	if err != nil {
		return fmt.Errorf("embedded 1.12 addon missing: %w", err)
	}
	configDir, err := os.UserConfigDir() // %APPDATA%
	if err != nil {
		return fmt.Errorf("resolving %%APPDATA%%: %w", err)
	}

	var prompt install.Prompter
	interactive := false
	if ui.gui {
		// Dialogs can always ask (unless --yes promised not to), and they
		// never read stdin — the GUI-mode no-blocking guarantee.
		prompt = guiPrompter{yes: cfg.Yes}
		interactive = !cfg.Yes
	} else {
		interactive = stdinIsTerminal()
		prompt = install.NewConsolePrompter(os.Stdin, os.Stdout, interactive, cfg.Yes)
	}

	res, err := install.Run(install.Options{
		Out:            os.Stdout,
		Prompt:         prompt,
		Store:          install.LoadStore(filepath.Join(configDir, "wowstreamd")),
		Sys:            install.NewSystem(),
		AddonFS:        addonFS,
		VanillaAddonFS: vanillaAddonFS,
		Width:          cfg.Width,
		Height:         cfg.Height,
		WindowTitle:    cfg.WindowTitle,
		WowDirFlag:     cfg.WowDir,
		GameExeFlag:    cfg.GameExe,
		FFmpegFlag:     cfg.FFmpegPath,
		Interactive:    interactive,
		Yes:            cfg.Yes,
		Status:         status,
	})
	if err != nil {
		return err
	}
	if cfg.FFmpegPath == "" {
		cfg.FFmpegPath = res.FFmpegPath
	}
	return nil
}

// guiPrompter implements install.Prompter with native dialogs (winui) —
// GUI-mode wizard runs never block on stdin anywhere.
type guiPrompter struct {
	yes bool // --yes: answer every Confirm with its default, ask nothing
}

func (p guiPrompter) Confirm(question string, def bool) (bool, error) {
	if p.yes {
		return def, nil
	}
	return winui.AskYesNo(question, def), nil
}

func (p guiPrompter) Ask(question string) (string, error) {
	// The wizard's only free-form question is the game location, which goes
	// through SelectGamePath below; anything else has no GUI affordance.
	return "", errors.New("free-form input is not available in GUI mode")
}

func (p guiPrompter) SelectGamePath(prevInvalid string) (string, error) {
	if p.yes {
		return "", errors.New("--yes cannot open a folder picker; pass --wow-dir or --game-exe")
	}
	path, err := winui.SelectGameLocation(prevInvalid)
	if errors.Is(err, winui.ErrCancelled) {
		return "", errors.New("folder selection cancelled")
	}
	return path, err
}

func (p guiPrompter) Notice(title, message string) {
	winui.Info(message)
}
