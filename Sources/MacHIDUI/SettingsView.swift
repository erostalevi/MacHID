import SwiftUI
import AppKit
import MacHIDDomain

/// Settings: start at login, automatic profiles, per-device defaults and per-app rules.
public struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var remap: RemapController
    @Bindable var plugins: PluginsModel
    @Bindable var updater: UpdaterModel

    public init(model: AppModel, remap: RemapController, plugins: PluginsModel, updater: UpdaterModel) {
        self.model = model
        self.remap = remap
        self.plugins = plugins
        self.updater = updater
    }

    public var body: some View {
        TabView {
            GeneralSettings(model: model, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
            RemapView(remap: remap)
                .tabItem { Label("Remap", systemImage: "keyboard") }
            MacrosView(remap: remap)
                .tabItem { Label("Macros", systemImage: "play.rectangle") }
            PluginsView(plugins: plugins)
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(.background)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @Bindable var updater: UpdaterModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var addingRule = false
    @AppStorage(OnboardingStore.key) private var onboardingDone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                general
                updates
                defaults
                rules
            }
            .padding(24)
        }
    }

    private func card<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            title.font(.headline)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 24)
    }

    // MARK: Sections

    private var general: some View {
        card(Text("General")) {
            Toggle("Start MacHID when I log in", isOn: Binding(get: { launchAtLogin }, set: { value in
                do { try LoginItem.set(value); launchAtLogin = value; loginError = nil }
                catch { launchAtLogin = LoginItem.isEnabled; loginError = "\(error)" }
            }))
            if let loginError { Text(verbatim: loginError).font(.caption).foregroundStyle(.orange) }
            Toggle("Apply a device's profile when it is plugged in", isOn: Binding(
                get: { model.automation.applyOnConnect }, set: { value in Task { await model.setApplyOnConnect(value) } }))
            Toggle("Pause automatic profiles", isOn: Binding(
                get: { model.automation.paused }, set: { value in Task { await model.setAutomationPaused(value) } }))
            Button("Show welcome again") { onboardingDone = false }.buttonStyle(PillButtonStyle())
        }
    }

    private var updates: some View {
        card(Text("Updates")) {
            if updater.isAvailable {
                HStack {
                    Button { updater.checkForUpdates() } label: { Label("Check for updates…", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(PillButtonStyle()).disabled(!updater.canCheck)
                    Spacer()
                    if let last = updater.lastCheck {
                        (Text("Checked ") + Text(last, format: .relative(presentation: .numeric))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
                Toggle("Download and install updates in the background", isOn: $updater.automaticDownloads)
                Text("Updates come from this project's GitHub releases and are installed only if they carry the project's signature.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This build cannot update itself because it was not built with the project's update key. Download releases from GitHub instead.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var defaults: some View {
        card(Text("Default profiles")) {
            Text("Used when no app rule matches the app you are working in.").font(.callout).foregroundStyle(.secondary)
            let definitions = model.knownDefinitions.filter { definition in
                model.profiles.contains { $0.settings[definition.id] != nil }
            }
            if definitions.isEmpty {
                Text("Save a profile from the main window first.").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(definitions) { definition in
                HStack {
                    Label(definition.name, systemImage: Titles.symbol(for: definition.category))
                    Spacer()
                    profileMenu(definitionID: definition.id, selection: model.automation.defaultProfiles[definition.id],
                                none: Text("None")) { id in Task { await model.setDefaultProfile(id, forDefinition: definition.id) } }
                }
            }
        }
    }

    private var rules: some View {
        card(Text("App rules")) {
            Text("When one of these apps is in front, the device switches to the chosen profile.")
                .font(.callout).foregroundStyle(.secondary)
            if model.automation.rules.isEmpty {
                Text("No rules yet.").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(model.automation.rules) { rule in
                HStack(spacing: 10) {
                    appIcon(rule.bundleID).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: rule.appName).font(.callout.weight(.medium))
                        Text(verbatim: "\(definitionName(rule.deviceDefinitionID)) → \(profileName(rule.profileID))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await model.removeRule(rule.id) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove rule")
                }
            }
            Button { addingRule = true } label: { Label("Add rule…", systemImage: "plus") }
                .buttonStyle(PillButtonStyle())
                .disabled(!model.profiles.contains { _ in true })
                .popover(isPresented: $addingRule, arrowEdge: .bottom) { AddRuleView(model: model) { addingRule = false } }
        }
    }

    // MARK: Helpers

    private func profileMenu(definitionID: String, selection: String?, none: Text, choose: @escaping (String?) -> Void) -> some View {
        Menu {
            Button { choose(nil) } label: { none }
            Divider()
            ForEach(model.profiles.filter { $0.settings[definitionID] != nil }) { profile in
                Button { choose(profile.id) } label: {
                    if profile.id == selection { Label(profile.name, systemImage: "checkmark") } else { Text(verbatim: profile.name) }
                }
            }
        } label: {
            if let selection, let profile = model.profiles.first(where: { $0.id == selection }) { Text(verbatim: profile.name) } else { none }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func definitionName(_ id: String) -> String { model.knownDefinitions.first { $0.id == id }?.name ?? id }
    private func profileName(_ id: String) -> String { model.profiles.first { $0.id == id }?.name ?? "—" }

    @ViewBuilder private func appIcon(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
}

private struct AddRuleView: View {
    @Bindable var model: AppModel
    let done: () -> Void
    @State private var app: RunningApp?
    @State private var definitionID: String?
    @State private var profileID: String?

    struct RunningApp: Hashable { let bundleID: String; let name: String }

    private var runningApps: [RunningApp] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != own }
            .map { RunningApp(bundleID: $0.bundleIdentifier!, name: $0.localizedName ?? $0.bundleIdentifier!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var definitions: [DeviceDefinition] {
        model.knownDefinitions.filter { definition in model.profiles.contains { $0.settings[definition.id] != nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New rule").font(.headline)
            Picker("App", selection: $app) {
                Text("Choose…").tag(RunningApp?.none)
                ForEach(runningApps, id: \.self) { Text(verbatim: $0.name).tag(Optional($0)) }
            }
            Picker("Device", selection: $definitionID) {
                Text("Choose…").tag(String?.none)
                ForEach(definitions) { Text(verbatim: $0.name).tag(Optional($0.id)) }
            }
            Picker("Profile", selection: $profileID) {
                Text("Choose…").tag(String?.none)
                ForEach(model.profiles.filter { definitionID != nil && $0.settings[definitionID!] != nil }) {
                    Text(verbatim: $0.name).tag(Optional($0.id))
                }
            }
            .disabled(definitionID == nil)
            HStack {
                Spacer()
                Button("Add") {
                    guard let app, let definitionID, let profileID else { return }
                    Task { await model.addRule(bundleID: app.bundleID, appName: app.name, definitionID: definitionID, profileID: profileID) }
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(app == nil || definitionID == nil || profileID == nil)
            }
        }
        .padding(18).frame(width: 320)
        .onChange(of: definitionID) { _, _ in profileID = nil }
    }
}
