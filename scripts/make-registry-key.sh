#!/bin/bash
# Creates the Ed25519 key pair that signs the plugin registry.
#   scripts/make-registry-key.sh [output-dir]
# Needs OpenSSL 3 (macOS: brew install openssl). Prints what to configure on GitHub; keeps nothing but the key files.
set -euo pipefail

OPENSSL="$(command -v /opt/homebrew/bin/openssl || command -v openssl)"
if ! "$OPENSSL" genpkey -algorithm ed25519 -out /dev/null 2>/dev/null; then
  echo "This OpenSSL cannot make Ed25519 keys. Install OpenSSL 3 (brew install openssl)." >&2
  exit 1
fi

OUT="${1:-./registry-key}"
mkdir -p "$OUT"
umask 077
"$OPENSSL" genpkey -algorithm ed25519 -out "$OUT/registry-signing-key.pem"
PUBLIC="$("$OPENSSL" pkey -in "$OUT/registry-signing-key.pem" -pubout -outform DER | tail -c 32 | base64)"
echo "$PUBLIC" > "$OUT/registry-public-key.txt"

cat <<TXT

Done. Two things to configure on GitHub (Settings):

1. Secret REGISTRY_SIGNING_KEY_PEM in the 'release' environment: the full contents of
     $OUT/registry-signing-key.pem
   Keep a private backup of this file, then delete it from this machine. Anyone holding it can sign a registry.

2. Repository variable REGISTRY_PUBLIC_KEY (not a secret):
     $PUBLIC
   Release builds put it into the app, which then trusts registries signed with the key above.
TXT
