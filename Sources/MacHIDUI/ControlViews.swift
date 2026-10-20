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
                .disabled(!spec.isWritable && spec.kind != .readout || blockedByAutomaticMode)
        }
        .opacity((spec.isWritable || spec.kind == .readout) && !blockedByAutomaticMode ? 1 : 0.5)
        .motion(\.snappy, value: blockedByAutomaticMode)
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
            .accessibilityLabel(Titles.control(spec.id))
            .accessibilityValue(currentInt == 1 ? Text("On") : Text("Off"))
        case .choice(let values):
            Picker(selection: Binding(get: { currentInt ?? values.first ?? 0 },
                                      set: { model.set(.int($0), capability: spec.id, on: device.id) })) {
                ForEach(values, id: \.self) { Titles.choice($0, control: spec.id).tag($0) }
            } label: { EmptyView() }
            .labelsHidden().pickerStyle(.segmented)
            .accessibilityLabel(Titles.control(spec.id))
        case .lighting(let modes):
            LightingControl(modes: modes, value: device.values[spec.id]) {
                model.set($0, capability: spec.id, on: device.id)
            }
        case .hostControl:
            let hostValue = spec.capability.parameters?.values?.max() ?? 1
            Toggle(isOn: Binding(get: { (currentInt ?? 0) != 0 },
                                 set: { model.set(.int($0 ? hostValue : 0), capability: spec.id, on: device.id) })) {
                Text("Keep lighting under MacHID control").font(.callout)
            }
            .toggleStyle(.switch)
            .accessibilityValue((currentInt ?? 0) != 0 ? Text("On") : Text("Off"))
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
            .accessibilityLabel(Titles.control(spec.id))
            .accessibilityValue(Text(verbatim: "\(currentInt ?? low)"))
    }

    private var currentInt: Int? {
        if case .int(let value)? = device.values[spec.id] { return value }
        return nil
    }

    private var blockedByAutomaticMode: Bool {
        guard let dependency = spec.disabledWhen, case .int(let value)? = device.values[dependency.control] else { return false }
        return value == dependency.equals
    }
}

/// Lighting: pick a mode, and a color for the modes that use one.
private struct LightingControl: View {
    let modes: [String]
    let value: SettingValue?
    let onChange: (SettingValue) -> Void

    private static let swatches: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .white]

    private var mode: String { LightingModes.mode(of: value) ?? modes.first ?? "static" }

    private var color: Color {
        switch value {
        case .color(let rgb)?: rgb.color
        case .effect(let effect)? where effect.color != nil: effect.color!.color
        default: .white
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            modePicker
            if LightingModes.usesColor(mode) {
                HStack(spacing: 10) {
                    ForEach(Self.swatches, id: \.self) { swatch in
                        Button { select(mode, color: swatch) } label: {
                            Circle().fill(swatch).frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                                .overlay { if swatch == color { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.black.opacity(0.7)) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "\(swatch.description)"))
                    }
                    ColorPicker("", selection: Binding(get: { color }, set: { select(mode, color: $0) }), supportsOpacity: false)
                        .labelsHidden()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .motion(\.snappy, value: mode)
    }

    private var modePicker: some View {
        // A menu for many modes keeps the card calm; two or three fit as segments.
        Group {
            if modes.count <= 3 {
                Picker(selection: Binding(get: { mode }, set: { select($0, color: color) })) {
                    ForEach(modes, id: \.self) { Titles.lightingMode($0).tag($0) }
                } label: { EmptyView() }
                .labelsHidden().pickerStyle(.segmented)
            } else {
                FlowRow(spacing: 8) {
                    ForEach(modes, id: \.self) { candidate in
                        Button { select(candidate, color: color) } label: { Titles.lightingMode(candidate) }
                            .buttonStyle(PillButtonStyle(selected: candidate == mode))
                            .accessibilityAddTraits(candidate == mode ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func select(_ mode: String, color: Color) {
        onChange(LightingModes.value(for: mode, color: RGBColor(color)))
    }
}

/// Lays chips out in rows that wrap when the card is narrow.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 480, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in arrange(width: bounds.width, subviews: subviews).origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
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
