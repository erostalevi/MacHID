# M3a — Logitech HID++ 2.0 (solo lectura) para el G203 LIGHTSYNC

## Objetivo
Preparar la familia Logitech de forma segura: descubrir cómo habla el G203 y construir el cliente HID++ 2.0 de solo lectura (versión de protocolo y DPI actual). La cámara UVC (Brio 100) y las escrituras (DPI, iluminación) quedan para M3b y para después de validar en hardware.

## Hallazgos (lectura del registro de IOKit, sin abrir el dispositivo)
- El G203 expone 2 interfaces HID. La de **usage page 1 / usage 6** (teclado) tiene entrada/salida de 20 bytes y su descriptor incluye dos colecciones de **usage page 0xFF00** con **report ID 0x10** (corto, 7 bytes) y **0x11** (largo, 20 bytes). Ese es el canal HID++; la otra interfaz es el mouse normal.
- Coincide con el formato `11 ff 0e 3c …` documentado por la comunidad para el G203 Prodigy (OpenRGB). El protocolo del Lightsync no está confirmado en una fuente oficial; los índices de feature se descubren en runtime (IRoot), no se asumen.
- Ids de feature (tabla pública de Solaar, GPL-2.0-or-later): ROOT 0x0000, ADJUSTABLE_DPI 0x2201, COLOR_LED_EFFECTS 0x8070, RGB_EFFECTS 0x8071.

## Archivos
- `Sources/MacHIDLogitech/Hidpp.swift`: `HidppMessage`, `HidppClient` (petición/respuesta, descubrimiento de features, ping), `HidppFeature`.
- `Sources/MacHIDLogitech/HidppDriver.swift`: capabilities `info` (versión HID++) y `dpi` (lectura). Las escrituras lanzan error a propósito.
- `Sources/MacHIDDomain/Ports.swift`: `Transport` gana `sendOutputReport` y `nextInputReport` (con implementación por defecto que falla, para no romper otros transportes).
- `Sources/MacHIDIOKit/IOKitHIDTransport.swift`: ahora recibe reportes de entrada por callback con cola, y selecciona la interfaz por `HIDInterfaceSelector` (tamaño de reporte feature o de salida).
- `Sources/machid/Connector.swift`: familia `logitech-gseries` usa la interfaz con salida de 20 bytes.
- `Definitions/logitech-g203-lightsync.json`: `info` y `dpi` (solo lectura).
- `Tests/MacHIDLogitechTests/HidppTests.swift` (13) y `Package.swift`.

## Lógica y decisiones
- Mensaje largo: `[0x11][índice dispositivo 0xFF por cable][feature][función<<4 | software id][16 parámetros]`. Las respuestas se emparejan por feature, función y software id; se ignoran notificaciones y respuestas de otros clientes.
- Errores: `[dev][0xFF][feature fallida][función<<4|swid][código]`. Una prueba detectó un error mío de interpretación de este formato y se corrigió antes de usarlo.
- DPI: función 2 de ADJUSTABLE_DPI (`getSensorDpi`, respuesta `[sensor, dpi BE16, dpi por defecto BE16]`). Está tomada de la documentación pública de libratbag/Solaar de memoria y **no está verificada contra el dispositivo**; por eso es solo lectura.
- Sin escrituras en esta fase: cumple SPEC §9 (solo lectura primero).

## Validación en hardware
Ejecutado por el usuario en Terminal.app: `machid get 046d:c092 info` → `HID++ 4.2` y `machid get 046d:c092 dpi` → `3200` (ambos exit 0). Quedan confirmados en un G203 real: la interfaz (salida de 20 bytes), el reporte largo 0x11 con índice 0xFF, el ping de IRoot, el descubrimiento de feature 0x2201 y la lectura de DPI. Las escrituras siguen sin implementar.

## Riesgos y pendientes
- ~~Sin validación en hardware~~ (resuelto para lecturas). Posibles ajustes: ID de reporte o relleno al enviar, formato de entrada en el callback (se quita el ID si viene duplicado), y selección de interfaz.
- Abrir la interfaz de teclado del mouse puede requerir Input Monitoring y competir con el sistema; revisar al probar.
- Luz del G203: efectos vía 0x8070/0x8071 o el comando propietario (`0x3C` con índice 0x0E) por confirmar con el descubrimiento de features en el dispositivo real.
- **M3b pendiente**: cámara UVC (Brio 100) y escrituras Logitech.

## Pruebas
- Ejecutadas: 55 pruebas unitarias pasan (Razer 15, Logitech 13, dominio 17, aplicación 10) y los validadores de definiciones.
- Hardware: `info` y `dpi` correctos en un G203 real.
