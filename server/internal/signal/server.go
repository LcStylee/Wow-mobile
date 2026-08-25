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
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	qrcode "github.com/skip2/go-qrcode"

	"github.com/LcStylee/Wow-mobile/server/internal/rtc"
)

// authCookie carries "<sessionId>.<secret>" for the offer/teardown calls.
// PROTOCOL.md allows cookie or bearer; both are accepted.
const authCookie = "wowstreamd_session"

// Server owns the HTTP listener and the session auth state.
type Server struct {
	addr      string
	tokenHash [32]byte
	noTLS     bool
	mgr       *rtc.Manager
	clientDir string // resolved absolute path, or "" when no client dir exists
	log       *slog.Logger

	httpServer *http.Server

	// Single-session auth state, replaced wholesale on each pairing.
	authMu   sync.Mutex
	auth     sessionAuth
	haveAuth bool
}

type sessionAuth struct {
	id         string
	secretHash [32]byte
}

// New creates the signaling server. clientDirFlag is the raw --client-dir
// value ("" = try ./client then ../client).
func New(addr, token string, noTLS bool, clientDirFlag string, mgr *rtc.Manager, log *slog.Logger) *Server {
	return &Server{
		addr:      addr,
		tokenHash: sha256.Sum256([]byte(token)),
		noTLS:     noTLS,
		mgr:       mgr,
		clientDir: resolveClientDir(clientDirFlag, log),
		log:       log,
	}
}

// resolveClientDir applies the documented fallback: an explicit flag is used
// as-is (missing dir is a hard warning), otherwise ./client then ../client.
func resolveClientDir(flagValue string, log *slog.Logger) string {
	candidates := []string{"./client", "../client"}
	if flagValue != "" {
		candidates = []string{flagValue}
	}
	for _, c := range candidates {
		abs, err := filepath.Abs(c)
		if err != nil {
			continue
		}
		if st, err := os.Stat(abs); err == nil && st.IsDir() {
			log.Info("serving phone client", "dir", abs)
			return abs
		}
	}
	log.Warn("phone client directory not found; only /api endpoints will work", "tried", candidates)
	return ""
}

// Run serves until ctx is cancelled, then shuts down gracefully.
func (s *Server) Run(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/session", s.handleCreateSession)
	mux.HandleFunc("POST /api/session/{id}/offer", s.handleOffer)
	mux.HandleFunc("DELETE /api/session/{id}", s.handleDelete)
	if s.clientDir != "" {
		mux.Handle("/", http.FileServer(http.Dir(s.clientDir)))
	} else {
		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, "wowstreamd: phone client files not found; run from the repo root or pass --client-dir", http.StatusNotFound)
		})
	}

	s.httpServer = &http.Server{
		Addr:              s.addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	errCh := make(chan error, 1)
	if s.noTLS {
		go func() { errCh <- s.httpServer.ListenAndServe() }()
	} else {
		cert, err := serverCertificate(LANIPs(), s.log)
		if err != nil {
			return err
		}
		s.httpServer.TLSConfig = &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
		}
		go func() { errCh <- s.httpServer.ListenAndServeTLS("", "") }()
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
	_, port, err := net.SplitHostPort(s.addr)
	if err != nil || port == "" {
		port = "8443"
	}
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
	if tokenGenerated {
		fmt.Fprintln(w, "Pairing token was generated for this run; pass --token to fix it.")
	}
	if !s.noTLS {
		fmt.Fprintln(w, "The certificate is self-signed: accept the browser warning when pairing (it is reused across restarts).")
	}
	fmt.Fprintln(w)
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
