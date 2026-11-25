#!/usr/bin/env bash
# Builds a release Islet.app in ./build
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ADAPTER="Vendor/MediaRemoteAdapter"
[ -d "$ADAPTER/MediaRemoteAdapter.framework" ] || ./Scripts/setup-adapter.sh

swift build -c release
BIN="$(swift build -c release --show-bin-path)/NotchMusic"

APP="build/Islet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/NotchMusic"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ADAPTER/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp -R "$ADAPTER/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/"

# Ad-hoc sign: framework first, then the app
codesign --force --sign - "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Install: mv \"$APP\" /Applications/ && open /Applications/Islet.app"
