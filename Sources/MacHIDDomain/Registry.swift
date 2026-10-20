import Foundation

/// Version of the plugin/core contract. Bump on breaking changes to the plugin API.
public let coreAPIVersion = 1

public enum ReviewLevel: String, Sendable, Codable {
    case reviewed, community
}

public struct APIRange: Sendable, Codable, Equatable {
    public let min: Int
    public let max: Int

    public init(min: Int, max: Int) {
        self.min = min
        self.max = max
    }

    public func contains(_ version: Int) -> Bool { version >= min && version <= max }
}

public struct RegistryEntry: Sendable, Codable, Equatable {
    public let id: String
    public let repo: String
    /// Full 40-character commit SHA. Branches and tags are rejected so installs are reproducible.
    public let ref: String
    public let manifestSha256: String
    public let license: String
    public let category: DeviceCategory
    public let devices: [USBID]
    public let coreApi: APIRange
    public let review: ReviewLevel

    enum CodingKeys: String, CodingKey {
        case id, repo, ref, license, category, devices, review
        case manifestSha256 = "manifest_sha256"
        case coreApi = "core_api"
    }

    public init(id: String, repo: String, ref: String, manifestSha256: String, license: String, category: DeviceCategory,
                devices: [USBID], coreApi: APIRange, review: ReviewLevel) {
        self.id = id
        self.repo = repo
        self.ref = ref
        self.manifestSha256 = manifestSha256
        self.license = license
        self.category = category
        self.devices = devices
        self.coreApi = coreApi
        self.review = review
    }
}

/// The `plugins.json` index.
public struct Registry: Sendable, Codable, Equatable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let plugins: [RegistryEntry]
    /// Added by the publishing workflow inside the signed document, never committed: a counter that only goes up and the
    /// time of issue. Together they stop an old (validly signed) list from being served again.
    public let sequence: Int?
    public let issuedAt: String?

    public init(schemaVersion: Int = Registry.supportedSchemaVersion, plugins: [RegistryEntry], sequence: Int? = nil, issuedAt: String? = nil) {
        self.schemaVersion = schemaVersion
        self.plugins = plugins
        self.sequence = sequence
        self.issuedAt = issuedAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case plugins, sequence
        case issuedAt = "issued_at"
    }

    public static func decode(_ data: Data) throws -> Registry {
        try JSONDecoder().decode(Registry.self, from: data)
    }
}

public struct RegistryIssue: Equatable, CustomStringConvertible, Sendable {
    public let pluginID: String?
    public let message: String

    public var description: String { "\(pluginID ?? "registry"): \(message)" }
}

/// Rules from SPEC §6 / §16.3 that can be checked offline. Repo existence and hash checks
/// against the network belong to the CI workflow, not the domain.
public struct RegistryValidator: Sendable {
    public static let allowedHosts: Set<String> = ["github.com"]
    /// SPDX ids compatible with distribution inside a GPLv3 project.
    public static let allowedLicenses: Set<String> = [
        "GPL-3.0-only", "GPL-3.0-or-later", "LGPL-3.0-only", "LGPL-3.0-or-later",
        "MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "ISC", "MPL-2.0", "CC0-1.0", "Unlicense",
    ]

    public init() {}

    public func validate(_ registry: Registry) -> [RegistryIssue] {
        var issues: [RegistryIssue] = []
        if registry.schemaVersion != Registry.supportedSchemaVersion {
            issues.append(.init(pluginID: nil, message: "unsupported schema_version \(registry.schemaVersion)"))
        }
        var seen = Set<String>()
        for entry in registry.plugins {
            func fail(_ message: String) { issues.append(.init(pluginID: entry.id, message: message)) }
            if !Identifier.isValid(entry.id) { fail("invalid id (lowercase kebab-case)") }
            if !seen.insert(entry.id).inserted { fail("duplicate id") }
            if !Self.isAllowedRepo(entry.repo) { fail("repo must be an https URL on \(Self.allowedHosts.sorted().joined(separator: ", "))") }
            if !Self.isHex(entry.ref, length: 40) { fail("ref must be a 40-character commit SHA") }
            if !Self.isHex(entry.manifestSha256, length: 64) { fail("manifest_sha256 must be 64 hex characters") }
            if !Self.allowedLicenses.contains(entry.license) { fail("license '\(entry.license)' is not an allowed SPDX id") }
            if entry.devices.isEmpty { fail("devices must not be empty") }
            if entry.coreApi.min > entry.coreApi.max || entry.coreApi.min < 1 { fail("invalid core_api range") }
        }
        return issues
    }

    static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    public static func isAllowedRepo(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "https",
              let host = url.host?.lowercased(), allowedHosts.contains(host),
              url.user == nil, url.query == nil, url.fragment == nil,
              url.pathComponents.filter({ $0 != "/" }).count == 2
        else { return false }
        return true
    }
}
