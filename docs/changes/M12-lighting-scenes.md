# M12: escenas de iluminación por capas

## Objetivo
Permitir que un teclado muestre varias capas a la vez (fondo spectrum/estático + capa reactiva + acentos pintados) y una escena distinta mientras un "shift mode" esté activo. El Huntsman Mini solo ejecuta un efecto nativo, así que las escenas multicapa se renderizan por software a frames por tecla y se envían como `key_lighting` (como hace el daemon de OpenRazer). Una escena de una sola capa nativa se marca con `nativeEquivalent` (se envía una vez, sin streaming).

## Archivos (todos nuevos)
- `Sources/MacHIDDomain/LightingScene.swift`: `LightingBlend`, `LightingRegion`, `LightingLayerKind`, `LightingLayer`, `LightingScene`, `ShiftSceneRule`, `LightingSetup`, escenas por defecto.
- `Sources/MacHIDApplication/LightingCompositor.swift`: `KeyEvent`, `LightingCompositor`, `FrameThrottle`.
- `Sources/MacHIDSystem/FileLightingSceneRepository.swift`: JSON `lighting-scenes.json` en Application Support (o `MACHID_SUPPORT_DIR`).
- Tests: `Tests/MacHIDApplicationTests/LightingCompositorTests.swift`, `Tests/MacHIDSystemTests/FileLightingSceneRepositoryTests.swift`.

## Lógica
- Matemática de color: sRGB codificado (0...1), sin linealizar (coincide con la simulación en pantalla). Alpha por tecla = alpha de la capa x opacidad x máscara de región. `out = fondo*(1-a) + a*mezcla(fondo, fuente)`; normal = s, add = min(1, b+s), screen = 1-(1-b)(1-s), multiply = b*s. El fondo inicial es negro opaco; el brillo de la escena escala el resultado. HSV con s=0.85, v=1.
- Capas: solid, spectrum, wave (dirección 0/1), breathing, starlight (hash FNV-1a + splitmix64 por tecla y ciclo: determinista), reactive (decae con la edad del evento, cuadrática; `ripple` añade un anillo a 9 u/s), painted (celdas de matriz), gradient (ángulo), rainbowRipple.
- Eventos: se descartan los futuros y solo cuentan los 32 más recientes (`maxEvents`).
- Selección de escena: `LightingSetup.scene(forActiveModes:)`; gana la regla con más modos, todos activos; empate = primera de la lista; reglas hacia escenas inexistentes se omiten; si no hay regla, escena base, luego la primera.
- `nativeEquivalent`: una sola capa habilitada, región `.all`, opacidad 1, no multiply. Mapeo a `static`, `spectrum`, `wave`, `breathing` (period = 4000/speed ms), `starlight`, `reactive`; sin capas = `off`. Painted, gradient, ripple y rainbowRipple no tienen equivalente. Los pasos de velocidad Razer (reactive 1...4, starlight 1...3) son una aproximación por umbrales.
- `singleZoneColor`: promedio del render, para mouse (una zona).
- `FrameThrottle`: máximo 1 frame por `minInterval` (0.05 s = 20 fps) y solo si algún canal cambió más que `tolerance` (2). `reset()` tras reconexión.
- Persistencia: `schemaVersion`; decodificación tolerante (campos ausentes con valor por omisión, capas/escenas/reglas ilegibles se descartan). Archivo ausente, corrupto o de versión mayor devuelve los valores por defecto.

## Decisiones
- `frame` omite teclas apagadas (`keyFrame` deja apagado lo no listado).
- Capas con tipo desconocido se descartan en vez de invalidar el archivo (compatibilidad hacia adelante).
- El compositor vive en Application (puro) y no conoce dispositivos ni UI.

## Límites y riesgos
- El streaming de frames NO está verificado en hardware. Cada frame cuesta 6 intercambios USB (5 filas + activar; el trabajo "5 paquetes/frame" son las filas): a 20 fps son ~120 paquetes/s, hay que medir latencia y calor antes de fijar la tasa.
- Los frames son volátiles; al desconectar el teclado la escena se pierde y debe reenviarse.
- La matriz de Esc y backslash está marcada como no cruzada (M11).
- No hay estado compartido: el llamador mantiene el reloj, la lista de `KeyEvent` y el `FrameThrottle`.

## Pruebas
Unitarias: mezcla, orden/opacidad, regiones, painted, decaimiento reactive, ripple, tope de eventos, starlight determinista, spectrum/gradient, equivalencia nativa, selección por combos, round-trip JSON y decodificación tolerante, throttle, repositorio (defaults, round-trip, archivo corrupto/versión futura). Pendiente: prueba en hardware vía Terminal del usuario.
