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
        VStack(alignment: .leading, spacing: Theme.gap - 2) {
            topBar
            if let device = model.selectedDevice {
                miniStage(device)
                DeviceCard(model: model, device: device)
                    .id(device.id)
                    .transition(.opacity)
            } else {
                emptyState
            }
            if !model.inputMonitoringGranted && !model.devices.isEmpty { permissionRow }
            if let remap { remapRow(remap); macrosSection(remap) }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .motion(\.smooth, value: model.selectedDeviceID)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cable.connector.horizontal").font(.system(size: 34, weight: .thin)).foregroundStyle(.secondary)
            Text("No supported devices connected").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22)
    }

    /// The same device bar as the window, with the app's name and the selected device's battery.
    private var topBar: some View {
        HStack(spacing: 10) {
            if model.devices.count > 1 {
                HStack(spacing: 4) {
                    ForEach(model.devices) { entry in
                        let active = entry.id == model.selectedDevice?.id
                        Button { withAnimation(.snappy(duration: 0.25)) { model.selectedDeviceID = entry.id } } label: {
                            Image(systemName: Titles.symbol(for: entry.category))
                                .font(.system(size: 14, weight: active ? .semibold : .regular))
                                .frame(width: 38, height: 30)
                                .foregroundStyle(active ? AnyShapeStyle(entry.accent) : AnyShapeStyle(.secondary))
                                .background {
                                    if active {
                                        RoundedRectangle(cornerRadius: Theme.chipRadius - 2, style: .continuous).fill(entry.accent.opacity(0.22))
                                            .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius - 2, style: .continuous).strokeBorder(entry.accent.opacity(0.45), lineWidth: 1))
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(Text(verbatim: entry.name)).accessibilityLabel(Text(verbatim: entry.name))
                    }
                }
                .padding(3).flatSurface(cornerRadius: Theme.chipRadius + 1)
            } else if let device = model.selectedDevice {
                Image(systemName: Titles.symbol(for: device.category)).font(.system(size: 15, weight: .semibold)).foregroundStyle(device.accent)
            }
            Spacer()
            if let device = model.selectedDevice {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: device.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let percent = model.batteryPercent(for: device.id) { BatteryBadge(percent: percent, charging: model.isCharging(device.id)) }
                    else { Text("Connected").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    /// A small live drawing of the selected device (the camera is never started from the menu).
    @ViewBuilder private func miniStage(_ device: AppModel.DeviceEntry) -> some View {
        ZStack {
            switch device.category {
            case .mouse:
                MouseSimView(accent: device.accent, lightsOn: miniLightsOn(device), dpi: nil, selected: nil)
                    .scaleEffect(0.29).frame(width: 420, height: 440).frame(width: 150, height: 132).clipped()
            case .keyboard:
                if let layout = KeyboardLayout.layout(forDefinitionID: device.definition?.id) {
                    KeyboardSimView(layout: layout, effect: miniEffect(device), brightness: miniBrightness(device))
                        .scaleEffect(0.62).frame(width: 540, height: 280).frame(width: 330, height: 132).clipped()
                } else { icon(device) }
            default: icon(device)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 132)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func icon(_ device: AppModel.DeviceEntry) -> some View {
        Image(systemName: Titles.symbol(for: device.category)).font(.system(size: 54, weight: .thin)).foregroundStyle(device.accent)
    }

    private func miniLightsOn(_ device: AppModel.DeviceEntry) -> Bool {
        for spec in device.specs { if case .lighting = spec.kind { return LightingModes.mode(of: device.values[spec.id]) != "off" } }
        return true
    }
    private func miniEffect(_ device: AppModel.DeviceEntry) -> SimEffect {
        if model.perKeyActive.contains(device.id), case .keyFrame(let frame)? = device.values["key_lighting"] { return SimEffect.from(nil, frame: frame) }
        for spec in device.specs { if case .lighting = spec.kind { return SimEffect.from(device.values[spec.id]) } }
        return SimEffect()
    }
    private func miniBrightness(_ device: AppModel.DeviceEntry) -> Double {
        if case .int(let value)? = device.values["brightness"] { return Double(value) / 100 }
        return 1
    }

    private func remapRow(_ remap: RemapController) -> some View {
        HStack {
            Image(systemName: "keyboard").foregroundStyle(.secondary).frame(width: 20)
            Text("Remapping").font(.callout)
            if remap.config.enabled {
                Circle().fill(remap.isActive ? Color.green : Color.orange).frame(width: 6, height: 6)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { remap.config.enabled }, set: { value in Task { await remap.setEnabled(value) } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .flatSurface(cornerRadius: Theme.cardRadius)
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
            .padding(14).flatSurface(cornerRadius: Theme.cardRadius)
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
        .padding(.horizontal, 14).padding(.vertical, 10).flatSurface(cornerRadius: Theme.cardRadius)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Profile").font(.callout).foregroundStyle(.secondary)
                Spacer()
                profileMenu
            }
            ForEach(quickSpecs) { spec in quickControl(spec) }
            dpiChips
            if let lighting = lightingSpec { lightingMenu(lighting) }
        }
        .padding(14).flatSurface(cornerRadius: Theme.cardRadius)
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
                    set: { model.set(.int(min + Int((($0 - Double(min)) / Double(Swift.max(step, 1))).rounded()) * Swift.max(step, 1)), capability: spec.id, on: device.id) }),
                       in: Double(min)...Double(max))
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
        let modes: [String] = { if case .lighting(let modes, _) = spec.kind { return modes }; return [] }()
        let current = LightingModes.mode(of: device.values[spec.id])
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Titles.control(spec.id).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Spacer()
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
            }
            if current != "off", current.map(LightingModes.usesColor) ?? true {
                HStack(spacing: 7) {
                    ForEach(LEDPalette.colors, id: \.hex) { swatch in
                        Button { model.set(LightingModes.value(for: current ?? "static", color: swatch), capability: spec.id, on: device.id) } label: {
                            Circle().fill(swatch.color).frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                                .overlay { if swatch == currentColor(spec) { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(swatch.isLight ? .black : .white) } }
                        }
                        .buttonStyle(.plain).help(Text(verbatim: "#" + swatch.hex))
                    }
                }
            }
        }
    }

    /// DPI presets as one-tap chips.
    @ViewBuilder private var dpiChips: some View {
        if case .text(let text)? = device.values["dpi_stages"], let stages = DPIStages(text: text) {
            let current: Int? = { if case .int(let value)? = device.values["dpi"] { value } else { nil } }()
            HStack(spacing: 6) {
                ForEach(Array(stages.values.enumerated()), id: \.offset) { _, value in
                    Button { model.set(.int(value), capability: "dpi", on: device.id) } label: {
                        Text(verbatim: "\(value)").font(.caption.weight(.semibold).monospacedDigit())
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(device.accent.opacity(value == current ? 0.3 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(device.accent.opacity(value == current ? 0.7 : 0), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
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
