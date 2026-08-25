package signal

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"log/slog"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// Certificate files under <user config dir>/wowstreamd. Persisting the
// self-signed key pair keeps the certificate identical across restarts, so
// the phone's "accept this certificate" decision really is one-time — a fresh
// cert per start would re-prompt after every restart, which iOS PWA installs
// handle particularly poorly.
const (
	certDirName  = "wowstreamd"
	certFileName = "tls-cert.pem"
	keyFileName  = "tls-key.pem"
)

// renewBefore forces regeneration while the persisted certificate still has
// this much validity left, so it never expires mid-session.
const renewBefore = 7 * 24 * time.Hour

// serverCertificate returns the TLS certificate to serve: the persisted one
// when it is still valid and covers every current LAN IP, otherwise a freshly
// generated one that is persisted for next time. If the config dir is
// unusable the certificate is served ephemerally (with a warning) rather than
// failing startup.
func serverCertificate(lanIPs []net.IP, log *slog.Logger) (tls.Certificate, error) {
	dir, dirErr := certDir()
	if dirErr == nil {
		if cert, ok := loadCertificate(dir, lanIPs); ok {
			return cert, nil
		}
	}
	cert, err := selfSignedCert(lanIPs)
	if err != nil {
		return tls.Certificate{}, err
	}
	if dirErr != nil {
		log.Warn("no user config dir; TLS certificate is ephemeral and the phone will re-prompt after each restart", "err", dirErr)
		return cert, nil
	}
	if err := saveCertificate(dir, cert); err != nil {
		log.Warn("persisting TLS certificate failed; the phone will re-prompt after each restart", "err", err)
	}
	return cert, nil
}

func certDir() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(base, certDirName)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return dir, nil
}

// loadCertificate returns the persisted certificate if it parses, has more
// than renewBefore of validity left, and lists every current LAN IP in its
// SANs (a DHCP address change regenerates, avoiding hard name-mismatch
// failures that, unlike the self-signed warning, browsers refuse to bypass).
func loadCertificate(dir string, lanIPs []net.IP) (tls.Certificate, bool) {
	certPEM, err := os.ReadFile(filepath.Join(dir, certFileName))
	if err != nil {
		return tls.Certificate{}, false
	}
	keyPEM, err := os.ReadFile(filepath.Join(dir, keyFileName))
	if err != nil {
		return tls.Certificate{}, false
	}
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, false
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return tls.Certificate{}, false
	}
	if time.Now().Add(renewBefore).After(leaf.NotAfter) {
		return tls.Certificate{}, false
	}
	for _, want := range lanIPs {
		if !containsIP(leaf.IPAddresses, want) {
			return tls.Certificate{}, false
		}
	}
	return cert, true
}

func containsIP(haystack []net.IP, want net.IP) bool {
	for _, ip := range haystack {
		if ip.Equal(want) {
			return true
		}
	}
	return false
}

func saveCertificate(dir string, cert tls.Certificate) error {
	key, ok := cert.PrivateKey.(*ecdsa.PrivateKey)
	if !ok {
		return fmt.Errorf("unexpected private key type %T", cert.PrivateKey)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	if err := os.WriteFile(filepath.Join(dir, certFileName), certPEM, 0o600); err != nil {
		return err
	}
	// 0600: the key identifies this host to paired phones; other local users
	// must not be able to read it.
	return os.WriteFile(filepath.Join(dir, keyFileName), keyPEM, 0o600)
}

// selfSignedCert generates a self-signed ECDSA P-256 certificate covering
// localhost and every detected LAN IP, so the phone browser's warning is a
// plain "self-signed" prompt rather than a hard name-mismatch failure.
func selfSignedCert(lanIPs []net.IP) (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("generating TLS key: %w", err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("generating serial: %w", err)
	}

	ips := append([]net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback}, lanIPs...)
	template := x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "wowstreamd"},
		NotBefore:             time.Now().Add(-time.Hour), // tolerate clock skew
		NotAfter:              time.Now().Add(90 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"localhost"},
		IPAddresses:           ips,
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("creating certificate: %w", err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}

// LANIPs returns the machine's non-loopback unicast IPv4 addresses, most
// useful (private-range) first — these go into the cert SANs and the banner.
func LANIPs() []net.IP {
	var private, other []net.IP
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipNet.IP.To4()
			if ip4 == nil {
				continue
			}
			if ip4.IsPrivate() {
				private = append(private, ip4)
			} else {
				other = append(other, ip4)
			}
		}
	}
	return append(private, other...)
}
