# M7 — Onboarding, panel de la barra de menú y accesibilidad

## Objetivo
Primer arranque guiado y un panel de la barra de menú más útil, con navegación por teclado y accesibilidad (SPEC §7, §19).

## Cambios
- `OnboardingView`: tarjeta de 4 pasos (qué hace MacHID, Monitoreo de entrada, permisos opcionales de remapeo, fin). Se muestra solo la primera vez (`onboarding.completed`), no pide ningún permiso hasta que el usuario pulsa un botón, y se puede repetir desde Ajustes > General.
- Panel de la barra de menú: macros favoritas (estrella en la lista de macros; deshabilitadas con aviso si necesitan aprobación), botón "Detener macros" mientras una corre, menú rápido de modos de iluminación por dispositivo y punto rojo en el engranaje si hay actualizaciones de plugins.
- Ventana principal: sección seleccionada en `AppModel`, atajos ⌘1…⌘5, estado de carga "Buscando dispositivos…", banner de error que se cierra solo a los 6 s.
- Accesibilidad: etiquetas y valores en controles, acción de accesibilidad en los puntos activos, selección que no depende solo del color.
- 34 cadenas nuevas con traducción al español.

## Riesgos y pendientes
- Atajos, temporizador del banner, favoritos y "Detener macros" no se han ejecutado en la app real; el panel de ejemplo no mostraba favoritos ni macros en ejecución.
- La herramienta de instantáneas no dibuja las capas de cristal ni las píldoras tintadas; las capturas de la ventana principal no se pudieron comprobar.
- Sin orden de foco propio más allá del de SwiftUI.
