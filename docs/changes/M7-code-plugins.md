# M7 — Plugins con código (JavaScriptCore en proceso aislado)

## Objetivo
Permitir que un plugin con `"driver": "driver.js"` hable un protocolo nuevo. El JavaScript corre en un proceso separado y con sandbox, y solo llega al dispositivo a través de un broker en la app que aplica los permisos del manifest (SPEC §5.3 y §5.4).

## Archivos
- `Sources/MacHIDPluginHost/main.swift` (nuevo ejecutable): host de JavaScriptCore; JSON por líneas en stdin/stdout.
- `Sources/MacHIDApplication/PluginDriver.swift`: puertos `PluginHostLauncher`/`PluginHostSession`, `PluginBrokerPolicy`, `PluginRateLimiter` y `PluginDriver` (un `DeviceDriver`).
- `Sources/MacHIDSystem/PluginHostProcess.swift`: `SandboxedPluginHostLauncher` (`sandbox-exec`), sesión por pipes e `InstalledPluginCode.lookup`.
- `Sources/MacHIDSystem/SystemDeviceConnector.swift`: familia `plugin:<id>`.
- `PluginInstaller.swift`, `PluginRegistry.swift`, `PluginManifest.swift`: instalación del script, `hasCode`, bloqueo de auto-actualización, validación del manifest.
- `PluginsModel.swift`, `PluginsView.swift`: confirmación explícita; `scripts/make-app.sh` y `sign-app.sh`: incluyen y firman el host; `Package.swift`.
- Pruebas: `Tests/MacHIDSystemTests/PluginDriverTests.swift`, `PluginInstallerTests.swift`. Docs: `docs/PLUGINS.md`.

## Lógica
- Host: expone solo `hid.sendFeature/getFeature/sendOutput/nextInput`, `log` y `sleep`. Cada llamada HID es un viaje de ida y vuelta síncrono a la app. Sin archivos, red, procesos, temporizadores ni módulos (se elimina `WebAssembly`). Tope de script 128 KB, 64 llamadas, 256 bytes por llamada, 4 s por petición; termina al cerrarse stdin. Se lanza con `JSC_useJIT=false`.
- Broker (`PluginDriver`): lanza un host nuevo por lectura o escritura, envía el script y atiende las llamadas. Antes de cada una exige transporte HID, `report_ids` (vacío o ausente = ninguno), clase de escritura (`none` prohíbe todo envío), tamaño y tasa (200 llamadas y 50 escrituras por segundo). Cualquier violación, timeout o error de protocolo mata el host y devuelve `DriverError`. Las lecturas de entrada solo entregan report IDs declarados, así que un plugin no ve eventos de teclado.
- Sandbox: `/usr/bin/sandbox-exec -p` con `(deny default)`; solo se permite ejecutar el host y leer `/usr/lib`, `/System/Library`, `/System/Cryptexes`, el propio binario y `/dev/{null,urandom,random}`. Sin escritura, red ni mach-lookup. Si falta `sandbox-exec` o el host, falla (sin ejecución fuera del sandbox).
- Instalador: copia el script como `driver.js` (archivo regular, ≤128 KB, UTF-8, sin NUL), guarda `hasCode: true` (JSON antiguo sigue decodificando) y exige que las definiciones usen `plugin:<id>`. Sin confirmación (`allowCode`) lanza `codeNeedsConfirmation` con tamaño y SHA-256. `autoUpdateBlocker` siempre bloquea plugins con código.
- Conector: la interfaz HID se elige por `driver_options.feature_report_size` u `output_report_size`.

## Decisiones
- Proceso por petición: más simple y limpio ante fallos, a costa de latencia (decenas de ms).
- `sandbox-exec` está en desuso oficialmente, pero es lo que permite un perfil deny-default sin empaquetar un XPC; si Apple lo retira, el plugin falla cerrado.
- La confirmación en la UI aparece cuando el instalador descubre el código (el registro no declara `hasCode`).

## Riesgos y pendientes
- No probado con hardware real ni con Input Monitoring. `interfaces` del manifest no se hace cumplir: IOKit elige la interfaz por tamaño de reporte, así que un plugin podría declarar un tamaño que coincida con una interfaz de teclado; el filtro por report ID mitiga pero no lo cierra del todo (revisar en la revisión del plugin).
- JIT desactivado: más lento, menos superficie; con hardened runtime habría que decidir sobre `allow-jit`.
- Un bucle infinito en JS se corta solo por el timeout de la app (mata el proceso); no hay watchdog interno.
- La denegación de red no se demostró de forma concluyente con `curl` (falló antes por configuración); la de archivos sí (ver pruebas).

## Pruebas
Ejecutadas: política del broker (ids, `writes: none`, tamaño, uvc, input sin ids), host simulado (violación mata el host sin tocar el dispositivo, host mudo), limitador de tasa, host real bajo `sandbox-exec` (lectura/escritura vía broker, ausencia de `require/fetch/setTimeout/...`, report id no autorizado, bucle infinito con timeout), instalador (script instalado, NUL/tamaño/ausente, plugin de datos no puede reclamar `plugin:`), auto-actualización bloqueada y compatibilidad de `installed.json`. Experimento manual: bajo el mismo perfil, `cat /etc/hosts`, `cat ~/.zshrc` y `ls ~` fallan con "Operation not permitted". Recomendadas: prueba con un dispositivo real y revisión de seguridad del perfil.
