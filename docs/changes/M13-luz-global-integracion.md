# M13: luz global e integración de gestos

## Objetivo
Una página para configurar la iluminación de todos los dispositivos con un tiempo de ciclo compartido, y conectar los gestos shift al event tap.

## Archivos
- Nuevos: `GlobalLightController.swift`, `GlobalLightView.swift` (Ajustes > Luces).
- Modificados: `LightingScenesController.swift` (`globalOverride`: escena y reloj compartidos para los dispositivos por software), `RemapController.swift` (`MotionHook`; el tap observa el movimiento solo si existen gestos y se reinicia al cambiar eso), `SettingsView.swift`, `MacHIDApp/main.swift`, `MacHIDSnapshots/main.swift`, `Localizable.xcstrings`.

## Lógica
- `GlobalLightingPlan.make` decide escrituras nativas por dispositivo; los que muestran fotogramas por tecla se renderizan desde un único `LightingClock` (mismo origen y periodo). Los efectos de firmware (G203 cycle, Razer spectrum/wave) no se pueden fijar en fase; se avisa en la página.
- Ajustes persistidos en UserDefaults. "Usar iluminación por dispositivo" libera el control global.

## Riesgos
- Sin verificar en hardware ni a la vista (streaming ~20 fps, gestos con el tap real, acciones de sistema por teclas sintetizadas).
- La página Luces no está en el panel de menú aún.

## Pruebas
`swift test` completo en verde. Recomendado: probar en hardware con la Terminal del usuario.
