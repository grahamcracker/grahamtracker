#!/bin/bash
# Builds a release binary and wraps it in build/GrahamTracker.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/GrahamTracker"
APP="build/GrahamTracker.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GrahamTracker"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"
