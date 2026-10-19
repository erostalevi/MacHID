# M1 — Device enumeration and read-only CLI

## Objetivo
CLI `machid` que lista los dispositivos conectados, los cruza con las definiciones y muestra su información, sin escribir nada y sin abrir los dispositivos (SPEC §13 M1).

## Archivos
- Dominio: `Sources/MacHIDDomain/Discovery.swift` (`DiscoveredDevice`, `HIDInterfaceInfo`, puerto `DeviceEnumerator`, `DefinitionCatalog`).
- Aplicación: `Sources/MacHIDApplication/DeviceInventory.swift` (caso de uso).
- Adaptador: `Sources/MacHIDIOKit/IOKitDeviceEnumerator.swift` (único lugar que importa IOKit).
- CLI: `Sources/machid/main.swift` (`list`, `info`, `--all`, `--json`, `--definitions`, `--version`).
- `Package.swift` (targets `MacHIDApplication`, `MacHIDIOKit`) y `Tests/MacHIDApplicationTests/InventoryTests.swift` (7 pruebas).

## Lógica y decisiones
- Enumeración por el registro de IOKit (`IOUSBHostDevice`) para cubrir también la cámara (no es HID), más `IOHIDManager` solo para listar las interfaces HID (usage page/usage). **No se abre ningún dispositivo**: no requiere Input Monitoring y no puede alterar el estado.
- El serial se reduce a sus últimos 4 caracteres al leerlo (SPEC §9: logs sin identificadores completos).
- `usbRelease` es el `bcdDevice` USB, no el firmware del fabricante; el CLI lo indica. El firmware real requiere driver (M2/M3).
- Se pospuso el `HIDTransport` de escritura/lectura de reportes a M2: M1 no lo necesita y no se quiso añadir código de escritura sin probar.
- Definiciones: `--definitions`, luego `./Definitions`, luego `../share/machid/Definitions` junto al binario. Los archivos inválidos se avisan por stderr.

## Resultado en hardware real (solo lectura)
- `machid list` detecta Brio 100, G203 LIGHTSYNC y Huntsman Mini como `supported`; `--all` añade además el hub USB como `unsupported`.
- Huntsman Mini expone 3 interfaces HID: Generic Desktop mouse (0x01/0x02), keyboard (0x01/0x06) y usage page 0x59.
- G203: solo 2 interfaces Generic Desktop (mouse y keyboard); ninguna usage page de fabricante visible. Esto importa para M3: hay que averiguar por cuál interfaz se hablaría el protocolo.
- Brio 100: sin interfaces HID, como se esperaba (UVC).

## Riesgos y pendientes
- **Entorno**: `~/Documents` está sincronizado con iCloud (File Provider) y marca los bundles `.xctest` con atributos que hacen fallar `codesign` (`resource fork, Finder information... not allowed`). Para correr las pruebas en local: `swift test --scratch-path <carpeta fuera de iCloud>`. Recomendado: mover el repo fuera de Documents (o desactivar la sincronización de Documents). El CI no se ve afectado.
- `IOHIDManagerCopyDevices` y las propiedades del registro pueden variar entre versiones de macOS; solo se probó en esta máquina (macOS 27).
- No hay pruebas automáticas del adaptador IOKit (depende de hardware); la verificación fue manual. Recomendado: una prueba de integración opcional que solo se ejecute con una variable de entorno.
- Los números de `bcdDevice` de los fabricantes no siempre son BCD válido; se muestran tal cual interpretados como BCD.

## Pruebas
- Ejecutadas: 24 pruebas unitarias (17 de dominio y 7 de aplicación) pasan; ejecución manual de `list`, `list --all` e `info` sobre los 3 dispositivos.
