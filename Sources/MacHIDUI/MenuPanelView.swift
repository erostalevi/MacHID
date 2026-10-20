import SwiftUI
import MacHIDDomain

/// The menu bar panel: connected devices with a profile switcher and the quick controls of each.
public struct MenuPanelView: View {
    @Bindable var model: AppModel
    var remap: RemapController?
    var plugins: PluginsModel?
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel, remap: RemapController? = nil, plugins: PluginsModel? = nil) {
        self.model = model
        self.remap = remap
        self.plugins = plugins
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.devices.isEmpty {
                Text("No supported devices connected").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 14)
            } else {
                ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Divider().opacity(0.5) }
                    DeviceCard(model: model, device: device)
                }
            }
            if !model.inputMonitoringGranted && !model.devices.isEmpty { permissionRow }
            if let remap { macrosSection(remap) }
            Divider().opacity(0.5)
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder private func macrosSection(_ remap: RemapController) -> some View {
        let favorites = remap.favoriteMacros
        if !favorites.isEmpty || remap.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Macros").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if remap.isRunning {
                        Button { Task { await remap.stopMacros() } } label: { Label("Stop macros", systemImage: "stop.fill") }
                            .buttonStyle(PillButtonStyle(tint: .red, selected: true))
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                ForEach(favorites) { macro in
                    let approved = remap.isApproved(macro)
                    Button { Task { await remap.run(macroID: macro.id) } } label: {
                        Label { Text(verbatim: macro.name).lineLimit(1) } icon: { Image(systemName: approved ? "play.fill" : "exclamationmark.triangle.fill") }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!approved || remap.isRunning)
                    .help(approved ? Text("Run now") : Text("Needs your approval in Settings > Macros first"))
                    .accessibilityHint(approved ? Text("") : Text("Needs your approval in Settings > Macros first"))
                }
            }
            .motion(\.smooth, value: remap.isRunning)
        }
    }

    private var hasUpdates: Bool { !(plugins?.updates.isEmpty ?? true) }

    private var permissionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.yellow)
            Text("Input Monitoring is needed").font(.caption)
            Spacer()
            Button("Allow") { PermissionActions.requestInputMonitoring() }.buttonStyle(PillButtonStyle())
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { show() } label: { Label("Open MacHID", systemImage: "macwindow") }
            Spacer()
            Button {
                Task { await model.setAutomationPaused(!model.automation.paused) }
            } label: { Image(systemName: model.automation.paused ? "pause.circle.fill" : "pause.circle") }
                .help(model.automation.paused ? Text("Automatic profiles are paused") : Text("Pause automatic profiles"))
                .accessibilityLabel(Text("Pause automatic profiles"))
                .accessibilityAddTraits(model.automation.paused ? .isSelected : [])
            Button { openWindow(id: "settings"); NSApplication.shared.activate() } label: {
                Image(systemName: "gearshape")
                    .overlay(alignment: .topTrailing) {
                        if hasUpdates { Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: 4, y: -3) }
                    }
            }
                .help(hasUpdates ? Text("Settings: plugin updates are available") : Text("Settings"))
                .accessibilityLabel(hasUpdates ? Text("Settings, plugin updates available") : Text("Settings"))
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help(Text("Quit"))
                .accessibilityLabel(Text("Quit"))
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func show() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}

private struct DeviceCard: View {
    @Bindable var model: AppModel
    let device: AppModel.DeviceEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: Titles.symbol(for: device.definition?.category ?? .other)).frame(width: 22)
                Text(verbatim: device.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let percent = model.batteryPercent(for: device.id) {
                    BatteryBadge(percent: percent, charging: model.isCharging(device.id))
                }
                Spacer()
                profileMenu
            }
            ForEach(quickSpecs) { spec in quickControl(spec) }
            if let lighting = lightingSpec { lightingMenu(lighting) }
        }
    }

    /// The most useful controls at a glance: lighting brightness, DPI and the on/off of the backlight.
    private var quickSpecs: [ControlSpec] {
        device.specs.filter { spec in
            switch spec.kind {
            case .slider: spec.capability.type == .brightness || spec.capability.type == .dpi
            default: false
            }
        }
    }

    @ViewBuilder private func quickControl(_ spec: ControlSpec) -> some View {
        if case .slider(let min, let max, let step, _) = spec.kind {
            HStack(spacing: 10) {
                Titles.control(spec.id).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Slider(value: Binding(
                    get: { if case .int(let value)? = device.values[spec.id] { Double(value) } else { Double(min) } },
                    set: { model.set(.int(Int($0.rounded())), capability: spec.id, on: device.id) }),
                       in: Double(min)...Double(max), step: Double(step))
                if case .int(let value)? = device.values[spec.id] {
                    Text(verbatim: "\(value)").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
            }
            .disabled(!spec.isWritable)
        }
    }

    private var lightingSpec: ControlSpec? {
        device.specs.first { if case .lighting = $0.kind { return $0.isWritable }; return false }
    }

    private func lightingMenu(_ spec: ControlSpec) -> some View {
        let modes: [String] = { if case .lighting(let modes) = spec.kind { return modes }; return [] }()
        let current = LightingModes.mode(of: device.values[spec.id])
        return HStack(spacing: 10) {
            Titles.control(spec.id).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Menu {
                ForEach(modes, id: \.self) { mode in
                    Button {
                        model.set(LightingModes.value(for: mode, color: currentColor(spec)), capability: spec.id, on: device.id)
                    } label: {
                        if mode == current { Label { Titles.lightingMode(mode) } icon: { Image(systemName: "checkmark") } } else { Titles.lightingMode(mode) }
                    }
                }
            } label: {
                if let current { Titles.lightingMode(current) } else { Text("Lighting mode") }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(Text("Lighting mode"))
            Spacer()
        }
    }

    private func currentColor(_ spec: ControlSpec) -> MacHIDDomain.RGBColor {
        switch device.values[spec.id] {
        case .color(let rgb)?: rgb
        case .effect(let effect)? where effect.color != nil: effect.color!
        default: MacHIDDomain.RGBColor(r: 255, g: 255, b: 255)
        }
    }

    private var profileMenu: some View {
        let profiles = model.profiles(for: device.id)
        let active = model.activeProfile(for: device.id)
        return Menu {
            if profiles.isEmpty { Text("No profiles yet") }
            ForEach(profiles) { profile in
                Button {
                    Task { await model.applyProfile(profile.id, to: device.id) }
                } label: {
                    if profile.id == active?.id { Label(profile.name, systemImage: "checkmark") } else { Text(verbatim: profile.name) }
                }
            }
        } label: {
            if let active { Text(verbatim: active.name) } else { Text("Profile") }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}
