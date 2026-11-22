#!/bin/bash
# Xcode builds the static connector for exactly the same SDK and architectures as the app.
set -euo pipefail
cd "$SRCROOT/QuickTunnel"
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"
command -v go >/dev/null || { echo "error: Install Go to build the embedded Web Share connector."; exit 1; }
export CGO_ENABLED=1 GOOS=ios GOTOOLCHAIN=auto
export CC="$(xcrun --sdk "$PLATFORM_NAME" --find clang)"
sdk=$(xcrun --sdk "$PLATFORM_NAME" --show-sdk-path)
out="$DERIVED_FILE_DIR/QuickTunnel"
mkdir -p "$out"
archives=()
for arch in $ARCHS; do
  case "$arch" in
    arm64) export GOARCH=arm64 ;;
    x86_64) export GOARCH=amd64 ;;
    *) echo "error: Unsupported iOS architecture $arch"; exit 1 ;;
  esac
  target="$arch-apple-ios$IPHONEOS_DEPLOYMENT_TARGET"
  if [[ "$PLATFORM_NAME" == iphonesimulator ]]; then target="$target-simulator"; fi
  export CGO_CFLAGS="-target $target -isysroot $sdk"
  export CGO_LDFLAGS="$CGO_CFLAGS"
  archive="$out/$arch.a"
  go build -p 3 -mod=readonly -trimpath -buildmode=c-archive -ldflags="-s -w" -o "$archive" .
  archives+=("$archive")
done
xcrun lipo -create "${archives[@]}" -output "$out/libStereoTunnel.a"

notices="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/QuickTunnelNotices.txt"
go list -mod=readonly -deps -f '{{if .Module}}{{if not .Module.Main}}{{.Module.Path}}{{"\t"}}{{.Module.Dir}}{{end}}{{end}}' . \
  | sort -u | python3 notices.py "$(go env GOROOT)" "$notices"
