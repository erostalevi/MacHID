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
# What people see (0.1.57) and what Sparkle compares (the build number, which only ever goes up).
APP_VERSION="${APP_VERSION:-${VERSION}.${BUILD_NUMBER}}"
APP="$OUT/MacHID.app"

swift build -c "$CONFIG" --scratch-path "$BUILD_DIR" --product MacHIDApp --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --scratch-path "$BUILD_DIR" --package-path "$ROOT" --show-bin-path)/MacHIDApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacHID"

# Sparkle (auto-update) is a dynamic framework: it travels inside the app.
SPARKLE="$(find "$BUILD_DIR/artifacts" -type d -name Sparkle.framework -path "*macos*" | head -1)"
[ -n "$SPARKLE" ] || { echo "Sparkle.framework not found; run swift build first" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MacHID" 2>/dev/null || true
cp -R "$ROOT/Definitions" "$APP/Contents/Resources/Definitions"

# String catalog -> .lproj/Localizable.strings (English text is the key, so English needs no file).
xcrun xcstringstool compile "$ROOT/Resources/Localizable.xcstrings" --output-directory "$APP/Contents/Resources"

# The plugin registry is trusted only with this key (see scripts/make-registry-key.sh). Without it plugin discovery stays off.
REGISTRY_KEY_PLIST=""
# Updates are installed only if signed with the project's EdDSA key (see docs/RELEASE.md). Without the key the app
# has updating switched off.
UPDATE_PLIST=""
if [ -n "${SPARKLE_PUBLIC_KEY:-}" ]; then
  UPDATE_PLIST="  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL:-https://github.com/erostalevi/MacHID/releases/latest/download/appcast.xml}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>"
fi
if [ -n "${REGISTRY_PUBLIC_KEY:-}" ]; then
  REGISTRY_KEY_PLIST="  <key>MacHIDRegistryPublicKey</key><string>${REGISTRY_PUBLIC_KEY}</string>"
fi

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
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>MacHID is free software (GPLv3).</string>
${REGISTRY_KEY_PLIST}
${UPDATE_PLIST}
</dict>
</plist>
PLIST

# Sign from the inside out: Sparkle's helpers, then the framework, then the app.
sign() {
  if [ "$IDENTITY" = "-" ]; then codesign --force --sign - --timestamp=none "$@"
  else codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; fi
}
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SP"/XPCServices/*.xpc "$SP/Autoupdate" "$SP/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  [ -e "$item" ] && sign "$item"
done
sign "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP"
