import SwiftUI
import MacHIDDomain

/// One control, generated from a `ControlSpec`. Writes go through the model, which debounces them.
struct ControlRow: View {
    @Bindable var model: AppModel
    let device: AppModel.DeviceEntry
    let spec: ControlSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            control
                .disabled(!spec.isWritable && spec.kind != .readout)
        }
        .opacity(spec.isWritable || spec.kind == .readout ? 1 : 0.5)
    }

    private var label: some View {
        HStack {
            Titles.control(spec.id).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            if case .slider = spec.kind, case .int(let value)? = device.values[spec.id] {
                Text(verbatim: "\(value)").font(.subheadline.monospacedDigit()).foregroundStyle(.primary)
                    .contentTransition(.numericText(value: Double(value)))
                    .motion(\.snappy, value: value)
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch spec.kind {
        case .slider(let min, let max, let step, let deviceLimits):
            sliderControl(min: min, max: max, step: step, deviceLimits: deviceLimits)
        case .toggle:
            Toggle(isOn: Binding(get: { currentInt == 1 }, set: { model.set(.int($0 ? 1 : 0), capability: spec.id, on: device.id) })) {
                EmptyView()
            }
            .labelsHidden().toggleStyle(.switch)
        case .choice(let values):
            Picker(selection: Binding(get: { currentInt ?? values.first ?? 0 },
                                      set: { model.set(.int($0), capability: spec.id, on: device.id) })) {
                ForEach(values, id: \.self) { Titles.choice($0, control: spec.id).tag($0) }
            } label: { EmptyView() }
            .labelsHidden().pickerStyle(.segmented)
        case .color(let canTurnOff):
            ColorControl(color: currentColor, canTurnOff: canTurnOff,
                         onColor: { model.set(.color(RGBColor($0)), capability: spec.id, on: device.id) },
                         onOff: { model.set(.text("off"), capability: spec.id, on: device.id) })
        case .hostControl:
            let hostValue = spec.capability.parameters?.values?.max() ?? 1
            Toggle(isOn: Binding(get: { (currentInt ?? 0) != 0 },
                                 set: { model.set(.int($0 ? hostValue : 0), capability: spec.id, on: device.id) })) {
                Text("Keep lighting under MacHID control").font(.callout)
            }
            .toggleStyle(.switch)
        case .readout:
            if case .text(let text)? = device.values[spec.id] {
                Text(verbatim: text).font(.callout).foregroundStyle(.primary).textSelection(.enabled)
            } else {
                Text("Not available").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    private func sliderControl(min: Int, max: Int, step: Int, deviceLimits: Bool) -> some View {
        let limits = device.limits[spec.id]
        let low = limits?.min ?? min, high = limits?.max ?? max, stride = limits?.step ?? step
        return Slider(value: Binding(get: { Double(currentInt ?? low) },
                                     set: { model.set(.int(Int($0.rounded())), capability: spec.id, on: device.id) }),
                      in: Double(low)...Double(Swift.max(high, low + 1)), step: Double(Swift.max(stride, 1)))
            .disabled(deviceLimits && limits == nil && device.values[spec.id] == nil)
    }

    private var currentInt: Int? {
        if case .int(let value)? = device.values[spec.id] { return value }
        return nil
    }

    private var currentColor: Color {
        if case .color(let value)? = device.values[spec.id] { return value.color }
        return .white
    }
}

private struct ColorControl: View {
    let color: Color
    let canTurnOff: Bool
    let onColor: (Color) -> Void
    let onOff: () -> Void

    private static let swatches: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .white]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.swatches, id: \.self) { swatch in
                Button { onColor(swatch) } label: {
                    Circle().fill(swatch).frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(swatch.description)"))
            }
            ColorPicker("", selection: Binding(get: { color }, set: onColor), supportsOpacity: false).labelsHidden()
            Spacer(minLength: 0)
            if canTurnOff { Button("Off", action: onOff).buttonStyle(PillButtonStyle()) }
        }
    }
}

/// The floating card with the controls of one section.
struct ControlPanel: View {
    @Bindable var model: AppModel
    let device: AppModel.DeviceEntry
    let section: ControlSection

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(device.specs.filter { $0.section == section }) { spec in
                ControlRow(model: model, device: device, spec: spec)
            }
            if let error = device.lastError {
                Label { Text(verbatim: error).font(.caption) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.orange)
            }
        }
        .padding(22)
        .frame(maxWidth: 560, alignment: .leading)
        .glassSurface(cornerRadius: 28)
    }
}
