# M12: Modos shift (capas) para remapeo

## Objetivo
Permitir "capas": una tecla o botón (el disparador) activa un modo mientras se mantiene (`hold`) o al pulsarlo (`toggle`), y las reglas que listan ese modo solo se aplican mientras está activo. Los modos son independientes y pueden combinarse. Se añaden además acciones de perfil y de alternar modo.

## Archivos modificados
- `Sources/MacHIDDomain/Remap.swift`: `ShiftMode`, `ShiftBehavior`, `RemapRule.shiftModeIDs`, `RemapConfig.shiftModes`, nuevas acciones, decodificación retrocompatible.
- `Sources/MacHIDApplication/RemapEngine.swift`: lógica de capas, `activeShiftModeIDs`, `resetTransientState()`, decisiones `.switchProfile` y `.cycleProfile`.
- `Sources/MacHIDQuartz/RemapEventTap.swift`: observa `.flagsChanged` (teclas modificadoras), cierres `switchProfile` y `cycleProfile`.
- `Sources/MacHIDUI/RemapController.swift`: `activeShiftModes`, CRUD de modos, callbacks.
- `Sources/machid/RulesCommand.swift` y `Sources/MacHIDUI/RemapView.swift`: solo casos nuevos en `switch` para que compile.
- Pruebas: `RemapEngineTests` (suite `ShiftModeTests`), `RemapControllerTests`, `RemapStorageTests` (suite `ShiftModeStorageTests`).

## Lógica
- El disparador de un modo se consume (suprimido, también su liberación) mientras el modo exista y el remapeo esté activo. Tiene prioridad sobre una regla con el mismo disparador. Se ignoran repeticiones automáticas.
- `hold`: activo mientras el disparador está pulsado. `toggle`: cada pulsación invierte el estado. `.toggleShiftMode(id)` como acción también lo invierte.
- Una regla aplica si TODOS sus `shiftModeIDs` están activos (y en alcance). Gana la que exige más modos; a igual profundidad, la de la app al frente sobre la global. Una regla de capa gana a una regla base de app.
- Alcance: `affectsOtherDevices == false` limita el modo a entradas del mismo `InputKind` que su disparador.
- Si un modo termina con teclas remapeadas aún pulsadas, su liberación se envía igual (tabla `active` por tecla física).
- `update(config:)` conserva modos alternados y disparadores sostenidos si el modo sigue existiendo con el mismo disparador; si el remapeo se apaga, todo se limpia. Al detener el tap se llama `resetTransientState()` para que ningún modo quede encendido.
- Eliminar un modo elimina sus reglas (y las que lo alternan).
- Unicidad de regla: disparador + app + conjunto de modos.
- Formato en disco: aditivo, `schemaVersion` sigue en 1; las claves nuevas son opcionales al decodificar y el encoding de los casos existentes de `RemapAction` no cambia.
- Teclas modificadoras: el tap convierte `flagsChanged` en `InputEvent` (teclado; códigos 54/55 cmd, 56/60 shift, 58/61 option, 59/62 control, 63 fn/globo, 57 bloq mayús). `isDown` sale del bit de flag específico izquierda/derecha. El bit propio de la tecla se excluye de `modifiers`, así un disparador con `modifiers: []` coincide. Solo se consume si el motor decide algo distinto de passthrough; el resto pasa intacto. Mientras un modificador consumido está pulsado, su flag se quita de los eventos siguientes para que las apps no lo vean pulsado. Force Quit se evalúa con los flags reales antes de quitarlos.

## Decisiones
- `makeTap` conserva su firma (no rompe pruebas ni previsualización): el controlador envuelve el handler y ejecuta `onSwitchProfile`/`onCycleProfile` en el actor principal, devolviendo `.suppress` al tap. El tap tiene igualmente los cierres `switchProfile`/`cycleProfile` (por defecto vacíos).
- Disparadores prohibidos (`ShiftMode.isAllowedTrigger`): clic izquierdo/derecho (el tap no los observa, y consumirlos podría bloquear al usuario) y Escape (reservado a Force Quit). El motor los ignora y el controlador los rechaza con un aviso.

## Límites y riesgos
- Las teclas Fn de teclados Razer se implementan en firmware y nunca llegan a macOS: no pueden ser disparadores. Sí sirven la tecla fn/globo del Mac, modificadores del lado derecho, cualquier tecla normal y los botones medio/extra del ratón. Bloq Mayús es de mejor esfuerzo (macOS informa estado, no pulsación física).
- El tap no distingue dispositivos: el alcance "mismo dispositivo" es en realidad "mismo tipo de entrada" (teclado vs ratón).
- Quitar un flag de modificador consumido afecta también a la otra tecla del mismo modificador si ambas están pulsadas (caso borde).
- No verificado en hardware (el agente no tiene Input Monitoring): probar con el Terminal del usuario, incluyendo Force Quit (⌘⌥Esc) con un modo sobre ⌥ derecho.

## Pruebas
Ejecutadas (`swift test --scratch-path /private/tmp/machid-shift`, todo en verde): hold vs toggle, dos modos simultáneos, regla combinada, prioridad y alcance por app, alcance por `InputKind`, liberación al terminar el modo a mitad de pulsación, disparadores modificadores con eventos sintéticos, disparadores prohibidos, acciones de perfil y alternar modo, eliminación de modo, decodificación de JSON antiguo, ida y vuelta en disco, controlador (actividad, callbacks, rechazo de disparadores). Pendiente: prueba manual en hardware.
