// Host dashboard routes: a loopback-only status page for the person at the
// gaming PC. Every /host route is guarded by LoopbackOnly — the dashboard
// shows the pairing token (in the URL/QR), so it must be reachable from this
// machine's own browser and from nothing else on the LAN. Phone-facing routes
// (/, /api/session...) are untouched by any of this.
package signal

import (
	"net"
	"net/http"
	"strings"
)

// registerHostRoutes mounts the /host tree when EnableHostUI configured it.
func (s *Server) registerHostRoutes(mux *http.ServeMux) {
	if s.host.FS == nil {
		return
	}
	// The page tree (index.html, host.css, host.js). StripPrefix maps
	// /host/ -> the embedded client/host root; FileServerFS serves index.html
	// for the directory request.
	mux.Handle("GET /host/", LoopbackOnly(http.StripPrefix("/host/", http.FileServerFS(s.host.FS))))
	mux.Handle("GET /host", LoopbackOnly(http.RedirectHandler("/host/", http.StatusMovedPermanently)))
	mux.Handle("GET /host/api/status", LoopbackOnly(http.HandlerFunc(s.handleHostStatus)))
	mux.Handle("GET /host/qr.svg", LoopbackOnly(http.HandlerFunc(s.handleHostQR)))
	mux.Handle("POST /host/api/quit", LoopbackOnly(http.HandlerFunc(s.handleHostQuit)))
}

// LoopbackOnly rejects with 403 any request whose peer address is not a
// loopback IP, or whose Host header is not a loopback name. RemoteAddr is the
// connected TCP peer as seen by this server — not a spoofable header — so
// that half is a real same-machine check. The Host check closes the DNS-
// rebinding hole that peer checking alone leaves open under --no-tls: an
// attacker page whose domain re-resolves to 127.0.0.1 makes the victim's own
// browser (a loopback peer) fetch /host with Host: attacker.example as a
// same-origin request, letting its JS read the pairing token and send the
// quit CSRF header. Such requests carry the attacker's hostname, never
// 127.0.0.1/localhost, so requiring a loopback Host defeats them. (Default
// TLS runs are already immune — the self-signed 127.0.0.1 certificate never
// validates for another hostname — this is defense in depth for --no-tls.)
// Anything unparsable is rejected too: fail closed.
func LoopbackOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !isLoopbackHostPort(r.RemoteAddr) || !isLoopbackHostname(r.Host) {
			http.Error(w, "the host dashboard is only available on the PC running wowstreamd", http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// isLoopbackHostPort reports whether addr ("ip:port", or a bare ip) parses as
// a loopback IP.
func isLoopbackHostPort(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr // no port (unusual, but don't fail open)
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && ip.IsLoopback()
}

// isLoopbackHostname reports whether an HTTP Host header value names this
// machine's loopback: a loopback IP literal or "localhost", with any port.
func isLoopbackHostname(hostHeader string) bool {
	if strings.EqualFold(hostHeader, "localhost") || isLoopbackHostPort(hostHeader) {
		return true
	}
	// "localhost:8443": SplitHostPort is needed because isLoopbackHostPort
	// only parses IPs.
	host, _, err := net.SplitHostPort(hostHeader)
	return err == nil && strings.EqualFold(host, "localhost")
}

// handleHostStatus serves the dashboard's 1 s polling JSON.
func (s *Server) handleHostStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(s.host.Status.JSON()) //nolint:errcheck
}

// handleHostQR serves the pairing URL as a scalable SVG QR code.
func (s *Server) handleHostQR(w http.ResponseWriter, r *http.Request) {
	url := s.host.Status.PairingURL()
	if url == "" {
		http.Error(w, "pairing URL not available yet", http.StatusServiceUnavailable)
		return
	}
	svg, err := qrSVG(url)
	if err != nil {
		http.Error(w, "QR encoding failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "image/svg+xml")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(svg) //nolint:errcheck
}

// QuitHeader is the dashboard's proof-of-intent header on POST /host/api/quit.
// LoopbackOnly checks the TCP peer, but a browser running ON this PC is a
// loopback peer too: once the user has accepted the certificate for
// 127.0.0.1, any website open in that browser could fire a cross-origin
// no-cors POST at the quit endpoint (browsers without full Private Network
// Access enforcement send it) — a drive-by kill of the stream. A custom
// header cannot be attached to a no-cors cross-origin request, and the CORS
// preflight it would otherwise trigger is never answered with an allowance,
// so requiring it limits quit to same-origin dashboard code — plus the one
// other legitimate loopback caller: the single-instance "Replace it" flow in
// cmd/wowstreamd, which sends the same header on its loopback-to-loopback
// takeover POST (exported for exactly that caller; the LoopbackOnly guard is
// unchanged).
const QuitHeader = "X-Wowmobile-Quit"

// handleHostQuit gracefully shuts the whole server down — identical to
// Ctrl+C: inputs released, peer closed, ffmpeg stopped, listener drained.
func (s *Server) handleHostQuit(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(QuitHeader) == "" {
		http.Error(w, "quit requires the dashboard's "+QuitHeader+" header", http.StatusForbidden)
		return
	}
	s.log.Info("shutdown requested via host dashboard")
	w.WriteHeader(http.StatusNoContent)
	if s.host.Quit != nil {
		// After the response is on the wire; Shutdown drains in-flight
		// requests, so ordering is cosmetic — but the page likes its 204.
		go s.host.Quit()
	}
}
