import Foundation
import Observation
import MacHIDApplication
import MacHIDDomain
import MacHIDIOKit

/// State behind the menu bar panel and the main window. All device access goes through `DeviceControl`.
@MainActor
@Observable
public final class AppModel {
    public struct DeviceEntry: Identifiable, Equatable {
        public let id: String
        public var item: InventoryItem
        public var specs: [ControlSpec]
        public var values: [String: SettingValue] = [:]
        public var limits: [String: ValueLimits] = [:]
        public var lastError: String?

        public var definition: DeviceDefinition? { item.definition }
        public var name: String { item.device.name }
        public var usbId: USBID { item.device.usbId }
    }

    public private(set) var devices: [DeviceEntry] = []
    public var selectedDeviceID: String?
    public private(set) var profiles: [Profile] = []
    /// Device definition id -> id of the profile last applied to it.
    public private(set) var activeProfileIDs: [String: String] = [:]
    public private(set) var automation = AutomationConfig()
    /// Bundle id of the app the user is working in (MacHID itself is ignored).
    public private(set) var frontmostBundleID: String?
    public private(set) var inputMonitoringGranted = true
    public var banner: String?
    /// Set by the app scene so the delegate and the menu can bring the window forward.
    @ObservationIgnored public var openMainWindow: (() -> Void)?
    /// Called after devices were plugged in or removed (the plugins page re-checks its recommendations).
    @ObservationIgnored public var onDevicesChanged: (() async -> Void)?

    @ObservationIgnored private var inventory: DeviceInventory
    @ObservationIgnored private var control: DeviceControl
    @ObservationIgnored private let baseCatalog: DefinitionCatalog
    @ObservationIgnored private var pluginRoots: [String: URL] = [:]
    @ObservationIgnored private let enumerator: any DeviceEnumerator
    @ObservationIgnored private let connector: any DeviceConnector
    @ObservationIgnored private let repository: any ProfileRepository
    @ObservationIgnored private let automationRepository: any AutomationRepository
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let writeDelay: Duration
    @ObservationIgnored private let permissionCheck: @Sendable () -> Bool
    @ObservationIgnored private var pendingWrites: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private let deviceChanges: AsyncStream<Void>?

    private static let activeProfilesKey = "activeProfileIDs"

    public init(inventory: DeviceInventory, control: DeviceControl, repository: any ProfileRepository,
                enumerator: (any DeviceEnumerator)? = nil, connector: (any DeviceConnector)? = nil,
                automationRepository: any AutomationRepository = MemoryAutomationRepository(),
                defaults: UserDefaults = .standard, writeDelay: Duration = .milliseconds(150),
                deviceChanges: AsyncStream<Void>? = nil,
                permissionCheck: @escaping @Sendable () -> Bool = { InputMonitoringPermission.isGranted }) {
        self.deviceChanges = deviceChanges
        self.inventory = inventory
        self.control = control
        self.baseCatalog = inventory.catalog
        self.enumerator = enumerator ?? inventory.enumerator
        self.connector = connector ?? control.connector
        self.repository = repository
        self.automationRepository = automationRepository
        self.defaults = defaults
        self.writeDelay = writeDelay
        self.permissionCheck = permissionCheck
        self.activeProfileIDs = (defaults.dictionary(forKey: Self.activeProfilesKey) as? [String: String]) ?? [:]
    }

    // MARK: Lifecycle

    /// Design review only: shows sample devices without touching hardware.
    func setPreview(devices: [DeviceEntry], selected: String?, profileName: String?) {
        self.devices = devices
        self.selectedDeviceID = selected
        if let profileName, let selected, let definitionID = devices.first(where: { $0.id == selected })?.definition?.id {
            let profile = Profile(id: "preview", name: profileName, settings: [definitionID: [:]])
            self.profiles = [profile]
            self.activeProfileIDs = [definitionID: profile.id]
        }
    }

    /// Loads profiles and starts watching for devices being plugged in or removed. With a change stream
    /// (IOKit notifications) the poll is only a slow safety net; without one it is the main mechanism.
    public func start(pollInterval: Duration? = nil) {
        guard pollTask == nil else { return }
        let interval = pollInterval ?? (deviceChanges == nil ? .seconds(2) : .seconds(30))
        pollTask = Task { [weak self] in
            await self?.reloadProfiles()
            await self?.reloadAutomation()
            while !Task.isCancelled {
                await self?.refreshDevices()
                try? await Task.sleep(for: interval)
            }
        }
        if let deviceChanges {
            eventTask = Task { [weak self] in
                for await _ in deviceChanges {
                    try? await Task.sleep(for: .milliseconds(400))   // let the system finish setting the device up
                    await self?.refreshDevices()
                }
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        eventTask?.cancel()
        pollTask = nil
        eventTask = nil
    }

    public var selectedDevice: DeviceEntry? {
        devices.first { $0.id == selectedDeviceID } ?? devices.first
    }

    /// Moves the selection forward or backward through the connected devices, wrapping around.
    public func selectNextDevice(offset: Int = 1) {
        guard !devices.isEmpty else { return }
        let current = devices.firstIndex { $0.id == selectedDeviceID } ?? 0
        let next = ((current + offset) % devices.count + devices.count) % devices.count
        selectedDeviceID = devices[next].id
    }

    // MARK: Devices

    public func refreshDevices() async {
        inputMonitoringGranted = permissionCheck()
        let inventory = self.inventory
        let items = (try? await Task.detached { try inventory.items(includeUnsupported: false) }.value) ?? []

        let incoming = Dictionary(uniqueKeysWithValues: items.map { ($0.device.usbId.description, $0) })
        let previousIDs = Set(devices.map(\.id))
        let removed = devices.filter { incoming[$0.id] == nil }
        devices.removeAll { incoming[$0.id] == nil }
        for entry in removed { await control.discard(entry.item.device) }
        var added: [String] = []
        for item in items where !previousIDs.contains(item.device.usbId.description) {
            let id = item.device.usbId.description
            devices.append(DeviceEntry(id: id, item: item, specs: item.definition.map(ControlSpec.specs(for:)) ?? []))
            added.append(id)
        }
        devices.sort { ($0.name, $0.id) < ($1.name, $1.id) }
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first?.id
        }
        for id in added {
            await loadValues(for: id)
            await applyOnConnect(deviceID: id)
        }
        if !added.isEmpty || !removed.isEmpty { await onDevicesChanged?() }
    }

    /// Reads every readable capability (and device-reported limits) once, when a device appears.
    public func loadValues(for deviceID: String) async {
        guard let entry = devices.first(where: { $0.id == deviceID }) else { return }
        for spec in entry.specs where spec.readable {
            do {
                if case .slider(_, _, _, true) = spec.kind,
                   let limits = try await control.limits(entry.usbId, capability: spec.id) {
                    update(deviceID) { $0.limits[spec.id] = limits }
                }
                let value = try await control.read(entry.usbId, capability: spec.id)
                update(deviceID) { $0.values[spec.id] = value }
            } catch {
                update(deviceID) { $0.lastError = "\(spec.id): \(error)" }
            }
        }
    }

    // MARK: Changing settings

    /// Updates the UI at once and sends the value to the device after a short pause, so dragging a
    /// slider produces one write instead of dozens.
    public func set(_ value: SettingValue, capability: String, on deviceID: String) {
        update(deviceID) { $0.values[capability] = value }
        let key = deviceID + "/" + capability
        pendingWrites[key]?.cancel()
        pendingWrites[key] = Task { [weak self, writeDelay] in
            try? await Task.sleep(for: writeDelay)
            guard !Task.isCancelled else { return }
            await self?.write(value, capability: capability, deviceID: deviceID)
        }
    }

    /// Waits until every scheduled write has been sent.
    public func flushWrites() async {
        for task in pendingWrites.values { await task.value }
        pendingWrites.removeAll()
    }

    private func write(_ value: SettingValue, capability: String, deviceID: String) async {
        guard let entry = devices.first(where: { $0.id == deviceID }) else { return }
        do {
            try await control.write(entry.usbId, capability: capability, value: value)
            update(deviceID) { $0.lastError = nil }
        } catch {
            update(deviceID) { $0.lastError = "\(error)" }
            banner = "\(entry.name): \(error)"
        }
    }

    private func update(_ deviceID: String, _ change: (inout DeviceEntry) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        change(&devices[index])
    }

    // MARK: Profiles

    public func reloadProfiles() async {
        profiles = (try? await repository.load()) ?? []
    }

    public func profiles(for deviceID: String) -> [Profile] {
        guard let definitionID = devices.first(where: { $0.id == deviceID })?.definition?.id else { return [] }
        return profiles.filter { $0.settings[definitionID] != nil }
    }

    public func activeProfile(for deviceID: String) -> Profile? {
        guard let definitionID = devices.first(where: { $0.id == deviceID })?.definition?.id,
              let profileID = activeProfileIDs[definitionID] else { return nil }
        return profiles.first { $0.id == profileID }
    }

    /// Saves the values currently set on a device as a profile for that device model.
    @discardableResult
    public func saveProfile(named name: String, from deviceID: String) async -> Profile? {
        guard let entry = devices.first(where: { $0.id == deviceID }), let definition = entry.definition else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let savable = entry.specs.filter { $0.isWritable && $0.kind != .hostControl }.map(\.id)
        let settings = entry.values.filter { savable.contains($0.key) }
        let profile = Profile(id: UUID().uuidString, name: trimmed, settings: [definition.id: settings])
        do {
            try await repository.save(profile)
            await reloadProfiles()
            setActive(profile.id, definitionID: definition.id)
            return profile
        } catch {
            banner = "Could not save the profile: \(error)"
            return nil
        }
    }

    public func deleteProfile(_ id: String) async {
        do {
            try await repository.delete(id: id)
            await reloadProfiles()
            for (definition, active) in activeProfileIDs where active == id { setActive(nil, definitionID: definition) }
            await updateAutomation { $0 = $0.removingRules(forProfile: id) }
        } catch {
            banner = "Could not delete the profile: \(error)"
        }
    }

    /// Writes every setting of the profile that applies to this device, one after another.
    public func applyProfile(_ profileID: String, to deviceID: String) async {
        guard let entry = devices.first(where: { $0.id == deviceID }), let definition = entry.definition,
              let profile = profiles.first(where: { $0.id == profileID }),
              let settings = profile.settings[definition.id] else { return }
        for spec in entry.specs {
            guard let value = settings[spec.id] else { continue }
            update(deviceID) { $0.values[spec.id] = value }
            await write(value, capability: spec.id, deviceID: deviceID)
        }
        setActive(profile.id, definitionID: definition.id)
    }

    // MARK: Artwork

    @ObservationIgnored private var artworkCache: [String: LoadedArtwork?] = [:]

    func artwork(for entry: DeviceEntry) -> LoadedArtwork? {
        guard let definition = entry.definition else { return nil }
        if let cached = artworkCache[definition.id] { return cached }
        let loaded = inventory.catalog.artworkRoots[definition.id].flatMap { ArtworkLoader.load(for: definition, root: $0) }
        artworkCache[definition.id] = .some(loaded)
        return loaded
    }

    // MARK: Plugins

    /// Adds the definitions of installed plugins to the built-in ones and starts using them. Built-in definitions
    /// win when a plugin claims the same USB ID.
    public func setPluginDefinitions(_ definitions: [DeviceDefinition], artworkRoots: [String: URL] = [:]) async {
        pluginRoots = artworkRoots
        artworkCache.removeAll()
        let catalog = baseCatalog.adding(definitions, artworkRoots: pluginRoots)
        inventory = DeviceInventory(enumerator: enumerator, catalog: catalog)
        control = DeviceControl(inventory: inventory, connector: connector)
        // A device whose definition changed gets its controls rebuilt; the rest are left alone.
        let changed = devices.filter { entry in
            catalog.definition(for: entry.usbId)?.id != entry.definition?.id || catalog.definition(for: entry.usbId) != entry.definition
        }
        devices.removeAll { entry in changed.contains { $0.id == entry.id } }
        await refreshDevices()
    }

    /// Attached devices that no definition covers: what plugin recommendations are about.
    public func unsupportedDeviceIDs() async -> [USBID] {
        let inventory = self.inventory
        let items = (try? await Task.detached { try inventory.items(includeUnsupported: true) }.value) ?? []
        return items.filter { !$0.isSupported }.map(\.device.usbId)
    }

    // MARK: Automation

    public var knownDefinitions: [DeviceDefinition] { inventory.catalog.definitions }

    public func reloadAutomation() async {
        automation = (try? await automationRepository.load()) ?? AutomationConfig()
    }

    private func updateAutomation(_ change: (inout AutomationConfig) -> Void) async {
        var copy = automation
        change(&copy)
        automation = copy
        do { try await automationRepository.save(copy) } catch { banner = "Could not save automation settings: \(error)" }
    }

    public func setAutomationPaused(_ paused: Bool) async { await updateAutomation { $0.paused = paused } }
    public func setApplyOnConnect(_ enabled: Bool) async { await updateAutomation { $0.applyOnConnect = enabled } }

    public func setDefaultProfile(_ profileID: String?, forDefinition definitionID: String) async {
        await updateAutomation { $0.defaultProfiles[definitionID] = profileID }
    }

    public func addRule(bundleID: String, appName: String, definitionID: String, profileID: String) async {
        let rule = AppRule(id: UUID().uuidString, bundleID: bundleID, appName: appName,
                           deviceDefinitionID: definitionID, profileID: profileID)
        await updateAutomation { $0 = $0.upserting(rule) }
        await applyAutomationForFrontmostApp()
    }

    public func removeRule(_ id: String) async {
        await updateAutomation { $0.rules.removeAll { $0.id == id } }
    }

    /// Called when the user switches app. Applies what the rules or defaults say for each connected device.
    public func frontmostAppChanged(_ bundleID: String?) async {
        frontmostBundleID = bundleID
        await applyAutomationForFrontmostApp()
    }

    private func applyAutomationForFrontmostApp() async {
        for entry in devices {
            guard let definitionID = entry.definition?.id,
                  let desired = automation.profileID(frontmostBundleID: frontmostBundleID, deviceDefinitionID: definitionID),
                  desired != activeProfileIDs[definitionID],
                  profiles.contains(where: { $0.id == desired && $0.settings[definitionID] != nil }) else { continue }
            await applyProfile(desired, to: entry.id)
        }
    }

    /// A device that was just plugged in gets its profile back: what the rules say for the current app,
    /// otherwise the profile it had last time.
    private func applyOnConnect(deviceID: String) async {
        guard automation.applyOnConnect, !automation.paused,
              let definitionID = devices.first(where: { $0.id == deviceID })?.definition?.id else { return }
        let desired = automation.profileID(frontmostBundleID: frontmostBundleID, deviceDefinitionID: definitionID)
            ?? activeProfileIDs[definitionID]
        guard let desired, profiles.contains(where: { $0.id == desired && $0.settings[definitionID] != nil }) else { return }
        await applyProfile(desired, to: deviceID)
    }

    private func setActive(_ profileID: String?, definitionID: String) {
        activeProfileIDs[definitionID] = profileID
        defaults.set(activeProfileIDs, forKey: Self.activeProfilesKey)
    }
}


/// Used when no repository is given (tests, previews): keeps the settings in memory only.
public actor MemoryAutomationRepository: AutomationRepository {
    private var config = AutomationConfig()
    public init() {}
    public func load() -> AutomationConfig { config }
    public func save(_ config: AutomationConfig) { self.config = config }
}
