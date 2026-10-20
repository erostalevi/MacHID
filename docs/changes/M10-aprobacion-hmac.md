# M10: aprobación de macros con HMAC y clave en Keychain

## Objetivo
Cerrar la brecha conocida: la aprobación de una macro era un SHA-256 sin clave guardado junto a la macro, por lo que un proceso del mismo usuario podía falsificarla escribiendo el archivo.

## Archivos modificados
- `Sources/MacHIDSystem/MacroFingerprint.swift`: `of` pasa a HMAC-SHA256 (64 hex, mismo formato) con una clave de 32 bytes; nuevo `ApprovalKeyStore` (Keychain, con archivo 0600 en Application Support como respaldo).
- `Tests/MacHIDSystemTests/RemapStorageTests.swift`: prueba de que la huella depende de la clave.

## Lógica y decisiones
- La clave se crea al primer uso (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). La interfaz `fingerprint: (Macro) -> String` no cambia, así que MacroRunner, RemapController y la CLI quedan intactos.
- Las aprobaciones anteriores (SHA-256 simple) dejan de ser válidas: cada macro con shell/open/Shortcuts se aprueba de nuevo una vez. Es el comportamiento seguro por defecto.
- Respaldo en archivo: protección más débil, pero la app sigue funcionando si el Keychain falla.

## Riesgos y pendientes
- Con firma ad hoc cada compilación cambia el requisito de código, por lo que macOS puede pedir permiso de Keychain tras reinstalar; con Developer ID deja de ocurrir.
- Un proceso del mismo usuario que obtenga acceso al Keychain (con permiso del usuario) sigue pudiendo firmar: es una mitigación, no un límite de seguridad absoluto.
- Las pruebas tocan el Keychain real al cargar la clave por defecto.

## Pruebas
`swift test` verde, incluida la nueva.
