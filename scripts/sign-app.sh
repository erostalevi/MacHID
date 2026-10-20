#!/bin/bash
# Signs MacHID.app from the inside out (Sparkle's helpers, the framework, then the app).
#   scripts/sign-app.sh <app> [identity]     identity "-" (default) means ad hoc
# Kept separate from the build so that the step holding the signing certificate never runs build tooling.
set -euo pipefail
APP="${1:?usage: sign-app.sh <app> [identity]}"
IDENTITY="${2:--}"

# The app needs the camera entitlement under the hardened runtime (live camera preview); the entitlements file
# is generated outside the repo folder.
ENT="$(mktemp /private/tmp/machid-entitlements.XXXXXX)"
trap 'rm -f "$ENT"' EXIT
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
PLIST

sign() {
  if [ "$IDENTITY" = "-" ]; then codesign --force --sign - --timestamp=none "$@"
  elif security find-identity -v -p codesigning | grep -F "$IDENTITY" | grep -q "Developer ID Application"; then
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"
  elif [[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] || [[ "$IDENTITY" == Apple\ Development* ]]; then
    # Development certificates cannot be notarized; no secure timestamp needed, keeps builds offline-capable.
    codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$@"
  else codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; fi
}
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SP"/XPCServices/*.xpc "$SP/Autoupdate" "$SP/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  [ -e "$item" ] && sign "$item"
done
[ -e "$APP/Contents/MacOS/MacHIDPluginHost" ] && sign "$APP/Contents/MacOS/MacHIDPluginHost"
sign --entitlements "$ENT" "$APP"
codesign --verify --strict --deep "$APP"
