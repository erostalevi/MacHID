# M4 — App de barra de menú y ventana principal (Liquid Glass)

## Objetivo
La primera versión usable de la interfaz según SPEC §19: icono en la barra de menú (sin Dock) con panel rápido, ventana principal generada desde las capabilities, y diseño con Liquid Glass con alternativa para macOS 14-25.

## Archivos
- `Sources/MacHIDUI/` (biblioteca, con la lógica probable):
  - `ControlSpec.swift`: traduce cada capability a un control (slider, interruptor, selector, color, control del host, texto) y a una sección. La UI nunca se escribe por dispositivo.
  - `AppModel.swift`: estado observable. Detecta conexión/desconexión por sondeo cada 2 s, lee los valores al aparecer un dispositivo, agrupa los cambios de un slider en una sola escritura (150 ms), gestiona perfiles y el permiso.
  - `GlassSurface.swift`: **único** lugar que conoce la API de cristal: Liquid Glass en macOS 26+, material del sistema en macOS 14-25, superficie opaca con "Reducir transparencia".
  - `MainWindowView.swift`, `ControlViews.swift`, `DeviceArt.swift`, `MenuPanelView.swift`, `Titles.swift`, `PermissionActions.swift`, `AppEnvironment.swift`.
- `Sources/MacHIDApp/main.swift`: `MenuBarExtra` + `Window`, política de activación `.accessory`, reapertura de la ventana al lanzar la app de nuevo (Spotlight).
- `Sources/MacHIDSystem/`: `SystemDeviceConnector` (movido desde el CLI, ahora compartido) y `FileProfileRepository` (JSON atómico en Application Support).
- `Sources/MacHIDIOKit/InputMonitoringPermission.swift`.
- `scripts/make-app.sh`: arma `MacHID.app` (Info.plist con `LSUIElement`, definiciones y cadenas dentro del bundle, firma ad hoc o Developer ID).
- `Resources/Localizable.xcstrings`: inglés como clave y español como primera traducción.
- Dominio: `DeviceDriver.limits` (rangos que solo conoce el dispositivo, implementado para UVC), `Profile: Identifiable`. Definición del Brio con conjuntos de valores para interruptores y frecuencia de red.
- Pruebas nuevas: `ControlSpecTests` (6) y `AppModelTests` (7), con enumerador y driver simulados.

## Diseño implementado
- Ventana: dispositivo al centro (silueta por categoría teñida con el color de la luz), píldoras de cristal arriba (dispositivo y perfil), fichas por sección y una tarjeta flotante con los controles, sin paneles con borde. Un perfil se guarda con "+" y se aplica desde su menú.
- Panel de la barra de menú: dispositivos conectados, selector de perfil por dispositivo, brillo/DPI al alcance, aviso de Input Monitoring, "Abrir MacHID…" y "Salir".
- Aparecen deshabilitados los controles de solo lectura; los perfiles no guardan el modo host ni lecturas.

## Decisiones
- Un perfil guarda los valores de un modelo de dispositivo; "Mantener control" (device_mode) no se guarda para no dejar el dispositivo reclamado sin querer.
- El nombre del paquete `MacHIDApp` evita chocar con el binario `machid` (el sistema de archivos no distingue mayúsculas); el ejecutable dentro del bundle se llama `MacHID`.
- Identificador del bundle provisional: `app.machid.MacHID`.

## Pendiente y riesgos
- **No verificado visualmente**: la app se compiló, se empaquetó, firmó y arrancó (el proceso sigue vivo sin errores en el registro), pero la captura de pantalla solo mostraba otra aplicación a pantalla completa, así que no se inspeccionó el aspecto ni el comportamiento de ventana y panel. Hace falta una revisión visual del usuario.
- La app es una identidad nueva para macOS: hay que concederle Input Monitoring por separado de Terminal.
- Cada escritura abre el dispositivo de nuevo (el conector crea el transporte por operación). Aceptable para sliders con agrupación, pero conviene una sesión persistente por dispositivo.
- Faltan: arte SVG con puntos activos por dispositivo (solo siluetas genéricas), inicio al iniciar sesión (`SMAppService`), actualizaciones con Sparkle, perfiles automáticos por app, remapeo y macros (M5), plugins (M6).
- Sondeo cada 2 s en lugar de notificaciones de IOKit: simple pero con latencia.

## Pruebas
- Ejecutadas: suite completa pasa (UI 13, UVC 15, HID++ 34, Razer 19, dominio 17, aplicación 11); `scripts/make-app.sh` construye y firma el bundle.
- Pendiente: revisión visual en claro/oscuro y con "Reducir transparencia"; pruebas de instantáneas.
