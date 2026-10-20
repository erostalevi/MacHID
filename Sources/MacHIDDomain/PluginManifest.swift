import Foundation

/// What a plugin may do with a device. Shown to the user before installing; a change in an update needs a new approval.
public struct PluginPermissions: Codable, Equatable, Sendable {
    public enum Transport: String, Codable, Sendable { case hid, uvc }
    public enum Writes: String, Codable, Sendable { case none, volatile, persistent }

    public var transport: Transport
    public var interfaces: [Int]?
    public var reportIDs: [Int]?
    public var writes: Writes

    enum CodingKeys: String, CodingKey {
        case transport, interfaces, writes
        case reportIDs = "report_ids"
    }

    public init(transport: Transport, interfaces: [Int]? = nil, reportIDs: [Int]? = nil, writes: Writes) {
        self.transport = transport
        self.interfaces = interfaces
        self.reportIDs = reportIDs
        self.writes = writes
    }
}

/// `manifest.json` at the root of a plugin repository.
public struct PluginManifest: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let license: String
    public let author: String
    public let coreAPI: APIRange
    public let devices: [USBID]
    /// Entry script (JavaScript) of a code driver, run in the sandbox host. Nil for data-only plugins.
    public let driver: String?
    public let permissions: PluginPermissions
    /// Definition files, relative to the plugin root. Default: `devices/*.json`.
    public let definitions: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, version, license, author, devices, driver, permissions, definitions
        case coreAPI = "core_api"
    }

    public init(id: String, name: String, version: String, license: String, author: String, coreAPI: APIRange, devices: [USBID],
                driver: String?, permissions: PluginPermissions, definitions: [String]?) {
        self.id = id
        self.name = name
        self.version = version
        self.license = license
        self.author = author
        self.coreAPI = coreAPI
        self.devices = devices
        self.driver = driver
        self.permissions = permissions
        self.definitions = definitions
    }

    public var isDataOnly: Bool { driver == nil }
}

public struct ManifestIssue: Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public var description: String { message }
}

extension PluginManifest {
    public static let maxDefinitionFiles = 64

    /// Offline checks on a manifest. Anything it returns means the plugin must not be installed.
    public func validate(coreAPIVersion: Int = MacHIDDomain.coreAPIVersion) -> [ManifestIssue] {
        var issues: [ManifestIssue] = []
        func fail(_ message: String) { issues.append(ManifestIssue(message: message)) }
        if !Identifier.isValid(id) { fail("invalid id (lowercase kebab-case)") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name.count > 80 { fail("name must be 1-80 characters") }
        if SemanticVersion(version) == nil { fail("version must look like 1.2.3") }
        if !RegistryValidator.allowedLicenses.contains(license) { fail("license '\(license)' is not an allowed SPDX id") }
        if author.trimmingCharacters(in: .whitespaces).isEmpty { fail("author is required") }
        if devices.isEmpty { fail("devices must not be empty") }
        if coreAPI.min < 1 || coreAPI.min > coreAPI.max { fail("invalid core_api range") }
        else if !coreAPI.contains(coreAPIVersion) { fail("needs core API \(coreAPI.min)-\(coreAPI.max); this MacHID has \(coreAPIVersion)") }
        if permissions.writes == .persistent { fail("writes to device memory are not allowed yet") }
        if let driver {
            if !Self.isSafeRelativePath(driver) || !driver.hasSuffix(".js") { fail("driver '\(driver)' must be a relative .js path inside the plugin") }
            if permissions.transport != .hid { fail("code plugins can only use the hid transport") }
        }
        if let definitions {
            if definitions.count > Self.maxDefinitionFiles { fail("too many definition files") }
            for path in definitions where !Self.isSafeRelativePath(path) || !path.hasSuffix(".json") {
                fail("definition path '\(path)' must be a relative .json path inside the plugin")
            }
        }
        return issues
    }

    /// No absolute paths, parent references, hidden path parts or backslashes.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.hasPrefix(".")
        }
    }
}

/// `MAJOR.MINOR.PATCH`, compared numerically.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
