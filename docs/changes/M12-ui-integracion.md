# M12: integración de interfaz (modos shift, escenas de iluminación, selector reordenable, panel de menú)

Complementa `M12-shift-modes.md` y `M12-lighting-scenes.md`.

## Cambios
- **Ratón**: una sola capa de detección (`MouseSimView.hit`) con la geometría del dibujo; cualquier zona de botón (izquierdo, derecho, rueda, DPI, adelante, atrás) se puede seleccionar. Dibujo mate, sin brillos. Pruebas en `ViewLogicTests`.
- **Reasignación**: la pestaña Key/Macro ya no se queda en "Default" (la elección se conserva hasta que existe una regla); menú de acciones: tecla, clic, macro, cambiar de perfil (concreto, siguiente, anterior), activar un modo shift, nada. "Crear una macro…" abre Ajustes > Macros.
- **Modos shift**: tarjeta "Shift modes" (activador grabado, mantener o alternar, "También cambia otros dispositivos") y selector de capa (base o combinación de modos) que decide a qué capa se aplican las reglas editadas. Los modificadores sueltos (fn de macOS, ⌥/⌘/⌃/⇧ derechos, Caps Lock) se pueden grabar como activador.
- **Perfiles como acción**: `onSwitchProfile`/`onCycleProfile` conectados a `AppModel.applyProfileToAll` y `cycleProfiles`.
- **Escenas de iluminación**: `LightingScenesController` (persistencia, escena activa según los modos shift, vista previa en el teclado, transmisión de fotogramas a ~20 fps con `AppModel.stream`, monitor de pulsaciones `KeyPressMonitor` de solo escucha para capas reactivas) y `LightingScenesPanel` (lista, asignación por modo shift, editor de capas: colores, velocidad, brillo, opacidad, mezcla, pintura por tecla). Un ratón recibe el color/efecto equivalente de la escena.
- **Color**: `ColorField` con muestras exactas, campo hexadecimal (RRGGBB, #RGB) y selector del sistema; los valores son sRGB exactos (antes se usaban colores del sistema que cambian con el tema).
- **Selector de dispositivos**: reordenable arrastrando (o con "Mover a la izquierda/derecha"); el orden se guarda.
- **Panel de menú**: mismo lenguaje visual que la ventana: barra de dispositivos, dibujo en miniatura en vivo, tarjeta con perfil, DPI (ajustes de un toque), iluminación con muestras, reasignación y pie.

## Límites
- La tecla Fn de Razer es firmware y macOS no la ve: no puede ser activador. Sí pueden: fn/globo de macOS, modificadores derechos, teclas normales, botones central y extra del ratón.
- "Otros dispositivos" distingue teclado y ratón, no dos teclados (el tap no identifica el dispositivo).
- Nada se probó en hardware ni se vio en pantalla; la transmisión de fotogramas cuesta ~120 paquetes USB por segundo (a medir).
- La actuación/rapid trigger sigue sin existir para este teclado (ver M11).
