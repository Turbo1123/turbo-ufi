package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

const leaseDuration = 10 * time.Minute

type deviceConfig struct {
	Host           string `json:"host"`
	Network        string `json:"network"`
	Port           int    `json:"port"`
	EnrollmentHash string `json:"enrollment_hash,omitempty"`
	EnrollUntil    int64  `json:"enroll_until,omitempty"`
	CredentialHash string `json:"credential_hash,omitempty"`
}

type pairingFile struct {
	Version           int    `json:"version"`
	Host              string `json:"host"`
	Port              int    `json:"port"`
	CertificateSHA256 string `json:"certificateSHA256"`
	Ticket            string `json:"ticket"`
}

func main() {
	var directory, host, network string
	var port int
	var provision bool
	flag.StringVar(&directory, "dir", "", "private state directory")
	flag.StringVar(&host, "host", "192.168.0.1", "hotspot gateway")
	flag.StringVar(&network, "network", "192.168.0.0/24", "allowed hotspot subnet")
	flag.IntVar(&port, "port", 9443, "hotspot TLS port")
	flag.BoolVar(&provision, "provision", false, "initialize credentials and write a pairing record to stdout")
	flag.Parse()
	if directory == "" {
		log.Fatal("state directory is required")
	}
	if provision {
		if err := initialize(directory, host, network, port); err != nil {
			log.Fatal(err)
		}
		return
	}
	if err := restrictProcess(); err != nil {
		log.Fatal(err)
	}
	if err := serve(directory); err != nil {
		log.Fatal(err)
	}
}

func initialize(directory, host, network string, port int) error {
	address, err := netip.ParseAddr(host)
	if err != nil || !address.Is4() || !address.IsPrivate() || port < 1024 || port > 65535 {
		return errors.New("a private hotspot IPv4 address and an unprivileged port are required")
	}
	prefix, err := netip.ParsePrefix(network)
	if err != nil || !prefix.Contains(address) || prefix.Bits() < 16 {
		return errors.New("hotspot subnet is invalid")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	for _, name := range []string{"config.json", "server.pem", "server-key.pem"} {
		if _, err := os.Stat(filepath.Join(directory, name)); !errors.Is(err, os.ErrNotExist) {
			return errors.New("state already provisioned; use a fresh private directory before re-pairing")
		}
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return err
	}
	now := time.Now()
	cert := x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "Turbo UFI Android"},
		NotBefore: now.Add(-10 * time.Minute), NotAfter: now.AddDate(5, 0, 0),
		IPAddresses: []net.IP{net.ParseIP(host)}, KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, &cert, &cert, &key.PublicKey, key)
	if err != nil {
		return err
	}
	privateKey, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	for _, file := range []struct {
		name string
		data []byte
	}{
		{"server.pem", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})},
		{"server-key.pem", pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateKey})},
	} {
		if err := os.WriteFile(filepath.Join(directory, file.name), file.data, 0600); err != nil {
			return err
		}
	}
	ticket, err := randomToken()
	if err != nil {
		return err
	}
	cfg := deviceConfig{Host: host, Network: prefix.Masked().String(), Port: port,
		EnrollmentHash: tokenHash(ticket), EnrollUntil: now.Add(72 * time.Hour).Unix()}
	if err := saveConfig(filepath.Join(directory, "config.json"), cfg); err != nil {
		return err
	}
	digest := sha256.Sum256(der)
	return json.NewEncoder(os.Stdout).Encode(pairingFile{
		Version: 1, Host: host, Port: port, CertificateSHA256: hex.EncodeToString(digest[:]), Ticket: ticket,
	})
}

func saveConfig(path string, cfg deviceConfig) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".config-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if err = json.NewEncoder(file).Encode(cfg); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), path)
}

func serve(directory string) error {
	path := filepath.Join(directory, "config.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var cfg deviceConfig
	if err = json.Unmarshal(data, &cfg); err != nil {
		return err
	}
	ip, err := netip.ParseAddr(cfg.Host)
	subnet, subnetErr := netip.ParsePrefix(cfg.Network)
	if err != nil || subnetErr != nil || !ip.Is4() || !ip.IsPrivate() || !subnet.Contains(ip) ||
		cfg.Port < 1024 || cfg.Port > 65535 {
		return errors.New("invalid hotspot binding")
	}
	bridge := &screenBridge{config: cfg, configPath: path, allowed: subnet, now: time.Now, device: androidScreen{}}
	server := &http.Server{
		Addr: net.JoinHostPort(ip.String(), strconv.Itoa(cfg.Port)), Handler: bridge,
		ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 6 * time.Second,
		IdleTimeout: 12 * time.Second, MaxHeaderBytes: 4096,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12},
	}
	log.Print(fmt.Sprintf("Turbo UFI Screen ready on %s", server.Addr))
	return server.ListenAndServeTLS(filepath.Join(directory, "server.pem"), filepath.Join(directory, "server-key.pem"))
}

func randomToken() (string, error) {
	var bytes [32]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes[:]), nil
}

func tokenHash(token string) string {
	digest := sha256.Sum256([]byte(token))
	return hex.EncodeToString(digest[:])
}
