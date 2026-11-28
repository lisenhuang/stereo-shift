// The iOS app embeds the upstream cloudflared HTTP/2 transport. Its only origin is
// the ephemeral loopback gallery listener opened by this share session.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/cloudflare/cloudflared/client"
	"github.com/cloudflare/cloudflared/connection"
	"github.com/cloudflare/cloudflared/features"
	"github.com/cloudflare/cloudflared/tlsconfig"
	"github.com/cloudflare/cloudflared/tracing"
	"github.com/cloudflare/cloudflared/tunnelrpc/pogs"
	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

const connectorVersion = "2026.11.1"

var errProvision = errors.New("requesting a Quick Tunnel")
var errEdge = errors.New("connecting to the Cloudflare edge")
var errPublicDNS = errors.New("publishing the public hostname")
var quickHost = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*\.trycloudflare\.com$`)
var log = zerolog.Nop()
var observer = sync.OnceValue(func() *connection.Observer { return connection.NewObserver(&log) })

type ticket struct {
	ID      uuid.UUID `json:"id"`
	Account string    `json:"account_tag"`
	Secret  []byte    `json:"secret"`
	Host    string    `json:"hostname"`
}

func provision(ctx context.Context) (ticket, error) {
	var result struct {
		Success bool
		Result  ticket
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.trycloudflare.com/tunnel", nil)
	if err != nil {
		return ticket{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "StereoShift (cloudflared/"+connectorVersion+")")
	c := &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := c.Do(req)
	if err != nil {
		return ticket{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ticket{}, fmt.Errorf("provisioning HTTP %d", resp.StatusCode)
	}
	if err = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&result); err != nil {
		return ticket{}, err
	}
	t := result.Result
	if !result.Success || t.ID == uuid.Nil || t.Account == "" || len(t.Secret) == 0 || !quickHost.MatchString(t.Host) || len(strings.Split(t.Host, ".")[0]) > 63 {
		return ticket{}, errors.New("invalid Quick Tunnel ticket")
	}
	return t, nil
}

type gallery struct {
	origin    string
	key       string
	host      string
	slots     chan struct{}
	transport *http.Transport
}

func (g *gallery) GetOriginProxy() (connection.OriginProxy, error) { return g, nil }
func (g *gallery) GetConfigJSON() ([]byte, error) {
	return json.Marshal(map[string]any{"ingress": []map[string]string{{"service": "http://" + g.origin}}})
}
func (g *gallery) UpdateConfig(int32, []byte) *pogs.UpdateConfigurationResponse {
	return &pogs.UpdateConfigurationResponse{Err: errors.New("fixed gallery origin")}
}
func (g *gallery) ProxyTCP(context.Context, connection.ReadWriteAcker, *connection.TCPRequest) error {
	return errors.New("HTTP gallery only")
}

func (g *gallery) ProxyHTTP(w connection.ResponseWriter, tr *tracing.TracedHTTPRequest, websocket bool) error {
	h := w.Header()
	h.Set("Cache-Control", "private, no-store")
	h.Set("Cloudflare-CDN-Cache-Control", "no-store")
	if websocket {
		w.WriteHeader(405)
		return nil
	}
	select {
	case g.slots <- struct{}{}:
		defer func() { <-g.slots }()
	default:
		w.WriteHeader(429)
		return nil
	}
	r := tr.Request
	target := url.URL{Scheme: "http", Host: g.origin, Path: r.URL.Path, RawPath: r.URL.RawPath}
	method := r.Method
	switch r.URL.Path {
	case "/session-auth":
		if method != "POST" {
			w.WriteHeader(405)
			return nil
		}
		if origin := r.Header.Get("Origin"); origin != "" && origin != "https://"+g.host {
			w.WriteHeader(403)
			return nil
		}
		if strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/x-www-form-urlencoded" {
			w.WriteHeader(415)
			return nil
		}
		data, err := io.ReadAll(io.LimitReader(r.Body, 65))
		if err != nil || len(data) > 64 {
			w.WriteHeader(400)
			return nil
		}
		form, err := url.ParseQuery(string(data))
		if err != nil || len(form) != 1 || len(form["pin"]) != 1 {
			w.WriteHeader(400)
			return nil
		}
		target.RawQuery = url.Values{"pin": {form.Get("pin")}}.Encode()
		method = http.MethodGet
	default:
		if method != "GET" && method != "HEAD" {
			w.WriteHeader(405)
			return nil
		}
		p := r.URL.Path
		if p != "/" && p != "/api/items" && !strings.HasPrefix(p, "/media/") && !strings.HasPrefix(p, "/thumb/") && !strings.HasPrefix(p, "/live/") {
			w.WriteHeader(404)
			return nil
		}
		if p == "/api/items" {
			params := url.Values{}
			for _, name := range []string{"offset", "limit"} {
				if v := r.URL.Query().Get(name); v != "" {
					params.Set(name, v)
				}
			}
			target.RawQuery = params.Encode()
		} else if strings.HasPrefix(p, "/thumb/") && r.URL.Query().Get("rebuild") == "1" {
			target.RawQuery = "rebuild=1"
		}
	}
	req, err := http.NewRequestWithContext(r.Context(), method, target.String(), nil)
	if err != nil {
		return err
	}
	for _, name := range []string{"Range", "Cookie"} {
		if value := r.Header.Get(name); value != "" {
			req.Header.Set(name, value)
		}
	}
	req.Header.Set("X-StereoShift-Origin", g.key)
	resp, err := g.transport.RoundTrip(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	for _, name := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Set-Cookie", "Location"} {
		for _, value := range resp.Header.Values(name) {
			h.Add(name, value)
		}
	}
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "same-origin")
	h.Set("X-Frame-Options", "DENY")
	if err = w.WriteRespHeaders(resp.StatusCode, h); err != nil {
		return err
	}
	if method == http.MethodHead {
		return nil
	}
	_, err = io.Copy(w, resp.Body)
	return err
}

type staticFeatures struct{}

func (staticFeatures) Snapshot() features.FeatureSnapshot {
	return features.FeatureSnapshot{FeaturesList: []string{"serialized_headers"}}
}

type connectedSignal struct {
	ch   chan struct{}
	once sync.Once
}

func (s *connectedSignal) Connected() { s.once.Do(func() { close(s.ch) }) }
func (s *connectedSignal) IsConnected() bool {
	select {
	case <-s.ch:
		return true
	default:
		return false
	}
}

// A newly registered tunnel can precede its DNS record. Checking Cloudflare's
// resolver first avoids seeding the viewer device's negative DNS cache.
func waitForPublicDNS(ctx context.Context, host string) bool {
	lookupCtx, cancel := context.WithTimeout(ctx, 95*time.Second)
	defer cancel()
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	c := &http.Client{Timeout: 5 * time.Second}
	for {
		select {
		case <-lookupCtx.Done():
			return false
		case <-timer.C:
		}
		req, err := http.NewRequestWithContext(lookupCtx, http.MethodGet, "https://cloudflare-dns.com/dns-query?type=A&name="+url.QueryEscape(host), nil)
		if err != nil {
			return false
		}
		req.Header.Set("Accept", "application/dns-json")
		resp, err := c.Do(req)
		if err == nil {
			var answer struct {
				Status int
				Answer []struct {
					Type int
					Data string
				}
			}
			valid := resp.StatusCode == 200 && json.NewDecoder(io.LimitReader(resp.Body, 16<<10)).Decode(&answer) == nil
			resp.Body.Close()
			if valid {
				for _, v := range answer.Answer {
					if answer.Status == 0 && v.Type == 1 && net.ParseIP(v.Data) != nil {
						return true
					}
				}
				if answer.Status == 0 || answer.Status == 3 {
					timer.Reset(4 * time.Second)
					continue
				}
			}
		}
		// The phone's resolver may already have the record or use a network
		// where the public DNS-over-HTTPS service is filtered.
		if ips, err := net.DefaultResolver.LookupHost(lookupCtx, host); err == nil && len(ips) > 0 {
			return true
		}
		timer.Reset(4 * time.Second)
	}
}

func serve(ctx context.Context, port int, key string, ready func(string)) error {
	t, err := provision(ctx)
	if err != nil {
		return errors.Join(errProvision, err)
	}
	tlsConf, err := edgeTLS()
	if err != nil {
		return err
	}
	dialer := tls.Dialer{Config: tlsConf, NetDialer: &net.Dialer{Timeout: 7 * time.Second, KeepAlive: 15 * time.Second}}
	var edge net.Conn
	for _, region := range []string{"region1.v2.argotunnel.com:7844", "region2.v2.argotunnel.com:7844"} {
		edge, err = dialer.DialContext(ctx, "tcp", region)
		if err == nil {
			break
		}
	}
	if err != nil {
		return errors.Join(errEdge, err)
	}
	defer edge.Close()
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	stopClose := context.AfterFunc(ctx, func() { edge.Close() })
	defer stopClose()
	g := &gallery{origin: fmt.Sprintf("127.0.0.1:%d", port), key: key, host: t.Host, slots: make(chan struct{}, 8),
		transport: &http.Transport{DisableCompression: true, DisableKeepAlives: true, ResponseHeaderTimeout: 20 * time.Second}}
	defer g.transport.CloseIdleConnections()
	clientConfig, err := client.NewConfig(connectorVersion, runtime.GOOS+"_"+runtime.GOARCH, staticFeatures{})
	if err != nil {
		return err
	}
	props := &connection.TunnelProperties{QuickTunnelUrl: t.Host, Credentials: connection.Credentials{AccountTag: t.Account, TunnelSecret: t.Secret, TunnelID: t.ID}}
	signal := &connectedSignal{ch: make(chan struct{})}
	control := connection.NewControlStream(observer(), signal, props, 0, edge.RemoteAddr().(*net.TCPAddr).IP, nil, 15*time.Second, ctx.Done(), time.Second, connection.HTTP2)
	conn := connection.NewHTTP2Connection(edge, g, clientConfig.ConnectionOptionsSnapshot(edge.LocalAddr().(*net.TCPAddr).IP, 0), observer(), 0, control, &log)
	go func() {
		timer := time.NewTimer(25 * time.Second)
		defer timer.Stop()
		select {
		case <-signal.ch:
			if waitForPublicDNS(ctx, t.Host) {
				ready("https://" + t.Host)
			} else {
				cancel(errPublicDNS)
			}
		case <-ctx.Done():
		case <-timer.C:
			cancel(errEdge)
		}
	}()
	err = conn.Serve(ctx)
	if cause := context.Cause(ctx); cause != nil {
		return cause
	}
	return err
}

func edgeTLS() (*tls.Config, error) {
	roots, err := x509.SystemCertPool()
	if err != nil {
		return nil, err
	}
	cfRoots, err := tlsconfig.GetCloudflareRootCA()
	if err != nil {
		return nil, err
	}
	for _, root := range cfRoots {
		roots.AddCert(root)
	}
	return &tls.Config{ServerName: connection.HTTP2.TLSSettings().ServerName, RootCAs: roots, MinVersion: tls.VersionTLS12}, nil
}
