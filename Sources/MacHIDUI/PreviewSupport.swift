import SwiftUI
import MacHIDApplication
import MacHIDDomain

/// Fake devices for design review and snapshots: no hardware, no permissions, nothing is written.
public enum PreviewSupport {
    private struct NoEnumerator: DeviceEnumerator { func enumerate() throws -> [DiscoveredDevice] { [] } }
    private struct NoConnector: DeviceConnector {
        func connect(to device: DiscoveredDevice, definition: DeviceDefinition) async throws -> (driver: any DeviceDriver, transport: any Transport) {
            throw DriverError.deviceFailure("preview only")
        }
    }
    private actor EmptyRepository: ProfileRepository {
        func load() -> [Profile] { [] }
        func save(_ profile: Profile) {}
        func delete(id: String) {}
    }

    /// A model filled with sample devices from the bundled definitions.
    @MainActor
    public static func model(selecting category: DeviceCategory = .keyboard, profileName: String? = "Work") -> AppModel {
        let (catalog, _) = (try? AppModel.loadDefinitions()) ?? (DefinitionCatalog(definitions: []), [])
        let inventory = DeviceInventory(enumerator: NoEnumerator(), catalog: catalog)
        let model = AppModel(inventory: inventory, control: DeviceControl(inventory: inventory, connector: NoConnector()),
                             repository: EmptyRepository(), defaults: UserDefaults(suiteName: "machid.preview")!,
                             permissionCheck: { true })
        model.loadPreviewDevices(catalog.definitions, selecting: category, profileName: profileName)
        return model
    }
}

extension PreviewSupport {
    private actor Idle: EventPoster, ShellRunner, Launcher, MacroLog, RemapRepository {
        func post(_ event: OutputEvent) async {}
        func type(_ text: String) async {}
        func run(_ command: String, timeout: Duration) async -> ShellResult { ShellResult(exitCode: 0) }
        func open(_ target: String) async -> Bool { true }
        func runShortcut(named name: String) async -> Bool { true }
        func record(_ entry: MacroLogEntry) async {}
        func load() async throws -> RemapConfig { RemapConfig() }
        func save(_ config: RemapConfig) async throws {}
    }

    private final class IdleTap: EventTapping, @unchecked Sendable {
        func start() -> Bool { false }
        func stop() {}
        var isRunning: Bool { false }
    }

    /// A remap controller with sample rules and macros; it cannot touch the keyboard.
    @MainActor
    public static func remapController() -> RemapController {
        let idle = Idle()
        let runner = MacroRunner(poster: idle, shell: idle, launcher: idle, log: idle, fingerprint: { _ in "x" })
        let controller = RemapController(repository: idle, runner: runner, fingerprint: { _ in "x" },
                                         permissionCheck: { (true, false) }, makeTap: { _, _ in IdleTap() })
        var config = RemapConfig()
        config.enabled = true
        config.macros = [
            Macro(id: "m1", name: "Sign off", steps: [.text("Best regards"), .key(code: 36, modifiers: [])]),
            Macro(id: "m2", name: "Backup notes", steps: [.shell("rsync -a ~/Notes ~/Backup/"), .open("com.apple.finder")], approvedFingerprint: "x"),
            Macro(id: "m3", name: "Imported helper", steps: [.shortcut("Morning")], imported: true),
        ]
        config.rules = [
            RemapRule(id: "r1", trigger: InputTrigger(kind: .mouseButton, code: 3), action: .macro("m1")),
            RemapRule(id: "r2", trigger: InputTrigger(kind: .keyboard, code: 96, modifiers: [.function]), action: .key(code: 122, modifiers: [.command])),
            RemapRule(id: "r3", trigger: InputTrigger(kind: .keyboard, code: 57), action: .disable, enabled: false),
        ]
        controller.setPreview(config: config, runs: [
            MacroLogEntry(macroID: "m1", macroName: "Sign off", date: Date(), outcome: .completed, stepKinds: ["text", "key"], shellExitCodes: []),
            MacroLogEntry(macroID: "m2", macroName: "Backup notes", date: Date(), outcome: .refused(.notApproved), stepKinds: ["shell", "open"], shellExitCodes: []),
        ])
        return controller
    }
}

extension AppModel {
    @MainActor
    func loadPreviewDevices(_ definitions: [DeviceDefinition], selecting category: DeviceCategory, profileName: String?) {
        var entries: [DeviceEntry] = []
        for definition in definitions.sorted(by: { $0.id < $1.id }) {
            guard let usbId = definition.usbIds.first else { continue }
            let device = DiscoveredDevice(usbId: usbId, name: definition.name, manufacturer: nil)
            var entry = DeviceEntry(id: usbId.description, item: InventoryItem(device: device, definition: definition),
                                    specs: ControlSpec.specs(for: definition))
            for spec in entry.specs {
                switch spec.kind {
                case .slider(let min, let max, _, _): entry.values[spec.id] = .int(min + (max - min) * 6 / 10)
                case .toggle: entry.values[spec.id] = .int(1)
                case .choice(let values): entry.values[spec.id] = .int(values.last ?? 0)
                case .lighting: entry.values[spec.id] = .color(MacHIDDomain.RGBColor(r: 120, g: 70, b: 255))
                case .hostControl: entry.values[spec.id] = .int(0)
                case .readout: entry.values[spec.id] = .text("v1.12")
                }
            }
            entries.append(entry)
        }
        setPreview(devices: entries, selected: entries.first { $0.definition?.category == category }?.id, profileName: profileName)
    }
}

extension PreviewSupport {
    private struct NoSource: RegistrySource { func fetchLatest() async throws -> RegistrySnapshot { throw URLError(.notConnectedToInternet) } }
    private struct NoVerifier: RegistryVerifier { func isValid(signature: Data, for data: Data) -> Bool { false } }
    private actor NoCache: RegistryCache {
        func load() -> RegistrySnapshot? { nil }
        func save(_ snapshot: RegistrySnapshot) {}
    }
    private actor NoStore: InstalledPluginStore {
        func load() -> [InstalledPlugin] { [] }
        func save(_ plugins: [InstalledPlugin]) {}
    }
    private struct NoFetcher: PluginFetcher { func fetchArchive(repo: String, ref: String) async throws -> URL { throw URLError(.badURL) } }
    private struct NoExtractor: ArchiveExtractor { func extract(_ archive: URL, into directory: URL) throws {} }

    /// A plugins model with sample entries; it cannot reach the network or change anything.
    @MainActor
    public static func pluginsModel() -> PluginsModel {
        let model = PluginsModel(registryService: RegistryService(source: NoSource(), verifier: NoVerifier(), cache: NoCache()),
                                 installer: PluginInstaller(directory: FileManager.default.temporaryDirectory, fetcher: NoFetcher(), extractor: NoExtractor(), sha256: { _ in "" }),
                                 store: NoStore(), pluginsRoot: FileManager.default.temporaryDirectory, discoveryAvailable: true,
                                 defaults: UserDefaults(suiteName: "machid.preview")!, catalogChanged: { _ in }, unsupportedDevices: { [] })
        let permissions = PluginPermissions(transport: .hid, writes: .volatile)
        let entries = [
            RegistryEntry(id: "razer-blackwidow-v3", repo: "https://github.com/example/razer-blackwidow-v3", ref: String(repeating: "a", count: 40), manifestSha256: String(repeating: "b", count: 64),
                          license: "GPL-3.0-or-later", category: .keyboard, devices: [USBID(vendor: 0x1532, product: 0x0243)], coreApi: APIRange(min: 1, max: 1), review: .reviewed),
            RegistryEntry(id: "logitech-g502-hero", repo: "https://github.com/example/logitech-g502", ref: String(repeating: "c", count: 40), manifestSha256: String(repeating: "d", count: 64),
                          license: "MIT", category: .mouse, devices: [USBID(vendor: 0x046d, product: 0xc08b)], coreApi: APIRange(min: 1, max: 1), review: .community),
        ]
        model.setPreview(registry: Registry(plugins: entries), recommendations: [entries[0]],
                         installed: [InstalledPlugin(id: "acme-webcam", name: "Acme Webcam", version: "1.2.0", ref: String(repeating: "e", count: 40), review: .reviewed, license: "MIT",
                                                     devices: [USBID(vendor: 0x1234, product: 1)], permissions: permissions, definitionFiles: [], installedAt: Date())])
        return model
    }
}
