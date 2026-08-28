package install

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// ConsolePrompter implements Prompter on a real console. It obeys the wizard
// UX rules: --yes answers every Confirm with its default without reading
// stdin, and a non-interactive session never blocks — Confirm takes the
// default (safe), Ask fails with a message naming the bypass flag.
type ConsolePrompter struct {
	in          *bufio.Reader
	out         io.Writer
	yes         bool
	interactive bool
}

// NewConsolePrompter wraps in/out. interactive must be false when stdin is
// not a terminal; yes mirrors --yes.
func NewConsolePrompter(in io.Reader, out io.Writer, interactive, yes bool) *ConsolePrompter {
	return &ConsolePrompter{in: bufio.NewReader(in), out: out, yes: yes, interactive: interactive}
}

// Confirm asks a [Y/n]-style question. Empty input takes the default;
// anything unrecognized re-asks.
func (p *ConsolePrompter) Confirm(question string, def bool) (bool, error) {
	suffix := "[Y/n]"
	if !def {
		suffix = "[y/N]"
	}
	if p.yes || !p.interactive {
		fmt.Fprintf(p.out, "%s %s %s\n", question, suffix, answerWord(def))
		return def, nil
	}
	for {
		fmt.Fprintf(p.out, "%s %s ", question, suffix)
		line, err := p.in.ReadString('\n')
		if err != nil && line == "" {
			return def, nil // EOF mid-wizard: fall back to the default
		}
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "":
			return def, nil
		case "y", "yes":
			return true, nil
		case "n", "no":
			return false, nil
		default:
			fmt.Fprintln(p.out, "Please answer y or n (or press Enter for the default).")
		}
	}
}

// Ask asks for free-form text. Non-interactive sessions (and --yes, which
// promises to never wait for input) fail instead of blocking.
func (p *ConsolePrompter) Ask(question string) (string, error) {
	if p.yes || !p.interactive {
		return "", fmt.Errorf("input required but the session is non-interactive")
	}
	fmt.Fprintf(p.out, "%s\n> ", question)
	line, err := p.in.ReadString('\n')
	if err != nil && line == "" {
		return "", fmt.Errorf("reading input: %w", err)
	}
	return strings.TrimSpace(line), nil
}

// SelectGamePath asks for a pasted path — a folder OR the game .exe itself
// (private servers often launch through Wow.exe/VanillaFixes.exe or a custom
// exe). The wizard validates and re-asks; prevInvalid was already reported to
// the output by the wizard, so the console just asks again.
func (p *ConsolePrompter) SelectGamePath(prevInvalid string) (string, error) {
	return p.Ask(`Paste the path to your World of Warcraft folder — or to the game program (.exe) itself.
Examples: C:\Program Files (x86)\World of Warcraft\_classic_era_
          D:\Games\TurtleWoW\VanillaFixes.exe`)
}

// ChooseGame renders the numbered install menu: 1..N picks a candidate, B
// switches to the paste-a-path flow, X cancels setup, and plain Enter takes
// the default — the first candidate, which the scanner orders to be the
// remembered or best install. EOF (Ctrl+Z/Ctrl+D, a dying terminal, piped
// stdin running dry) CANCELS like X: silently selecting and permanently
// persisting candidate #1 without an affirmative keypress would break the
// never-auto-proceeds contract, and cancelling never blocks either.
func (p *ConsolePrompter) ChooseGame(cands []GameCandidate) (GameSelection, error) {
	if p.yes || !p.interactive {
		// Defensive: the wizard resolves --yes/non-interactive before ever
		// prompting; never block here regardless.
		return GameSelection{Index: -1}, fmt.Errorf("input required but the session is non-interactive")
	}
	if len(cands) == 1 {
		fmt.Fprintln(p.out, "Found this World of Warcraft install:")
	} else {
		fmt.Fprintf(p.out, "Found %d World of Warcraft installs. Which one should WoW Mobile use?\n", len(cands))
	}
	for i, c := range cands {
		fmt.Fprintf(p.out, "  %d. %s\n", i+1, c.Label)
	}
	fmt.Fprintln(p.out, "  B. Somewhere else — enter a folder or game .exe path")
	fmt.Fprintln(p.out, "  X. Cancel setup")
	rangeHint := "1"
	if len(cands) > 1 {
		rangeHint = fmt.Sprintf("1-%d", len(cands))
	}
	for {
		fmt.Fprintf(p.out, "Choose [%s, B, X] (Enter = 1): ", rangeHint)
		line, err := p.in.ReadString('\n')
		if err != nil && line == "" {
			return GameSelection{Index: -1}, ErrGameChoiceCancelled // EOF mid-menu: cancel, never pick
		}
		switch ans := strings.ToLower(strings.TrimSpace(line)); ans {
		case "":
			return GameSelection{Index: 0}, nil
		case "b":
			return GameSelection{Index: -1, Browse: true}, nil
		case "x":
			return GameSelection{Index: -1}, ErrGameChoiceCancelled
		default:
			if n, aerr := strconv.Atoi(ans); aerr == nil && n >= 1 && n <= len(cands) {
				return GameSelection{Index: n - 1}, nil
			}
			fmt.Fprintf(p.out, "Please answer %s, B, or X (or press Enter for 1).\n", rangeHint)
		}
	}
}

// Notice is a no-op on the console: the wizard has already printed the same
// text to its output, and a modal pause would only get in the way.
func (p *ConsolePrompter) Notice(title, message string) {}

func answerWord(def bool) string {
	if def {
		return "yes"
	}
	return "no"
}
