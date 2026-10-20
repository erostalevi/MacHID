# Releases

Every push to `master` that touches code runs `.github/workflows/release.yml`: it builds and tests on a macOS runner. **A release is published only when the signing secrets exist.** Without them the run still builds and tests, finishes green, and prints a notice.

## Secrets (repository → Settings → Environments → `release`)
| Secret | What |
|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | Developer ID Application certificate with its private key, exported as .p12 and base64-encoded |
| `DEVELOPER_ID_CERT_PASSWORD` | Password of that .p12 |
| `DEVELOPER_ID_IDENTITY` | Certificate name, e.g. `Developer ID Application: Name (TEAMID)` |
| `NOTARY_API_KEY_P8_BASE64` | App Store Connect API key (.p8), base64-encoded |
| `NOTARY_API_KEY_ID` / `NOTARY_API_ISSUER_ID` | The key's id and issuer id |
| `REGISTRY_SIGNING_KEY_PEM` | Ed25519 private key that signs `plugins.json` (registry workflow); create with `scripts/make-registry-key.sh` |
| `SPARKLE_ED_PRIVATE_KEY` | EdDSA private key that signs app updates (see below) |

Repository **variables** (not secrets): `REGISTRY_PUBLIC_KEY` (printed by `make-registry-key.sh`) and `SPARKLE_PUBLIC_KEY`.

Protect the `release` environment (required reviewers, restricted to `master`). Forks never receive these secrets.

## What a release contains
`MacHID-<version>.dmg` (signed, notarized, stapled), `machid-<version>-macos-arm64.zip` (signed, notarized) and `SHA256SUMS`. The version is `VERSION` (`MAJOR.MINOR`) plus the commit count.

## Building the app locally
```
scripts/make-app.sh                      # ad hoc signed, written to /tmp/machid-app/MacHID.app
SIGN_IDENTITY="Developer ID Application: …" scripts/make-app.sh
```
The Liquid Glass look needs the macOS 26 SDK (Xcode 26 or newer). Older toolchains build the same UI with system materials. The release job selects the newest Xcode installed on the runner.

## Keys
Back up the Developer ID certificate and the registry signing key outside GitHub. Losing the registry key means re-signing the index with a new key shipped in an app update.

## Auto-update of the app
MacHID updates itself with [Sparkle](https://sparkle-project.org). Each release publishes `appcast.xml` next to the DMG; the app reads `https://github.com/erostalevi/MacHID/releases/latest/download/appcast.xml` and installs an update only if its EdDSA signature matches the key built into the app. Registry releases are marked "not latest", so "latest" always means the newest app release.

One-time setup:
1. Build the tools once: `swift package --scratch-path /tmp/machid-build resolve`, then run `/tmp/machid-build/artifacts/sparkle/Sparkle/bin/generate_keys`. It stores the private key in your login keychain and prints the public key.
2. Set the repository variable `SPARKLE_PUBLIC_KEY` to that public key.
3. Export the private key with `generate_keys -x sparkle-private-key`, store its contents as the secret `SPARKLE_ED_PRIVATE_KEY` in the `release` environment, keep a private backup, and delete the exported file.

Losing the private key means existing installs can never be updated by a new key: they would have to download a release by hand. A build made without `SPARKLE_PUBLIC_KEY` (such as a local one) has updating switched off.
