#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET=13.0
app="dist/副屏监视器.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
binary="$app/Contents/MacOS/DisplayMonitor"
flags=(-swift-version 5 -O -parse-as-library)
case "${1:-}" in
    --universal)
        slices="$(mktemp -d)"
        trap 'rm -rf "$slices"' EXIT
        for arch in arm64 x86_64; do
            xcrun swiftc "${flags[@]}" -target "$arch-apple-macos$MACOSX_DEPLOYMENT_TARGET" Sources/*.swift -o "$slices/$arch"
        done
        xcrun lipo -create "$slices/arm64" "$slices/x86_64" -output "$binary"
        ;;
    "") xcrun swiftc "${flags[@]}" Sources/*.swift -o "$binary" ;;
    *) echo "Usage: $0 [--universal]" >&2; exit 2 ;;
esac
cp Resources/Info.plist "$app/Contents/"
if [[ Resources/Gauge.svg -nt Resources/AppIcon.icns || Scripts/build-icon.swift -nt Resources/AppIcon.icns || ! -s Resources/AppIcon.icns ]]; then
    xcrun swift Scripts/build-icon.swift Resources/Gauge.svg Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns Resources/Gauge.svg Resources/Dashboard.html Resources/dashboard.js LICENSE "$app/Contents/Resources/"
codesign --force --sign - "$app"
