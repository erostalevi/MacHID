import SwiftUI
import AppKit
import MacHIDApplication
import MacHIDDomain

/// Plugins: devices MacHID can learn about, what is installed, updates, and the whole registry to browse.
public struct PluginsView: View {
    @Bindable var plugins: PluginsModel
    @State private var query = ""

    public init(plugins: PluginsModel) { self.plugins = plugins }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !plugins.discoveryAvailable { unavailable }
                if !plugins.recommendations.isEmpty { recommended }
                installedCard
                if plugins.discoveryAvailable { browse }
                SettingsCard(Text("Share a plugin")) {
                    Text("A plugin is a small public repository that describes a device for MacHID's built-in drivers. Anyone can submit one with a pull request to the registry. It never runs code.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button { NSWorkspace.shared.open(URL(string: "https://github.com/erostalevi/MacHID/blob/master/docs/PLUGINS.md")!) } label: {
                        Label("How to write and submit one", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
            .padding(24)
        }
    }

    // MARK: Header

    private var header: some View {
        SettingsCard(Text("Plugins")) {
            HStack(spacing: 12) {
                statusLabel.font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await plugins.refresh(force: true) } } label: { Label("Check now", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!plugins.discoveryAvailable || plugins.status == .refreshing)
            }
            Toggle("Update reviewed plugins automatically", isOn: $plugins.autoUpdate)
            Text("Only plugins reviewed by the maintainers, and only when their permissions and license did not change. Everything else asks first.")
                .font(.caption).foregroundStyle(.secondary)
            if let banner = plugins.banner {
                HStack {
                    Text(verbatim: banner).font(.caption).foregroundStyle(.orange)
                    Button { plugins.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch plugins.status {
        case .refreshing: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }.font(.callout)
        case .failed(let message): Label { Text(verbatim: message).lineLimit(2) } icon: { Image(systemName: "exclamationmark.triangle") }.font(.caption).foregroundStyle(.orange)
        case .idle:
            if let last = plugins.lastChecked { Text("Checked ") + Text(last, format: .relative(presentation: .numeric)) }
            else { Text("Not checked yet") }
        }
    }

    private var unavailable: some View {
        SettingsCard(Text("Plugin discovery is off")) {
            Text("This build of MacHID has no registry signing key, so it cannot tell a genuine plugin list from a forged one. Installed plugins keep working.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Lists

    private var recommended: some View {
        SettingsCard(Text("For your devices")) {
            Text("These plugins describe devices you have plugged in that MacHID does not know yet.").font(.callout).foregroundStyle(.secondary)
            ForEach(plugins.recommendations, id: \.id) { entry in EntryRow(plugins: plugins, entry: entry) }
        }
    }

    private var installedCard: some View {
        SettingsCard(Text("Installed")) {
            if plugins.installed.isEmpty { Text("No plugins installed.").font(.callout).foregroundStyle(.tertiary) }
            ForEach(plugins.installed) { plugin in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: plugin.name).font(.callout.weight(.medium))
                            ReviewBadge(review: plugin.review)
                            if plugins.orphaned.contains(where: { $0.id == plugin.id }) {
                                Label("Removed from registry", systemImage: "questionmark.circle").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(verbatim: "v\(plugin.version) · \(plugin.devices.map(\.description).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let update = plugins.update(for: plugin.id) { UpdateButton(plugins: plugins, update: update) }
                    Button { Task { await plugins.remove(plugin.id) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
                }
            }
        }
    }

    private var browse: some View {
        SettingsCard(Text("Browse")) {
            TextField("Search by name, license or device ID", text: $query).textFieldStyle(.roundedBorder)
            let entries = filtered
            if entries.isEmpty { Text(plugins.registry == nil ? "Nothing to show yet." : "No plugins match.").font(.callout).foregroundStyle(.tertiary) }
            ForEach(entries, id: \.id) { entry in EntryRow(plugins: plugins, entry: entry) }
        }
    }

    private var filtered: [RegistryEntry] {
        let all = plugins.registry?.plugins ?? []
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.id.contains(needle) || $0.license.lowercased().contains(needle) || $0.devices.contains { $0.description.contains(needle) } }
    }
}

private struct ReviewBadge: View {
    let review: ReviewLevel
    var body: some View {
        switch review {
        case .reviewed: Label("Reviewed", systemImage: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green)
        case .community: Label("Community", systemImage: "person.2").font(.caption2).foregroundStyle(.orange)
        }
    }
}

private struct EntryRow: View {
    @Bindable var plugins: PluginsModel
    let entry: RegistryEntry
    @State private var showingDetails = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.id).font(.callout.weight(.medium))
                    ReviewBadge(review: entry.review)
                }
                Text(verbatim: "\(entry.license) · \(entry.devices.map(\.description).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if plugins.isInstalled(entry.id) {
                Label("Installed", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            } else if plugins.busy.contains(entry.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Install…") { showingDetails = true }.buttonStyle(PillButtonStyle())
                    .popover(isPresented: $showingDetails, arrowEdge: .bottom) { InstallDetails(plugins: plugins, entry: entry) { showingDetails = false } }
            }
        }
    }
}

private struct InstallDetails: View {
    @Bindable var plugins: PluginsModel
    let entry: RegistryEntry
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: entry.id).font(.headline)
            LabeledContent("License") { Text(verbatim: entry.license) }
            LabeledContent("Devices") { Text(verbatim: entry.devices.map(\.description).joined(separator: ", ")) }
            LabeledContent("Source") { Text(verbatim: entry.repo.replacingOccurrences(of: "https://", with: "")).textSelection(.enabled) }
            Divider()
            Text("It adds support for these devices by describing them to MacHID's built-in drivers. It cannot run code or read what you type.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if entry.review == .community {
                Label("Community plugin: not reviewed by the maintainers. A wrong description could make your device behave unexpectedly. Install only if you trust the author.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Reviewed by the maintainers.", systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(.green)
            }
            HStack {
                Spacer()
                Button("Install") {
                    Task { await plugins.install(entry) }
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 380)
    }
}

private struct UpdateButton: View {
    @Bindable var plugins: PluginsModel
    let update: PluginUpdate
    @State private var open = false

    var body: some View {
        if plugins.busy.contains(update.entry.id) {
            ProgressView().controlSize(.small)
        } else {
            Button { open = true } label: { Label("Update", systemImage: "arrow.down.circle") }
                .buttonStyle(PillButtonStyle(selected: true))
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Update available").font(.headline)
                        Text(verbatim: "\(update.installed.name) \(update.installed.version) → a newer version").font(.callout)
                        if update.entry.review == .community {
                            Label("This is a community plugin and is never updated automatically.", systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                        } else {
                            Text("This update needs your approval: its permissions or license may have changed.").font(.callout).foregroundStyle(.secondary)
                        }
                        HStack {
                            Spacer()
                            Button("Update") { Task { await plugins.update(update, approved: true) }; open = false }.keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(18).frame(width: 340)
                }
        }
    }
}
