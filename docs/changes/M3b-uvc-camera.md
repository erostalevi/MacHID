# M3b — Cámara UVC (Logitech Brio 100)

## Objetivo
Controlar la imagen de una cámara USB Video Class desde MacHID, de forma genérica (no solo para el Brio) y volátil, con comandos verificados antes en fuentes abiertas.

## Hallazgos
- Lectura de descriptores del Brio 100 real, solo lectura, con IOUSBHost sin capturar el dispositivo: interfaz Video Control 0; terminal de cámara id 1 (`bmControls` = `0e 00 00`: solo controles de exposición); **unidad de procesamiento id 2 con `bmControls` = `5b 17` (0x175B)** = brillo, contraste, saturación, nitidez, temperatura de blanco, compensación de contraste a contraluz, ganancia, frecuencia de red y balance de blancos automático; cuatro unidades de extensión propietarias de Logitech (no se tocan). No hay zoom, enfoque ni pan/tilt.
- Verificación contra el kernel de Linux (`uvcvideo`, GPL-2.0): códigos de petición (`SET_CUR 0x01`, `GET_CUR 0x81`, `GET_MIN 0x82`, `GET_MAX 0x83`, `GET_RES 0x84`), selectores y bit de cada control, y el formato de la transferencia: tipo de petición de clase hacia la interfaz (`0x21`/`0xA1`), `wValue = selector << 8`, `wIndex = unidad << 8 | interfaz`. Algunas cámaras responden con menos bytes de los pedidos; los bytes faltantes cuentan como cero.

## Archivos
- `Sources/MacHIDUVC/UVCDescriptor.swift`: análisis del descriptor de configuración (genérico, tolerante a datos truncados).
- `Sources/MacHIDUVC/UVCDriver.swift`: `info` (controles que soporta la cámara) y 9 controles de la unidad de procesamiento. Antes de escribir un valor de rango consulta los límites y el paso de la propia cámara y rechaza lo que quede fuera; marcas (0/1) y frecuencia de red (0-2) también se validan.
- `Sources/MacHIDIOKit/IOKitUSBTransport.swift`: transferencias de control y descriptores vía IOUSBHost, sin captura exclusiva (los controladores de cámara del sistema siguen funcionando).
- `Sources/MacHIDDomain/Ports.swift`: `Transport` gana `controlRead`, `controlWrite` y `usbConfigurationDescriptor`.
- `Sources/machid/`: familia `uvc` en el conector y `set` acepta cualquier capability numérica.
- `Definitions/logitech-brio-100.json` con los 9 controles; `Tests/MacHIDUVCTests/UVCTests.swift` (13 pruebas, incluida la parte Video Control del descriptor real del Brio).
- `Package.swift`: target `MacHIDUVC` y enlace con IOUSBHost.

## Error de diseño detectado por las pruebas
Los tres métodos nuevos estaban solo en una extensión del protocolo, no como requisitos, así que cualquier llamada a través de `any Transport` usaba la implementación por defecto ("no soportado") y el transporte real habría fallado igual. Se declararon como requisitos del protocolo (las implementaciones por defecto se mantienen para los transportes que no los soportan).

## Validación en hardware (Brio 100 real, ejecutado desde el terminal de la app)
- `get info` → brillo, contraste, saturación, nitidez, temperatura de blanco, contraluz, ganancia, frecuencia de red y balance automático.
- Lecturas: brillo 128, contraste 128, saturación 128, nitidez 128, temperatura de blanco 4000, balance automático 1, contraluz 1, ganancia 0, frecuencia de red 2.
- Escritura: `set brightness 160` → releído 160; restaurado a 128 → releído 128. `set brightness 999` → rechazado antes de enviar ("must be between 0 and 255", rango propio de la cámara) y el valor siguió en 128.
- No se pidió ningún permiso de cámara: las transferencias de control no pasan por AVFoundation.
- No se comprobó visualmente el cambio de imagen en una app de cámara.

## Decisiones y límites
- Valores solo en el estado actual de la cámara; UVC no tiene perfiles onboard y los valores se pierden al reconectar (SPEC §9: nada persistente).
- Exposición (terminal de cámara: modo AE, prioridad, tiempo absoluto) **no** está en esta fase: requiere manejar el modo automático/manual y mapas de bits propios.
- Las unidades de extensión de Logitech no se usan.

## Riesgos y pendientes
- Si otra app configura la cámara a la vez (por ejemplo el procesamiento propio de macOS), puede sobrescribir los valores.
- Cámaras con descriptores atípicos (varios interfaces VC, unidades en cadena) no se probaron; solo el Brio 100.
- Falta confirmar el efecto visual en una app de cámara y cómo se comporta al reconectar.

## Pruebas
- Ejecutadas: 94 pruebas unitarias pasan (UVC 13, HID++ 34, Razer 19, dominio 17, aplicación 11) y validación de definiciones; verificación manual en el Brio 100.
