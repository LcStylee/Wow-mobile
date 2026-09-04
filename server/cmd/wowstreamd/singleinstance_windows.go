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
	"os/exec"
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

// stuckResolveWait bounds how long a launch waits for a mutex-holding copy
// with no dashboard to either finish starting (dashboard comes up) or finish
// exiting (mutex frees) before treating it as wedged. Long enough for a slow
// startup's bind, short enough that a genuinely stuck copy does not read as
// a hang.
const stuckResolveWait = 6 * time.Second

// probeTimeout is the initial dashboard probe's per-request HTTP timeout;
// pollProbeTimeout is the tighter budget used inside the bounded resolution
// loop, so a copy that accepts TCP but never answers HTTP cannot stretch the
// wait far past stuckResolveWait.
const (
	probeTimeout     = 2 * time.Second
	pollProbeTimeout = 750 * time.Millisecond
)

// portFromAddr extracts the port from a listen address; fallback when the
// address carries none or it does not parse.
func portFromAddr(addr string, fallback int) int {
	if _, p, err := net.SplitHostPort(addr); err == nil && p != "" {
		if n, cerr := strconv.Atoi(p); cerr == nil && n > 0 && n < 65536 {
			return n
		}
	}
	return fallback
}

// candidatePorts returns the loopback ports a running copy may answer on:
// the port it persisted on its last successful bind, plus this launch's own
// --addr port when different — a copy whose persistBoundPort write failed,
// or one running under ANOTHER user account (the mutex is machine-wide, the
// store per-user), still answers on the address both launches share.
func candidatePorts(cfg *config.Config) []int {
	stored := storedDashboardPort()
	if own := portFromAddr(cfg.Addr, stored); own != stored {
		return []int{stored, own}
	}
	return []int{stored}
}

// probeDashboards probes each candidate port and returns the first that
// answers (alive=true), or the first candidate with alive=false — the URL
// shown in that case is a best guess for messages only.
func probeDashboards(cfg *config.Config, ports []int, timeout time.Duration) (port int, alive bool) {
	for _, p := range ports {
		if dashboardAnswersOn(cfg, p, timeout) {
			return p, true
		}
	}
	return ports[0], false
}

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

	// The mutex alone is not proof of a HEALTHY instance (field report
	// v0.4.1): a copy stuck mid-startup — its first dialog hidden behind
	// other windows — or wedged mid-shutdown holds the mutex while answering
	// on no dashboard, and "Open dashboard" then lands on a refused
	// connection. Probe before claiming "already running"; when nothing
	// answers, wait a bounded moment for the copy to resolve itself either
	// way (finish starting → normal dialog; finish exiting → proceed with no
	// dialog at all), and only a copy that stays wedged gets the distinct
	// stuck-instance choice with a force-quit. Both candidate ports are
	// probed — the persisted last-bind port AND this launch's own --addr —
	// so a healthy copy whose port was never persisted (best-effort store,
	// another user account's per-user store behind the machine-wide mutex)
	// is not misdiagnosed as stuck.
	ports := candidatePorts(cfg)
	port, alive := probeDashboards(cfg, ports, probeTimeout)
	if !alive {
		var claimed windows.Handle
		deadline := time.Now().Add(stuckResolveWait)
		outcome := waitStuckResolution(
			func() bool {
				h2, owned2, err2 := claimInstanceMutex()
				if err2 == nil && owned2 {
					claimed = h2
					return true
				}
				if h2 != 0 {
					_ = windows.CloseHandle(h2)
				}
				return false
			},
			func() bool {
				// Short per-attempt timeout: against a copy that accepts TCP
				// but never answers HTTP, a full-length probe per round would
				// stretch the bounded wait well past its budget.
				port, alive = probeDashboards(cfg, ports, pollProbeTimeout)
				return alive
			},
			func() bool { return time.Now().After(deadline) },
			func() { time.Sleep(500 * time.Millisecond) },
		)
		switch outcome {
		case stuckWentAway:
			// The other copy was simply exiting: its mutex is ours now.
			waitForPortFree(cfg.Addr, time.Now().Add(2*time.Second))
			log.Info("previous instance exited during launch; proceeding")
			return func() { _ = windows.CloseHandle(claimed) }, true, nil
		case stuckStillStuck:
			return resolveStuckInstance(cfg, ui, log, ports)
		}
		// stuckBecameAlive: it was mid-startup — fall through to the normal
		// already-running choices below, which now have a live dashboard.
	}
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

// resolveStuckInstance handles the wedged case: the mutex is held, no
// dashboard answers, and the bounded wait changed neither. The user (or
// --yes) picks force-quit-and-start or exit; GUI mode gets its own dialog —
// NOT the already-running one, whose "Open dashboard" would land on a
// refused connection.
func resolveStuckInstance(cfg *config.Config, ui *appUI, log *slog.Logger, ports []int) (release func(), proceed bool, err error) {
	force := false
	switch {
	case cfg.Yes:
		fmt.Println("A previous WoW Mobile appears stuck (marked running, dashboard not answering) — force-quitting it (--yes).")
		force = true
	case ui.gui:
		force = winui.AskStuckInstance() == winui.StuckInstanceForceReplace
	case !stdinIsTerminal():
		fmt.Println("A previous WoW Mobile appears stuck: marked as running, but its dashboard does not answer.\n" +
			"Quit it yourself (tray icon, or Task Manager > wowstreamd.exe) and start again — or pass --yes to force-quit it.")
		return nil, false, nil
	default:
		fmt.Println("A previous WoW Mobile appears stuck: marked as running, but its dashboard does not answer.\n" +
			"It may still be starting (check the tray) or wedged mid-shutdown.\n" +
			"  [R] Force-quit it, then start this copy\n" +
			"  [X] Exit and check the tray / Task Manager yourself")
		for !force {
			fmt.Print("Choose [r/X]: ")
			var line string
			if _, serr := fmt.Scanln(&line); serr != nil {
				break // EOF/empty: the safe default
			}
			switch strings.ToLower(strings.TrimSpace(line)) {
			case "r":
				force = true
			case "x":
				// (A blank Enter never reaches this switch — Scanln returns
				// "unexpected newline" and the break above exits instead,
				// landing on the same safe default.)
				return nil, false, nil
			default:
				fmt.Println("Please answer r or x.")
				continue
			}
		}
	}
	if !force {
		fmt.Println("Leaving the stuck WoW Mobile alone — quit it from the tray or Task Manager, then start again.")
		return nil, false, nil
	}
	// Graceful first, on every candidate port: the "stuck" diagnosis rests on
	// loopback probes that can miss a healthy copy (a port that was never
	// persisted AND differs from this launch's --addr), and a quit request to
	// a dead port costs nothing. Only then the hard taskkill.
	for _, p := range ports {
		if qerr := requestInstanceQuit(cfg, p); qerr == nil {
			log.Info("stuck-diagnosed instance answered the graceful quit after all", "port", p)
			break
		}
	}
	fmt.Println("Force-quitting the stuck WoW Mobile...")
	if kerr := forceKillOtherInstances(log); kerr != nil {
		return nil, false, kerr
	}
	deadline := time.Now().Add(replaceWait)
	for {
		h, owned, cerr := claimInstanceMutex()
		if cerr == nil && owned {
			waitForPortFree(cfg.Addr, deadline)
			fmt.Println("The stuck WoW Mobile is gone; starting this one.")
			return func() { _ = windows.CloseHandle(h) }, true, nil
		}
		if h != 0 {
			_ = windows.CloseHandle(h)
		}
		if time.Now().After(deadline) {
			return nil, false, fmt.Errorf("the stuck WoW Mobile still holds the running marker after a force-quit — end wowstreamd.exe in Task Manager, then start this one again (if Task Manager refuses, the stuck copy runs as Administrator: use an elevated Task Manager)")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// forceKillOtherInstances ends every OTHER process with this binary's image
// name (taskkill /F, filtered to exclude our own PID — killing by bare image
// name would take this launch down too). A renamed portable copy holding the
// mutex cannot be found this way; the caller's mutex re-claim then fails
// with a Task-Manager pointer, which is the honest answer.
func forceKillOtherInstances(log *slog.Logger) error {
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("cannot determine this binary's name for the force-quit: %w", err)
	}
	image := filepath.Base(exe)
	out, err := exec.Command("taskkill", "/F", "/IM", image,
		"/FI", fmt.Sprintf("PID ne %d", os.Getpid())).CombinedOutput()
	msg := strings.TrimSpace(string(out))
	if err != nil {
		// taskkill exits non-zero when the filter matches nothing (a stuck
		// copy under a DIFFERENT binary name) or when access is denied (the
		// stuck copy is elevated and this launch is not) — the output names
		// which. Not fatal here: the mutex re-claim decides, and its timeout
		// message points at (an elevated) Task Manager.
		log.Warn("taskkill could not end another instance", "image", image, "output", msg, "err", err)
		return nil
	}
	log.Info("force-quit the stuck instance", "image", image, "output", msg)
	return nil
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
	return dashboardAnswersOn(cfg, port, probeTimeout)
}

// dashboardAnswersOn is dashboardAnswers with a caller-chosen per-request
// timeout (the stuck-resolution poll uses a tighter one).
func dashboardAnswersOn(cfg *config.Config, port int, timeout time.Duration) bool {
	client := &http.Client{
		Timeout: timeout,
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
