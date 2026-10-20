# M11: funciones del G203 LIGHTSYNC (iluminación completa, etapas DPI, estado onboard, layout de botones)

## Objetivo
Exponer lo que G HUB ofrece para el G203 y que es alcanzable con escrituras volátiles HID++ 2.0 verificables en fuentes abiertas. Lo no verificable queda como brecha documentada, no se escribe.

## Archivos
- `Sources/MacHIDLogitech/HidppDriver.swift`: `effectParameters(for:)` (función pura), validación de `dpi_stages`, lectura `onboard_state`.
- `Sources/MacHIDDomain/Profile.swift`: `LightingEffect` gana `period`, `brightness`, `waveform` (opcionales; perfiles antiguos siguen decodificando).
- `Sources/MacHIDDomain/Capability.swift`: `CapabilityType.dpiStages`; `LightingZone` gana `period_min`, `period_max`, `brightness`, `waveforms` (opcionales).
- `Sources/MacHIDDomain/MouseLayout.swift` (nuevo): `MouseLayout`, `MouseButton`, `DPIStages`.
- `Schemas/device-definition.schema.json`: tipo `dpi_stages` y campos nuevos de zona (necesario para el validador; archivo fuera de la lista inicial, cambio mínimo).
- `Definitions/logitech-g203-lightsync.json`: capacidades `dpi_stages`, `onboard_state` y parámetros de la zona `backlight`.
- `Tests/MacHIDLogitechTests/HidppTests.swift`: pruebas nuevas.

## Lógica y bytes (0x8071 SetEffectByIndex: `[zona, índice, 10 bytes de efecto, flag]`)
Fuentes: libratbag `src/hidpp20.h` (`hidpp20_internal_led`, MIT) y Solaar `hidpp20.py` `LEDEffects` (offsets coinciden).
- Estático (id 1): `r g b` (brillo = escalado en el host, no hay campo de intensidad; Solaar solo define color y ramp).
- Cycle (id 3): `0 0 0 0 0, período BE16 (ms), intensidad 1..100`.
- Breathing (id 10): `r g b, período BE16, forma de onda 0..6, intensidad 1..100`. Formas (Solaar `LedFormChoices`): default, sine, square, triangle, sawtooth, shark_fin, exponential.
- Off (id 0), con el respaldo previo a negro estático.
- Valores por defecto sin cambios: período 5000 ms, intensidad 100 (los bytes antiguos de cycle no cambian).
- `dpi_stages`: lista solo en el host (texto "400,800,1600", 1 a 5 etapas). El driver solo valida cada etapa contra la lista del sensor (0x2201 fn1) y no escribe nada; la app cicla en software con `dpi`. La tabla de etapas onboard es memoria persistente y no se toca.
- `onboard_state` (solo lectura, 0x8100): fn 2 = modo (1 onboard, 2 host), fn 4 = perfil actual (byte 1). libratbag `CMD_ONBOARD_PROFILES_GET_ONBOARD_MODE 0x20 / GET_CURRENT_PROFILE 0x40`.
- `polling_rate`: sin cambios (0x8060, 125/250/500/1000; 0x8061 no existe en este equipo).
- `MouseLayout.logitechG203`: izquierdo(0), derecho(1), rueda(2), atrás(3), adelante(4) como botones macOS; rueda arriba/abajo son scroll (no son `InputTrigger`); DPI es onboard (no visible en el host).

## Decisiones
- Brillo y velocidad no son capacidades separadas: viajan en el valor `backlight` (`LightingEffect`) porque el equipo los aplica junto al efecto y el driver no guarda estado. La UI usa los rangos de la zona.
- Sin escrituras persistentes; 0x8110, 0x00c2 (DFU), batería (cableado) no se tocan.

## Riesgos / brechas no verificadas
- Rango de período 1000..20000 ms es consejo de UI; el driver acepta 1..65535. El límite real del G203 no está en fuentes abiertas.
- Brillo del estático por escalado de color es una decisión propia, no un campo del protocolo.
- Cycle/breathing y formas de onda no probados en hardware (como indica HANDOFF). Probar con `machid set 046d:c092 backlight ...` y restaurar con `device_mode 0`.
- Asignación atrás/adelante de los botones laterales es la convención HID, sin confirmar con un monitor de eventos; el fichero libratbag `logitech-g102-g203.device` no describe botones.
- No existe feature id verificado para angle snapping, surface tuning ni lift-off en este equipo: brecha documentada, no implementada.
- Tabla de etapas DPI onboard y botones onboard (0x8100 memoria, 0x8110 spy) quedan fuera por la regla de no persistencia.

## Pruebas
`swift test --scratch-path /private/tmp/machid-logi --filter MacHIDLogitechTests` (60 pruebas, pasan): bytes exactos de cycle/breathing/static, rechazo de valores inválidos, escritura completa por 0x8071, decodificación retrocompatible, etapas DPI, estado onboard, layout. `machid-validate definition` OK. Recomendado: prueba en hardware vía Terminal del usuario.
