#!/bin/zsh
# Builds MacHID.app, quits any running copy, installs it in /Applications and launches it.
set -e
cd "${0:A:h}/.."
OUT=/private/tmp/machid-app BUILD_DIR=/private/tmp/machid-appbuild scripts/make-app.sh
pkill -x MacHID || true
sleep 1
rm -rf /Applications/MacHID.app
ditto /private/tmp/machid-app/MacHID.app /Applications/MacHID.app
xattr -cr /Applications/MacHID.app
open /Applications/MacHID.app
