#!/usr/bin/env bash
# Builds a release Islet.app in ./build
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ADAPTER="Vendor/MediaRemoteAdapter"
[ -d "$ADAPTER/MediaRemoteAdapter.framework" ] || ./Scripts/setup-adapter.sh

# Command Line Tools 27+ omits the SwiftUIMacros plugin that @State needs; fall back to the macOS 26 SDK.
if [ -z "${SDKROOT:-}" ]; then
    DEV_DIR="$(xcode-select -p)"
    SDK_MAJOR="$(xcrun --show-sdk-version | cut -d. -f1)"
    if [[ "$DEV_DIR" == *CommandLineTools* ]] && [ "$SDK_MAJOR" -ge 27 ] 2>/dev/null \
        && ! compgen -G "$DEV_DIR/usr/lib/swift/host/plugins/*SwiftUIMacros*" >/dev/null; then
        SDK26="$DEV_DIR/SDKs/MacOSX26.sdk"
        if [ -d "$SDK26" ]; then
            export SDKROOT="$SDK26"
        else
            echo "error: Command Line Tools $SDK_MAJOR+ is missing SwiftUIMacros and no macOS 26 SDK was found at $SDK26." >&2
            echo "Install full Xcode from the App Store and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
            exit 1
        fi
    fi
fi

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
