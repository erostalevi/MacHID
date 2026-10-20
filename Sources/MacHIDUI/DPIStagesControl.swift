import SwiftUI
import MacHIDDomain

/// DPI presets: up to five steps the user can jump between. The mouse holds one DPI at a time, so the app keeps the list
/// and writes the chosen step; "Next" in the menu bar cycles through them.
struct DPIStagesControl: View {
    @Bindable var model: AppModel
    let device: AppModel.DeviceEntry
    let spec: ControlSpec
    let min: Int, max: Int, step: Int, slots: Int
    @State private var editing = 0

    private var stages: [Int] {
        if case .text(let text)? = device.values[spec.id], let parsed = DPIStages(text: text) { return parsed.values }
        return AppModel.defaultDPIStages
    }
    private var current: Int? { if case .int(let value)? = device.values["dpi"] { value } else { nil } }

    var body: some View {
        let stages = stages
        let index = Swift.min(editing, stages.count - 1)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Presets").font(.subheadline.weight(.medium))
                Spacer()
                Button { add(stages) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(stages.count >= Swift.min(slots, DPIStages.maxStages))
                    .help("Add a preset")
                Button { remove(stages, index) } label: { Image(systemName: "minus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(stages.count <= 1)
                    .help("Remove the selected preset")
            }
            HStack(spacing: 6) {
                ForEach(Array(stages.enumerated()), id: \.offset) { offset, value in
                    Button {
                        editing = offset
                        model.set(.int(value), capability: "dpi", on: device.id)
                    } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: "\(value)").font(.callout.weight(.semibold).monospacedDigit())
                            Text(verbatim: "\(offset + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background {
                            let active = value == current
                            RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                                .fill(device.accent.opacity(active ? 0.30 : (offset == index ? 0.14 : 0.06)))
                                .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                                    .strokeBorder(device.accent.opacity(active ? 0.7 : (offset == index ? 0.35 : 0)), lineWidth: 1))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "\(value) DPI"))
                    .accessibilityAddTraits(value == current ? .isSelected : [])
                }
            }
            SettingRow(title: Text("Preset \(index + 1)"), value: Text(verbatim: "\(stages[index]) DPI")) {
                Slider(value: Binding(get: { Double(stages[index]) },
                                      set: { setStage(index, to: min + Int((($0 - Double(min)) / Double(Swift.max(step, 1))).rounded()) * Swift.max(step, 1), stages) }),
                       in: Double(min)...Double(max))
            }
        }
    }

    private func save(_ values: [Int]) {
        guard let stages = DPIStages(values: values) else { return }
        model.set(.text(stages.text), capability: spec.id, on: device.id)
    }

    private func setStage(_ index: Int, to value: Int, _ stages: [Int]) {
        var copy = stages
        copy[index] = value
        save(copy)
        if stages[index] == current { model.set(.int(value), capability: "dpi", on: device.id) }
    }

    private func add(_ stages: [Int]) {
        save(stages + [Swift.min(max, (stages.last ?? 800) * 2)])
        editing = stages.count
    }

    private func remove(_ stages: [Int], _ index: Int) {
        var copy = stages
        copy.remove(at: index)
        save(copy)
        editing = Swift.max(0, index - 1)
    }
}
