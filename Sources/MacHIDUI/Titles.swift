import SwiftUI
import MacHIDDomain

/// User-facing names. Literals are listed explicitly so they land in the string catalog; ids this version
/// does not know (from plugins) fall back to a readable form of the id.
enum Titles {
    static func control(_ id: String) -> Text {
        switch id {
        case "info": Text("Information")
        case "brightness": Text("Brightness")
        case "backlight": Text("Backlight")
        case "dpi": Text("DPI")
        case "device_mode": Text("Host control")
        case "contrast": Text("Contrast")
        case "saturation": Text("Saturation")
        case "sharpness": Text("Sharpness")
        case "gain": Text("Gain")
        case "white_balance_temperature": Text("White balance")
        case "white_balance_auto": Text("Auto white balance")
        case "backlight_compensation": Text("Backlight compensation")
        case "power_line_frequency": Text("Power line frequency")
        case "features": Text("Features")
        case "polling_rate": Text("Polling rate")
        case "exposure_auto": Text("Auto exposure")
        case "exposure_time": Text("Exposure time")
        default: Text(verbatim: humanize(id))
        }
    }

    static func section(_ section: ControlSection) -> Text {
        switch section {
        case .lighting: Text("Lighting")
        case .performance: Text("Performance")
        case .image: Text("Image")
        case .advanced: Text("Advanced")
        case .info: Text("Details")
        }
    }

    static func choice(_ value: Int, control id: String) -> Text {
        switch (id, value) {
        case ("power_line_frequency", 0): Text("Off")
        case ("power_line_frequency", 1): Text(verbatim: "50 Hz")
        case ("power_line_frequency", 2): Text(verbatim: "60 Hz")
        case ("polling_rate", _): Text(verbatim: "\(value) Hz")
        default: Text(verbatim: "\(value)")
        }
    }

    static func lightingMode(_ mode: String) -> Text {
        switch mode {
        case "static": Text("Static")
        case "off": Text("Off")
        case "spectrum": Text("Spectrum")
        case "wave": Text("Wave")
        case "reactive": Text("Reactive")
        case "starlight": Text("Starlight")
        case "cycle": Text("Cycle")
        case "breathing": Text("Breathing")
        default: Text(verbatim: humanize(mode))
        }
    }

    static func humanize(_ id: String) -> String {
        let words = id.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func symbol(for category: DeviceCategory) -> String {
        switch category {
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        case .camera: "web.camera"
        case .headset: "headphones"
        case .other: "cable.connector"
        }
    }

    static func symbol(for section: ControlSection) -> String {
        switch section {
        case .lighting: "lightbulb"
        case .performance: "speedometer"
        case .image: "camera.filters"
        case .advanced: "slider.horizontal.3"
        case .info: "info.circle"
        }
    }
}

extension MacHIDDomain.RGBColor {
    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func byte(_ value: CGFloat) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        self.init(r: byte(ns.redComponent), g: byte(ns.greenComponent), b: byte(ns.blueComponent))
    }
}
