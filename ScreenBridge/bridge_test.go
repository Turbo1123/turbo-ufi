package main

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/png"
	"net/http/httptest"
	"net/netip"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

type sampleScreen struct {
	size   image.Rectangle
	inputs [][]string
	takes  int
}

func (s *sampleScreen) capture(context.Context) ([]byte, error) {
	s.takes++
	var data bytes.Buffer
	err := png.Encode(&data, image.NewRGBA(s.size))
	return data.Bytes(), err
}

func (s *sampleScreen) input(_ context.Context, args ...string) error {
	s.inputs = append(s.inputs, args)
	return nil
}

func TestPairingSessionAndTouch(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	ticket, key := strings.Repeat("a", 64), strings.Repeat("b", 64)
	screen := &sampleScreen{size: image.Rect(0, 0, 480, 854)}
	bridge := &screenBridge{
		config:     deviceConfig{EnrollmentHash: tokenHash(ticket), EnrollUntil: now.Add(time.Hour).Unix()},
		configPath: filepath.Join(t.TempDir(), "config.json"),
		allowed:    netip.MustParsePrefix("192.168.0.0/24"), device: screen,
		now: func() time.Time { return now },
	}
	call := func(method, path, token, body string, expected int) *httptest.ResponseRecorder {
		t.Helper()
		request := httptest.NewRequest(method, path, strings.NewReader(body))
		request.RemoteAddr = "192.168.0.2:55433"
		request.Header.Set("Authorization", "Bearer "+token)
		recorder := httptest.NewRecorder()
		bridge.ServeHTTP(recorder, request)
		if recorder.Code != expected {
			t.Fatalf("%s %s: got %d, want %d: %s", method, path, recorder.Code, expected, recorder.Body.String())
		}
		return recorder
	}
	enrollment := `{"key":"` + key + `"}`
	call("GET", "/v1/frame", "", "", 401)
	call("POST", "/v1/session", key, "", 401)
	call("POST", "/v1/enroll", ticket, enrollment, 204)
	call("POST", "/v1/enroll", ticket, enrollment, 401)
	response := call("POST", "/v1/session", key, "", 200)
	var lease struct{ Session string }
	if err := json.Unmarshal(response.Body.Bytes(), &lease); err != nil || !validToken(lease.Session) {
		t.Fatal("missing or invalid session credential")
	}
	call("GET", "/v1/frame", key, "", 401)
	call("POST", "/v1/action", lease.Session, `{"kind":"shell"}`, 400)
	frame := call("GET", "/v1/frame", lease.Session, "", 200)
	if screen.takes != 1 || frame.Header().Get("Content-Type") != "image/png" {
		t.Fatal("expected exactly one authenticated PNG")
	}
	touch := `{"kind":"tap","start":{"x":0.5,"y":1},"revision":1}`
	call("POST", "/v1/action", lease.Session, touch, 204)
	if !reflect.DeepEqual(screen.inputs, [][]string{{"tap", "239", "853"}}) {
		t.Fatalf("unexpected input: %v", screen.inputs)
	}
	now = now.Add(time.Second)
	screen.size = image.Rect(0, 0, 854, 480)
	call("GET", "/v1/frame", lease.Session, "", 200)
	call("POST", "/v1/action", lease.Session, touch, 409)
	call("POST", "/v1/action", lease.Session, `{"kind":"tap","start":{"x":-1,"y":0},"revision":2}`, 400)
	now = now.Add(leaseDuration)
	call("GET", "/v1/frame", lease.Session, "", 401)

	outside := httptest.NewRequest("POST", "/v1/session", nil)
	outside.RemoteAddr = "10.10.10.1:1000"
	outside.Header.Set("Authorization", "Bearer "+key)
	denied := httptest.NewRecorder()
	bridge.ServeHTTP(denied, outside)
	if denied.Code != 403 {
		t.Fatal("outside peer was not rejected")
	}
}
