// Package signal is the HTTPS front door: WHEP-style session signaling per
// PROTOCOL.md, static serving of the phone client, and the pairing banner.
package signal

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	qrcode "github.com/skip2/go-qrcode"

	"github.com/LcStylee/Wow-mobile/server/internal/hoststatus"
	"github.com/LcStylee/Wow-mobile/server/internal/rtc"
)

// authCookie carries "<sessionId>.<secret>" for the offer/teardown calls.
// PROTOCOL.md allows cookie or bearer; both are accepted.
const authCookie = "wowstreamd_session"

// init pins the MIME types the PWA depends on: on Windows (where the exe
// runs) mime.TypeByExtension consults per-machine registry values that
// third-party installers are known to corrupt (e.g. .js or .css mapped to
// text/plain). Browsers hard-reject module scripts, service workers, and
// standards-mode stylesheets served with a wrong type, which would brick the
// client on that PC with no server-side error — so the exe must not trust
// the registry for anything it serves. .webmanifest additionally has no
// entry in Go's built-in table at all.
func init() {
	// AddExtensionType only errors on an extension without a leading dot.
	_ = mime.AddExtensionType(".webmanifest", "application/manifest+json")
	_ = mime.AddExtensionType(".js", "text/javascript; charset=utf-8")
	_ = mime.AddExtensionType(".css", "text/css; charset=utf-8")
	_ = mime.AddExtensionType(".svg", "image/svg+xml")
	_ = mime.AddExtensionType(".html", "text/html; charset=utf-8")
	_ = mime.AddExtensionType(".png", "image/png")
}

// Server owns the HTTP listener and the session auth state.
type Server struct {
	addr string
	// token is kept alongside its hash solely to build the token-bound
	// manifest's start_url (handleManifest); every comparison still goes
	// through tokenHash + constant-time compare, and the raw value is never
	// logged.
	token     string
	tokenHash [32]byte
	noTLS     bool
	mgr       *rtc.Manager
	clientFS  fs.FS  // filesystem the phone client PWA is served from
	version   string // server build version, stamped into sw.js / js/version.js
	log       *slog.Logger

	httpServer *http.Server
	listener   net.Listener // bound by Listen, consumed by Serve
	boundPort  int          // actual TCP port after Listen (resolves --addr :0)

	host HostUI // zero value = host dashboard disabled

	// Single-session auth state, replaced wholesale on each pairing.
	authMu   sync.Mutex
	auth     sessionAuth
	haveAuth bool
}

// HostUI configures the loopback-only host dashboard (/host). All fields must
// be set for the dashboard to be served.
type HostUI struct {
	// FS is the embedded dashboard page tree (client/host).
	FS fs.FS
	// Status is serialized at GET /host/api/status and provides the pairing
	// URL for GET /host/qr.svg.
	Status *hoststatus.Status
	// Quit is invoked by POST /host/api/quit — the same graceful shutdown as
	// Ctrl+C (cancel the Serve context).
	Quit func()
}

// EnableHostUI turns on the /host dashboard routes. Must be called before
// Listen.
func (s *Server) EnableHostUI(h HostUI) { s.host = h }

type sessionAuth struct {
	id         string
	secretHash [32]byte
}

// New creates the signaling server. embeddedClient is the client PWA built
// into the binary (already rooted at the PWA's index.html); clientDirFlag is
// the raw --client-dir value — when set, it overrides the embedded files with
// a disk directory (development). version is the server build version, stamped
// into the served sw.js (cache name) and js/version.js (client HUD identity).
func New(addr, token string, noTLS bool, embeddedClient fs.FS, clientDirFlag, version string, mgr *rtc.Manager, log *slog.Logger) *Server {
	return &Server{
		addr:      addr,
		token:     token,
		tokenHash: sha256.Sum256([]byte(token)),
		noTLS:     noTLS,
		mgr:       mgr,
		clientFS:  resolveClientFS(embeddedClient, clientDirFlag, log),
		version:   version,
		log:       log,
	}
}

// resolveClientFS picks the filesystem the PWA is served from: the embedded
// copy by default (the binary does not care what directory it is started
// from), or the --client-dir override when it names an existing directory.
func resolveClientFS(embeddedClient fs.FS, flagValue string, log *slog.Logger) fs.FS {
	if flagValue != "" {
		abs, err := filepath.Abs(flagValue)
		if err == nil {
			if st, statErr := os.Stat(abs); statErr == nil && st.IsDir() {
				log.Info("serving phone client from disk (--client-dir override)", "dir", abs)
				return os.DirFS(abs)
			}
		}
		log.Warn("--client-dir is not an existing directory; serving the embedded client instead", "client-dir", flagValue)
	}
	return embeddedClient
}

// Listen binds the address and prepares TLS without serving yet, so callers
// print the "ready" banner only after a successful bind — a port already in
// use fails here, before any ready message could mislead.
func (s *Server) Listen() error {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/session", s.handleCreateSession)
	mux.HandleFunc("POST /api/session/{id}/offer", s.handleOffer)
	mux.HandleFunc("DELETE /api/session/{id}", s.handleDelete)
	// The manifest gets its own handler so ?token=<pairing token> can serve
	// the token-bound variant (start_url carries the token, making an
	// installed PWA open pre-paired); the exact-path pattern outranks the
	// catch-all file server below.
	mux.HandleFunc("GET /manifest.webmanifest", s.handleManifest)
	// Version-stamped shell files: the service worker's cache name and the
	// client's own version identity both derive from the SERVER version, so
	// every release busts the cached shell automatically (a stale cached
	// client was a live field failure) and the phone HUD can display what is
	// actually running. no-cache (not no-store): browsers may keep bytes but
	// must revalidate — exactly what a service worker update check needs.
	mux.HandleFunc("GET /sw.js", s.handleStamped("sw.js"))
	mux.HandleFunc("GET /js/version.js", s.handleStamped("js/version.js"))
	mux.Handle("/", http.FileServerFS(s.clientFS))
	s.registerHostRoutes(mux)

	s.httpServer = &http.Server{
		Addr:              s.addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	if !s.noTLS {
		cert, err := serverCertificate(LANIPs(), s.log)
		if err != nil {
			return err
		}
		s.httpServer.TLSConfig = &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
		}
	}

	ln, err := net.Listen("tcp", s.addr)
	if err != nil {
		return err
	}
	s.listener = ln
	if tcp, ok := ln.Addr().(*net.TCPAddr); ok {
		s.boundPort = tcp.Port
	}
	return nil
}

// Port returns the actually bound TCP port (0 before Listen). With --addr
// ending in :0 this is the kernel-assigned port — the value test harnesses
// need (via --port-file) and the one every printed URL uses.
func (s *Server) Port() int { return s.boundPort }

// port is the port every advertised URL carries: the bound port when known,
// else whatever --addr says (before Listen), else the 8443 default.
func (s *Server) port() string {
	if s.boundPort != 0 {
		return strconv.Itoa(s.boundPort)
	}
	_, port, err := net.SplitHostPort(s.addr)
	if err != nil || port == "" {
		return "8443"
	}
	return port
}

// Serve serves on the listener bound by Listen until ctx is cancelled, then
// shuts down gracefully. Listen must have returned nil first.
func (s *Server) Serve(ctx context.Context) error {
	errCh := make(chan error, 1)
	if s.noTLS {
		go func() { errCh <- s.httpServer.Serve(s.listener) }()
	} else {
		go func() { errCh <- s.httpServer.ServeTLS(s.listener, "", "") }()
	}

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		return s.httpServer.Shutdown(shutdownCtx)
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

// PrintBanner prints the pairing URL(s) and a scannable terminal QR code for
// the preferred one (ARCHITECTURE.md: token "printed + QR at startup"). The
// token rides in the query string; the client PWA reads it and POSTs it to
// /api/session.
func (s *Server) PrintBanner(w io.Writer, token string, tokenGenerated bool) {
	scheme := "https"
	if s.noTLS {
		scheme = "http"
	}
	port := s.port()
	ips := LANIPs()
	fmt.Fprintln(w)
	fmt.Fprintln(w, "wowstreamd ready — open on your phone (same Wi-Fi):")
	if len(ips) == 0 {
		fmt.Fprintf(w, "  %s://<this-pc-ip>:%s/?token=%s\n", scheme, port, token)
	}
	for _, ip := range ips {
		fmt.Fprintf(w, "  %s://%s:%s/?token=%s\n", scheme, ip, port, token)
	}
	if len(ips) > 0 {
		// LANIPs sorts private-range addresses first, so ips[0] is the URL a
		// phone on the same Wi-Fi most likely needs.
		url := fmt.Sprintf("%s://%s:%s/?token=%s", scheme, ips[0], port, token)
		if qr := terminalQR(url); qr != "" {
			fmt.Fprintln(w, "\nScan to pair:")
			fmt.Fprint(w, qr)
		}
	}
	if s.host.FS != nil {
		// Console mode: the dashboard is not auto-opened, so print where it
		// lives (GUI mode opens the browser and the tray icon links it) — or,
		// on a non-loopback --addr bind, say why there is no dashboard URL
		// instead of advertising one the listener cannot serve.
		if url := s.HostURL(); url != "" {
			fmt.Fprintf(w, "\nStatus dashboard (this PC only): %s\n", url)
		} else {
			fmt.Fprintf(w, "\nStatus dashboard unavailable: --addr binds %s only, which loopback cannot reach (use a wildcard or loopback bind to enable it).\n", s.addr)
		}
	}
	if tokenGenerated {
		fmt.Fprintln(w, "Pairing token was generated for this run; pass --token to fix it.")
	}
	if !s.noTLS {
		fmt.Fprintln(w, "The certificate is self-signed: accept the browser warning when pairing (it is reused across restarts).")
	}
	fmt.Fprintln(w)
}

// HostURL is the loopback address of the host dashboard, derived from the
// configured bind: 127.0.0.1 for the default wildcard binds (which include
// loopback), the bound address itself for an explicit loopback bind (e.g.
// --addr [::1]:8443, where 127.0.0.1 is NOT listening). It returns "" when
// --addr binds a specific non-loopback address: no loopback listener exists
// then — and LoopbackOnly would reject the /host routes on that address
// anyway — so there is no working dashboard URL to advertise; callers print a
// warning / skip the browser auto-open instead of pointing at a dead URL.
func (s *Server) HostURL() string {
	scheme := "https"
	if s.noTLS {
		scheme = "http"
	}
	host, _, err := net.SplitHostPort(s.addr)
	if err != nil {
		host = ""
	}
	port := s.port()
	ip := net.ParseIP(host)
	switch {
	case host == "" || (ip != nil && ip.IsUnspecified()):
		host = "127.0.0.1" // wildcard bind: loopback is included
	case (ip != nil && ip.IsLoopback()) || strings.EqualFold(host, "localhost"):
		// explicit loopback bind: keep it — it is the only listening address.
	default:
		return "" // non-loopback bind: the dashboard is unreachable
	}
	return fmt.Sprintf("%s://%s/host/", scheme, net.JoinHostPort(host, port))
}

// PairingURL is the preferred phone pairing URL (token in the query string),
// mirroring the banner's first line; "" when no LAN IP is known.
func (s *Server) PairingURL(token string) string {
	ips := LANIPs()
	if len(ips) == 0 {
		return ""
	}
	scheme := "https"
	if s.noTLS {
		scheme = "http"
	}
	return fmt.Sprintf("%s://%s:%s/?token=%s", scheme, ips[0], s.port(), token)
}

// terminalQR renders content as a half-block-character QR code, two modules
// per terminal row, or "" if encoding fails (content too long — the banner's
// plain URLs remain).
func terminalQR(content string) string {
	code, err := qrcode.New(content, qrcode.Medium)
	if err != nil {
		return ""
	}
	// inverseColor=false keeps dark modules dark: with the emitted light
	// border (quiet zone) around them, phone cameras scan this on both dark-
	// and light-background terminals.
	return code.ToSmallString(false)
}

// versionPlaceholder is the template literal in client/sw.js and
// client/js/version.js that handleStamped replaces with the server version.
const versionPlaceholder = "__WM_VERSION__"

// handleStamped serves one client file with the version placeholder replaced
// by the server's build version. The stamping is idempotent for files without
// the placeholder, so a --client-dir override that already hardcodes a value
// still serves correctly.
func (s *Server) handleStamped(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		data, err := fs.ReadFile(s.clientFS, name)
		if err != nil {
			http.Error(w, "file unavailable", http.StatusInternalServerError)
			return
		}
		stamped := stampVersion(data, s.version)
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		w.Write(stamped) //nolint:errcheck
	}
}

// stampVersion replaces the version placeholder. The version is embedded into
// a single-quoted JS string literal, so quotes/backslashes (never present in
// real versions, but never trust) are stripped rather than escaped.
func stampVersion(data []byte, version string) []byte {
	clean := strings.Map(func(r rune) rune {
		if r == '\'' || r == '\\' || r == '\n' || r == '\r' {
			return -1
		}
		return r
	}, version)
	return []byte(strings.ReplaceAll(string(data), versionPlaceholder, clean))
}

// handleManifest serves the PWA manifest. Without a token query parameter it
// serves the on-disk file byte-for-byte, exactly as the file server used to.
// With ?token=<t> matching the pairing token (constant-time, via the hash),
// it serves the TOKEN-BOUND variant: "start_url": "/?token=<token>" with
// scope unchanged, so Add to Home Screen captures a launch URL that
// self-pairs — installed PWAs (iOS above all) get their own storage
// partition, where the token saved during the in-browser scan is absent.
//
// Security posture: the token already rides the pairing URL this page was
// opened from, so echoing it back to the SAME holder leaks nothing new; a
// wrong or missing token gets the tokenless manifest (no oracle beyond the
// constant-time compare). The tokened variant is Cache-Control: no-store so
// no shared cache can hand it to another client, and the token is never
// logged (this handler logs nothing).
func (s *Server) handleManifest(w http.ResponseWriter, r *http.Request) {
	data, err := fs.ReadFile(s.clientFS, "manifest.webmanifest")
	if err != nil {
		http.Error(w, "manifest unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/manifest+json")

	q := r.URL.Query().Get("token")
	if q != "" {
		// Any tokened URL variant must never be cached beyond this response.
		w.Header().Set("Cache-Control", "no-store")
		got := sha256.Sum256([]byte(q))
		if subtle.ConstantTimeCompare(got[:], s.tokenHash[:]) == 1 {
			if bound, ok := tokenBoundManifest(data, s.token); ok {
				w.Write(bound) //nolint:errcheck
				return
			}
			// Malformed embedded manifest: fall through to the raw bytes —
			// a working tokenless manifest beats a 500 on install.
		}
	}
	w.Write(data) //nolint:errcheck
}

// tokenBoundManifest rewrites the manifest's start_url to the self-pairing
// "/?token=<token>" launch URL, leaving every other field (scope included)
// untouched. ok is false when the manifest is not valid JSON.
func tokenBoundManifest(manifest []byte, token string) ([]byte, bool) {
	var m map[string]any
	if err := json.Unmarshal(manifest, &m); err != nil {
		return nil, false
	}
	m["start_url"] = "/?token=" + url.QueryEscape(token)
	out, err := json.Marshal(m)
	if err != nil {
		return nil, false
	}
	return out, true
}

// handleCreateSession implements POST /api/session: constant-time token
// check, then a new session that replaces any existing one (safety rule 3).
func (s *Server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		http.Error(w, "malformed JSON body", http.StatusBadRequest)
		return
	}
	// Hash-then-compare keeps the comparison constant-time for any length.
	got := sha256.Sum256([]byte(body.Token))
	if subtle.ConstantTimeCompare(got[:], s.tokenHash[:]) != 1 {
		s.log.Warn("pairing rejected: bad token", "remote", r.RemoteAddr)
		http.Error(w, "invalid pairing token", http.StatusUnauthorized)
		return
	}

	id, err := randomHex(8)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	secret, err := randomHex(16)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	s.storeAuth(sessionAuth{id: id, secretHash: sha256.Sum256([]byte(secret))})
	s.mgr.Create(id)
	// Dashboard "phone" card: who paired last (nil-safe when no host UI).
	s.host.Status.SetPhoneInfo(r.RemoteAddr, r.UserAgent())

	http.SetCookie(w, &http.Cookie{
		Name:     authCookie,
		Value:    id + "." + secret,
		Path:     "/api/session",
		HttpOnly: true,
		Secure:   !s.noTLS,
		SameSite: http.SameSiteStrictMode,
	})
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	// The secret is also returned in-body so clients that prefer
	// Authorization: Bearer over cookies (PROTOCOL.md allows either) have it.
	json.NewEncoder(w).Encode(map[string]string{"sessionId": id, "bearer": secret}) //nolint:errcheck
}

func (s *Server) handleOffer(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.authorize(r, id) {
		http.Error(w, "unknown or unauthorized session", http.StatusNotFound)
		return
	}
	if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/sdp") {
		http.Error(w, "Content-Type must be application/sdp", http.StatusUnsupportedMediaType)
		return
	}
	offer, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		http.Error(w, "reading offer", http.StatusBadRequest)
		return
	}
	answer, err := s.mgr.Offer(id, string(offer))
	if err != nil {
		if errors.Is(err, rtc.ErrNoSession) {
			http.Error(w, "unknown session", http.StatusNotFound)
			return
		}
		if errors.Is(err, rtc.ErrSessionNegotiated) {
			// WHEP allows one offer/answer per session; renegotiation means
			// creating a new session (which replaces this one).
			http.Error(w, "session already negotiated; create a new session", http.StatusConflict)
			return
		}
		s.log.Error("SDP negotiation failed", "err", err)
		http.Error(w, "negotiation failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/sdp")
	w.WriteHeader(http.StatusCreated)
	io.WriteString(w, answer) //nolint:errcheck
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.authorize(r, id) {
		http.Error(w, "unknown or unauthorized session", http.StatusNotFound)
		return
	}
	if err := s.mgr.Close(id); err != nil && !errors.Is(err, rtc.ErrNoSession) {
		http.Error(w, "teardown failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// authorize checks the per-session credential (cookie or bearer) against the
// current session. Constant-time on the secret; id mismatch is not secret.
func (s *Server) authorize(r *http.Request, id string) bool {
	auth, ok := s.loadAuth()
	if !ok || auth.id != id {
		return false
	}
	secret := ""
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		secret = strings.TrimPrefix(h, "Bearer ")
	} else if c, err := r.Cookie(authCookie); err == nil {
		if idPart, secretPart, found := strings.Cut(c.Value, "."); found && idPart == id {
			secret = secretPart
		}
	}
	got := sha256.Sum256([]byte(secret))
	return subtle.ConstantTimeCompare(got[:], auth.secretHash[:]) == 1
}

func (s *Server) storeAuth(a sessionAuth) {
	s.authMu.Lock()
	defer s.authMu.Unlock()
	s.auth = a
	s.haveAuth = true
}

func (s *Server) loadAuth() (sessionAuth, bool) {
	s.authMu.Lock()
	defer s.authMu.Unlock()
	return s.auth, s.haveAuth
}

// randomHex returns n random bytes hex-encoded (2n characters).
func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
