# MacHID — Especificación v1

Estado: borrador para aprobación · Licencia: GPLv3 · Plataforma: macOS 14+ (Apple Silicon) · Lenguaje: Swift

## 1. Objetivo

Hub universal y open source para gestionar periféricos (mouse, teclado, cámara y otros) en macOS sin depender del software del fabricante. El núcleo no conoce marcas. Las marcas se añaden con **plugins** (definiciones de datos y, opcionalmente, drivers de código en sandbox) distribuidos desde un registro público al estilo AUR.

Dispositivos de referencia del autor (detectados por `ioreg`):

| Dispositivo | VID:PID | Familia de protocolo | Estado de investigación |
|---|---|---|---|
| Razer Huntsman Mini | `1532:0257` | Razer (reportes de feature, matriz RGB) | Hay referencia abierta (OpenRazer); verificar compatibilidad de licencia (§12) |
| Logitech G203 LIGHTSYNC | `046d:c092` | Logitech G-series (por verificar si es HID++ o propio) | Por investigar |
| Logitech Brio 100 | `046d:094c` | UVC (cámara) | API estándar de macOS |

Ninguno es inalámbrico, así que la batería es una capability soportada por el modelo pero sin dispositivo de prueba en v1.

## 2. Alcance v1

Incluido:
- Enumeración y detección automática de dispositivos (conexión y desconexión en caliente).
- Capabilities comunes: DPI, polling rate, iluminación (zonas, colores, efectos), brillo, perfiles, información (firmware, nombre, VID:PID), batería (solo lectura).
- Remapeo por software de botones y teclas.
- Macros: teclas, clics, esperas, abrir apps/URLs/Atajos y **scripts de shell** (con salvaguardas, §9).
- Perfiles automáticos (por app activa y por conexión de dispositivo).
- Controles de cámara UVC (zoom, brillo, contraste, etc., según lo que exponga el dispositivo).
- Sistema de plugins completo: formato, sandbox, registro, descubrimiento, instalación y envío. Sin plugins de terceros todavía; solo los drivers incluidos en el repo.
- App de barra de menú con ventana, CLI `machid` y reaplicación de perfiles al conectar.
- Auto-actualización de la app y de la lista de plugins (`plugins.json`) basada en GitHub Releases (§15).
- CI/CD con GitHub Actions: build, pruebas y release en cada commit a `master` (§16).

Fuera de v1: Linux/Windows, escritura de memoria onboard y firmware (ver §9), plugins de terceros con código sin revisión.

## 3. Arquitectura (hexagonal)

```
┌────────────────────────── Interfaces ──────────────────────────┐
│  MacHID.app (SwiftUI, menu bar)     machid CLI                 │
└───────────────┬───────────────────────────┬────────────────────┘
                │ casos de uso              │ XPC / Mach service
┌───────────────▼───────────────────────────▼────────────────────┐
│ Application: DeviceManager, ProfileService, RemapEngine,        │
│              MacroEngine, AutoSwitcher, PluginService           │
├─────────────────────────────────────────────────────────────────┤
│ Domain (sin frameworks): Device, Capability, Profile, Binding,  │
│   Macro, DeviceDefinition, puertos (protocolos Swift)           │
├─────────────────────────────────────────────────────────────────┤
│ Infrastructure (adaptadores):                                   │
│   HIDTransport (IOHIDManager)   UVCTransport (AVFoundation/IOKit)│
│   EventTap (CGEventTap)         ProfileStore (JSON en disco)    │
│   PluginSandbox (XPC + JSC)     RegistryClient (git/HTTPS)      │
│   Drivers incluidos: razer, logitech-gseries/hidpp, uvc         │
└─────────────────────────────────────────────────────────────────┘
```

Reglas: el dominio no importa IOKit, AppKit ni SwiftUI. Los puertos clave son `Transport`, `DeviceDriver`, `ProfileRepository`, `PluginRegistry` y `EventSink`. Todo lo que toca hardware se puede simular con un transporte falso en las pruebas.

Estructura de paquete Swift (SPM):

```
MacHID/
  Sources/
    MacHIDDomain/   MacHIDApplication/
    Adapters/{HID,UVC,EventTap,Storage,Plugins,Registry}/
    Drivers/{Razer,LogitechGSeries,UVC}/
    App/   CLI/   PluginHost/   (helper XPC sandboxed)
  Definitions/        (JSON de dispositivos incluidos + SVG)
  Schemas/            (JSON Schema: capability, device, manifest, plugins.json)
  Tests/
  docs/
```

## 4. Modelo de capabilities (contrato núcleo ↔ UI ↔ plugin)

Cada capability tiene `id`, `type`, `access` (`read` | `write_volatile` | `write_persistent`), restricciones y metadatos de UI.

| type | parámetros | widget |
|---|---|---|
| `dpi` | etapas, min/max/step | slider + lista de etapas |
| `polling_rate` | enum (125/500/1000...) | menú |
| `lighting_zone` | zonas, modos, efectos, soporte por tecla | selector de color / efectos / matriz |
| `brightness` | 0-100 | slider |
| `button_remap` | botones y acciones permitidas | clic en hotspot |
| `key_remap` | layout y teclas | teclado visual |
| `macro_slots` | límite | editor de macros |
| `profile_slots` | cantidad, onboard/software | selector |
| `battery` | solo lectura | indicador |
| `info` | firmware, serial, etc. | texto |
| `camera_control` | por control UVC: zoom, brillo, contraste, nitidez, balance de blancos, enfoque | sliders / toggles |

La UI se genera desde las capabilities. Lo no soportado se muestra deshabilitado, nunca oculto. Los dispositivos sin ilustración usan una silueta genérica y una lista de capabilities.

Capas de remapeo:
1. **Onboard** (si el driver lo expone): se escribe al dispositivo, requiere confirmación (§9).
2. **Software** (siempre disponible): `CGEventTap` en el motor, con permisos de Input Monitoring y Accessibility.

## 5. Plugins

### 5.1 Unidades
- **Definición de dispositivo** (datos): JSON validado contra JSON Schema. Declara VID:PID, driver, capabilities, límites, layout y SVG con hotspots. Nunca ejecuta código.
- **Driver** (código): implementa el contrato `DeviceDriver` (identificar, leer capabilities, leer/escribir valores) para una **familia de protocolo**, no por dispositivo ni por marca.
- Un **plugin** es un repo git con `manifest.json` y una o más definiciones y, opcionalmente, drivers.

### 5.2 Manifest
Campos: `id`, `name`, `version` (semver), `license` (obligatoria, compatible con GPLv3), `author`, `core_api` (rango mínimo/máximo), `devices[]` (VID:PID), `driver` (opcional, archivo de entrada), `permissions` (ver 5.4) y `capabilities` que expone.

### 5.3 Runtime del driver con código
Elección propuesta (a confirmar): drivers externos son **scripts JavaScript ejecutados con JavaScriptCore dentro de un helper XPC con App Sandbox**. Razones: JSC viene con macOS, no hay compilación en la máquina del usuario, el sandbox es por diseño y encaja con la distribución desde código fuente tipo AUR.

Modelo broker:
- El driver **no abre HID**. El host (proceso principal) abre el dispositivo y entrega al driver una API mínima: `sendFeatureReport`, `sendOutputReport`, `readReport`, con timeouts.
- El host impone, según el manifest aprobado por el usuario: interfaces y usage pages permitidas, report IDs permitidos, clase de escritura (volátil / persistente) y límite de tasa.
- El driver **nunca** accede a la interfaz de entrada del teclado ni a eventos de teclas. El remapeo y las macros viven en el motor del núcleo, no en plugins.
- Sin red, sin sistema de archivos y sin spawn de procesos dentro del helper.
- Los drivers incluidos en el repo (Razer, Logitech, UVC) son Swift nativos y usan los mismos puertos.

### 5.4 Permisos declarados
`transport` (hid | uvc), `interfaces`, `report_ids`, `writes` (volatile | persistent). El usuario ve y aprueba esta lista al instalar. Un cambio de permisos en una actualización exige nueva aprobación.

## 6. Registro y descubrimiento (estilo AUR)

- El repo principal contiene `plugins.json`: lista de plugins, cada uno con `id`, `repo` (URL git), `ref` (commit SHA fijado), `sha256` del árbol del manifest, VID:PID soportados, categoría, `core_api` y nivel de revisión.
- **Envío**: se abre un PR a `plugins.json` (la app puede generar la entrada y abrir el PR preparado). CI valida el schema, el manifest, la licencia, los VID:PID y corre linters de seguridad.
- **Niveles de confianza**: `reviewed` (un mantenedor revisó el código del commit fijado) y `community` (sin revisión; la app muestra advertencia explícita y pide confirmación).
- **Instalación**: la app clona el repo al commit fijado, verifica hashes, muestra permisos y, si hay código, el diff respecto de la versión instalada al actualizar. Nunca se actualiza en silencio.
- **Descubrimiento en la app**: búsqueda por texto, filtros por marca y categoría, y **autodetección**: se ordenan los plugins que coinciden con los VID:PID conectados y se propone el mejor (más específico, `reviewed`, versión compatible).
- `machid plugin search|install|update|remove|list`.
- Copia local del índice con caché; las fallas de red no rompen la app.

## 7. App y daemon

- Una sola app `MacHID.app` con `LSUIElement = true`: vive en la barra de menú, sin Dock.
- Ventana principal (SwiftUI) abrible desde el icono de menú y también al lanzar la app desde Spotlight (Cmd+Espacio): el manejo de reopen debe mostrar la ventana de la instancia ya corriendo.
- Arranque al iniciar sesión con `SMAppService`.
- El motor (detección, perfiles, remapeo, macros) corre en el proceso de la app. El CLI `machid` habla con él por un servicio Mach/XPC. Si más adelante hace falta un daemon separado, el motor ya es una librería.
- Permisos que se piden de forma guiada: Input Monitoring y Accessibility (remapeo), acceso a cámara solo si el control UVC lo requiere.
- Firma Developer ID y notarización. Distribución por DMG y cask de Homebrew.

## 8. Perfiles

- Se guardan en `~/Library/Application Support/MacHID/` como JSON versionado y con `schemaVersion`. Exportables e importables, sin datos personales.
- Un perfil contiene valores de capabilities por dispositivo, bindings de remapeo, macros y reglas.
- **Perfiles automáticos**: reglas por app en primer plano (bundle ID), por conexión/desconexión de dispositivo y por perfil por defecto. Con prioridad explícita y sin conflictos silenciosos.
- La fuente de verdad es el hub: lo aplicado al dispositivo se puede reconstruir tras un reset.
- Los cambios volátiles se aplican en vivo. Lo persistente requiere "Guardar en dispositivo" explícito.

## 9. Seguridad y seguridad de hardware

- Fase de escritura gradual: solo lectura → volátil → persistente. **Prohibido en v1**: escritura de firmware y flasheo. Escrituras persistentes (memoria onboard) solo con confirmación y respaldo previo cuando sea posible.
- El keylogging es la amenaza principal: el broker (§5.3) impide que un plugin vea eventos de teclado; el tap de eventos es exclusivo del núcleo. El tap no registra contenido de teclas en logs.
- Macros con shell (decisión del autor): se ejecutan con los privilegios del usuario, sin sandbox. Salvaguardas obligatorias: (1) los plugins nunca pueden definir ni disparar macros; (2) una macro con shell, apps o URLs importada o recibida en un perfil compartido llega **deshabilitada** y se activa solo tras mostrar el comando completo y confirmar; (3) editar el comando de una macro ya aprobada vuelve a exigir confirmación; (4) sin `sudo`/elevación; (5) tiempo máximo y límite de salida; (6) registro de ejecuciones (macro, hora, código de salida) sin guardar argumentos sensibles; (7) interruptor global "desactivar macros con shell". Los perfiles exportados marcan estas macros de forma visible.
- Registro y plugins: SHA fijado, verificación de hash, validación estricta de JSON/SVG (el SVG no puede incluir scripts ni recursos externos), sin ejecución de código de definiciones.
- Logs sin información sensible (sin contenido de teclas ni números de serie completos).
- Para el cumplimiento del proyecto: validación de entradas, manejo seguro de errores, sin secretos en el repo y una política de divulgación de vulnerabilidades (`SECURITY.md`).

## 10. Cámara UVC

Categoría de dispositivo con driver nativo `UVC`. Los controles se leen desde lo que reporta el propio dispositivo (no se asume nada del Brio 100 más allá de lo que anuncie). Los valores se aplican en vivo y se guardan en perfiles. Los límites del dispositivo (por ejemplo, sin enfoque automático) se reflejan como capabilities deshabilitadas.

## 11. Pruebas

- Unitarias: dominio (capabilities, perfiles, reglas de auto-switch, resolución de conflictos), validación de manifests/schema, resolución de plugins por VID:PID.
- Con transporte simulado: drivers Razer y Logitech contra reportes grabados; el broker (permisos, report IDs, rate limit).
- Integración manual guiada en tus tres dispositivos con checklist (solo lectura primero).
- CI: SPM build y tests en macOS, validación de `plugins.json`.
- Seguridad: pruebas del sandbox del helper (intentos de acceso a red, archivos y a interfaces no permitidas deben fallar).

## 12. Riesgos y supuestos pendientes

- **Licencias**: GPLv3 permite portar código GPL compatible, pero OpenRazer (parte del controlador es GPL-2.0) y libratbag (MIT) deben revisarse. Si una pieza es "GPLv2 only", no se puede copiar a un proyecto GPLv3; en ese caso se usa solo como referencia documental. Revisar caso por caso y registrarlo en `docs/LICENSES.md`.
- **G203 Lightsync**: el protocolo exacto no está confirmado (HID++ vs. propio). Hay que confirmar con documentación abierta antes de escribir el driver.
- **Razer en macOS**: algunos reportes pueden requerir comportamiento específico de IOKit (interfaz de control); se valida en el hito del teclado.
- **Input Monitoring y Accessibility** dependen de la firma de la app; durante el desarrollo los permisos se pierden al cambiar de firma.
- **JSC como runtime**: suposición a validar con un prototipo antes de congelar el contrato de plugins.
- Marca: la app, la UI y el repo no usan nombres ni logos de fabricantes más allá de descripciones factuales de compatibilidad.
- Colisión de nombre `machid` (GitHub, Homebrew, SPM): pendiente de verificar.

## 13. Hitos

| # | Hito | Resultado |
|---|---|---|
| M0 | Esqueleto SPM, dominio, schemas | Compila, tests de dominio, CI |
| M1 | HIDTransport + CLI `machid list/info` | Enumera los 3 dispositivos, lee información, solo lectura |
| M2 | Driver Razer (Huntsman Mini) | Lee estado, aplica color/brillo/efectos volátiles |
| M3 | Driver Logitech G203 y UVC (Brio 100) | DPI, color; controles de cámara |
| M4 | App de barra de menú + ventana generada por capabilities | UI de Liquid Glass (§19) con SVG/hotspots, fallback y panel de menú |
| M5 | Perfiles, auto-switch, remapeo por software, macros | Perfiles reaplicados al conectar |
| M6 | Plugins: manifest, broker, helper JSC, registro, descubrimiento | Instalar/enviar plugins con autodetección |
| M0b | Workflows de GitHub Actions (ci.yml, release.yml, registry.yml) | PRs validados; cada push a `master` genera release (desde M1, artefacto aunque sea solo CLI) |
| M6b | Auto-actualización de app (Sparkle) y del índice de plugins | Actualizaciones verificadas desde GitHub Releases |
| M7 | Firma, notarización, DMG, cask, documentación | Release 0.1 |

Cada hito deja su `.md` de cambios en `docs/changes/` (objetivo, archivos, lógica, decisiones, riesgos, pruebas).

## 14. Decisiones abiertas (a confirmar)

1. Runtime de drivers externos: JavaScriptCore (propuesto) vs. otra opción.
2. Nombre del repo de registro y organización en GitHub.
3. Qué campos de `plugins.json` firma el equipo (SHA del commit únicamente, o también firma del índice).
4. ~~Política de macros~~ Resuelta: incluye shell con las salvaguardas de §9.
5. ~~Cuenta de Apple Developer~~ Resuelta: disponible.
6. Colector de telemetría opt-in (§18): ¿Sentry autoalojado, endpoint propio o informes que el usuario envía manualmente?

## 15. Auto-actualización (v1)

### 15.1 App
- Motor: **Sparkle 2** (licencia MIT, compatible con GPLv3), con actualizaciones en segundo plano, verificación de firma EdDSA y de firma Developer ID.
- Fuente: **GitHub Releases** del repo. Cada release publica `MacHID-<versión>.dmg` (y zip para Sparkle) y un `appcast.xml` generado por el workflow y servido como asset de la última release (o desde GitHub Pages si Sparkle necesita URL estable).
- La clave privada EdDSA vive solo en secretos de GitHub Actions; la pública va embebida en `Info.plist` (`SUPublicEDKey`). Sin firma válida, no se instala.
- Comportamiento: comprobación al iniciar y cada 24 h; opciones en la app: automático / avisar / manual; botón "Buscar actualizaciones". Solo canal estable en v1 (las pre-releases quedan fuera del appcast).
- Seguridad: solo HTTPS, sin downgrade (la versión debe ser mayor), la app no actualiza mientras se aplica un perfil o hay una escritura persistente en curso.

### 15.2 `plugins.json` (registro)
- Cada cambio mergeado a `plugins.json` publica una **release del registro** (`registry-<fecha>-<sha>`) con `plugins.json` y `plugins.json.sig` (firma Ed25519 de la clave del proyecto, distinta de la de Sparkle; la pública va embebida en la app).
- La app consulta la última release del registro (API de GitHub con ETag/If-None-Match para no gastar límite), verifica la firma y el `schemaVersion`, y reemplaza la copia local de forma atómica. Si falla algo, conserva la copia previa.
- Frecuencia: al iniciar y cada 6 h; sin datos personales en las peticiones.
- Entradas con `ref` fijado a SHA: refrescar el índice **no** instala nada.

### 15.3 Plugins instalados
- Detectar versiones nuevas al refrescar el índice.
- Plugins solo de datos (definiciones): se actualizan automáticamente si son `reviewed`, pasan validación de schema y no cambian permisos.
- Plugins con código, o con cambios de permisos, o `community`: **nunca en silencio**. La app notifica, muestra el diff y pide aprobación. (Esta regla se mantiene aunque el resto sea automático, por la amenaza de keylogger de §9.)
- Rollback a la versión anterior disponible desde la ventana.

## 16. CI/CD con GitHub Actions

Runners: `macos-15` o el más reciente con Xcode compatible con macOS 14+ como destino. Acciones fijadas por SHA de commit.

### 16.1 `ci.yml` (pull requests y push a ramas)
1. `swift build` y `swift test`.
2. Validación de schemas: `Definitions/`, manifests de ejemplo y `plugins.json` contra JSON Schema, incluyendo reglas (licencia presente, VID:PID válidos, `ref` es SHA de 40 caracteres, URL permitida).
3. Linter de SVG (sin scripts ni recursos externos).
4. Análisis de dependencias y secretos (por ejemplo `gitleaks`).

### 16.2 `release.yml` (push a `master`)
Cada commit a `master` produce una release.
1. **Versión**: `VERSION` en el repo define `MAJOR.MINOR`; el parche es el número de commits (o de la ejecución) y se crea el tag `v<MAJOR.MINOR.PATCH>`. Los commits que solo tocan `docs/` o `plugins.json` se excluyen con `paths-ignore` (el registro tiene su propio workflow).
2. Build de release de la app (universal solo si hace falta; Apple Silicon por defecto) y del CLI.
3. Firma con Developer ID desde un keychain temporal creado con secretos; **notarización** con `notarytool` y *stapling*.
4. Empaquetado: DMG y zip firmados.
5. Firma Sparkle (EdDSA) y generación de `appcast.xml`.
6. Creación de la GitHub Release con los assets y notas generadas desde los commits.
7. Actualización del cask de Homebrew (PR o push al repo del tap) con el nuevo SHA256.
8. Concurrencia: un solo release a la vez (`concurrency` con cola, sin cancelar los releases en curso).

Secretos necesarios: certificado Developer ID (p12 + contraseña), credenciales de notarización (clave API de App Store Connect), clave EdDSA de Sparkle, token para el tap. Se guardan como *environment secrets* en un entorno `release` protegido, y los workflows de PRs de forks nunca los reciben.

### 16.3 `registry.yml` (cambios en `plugins.json`)
1. Valida schema y reglas, y verifica que cada `ref` exista en el repo del plugin y que el hash coincida.
2. Si es un push a `master`: firma el índice con la clave del registro y publica la release `registry-<fecha>-<sha>`.
3. En PRs: comenta el resultado de la validación y los permisos declarados para la revisión humana.

### 16.4 Reglas del repo
- `master` protegida: PR obligatorio, CI verde, al menos una aprobación; los cambios a `plugins.json` con revisión CODEOWNERS.
- Permisos mínimos de `GITHUB_TOKEN` por workflow (`contents: write` solo en release).
- Build reproducible en lo posible; los artefactos incluyen checksums SHA256.

## 17. Riesgos y supuestos añadidos

- **Release por cada commit**: genera muchas versiones y notificaciones. Mitigación: excluir cambios de docs/registro y permitir ajustar la cadencia (por ejemplo, solo commits que cambian código).
- **Gestión de claves**: la pérdida de la clave EdDSA de Sparkle o del registro impide actualizar. Se debe documentar respaldo y rotación en `docs/RELEASE.md`.
- **Límites de la API de GitHub**: se mitigan con ETag y caché local.
- La firma y notarización usan la cuenta de Apple Developer del autor; los secretos van al entorno `release` (§16.2).
- El auto-update de plugins con código queda con aprobación manual por diseño (§15.3), lo cual limita "totalmente automático" a propósito.

## 18. Localización y telemetría

### 18.1 Localización
- Inglés como idioma base. Infraestructura de localización completa desde M4: String Catalogs (`.xcstrings`), sin textos fijos en el código, formatos de fecha/número por *locale*, y soporte de texto más largo en los layouts.
- Los textos de plugins (nombres de capabilities, de zonas) permiten un mapa `i18n` opcional por idioma, con fallback a inglés.
- Otros idiomas se añaden después como contribuciones; CI falla si falta una clave en el idioma base.

### 18.2 Telemetría y reporte de fallos (opt-in)
- **Desactivada por defecto**; se pregunta una vez en el primer arranque y se puede cambiar en Ajustes.
- Contenido permitido: versión de la app y de macOS, arquitectura, trazas de fallos, versiones de plugins instalados y errores de drivers. VID:PID solo como dato de compatibilidad.
- Nunca: contenido de teclas o macros, comandos de shell, rutas con nombre de usuario, números de serie, IPs persistentes ni identificadores del usuario.
- Antes de enviar, "Ver qué se envía". Identificador de instalación aleatorio y reiniciable.
- El colector es una decisión abierta (nº 6). Aparte, "Exportar diagnóstico" produce un archivo local redactado que el usuario puede adjuntar a un issue.
- La política de privacidad se publica en el repo (`docs/PRIVACY.md`) y el opt-in queda sin efecto hasta que exista.

## 19. Diseño de interfaz

### 19.1 Principios
- **Liquid Glass** como lenguaje visual (`glassEffect`, `GlassEffectContainer` y barras/controles con el estilo del sistema en macOS 26+). Fondo con translucidez y el dispositivo como protagonista.
- **Pocos paneles, casi sin líneas**: nada de sidebars con bordes, tablas ni separadores duros. Los elementos flotan sobre la ventana, agrupados por espacio en blanco, tamaño y jerarquía tipográfica.
- El dispositivo se muestra grande y centrado (SVG con hotspots). Los controles aparecen como **píldoras de cristal flotantes** alrededor del dispositivo y se despliegan al tocar un hotspot (botón, tecla, zona de luz), con animaciones de *morph* entre estados.
- Una sola vista principal: dispositivo y sus ajustes. El resto (plugins, perfiles, macros, ajustes) se abre como **hojas flotantes** de cristal sobre la misma ventana, sin navegación profunda.
- Tipografía del sistema (SF), mucho aire, un color de acento que toma el color de iluminación actual del dispositivo.
- Accesibilidad: respeta "Reducir transparencia" y "Aumentar contraste" (fondos sólidos con el mismo diseño), Dynamic Type donde aplique, VoiceOver en hotspots, navegación completa por teclado y modo claro/oscuro.

### 19.2 Compatibilidad
Liquid Glass requiere macOS 26+; el mínimo del proyecto es macOS 14. Decisión de diseño: en macOS 14-25 la misma UI usa `Material` (`.ultraThinMaterial`/`.regularMaterial`) detrás de una capa de abstracción `GlassSurface` propia, de modo que ningún componente llame a la API de glass directamente. Una prueba de snapshots cubre ambos caminos.

### 19.3 Ventana principal
```
┌──────────────────────────────────────────────┐
│  ◂ G203 LIGHTSYNC ▾            profile: Work ▾ │  ← píldoras flotantes
│                                                │
│            [ ilustración del dispositivo ]     │  ← protagonista, hotspots
│       (DPI)        (Lighting)      (Buttons)   │  ← chips de cristal
│                                                │
│     ───────────  panel contextual flotante     │
│     slider / selector de color / remap         │
└──────────────────────────────────────────────┘
```
- Selector de dispositivo y de perfil como píldoras en la parte superior; cambiar de dispositivo hace una transición *morph* de la ilustración.
- Los chips inferiores se generan desde las capabilities (§4); lo no soportado aparece atenuado, no oculto.
- Iluminación: vista previa en vivo sobre el SVG y selector de color flotante; para teclados, la matriz por tecla se edita directamente sobre el teclado.
- Estado vacío: ilustración genérica y mensaje para buscar un plugin con autodetección (§6).
- La ventana se abre con la app desde Spotlight o desde el icono de menú (§7); recuerda posición y tamaño.

### 19.4 Icono de la barra de menú
Panel de cristal compacto (no un menú de texto clásico), con:
1. **Dispositivos conectados** (icono + nombre + estado) y, por cada uno, un **selector rápido de perfil** (cambio por dispositivo).
2. **Perfil global** y botón de pausa de perfiles automáticos.
3. **Controles rápidos por dispositivo**: DPI (ciclo entre etapas), brillo de iluminación, apagar/encender luces, y para cámaras un interruptor de espejo/zoom según capabilities.
4. **Macros favoritas** (fijadas por el usuario) y el interruptor global de "macros con shell".
5. **Estado**: batería cuando exista, avisos de permisos que faltan (Input Monitoring/Accessibility) con botón para resolverlos.
6. **Actualizaciones**: indicador cuando hay una nueva versión de la app o de plugins, con acción directa.
7. Pie: "Open MacHID…", "Plugins…", "Settings…", "Quit".
- El icono es monocromo (template) y cambia sutilmente según el estado: dispositivo conectado, perfiles pausados, actualización disponible.
- Atajos de teclado globales opcionales (configurables y sin valor por defecto): ciclar perfil, ciclar DPI, abrir la ventana.
- Clic derecho: menú mínimo (pausar, abrir ajustes, salir).

### 19.5 Activos
- Ilustraciones SVG de dispositivos dibujadas por la comunidad y por el proyecto (nunca fotos o renders de fabricantes), con colores de acento por tema y hotspots nombrados.
- Silueta genérica por categoría (mouse, teclado, cámara, auriculares) como fallback.
- Los SVG se renderizan con un parser propio restringido (sin scripts, sin recursos externos, §9).

### 19.6 Pruebas de UI
- Snapshots de las vistas principales en claro/oscuro, con "Reducir transparencia" y con cada camino (Liquid Glass y Material).
- Pruebas de accesibilidad automáticas más una revisión manual con VoiceOver.

## 20. Estado de implementación (actualizado)

| Área | Estado |
|---|---|
| Dominio, puertos, definiciones, esquemas | Hecho |
| Drivers: Razer (efectos, brillo, modo driver), Logitech HID++ 2.0 (DPI, luces, sondeo), UVC (imagen y exposición) | Hecho; probado en hardware: lecturas, DPI, brillo, color/modo driver (Razer) y luces del G203. Sin probar en hardware: efectos nuevos, sondeo y exposición |
| App de barra de menú y ventana (Liquid Glass con alternativa), dibujos SVG con puntos activos | Hecho; revisión visual hecha por el usuario en M4 |
| Perfiles, reglas por app, reaplicar al conectar, pausa | Hecho (probado con simulados) |
| Remapeo y macros con aprobación | Hecho; **tap de eventos sin probar con eventos reales** |
| Plugins solo de datos, registro firmado, autodetección, actualizaciones | Hecho; sin probar contra un registro real (faltan las claves) |
| Plugins con código (JavaScriptCore aislado) | En desarrollo |
| Auto-actualización de la app (Sparkle) y workflows de release | Hecho; sin ejecutar con secretos |
| Telemetría opt-in | Pendiente: solo exportación local de diagnóstico; el colector sigue sin decidirse |
| Batería | En desarrollo (sin hardware inalámbrico para probar) |

### Límites conocidos y aceptados (resultado de la revisión de seguridad)
- La aprobación de una macro es un SHA-256 guardado junto a la macro, sin secreto: un proceso del mismo usuario puede escribir una macro y su huella. Es una limitación honesta de la fase actual (mitigación futura: HMAC con clave en el llavero).
- `ElevationGuard` es orientativo; el control real es que el usuario lea el comando completo al aprobar.
- Un registro de plugins válido y firmado pero antiguo se rechaza por número de secuencia y fecha de emisión (los añade el workflow al publicar); no hay protección si el atacante controla además la caché local.
- La confianza en el registro equivale al acceso de escritura al repositorio más la configuración del entorno `release` en GitHub (revisores requeridos y restricción de ramas: configurar).
- Los permisos declarados por un plugin de datos se muestran al usuario pero no se aplican a los drivers incluidos: un plugin puede asociar un driver a cualquier USB ID que declare su manifest.
