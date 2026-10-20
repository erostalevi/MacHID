# M11: funciones de iluminación del Razer Huntsman Mini

## Objetivo
Exponer todo lo de iluminación que OpenRazer verifica para el Huntsman Mini (USB 1532:0257, modelo opto-mecánico estándar, no el analógico): breathing (aleatorio/uno/dos colores), dirección de wave, velocidad de reactive y starlight, starlight de dos colores, y frame personalizado por tecla. Más los datos de layout físico y matriz para que la UI dibuje el teclado. Todas las escrituras son volátiles (varStore, o frame sin almacenamiento).

## Archivos
- `Sources/MacHIDRazer/RazerCommands.swift`: `breathing`, `starlight` (dos colores), `customFrameRow`, `activateCustomFrame`.
- `Sources/MacHIDRazer/RazerDriver.swift`: `effectRequest` (valida y mapea), capacidad `key_lighting`, `customFrameRows`, dimensiones de matriz en `RazerModel` (`driver_options.matrix_rows` / `matrix_columns`).
- `Sources/MacHIDDomain/Capability.swift`: `CapabilityType.perKeyLighting` (`per_key_lighting`), `LightingModeOptions`, `LightingZone.modeOptions`, `CapabilityParameters.rows/columns`.
- `Sources/MacHIDDomain/Profile.swift`: `LightingEffect.speed/direction/secondColor`, `KeyColor`, `SettingValue.keyFrame`.
- `Sources/MacHIDDomain/KeyboardLayout.swift` (nuevo): `KeyboardKey`, `KeyboardLayout.huntsmanMini`.
- Fuera de la lista inicial pero necesarios para compilar y validar: `Sources/machid/Common.swift` (`describe` exhaustivo, una línea), `Sources/MacHIDApplication/DeviceControl.swift` (`validate` acepta `.perKeyLighting` + `.keyFrame` y comprueba límites), `Schemas/device-definition.schema.json` (tipo `per_key_lighting`, `rows`, `columns`, `mode_options`).
- `Definitions/razer-huntsman-mini.json`: modo `breathing`, `mode_options`, capacidad `key_lighting` (5 x 15).
- Tests: `Tests/MacHIDRazerTests/RazerFeatureTests.swift`.

## Formatos de bytes y fuentes
Todos son reportes de 90 bytes, transacción `0x3F` (OpenRazer `razerkbd_driver.c`: el Huntsman Mini usa `0x3F` en wave, starlight y custom frame), CRC = XOR de los bytes 2..<88. Argumentos (desde el byte 8):

| Comando | Clase/cmd | Tamaño | Argumentos | Fuente (razerchromacommon.c) |
|---|---|---|---|---|
| Breathing aleatorio | 0F 02 | 06 | `01 05 02` | `razer_chroma_extended_matrix_effect_breathing_random` |
| Breathing 1 color | 0F 02 | 09 | `01 05 02 01 00 01 R G B` | `..._breathing_single` |
| Breathing 2 colores | 0F 02 | 0C | `01 05 02 02 00 02 R1 G1 B1 R2 G2 B2` | `..._breathing_dual` |
| Starlight 2 colores | 0F 02 | 0C | `01 05 07 00 SPD 02 RGB1 RGB2` (SPD 1..3) | `..._starlight_dual` |
| Wave | 0F 02 | 06 | `01 05 04 DIR 28` (DIR 0 o 1) | `..._wave` |
| Fila de frame | 0F 03 | 47 | `00 00 FILA COL_INI COL_FIN RGB...` | `razer_chroma_extended_matrix_set_custom_frame2` |
| Activar frame | 0F 02 | 0C | `00 00 08` | `razer_chroma_extended_matrix_effect_custom_frame` |

Reactive (velocidad 1..4), starlight 1 color/aleatorio, spectrum, none y static ya existían (mismas fuentes). El orden de operación del frame sigue `razer_attr_write_matrix_custom_frame` (filas) y `razer_attr_write_mode_custom` (activar) de `razerkbd_driver.c`. `keyboards.py` declara para `RazerHuntsmanMini`: `MATRIX_DIMS = [5, 15]`, `WAVE_DIRS = (0, 1)` y los métodos breath/starlight/reactive/wave/custom/spectrum/static/none.

## Lógica
- `LightingEffect` ganó `speed`, `direction`, `secondColor` (todos opcionales; los perfiles anteriores decodifican igual). Valores por omisión: wave dirección 1, reactive velocidad 2, starlight velocidad 2. Valores fuera de rango se rechazan (antes se recortaban en silencio) y nada se envía.
- `breathing`: sin color = aleatorio; `color` = uno; `color` + `secondColor` = dos. `secondColor` sin `color` es error. Starlight igual (sin color = aleatorio).
- `key_lighting` recibe `.keyFrame([KeyColor])`: las teclas listadas toman su color, el resto queda apagado (si se repite una celda gana la última). El driver arma 5 filas densas de 15 celdas, entra en modo driver, envía cada fila y luego activa el efecto custom (6 intercambios). Codificado en JSON como arreglo de `{row, col, color}`.

## Decisiones
- Wave: no se expone velocidad. OpenRazer fija `0x28` (comenta que otro modelo usa `0x10` para "fast wave", sin verificar en este). Solo dirección.
- Game mode / macro LED: no se exponen. Game mode no es iluminación (afecta la tecla Windows) y OpenRazer no verifica un LED de macro físico en el Mini. Ripple lo hace el daemon de OpenRazer por software (reenvía frames), no es un comando del dispositivo; no se implementa.
- No se inventó actuación ni rapid trigger: no existen en el Mini estándar.
- `LightingModeOptions` en la definición permite a la UI saber qué parámetros muestra cada modo sin conocer la marca.

## Layout (`KeyboardLayout.huntsmanMini`)
61 teclas ANSI 60%, matriz 5 filas x 15 columnas (columna 0 sin uso). API: `keys` (`id`, `label`, `row`, `col`, `x`, `y`, `width`, `height`, `matrixCrossChecked`), `width`, `height`, `key(row:col:)`, `key(id:)`, `key(atX:y:)` (unidades de tecla), `frame(filling:)`.
Origen de la matriz: mapa de Polychromatic `data/devicemaps/huntsman_mini_en_US.json` (GPL-3.0, keycode evdev -> [col, fila]), contrastado con `KEY_MAPPING` de OpenRazer `keyboard.py` (teclado completo). Coinciden letras, números, Caps, Shift, Ctrl, Super, Alt, Space (col 7), Alt derecho (11), Fn (12), Menu (13), Ctrl derecho (14), Enter, Backspace. **No verificadas por segunda fuente** (`matrixCrossChecked == false`): `esc` (ocupa la posición del backtick completo) y `backslash` (ANSI; OpenRazer solo lista el ISO). Las medidas de las teclas son las ANSI 60% estándar, supuestas, no medidas. Nada se probó en hardware.

## Riesgos y pendientes
- Sin hardware: ningún efecto nuevo ni el frame se probó en el teclado. Probar con `machid` en la Terminal del usuario y restaurar con `device_mode 0`.
- Si la matriz real difiere en alguna tecla, se vería la luz en otra tecla; es inocuo pero visible.
- Las 5 escrituras de fila + activación no son atómicas: puede verse un frame parcial unos milisegundos.
- La UI debe tratar `key_lighting` y `backlight` como excluyentes (el último escrito gana) y re-aplicar `.keyFrame` tras reconectar (el dispositivo no lo guarda).
- `swift test` completo: fallan 2 tests de `FingerprintTests` (HMAC con Keychain, M10, de otro agente), ajenos a este cambio.

## Pruebas
`swift test --scratch-path /private/tmp/machid-razer --filter MacHIDRazerTests`: 38 tests pasan. Nuevos: bytes exactos con CRC para breathing (3 variantes), starlight dual, wave dirección 0, fila de frame y activación; mapeo del driver para cada efecto; rechazo de parámetros inválidos antes de enviar; frame (5 filas + activación, última celda gana, fuera de matriz rechazado); decodificación retrocompatible de `LightingEffect` y round trip de `.keyFrame`; consistencia del layout (61 teclas, sin celdas repetidas, filas de 15u). `machid-validate definition Definitions/razer-huntsman-mini.json`: OK.
