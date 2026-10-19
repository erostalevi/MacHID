# M2 — Driver Razer (Huntsman Mini)

## Objetivo
Driver de la familia Razer con transporte HID de reportes feature, y comandos de CLI para leer firmware/brillo y aplicar brillo y color de forma volátil (SPEC §13 M2).

## Archivos
- `Sources/MacHIDRazer/`: `RazerReport` (paquete de 90 bytes, CRC), `RazerCommands` (constructores), `RazerDriver` + `RazerModel` (tabla por PID).
- `Sources/MacHIDIOKit/IOKitHIDTransport.swift`: transporte de reportes feature sobre una interfaz HID.
- `Sources/MacHIDApplication/DeviceControl.swift`: caso de uso `read`/`write` con validación contra la definición; puerto `DeviceConnector`.
- `Sources/MacHIDDomain/Ports.swift`: `Transport` pasa a `sendFeatureReport(reportID:_:)` / `getFeatureReport(reportID:length:)`; nuevo `DriverError`.
- `Sources/machid/Connector.swift` (composición) y `main.swift` (`get`, `set`).
- `Definitions/razer-huntsman-mini.json`: añade `brightness` (0-100, volátil) y `backlight` (modos `static`, `off`).
- Pruebas: `Tests/MacHIDRazerTests/RazerTests.swift` (15) y 3 nuevas en `MacHIDApplicationTests` (en total 42 pruebas).

## Lógica
- Protocolo: reporte de 90 bytes (status, transaction id, packets restantes, protocol type, data size, class, command, 80 de argumentos, CRC = XOR de los bytes 2…87, reservado). Petición con SET_REPORT feature y lectura con GET_REPORT feature, con espera y reintentos si el estado es `busy`.
- Comandos (verificados contra las fuentes de OpenRazer, GPL-2.0-or-later, compatible con GPLv3): firmware `00/81` (transaction 0xFF); brillo get/set `0F/84` y `0F/04`; efecto estático `0F/02` size 9; efecto none `0F/02` size 6; todos con transaction id `0x3F`, almacenamiento `VARSTORE` y LED `BACKLIGHT` (0x05). El paquete estático de la documentación se usa como vector de prueba (bytes y CRC).
- La interfaz HID de control se elige por `MaxFeatureReportSize == 90` (en esta máquina es la interfaz 2, usage 0x01/0x02), equivalente al `wIndex = 2` de OpenRazer.
- Seguridad de escritura (SPEC §9): `DeviceControl` rechaza escrituras en capabilities de solo lectura, fuera de rango o de tipo incorrecto, y bloquea `write_persistent`. El driver no usa nunca memoria onboard (`VARSTORE` aplica al estado actual).
- Brillo: la API usa 0-100 y se convierte a 0-255 al enviar (redondeo). La conversión 0-255 es la convención de OpenRazer y **no se ha verificado en el dispositivo**.

## Decisiones
- Se exige lectura previa: `get` no escribe; `set` imprime que el cambio es volátil.
- `backlight` no es legible (el protocolo no permite leer el efecto actual), por eso no se puede restaurar el efecto anterior después de un `set`.
- El transporte no abre el dispositivo hasta que el driver lo necesita; M1 sigue sin abrir nada.

## Estado de la validación en hardware: PENDIENTE
`machid get 1532:0257 info` falla con `open HID interface was refused (0xe00002e2)`: macOS exige el permiso **Input Monitoring** al proceso que abre la interfaz. Es un ajuste de seguridad del sistema; debe concederlo el usuario al programa que ejecuta el comando (Terminal o la app de Claude). Hasta entonces el driver solo está probado con un dispositivo simulado.

Verificación recomendada, en orden (la 1 y 2 son solo lectura):
1. `machid get 1532:0257 info` → firmware, p. ej. `v1.x`.
2. `machid get 1532:0257 brightness` → porcentaje actual.
3. `machid set 1532:0257 brightness <el mismo valor>` → sin cambio visible.
4. `machid set 1532:0257 backlight 00FF00`, luego `off`. Cambia el efecto actual; no se puede restaurar por software hasta que exista un perfil guardado.

## Riesgos y pendientes
- Si el firmware responde distinto en macOS (tamaño de reporte o ID de reporte), habrá que ajustar `IOKitHIDTransport` (por ejemplo, si el reporte debe llevar el ID 0 como primer byte).
- El permiso de Input Monitoring se asocia al proceso anfitrión: en la app final hay que pedirlo de forma guiada (SPEC §7).
- Otros modelos Razer necesitan su `RazerModel` (transaction id, y a veces otro índice de interfaz); no se añaden sin dispositivo para probarlos.
- Familia Logitech y UVC: M3.

## Pruebas
- Ejecutadas: 42 pruebas unitarias pasan (codec, CRC con vector de la documentación, reintentos, errores, validación de `DeviceControl`).
- No ejecutadas: cualquier prueba contra el teclado real (bloqueada por el permiso).
