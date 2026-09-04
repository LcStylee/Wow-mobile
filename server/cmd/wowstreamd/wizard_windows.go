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
// so the rest of startup needs no PATH lookup of its own, and returns the
// RESOLVED layout (config.LayoutBand/LayoutPortrait — the wizard settles
// --layout auto by the located client type; "" when the wizard was skipped
// and main must fall back). In console mode the wizard is the classic text
// flow on stdin/stdout; in GUI mode the same wizard logic speaks through
// native dialogs (guiPrompter) and never touches stdin.
func runFirstRunWizard(cfg *config.Config, ui *appUI, status *hoststatus.Status, _ *slog.Logger) (string, error) {
	if cfg.SkipSetup {
		return "", nil
	}
	addonFS, err := fs.Sub(embedded.AddonFS, "addon/WowMobile")
	if err != nil {
		return "", fmt.Errorf("embedded addon missing: %w", err)
	}
	vanillaAddonFS, err := fs.Sub(embedded.VanillaAddonFS, "addon/WowMobile_Vanilla")
	if err != nil {
		return "", fmt.Errorf("embedded 1.12 addon missing: %w", err)
	}
	configDir, err := os.UserConfigDir() // %APPDATA%
	if err != nil {
		return "", fmt.Errorf("resolving %%APPDATA%%: %w", err)
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

	// --client-type: the config layer validated the value; map it onto the
	// install package's ClientType ("" stays "detect").
	var clientTypeFlag install.ClientType
	switch cfg.ClientType {
	case config.ClientTypeEra:
		clientTypeFlag = install.ClientTypeClassicEra
	case config.ClientTypeLegacy:
		clientTypeFlag = install.ClientTypeLegacy
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
		ResolutionFit:  cfg.ResolutionIsFit,
		Layout:         cfg.Layout,
		WindowTitle:    cfg.WindowTitle,
		WowDirFlag:     cfg.WowDir,
		GameExeFlag:    cfg.GameExe,
		ClientTypeFlag: clientTypeFlag,
		FFmpegFlag:     cfg.FFmpegPath,
		Interactive:    interactive,
		Yes:            cfg.Yes,
		ChooseGame:     cfg.ChooseGame,
		Status:         status,
	})
	if err != nil {
		return "", err
	}
	if cfg.FFmpegPath == "" {
		cfg.FFmpegPath = res.FFmpegPath
	}
	// The wizard decided the capture resolution (monitor-fitted under
	// --resolution fit in portrait layout; the band-mode fallback frame
	// otherwise); adopt it so capture, injection mapping, and the hello
	// geometry all use the same number Config.wtf was written with.
	cfg.Width, cfg.Height = res.Width, res.Height
	return res.Layout, nil
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

// guiVisibleCandidates caps how many installs the task dialog lists as
// command links — beyond that the "Browse for a folder…" link covers the
// rest (the picker's content line says so).
const guiVisibleCandidates = 8

// ChooseGame shows the native install picker (winui.ChooseGameInstall, a
// task dialog with one command link per install). The browse / pick-exe
// escape hatches run their native dialogs right here so a cancelled
// sub-dialog returns to the picker instead of aborting setup; if task
// dialogs are unavailable (comctl32 without v6 — effectively never with the
// shipped manifest) the plain folder browser is the honest fallback.
func (p guiPrompter) ChooseGame(cands []install.GameCandidate) (install.GameSelection, error) {
	if p.yes {
		return install.GameSelection{Index: -1}, errors.New("--yes cannot open the game picker; pass --game-exe or --wow-dir")
	}
	labels := make([]string, 0, guiVisibleCandidates)
	for i, c := range cands {
		if i == guiVisibleCandidates {
			break
		}
		labels = append(labels, c.Label)
	}
	for {
		choice, err := winui.ChooseGameInstall(labels, len(cands))
		switch {
		case errors.Is(err, winui.ErrCancelled):
			return install.GameSelection{Index: -1}, install.ErrGameChoiceCancelled
		case errors.Is(err, winui.ErrTaskDialogUnavailable):
			return install.GameSelection{Index: -1, Browse: true}, nil
		case err != nil:
			return install.GameSelection{Index: -1}, err
		}
		switch {
		case choice.Index >= 0:
			return install.GameSelection{Index: choice.Index}, nil
		case choice.Browse:
			dir, berr := winui.BrowseForFolder("Select your World of Warcraft folder")
			if errors.Is(berr, winui.ErrCancelled) {
				continue // back to the picker
			}
			if berr != nil {
				return install.GameSelection{Index: -1}, berr
			}
			return install.GameSelection{Index: -1, Path: dir}, nil
		case choice.PickExe:
			path, perr := winui.PickExeFile("Pick your game program (.exe)")
			if errors.Is(perr, winui.ErrCancelled) {
				continue // back to the picker
			}
			if perr != nil {
				return install.GameSelection{Index: -1}, perr
			}
			return install.GameSelection{Index: -1, Path: path}, nil
		}
	}
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
