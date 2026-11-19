#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export MACOSX_DEPLOYMENT_TARGET=13.0
app="dist/副屏监视器.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -O -parse-as-library Sources/*.swift -o "$app/Contents/MacOS/DisplayMonitor"
cp Resources/Info.plist "$app/Contents/"
if [[ Resources/Gauge.svg -nt Resources/AppIcon.icns || Scripts/build-icon.swift -nt Resources/AppIcon.icns || ! -s Resources/AppIcon.icns ]]; then
    xcrun swift Scripts/build-icon.swift Resources/Gauge.svg Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns Resources/Gauge.svg Resources/Dashboard.html Resources/dashboard.js "$app/Contents/Resources/"
codesign --force --sign - "$app"
