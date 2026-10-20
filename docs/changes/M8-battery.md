# M8 — Batería (lectura, indicador y avisos)

## Objetivo
Dar soporte a la capability `battery` (solo lectura, SPEC §4): lectura en los drivers Logitech HID++ 2.0 y Razer, indicador en la sección Detalles, refresco periódico y aviso opcional de batería baja.

**Nada de esto se verificó con hardware inalámbrico real**: solo se posee hardware con cable. Todo lo probado usa transportes simulados con los bytes que documentan las fuentes abiertas. Los modelos que ya existen (G203 con cable, Huntsman Mini, Brio) no declaran `battery`, así que no cambia su comportamiento.

## Archivos
- `Sources/MacHIDDomain/Profile.swift`: nuevo caso `SettingValue.battery(percent:charging:)`.
- `Sources/MacHIDLogitech/Hidpp.swift` (ids de feature), `HidppBattery.swift` (decodificadores puros nuevos), `HidppDriver.swift` (`battery`).
- `Sources/MacHIDRazer/RazerCommands.swift`, `RazerDriver.swift`: comandos 0x07/0x80 y 0x07/0x84, `RazerModel.batteryTransactionID`.
- `Sources/MacHIDUI/BatteryBadge.swift`, `BatteryAlerts.swift` (nuevos), `AppModel.swift`, `ControlSpec.swift`, `ControlViews.swift`, `PreviewSupport.swift` (un caso por switch exhaustivo).
- `Sources/machid/main.swift`: un caso en `describe` (el switch es exhaustivo).
- Pruebas: `Tests/MacHIDLogitechTests/HidppBatteryTests.swift`, `Tests/MacHIDRazerTests/RazerBatteryTests.swift`, `Tests/MacHIDUITests/BatteryTests.swift`, y el caso `battery` de `ControlSpecTests.swift`.

## Lógica
**HID++ (fuentes: Solaar `hidpp20.py`/`hidpp20_constants.py` y libratbag `hidpp20.c`, leídos del código, no de memoria).** Se prueba 0x1004, luego 0x1000, luego 0x1001; si ninguna existe se lanza `unsupportedCapability`.
- 0x1004 UNIFIED_BATTERY, función 1 (Solaar pide `0x10`): `[% de carga, flags de nivel, estado, ...]`. Si el % es 0 se usan los flags (8/4/2/1 → 90/50/20/5, aproximaciones de Solaar).
- 0x1000 BATTERY_STATUS, función 0: `[nivel %, siguiente nivel, estado]`; nivel 0 = desconocido.
- 0x1001 BATTERY_VOLTAGE, función 0: `[mV (BE16), flags]`, bit 7 = cargando; el % se estima con la tabla de Solaar (aproximado).
- Estado (0x1000/0x1004): 1, 2 y 4 = cargando; 0 y 3 = no cargando; otro = desconocido (`nil`).

**Razer (OpenRazer `razerchromacommon.c`, `razermouse_driver.c`).** Clase 0x07, comando 0x80 (nivel 0..255 en `arguments[1]`, se convierte a % con la función existente) y 0x84 (cargando 0/1 en `arguments[1]`). El transaction id depende del modelo (0x3F, 0x1F o 0xFF en el driver de OpenRazer): `driver_options.battery_transaction_id`, por defecto 0x3F. Si la consulta de carga falla (modelos con pilas AA) se devuelve el nivel con `charging = nil`.

**UI.** `BatteryBadge` (símbolo battery.0/25/50/75/100percent, rayo al cargar, naranja a ≤15 %, rojo a ≤5 %, etiqueta de accesibilidad). `ControlSpec` mapea `battery` a `.battery` en la sección Detalles. Reglas de visualización en `BatteryDisplay` (puro).

**AppModel.** `batteryPercent(for:)`, `isLowBattery(_:)`, `isCharging(_:)`; `refreshBatteries()` cada 5 minutos (`batteryInterval`) por la misma ruta de control, solo para dispositivos con la capability. Avisos: `BatteryAlertPolicy` (puro) emite 15 % y 5 %, una vez por nivel y ciclo de carga (el ciclo se reinicia al cargar o superar 20 %); si una lectura salta por debajo de ambos solo avisa el 5 %. Se envía únicamente si el usuario activó `lowBatteryAlerts` (UserDefaults, apagado por defecto) y el sistema ya concedió el permiso; nunca se solicita al avisar. `lowBatteryAlertsBinding` activa la opción y solicita el permiso. Las notificaciones están detrás del protocolo `BatteryAlerting` (`UserNotificationBatteryAlerts` es la implementación real).

## Decisiones
- **`SettingValue.battery` en lugar de `.int` + capability `charging`**: una sola lectura devuelve porcentaje y estado de forma atómica (dos lecturas podían ser incoherentes), no hace falta definir una capability extra en cada definición y el estado de carga puede ser `nil` (desconocido). Compatibilidad: se codifica como objeto `{percent, charging}`, que no coincide con `LightingEffect` (requiere `effect`) ni `RGBColor` (requiere `r,g,b`), y se intenta después de ellos y antes del respaldo de texto; los valores antiguos (`Bool`, `Int`, efectos, colores, texto) decodifican igual (hay una prueba). Las baterías no se guardan en perfiles (`isWritable` es falso).
- Un fallo de lectura de batería no muestra banner de error (un dispositivo dormido es normal).
- El dispositivo con cable simplemente no lista la capability: es un dato, no se tocó la definición del G203.
- Se añadió un caso mínimo en `Sources/machid/main.swift` y `PreviewSupport.swift` porque los switch son exhaustivos.

## Riesgos y pendientes
- Sin verificar en hardware inalámbrico: índices de función, interpretación del estado, el transaction id de cada modelo Razer y el comportamiento al estar el dispositivo dormido o detrás de un receptor (el cliente HID++ usa el índice de dispositivo 0xFF, de cable; los receptores Unifying/Lightspeed necesitan el índice de dispositivo del receptor y no están soportados aquí).
- Tabla de voltaje y aproximaciones por flags son estimaciones de Solaar, no valores del fabricante.
- Pendiente de integración (otros agentes): colocar `BatteryBadge` en `MenuPanelView` con `model.batteryPercent(for:)`/`isLowBattery(_:)`, y el interruptor `lowBatteryAlertsBinding` en Ajustes.
- Las notificaciones reales no se probaron (la app no se ejecutó); falta un identificador de bundle firmado para `UNUserNotificationCenter`.

## Pruebas
Ejecutadas (`swift test` con `--scratch-path` fuera del repo): decodificación HID++ por 0x1004/0x1000/0x1001, preferencia entre features, ausencia de feature, bordes de los decodificadores, compatibilidad de Codable; Razer con transaction id por modelo, consulta de carga rechazada y opciones; política de avisos (una vez por nivel/ciclo, carga, salto de niveles, dispositivos independientes); símbolos y umbrales de la insignia; `ControlSpec`. Recomendadas: pruebas con un mouse inalámbrico real (Logitech y Razer) y una notificación real tras firmar la app.
