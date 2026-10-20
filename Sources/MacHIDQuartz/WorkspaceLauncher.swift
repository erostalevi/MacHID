import AppKit
import Foundation
import MacHIDApplication

/// Opens apps, URLs and files, and runs Shortcuts, for macros.
public struct WorkspaceLauncher: Launcher {
    public init() {}

    @MainActor
    private func openOnMain(_ target: String) async -> Bool {
        let workspace = NSWorkspace.shared
        // An app: a bundle id such as com.apple.Safari.
        if !target.contains("/"), !target.contains(":"), target.contains("."),
           let appURL = workspace.urlForApplication(withBundleIdentifier: target) {
            return (try? await workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())) != nil
        }
        // A URL with a scheme (https:, mailto:, ...).
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1 { return workspace.open(url) }
        // A file or folder.
        let expanded = (target as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return workspace.open(URL(fileURLWithPath: expanded)) }
        return false
    }

    public func open(_ target: String) async -> Bool { await openOnMain(target) }

    public func runShortcut(named name: String) async -> Bool {
        // Arguments are passed as an array: the name never goes through a shell.
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
