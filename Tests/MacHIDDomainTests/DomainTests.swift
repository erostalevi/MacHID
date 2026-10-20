import Foundation
import Testing
@testable import MacHIDDomain

@Suite struct USBIDTests {
    @Test func parsesAndFormats() {
        let id = USBID(string: "046d:c092")
        #expect(id == USBID(vendor: 0x046d, product: 0xc092))
        #expect(id?.description == "046d:c092")
        #expect(USBID(vendor: 0x1532, product: 0x0257).description == "1532:0257")
    }

    @Test(arguments: ["", "046d", "046d:c09", "046d:c0920", "zzzz:c092", "046d-c092", "046d:c092:1"])
    func rejectsMalformed(text: String) {
        #expect(USBID(string: text) == nil)
    }

    @Test func decodingRejectsBadID() {
        let json = Data(#"["nope"]"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([USBID].self, from: json) }
    }
}

@Suite struct DefinitionTests {
    private func definition(capabilities: [CapabilityDescriptor], id: String = "dev", usb: [USBID]? = nil) -> DeviceDefinition {
        DeviceDefinition(id: id, name: "Dev", category: .mouse,
                         usbIds: usb ?? [USBID(vendor: 1, product: 2)], driver: "x", capabilities: capabilities)
    }

    @Test func validDefinitionPasses() throws {
        let dpi = CapabilityDescriptor(id: "dpi", type: .dpi, access: .writeVolatile,
                                       parameters: .init(min: 200, max: 8000, step: 50))
        try definition(capabilities: [dpi]).validate()
    }

    @Test func rejectsBadID() {
        #expect(throws: DefinitionError.invalidID("Bad_ID")) { try definition(capabilities: [], id: "Bad_ID").validate() }
    }

    @Test func rejectsNoUSBIDs() {
        #expect(throws: DefinitionError.noUSBIDs) { try definition(capabilities: [], usb: []).validate() }
    }

    @Test func rejectsDuplicateCapabilityAndBadRange() {
        let a = CapabilityDescriptor(id: "a", type: .info, access: .read)
        #expect(throws: DefinitionError.duplicateCapability("a")) { try definition(capabilities: [a, a]).validate() }
        let bad = CapabilityDescriptor(id: "dpi", type: .dpi, access: .writeVolatile, parameters: .init(min: 10, max: 5))
        #expect(throws: DefinitionError.invalidRange(capability: "dpi")) { try definition(capabilities: [bad]).validate() }
        let zeroStep = CapabilityDescriptor(id: "dpi", type: .dpi, access: .writeVolatile, parameters: .init(step: 0))
        #expect(throws: DefinitionError.invalidRange(capability: "dpi")) { try definition(capabilities: [zeroStep]).validate() }
    }

    @Test func decodesSnakeCaseJSON() throws {
        let json = Data(#"""
        {"id":"m","name":"M","category":"mouse","usb_ids":["046d:c092"],"driver":"d",
         "capabilities":[{"id":"dpi","type":"dpi","access":"write_volatile","parameters":{"min":200,"max":8000,"step":50}}]}
        """#.utf8)
        let decoded = try JSONDecoder().decode(DeviceDefinition.self, from: json)
        #expect(decoded.usbIds == [USBID(vendor: 0x046d, product: 0xc092)])
        #expect(decoded.capabilities.first?.type == .dpi)
        #expect(decoded.capabilities.first?.access == .writeVolatile)
    }
}

@Suite struct ProfileTests {
    @Test func roundTripsAllValueKinds() throws {
        let profile = Profile(id: "p", name: "Work", settings: [
            "dev": ["dpi": .int(1600), "lights": .bool(true),
                    "color": .color(RGBColor(r: 1, g: 2, b: 3)), "mode": .text("static")],
        ])
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(Profile.self, from: data) == profile)
        #expect(profile.schemaVersion == Profile.currentSchemaVersion)
    }
}

@Suite struct RegistryTests {
    private let sha = String(repeating: "a", count: 40)
    private let hash = String(repeating: "b", count: 64)

    private func entry(id: String = "good", repo: String = "https://github.com/acme/plugin", ref: String? = nil,
                       license: String = "MIT", devices: [USBID]? = nil) -> RegistryEntry {
        RegistryEntry(id: id, repo: repo, ref: ref ?? sha, manifestSha256: hash, license: license,
                      category: .mouse, devices: devices ?? [USBID(vendor: 1, product: 2)],
                      coreApi: APIRange(min: 1, max: 1), review: .community)
    }

    private func issues(_ entries: [RegistryEntry]) -> [RegistryIssue] {
        RegistryValidator().validate(Registry(schemaVersion: 1, plugins: entries))
    }

    @Test func emptyAndValidRegistriesPass() {
        #expect(issues([]).isEmpty)
        #expect(issues([entry()]).isEmpty)
    }

    @Test func rejectsMutableRefs() {
        #expect(!issues([entry(ref: "main")]).isEmpty)
        #expect(!issues([entry(ref: String(repeating: "A", count: 40))]).isEmpty)
        #expect(!issues([entry(ref: String(repeating: "a", count: 39))]).isEmpty)
    }

    @Test(arguments: [
        "http://github.com/acme/plugin",
        "https://evil.example/acme/plugin",
        "https://github.com.evil.example/acme/plugin",
        "https://user@github.com/acme/plugin",
        "https://github.com/acme",
        "https://github.com/acme/plugin?x=1",
        "https://github.com/acme/plugin/tree/main",
    ])
    func rejectsUnsafeRepos(repo: String) {
        #expect(!issues([entry(repo: repo)]).isEmpty)
    }

    @Test func rejectsBadLicenseDuplicatesAndNoDevices() {
        #expect(!issues([entry(license: "Proprietary")]).isEmpty)
        #expect(!issues([entry(), entry()]).isEmpty)
        #expect(!issues([entry(devices: [])]).isEmpty)
    }

    @Test func rejectsUnknownSchemaVersion() {
        #expect(!RegistryValidator().validate(Registry(schemaVersion: 2, plugins: [])).isEmpty)
    }

    @Test func apiRangeContains() {
        #expect(APIRange(min: 1, max: 2).contains(2))
        #expect(!APIRange(min: 1, max: 2).contains(3))
    }
}

@Suite struct BundledFilesTests {
    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func bundledDefinitionsAreValid() throws {
        let dir = root().appendingPathComponent("Definitions")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(!files.isEmpty)
        for file in files {
            let definition = try JSONDecoder().decode(DeviceDefinition.self, from: Data(contentsOf: file))
            try definition.validate()
        }
    }

    @Test func shippedRegistryIsValid() throws {
        let data = try Data(contentsOf: root().appendingPathComponent("plugins.json"))
        let registry = try Registry.decode(data)
        #expect(RegistryValidator().validate(registry).isEmpty)
    }
}

@Suite struct AutomationTests {
    private func rule(_ id: String, app: String = "com.app", device: String = "kbd", profile: String = "p1") -> AppRule {
        AppRule(id: id, bundleID: app, appName: app, deviceDefinitionID: device, profileID: profile)
    }

    @Test func ruleBeatsDefaultAndDefaultBeatsNothing() {
        var config = AutomationConfig()
        config.defaultProfiles["kbd"] = "default"
        config = config.upserting(rule("r1", app: "com.game", profile: "game"))
        #expect(config.profileID(frontmostBundleID: "com.game", deviceDefinitionID: "kbd") == "game")
        #expect(config.profileID(frontmostBundleID: "com.other", deviceDefinitionID: "kbd") == "default")
        #expect(config.profileID(frontmostBundleID: nil, deviceDefinitionID: "kbd") == "default")
        #expect(config.profileID(frontmostBundleID: "com.game", deviceDefinitionID: "mouse") == nil)
    }

    @Test func pausedMeansNothingIsResolved() {
        var config = AutomationConfig().upserting(rule("r1"))
        config.defaultProfiles["kbd"] = "d"
        config.paused = true
        #expect(config.profileID(frontmostBundleID: "com.app", deviceDefinitionID: "kbd") == nil)
    }

    @Test func oneRulePerAppAndDevice() {
        let config = AutomationConfig().upserting(rule("r1", profile: "a")).upserting(rule("r2", profile: "b"))
        #expect(config.rules.count == 1 && config.rules[0].profileID == "b")
        let other = config.upserting(rule("r3", device: "mouse"))
        #expect(other.rules.count == 2)
        #expect(other.upserting(rule("r3", device: "mouse", profile: "c")).rules.count == 2)
    }

    @Test func removingAProfileCleansRulesAndDefaults() {
        var config = AutomationConfig().upserting(rule("r1", profile: "gone")).upserting(rule("r2", app: "com.b", profile: "kept"))
        config.defaultProfiles = ["kbd": "gone", "mouse": "kept"]
        let cleaned = config.removingRules(forProfile: "gone")
        #expect(cleaned.rules.map(\.id) == ["r2"])
        #expect(cleaned.defaultProfiles == ["mouse": "kept"])
    }

    @Test func roundTripsThroughJSON() throws {
        var config = AutomationConfig().upserting(rule("r1"))
        config.paused = true
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(AutomationConfig.self, from: data) == config)
    }
}
