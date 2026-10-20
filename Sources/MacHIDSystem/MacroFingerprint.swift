import CryptoKit
import Foundation
import Security
import MacHIDDomain

/// An HMAC-SHA256 of what a macro does (steps and repeat count), keyed with a secret that lives in the user's
/// Keychain. Approval is tied to it, so editing a step, even by one character, revokes approval, and a process
/// that can only write the macros file cannot forge an approval without the key.
public enum MacroFingerprint {
    /// Replaced in tests; the default reads (or creates) the Keychain key.
    nonisolated(unsafe) public static var key: SymmetricKey = ApprovalKeyStore.loadOrCreate()

    public static func of(_ macro: Macro) -> String {
        struct Canonical: Encodable { let steps: [MacroStep]; let repeatCount: Int }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Canonical(steps: macro.steps, repeatCount: macro.repeatCount))) ?? Data()
        return HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
    }

    /// The macro with the user's approval recorded for its current steps.
    public static func approving(_ macro: Macro) -> Macro {
        var copy = macro
        copy.approvedFingerprint = of(macro)
        return copy
    }
}

/// The approval key: 32 random bytes in the login Keychain. If the Keychain is unavailable the key lives in a
/// 0600 file in Application Support, so approvals still work (with weaker protection).
enum ApprovalKeyStore {
    private static let service = "app.machid.MacHID.macro-approval"
    private static let account = "hmac-key"

    static func loadOrCreate() -> SymmetricKey {
        if let data = readKeychain() { return SymmetricKey(data: data) }
        if let data = readFile() { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        if !writeKeychain(data) { writeFile(data) }
        return key
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func readKeychain() -> Data? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 else { return nil }
        return data
    }

    private static func writeKeychain(_ data: Data) -> Bool {
        var q = query()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacHID/approval.key")
    }

    private static func readFile() -> Data? {
        guard let data = try? Data(contentsOf: fileURL), data.count == 32 else { return nil }
        return data
    }

    private static func writeFile(_ data: Data) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
