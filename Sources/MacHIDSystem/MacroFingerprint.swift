import CryptoKit
import Foundation
import MacHIDDomain

/// A SHA-256 of what a macro does (steps and repeat count). Approval is tied to it, so editing a step, even by
/// one character, revokes approval.
public enum MacroFingerprint {
    public static func of(_ macro: Macro) -> String {
        struct Canonical: Encodable { let steps: [MacroStep]; let repeatCount: Int }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Canonical(steps: macro.steps, repeatCount: macro.repeatCount))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The macro with the user's approval recorded for its current steps.
    public static func approving(_ macro: Macro) -> Macro {
        var copy = macro
        copy.approvedFingerprint = of(macro)
        return copy
    }
}
