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
- ~~Luces sin validar en hardware~~ (resuelto, ver la sección de 0x8071). Solo hay pruebas contra un dispositivo simulado construido a partir de las fuentes anteriores. Podría haber diferencias en el G203 real (por ejemplo, otro número de zonas o un efecto "fijo" con otro id).
- El efecto previo del mouse no se puede leer ni restaurar desde MacHID; se recupera con `device_mode 0` o reconectando.
- Si el DPI se aplica solo al perfil activo del mouse (perfil onboard), puede volver al valor guardado al reconectar; hay que comprobarlo.
- Otras funciones (tasa de sondeo 0x8060/0x8061, perfiles onboard) no se tocan.

## Pruebas
- Ejecutadas: suite completa (71 pruebas) y validación de definiciones.
- Recomendadas en el dispositivo, por etapas: (1) `get dpi`, `set dpi 1600`, `get dpi`, `set dpi 3200`; (2) `set backlight` con un color y `set device_mode 0`.

## Hallazgo: el G203 usa RGB_EFFECTS (0x8071), no COLOR_LED_EFFECTS (0x8070)
Lectura del listado de features en el G203 real (`machid get 046d:c092 features`, solo lectura): `0:0000 1:0001 2:0003 3:0005 4:1801 5:1802 6:1806 7:1e00 8:1e22 9:1eb0 10:2201 11:18b1 12:00c2 13:8060 14:8071 15:8100 16:8110 17:18a1 18:8081`. No existe 0x8070; el primer intento de luces falló limpiamente (`feature 0x8070 is not available`) sin enviar nada. El índice 14 (0x0e) coincide con los paquetes `11 ff 0e …` de la comunidad.

Implementado según las fuentes abiertas (Solaar, GPL-2.0-or-later, y libratbag para los formatos de información):
- Información 0x8071, función 0: `[0xFF,0xFF,0]` → nº de zonas en el byte 2; `[zona,0xFF,0]` → nº de efectos en el byte 4; `[zona,posición,0]` → id de efecto (BE16) en los bytes 2-3.
- Control del host: perfiles onboard (0x8100) función 1 = `[2]` (modo host) y 0x8071 función 5 `[1,3,4]` (SetSWControl). Liberar: `[1,0,0]` y luego perfiles `[1]`.
- Fijar efecto: función 1 con `[zona, posición, 10 bytes de parámetros, 0x01]` (color RGB en los 3 primeros). Solaar lo describe como efecto estático "no persistente" para 0x8071.
- `off`: efecto id 0 si existe; si no, estático en negro.
- `device_mode` en 0x8071: leer = función 5 sin parámetros (modo en el byte 1); escribir 1 reclama y 0 libera.

Riesgo conocido: el byte final `0x01` de 0x8071 se toma de un único comentario de Solaar (probado allí en otro mouse); si el G203 conserva el color tras desconectarlo, esa bandera hay que revisarla. Mientras el mouse esté en modo host los botones del perfil onboard pueden comportarse distinto; `device_mode 0` lo revierte.

Pruebas: 81 pruebas unitarias en total (21 de HID++ nuevas, con un mouse simulado de 0x8071).

## Validación en hardware de las luces (G203 real)
Ejecutado desde el terminal de la app: `get device_mode` → `0`; `set backlight FF0000`, `00FF00` y `0000FF` (exit 0, 2 s cada uno); `get device_mode` → `1` durante el ciclo; `set device_mode 0` (exit 0); `get device_mode` → `0`. El usuario confirmó que las luces pasaron por rojo, verde y azul y que luego volvieron a su efecto original. Quedan validados en un G203 LIGHTSYNC: 0x8071 (información de zona y efectos, SetSWControl, modo host de perfiles onboard, SetEffectByIndex) y la liberación.

Pendiente: comprobar que el color no persiste tras desconectar el mouse (la bandera final `0x01`) y el comportamiento de los botones durante el modo host.
