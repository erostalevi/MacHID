#!/bin/bash
# Signs MacHID.app from the inside out (Sparkle's helpers, the framework, then the app).
#   scripts/sign-app.sh <app> [identity]     identity "-" (default) means ad hoc
# Kept separate from the build so that the step holding the signing certificate never runs build tooling.
set -euo pipefail
APP="${1:?usage: sign-app.sh <app> [identity]}"
IDENTITY="${2:--}"

sign() {
  if [ "$IDENTITY" = "-" ]; then codesign --force --sign - --timestamp=none "$@"
  else codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; fi
}
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SP"/XPCServices/*.xpc "$SP/Autoupdate" "$SP/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
  [ -e "$item" ] && sign "$item"
done
[ -e "$APP/Contents/MacOS/MacHIDPluginHost" ] && sign "$APP/Contents/MacOS/MacHIDPluginHost"
sign "$APP"
codesign --verify --strict --deep "$APP"
