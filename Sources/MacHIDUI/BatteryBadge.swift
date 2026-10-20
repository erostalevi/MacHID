import SwiftUI

/// Pure display rules for a battery reading, kept apart from the view so they can be tested.
enum BatteryDisplay {
    static let lowThreshold = 15
    static let criticalThreshold = 5

    static func symbolName(percent: Int?) -> String {
        guard let percent else { return "battery.0percent" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func isLow(percent: Int?, charging: Bool?) -> Bool {
        guard let percent, charging != true else { return false }
        return percent <= lowThreshold
    }

    static func isCritical(percent: Int?, charging: Bool?) -> Bool {
        guard let percent, charging != true else { return false }
        return percent <= criticalThreshold
    }
}

/// Battery icon with percentage; a bolt while charging; orange at 15 % and red at 5 % or less.
public struct BatteryBadge: View {
    let percent: Int?
    let charging: Bool?

    public init(percent: Int?, charging: Bool?) {
        self.percent = percent
        self.charging = charging
    }

    private var tint: Color {
        if BatteryDisplay.isCritical(percent: percent, charging: charging) { return .red }
        if BatteryDisplay.isLow(percent: percent, charging: charging) { return .orange }
        return .primary
    }

    private var accessibilityText: String {
        guard let percent else { return String(localized: "Battery level unknown") }
        let level = String(localized: "Battery \(percent) percent")
        return charging == true ? level + ", " + String(localized: "charging") : level
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: BatteryDisplay.symbolName(percent: percent))
            if charging == true { Image(systemName: "bolt.fill").imageScale(.small) }
            Text(verbatim: percent.map { "\($0)%" } ?? "--")
                .monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }
}
