import SwiftUI
import MacHIDDomain

/// The settings column on the right of the window: three tabs (Light, Keys, Info), the controls of that tab below.
struct DeviceSidebar: View {
    @Bindable var model: AppModel
    let device: AppModel.DeviceEntry
    var remap: RemapController?
    var scenes: LightingScenesController?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tab: DeviceTab {
        device.tabs.contains(model.selectedTab) ? model.selectedTab : (device.tabs.first ?? .info)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
                .padding(.horizontal, Theme.inset).padding(.top, 44).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    content
                        .id(tab)
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
        .animation(Motion(reduce: reduceMotion).snappy, value: tab)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(device.tabs, id: \.self) { candidate in
                Button {
                    withAnimation(Motion(reduce: reduceMotion).snappy) { model.selectedTab = candidate }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: candidate.symbol).font(.system(size: 12, weight: candidate == tab ? .semibold : .regular))
                        candidate.title.font(.callout.weight(candidate == tab ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .foregroundStyle(candidate == tab ? AnyShapeStyle(device.accent) : AnyShapeStyle(.secondary))
                    .background {
                        if candidate == tab {
                            RoundedRectangle(cornerRadius: Theme.chipRadius - 2, style: .continuous).fill(device.accent.opacity(0.22))
                                .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius - 2, style: .continuous).strokeBorder(device.accent.opacity(0.45), lineWidth: 1))
                                .matchedGeometryEffect(id: "tab", in: tabSpace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: candidate.name))
                .accessibilityLabel(candidate.title)
                .accessibilityAddTraits(candidate == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.chipRadius + 1, style: .continuous))
    }

    @Namespace private var tabSpace

    private func has(_ section: ControlSection) -> Bool { device.sections.contains(section) }

    @ViewBuilder private var content: some View {
        switch tab {
        case .light:
            if has(.lighting) { SpecsPanel(model: model, device: device, section: .lighting, scenes: scenes, remap: remap) }
            if has(.image) { SpecsPanel(model: model, device: device, section: .image, scenes: scenes, remap: remap) }
        case .keys:
            if has(.buttons) { ButtonsPanel(model: model, device: device, remap: remap) }
            if has(.performance) {
                // DPI and polling belong with the keys: they are what the device does, not how it looks.
                DisclosureCard(title: Text("Performance"), symbol: Titles.symbol(for: .performance), expanded: device.category == .mouse) {
                    SpecsPanel(model: model, device: device, section: .performance, scenes: scenes, remap: remap)
                }
            }
        case .info:
            if has(.info) { SpecsPanel(model: model, device: device, section: .info, scenes: scenes, remap: remap) }
            else { Card { Text(verbatim: device.name).font(.callout.weight(.medium)); Text(verbatim: device.usbId.description).font(.caption.monospaced()).foregroundStyle(.secondary) } }
            if has(.advanced) {
                DisclosureCard(title: Text("Advanced"), symbol: Titles.symbol(for: .advanced)) {
                    SpecsPanel(model: model, device: device, section: .advanced, scenes: scenes, remap: remap)
                }
            }
        }
    }
}

/// The generated controls of one section, grouped on cards.
struct SpecsPanel: View {
    @Bindable var model: AppModel
    let device: AppModel.DeviceEntry
    let section: ControlSection
    var scenes: LightingScenesController?
    var remap: RemapController?

    private struct Block { let id: String; let title: Text?; let specs: [ControlSpec] }

    /// Specs that share a group go on one card; the rest get a card each.
    private func blocks(of specs: [ControlSpec], hidingEffects: Bool, hidingBrightness: Bool = false) -> [Block] {
        var result: [Block] = []
        // Automatic switches come first in a group: the manual control below them is disabled while they are on.
        let ordered = specs.enumerated().sorted { ($0.element.id.hasSuffix("_auto") ? 0 : 1, $0.offset) < ($1.element.id.hasSuffix("_auto") ? 0 : 1, $1.offset) }.map(\.element)
        for spec in ordered {
            if case .keyLighting = spec.kind { continue }
            if hidingEffects, case .lighting = spec.kind { continue }
            if hidingBrightness, spec.capability.type == .brightness { continue }
            if let key = spec.group {
                if let index = result.firstIndex(where: { $0.id == key }) {
                    result[index] = Block(id: key, title: result[index].title, specs: result[index].specs + [spec])
                } else {
                    result.append(Block(id: key, title: Titles.group(key), specs: [spec]))
                }
            } else {
                result.append(Block(id: spec.id, title: nil, specs: [spec]))
            }
        }
        return result
    }

    var body: some View {
        let specs = device.specs.filter { $0.section == section }
        let hasKeys = section == .lighting && specs.contains { if case .keyLighting = $0.kind { true } else { false } }
        let painting = model.perKeyActive.contains(device.id)
        VStack(alignment: .leading, spacing: Theme.gap) {
            let hasLighting = section == .lighting && specs.contains { if case .lighting = $0.kind { true } else { false } }
            let scenesOn = scenes?.enabled ?? false
            if section == .lighting, scenes != nil, hasKeys || hasLighting {
                Card {
                    Segmented(options: LightingTool.available(hasKeys: hasKeys), selection: Binding(get: { scenesOn ? .scenes : (painting ? .perKey : .effects) }, set: { tool in
                        switch tool {
                        case .effects: scenes?.setEnabled(false); model.setPerKey(false, for: device.id)
                        case .perKey: scenes?.setEnabled(false); model.setPerKey(true, for: device.id)
                        case .scenes: if painting { model.setPerKey(false, for: device.id) }; scenes?.setEnabled(true)
                        }
                    }), tint: device.accent) { $0.title }
                }
            } else if hasKeys {
                Card {
                    Segmented(options: [false, true], selection: Binding(get: { painting }, set: { model.setPerKey($0, for: device.id) }),
                              tint: device.accent) { $0 ? Text("Per key") : Text("Effects") }
                }
            }
            if section == .lighting, scenesOn, let scenes {
                LightingScenesPanel(scenes: scenes, remap: remap, accent: device.accent)
            }
            if hasKeys && painting && !scenesOn {
                PerKeyCard(model: model, device: device)
            }
            ForEach(blocks(of: specs, hidingEffects: (hasKeys && painting) || (section == .lighting && scenesOn), hidingBrightness: section == .lighting && scenesOn), id: \.id) { block in
                Card(title: block.title) {
                    ForEach(block.specs) { spec in ControlRow(model: model, device: device, spec: spec) }
                }
            }
            if section == .lighting, model.devices.filter({ $0.specs.contains { if case .lighting = $0.kind { true } else { false } } }).count > 1 {
                Button { model.syncLighting(from: device.id) } label: { Label("Match other devices", systemImage: "link") }
                    .buttonStyle(PillButtonStyle())
                    .help("Use this color on every other device with lighting")
            }
            if section == .image {
                Button { model.resetImage(for: device.id) } label: { Label("Reset to defaults", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(PillButtonStyle())
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

    var body: some View {
        Card(title: Text("Paint")) {
            Text("Click or drag over the keys to color them.").font(.callout).foregroundStyle(.secondary)
            ColorField(selected: model.brush) { model.brush = $0 }
            HStack {
                Button("Fill all") { model.fillKeys(with: model.brush, for: device.id) }.buttonStyle(PillButtonStyle())
                Button("Clear") { model.fillKeys(with: nil, for: device.id) }.buttonStyle(PillButtonStyle())
            }
        }
    }
}

/// How the lighting of a device is driven.
enum LightingTool: Hashable {
    case effects, perKey, scenes
    static func available(hasKeys: Bool) -> [LightingTool] { hasKeys ? [.effects, .perKey, .scenes] : [.effects, .scenes] }
    var title: Text {
        switch self {
        case .effects: Text("Effects")
        case .perKey: Text("Per key")
        case .scenes: Text("Scenes")
        }
    }
}
