//go:build windows

// Single-instance guard (Windows). A named machine-wide mutex marks a
// running wowstreamd; a second copy — most commonly the launch right after
// installing over a running version, whose OLD instance still sits in the
// tray — must never die with "bind: Only one usage of each socket address".
// Instead the user chooses: open the running instance's dashboard, replace
// it (a loopback POST to its /host/api/quit, then a bounded wait for the
// mutex and port to free), or exit cleanly. Console mode offers the same
// three choices on stdin; --yes and non-interactive sessions never block
// (--yes replaces, everything else leaves the running copy in charge).
package main

import (
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/windows"

	"github.com/LcStylee/Wow-mobile/server/internal/config"
	"github.com/LcStylee/Wow-mobile/server/internal/install"
	sig "github.com/LcStylee/Wow-mobile/server/internal/signal"
	"github.com/LcStylee/Wow-mobile/server/internal/winui"
)

// singleInstanceMutexName is the machine-wide marker of a running
// wowstreamd. The Global\ prefix spans desktop sessions and elevation levels
// (the installer runs elevated; the app does not), so an elevated and a
// normal launch still see each other.
const singleInstanceMutexName = `Global\WowMobileWowstreamd`

// replaceWait bounds how long "Replace it" waits for the running instance to
// release the mutex and the port after being asked to quit.
const replaceWait = 5 * time.Second

// claimInstanceMutex tries to create/claim the single-instance mutex.
// owned=true means this process now holds the marker (close the handle on
// exit); owned=false with a nil error means another instance holds it.
func claimInstanceMutex() (h windows.Handle, owned bool, err error) {
	name, err := windows.UTF16PtrFromString(singleInstanceMutexName)
	if err != nil {
		return 0, false, err
	}
	h, err = windows.CreateMutex(nil, false, name)
	switch err {
	case nil:
		return h, true, nil
	case windows.ERROR_ALREADY_EXISTS:
		// CreateMutex returned a valid handle to the EXISTING mutex.
		return h, false, nil
	case windows.ERROR_ACCESS_DENIED:
		// The mutex exists but was created under another account/integrity
		// level we may not open — still proof of a running instance.
		return 0, false, nil
	}
	return 0, false, err
}

// ensureSingleInstance claims the mutex, or — when another instance holds it —
// resolves the conflict per the user's choice. proceed=false with a nil error
// is the clean "leave the running copy alone" exit; release must be called
// (deferred) whenever proceed is true.
func ensureSingleInstance(cfg *config.Config, ui *appUI, log *slog.Logger) (release func(), proceed bool, err error) {
	h, owned, cerr := claimInstanceMutex()
	if cerr != nil {
		// Cannot even create a mutex (should not happen): degrade to the old
		// behavior — start anyway; the bind error path still catches a real
		// port conflict with a clear message.
		log.Warn("single-instance mutex unavailable; continuing without the guard", "err", cerr)
		return func() {}, true, nil
	}
	if owned {
		return func() { _ = windows.CloseHandle(h) }, true, nil
	}
	if h != 0 {
		_ = windows.CloseHandle(h) // not ours; drop the extra reference
	}

	port := storedDashboardPort()
	dashboardURL := fmt.Sprintf("%s://127.0.0.1:%d/host/", loopbackScheme(cfg), port)
	switch chooseAlreadyRunning(cfg, ui, dashboardURL) {
	case alreadyRunningOpen:
		if ui.openURL != nil {
			ui.openURL(dashboardURL)
		} else if oerr := winui.OpenURL(dashboardURL); oerr != nil {
			fmt.Printf("Open the running WoW Mobile's dashboard here: %s\n", dashboardURL)
		}
		return nil, false, nil
	case alreadyRunningReplace:
		fmt.Println("WoW Mobile is already running — asking it to quit...")
		h2, rerr := replaceRunningInstance(cfg, port, log)
		if rerr != nil {
			return nil, false, rerr
		}
		fmt.Println("The previous WoW Mobile has quit; starting this one.")
		return func() { _ = windows.CloseHandle(h2) }, true, nil
	default: // exit, leaving the running instance in charge
		fmt.Printf("WoW Mobile is already running — leaving it in charge. Dashboard: %s\n", dashboardURL)
		return nil, false, nil
	}
}

// alreadyRunningAction is the second launch's resolution.
type alreadyRunningAction int

const (
	alreadyRunningExit alreadyRunningAction = iota
	alreadyRunningOpen
	alreadyRunningReplace
)

// chooseAlreadyRunning asks how to resolve the conflict, without ever
// blocking a session that cannot answer: GUI mode shows a small native
// dialog; console mode replaces under --yes, prompts on a real terminal, and
// otherwise leaves the running instance alone with a printed explanation.
func chooseAlreadyRunning(cfg *config.Config, ui *appUI, dashboardURL string) alreadyRunningAction {
	if cfg.Yes {
		// --yes promised no questions in either mode: replace, as documented.
		fmt.Println("WoW Mobile is already running — replacing it (--yes).")
		return alreadyRunningReplace
	}
	if ui.gui {
		switch winui.AskAlreadyRunning(dashboardURL) {
		case winui.AlreadyRunningOpenDashboard:
			return alreadyRunningOpen
		case winui.AlreadyRunningReplace:
			return alreadyRunningReplace
		}
		return alreadyRunningExit
	}
	if !stdinIsTerminal() {
		fmt.Println("WoW Mobile is already running (pass --yes to replace it).")
		return alreadyRunningExit
	}
	fmt.Printf("WoW Mobile is already running.\n"+
		"  [O] Open the running copy's dashboard (%s) and exit\n"+
		"  [R] Replace it — quit the running copy, then start this one\n"+
		"  [X] Exit and leave it running\n", dashboardURL)
	for {
		fmt.Print("Choose [o/r/X]: ")
		var line string
		if _, err := fmt.Scanln(&line); err != nil {
			return alreadyRunningExit // EOF/empty: the safe default
		}
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "o":
			return alreadyRunningOpen
		case "r":
			return alreadyRunningReplace
		case "x", "":
			return alreadyRunningExit
		}
		fmt.Println("Please answer o, r, or x.")
	}
}

// storedDashboardPort reads the port the running instance persisted on its
// last successful bind (KeyLastPort, written by persistBoundPort); 8443 —
// the --addr default — when absent or unparsable.
func storedDashboardPort() int {
	dir, err := os.UserConfigDir()
	if err != nil {
		return 8443
	}
	store := install.LoadStore(filepath.Join(dir, "wowstreamd"))
	if p, err := strconv.Atoi(store.Get(install.KeyLastPort)); err == nil && p > 0 && p < 65536 {
		return p
	}
	return 8443
}

// loopbackScheme guesses the running instance's dashboard scheme from this
// launch's own flags — TLS is the default for both, and requestInstanceQuit
// tries the other scheme too, so a mismatch only costs one extra request.
func loopbackScheme(cfg *config.Config) string {
	if cfg.NoTLS {
		return "http"
	}
	return "https"
}

// replaceRunningInstance asks the running instance to quit through the same
// loopback dashboard endpoint its Quit button uses, then waits (bounded) for
// the single-instance mutex AND the listen port to free before handing back
// a freshly claimed mutex handle.
func replaceRunningInstance(cfg *config.Config, port int, log *slog.Logger) (windows.Handle, error) {
	if err := requestInstanceQuit(cfg, port); err != nil {
		// The quit request could not be delivered (crashed instance holding
		// the mutex, a firewalled loopback, a moved port). Still poll
		// briefly — an instance mid-shutdown releases the mutex on its own —
		// but surface the request failure if nothing frees up.
		log.Warn("could not reach the running instance's quit endpoint", "err", err)
	}
	deadline := time.Now().Add(replaceWait)
	for {
		h, owned, err := claimInstanceMutex()
		if err == nil && owned {
			waitForPortFree(cfg.Addr, deadline)
			return h, nil
		}
		if h != 0 {
			_ = windows.CloseHandle(h)
		}
		if time.Now().After(deadline) {
			return 0, fmt.Errorf("the running WoW Mobile did not exit within %s — quit it yourself (tray icon > Quit WoW Mobile, or the dashboard's Quit button), then start this one again", replaceWait)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// requestInstanceQuit POSTs the dashboard's quit endpoint on the loopback
// interface with its proof-of-intent header (sig.QuitHeader). Loopback to
// loopback: the server's certificate is self-signed by design and the
// request carries no secret, so skipping verification for this one call
// keeps exactly the same trust the dashboard's own browser session has after
// the user accepts the certificate warning. The server-side LoopbackOnly +
// header guard is untouched — this caller simply satisfies it. Both schemes
// are tried (the running instance may be a --no-tls run, or vice versa).
func requestInstanceQuit(cfg *config.Config, port int) error {
	client := &http.Client{
		Timeout: 3 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // loopback-only, self-signed by design, no secrets in flight
		},
	}
	schemes := []string{"https", "http"}
	if cfg.NoTLS {
		schemes = []string{"http", "https"}
	}
	var lastErr error
	for _, scheme := range schemes {
		url := fmt.Sprintf("%s://127.0.0.1:%d/host/api/quit", scheme, port)
		req, err := http.NewRequest(http.MethodPost, url, nil)
		if err != nil {
			return err
		}
		req.Header.Set(sig.QuitHeader, "1")
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusNoContent {
			return nil
		}
		lastErr = fmt.Errorf("quit request to %s answered %s", url, resp.Status)
	}
	return lastErr
}

// waitForPortFree polls until this launch's own listen address binds (the
// probe listener is closed immediately) or the deadline passes. It guards
// crashed or hard-killed instances, whose kernel handle teardown order is
// unspecified, plus any residual close race — note run()'s defer ordering
// actually releases the mutex AFTER the listener closes on a clean quit, so
// this is defense for the unclean paths, not a mutex-before-listener race. A
// timeout is not an error here: the definitive attempt is the real Listen,
// whose failure describeListenError explains.
func waitForPortFree(addr string, deadline time.Time) {
	for {
		if ln, err := net.Listen("tcp", addr); err == nil {
			ln.Close()
			return
		}
		if time.Now().After(deadline) {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// handleBindConflict recovers the one already-running case the mutex cannot
// see: a pre-0.3.3 wowstreamd (which claimed no mutex) still holding the
// port — exactly the portable-upgrade field scenario. On EADDRINUSE it
// probes the port's loopback dashboard; if a wowstreamd status endpoint
// answers, the normal open/replace/exit choice runs. Returns retry=true when
// the old copy quit and the caller should Listen again; done=true when
// resolved without starting (dashboard opened, or the user left the old copy
// in charge); (false, false, nil) when the holder is not a wowstreamd — the
// caller falls back to describeListenError.
func handleBindConflict(cfg *config.Config, ui *appUI, log *slog.Logger, bindErr error) (retry, done bool, err error) {
	if !isAddrInUse(bindErr) {
		return false, false, nil
	}
	port := 8443
	if _, p, splitErr := net.SplitHostPort(cfg.Addr); splitErr == nil && p != "" {
		if n, convErr := strconv.Atoi(p); convErr == nil && n > 0 {
			port = n
		}
	}
	if !dashboardAnswers(cfg, port) {
		return false, false, nil
	}
	log.Info("port is held by a running WoW Mobile without the single-instance mutex (pre-0.3.3)", "port", port)
	dashboardURL := fmt.Sprintf("%s://127.0.0.1:%d/host/", loopbackScheme(cfg), port)
	switch chooseAlreadyRunning(cfg, ui, dashboardURL) {
	case alreadyRunningOpen:
		if ui.openURL != nil {
			ui.openURL(dashboardURL)
		} else if oerr := winui.OpenURL(dashboardURL); oerr != nil {
			fmt.Printf("Open the running WoW Mobile's dashboard here: %s\n", dashboardURL)
		}
		return false, true, nil
	case alreadyRunningReplace:
		fmt.Println("An older WoW Mobile is running — asking it to quit...")
		if qerr := requestInstanceQuit(cfg, port); qerr != nil {
			return false, false, fmt.Errorf("the running WoW Mobile did not answer the quit request: %w — quit it from its tray icon (or Task Manager) and start again", qerr)
		}
		waitForPortFree(cfg.Addr, time.Now().Add(5*time.Second))
		fmt.Println("The previous WoW Mobile has quit; starting this one.")
		return true, false, nil
	default:
		fmt.Printf("WoW Mobile is already running — leaving it in charge. Dashboard: %s\n", dashboardURL)
		return false, true, nil
	}
}

// dashboardAnswers reports whether a wowstreamd host dashboard answers on the
// loopback port: GET /host/api/status returning 200 with the status JSON's
// "steps" field (present since the first dashboard release). Loopback-only,
// short timeout, both schemes — the same reachability model as
// requestInstanceQuit.
func dashboardAnswers(cfg *config.Config, port int) bool {
	client := &http.Client{
		Timeout: 2 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // loopback-only probe, self-signed by design
		},
	}
	schemes := []string{"https", "http"}
	if cfg.NoTLS {
		schemes = []string{"http", "https"}
	}
	for _, scheme := range schemes {
		resp, err := client.Get(fmt.Sprintf("%s://127.0.0.1:%d/host/api/status", scheme, port))
		if err != nil {
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK && strings.Contains(string(body), `"steps"`) {
			return true
		}
	}
	return false
}

// isAddrInUse reports the bind-time "address already in use" failure
// (winsock WSAEADDRINUSE, a syscall.Errno — the "Only one usage of each
// socket address" message from the field report; net.OpError wraps it).
func isAddrInUse(err error) bool {
	return errors.Is(err, windows.WSAEADDRINUSE)
}
