package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"image/png"
	"io"
	"net/http"
	"net/netip"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maximumFrameBytes = 2 * 1024 * 1024

type screenDevice interface {
	capture(context.Context) ([]byte, error)
	input(context.Context, ...string) error
}

type androidScreen struct{}

func (androidScreen) capture(ctx context.Context) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "/system/bin/screencap", "-p").Output()
}

func (androidScreen) input(ctx context.Context, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "/system/bin/input", args...).Run()
}

type screenBridge struct {
	config     deviceConfig
	configPath string
	allowed    netip.Prefix
	now        func() time.Time
	device     screenDevice

	mu         sync.Mutex
	lease      string
	expires    time.Time
	pairStarts time.Time
	pairCount  int

	operations sync.Mutex
	width      int
	height     int
	revision   uint64
	lastFrame  time.Time
}

func (b *screenBridge) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	peer, err := netip.ParseAddrPort(req.RemoteAddr)
	if err != nil || !b.allowed.Contains(peer.Addr().Unmap()) {
		http.Error(w, "hotspot clients only", http.StatusForbidden)
		return
	}
	token := strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer ")
	if !strings.HasPrefix(req.Header.Get("Authorization"), "Bearer ") || !validToken(token) {
		http.Error(w, "authentication required", http.StatusUnauthorized)
		return
	}
	switch {
	case req.Method == http.MethodPost && req.URL.Path == "/v1/enroll":
		b.enroll(w, req, token)
	case req.Method == http.MethodPost && req.URL.Path == "/v1/session":
		b.openSession(w, token)
	case req.Method == http.MethodDelete && req.URL.Path == "/v1/session":
		b.closeSession(w, token)
	case req.Method == http.MethodGet && req.URL.Path == "/v1/frame":
		b.withScreen(w, req, token, b.frame)
	case req.Method == http.MethodPost && req.URL.Path == "/v1/action":
		b.withScreen(w, req, token, b.action)
	default:
		http.NotFound(w, req)
	}
}

func validToken(value string) bool {
	if len(value) != 64 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil && value == strings.ToLower(value)
}

func matches(value, expected string) bool {
	return len(expected) == 64 && subtle.ConstantTimeCompare([]byte(tokenHash(value)), []byte(expected)) == 1
}

func decodeRequest(w http.ResponseWriter, req *http.Request, result any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(w, req.Body, 2048))
	decoder.DisallowUnknownFields()
	if decoder.Decode(result) != nil || decoder.Decode(new(any)) != io.EOF {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return false
	}
	return true
}

func (b *screenBridge) enroll(w http.ResponseWriter, req *http.Request, ticket string) {
	var input struct {
		Key string `json:"key"`
	}
	if !decodeRequest(w, req, &input) {
		return
	}
	if !validToken(input.Key) || input.Key == ticket {
		http.Error(w, "invalid phone key", http.StatusBadRequest)
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	if now.Sub(b.pairStarts) >= time.Minute {
		b.pairStarts, b.pairCount = now, 0
	}
	if b.pairCount >= 10 {
		http.Error(w, "too many enrollment attempts", http.StatusTooManyRequests)
		return
	}
	b.pairCount++
	if now.Unix() >= b.config.EnrollUntil || !matches(ticket, b.config.EnrollmentHash) || b.config.CredentialHash != "" {
		http.Error(w, "invalid or expired pairing ticket", http.StatusUnauthorized)
		return
	}
	next := b.config
	next.CredentialHash, next.EnrollmentHash, next.EnrollUntil = tokenHash(input.Key), "", 0
	if err := saveConfig(b.configPath, next); err != nil {
		http.Error(w, "could not save pairing", http.StatusInternalServerError)
		return
	}
	b.config = next
	w.WriteHeader(http.StatusNoContent)
}

func (b *screenBridge) openSession(w http.ResponseWriter, key string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !matches(key, b.config.CredentialHash) {
		http.Error(w, "phone is not paired", http.StatusUnauthorized)
		return
	}
	token, err := randomToken()
	if err != nil {
		http.Error(w, "could not open session", http.StatusInternalServerError)
		return
	}
	b.lease, b.expires = tokenHash(token), b.now().Add(leaseDuration)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(struct {
		Session string `json:"session"`
		Seconds int    `json:"seconds"`
	}{token, int(leaseDuration / time.Second)})
}

func (b *screenBridge) closeSession(w http.ResponseWriter, token string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !matches(token, b.lease) {
		http.Error(w, "session not found", http.StatusUnauthorized)
		return
	}
	b.lease = ""
	w.WriteHeader(http.StatusNoContent)
}

func (b *screenBridge) canUseScreen(token string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.now().Before(b.expires) && matches(token, b.lease)
}

func (b *screenBridge) withScreen(w http.ResponseWriter, req *http.Request, token string, operation http.HandlerFunc) {
	if !b.canUseScreen(token) {
		http.Error(w, "session expired", http.StatusUnauthorized)
		return
	}
	b.operations.Lock()
	defer b.operations.Unlock()
	if req.Context().Err() != nil {
		return
	}
	if !b.canUseScreen(token) {
		http.Error(w, "session expired", http.StatusUnauthorized)
		return
	}
	operation(w, req)
}

func (b *screenBridge) frame(w http.ResponseWriter, req *http.Request) {
	if b.now().Sub(b.lastFrame) < 180*time.Millisecond {
		http.Error(w, "frame request too fast", http.StatusTooManyRequests)
		return
	}
	b.lastFrame = b.now()
	data, err := b.device.capture(req.Context())
	if err != nil || len(data) == 0 || len(data) > maximumFrameBytes {
		http.Error(w, "screen capture unavailable", http.StatusServiceUnavailable)
		return
	}
	size, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil || size.Width < 1 || size.Height < 1 || size.Width > 4096 || size.Height > 4096 {
		http.Error(w, "screen capture unavailable", http.StatusServiceUnavailable)
		return
	}
	if b.width != size.Width || b.height != size.Height {
		b.width, b.height = size.Width, size.Height
		b.revision++
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("X-Screen-Revision", strconv.FormatUint(b.revision, 10))
	_, _ = w.Write(data)
}

type touchPoint struct {
	X *float64 `json:"x"`
	Y *float64 `json:"y"`
}

type screenAction struct {
	Kind     string     `json:"kind"`
	Start    touchPoint `json:"start"`
	End      touchPoint `json:"end"`
	Revision uint64     `json:"revision"`
}

var screenKeys = map[string]string{
	"back": "KEYCODE_BACK", "home": "KEYCODE_HOME",
	"recents": "KEYCODE_APP_SWITCH", "wake": "KEYCODE_WAKEUP",
}

func (b *screenBridge) action(w http.ResponseWriter, req *http.Request) {
	var input screenAction
	if !decodeRequest(w, req, &input) {
		return
	}
	var args []string
	if key := screenKeys[input.Kind]; key != "" {
		args = []string{"keyevent", key}
	} else {
		if input.Kind != "tap" && input.Kind != "swipe" {
			http.Error(w, "unsupported input", http.StatusBadRequest)
			return
		}
		if b.revision == 0 || input.Revision != b.revision {
			http.Error(w, "refresh the display before touching", http.StatusConflict)
			return
		}
		start, err := b.coordinates(input.Start)
		if err != nil {
			http.Error(w, "invalid touch coordinates", http.StatusBadRequest)
			return
		}
		args = append([]string{input.Kind}, start...)
		if input.Kind == "swipe" {
			end, err := b.coordinates(input.End)
			if err != nil {
				http.Error(w, "invalid swipe coordinates", http.StatusBadRequest)
				return
			}
			args = append(append(args, end...), "280")
		}
	}
	if err := b.device.input(req.Context(), args...); err != nil {
		http.Error(w, "input unavailable", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (b *screenBridge) coordinates(point touchPoint) ([]string, error) {
	if point.X == nil || point.Y == nil || *point.X < 0 || *point.X > 1 || *point.Y < 0 || *point.Y > 1 {
		return nil, errors.New("touch outside screen")
	}
	return []string{strconv.Itoa(int(*point.X * float64(b.width-1))), strconv.Itoa(int(*point.Y * float64(b.height-1)))}, nil
}
