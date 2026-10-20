# M4b–M5 — Pulido de la interfaz, automatización, más capacidades, remapeo y macros

## Objetivo
Llevar la app más allá del primer arranque: interfaz con mejor sensación de movimiento, perfiles automáticos, más capacidades verificadas en fuentes abiertas y el motor de remapeo y macros del SPEC (§2, §8, §9), con las salvaguardas exigidas.

## Interfaz
- Movimiento: botones de cristal con elevación al pasar el cursor y hundimiento al pulsar; selector de secciones como una sola cápsula con el resaltado deslizante (`matchedGeometryEffect`); transiciones `blurReplace` al cambiar de dispositivo o sección; cifras con `contentTransition(.numericText)`; el dispositivo "flota" con un balanceo casi imperceptible. Todo respeta "Reducir movimiento" (`Motion`) y "Reducir transparencia".
- Atajos ⌘] y ⌘[ para cambiar de dispositivo; ventana de Ajustes con pestañas General, Remap y Macros.
- Herramienta `MacHIDSnapshots`: renderiza las vistas a PNG fuera de pantalla (sin abrir ventanas ni leer la pantalla) para revisar el diseño; no captura las capas de cristal, solo la disposición y los controles.

## Robustez
- `SessionPool`: una sesión abierta por dispositivo (cierre por inactividad de 30 s o tras un error), en lugar de reabrir en cada escritura.
- `IOKitDeviceMonitor`: notificaciones de conexión y desconexión USB; el sondeo queda como red de seguridad cada 30 s.
- HID++: se descartan las respuestas pendientes antes de cada petición.

## Automatización (SPEC §8)
- `AutomationConfig`: reglas por app (una por app y dispositivo), perfil predeterminado por dispositivo, interruptor de pausa y "aplicar al conectar". Prioridad explícita: regla de la app en uso, luego el predeterminado.
- Al conectar un dispositivo se reaplica el perfil que le corresponde; al cambiar de app se aplica la regla. Borrar un perfil elimina sus reglas. Ignora a MacHID mismo como app activa.
- Ajustes: abrir al iniciar sesión (`SMAppService`), reglas, predeterminados y pausa también en el panel de la barra de menú.

## Capacidades nuevas (verificadas en fuentes abiertas, sin probar todas en hardware)
- Razer: efectos espectro, onda, reactivo y estrellas (formatos de los ejemplos de paquetes de OpenRazer).
- Logitech (G203): efectos ciclo y respiración sobre RGB_EFFECTS (formatos de libratbag) y frecuencia de sondeo (0x8060: lista como campo de bits, lectura función 1, escritura función 2).
- UVC: exposición automática y tiempo de exposición (terminal de cámara; modos AE según GET_RES) con valores en 4 bytes; el control manual se deshabilita mientras el automático está activo en la UI.
- Nuevo valor de ajuste `effect` (nombre y color opcional) y UI de iluminación por modos.

## Remapeo y macros (SPEC §2, §9)
- Dominio (`Remap.swift`): disparadores de teclado o botón, acciones (tecla, botón, macro, nada), reglas con ámbito de app, macros de 7 tipos de paso y `RemapConfig`. **Desactivado por defecto**.
- `RemapEngine` (lógica pura): modificadores exactos, regla de app sobre global, liberación emparejada con su pulsación aunque se suelte antes el modificador, repeticiones que no relanzan una macro.
- `MacroRunner` con las salvaguardas: aprobación ligada a un SHA-256 de los pasos (editar un paso la revoca); interruptor global de shell; guarda contra elevación (`sudo`, `doas`, `su`, `pkexec`, "with administrator privileges"); límites de pasos, repeticiones y esperas; una ejecución a la vez; el registro guarda nombre, tipos de paso y resultado, nunca texto ni comandos.
- Adaptadores (`MacHIDQuartz`): `CGEventTap` solo de teclas y botones extra (no clics ni movimiento), reducidos a código, modificadores y subida/bajada antes de llegar al motor; ignora los eventos propios (marca) y Force Quit; se reactiva tras desactivaciones del sistema; `ProcessShellRunner` (sin entrada, entorno mínimo, tiempo máximo y muerte forzada); `WorkspaceLauncher` (apps, enlaces, archivos y Atajos sin pasar por shell).
- `RemapController`: permisos, ciclo de vida del tap (arranca solo cuando están concedidos Input Monitoring y Accesibilidad), importar y exportar macros (la importación nunca hereda aprobación, regenera ids y limita tamaño).
- UI: grabador de teclas, reglas, editor de macros que muestra íntegro todo paso "poderoso" y exige aprobación explícita.

## CI
La compilación de Liquid Glass se protege con `#if compiler(>=6.2)` además de `#available`; sin secretos de firma el workflow de release compila y prueba y termina en verde; el workflow del registro valida y omite la firma. El CI sigue verde en cada commit desde el arreglo.

## Riesgos y pendientes
- **El tap de eventos y los adaptadores de Quartz no se han probado con eventos reales**: requieren permisos que concede el usuario; están cubiertos por pruebas de lógica y de procesos, no de la tubería de eventos. Primera prueba recomendada: una regla inocua (por ejemplo, F5 a otra tecla) y comprobar que MacHID se puede detener desde el interruptor.
- Los efectos de Razer, Logitech y la exposición de UVC se probaron contra dispositivos simulados; falta probarlos en el hardware.
- Los modificadores como teclas disparadoras (Caps Lock, fn) y el filtro por dispositivo no están soportados (el tap no sabe de qué dispositivo viene un evento).
- La captura de pantalla de la ventana real queda a cargo del usuario; las instantáneas fuera de pantalla no muestran el cristal.

## Pruebas
Suite completa: dominio 42, aplicación 36, UI 35, Razer 23, Logitech 42 y UVC 22 (entre otras), más pruebas de procesos reales (`ProcessShellRunner`) y de almacenamiento.
