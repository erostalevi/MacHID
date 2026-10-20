import SwiftUI
import MacHIDDomain

/// The settings column on the right of the window: section tabs on top, the controls of that section below.
struct DeviceSidebar: View {
    @Bindable var model: AppModel
    let device: AppModel.DeviceEntry
    var remap: RemapController?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var section: ControlSection {
        device.sections.contains(model.selectedSection) ? model.selectedSection : (device.sections.first ?? .info)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
                .padding(.horizontal, Theme.inset).padding(.top, 44).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    content
                        .id(section)
                        .transition(.opacity)
                }
                .padding(.horizontal, Theme.inset).padding(.bottom, Theme.inset).padding(.top, 4)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.02),
                                         .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .frame(width: Theme.sidebarWidth)
        .animation(Motion(reduce: reduceMotion).snappy, value: section)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(device.sections, id: \.self) { candidate in
                Button {
                    withAnimation(Motion(reduce: reduceMotion).snappy) { model.selectedSection = candidate }
                } label: {
                    Image(systemName: Titles.symbol(for: candidate))
                        .font(.system(size: 15, weight: candidate == section ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(candidate == section ? AnyShapeStyle(device.accent) : AnyShapeStyle(.secondary))
                        .background {
                            if candidate == section {
                                RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous).fill(device.accent.opacity(0.22))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous).strokeBorder(device.accent.opacity(0.45), lineWidth: 1))
                                    .matchedGeometryEffect(id: "tab", in: tabSpace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Titles.sectionName(candidate))
                .accessibilityLabel(Titles.section(candidate))
                .accessibilityAddTraits(candidate == section ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.chipRadius + 3, style: .continuous))
    }

    @Namespace private var tabSpace

    @ViewBuilder private var content: some View {
        HStack {
            Titles.section(section).font(.title2.weight(.semibold))
            Spacer()
        }
        switch section {
        case .buttons:
            ButtonsPanel(model: model, device: device, remap: remap)
        default:
            SpecsPanel(model: model, device: device, section: section)
        }
    }
}

/// The generated controls of one section, grouped on cards.
struct SpecsPanel: View {
    @Bindable var model: AppModel
    let device: AppModel.DeviceEntry
    let section: ControlSection

    var body: some View {
        let specs = device.specs.filter { $0.section == section }
        let hasKeys = section == .lighting && specs.contains { if case .keyLighting = $0.kind { true } else { false } }
        let painting = model.perKeyActive.contains(device.id)
        VStack(alignment: .leading, spacing: Theme.gap) {
            if hasKeys {
                Card {
                    Segmented(options: [false, true], selection: Binding(get: { painting }, set: { model.setPerKey($0, for: device.id) }),
                              tint: device.accent) { $0 ? Text("Per key") : Text("Effects") }
                }
            }
            if hasKeys && painting {
                PerKeyCard(model: model, device: device)
            }
            ForEach(specs) { spec in
                if case .keyLighting = spec.kind { EmptyView() }
                else if hasKeys && painting && spec.section == .lighting, case .lighting = spec.kind { EmptyView() }
                else { Card { ControlRow(model: model, device: device, spec: spec) } }
            }
            if let error = device.lastError {
                Label { Text(verbatim: error).font(.caption) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Brush, fill and clear for painting keys on the drawing.
struct PerKeyCard: View {
    @Bindable var model: AppModel
    let device: AppModel.DeviceEntry
    private static let swatches: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .white]

    var body: some View {
        Card(title: Text("Paint")) {
            Text("Click or drag over the keys to color them.").font(.callout).foregroundStyle(.secondary)
            FlowRow(spacing: 10) {
                ForEach(Self.swatches, id: \.self) { swatch in
                    Button { model.brush = RGBColor(swatch) } label: {
                        Circle().fill(swatch).frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                            .overlay { if RGBColor(swatch) == model.brush { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.black.opacity(0.7)) } }
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(get: { model.brush.color }, set: { model.brush = RGBColor($0) }), supportsOpacity: false).labelsHidden()
            }
            HStack {
                Button("Fill all") { model.fillKeys(with: model.brush, for: device.id) }.buttonStyle(PillButtonStyle())
                Button("Clear") { model.fillKeys(with: nil, for: device.id) }.buttonStyle(PillButtonStyle())
            }
        }
    }
}
