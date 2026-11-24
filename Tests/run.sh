#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
app="$temp/Smoke.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Gauge.svg Resources/Dashboard.html Resources/dashboard.js "$app/Contents/Resources/"
sed -e 's/local.dingkun.MacintoshMonitor/local.dingkun.MacintoshMonitor.smoke/' -e 's/DisplayMonitor/Smoke/g' Resources/Info.plist > "$app/Contents/Info.plist"
xcrun swiftc -swift-version 5 -parse-as-library Sources/{Display,LoginItem,MenuBarIcon,Metrics,Monitor,Quota}.swift Tests/Smoke.swift -o "$app/Contents/MacOS/Smoke"
codesign --force --sign - "$app"
# Run with the environment Finder gives an app, so CLI discovery is tested as users get it.
env -i HOME="$HOME" USER="$USER" SHELL="${SHELL:-/bin/zsh}" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    ${MONITOR_TEST_SNAPSHOT:+MONITOR_TEST_SNAPSHOT="$MONITOR_TEST_SNAPSHOT"} "$app/Contents/MacOS/Smoke" "$@"
