#!/bin/bash
# Builds FloatPin.app with just the Xcode command line tools (no Xcode project needed).
#   ./build.sh            build into ./build/FloatPin.app
#   ./build.sh install    build, copy to /Applications, and launch
#   ./build.sh dmg        build and package FloatPin.dmg (drag-to-Applications installer)
#
# Tip: set SIGN_IDENTITY to your "Apple Development: ..." certificate name so macOS
# keeps your permissions between rebuilds. Without it the app is ad-hoc signed and
# you'll need to re-grant permissions after each rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FloatPin.app"
ARCH="$(uname -m)"
IDENTITY="${SIGN_IDENTITY:--}"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

echo "Compiling for $ARCH..."
swiftc -O \
  -target "$ARCH-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework ScreenCaptureKit \
  -framework Carbon -framework ServiceManagement \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/FloatPin"

echo "Signing ($IDENTITY)..."
codesign --force --sign "$IDENTITY" "$APP"

echo "Built $APP"

if [[ "${1:-}" == "dmg" ]]; then
  echo "Making FloatPin.dmg..."
  STAGE="build/dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"   # drag-to-install shortcut
  rm -f FloatPin.dmg
  hdiutil create -volname "FloatPin" -srcfolder "$STAGE" -ov -format UDZO FloatPin.dmg
  echo "Made $(pwd)/FloatPin.dmg"
fi

if [[ "${1:-}" == "install" ]]; then
  pkill -x FloatPin 2>/dev/null || true
  rm -rf /Applications/FloatPin.app
  cp -R "$APP" /Applications/
  open /Applications/FloatPin.app
  echo "Installed to /Applications and launched."
fi
