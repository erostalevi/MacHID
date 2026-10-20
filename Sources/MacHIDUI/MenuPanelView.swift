import SwiftUI
import MacHIDDomain

/// The menu bar panel: connected devices with a profile switcher and the quick controls of each.
public struct MenuPanelView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.devices.isEmpty {
                Text("No supported devices connected").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 18)
            } else {
                GlassGroup(spacing: 10) {
                    VStack(spacing: 10) {
                        ForEach(model.devices) {
                            DeviceCard(model: model, device: $0)
                                .transition(.scale(scale: 0.94).combined(with: .opacity))
                        }
                    }
                }
                .motion(\.smooth, value: model.devices.map(\.id))
            }
            if !model.inputMonitoringGranted && !model.devices.isEmpty { permissionRow }
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint)
            Text("MacHID").font(.headline)
            Spacer()
            Circle().fill(model.devices.isEmpty ? Color.secondary : Color.green).frame(width: 8, height: 8)
        }
    }

    private var permissionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.yellow)
            Text("Input Monitoring is needed").font(.caption)
            Spacer()
            Button("Allow") { PermissionActions.requestInputMonitoring() }.buttonStyle(PillButtonStyle())
        }
        .padding(10).glassSurface(cornerRadius: 16)
    }

    private var footer: some View {
        HStack {
            Button { show() } label: { Label("Open MacHID…", systemImage: "macwindow") }
                .buttonStyle(PillButtonStyle())
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut("q")
        }
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
                Spacer()
                profileMenu
            }
            ForEach(quickSpecs) { spec in quickControl(spec) }
        }
        .padding(12)
        .glassSurface(cornerRadius: 20)
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
                Titles.control(spec.id).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
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
