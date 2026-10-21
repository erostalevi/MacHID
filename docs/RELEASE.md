# Releases

Every push to `master` that touches code runs `.github/workflows/release.yml`: it builds, tests and publishes a release (see below).

## Modelo de publicación (sin cuenta de pago de Apple)
Cada push a `master` que toque código construye, prueba y **publica siempre** un release de GitHub: `MacHID-<version>.dmg` (firma ad hoc, sin notarizar), `machid-<version>-macos-arm64.zip` y `SHA256SUMS`, más `appcast.xml` si existe el secreto de Sparkle. La versión es `VERSION` (`MAJOR.MINOR`) más el número de commits. No hace falta ningún secreto para publicar.

Primera instalación: Gatekeeper bloqueará la app (no está notarizada). El usuario hace clic derecho en `MacHID.app` > Abrir, o Ajustes del Sistema > Privacidad y seguridad > "Abrir igualmente". Las actualizaciones posteriores las instala Sparkle y no llevan cuarentena, así que Gatekeeper no vuelve a preguntar.

## Configuración única para que el autoupdate funcione
La clave pública de Sparkle está en `Resources/sparkle-public-key.txt` (no es secreto; `make-app.sh` la incrusta). Falta solo el secreto privado:
1. Secreto de repositorio `SPARKLE_ED_PRIVATE_KEY` (Settings > Secrets and variables > Actions) con el contenido de la clave privada (`generate_keys -x archivo`).
2. Haz copia privada de esa clave y borra el archivo exportado. Si se pierde, las instalaciones existentes no podrán actualizarse con otra clave.
Sin el secreto el release se publica igual pero sin `appcast.xml`: las apps instaladas no verán la actualización (el workflow avisa con un warning).

Opcional: variable `REGISTRY_PUBLIC_KEY` y secreto `REGISTRY_SIGNING_KEY_PEM` para el registro de plugins (ver `scripts/make-registry-key.sh`).

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
