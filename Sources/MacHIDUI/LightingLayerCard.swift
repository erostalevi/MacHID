import SwiftUI
import MacHIDDomain

/// One layer of a scene. Folded it is a single line (swatch, name, eye); open it shows the effect's main controls and a
/// "More" group with the rest. The open layer follows the click, or the pointer resting on a folded layer.
struct LayerCard: View {
    @Bindable var scenes: LightingScenesController
    let layer: LightingLayer
    let index: Int, count: Int
    var accent: Color
    let expanded: Bool
    let expand: () -> Void
    let update: ((inout LightingLayer) -> Void) -> Void
    let move: (Int) -> Void
    let remove: () -> Void

    @State private var hoverTask: Task<Void, Never>?
    @State private var showMore = false

    private var title: Text {
        switch layer.kind {
        case .solid: Text("Solid color")
        case .spectrum: Text("Spectrum")
        case .wave: Text("Wave")
        case .breathing: Text("Breathing")
        case .starlight: Text("Starlight")
        case .reactive: Text("Reactive")
        case .rainbowRipple: Text("Rainbow ripple")
        case .gradient: Text("Gradient")
        case .painted: Text("Painted keys")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    parameters
                    DisclosureGroup(isExpanded: $showMore) {
                        VStack(alignment: .leading, spacing: 10) {
                            more
                            SettingRow(title: Text("Opacity"), value: Text(verbatim: "\(Int((layer.opacity * 100).rounded()))%")) {
                                Slider(value: Binding(get: { layer.opacity }, set: { value in update { $0.opacity = value } }), in: 0...1)
                            }
                            HStack {
                                Text("Blend").font(.callout)
                                Spacer()
                                Picker("", selection: Binding(get: { layer.blend }, set: { value in update { $0.blend = value } })) {
                                    ForEach(LightingBlend.allCases, id: \.self) { Text(verbatim: Titles.humanize($0.rawValue)).tag($0) }
                                }
                                .labelsHidden().fixedSize()
                            }
                        }
                        .padding(.top, 8)
                    } label: { Text("More").font(.callout).foregroundStyle(.secondary) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, expanded ? 12 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatSurface(cornerRadius: Theme.cardRadius, tint: expanded ? accent.opacity(0.35) : nil)
        .opacity(layer.enabled ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { if !expanded { expand() } }
        .onHover { inside in
            hoverTask?.cancel()
            guard inside, !expanded else { return }
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { expand() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { update { $0.enabled.toggle() } } label: {
                Image(systemName: layer.enabled ? "eye" : "eye.slash").frame(width: 20)
            }
            .buttonStyle(.plain).foregroundStyle(layer.enabled ? .primary : .secondary)
            .help(layer.enabled ? "Hide layer" : "Show layer")
            .accessibilityLabel(layer.enabled ? Text("Hide layer") : Text("Show layer"))
            LayerSwatch(kind: layer.kind)
            title.font(.callout.weight(expanded ? .semibold : .regular))
            if !expanded { summary.font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if expanded {
                Button { move(-1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(index == 0).help("Move down")
                Button { move(1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(index == count - 1).help("Move up")
                Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.plain).help("Remove layer")
            } else {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(.secondary)
    }

    /// What a folded layer shows after its name.
    private var summary: Text {
        switch layer.kind {
        case .spectrum(let speed), .wave(let speed, _), .breathing(_, let speed), .starlight(_, let speed, _), .rainbowRipple(let speed, _):
            Text(verbatim: String(format: "%.1f×", speed))
        case .painted(let cells): Text("\(cells.count) keys")
        default: Text(verbatim: "")
        }
    }

    // MARK: Main controls

    @ViewBuilder private var parameters: some View {
        switch layer.kind {
        case .solid(let color):
            ColorField(selected: color) { picked in update { $0.kind = .solid(picked) } }
        case .spectrum(let speed):
            speedRow(speed) { value in update { $0.kind = .spectrum(speed: value) } }
        case .wave(let speed, let direction):
            speedRow(speed) { value in update { $0.kind = .wave(speed: value, direction: direction) } }
        case .breathing(let color, let speed):
            ColorField(selected: color) { picked in update { $0.kind = .breathing(color: picked, speed: speed) } }
            speedRow(speed) { value in update { $0.kind = .breathing(color: color, speed: value) } }
        case .starlight(let colors, let speed, let density):
            ColorField(selected: colors.first ?? RGBColor(r: 255, g: 255, b: 255)) { picked in
                update { var list = colors; if list.isEmpty { list = [picked] } else { list[0] = picked }; $0.kind = .starlight(colors: list, speed: speed, density: density) }
            }
            speedRow(speed) { value in update { $0.kind = .starlight(colors: colors, speed: value, density: density) } }
        case .reactive(let color, let decay, let ripple):
            ColorField(selected: color) { picked in update { $0.kind = .reactive(color: picked, decay: decay, ripple: ripple) } }
        case .rainbowRipple(let speed, let decay):
            speedRow(speed) { value in update { $0.kind = .rainbowRipple(speed: value, decay: decay) } }
        case .gradient(let from, let to, let angle):
            ColorField(selected: from, title: Text("From")) { picked in update { $0.kind = .gradient(from: picked, to: to, angle: angle) } }
            ColorField(selected: to, title: Text("To")) { picked in update { $0.kind = .gradient(from: from, to: picked, angle: angle) } }
        case .painted(let cells):
            let painting = scenes.paintingLayerID == layer.id
            Text("\(cells.count) keys painted").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { scenes.paintingLayerID = painting ? nil : layer.id } label: {
                    Label(painting ? "Done painting" : "Paint keys", systemImage: painting ? "checkmark" : "paintbrush")
                }
                .buttonStyle(PillButtonStyle(tint: accent, selected: painting))
                Button("Clear") { update { $0.kind = .painted([]) } }.buttonStyle(PillButtonStyle())
            }
        }
    }

    // MARK: Rarely needed controls (inside "More")

    @ViewBuilder private var more: some View {
        switch layer.kind {
        case .wave(let speed, let direction):
            Segmented(options: [0, 1], selection: Binding(get: { direction }, set: { value in update { $0.kind = .wave(speed: speed, direction: value) } }), tint: accent) {
                $0 == 0 ? Text("Left to right") : Text("Right to left")
            }
        case .starlight(let colors, let speed, let density):
            Toggle(isOn: Binding(get: { colors.count > 1 }, set: { on in
                update { $0.kind = .starlight(colors: on ? [colors.first ?? RGBColor(r: 255, g: 255, b: 255), RGBColor(r: 0, g: 229, b: 255)] : Array(colors.prefix(1)), speed: speed, density: density) }
            })) { Text("Second color").font(.callout) }.toggleStyle(.switch)
            if colors.count > 1 {
                ColorField(selected: colors[1]) { picked in update { var list = colors; list[1] = picked; $0.kind = .starlight(colors: list, speed: speed, density: density) } }
            }
            SettingRow(title: Text("Density"), value: Text(verbatim: "\(Int((density * 100).rounded()))%")) {
                Slider(value: Binding(get: { density }, set: { value in update { $0.kind = .starlight(colors: colors, speed: speed, density: value) } }), in: 0.05...1)
            }
        case .reactive(let color, let decay, let ripple):
            SettingRow(title: Text("Fade"), value: Text(verbatim: String(format: "%.1f s", decay))) {
                Slider(value: Binding(get: { decay }, set: { value in update { $0.kind = .reactive(color: color, decay: value, ripple: ripple) } }), in: 0.1...3)
            }
            Toggle(isOn: Binding(get: { ripple }, set: { value in update { $0.kind = .reactive(color: color, decay: decay, ripple: value) } })) { Text("Ripple outwards").font(.callout) }.toggleStyle(.switch)
        case .rainbowRipple(let speed, let decay):
            SettingRow(title: Text("Fade"), value: Text(verbatim: String(format: "%.1f s", decay))) {
                Slider(value: Binding(get: { decay }, set: { value in update { $0.kind = .rainbowRipple(speed: speed, decay: value) } }), in: 0.2...3)
            }
        case .gradient(let from, let to, let angle):
            SettingRow(title: Text("Angle"), value: Text(verbatim: "\(Int(angle))°")) {
                Slider(value: Binding(get: { angle }, set: { value in update { $0.kind = .gradient(from: from, to: to, angle: value.rounded()) } }), in: 0...360)
            }
        default: EmptyView()
        }
    }

    private func speedRow(_ speed: Double, set: @escaping (Double) -> Void) -> some View {
        SettingRow(title: Text("Speed"), value: Text(verbatim: String(format: "%.1f×", speed))) {
            Slider(value: Binding(get: { speed }, set: set), in: 0.1...4)
        }
    }
}

/// A tiny preview of what a layer looks like: its color, its gradient, or a rainbow for moving effects.
struct LayerSwatch: View {
    let kind: LightingLayerKind

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(fill)
            .frame(width: 22, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
            .overlay { if case .painted = kind { Image(systemName: "paintbrush.fill").font(.system(size: 8)).foregroundStyle(.white) } }
    }

    private var fill: AnyShapeStyle {
        let rainbow = LinearGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple], startPoint: .leading, endPoint: .trailing)
        switch kind {
        case .solid(let color), .breathing(let color, _), .reactive(let color, _, _): return AnyShapeStyle(color.color)
        case .starlight(let colors, _, _): return AnyShapeStyle((colors.first ?? RGBColor(r: 255, g: 255, b: 255)).color)
        case .gradient(let from, let to, _): return AnyShapeStyle(LinearGradient(colors: [from.color, to.color], startPoint: .leading, endPoint: .trailing))
        case .spectrum, .wave, .rainbowRipple: return AnyShapeStyle(rainbow)
        case .painted: return AnyShapeStyle(Color.gray.opacity(0.5))
        }
    }
}
