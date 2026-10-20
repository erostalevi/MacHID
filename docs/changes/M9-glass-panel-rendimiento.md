# M9: ventana de vidrio único, menú simplificado y rendimiento de la interfaz

## Objetivo
- La ventana principal es un único panel de vidrio flotante, sin barra superior y transparente al escritorio y a las apps de detrás.
- El panel de la barra de menús es más simple y limpio.
- Corregir la lentitud percibida de la ventana.

## Causas de la lentitud (revisadas en el código)
1. `IdleFloat`: un `TimelineView(.animation)` a 30 fps movía toda la ilustración del dispositivo, que incluía un `blur(radius: 60)` y unas 46 sombras (una por tecla en el teclado). Cada fotograma se volvía a rasterizar bajo vidrio.
2. Capas de Liquid Glass anidadas: cada botón (`PillButtonStyle`, interactivo con hover), cada tarjeta y la cápsula de secciones eran una capa de vidrio propia.
3. Fondo con degradado a pantalla completa y transiciones `blurReplace` al cambiar de dispositivo o sección.

## Archivos modificados
- `Sources/MacHIDUI/WindowGlass.swift` (nuevo): configura la ventana (transparente, sin título, arrastrable por el fondo) e inserta una sola vista de vidrio del sistema detrás del contenido (`NSGlassEffectView` en macOS 26+, `NSVisualEffectView` behind-window antes).
- `Sources/MacHIDUI/GlassSurface.swift`: nuevo `flatSurface` (relleno translúcido y filete, sin capa de vidrio); `PillButtonStyle` lo usa.
- `Sources/MacHIDUI/MainWindowView.swift`: sin fondo propio, `.glassPanelWindow()`, tarjetas planas, `.opacity` en lugar de `blurReplace`.
- `Sources/MacHIDUI/DeviceArt.swift`: se elimina la animación continua, el blur de 60 pt pasa a un `RadialGradient` y se quitan las sombras por tecla (un solo resplandor).
- `Sources/MacHIDUI/ControlViews.swift`: la tarjeta de controles es plana.
- `Sources/MacHIDUI/MenuPanelView.swift`: sin cabecera ni tarjetas de vidrio; dispositivos separados por líneas finas, ancho 300; pie con iconos (abrir, pausar perfiles automáticos, ajustes, salir).
- `Sources/MacHIDApp/main.swift`: `.windowStyle(.hiddenTitleBar)` en la ventana principal.

## Decisiones
- Un solo vidrio real (el de la ventana); el resto es relleno plano. Se pierde el efecto "interactivo" de los botones a cambio de fluidez.
- Se mantienen los botones de semáforo del sistema (flotan sobre el vidrio) para poder cerrar la ventana.
- Se quita la animación de flotación en reposo: era puramente decorativa.
- Con "Reducir transparencia" el sistema muestra el panel opaco.

## Riesgos y pendientes
- No verificado visualmente: el agente no captura la pantalla y los snapshots no renderizan vidrio. Hay que abrir la app y revisar el radio de esquina del vidrio, el contraste del texto sobre fondos claros y el arrastre de la ventana.
- `NSGlassEffectView` se inserta como hermano del contenido en el marco de la ventana (no es su uso documentado, que es `contentView`); si en alguna versión del sistema no se ve, hay que envolver el contenido.
- Ajustes y onboarding siguen con `glassSurface`.
- Si sigue lenta: medir con Instruments (SwiftUI) la lectura de `model.devices` en cada ajuste de slider.

## Pruebas
- `swift build` y `swift test` (todas pasan) con `--scratch-path /private/tmp/machid-ui`.
- Recomendado: `scripts/make-app.sh`, abrir la app y comprobar ventana, menú, arrastre y respuesta de los sliders.
