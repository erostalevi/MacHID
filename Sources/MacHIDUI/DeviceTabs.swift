import SwiftUI
import MacHIDDomain

/// The three tabs of the device sidebar. Every device gets the ones it has controls for:
/// Light is visual configuration, Keys is functional configuration, Info is read-only (plus advanced options).
public enum DeviceTab: String, CaseIterable, Hashable, Sendable {
    case light, keys, info

    /// Domain sections that live inside this tab, in display order.
    var sections: [ControlSection] {
        switch self {
        case .light: [.lighting, .image]
        case .keys: [.buttons, .performance]
        case .info: [.info, .advanced]
        }
    }

    /// The section a tab selects when it is picked.
    var primarySection: ControlSection { sections[0] }

    static func of(_ section: ControlSection) -> DeviceTab {
        allCases.first { $0.sections.contains(section) } ?? .info
    }

    var title: Text {
        switch self {
        case .light: Text("Light")
        case .keys: Text("Keys")
        case .info: Text("Info")
        }
    }

    var name: String {
        switch self {
        case .light: String(localized: "Light")
        case .keys: String(localized: "Keys")
        case .info: String(localized: "Info")
        }
    }

    var symbol: String {
        switch self {
        case .light: "lightbulb"
        case .keys: "keyboard"
        case .info: "info.circle"
        }
    }
}

extension AppModel.DeviceEntry {
    /// Tabs this device shows. Info is always there; a camera has no Keys, a device without lighting no Light.
    var tabs: [DeviceTab] {
        DeviceTab.allCases.filter { tab in tab == .info || tab.sections.contains { sections.contains($0) } }
    }
}
