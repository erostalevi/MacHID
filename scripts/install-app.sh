#!/bin/zsh
# Builds MacHID.app, quits any running copy, installs it in /Applications and launches it.
set -e
cd "${0:A:h}/.."
# macOS ties privacy grants (Input Monitoring, Accessibility, Camera) to the code signature. An ad-hoc signature
# changes on every build, so every install would lose them. Sign with a stable identity instead: SIGN_IDENTITY,
# else the first valid (non-revoked) Apple Development / Developer ID certificate in the keychain.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep -v CSSMERR | grep -E 'Developer ID Application|Apple Development' | head -1 | awk '{print $2}')"
fi
[ -n "$SIGN_IDENTITY" ] || echo "warning: no signing identity found; ad-hoc signing will reset privacy permissions on every install" >&2
export SIGN_IDENTITY
OUT=/private/tmp/machid-app BUILD_DIR=/private/tmp/machid-appbuild scripts/make-app.sh
pkill -x MacHID || true
sleep 1
rm -rf /Applications/MacHID.app
ditto /private/tmp/machid-app/MacHID.app /Applications/MacHID.app
xattr -cr /Applications/MacHID.app
open /Applications/MacHID.app
