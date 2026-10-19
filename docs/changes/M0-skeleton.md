# M0 — Skeleton, schemas and workflows

## Objetivo
Dejar el repo listo para construir encima: paquete SPM, dominio sin dependencias de plataforma, schemas de datos, validación offline y workflows de CI/release (SPEC §3, §13 M0/M0b, §16).

## Archivos
- `Package.swift`, `VERSION`, `.gitignore`.
- `Sources/MacHIDDomain/`: `USBID`, `Capability`, `DeviceDefinition`, `Profile`, `Ports` (Transport, DeviceDriver, ProfileRepository), `Registry` (modelo y `RegistryValidator`).
- `Sources/machid/` (CLI mínimo, solo `--version`) y `Sources/machid-validate/` (validador usado por CI).
- `Schemas/`: `plugins`, `device-definition` y `plugin-manifest` (JSON Schema 2020-12).
- `Definitions/`: Huntsman Mini, G203 Lightsync y Brio 100, solo con la capability `info`, porque los protocolos aún no están verificados.
- `plugins.json` vacío (schema_version 1).
- `scripts/verify-registry-refs.py`: comprueba en GitHub que cada `ref` existe y que `manifest_sha256` coincide.
- `.github/workflows/`: `ci.yml`, `release.yml`, `registry.yml`.
- `Tests/MacHIDDomainTests/DomainTests.swift`: 17 pruebas (Swift Testing).

## Lógica y decisiones
- El dominio solo usa Foundation; el hardware queda detrás de `Transport`.
- La validación de `plugins.json` rechaza refs que no sean un SHA de 40 caracteres, repos fuera de `https://github.com/<owner>/<repo>`, licencias fuera de una lista SPDX compatible con GPLv3 y ids duplicados. Reglas que necesitan red (existencia del commit, hash del manifest) corren solo en CI.
- `release.yml`: versión `MAJOR.MINOR` (archivo `VERSION`) más número de commits; tag `v<versión>`; ignora `docs/**`, `*.md`, `plugins.json` y `Schemas/**`; cola de releases sin cancelar; entorno `release` para los secretos.
- `registry.yml`: valida y, en `master`, firma `plugins.json` con Ed25519 (OpenSSL 3) y publica una release `registry-<fecha>-<sha>` marcada `--latest=false`. La app debe filtrar releases por prefijo `registry-` en lugar de usar `latest`.

## Secretos que debes crear (entorno `release`)
`DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`, `DEVELOPER_ID_IDENTITY`, `NOTARY_API_KEY_P8_BASE64`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID`, `REGISTRY_SIGNING_KEY_PEM` (clave Ed25519 privada).

## Riesgos y pendientes
- **Los workflows no se han ejecutado**: no hay remoto de GitHub. Solo se verificó que el YAML parsea y que `swift build/test` y `machid-validate` funcionan en local. Es probable que el primer run requiera ajustes.
- Acciones fijadas por tag (`@v4`), no por SHA como pide SPEC §16. Fijarlas por SHA (por ejemplo con `pinact`/Dependabot) antes de usar secretos reales.
- `release.yml` publica por ahora solo el CLI firmado y notarizado (un `.zip` no admite *stapling*). Faltan app, DMG, Sparkle/appcast y cask (M4, M6b, M7).
- Ajustar `macos-15` si Xcode del runner no cubre el SDK que necesite la app.
- La clave pública del registro aún no está embebida en ningún cliente (llega con M6b).
- Se desarrolló con Swift 6.4 / Xcode 27.1; el CI usa la toolchain del runner (Swift 6.0 mínimo, `swift-tools-version: 6.0`).

## Pruebas
- Ejecutadas: `swift build`, `swift test` (17 pasan), `machid-validate registry|definition` y `verify-registry-refs.py` sobre el estado actual.
- Recomendadas: ejecutar los tres workflows en un repo de prueba; añadir un plugin de ejemplo real para ejercitar `verify-registry-refs.py`.
