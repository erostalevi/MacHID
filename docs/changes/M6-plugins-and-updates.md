# M6 — Plugins, registry y auto-actualización

## Objetivo
Sistema de plugins con descubrimiento y autodetección (SPEC §5-6) y auto-actualización de la app (SPEC §15), con las salvaguardas de §9. En esta versión los plugins son **solo datos**: describen dispositivos para las familias de drivers que MacHID ya tiene. Los plugins con código (sandbox JavaScriptCore) quedan para una fase posterior y se rechazan de forma explícita.

## Plugins
- **Definiciones como datos**: `DeviceDefinition` gana `driver_options` (parámetros por modelo en texto plano, p. ej. el transaction id de Razer). Un plugin puede así añadir un modelo Razer sin código; las definiciones incluidas se mantienen y ganan si un plugin reclama el mismo USB ID.
- **Manifest** (`PluginManifest`, `Schemas/plugin-manifest.schema.json`): id, versión semántica, licencia SPDX compatible con GPLv3, autor, rango de `core_api`, dispositivos y permisos (`transport`, `report_ids`, `writes`). `writes: persistent` no se admite. Rutas de definición seguras (relativas, sin `..`, sin ocultos).
- **Instalador** (`PluginInstaller`): descarga el commit exacto, desempaqueta con comprobaciones, compara el hash del manifest con la entrada del registro, exige que id, licencia, dispositivos y `core_api` coincidan, valida cada definición (driver conocido, USB IDs declarados en el manifest, tamaños), y guarda solo `manifest.json` y las definiciones en una carpeta temporal que se mueve de forma atómica; las versiones anteriores se borran después. Nada de un plugin se ejecuta.
- **Archivos**: `TarExtractor` lista el archivo antes de extraer y rechaza rutas absolutas, `..`, demasiados archivos, enlaces simbólicos y archivos especiales, con tope de 50 MB; `GitHubArchiveFetcher` solo acepta repositorios de GitHub que pasen las reglas del registro y un SHA de commit completo (tope de 20 MB).

## Registro (SPEC §6)
- `RegistryService`: una lista solo se usa si su firma Ed25519 verifica y cada entrada pasa las reglas del registro; si no, se descarta y se conserva la última copia buena. Sin clave de confianza en la compilación el descubrimiento queda **desactivado** (nunca se confía "a ciegas"). La caché se vuelve a verificar al leerla.
- `GitHubRegistrySource`: toma la última release con tag `registry-*` (las releases de la app llevan otro tag), descarga `plugins.json` y `plugins.json.sig` solo desde GitHub por HTTPS y con tope de tamaño.
- Una prueba usa una firma generada con **el mismo comando de OpenSSL que usa el workflow** y la verifica con CryptoKit, para asegurar la compatibilidad.
- `PluginPlanner` (lógica pura): recomendaciones para dispositivos conectados sin definición (revisados primero, compatibles, no instalados), actualizaciones por cambio de commit, y bloqueo de la actualización automática si el plugin no es `reviewed`, o cambian permisos o licencia.
- `scripts/make-registry-key.sh` crea el par de claves; la clave pública se inyecta en el `Info.plist` desde la variable `REGISTRY_PUBLIC_KEY`.

## Interfaz
Pestaña Plugins en Ajustes: estado y "Comprobar ahora", interruptor de actualización automática de plugins revisados, recomendaciones para tus dispositivos, instalados (con aviso de actualización y de plugin retirado del registro), exploración con búsqueda, detalle de instalación con advertencia para plugins de comunidad, y guía para compartir ([docs/PLUGINS.md](../PLUGINS.md)). Al instalar o quitar un plugin las definiciones se aplican al catálogo en caliente.

## Auto-actualización de la app (SPEC §15)
- Sparkle 2 (MIT) como dependencia. `UpdaterModel` solo arranca si la compilación lleva `SUPublicEDKey` válida y `SUFeedURL` HTTPS; si no, la actualización está desactivada y la UI lo dice. Ajustes: buscar actualizaciones y descargar/instalar en segundo plano.
- `scripts/make-app.sh` incrusta `Sparkle.framework`, ajusta el rpath y firma de dentro hacia fuera (XPC, Autoupdate, Updater.app, framework y app); la versión visible es la de la release y el número de compilación (que Sparkle compara) es el contador de commits.
- El workflow de release genera `appcast.xml` con `generate_appcast` y la clave EdDSA (secreto `SPARKLE_ED_PRIVATE_KEY`) y lo publica junto al DMG; la app lee `releases/latest/download/appcast.xml` (las releases del registro se marcan "no latest").
- `docs/RELEASE.md` describe la creación y respaldo de las claves.

## Riesgos y pendientes
- **No probado de extremo a extremo**: instalar un plugin real desde GitHub, publicar y leer un registro firmado, y una actualización real con Sparkle requieren claves y una release firmada que aún no existen. Probado: instalador con archivos `.tar.gz` reales, firmas (incluida la de OpenSSL), planificación, modelo con registro simulado, y que la app empaquetada con Sparkle arranca.
- La generación del appcast y el DMG en el workflow no se ha ejecutado (requiere los secretos).
- Sin protección contra regresión del registro (no hay número de serie); un atacante con una lista firmada antigua podría reofrecerla. Mitigación pendiente: serie monótona en `plugins.json`.
- Plugins con código (JavaScriptCore en un proceso aislado con broker) no están implementados.
- El tap de eventos y los efectos nuevos de iluminación siguen pendientes de prueba en hardware (ver M5).
