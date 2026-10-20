# M11: vista previa en vivo de la cámara (Brio 100)

## Objetivo
Que el usuario vea en tiempo real el efecto de brillo, contraste, balance de blancos, exposición, etc. (aplicados por UVC) en una cámara Logitech (Brio 100, 046d:094c).

## Archivos
- `Sources/MacHIDUI/CameraPreview.swift`: `CameraPreviewView(deviceName:usbID:)`, capa `AVCaptureVideoPreviewLayer` en un `NSViewRepresentable`, píldora LIVE, interruptor de espejo (`@AppStorage("cameraPreviewMirrored")`, por defecto activo), estados de permiso/error. Usa `.flatSurface`, sin capas de vidrio.
- `Sources/MacHIDUI/CameraPreviewModel.swift`: `CameraAuthorization`, `CameraMatcher` (puro), `CameraSessionController` (cola serie propia), `CameraPreviewModel`.
- `Tests/MacHIDUITests/CameraPreviewTests.swift`: matcher y mapeo de autorización.
- `scripts/make-app.sh`: `NSCameraUsageDescription`. `scripts/sign-app.sh`: entitlement `com.apple.security.device.camera` (plist generado en /private/tmp), aplicado a la app; la firma ad hoc sigue funcionando.
- `Resources/Localizable.xcstrings`: traducciones al español.

## Lógica y decisiones
- Emparejamiento: primero por `modelID` (`VendorID_1133`, `ProductID_2380`, comparación por token exacto), luego por nombre (sin distinguir mayúsculas).
- La sesión arranca en `onAppear` y se detiene en `onDisappear` y al desactivarse la app; start/stop siempre en la cola serie, nunca en main. Preset 720p (o `.high`).
- El espejo gira la capa (transform), sin actualizaciones SwiftUI por fotograma.
- Errores: desconexión, error de runtime o entrada no disponible muestran "ocupada/no encontrada" con reintento.
- Nada se graba ni se envía; sin logs.

## Riesgos y supuestos
- Formato de `usbID` asumido "046d:094c" (hex); otros formatos caen al emparejamiento por nombre.
- Si el UVC y AVFoundation compiten por el dispositivo, algunos controles podrían verse afectados (por validar en hardware).
- El permiso de cámara exige app firmada con bundle estable; con firma ad hoc macOS puede volver a pedirlo tras cada build.
- La vista aún debe integrarse en la ventana (lo hace el lead).

## Pruebas
- Unitarias ejecutadas: `swift test --filter CameraPreviewTests` (5 pasan).
- Recomendado: probar en hardware (permiso, desconexión, cámara ocupada por otra app, espejo).
