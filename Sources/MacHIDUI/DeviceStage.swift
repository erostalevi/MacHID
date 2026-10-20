import SwiftUI
import MacHIDDomain

/// The left side of the window: the device itself, drawn large, alive and clickable.
struct DeviceStage: View {
    @Bindable var model: AppModel
    let device: AppModel.DeviceEntry
    var remap: RemapController?
    var onPick: (String) -> Void = { _ in }

    var body: some View {
        ZStack {
            stageContent
                .id(device.id)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var stageContent: some View {
        switch device.category {
        case .mouse:
            MouseSimView(accent: device.accent, lightsOn: lightsOn, dpi: intValue("dpi"), selected: model.selectedInput,
                         remapped: remappedMouseButtons, onSelect: { id in model.selectedInput = id; onPick(id) })
        case .keyboard where layout != nil:
            KeyboardSimView(layout: layout!, effect: keyboardEffect, brightness: brightness, selected: painting ? nil : model.selectedInput,
                            remapped: painting ? [] : remappedKeys, dragSelects: painting,
                            onSelect: { id in
                                if painting { model.paintKey(id, on: device.id) } else { model.selectedInput = id; onPick(id) }
                            })
                .padding(.horizontal, 24)
        case .camera:
            CameraPreviewView(deviceName: device.name, usbID: device.usbId.description)
                .padding(.horizontal, 36)
        default:
            DeviceArt(category: device.category, accent: device.accent, artwork: model.artwork(for: device),
                      interactive: Set(device.specs.map(\.id))) { _ in }
        }
    }

    private var layout: KeyboardLayout? { KeyboardLayout.layout(forDefinitionID: device.definition?.id) }
    private var painting: Bool { model.isPainting(device) }

    private var keyboardEffect: SimEffect {
        if model.perKeyActive.contains(device.id) {
            for spec in device.specs {
                if case .keyLighting = spec.kind {
                    if case .keyFrame(let frame)? = device.values[spec.id] { return SimEffect.from(nil, frame: frame) }
                    return SimEffect.from(nil, frame: [])
                }
            }
        }
        for spec in device.specs {
            if case .lighting = spec.kind { return SimEffect.from(device.values[spec.id]) }
        }
        return SimEffect()
    }

    private var brightness: Double { Double(intValue("brightness") ?? 100) / 100 }

    private var remappedKeys: Set<String> {
        guard let remap else { return [] }
        return Set(remap.config.rules.filter { $0.trigger.kind == .keyboard && $0.appBundleID == nil && $0.enabled }
            .compactMap { KeyboardKeyCodes.keyID(forCode: $0.trigger.code) })
    }

    private var remappedMouseButtons: Set<String> {
        guard let remap else { return [] }
        let numbers = Set(remap.config.rules.filter { $0.trigger.kind == .mouseButton && $0.appBundleID == nil && $0.enabled }.map(\.trigger.code))
        return Set(MouseSimView.g203.filter { $0.quartzButton.map(numbers.contains) ?? false }.map(\.id))
    }

    private var lightsOn: Bool {
        for spec in device.specs {
            if case .lighting = spec.kind { return LightingModes.mode(of: device.values[spec.id]) != "off" }
        }
        return true
    }

    private func intValue(_ id: String) -> Int? {
        if case .int(let value)? = device.values[id] { value } else { nil }
    }
}
