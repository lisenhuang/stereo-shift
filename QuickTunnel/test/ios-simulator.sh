#!/bin/bash
# Live verification uses a new simulator containing only the synthetic test gallery.
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch=$(mktemp -d)
device=$(xcrun simctl create "StereoShift Quick Tunnel test" "${2:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}" "${1:-com.apple.CoreSimulator.SimRuntime.iOS-27-2}")
cleanup() {
  xcrun simctl shutdown "$device" 2>/dev/null || true
  xcrun simctl delete "$device"
  rm -rf "$scratch"
}
trap cleanup EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
openssl pkcs12 -legacy -in StereoShift/Resources/WebShareIdentity.p12 -clcerts -nokeys \
  -passin pass:StereoShiftLocalWebShare | openssl x509 -out "$scratch/local.pem"
xcrun simctl keychain "$device" add-root-cert "$scratch/local.pem"
export TEST_RUNNER_STEREOSHIFT_LIVE_TUNNEL_TEST=1
# The bundled LAN certificate covers loopback. Pin its exact leaf in the UI test
# so the viewer can also exercise the numeric Wi-Fi address printed in the QR code.
TEST_RUNNER_STEREOSHIFT_LAN_CERT_SHA256=$(openssl x509 -in "$scratch/local.pem" -outform DER | shasum -a 256 | cut -d ' ' -f 1)
export TEST_RUNNER_STEREOSHIFT_LAN_CERT_SHA256
args=(-jobs 3 -project StereoShift.xcodeproj -destination "platform=iOS Simulator,id=$device" -parallel-testing-enabled NO
  -derivedDataPath "${STEREOSHIFT_DERIVED_DATA:-$scratch/build}" CODE_SIGNING_ALLOWED=NO)
xcodebuild "${args[@]}" -scheme StereoShiftTests test
xcodebuild "${args[@]}" -scheme StereoShiftUITests -only-testing:StereoShiftUITests/GalleryQuickTunnelUITests -resultBundlePath "$scratch/ui.xcresult" test
xcrun xcresulttool export attachments --path "$scratch/ui.xcresult" --output-path "$scratch/qr"
npm ci --prefix QuickTunnel/test --ignore-scripts --no-audit --no-fund
node QuickTunnel/test/verify-qr.mjs "$scratch/qr"
