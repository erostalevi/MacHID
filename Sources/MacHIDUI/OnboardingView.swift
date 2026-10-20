import SwiftUI
import AVFoundation
import MacHIDIOKit
import MacHIDDomain

enum OnboardingStore {
    static let key = "onboarding.completed"
}

/// First-run walkthrough: what MacHID does, which devices it found, and the permissions it can use.
/// Nothing is requested until a button is pressed, and every permission can be skipped.
public struct OnboardingView: View {
    var remap: RemapController?
    var model: AppModel?
    let finish: () -> Void
    @State private var step = 0
    @State private var inputGranted = InputMonitoringPermission.isGranted
    @State private var camera = CameraAuthorization(AVCaptureDevice.authorizationStatus(for: .video))
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let lastStep = 3

    public init(remap: RemapController?, model: AppModel? = nil, finish: @escaping () -> Void) {
        self.remap = remap
        self.model = model
        self.finish = finish
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome
                case 1: devices
                case 2: permissions
                default: ready
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 18)), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(30)
        .frame(width: 520, height: 470)
        .flatSurface(cornerRadius: 30)
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        inputGranted = InputMonitoringPermission.isGranted
        camera = CameraAuthorization(AVCaptureDevice.authorizationStatus(for: .video))
    }

    private func go(_ next: Int) {
        withAnimation(Motion(reduce: reduceMotion).smooth) { step = next }
    }

    // MARK: Chrome

    private var footer: some View {
        HStack {
            if step > 0 { Button("Back") { go(step - 1) }.buttonStyle(PillButtonStyle()) }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0...lastStep, id: \.self) { index in
                    Capsule().fill(index == step ? Color.accentColor : .white.opacity(0.25))
                        .frame(width: index == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Step \(step + 1) of \(lastStep + 1)"))
            Spacer()
            if step < lastStep {
                Button("Continue") { go(step + 1) }.buttonStyle(PillButtonStyle(tint: .accentColor, selected: true))
            } else {
                Button("Get started") { finish() }.buttonStyle(PillButtonStyle(tint: .accentColor, selected: true))
            }
        }
    }

    private func page(symbol: String? = nil, image: NSImage? = nil, title: Text, @ViewBuilder body: () -> some View) -> some View {
        VStack(spacing: 16) {
            Group {
                if let image { Image(nsImage: image).resizable().frame(width: 84, height: 84) }
                else if let symbol {
                    Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(Color.accentColor)
                        .frame(width: 84, height: 84)
                }
            }
            .accessibilityHidden(true)
            title.font(.title.weight(.semibold)).multilineTextAlignment(.center)
            body()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Steps

    private var welcome: some View {
        page(image: NSApp.applicationIconImage, title: Text("Welcome to MacHID")) {
            Text("Your mouse, keyboard and camera, set up from one calm place. No vendor software.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                line("lightbulb", Text("Lighting, DPI and image controls that update live."))
                line("computermouse", Text("Change what every button and key does."))
                line("person.crop.circle", Text("Profiles that switch automatically per app."))
            }
            .padding(.top, 6)
        }
    }

    private var devices: some View {
        page(symbol: "cable.connector.horizontal", title: Text("Your devices")) {
            if let model, !model.devices.isEmpty {
                VStack(spacing: 8) {
                    ForEach(model.devices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: Titles.symbol(for: device.category)).frame(width: 24).foregroundStyle(device.accent)
                            Text(verbatim: device.name).font(.callout.weight(.medium))
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .flatSurface(cornerRadius: Theme.chipRadius + 2)
                    }
                }
                .frame(maxWidth: 380)
            } else {
                Text("Plug in a supported mouse, keyboard or camera. MacHID picks it up automatically.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var permissions: some View {
        page(symbol: "lock.shield", title: Text("Permissions")) {
            Text("Each one is optional and only used for what it says. You can change them later in System Settings.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).font(.callout)
            VStack(spacing: 8) {
                permissionRow(symbol: "keyboard", title: Text("Input Monitoring"), detail: Text("Talk to keyboards and mice."),
                              granted: inputGranted) { PermissionActions.requestInputMonitoring() }
                permissionRow(symbol: "web.camera", title: Text("Camera"), detail: Text("Live preview of your camera."),
                              granted: camera == .authorized) {
                    if camera == .notDetermined { AVCaptureDevice.requestAccess(for: .video) { _ in Task { @MainActor in refresh() } } }
                    else { CameraPermissionActions.openSettings() }
                }
                if let remap {
                    permissionRow(symbol: "command", title: Text("Accessibility"), detail: Text("Only for remapping and macros."),
                                  granted: remap.accessibilityGranted) { remap.requestPermissions() }
                }
            }
            .frame(maxWidth: 400)
        }
    }

    private var ready: some View {
        page(symbol: "checkmark.seal", title: Text("You are all set")) {
            VStack(alignment: .leading, spacing: 10) {
                line("macwindow", Text("Pick a part of the device to change it, or use the tabs on the right."))
                line("menubar.rectangle", Text("Quick controls live in the menu bar."))
                line("gearshape", Text("Open this welcome again from Settings > General."))
            }
        }
    }

    // MARK: Pieces

    private func line(_ symbol: String, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            text.font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(symbol: String, title: Text, detail: Text, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                title.font(.callout.weight(.medium))
                detail.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            } else {
                Button("Allow", action: action).buttonStyle(PillButtonStyle())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .flatSurface(cornerRadius: Theme.chipRadius + 2)
        .accessibilityElement(children: .combine)
    }
}
