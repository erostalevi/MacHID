import SwiftUI
import MacHIDDomain

/// Settings > Lights: one preset for every device, with a cycle time they all share.
struct GlobalLightView: View {
    @Bindable var light: GlobalLightController

    private func title(_ kind: GlobalLightController.Kind) -> Text {
        switch kind {
        case .off: Text("Off")
        case .solid: Text("Solid")
        case .spectrum: Text("Rainbow")
        case .wave: Text("Wave")
        case .breathing: Text("Breathing")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("All devices").font(.title3.weight(.semibold))
                Text("Set the lighting of every connected device from here. Animations share one cycle time so they stay in step.")
                    .font(.callout).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Effect", selection: $light.kind) {
                        ForEach(GlobalLightController.Kind.allCases) { kind in title(kind).tag(kind) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    if light.needsColor { ColorField(selected: light.color, title: Text("Color")) { light.color = $0 } }
                    if light.kind != .off {
                        LabeledContent("Brightness") {
                            HStack { Slider(value: $light.brightness, in: 1...100); Text("\(Int(light.brightness))%").monospacedDigit().frame(width: 44, alignment: .trailing) }
                        }
                    }
                    if light.usesCycle {
                        LabeledContent("Cycle time") {
                            HStack { Slider(value: $light.cycleSeconds, in: 2...60); Text("\(Int(light.cycleSeconds)) s").monospacedDigit().frame(width: 44, alignment: .trailing) }
                        }
                        Toggle("Keep devices in sync", isOn: $light.keepInSync)
                        Text("Keyboards are drawn by MacHID from one shared clock, so they start every cycle together. Needs MacHID running.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Color.primary.opacity(0.06)))

                HStack {
                    Button("Apply to all devices") { light.apply() }.buttonStyle(.borderedProminent)
                    if light.active { Button("Use per-device lighting") { light.release() } }
                }
                ForEach(light.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .onChange(of: light.kind) { _, _ in if light.active { light.apply() } }
        .onSubmit { if light.active { light.apply() } }
    }
}
