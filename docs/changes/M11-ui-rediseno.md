# M11: rediseño de la interfaz (ventana fija, escenario + barra lateral) y funciones por dispositivo

Complementa `M11-razer-features.md`, `M11-logitech-g203-features.md` y `M11-camera-preview.md`.

## Objetivo
Una sola interfaz coherente (ventana, barra de menús, ajustes, bienvenida), con el dispositivo dibujado a la izquierda y sus ajustes en una barra lateral a la derecha; ventana de tamaño fijo y panel de vidrio único.

## Archivos
- Nuevos: `Theme.swift` (medidas, `Card`, `SettingRow`, `Segmented`, acento por dispositivo), `DeviceStage.swift`, `DeviceSidebar.swift` (pestañas, tarjetas agrupadas, pintura por tecla), `MouseSimView.swift`, `KeyboardSimView.swift` (simulación de efectos: estático, espectro, ola, respiración, reactivo, starlight, cuadro por tecla), `ButtonsPanel.swift` (reasignación de teclas y botones por dispositivo), `LightingControl.swift` (opciones de iluminación según la definición: colores, velocidad, brillo, dirección, forma de onda), `DPIStagesControl.swift`.
- Reescritos: `MainWindowView` (fija 1020×680), `MenuPanelView` (mismo lenguaje visual), `SettingsView` (barra lateral, fija 880×640), `OnboardingView` (4 pasos: bienvenida, dispositivos detectados, permisos con cámara, listo).
- Modificados: `ControlSpec` (sección `buttons`, tipos `dpiStages` y `keyLighting`, grupos), `AppModel` (selección de tecla/botón, presets DPI, pintura por tecla, igualar iluminación), `WindowGlass` (ventana no redimensionable), `main.swift`, snapshots.

## Lógica
- Pestañas por dispositivo: Iluminación, Botones (ratón y teclado), Rendimiento, Imagen, Avanzado, Detalles.
- La vista previa de la cámara va en el escenario y refleja los cambios UVC en vivo.
- Botones: clic en una parte del dibujo selecciona el botón/tecla; la regla se guarda al instante como regla global (`RemapRule`). El botón DPI del G203 no llega al Mac y se explica en pantalla.
- Presets DPI (hasta 5) se guardan por dispositivo en UserDefaults; "Siguiente" en la barra de menús los recorre.
- Pintura por tecla: `key_lighting` se escribe como `.keyFrame`; arrastrar pinta varias teclas.
- Rendimiento: una sola capa de vidrio (la ventana), tarjetas planas, sliders sin marcas por paso, simulación del teclado con un único `Canvas` y pausa cuando la ventana está inactiva.

## Decisiones y hallazgos
- El teclado del dueño es el Huntsman Mini estándar (USB 1532:0257, cadena "Razer Huntsman Mini", sin interfaz HID analógica). OpenRazer no define comandos de actuación ni rapid trigger y el modelo analógico tiene otro ID (0x0282). No se implementaron controles de recorrido de tecla porque no existe protocolo verificable para este dispositivo.
- No se toca la aceleración del puntero: las API disponibles están obsoletas desde macOS 10.12.
- El Keychain se usa para aprobar macros (M10); sin relación con este cambio.

## Riesgos y pendientes
- Nada se probó en hardware ni se vio en pantalla (el agente no captura la pantalla).
- Las capas de vidrio reales no se ven en los snapshots.
- Iluminación por tecla: la escritura son 5 paquetes más activación (no atómica).

## Pruebas
`swift test` verde; nuevas pruebas en `ModelFeatureTests` y `ControlSpecTests`.
