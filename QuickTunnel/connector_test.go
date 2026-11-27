package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/cloudflare/cloudflared/tracing"
)

type recorder struct{ *httptest.ResponseRecorder }

func (w recorder) WriteRespHeaders(status int, _ http.Header) error {
	w.WriteHeader(status)
	return nil
}
func (w recorder) AddTrailer(string, string) {}
func (w recorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return nil, nil, errors.New("HTTP only")
}

func TestGalleryProxy(t *testing.T) {
	tests := []struct {
		name, method, path, origin, body, wantPath string
		status                                     int
	}{
		{"media with range", "GET", "/media/test.mp4?code=1234", "", "", "/media/test.mp4", 206},
		{"head", "HEAD", "/media/test.mp4", "", "", "/media/test.mp4", 206},
		{"page", "GET", "/?code=1234", "", "", "/", 206},
		{"pagination", "GET", "/api/items?limit=4&code=0000", "", "", "/api/items?limit=4", 206},
		{"rebuild thumbnail", "GET", "/thumb/photo.jpg?rebuild=1&code=0000", "", "", "/thumb/photo.jpg?rebuild=1", 206},
		{"form", "POST", "/session-auth?pin=2468", "https://four-test-words-here.trycloudflare.com", "pin=1234", "/session-auth?pin=1234", 206},
		{"foreign origin", "POST", "/session-auth", "https://example.org", "pin=1234", "", 403},
		{"get form", "GET", "/session-auth?pin=1234", "", "", "", 405},
		{"other route", "GET", "/other", "", "", "", 404},
		{"oversize form", "POST", "/session-auth", "", strings.Repeat("1", 65), "", 400},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var got string
			origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				got = r.URL.RequestURI()
				if r.Header.Get("Range") != "bytes=8-9" || r.Header.Get("X-StereoShift-Origin") != "local-secret" || r.Header.Get("Cookie") != "test=ok" {
					t.Error("incorrect origin headers")
				}
				w.Header().Set("Content-Range", "bytes 8-9/10")
				w.WriteHeader(206)
				io.WriteString(w, "89")
			}))
			defer origin.Close()
			g := &gallery{origin: origin.Listener.Addr().String(), host: "four-test-words-here.trycloudflare.com", key: "local-secret", slots: make(chan struct{}, 8), transport: &http.Transport{}}
			defer g.transport.CloseIdleConnections()
			req := httptest.NewRequest(tc.method, tc.path, bytes.NewBufferString(tc.body))
			req.Header.Set("Range", "bytes=8-9")
			req.Header.Set("Cookie", "test=ok")
			req.Header.Set("X-StereoShift-Origin", "ignore")
			req.Header.Set("Origin", tc.origin)
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			w := recorder{httptest.NewRecorder()}
			if err := g.ProxyHTTP(w, tracing.NewTracedHTTPRequest(req, 0, &log), false); err != nil {
				t.Fatal(err)
			}
			if w.Code != tc.status || got != tc.wantPath {
				t.Errorf("got HTTP %d and origin path %q", w.Code, got)
			}
			if tc.method == "HEAD" && w.Body.Len() != 0 {
				t.Error("unexpected body")
			}
			if w.Header().Get("Cloudflare-CDN-Cache-Control") != "no-store" {
				t.Error("missing CDN cache policy")
			}
		})
	}
}

func TestCancelledShareDoesNotRegister(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := serve(ctx, 1, "unused", func(string) { t.Error("cancelled share became ready") }); err == nil {
		t.Fatal("missing cancellation error")
	}
}

// This opt-in check publishes only the fixture response generated in this function.
func TestLiveRegistration(t *testing.T) {
	if os.Getenv("STEREOSHIFT_LIVE_TUNNEL_TEST") != "1" {
		t.Skip("requires Cloudflare Quick Tunnels")
	}
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-StereoShift-Origin") != "fixture" {
			w.WriteHeader(403)
			return
		}
		io.WriteString(w, "StereoShift synthetic gallery")
	}))
	defer origin.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 140*time.Second)
	defer cancel()
	link := make(chan string, 1)
	ended := make(chan error, 1)
	go func() {
		ended <- serve(ctx, origin.Listener.Addr().(*net.TCPAddr).Port, "fixture", func(s string) { link <- s })
	}()
	select {
	case err := <-ended:
		t.Fatalf("connector ended before registration: %v", err)
	case <-ctx.Done():
		t.Fatal("registration timed out")
	case u := <-link:
		t.Log("Cloudflare registered the connector and published the hostname")
		lastStatus := 0
		var lastError error
		client := &http.Client{Timeout: 5 * time.Second}
		for ctx.Err() == nil {
			response, err := client.Get(u)
			lastError = err

			if err == nil {
				lastStatus = response.StatusCode
				data, _ := io.ReadAll(io.LimitReader(response.Body, 512))
				response.Body.Close()

				if response.StatusCode == 200 && string(data) == "StereoShift synthetic gallery" {
					break
				}
			}
			time.Sleep(time.Second)
		}
		if ctx.Err() != nil {
			t.Fatalf("gallery never reached via Cloudflare, last status %d, error %v", lastStatus, lastError)
		}
	}
	cancel()
	select {
	case <-ended:
	case <-time.After(5 * time.Second):
		t.Fatal("connector did not stop")
	}
}
