import SwiftUI
import MacHIDDomain

/// Main window: the device in the middle, glass pills around it, one floating card of controls.
public struct MainWindowView: View {
    @Bindable var model: AppModel
    @State private var section: ControlSection = .lighting
    @State private var savingProfile = false
    @State private var profileName = ""
    @Namespace private var chipNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        ZStack {
            backdrop
            if let device = model.selectedDevice {
                VStack(spacing: 20) {
                    topBar(device)
                    Spacer(minLength: 0)
                    DeviceArt(category: device.definition?.category ?? .other, accent: accent(for: device),
                              artwork: model.artwork(for: device),
                              interactive: Set(device.specs.map(\.id))) { capability in
                        if let spec = device.specs.first(where: { $0.id == capability }) {
                            withAnimation(Motion(reduce: reduceMotion).snappy) { section = spec.section }
                        }
                    }
                        .id(device.id)
                        .transition(.blurReplace)
                    sectionChips(device)
                    if sections(of: device).contains(effectiveSection(device)) {
                        ControlPanel(model: model, device: device, section: effectiveSection(device))
                            .id(effectiveSection(device))
                            .transition(.blurReplace.combined(with: .offset(y: 8)))
                    }
                    Spacer(minLength: 0)
                }
                .padding(28)
                .motion(\.smooth, value: effectiveSection(device))
            } else {
                emptyState
            }
            VStack(spacing: 10) {
                Spacer()
                if let banner = model.banner { bannerPill(banner) }
                if !model.inputMonitoringGranted && !model.devices.isEmpty { permissionPill }
            }
            .padding(20)
        }
        .frame(minWidth: 680, minHeight: 600)
        .motion(\.smooth, value: model.selectedDeviceID)
    }

    // MARK: Pieces

    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.background)
            LinearGradient(colors: [(model.selectedDevice.map(accent(for:)) ?? .accentColor).opacity(0.28), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }

    private func topBar(_ device: AppModel.DeviceEntry) -> some View {
        GlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(model.devices) { entry in
                        Button { model.selectedDeviceID = entry.id } label: {
                            Label(entry.name, systemImage: Titles.symbol(for: entry.definition?.category ?? .other))
                        }
                    }
                } label: {
                    Label(device.name, systemImage: Titles.symbol(for: device.definition?.category ?? .other))
                }
                .menuStyle(.button).buttonStyle(PillButtonStyle())
                .fixedSize()

                Spacer()

                profileMenu(device)
            }
        }
    }

    private func profileMenu(_ device: AppModel.DeviceEntry) -> some View {
        let available = model.profiles(for: device.id)
        let active = model.activeProfile(for: device.id)
        return HStack(spacing: 8) {
            Menu {
                if available.isEmpty { Text("No profiles yet") }
                ForEach(available) { profile in
                    Button {
                        Task { await model.applyProfile(profile.id, to: device.id) }
                    } label: {
                        if profile.id == active?.id { Label(profile.name, systemImage: "checkmark") } else { Text(verbatim: profile.name) }
                    }
                }
                if let active {
                    Divider()
                    Button("Delete “\(active.name)”", role: .destructive) { Task { await model.deleteProfile(active.id) } }
                }
            } label: {
                Label { if let active { Text(verbatim: active.name) } else { Text("Profile") } } icon: { Image(systemName: "person.crop.circle") }
            }
            .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()

            Button { profileName = ""; savingProfile = true } label: { Image(systemName: "plus") }
                .buttonStyle(PillButtonStyle())
                .help("Save current settings as a profile")
                .popover(isPresented: $savingProfile, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Save profile").font(.headline)
                        TextField("Profile name", text: $profileName)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                            .onSubmit { saveProfile(device) }
                        HStack {
                            Spacer()
                            Button("Save") { saveProfile(device) }.keyboardShortcut(.defaultAction)
                                .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(16)
                }
        }
    }

    private func saveProfile(_ device: AppModel.DeviceEntry) {
        let name = profileName
        savingProfile = false
        Task { await model.saveProfile(named: name, from: device.id) }
    }

    /// One glass capsule holding the sections; the highlight slides to the selected one.
    private func sectionChips(_ device: AppModel.DeviceEntry) -> some View {
        let motion = Motion(reduce: reduceMotion)
        let selected = effectiveSection(device)
        return HStack(spacing: 4) {
            ForEach(sections(of: device), id: \.self) { candidate in
                Button {
                    withAnimation(motion.snappy) { section = candidate }
                } label: {
                    Label { Titles.section(candidate) } icon: { Image(systemName: Titles.symbol(for: candidate)) }
                        .font(.callout.weight(candidate == selected ? .semibold : .regular))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background {
                            if candidate == selected {
                                Capsule().fill(accent(for: device).opacity(0.28))
                                    .overlay(Capsule().strokeBorder(accent(for: device).opacity(0.5), lineWidth: 1))
                                    .matchedGeometryEffect(id: "selection", in: chipNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(candidate == selected ? .isSelected : [])
            }
        }
        .padding(5)
        .glassSurface(cornerRadius: 26)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cable.connector.horizontal").font(.system(size: 54, weight: .thin)).foregroundStyle(.secondary)
            Text("No supported devices").font(.title2.weight(.semibold))
            Text("Plug in a mouse, keyboard or camera. MacHID picks it up automatically.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .glassSurface(cornerRadius: 32)
    }

    private func bannerPill(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(verbatim: message).font(.callout).lineLimit(2)
            Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassSurface(cornerRadius: 22)
    }

    private var permissionPill: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").foregroundStyle(.yellow)
            Text("MacHID needs Input Monitoring to talk to keyboards and mice.").font(.callout)
            Button("Allow") { PermissionActions.requestInputMonitoring() }.buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassSurface(cornerRadius: 22)
    }

    // MARK: Helpers

    private func sections(of device: AppModel.DeviceEntry) -> [ControlSection] {
        ControlSection.allCases.filter { candidate in device.specs.contains { $0.section == candidate } }
    }

    private func effectiveSection(_ device: AppModel.DeviceEntry) -> ControlSection {
        let available = sections(of: device)
        return available.contains(section) ? section : (available.first ?? .info)
    }

    /// Accent follows the backlight color when the device has one.
    private func accent(for device: AppModel.DeviceEntry) -> Color {
        for (_, value) in device.values {
            if case .color(let color) = value { return color.color }
        }
        switch device.definition?.category {
        case .keyboard: return .purple
        case .camera: return .teal
        default: return .blue
        }
    }
}
