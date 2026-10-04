// Package remote makes the PC reachable from outside the home network
// ("play over mobile data"): it asks the router to forward the streaming
// port (UPnP IGD, TCP for pairing/signaling and UDP for WebRTC, the same
// number) and finds the home's public IPv4 address, which the WebRTC side
// then advertises next to the LAN addresses (rtc.Manager.SetPublicIP).
//
// Three outcomes, reported as Status for the host dashboard:
//   - open:   the router forwarded the port; the away link works.
//   - manual: no UPnP answer (often switched off in the router); the public
//     address is known via STUN, and forwarding TCP+UDP <port> to the PC
//     by hand makes the away link work.
//   - cgnat:  the router itself has no public address (the provider shares
//     one between customers, or a second router sits in front) — nothing on
//     this PC can open a way in.
//
// Security: what becomes reachable is the same server the phone uses at
// home — HTTPS with the persisted self-signed certificate, every phone
// route behind the 128-bit pairing token, the /host dashboard loopback-only.
package remote

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"sync"
	"time"

	"github.com/huin/goupnp/dcps/internetgateway2"
	"github.com/pion/stun/v3"
)

// States reported in Status.State.
const (
	StateOff     = "off"
	StateWorking = "working"
	StateOpen    = "open"
	StateManual  = "manual"
	StateCGNAT   = "cgnat"
	StateFailed  = "failed"
)

// Status is the dashboard's view of remote play.
type Status struct {
	Enabled  bool   `json:"enabled"`
	State    string `json:"state"`
	PublicIP string `json:"publicIp,omitempty"`
	LANIP    string `json:"lanIp,omitempty"`
	Port     int    `json:"port"`    // TCP: pairing / signaling (the away link's port)
	UDPPort  int    `json:"udpPort"` // UDP: WebRTC media + input
	Message  string `json:"message"`
}

// gateway is the subset of the UPnP WAN connection services (IP v1/v2, PPP
// v1 all share these signatures) that remote play uses.
type gateway interface {
	AddPortMappingCtx(ctx context.Context, remoteHost string, externalPort uint16, protocol string,
		internalPort uint16, internalClient string, enabled bool, description string, leaseSeconds uint32) error
	DeletePortMappingCtx(ctx context.Context, remoteHost string, externalPort uint16, protocol string) error
	GetExternalIPAddressCtx(ctx context.Context) (string, error)
	LocalAddr() net.IP
}

const (
	leaseSeconds  = 3600             // routers drop the mapping if we vanish
	renewEvery    = 20 * time.Minute // well inside the lease
	discoverLimit = 10 * time.Second
	mappingName   = "WoW Mobile"
)

// Controller runs remote play: Enable/Disable from the dashboard, Status
// for it. onPublicIP receives the address to advertise ("" when off).
type Controller struct {
	port       int // TCP
	udpPort    int
	log        *slog.Logger
	onPublicIP func(ip string) error

	// Injected in tests.
	discover func(ctx context.Context) (gateway, error)
	stunIP   func(ctx context.Context) (string, error)

	mu     sync.Mutex
	status Status
	cancel context.CancelFunc
	done   chan struct{}
}

// New returns a stopped controller for the signaling TCP port and the
// WebRTC UDP port (often the same number).
func New(tcpPort, udpPort int, log *slog.Logger, onPublicIP func(string) error) *Controller {
	return &Controller{
		port:       tcpPort,
		udpPort:    udpPort,
		log:        log.With("component", "remote"),
		onPublicIP: onPublicIP,
		discover:   discoverGateway,
		stunIP:     stunPublicIP,
		status:     Status{State: StateOff, Port: tcpPort, UDPPort: udpPort},
	}
}

// Status returns a snapshot.
func (c *Controller) Status() Status {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.status
}

func (c *Controller) set(update func(*Status)) {
	c.mu.Lock()
	update(&c.status)
	c.mu.Unlock()
}

// SetEnabled turns remote play on (opens the port, finds the address, keeps
// renewing) or off (closes the port, stops advertising). Idempotent.
func (c *Controller) SetEnabled(on bool) {
	c.mu.Lock()
	if on == (c.cancel != nil) {
		c.mu.Unlock()
		return
	}
	if !on {
		cancel, done := c.cancel, c.done
		c.cancel, c.done = nil, nil
		c.mu.Unlock()
		cancel()
		<-done
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.cancel, c.done = cancel, make(chan struct{})
	c.status = Status{Enabled: true, State: StateWorking, Port: c.port, UDPPort: c.udpPort, Message: "Opening the port on your router…"}
	done := c.done
	c.mu.Unlock()
	go c.run(ctx, done)
}

func (c *Controller) run(ctx context.Context, done chan struct{}) {
	defer close(done)
	var gw gateway
	advertised := ""
	defer func() {
		// Off: stop advertising, close the router port (best effort, on a
		// fresh context — ours is cancelled).
		if advertised != "" {
			_ = c.onPublicIP("")
		}
		if gw != nil {
			cctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_ = gw.DeletePortMappingCtx(cctx, "", uint16(c.port), "TCP")
			_ = gw.DeletePortMappingCtx(cctx, "", uint16(c.udpPort), "UDP")
			cancel()
		}
		c.set(func(s *Status) { *s = Status{State: StateOff, Port: c.port, UDPPort: c.udpPort, Message: "Off"} })
	}()

	for {
		var r result
		gw, r = c.attempt(ctx, gw)
		if ctx.Err() != nil {
			return
		}
		if r.publicIP != advertised {
			if err := c.onPublicIP(r.publicIP); err != nil {
				r = result{state: StateFailed, message: err.Error(), lanIP: r.lanIP}
			} else {
				advertised = r.publicIP
			}
		}
		c.log.Info("remote play", "state", r.state, "public", r.publicIP, "lan", r.lanIP)
		c.set(func(s *Status) {
			*s = Status{Enabled: true, State: r.state, PublicIP: r.publicIP, LANIP: r.lanIP, Port: c.port, UDPPort: c.udpPort, Message: r.message}
		})
		wait := renewEvery
		if r.state != StateOpen {
			wait = 2 * time.Minute // keep trying: the router may come round
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

type result struct {
	state, publicIP, lanIP, message string
}

// attempt maps the port (again — renewal is the same call) and works out
// the public address. It returns the gateway to reuse next time.
func (c *Controller) attempt(ctx context.Context, gw gateway) (gateway, result) {
	if gw == nil {
		dctx, cancel := context.WithTimeout(ctx, discoverLimit)
		found, err := c.discover(dctx)
		cancel()
		if err != nil {
			c.log.Info("no UPnP router answered", "err", err)
		}
		gw = found
	}
	sctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	stunAddr, stunErr := c.stunIP(sctx)
	cancel()
	if stunErr != nil {
		c.log.Info("public address lookup (STUN) failed", "err", stunErr)
	}

	lan := outboundIP()
	if gw == nil {
		return nil, decide(false, nil, "", stunAddr, lan, c.port, c.udpPort)
	}
	if l := gw.LocalAddr(); l != nil {
		lan = l.String()
	}
	var mapErr error
	if err := addMapping(ctx, gw, c.port, "TCP", lan); err != nil {
		mapErr = fmt.Errorf("TCP: %w", err)
	}
	if err := addMapping(ctx, gw, c.udpPort, "UDP", lan); err != nil {
		mapErr = fmt.Errorf("UDP: %w", err)
	}
	ext, extErr := gw.GetExternalIPAddressCtx(ctx)
	if extErr != nil {
		ext = ""
	}
	return gw, decide(true, mapErr, ext, stunAddr, lan, c.port, c.udpPort)
}

// addMapping forwards port/proto to lan. Some routers refuse a non-zero
// lease ("OnlyPermanentLeasesSupported"); retry permanent then.
func addMapping(ctx context.Context, gw gateway, port int, proto, lan string) error {
	err := gw.AddPortMappingCtx(ctx, "", uint16(port), proto, uint16(port), lan, true, mappingName, leaseSeconds)
	if err != nil {
		err = gw.AddPortMappingCtx(ctx, "", uint16(port), proto, uint16(port), lan, true, mappingName, 0)
	}
	return err
}

// decide turns what the router and STUN said into a Status outcome. Pure
// (unit-tested).
//   - router answered, mapped, and its WAN address is public (and agrees
//     with STUN when STUN answered): open.
//   - router's WAN address is shared/private, or STUN sees a different
//     address (a second NAT in front): cgnat.
//   - no router / mapping refused but STUN found a public address: manual.
func decide(haveGW bool, mapErr error, upnpExt, stunAddr, lan string, port, udpPort int) result {
	r := result{lanIP: lan}
	manual := func(public string) result {
		r.state, r.publicIP = StateManual, public
		r.message = fmt.Sprintf("Your router did not open the ports automatically (UPnP may be switched off in its settings). "+
			"Forward TCP port %d and UDP port %d to this PC (%s) in your router, and the away link works.", port, udpPort, lan)
		return r
	}
	if haveGW && upnpExt != "" && isShared(net.ParseIP(upnpExt)) {
		r.state = StateCGNAT
		r.message = cgnatMessage
		return r
	}
	if haveGW && mapErr == nil && upnpExt != "" {
		if stunAddr != "" && stunAddr != upnpExt {
			r.state = StateCGNAT
			r.message = cgnatMessage
			return r
		}
		r.state, r.publicIP = StateOpen, upnpExt
		r.message = fmt.Sprintf("Your router forwards TCP %d and UDP %d to this PC. The away link works on mobile data.", port, udpPort)
		return r
	}
	public := stunAddr
	if public == "" && haveGW {
		public = upnpExt
	}
	if public != "" && !isShared(net.ParseIP(public)) {
		return manual(public)
	}
	r.state = StateFailed
	r.message = "Could not find your home's public address — is this PC online?"
	return r
}

const cgnatMessage = "Your internet connection has no public address of its own (your provider shares one between " +
	"customers, or a second router sits in front of yours), so the phone cannot reach this PC from outside. " +
	"Ask your provider for a public IPv4 address, or use a VPN app such as Tailscale."

// isShared reports addresses that cannot be reached from the internet:
// private, carrier-grade NAT (100.64.0.0/10), loopback, link-local.
func isShared(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
		return true
	}
	_, cgnat, _ := net.ParseCIDR("100.64.0.0/10")
	return cgnat.Contains(ip)
}

// outboundIP is the LAN address the default route leaves from (no packet is
// sent: a UDP "connect" only picks the route).
func outboundIP() string {
	conn, err := net.Dial("udp4", "192.0.2.1:9")
	if err != nil {
		return ""
	}
	defer conn.Close()
	if a, ok := conn.LocalAddr().(*net.UDPAddr); ok {
		return a.IP.String()
	}
	return ""
}

// discoverGateway finds the first UPnP WAN connection service on the LAN.
func discoverGateway(ctx context.Context) (gateway, error) {
	type found struct {
		gw  gateway
		err error
	}
	ch := make(chan found, 3)
	go func() {
		c, _, err := internetgateway2.NewWANIPConnection2ClientsCtx(ctx)
		if len(c) > 0 {
			ch <- found{gw: c[0]}
			return
		}
		ch <- found{err: err}
	}()
	go func() {
		c, _, err := internetgateway2.NewWANIPConnection1ClientsCtx(ctx)
		if len(c) > 0 {
			ch <- found{gw: c[0]}
			return
		}
		ch <- found{err: err}
	}()
	go func() {
		c, _, err := internetgateway2.NewWANPPPConnection1ClientsCtx(ctx)
		if len(c) > 0 {
			ch <- found{gw: c[0]}
			return
		}
		ch <- found{err: err}
	}()
	var lastErr error
	for i := 0; i < 3; i++ {
		f := <-ch
		if f.gw != nil {
			return f.gw, nil
		}
		if f.err != nil {
			lastErr = f.err
		}
	}
	if lastErr == nil {
		lastErr = errors.New("no UPnP internet gateway found")
	}
	return nil, lastErr
}

// stunServers answer "what address do you see me at?" (RFC 5389).
var stunServers = []string{"stun.l.google.com:19302", "stun.cloudflare.com:3478"}

func stunPublicIP(ctx context.Context) (string, error) {
	var lastErr error
	for _, server := range stunServers {
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		ip, err := stunOnce(ctx, server)
		if err == nil {
			return ip, nil
		}
		lastErr = err
	}
	return "", lastErr
}

func stunOnce(ctx context.Context, server string) (string, error) {
	d := net.Dialer{}
	conn, err := d.DialContext(ctx, "udp4", server)
	if err != nil {
		return "", err
	}
	client, err := stun.NewClient(conn)
	if err != nil {
		conn.Close()
		return "", err
	}
	defer client.Close()
	var ip string
	var cbErr error
	err = client.Do(stun.MustBuild(stun.TransactionID, stun.BindingRequest), func(ev stun.Event) {
		if ev.Error != nil {
			cbErr = ev.Error
			return
		}
		var xor stun.XORMappedAddress
		if err := xor.GetFrom(ev.Message); err != nil {
			cbErr = err
			return
		}
		ip = xor.IP.String()
	})
	if err != nil {
		return "", err
	}
	if cbErr != nil {
		return "", cbErr
	}
	return ip, nil
}
