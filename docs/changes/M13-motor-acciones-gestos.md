# M13: acciones de sistema, gestos con tecla mantenida y reloj global de iluminación (motor)

## Objetivo
Añadir al motor (sin vistas) lo que la interfaz necesita para: acciones de navegación de macOS (Mission Control, App Exposé, cambiar de escritorio, teclas multimedia...), gestos "mantén un botón/tecla y mueve el puntero", control global de iluminación con un reloj común, y escenas por defecto más simples.

## Archivos
- Nuevos: `Sources/MacHIDDomain/SystemActions.swift`, `Sources/MacHIDDomain/GlobalLightingPlan.swift`, `Sources/MacHIDApplication/LightingClock.swift`, `Sources/MacHIDQuartz/SystemActionRunner.swift`; pruebas `GestureTests.swift`, `GlobalLightingTests.swift`, `SystemActionRunnerTests.swift`.
- Modificados: `Domain/Remap.swift` (`RemapAction.system`, `ShiftGesture`, `RemapConfig.gestures`), `Domain/LightingScene.swift` (`syncToGlobalClock`, escenas simples), `Application/RemapEngine.swift` (acción de sistema, gestos, `decideMotion`), `Quartz/RemapEventTap.swift` (movimiento, `runSystem`), `machid/RulesCommand.swift` (caso nuevo), `LightingCompositorTests` (número de escenas).

## Lógica
- **Acciones de sistema**: `RemapAction.system(id)` con catálogo `SystemActionCatalog` (id, título, símbolo SF, categoría, implementación). Tres implementaciones: combinación de teclas sintetizada (App Exposé Ctrl+↓, escritorio Ctrl+←/→, Mostrar escritorio F11, Spotlight ⌘Espacio, Notificaciones fn+N, Dock ⌥⌘D, captura ⇧⌘5, bloqueo ⌃⌘Q), tecla multimedia como evento `systemDefined` subtipo 8 (play, siguiente, anterior, volumen, silencio, brillo) y abrir app (Mission Control, Apps/Launchpad: no dependen de atajos). "Ejecutar Atajo" no está en el catálogo: es un paso `shortcut` de una macro y ya pasa por la aprobación.
- **Gestos** (`ShiftGesture`): disparador (tecla o botón; mismas prohibiciones que `ShiftMode`: clic izquierdo/derecho y Escape), umbral en píxeles (10...1000, defecto 80), una acción por dirección (izq/der/arriba/abajo), `freezePointer`. Mientras se mantiene el disparador (que se consume) el motor acumula el desplazamiento; al llegar al umbral en el eje dominante se dispara la acción una vez y se desplaza la referencia. Se rearma al volver medio umbral en sentido contrario o al soltar. Las acciones de tecla/botón se envían como pulsación + liberación. Puntero: por defecto NO se congela (el usuario ve lo que hace); con `freezePointer` el tap descarta los eventos de movimiento mientras el disparador está pulsado. El tap solo observa movimiento si se le pasa `motion` (alto volumen de eventos).
- **Reloj global** (`LightingClock`): origen y periodo de ciclo compartidos; `time(at:)` es idéntico para todos los dispositivos; `retimed(scene)` ajusta velocidades de spectrum/wave/breathing al periodo y marca `syncToGlobalClock`.
- **Plan global** (`GlobalLightingPlan.make`): para cada dispositivo con `lighting_zone` escribible elige el modo (`static/off/spectrum|cycle/wave/breathing`), el periodo (acotado al rango de la zona), el brillo (capacidad `brightness` o inline en el efecto) y devuelve escrituras `SettingValue.effect`. Si el efecto es animado, `keepInSync` está activo, el dispositivo tiene `per_key_lighting` y su firmware no admite periodo, va a `softwareDeviceIDs` (se renderiza `GlobalLightingPlan.scene(for:)` con el reloj). Los efectos de firmware que quedan se listan en `notPhaseLockedDeviceIDs`.
- **Escenas por defecto**: `Solid, Breathing, Reactive, Gaming` (simples) antes de las anteriores (`aurora` sigue como base).

## Decisiones y límites
- Las acciones con teclas sintetizadas solo funcionan si el atajo por defecto de macOS sigue activo (Ajustes > Teclado > Atajos). No se lee `com.apple.symbolichotkeys` (formato no documentado). Mission Control y Apps se abren como app para no depender de ello.
- Efectos nativos (G203 `cycle`, Razer `spectrum`/`wave`) no se pueden fasear: comienzan al recibir el comando. Solo se igualan en periodo (G203) o se pasan a software (teclado).
- Cooldown por tiempo no existe (el motor es puro): el rearme por retorno hace de histéresis.
- Nada de esto se probó en hardware ni con el tap real (el agente no tiene Input Monitoring).

## Pruebas
Ejecutadas (paquete sin UI, `swift test`, todo en verde): gestos (umbral, direcciones, disparo único y rearme, freeze, prohibidos, actualización de configuración, JSON), acciones de sistema, catálogo, plan global (sólido, spectrum con teclado en software, sin sync, periodo acotado), reloj, round-trip de escena. Recomendadas: probar en el Terminal del usuario cada acción de sistema (sobre todo Notificaciones, Apps) y un gesto con botón lateral.
