#!/bin/bash
# Fills the Homebrew cask template: scripts/update-cask.sh <version> <sha256> [output]
# The default output is packaging/homebrew/out/machid.rb (copy it to Casks/machid.rb in the tap repository).
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <version> <sha256> [output-file]" >&2
  exit 2
fi
version="$1"
sha="$2"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${3:-$root/packaging/homebrew/out/machid.rb}"

if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "version must look like 1.2 or 1.2.3 (no leading v)" >&2
  exit 2
fi
if ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
  echo "sha256 must be 64 lowercase hex characters" >&2
  exit 2
fi

mkdir -p "$(dirname "$out")"
sed -e "s/__VERSION__/$version/" -e "s/__SHA256__/$sha/" "$root/packaging/homebrew/machid.rb" > "$out"
echo "wrote $out"
