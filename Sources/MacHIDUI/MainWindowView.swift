import SwiftUI
import MacHIDDomain

/// One floating glass panel: the device on the left, its settings on the right. The window has a fixed size.
public struct MainWindowView: View {
    @Bindable var model: AppModel
    @State private var savingProfile = false
    @State private var profileName = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(OnboardingStore.key) private var onboardingDone = false
    var remap: RemapController?

    public init(model: AppModel, remap: RemapController? = nil) { self.model = model; self.remap = remap }

    public var body: some View {
        ZStack {
            if let device = model.selectedDevice {
                HStack(spacing: 0) {
                    stage(device)
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1).padding(.vertical, 18)
                    DeviceSidebar(model: model, device: device, remap: remap)
                }
            } else if !model.hasScanned {
                loadingState
            } else {
                emptyState
            }
            if !onboardingDone {
                Color.black.opacity(0.28)
                OnboardingView(remap: remap, model: model) { withAnimation(Motion(reduce: reduceMotion).smooth) { onboardingDone = true } }
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            notices
        }
        .frame(width: Theme.windowSize.width, height: Theme.windowSize.height)
        .glassPanelWindow()
        .motion(\.smooth, value: model.selectedDeviceID)
        .motion(\.smooth, value: model.banner)
        .motion(\.smooth, value: model.hasScanned)
    }

    // MARK: Stage

    private func stage(_ device: AppModel.DeviceEntry) -> some View {
        ZStack {
            DeviceStage(model: model, device: device, remap: remap) { _ in
                withAnimation(Motion(reduce: reduceMotion).snappy) { model.selectedSection = .buttons }
            }
            VStack(spacing: 0) {
                header(device)
                Spacer()
                if model.devices.count > 1 { dock }
            }
            .padding(.horizontal, Theme.inset).padding(.bottom, Theme.inset)
        }
        .frame(maxWidth: .infinity)
    }

    private func header(_ device: AppModel.DeviceEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: device.name).font(.title2.weight(.semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    if let percent = model.batteryPercent(for: device.id) { BatteryBadge(percent: percent, charging: model.isCharging(device.id)) }
                    else { Text(verbatim: device.usbId.description).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            }
            .padding(.leading, 78)   // clears the window buttons
            Spacer()
            profileMenu(device)
        }
        .padding(.top, 18)
    }

    /// Switch between connected devices.
    private var dock: some View {
        HStack(spacing: 6) {
            ForEach(model.devices) { entry in
                Button { withAnimation(Motion(reduce: reduceMotion).smooth) { model.selectedDeviceID = entry.id } } label: {
                    Image(systemName: Titles.symbol(for: entry.category))
                        .font(.system(size: 16, weight: entry.id == model.selectedDevice?.id ? .semibold : .regular))
                        .frame(width: 44, height: 36)
                        .foregroundStyle(entry.id == model.selectedDevice?.id ? AnyShapeStyle(entry.accent) : AnyShapeStyle(.secondary))
                        .background {
                            if entry.id == model.selectedDevice?.id {
                                RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous).fill(entry.accent.opacity(0.22))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous).strokeBorder(entry.accent.opacity(0.45), lineWidth: 1))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: entry.name))
                .accessibilityLabel(Text(verbatim: entry.name))
            }
        }
        .padding(4)
        .flatSurface(cornerRadius: Theme.chipRadius + 4)
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

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cable.connector.horizontal").font(.system(size: 54, weight: .thin)).foregroundStyle(.secondary)
            Text("No supported devices").font(.title2.weight(.semibold))
            Text("Plug in a mouse, keyboard or camera. MacHID picks it up automatically.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Looking for devices…").foregroundStyle(.secondary)
        }
        .padding(40)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private var notices: some View {
        VStack(spacing: 10) {
            Spacer()
            if let banner = model.banner {
                bannerPill(banner)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: banner) {
                        try? await Task.sleep(for: .seconds(6))
                        if !Task.isCancelled, model.banner == banner { model.banner = nil }
                    }
            }
            if !model.inputMonitoringGranted && !model.devices.isEmpty { permissionPill }
        }
        .padding(20)
        .padding(.trailing, Theme.sidebarWidth)   // notices belong to the stage side
    }

    private func bannerPill(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(verbatim: message).font(.callout).lineLimit(2)
            Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .flatSurface(cornerRadius: 22)
    }

    private var permissionPill: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").foregroundStyle(.yellow)
            Text("MacHID needs Input Monitoring to talk to keyboards and mice.").font(.callout)
            Button("Allow") { PermissionActions.requestInputMonitoring() }.buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .flatSurface(cornerRadius: 22)
    }
}
