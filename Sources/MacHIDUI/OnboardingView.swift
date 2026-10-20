import SwiftUI
import MacHIDIOKit

enum OnboardingStore {
    static let key = "onboarding.completed"
}

/// First-run card: what MacHID does and the permissions it can use. Nothing is requested until a button is pressed.
public struct OnboardingView: View {
    var remap: RemapController?
    let finish: () -> Void
    @State private var step = 0
    @State private var inputGranted = InputMonitoringPermission.isGranted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let lastStep = 3

    public init(remap: RemapController?, finish: @escaping () -> Void) {
        self.remap = remap
        self.finish = finish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Welcome to MacHID").font(.title2.weight(.semibold))
                Spacer()
                Text("Step \(step + 1) of \(lastStep + 1)").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                switch step {
                case 0: intro
                case 1: inputMonitoring
                case 2: remapping
                default: done
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if step > 0 { Button("Back") { go(step - 1) }.buttonStyle(PillButtonStyle()) }
                Spacer()
                if step < lastStep {
                    Button("Continue") { go(step + 1) }.buttonStyle(PillButtonStyle())
                } else {
                    Button("Get started") { finish() }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .padding(26)
        .frame(width: 460)
        .glassSurface(cornerRadius: 30)
        .onAppear { inputGranted = InputMonitoringPermission.isGranted }
    }

    private func go(_ next: Int) {
        withAnimation(Motion(reduce: reduceMotion).smooth) { step = next }
    }

    private func line(_ symbol: String, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            text.fixedSize(horizontal: false, vertical: true)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacHID manages the settings of your mouse, keyboard and camera from one calm place.").foregroundStyle(.secondary)
            line("slider.horizontal.3", Text("Change lighting, DPI and image controls."))
            line("person.crop.circle", Text("Save profiles and apply them automatically per app."))
            line("menubar.rectangle", Text("Quick controls live in the menu bar."))
        }
    }

    private var inputMonitoring: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device control needs Input Monitoring so MacHID can talk to keyboards and mice.").foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: inputGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(inputGranted ? .green : .orange)
                Text(inputGranted ? "Input Monitoring is allowed" : "Input Monitoring is not allowed yet")
                    .font(.callout.weight(.medium))
            }
            .accessibilityElement(children: .combine)
            if !inputGranted {
                HStack {
                    Button("Allow Input Monitoring") { PermissionActions.requestInputMonitoring() }.buttonStyle(PillButtonStyle())
                    Button("Check again") { inputGranted = InputMonitoringPermission.isGranted }.buttonStyle(PillButtonStyle())
                }
            }
            Text("You can skip this and allow it later; cameras work without it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var remapping: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional: remapping and macros").font(.headline)
            Text("Remapping keys and running macros also needs Accessibility. This is entirely optional and off by default; you can enable it later in Settings > Remap.")
                .foregroundStyle(.secondary)
            if let remap {
                Button("Allow remapping permissions") { remap.requestPermissions() }.buttonStyle(PillButtonStyle())
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You are all set.").font(.headline)
            Text("Open this welcome again any time from Settings > General.").foregroundStyle(.secondary)
        }
    }
}
