# Embedded Quick Tunnel

StereoShift links Cloudflare's open-source cloudflared HTTP/2 connector as a static iOS library. Starting a share requests an anonymous, temporary hostname from Cloudflare and opens an outbound TLS connection on TCP port 7844. The app displays the HTTPS URL after registration and DNS publication. Cloudflare operates the Quick Tunnel service and describes it as a development and testing service with no uptime guarantee.

The connector can reach only the current gallery listener on the phone's loopback interface. Each attempt uses a fresh private header to authenticate requests to that listener. The Swift gallery router checks the PIN, serves photos and supports HTTP byte ranges for video. Public PIN submissions use HTTPS POST. The connector allows eight concurrent HTTP requests and streams responses with backpressure. Media responses instruct browsers and Cloudflare to disable caching. Stopping or replacing a session closes the connector and the private listener. Switching apps leaves the session open. If iOS suspends the process, requests may stall and the tunnel may disconnect. After returning to the app, Retry public link creates a new URL if needed. LAN and hotspot listeners have an independent lifetime.

## Build

Install Xcode and Go with automatic toolchain selection enabled. Open StereoShift.xcodeproj and build the StereoShift scheme. Xcode runs build.sh for the target architecture. The Go module pins cloudflared 2026.11.1 and the required Go toolchain version. Building for the first time requires network access to fetch the dependencies. All connector code ships in the signed app. End users only need StereoShift. There is no server deployment or account setup.

## Test

From this directory run `go test ./...` for the origin forwarding and cancellation tests. Run `STEREOSHIFT_LIVE_TUNNEL_TEST=1 go test -count=1 ./...` to additionally publish and retrieve a short synthetic response using the real Quick Tunnel service.

On a Mac with an iOS simulator runtime, OpenSSL 3, Node.js and npm, run `./test/ios-simulator.sh` for the app and browser checks. The runner creates a disposable simulator, trusts the LAN test certificate there and starts temporary Quick Tunnels from the simulator app, using the real Cloudflare edge and public DNS. It exercises the actual gallery PIN, photo download, MP4 seeking, tunnel teardown and QR codes. It removes the simulator on exit. An optional first argument selects a simulator runtime identifier, and the second selects a device type.

[Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/) · [cloudflared source](https://github.com/cloudflare/cloudflared/tree/2026.11.1)
