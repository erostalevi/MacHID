#!/usr/bin/env python3
"""Check that every plugins.json entry points at a real commit and that manifest_sha256
matches the manifest.json at that commit. Standard library only. Run with `python3 -I`."""
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

TOKEN = os.environ.get("GITHUB_TOKEN")


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "machid-registry-check"})
    if TOKEN and url.startswith("https://api.github.com/"):
        request.add_header("Authorization", f"Bearer {TOKEN}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def main(path: str) -> int:
    with open(path, encoding="utf-8") as handle:
        registry = json.load(handle)
    failures = 0
    for entry in registry.get("plugins", []):
        owner_repo = entry["repo"].removeprefix("https://github.com/").removesuffix(".git")
        try:
            commit = json.loads(fetch(f"https://api.github.com/repos/{owner_repo}/commits/{entry['ref']}"))
            if commit.get("sha") != entry["ref"]:
                raise ValueError("ref did not resolve to the same full commit SHA")
            manifest = fetch(f"https://raw.githubusercontent.com/{owner_repo}/{entry['ref']}/manifest.json")
            digest = hashlib.sha256(manifest).hexdigest()
            if digest != entry["manifest_sha256"]:
                raise ValueError(f"manifest hash mismatch (got {digest})")
        except (urllib.error.URLError, ValueError, KeyError) as error:
            print(f"{entry.get('id', '?')}: {error}")
            failures += 1
    print("OK" if failures == 0 else f"{failures} plugin(s) failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "plugins.json"))
