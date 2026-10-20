import Foundation
import Observation
import Sparkle

/// Whether this build can update itself. Sparkle installs only updates signed with the project's EdDSA key, so a build
/// without that key (a local or development build) has updating switched off instead of trusting anything.
public enum UpdaterConfiguration {
    public static func isConfigured(infoDictionary: [String: Any]?) -> Bool {
        guard let info = infoDictionary,
              let key = info["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: key), keyData.count == 32,
              let feed = info["SUFeedURL"] as? String, let url = URL(string: feed), url.scheme == "https" else { return false }
        return true
    }
}

/// Checks GitHub Releases for a newer MacHID, downloads it in the background and installs it (Sparkle).
@MainActor
@Observable
public final class UpdaterModel {
    public let isAvailable: Bool
    public private(set) var canCheck = false
    public var automaticChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }
    public var automaticDownloads: Bool {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticDownloads }
    }
    public private(set) var lastCheck: Date?

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observer: NSKeyValueObservation?

    public init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        let configured = UpdaterConfiguration.isConfigured(infoDictionary: infoDictionary)
        isAvailable = configured
        controller = configured ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
        automaticChecks = controller?.updater.automaticallyChecksForUpdates ?? false
        automaticDownloads = controller?.updater.automaticallyDownloadsUpdates ?? false
        lastCheck = controller?.updater.lastUpdateCheckDate
        canCheck = controller?.updater.canCheckForUpdates ?? false
        observer = controller?.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = can }
        }
    }

    public func checkForUpdates() {
        controller?.checkForUpdates(nil)
        lastCheck = Date()
    }
}
