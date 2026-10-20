# M3c — Escrituras Logitech HID++ (DPI y luces) para el G203 LIGHTSYNC

## Objetivo
Permitir cambiar DPI y color de iluminación del G203 de forma volátil, con comandos verificados antes en fuentes abiertas (pedido del usuario).

## Verificación en fuentes abiertas
- **libratbag** (`src/hidpp20.c`, licencia MIT; lista el G203 `046d:c092` con el driver `hidpp20`): ADJUSTABLE_DPI (0x2201): función 1 = lista de DPI válidas (`[sensor, valores BE16…]`, con rango `[min, 0xE000+paso, max]`), función 2 = leer DPI, función 3 = fijar DPI `[sensor, dpi BE16]`, con eco del valor.
- COLOR_LED_EFFECTS (0x8070): función 0 = info (nº de zonas), 1 = info de zona (nº de efectos), 2 = info de efecto `[zona, posición, id BE16, …]`, 3 = fijar efecto de zona `[zona, efecto…]`. IDs de efecto: 0 desactivado, 1 fijo (color RGB en los 3 primeros bytes). libratbag escribe un byte de persistencia (`parameters[12] = 1`: "RAM y flash"); aquí queda en **0 (solo RAM)**, como Solaar, que no lo envía.
- **Solaar** (`settings_templates.py`, GPL-2.0-or-later): el ajuste "LED Control" de 0x8070 usa la función 7 (leer) y la 8 (escribir) con 1 = control por software y 0 = modo dispositivo, y las luces por zona exigen que esté activado. Es el equivalente del modo driver de Razer.
- Los efectos se direccionan por su **posición** en la lista de efectos de la zona, no por id; el driver recorre la lista y busca el id.

## Cambios
- `Sources/MacHIDLogitech/HidppDriver.swift`: `dpi` (escritura validada contra la lista del sensor, eco comprobado), `backlight` (color o `off`, zona 0), `device_mode` (0 dispositivo / 1 host, leer y escribir), `HidppDPIList`.
- `Definitions/logitech-g203-lightsync.json`: `dpi` (200-8000, paso 50), `device_mode` (0, 1) y `backlight` (modos `static`, `off`), todo volátil.
- `Tests/MacHIDLogitechTests/HidppTests.swift`: mouse simulado y 13 pruebas nuevas; en total 71 pruebas en el proyecto.

## Decisiones
- Cualquier DPI que no esté en la lista del sensor se rechaza **antes** de enviar nada.
- Escribir luz toma el control de las LEDs (función 8 = 1) automáticamente y lo deja activo; `machid set 046d:c092 device_mode 0` devuelve el efecto propio del mouse.
- La persistencia queda siempre en 0; no se escribe nada en la memoria del mouse (SPEC §9).

## Validación en hardware
- DPI (G203 real, ejecutado por el usuario): `set dpi 1600` y `set dpi 3200` funcionaron correctamente, con relectura y comportamiento del cursor acorde ("works perfectly"). Confirma la función 3 de ADJUSTABLE_DPI, la validación contra la lista del sensor y el eco. El primer intento falló solo porque el CLI aún no aceptaba `dpi` en `set` (corregido en `5c95dba`); no llegó a enviarse nada.
- **Pendiente en hardware**: luces (`backlight`) y `device_mode`.

## Riesgos y pendientes
- **Luces sin validar en hardware.** Solo hay pruebas contra un dispositivo simulado construido a partir de las fuentes anteriores. Podría haber diferencias en el G203 real (por ejemplo, otro número de zonas o un efecto "fijo" con otro id).
- El efecto previo del mouse no se puede leer ni restaurar desde MacHID; se recupera con `device_mode 0` o reconectando.
- Si el DPI se aplica solo al perfil activo del mouse (perfil onboard), puede volver al valor guardado al reconectar; hay que comprobarlo.
- Otras funciones (tasa de sondeo 0x8060/0x8061, perfiles onboard) no se tocan.

## Pruebas
- Ejecutadas: suite completa (71 pruebas) y validación de definiciones.
- Recomendadas en el dispositivo, por etapas: (1) `get dpi`, `set dpi 1600`, `get dpi`, `set dpi 3200`; (2) `set backlight` con un color y `set device_mode 0`.
