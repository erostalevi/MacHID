# M13: rediseño de interfaz (pestañas Light/Keys/Info, selector de teclas, capas plegables, modos shift, gestos)

## Objetivo
Interfaz más compacta y estilo Apple, con tres pestañas por dispositivo, selector de teclas además de la escucha, editor de capas de iluminación plegable y gestor de modos shift y gestos. Solo capa de UI; el motor (acciones de sistema, gestos, reloj global) está en M13 motor.

## Archivos
- Nuevos (`Sources/MacHIDUI`): `DeviceTabs.swift`, `FocusSupport.swift`, `InputPicker.swift`, `ShiftModesManager.swift`, `GesturesManager.swift`, `SystemActionMenu.swift`, `LightingLayerCard.swift`; prueba `Tests/MacHIDUITests/InterfaceRedesignTests.swift`.
- Modificados: `DeviceSidebar`, `AppModel` (pestañas), `ButtonsPanel`, `LightingScenesPanel`, `RemapController` (`upsertGesture`/`removeGesture`), `RemapView`, `MacrosView`, `ColorField`, `MainWindowView`, `SettingsView`, `Theme` (`DisclosureCard`, espaciados), `DeviceStage`, `MacHIDApp/main.swift` (menú «Tab», ⌘1…⌘3), `Resources/Localizable.xcstrings` (es).

## Lógica
- **Pestañas**: `DeviceTab` agrupa las secciones del dominio sin tocarlas: Light = lighting + image; Keys = buttons + performance (DPI/polling dentro de un `DisclosureCard`); Info = info + advanced (plegado). Info siempre existe; una cámara no tiene Keys. `AppModel.selectedTab` deriva de `selectedSection`.
- **Foco**: `commitsAndResigns` (Return confirma y suelta el foco) en todos los `TextField`; `resignsFocusOnBackgroundTap` en ventana principal y ajustes.
- **Selector**: `InputPicker` = grabadora + lista con búsqueda por grupos (letras, números, F, modificadoras, navegación, puntuación, teclado numérico, botones de ratón) y conmutadores ⌃⌥⇧⌘ para salidas de tecla. Usado en reasignación, disparadores de modos y gestos, macros y Ajustes > Remap. `InputCatalog` es puro y probado.
- **Capas**: se muestran de arriba abajo (orden invertido solo visual; el orden guardado y el de composición no cambian). Solo una capa abierta; el resto una línea (muestra, nombre, ojo). Se abre con clic o con el puntero detenido 0,45 s; la capa nueva y la que se pinta se abren solas. Controles secundarios en «More».
- **Modos shift**: lista compacta con punto de actividad, activador, comportamiento, nº de reglas, avisos (activador compartido, regla normal tapada, activador prohibido), duplicar (copia reglas), quitar con confirmación; chips de capa con contador de reglas. `ShiftModeDiagnostics` es puro y probado.
- **Gestos y acciones macOS**: `GesturesManager` (activador, 4 direcciones, distancia, congelar puntero) y submenús por categoría (`SystemActionMenu`) en «macOS action».

## Decisiones y límites
- Los modos shift no tienen campo «activado» en el dominio, así que no hay interruptor de desactivar (sí duplicar/quitar).
- El catálogo del selector no incluye teclas multimedia: salen por acciones de sistema, no por códigos de tecla.
- La página «Global Light» no está integrada aún (falta el controlador que aplique `GlobalLightingPlan`).
- No se probó en pantalla real ni con hardware; solo instantáneas fuera de pantalla (sin vidrio).

## Pruebas
`swift test --scratch-path /private/tmp/machid-ui2`: todo en verde, incluidas las nuevas (pestañas, catálogo de teclas, diagnósticos de modos shift). Recomendado: revisar a mano el foco tras Return, hover de capas y el selector con Input Monitoring concedido.
