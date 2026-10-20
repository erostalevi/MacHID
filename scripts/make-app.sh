#!/bin/bash
# Builds MacHID.app (a menu bar app: no Dock icon) from the Swift package.
#   OUT=/path scripts/make-app.sh          ad-hoc signed, for local use
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/make-app.sh
# Build products stay outside the repository folder (iCloud-synced folders break code signing).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/machid-app}"
BUILD_DIR="${BUILD_DIR:-/tmp/machid-build}"
CONFIG="${CONFIG:-release}"
IDENTITY="${SIGN_IDENTITY:--}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="$OUT/MacHID.app"

swift build -c "$CONFIG" --scratch-path "$BUILD_DIR" --product MacHIDApp --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --scratch-path "$BUILD_DIR" --package-path "$ROOT" --show-bin-path)/MacHIDApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacHID"
cp -R "$ROOT/Definitions" "$APP/Contents/Resources/Definitions"

# String catalog -> .lproj/Localizable.strings (English text is the key, so English needs no file).
xcrun xcstringstool compile "$ROOT/Resources/Localizable.xcstrings" --output-directory "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>MacHID</string>
  <key>CFBundleIdentifier</key><string>app.machid.MacHID</string>
  <key>CFBundleName</key><string>MacHID</string>
  <key>CFBundleDisplayName</key><string>MacHID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>MacHID is free software (GPLv3).</string>
</dict>
</plist>
PLIST

if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - --timestamp=none "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"
