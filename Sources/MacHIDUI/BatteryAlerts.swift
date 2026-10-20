import Foundation
import UserNotifications

/// Delivers low-battery notifications. Behind a protocol so the model can be tested without the system.
public protocol BatteryAlerting: Sendable {
    /// True only when the user has already granted notification permission. Never prompts.
    func isAuthorized() async -> Bool
    /// Asks the system for permission (used when the user turns the alerts on). Returns whether it was granted.
    func requestAuthorization() async -> Bool
    func notifyLowBattery(deviceName: String, percent: Int) async
}

/// Decides when a low-battery alert is due: at 15 % and again at 5 %, each at most once per charge cycle.
/// A cycle ends when the device charges or climbs back above `resetAbove`.
struct BatteryAlertPolicy: Equatable {
    static let thresholds = [15, 5]
    static let resetAbove = 20

    private var alerted: [String: Set<Int>] = [:]

    /// Returns the threshold to announce for this reading, if any, and remembers it.
    /// A reading that skips straight below both thresholds announces only the lower one.
    mutating func threshold(for percent: Int?, charging: Bool?, device: String) -> Int? {
        guard let percent else { return nil }
        if charging == true || percent > Self.resetAbove {
            alerted[device] = nil
            return nil
        }
        var done = alerted[device] ?? []
        guard let crossed = Self.thresholds.filter({ percent <= $0 && !done.contains($0) }).min() else { return nil }
        for threshold in Self.thresholds where threshold >= crossed { done.insert(threshold) }
        alerted[device] = done
        return crossed
    }

    mutating func forget(device: String) { alerted[device] = nil }
}

/// Real implementation on `UNUserNotificationCenter`. The center is only touched when needed, so building the model
/// in a process without an app bundle (tests, CLI) is harmless.
public struct UserNotificationBatteryAlerts: BatteryAlerting {
    public init() {}

    public func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func notifyLowBattery(deviceName: String, percent: Int) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Low battery")
        content.body = String(localized: "\(deviceName) is at \(percent)%.")
        // One identifier per device and level: a repeated delivery replaces instead of stacking.
        let request = UNNotificationRequest(identifier: "machid.battery.\(deviceName).\(percent)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
