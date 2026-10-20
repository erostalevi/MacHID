import MacHIDDomain

/// Builders for the commands M2 uses. Values verified against the OpenRazer protocol notes
/// (GPL-2.0-or-later, compatible with this project's GPLv3).
public enum RazerCommands {
    public static let noStore: UInt8 = 0x00
    /// "Variable storage": applied to the device now, not written to onboard profile memory.
    public static let varStore: UInt8 = 0x01
    public static let backlightLED: UInt8 = 0x05

    /// Standard commands (class 0x00) use transaction id 0xFF on the models we support.
    public static let standardTransactionID: UInt8 = 0xFF

    public static func firmwareVersion() -> RazerReport {
        RazerReport(transactionID: standardTransactionID, commandClass: 0x00, commandID: 0x81, dataSize: 0x02)
    }

    /// Battery level (class 0x07, command 0x80): 0...255 in argument 1. OpenRazer `razer_chroma_misc_get_battery_level`.
    public static func batteryLevel(transactionID: UInt8) -> RazerReport {
        RazerReport(transactionID: transactionID, commandClass: 0x07, commandID: 0x80, dataSize: 0x02)
    }

    /// Charging status (class 0x07, command 0x84): 0 or 1 in argument 1. OpenRazer `razer_chroma_misc_get_charging_status`.
    public static func chargingStatus(transactionID: UInt8) -> RazerReport {
        RazerReport(transactionID: transactionID, commandClass: 0x07, commandID: 0x84, dataSize: 0x02)
    }

    public static func getBrightness(transactionID: UInt8) -> RazerReport {
        RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x84, dataSize: 0x03,
                    arguments: [varStore, backlightLED, 0x00])
    }

    public static func setBrightness(_ raw: UInt8, transactionID: UInt8) -> RazerReport {
        RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x04, dataSize: 0x03,
                    arguments: [varStore, backlightLED, raw])
    }

    public static func staticColor(_ color: RGBColor, transactionID: UInt8) -> RazerReport {
        RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x09,
                    arguments: [varStore, backlightLED, 0x01, 0x00, 0x00, 0x01, color.r, color.g, color.b])
    }

    public static func effectNone(transactionID: UInt8) -> RazerReport {
        RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x06,
                    arguments: [varStore, backlightLED, 0x00])
    }

    /// Built-in effects of the extended matrix (class 0x0F, command 0x02). Layouts follow the packet
    /// examples in OpenRazer's razerchromacommon.c.
    public static func spectrum(transactionID: UInt8) -> RazerReport {
        RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x06,
                    arguments: [varStore, backlightLED, 0x03])
    }

    /// `direction`: 0 or 1 on current devices (some older models use 1 and 2). Speed byte 0x28 is the default.
    public static func wave(direction: UInt8, transactionID: UInt8) -> RazerReport {
        RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x06,
                    arguments: [varStore, backlightLED, 0x04, min(direction, 2), 0x28])
    }

    /// `speed` 1...4 (lower is faster reaction decay).
    public static func reactive(speed: UInt8, color: RGBColor, transactionID: UInt8) -> RazerReport {
        RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x09,
                    arguments: [varStore, backlightLED, 0x05, 0x00, min(max(speed, 1), 4), 0x01, color.r, color.g, color.b])
    }

    /// `speed` 1...3. Without a color the stars are random.
    public static func starlight(speed: UInt8, color: RGBColor?, transactionID: UInt8) -> RazerReport {
        let speed = min(max(speed, 1), 3)
        guard let color else {
            return RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x06,
                               arguments: [varStore, backlightLED, 0x07, 0x00, speed])
        }
        return RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x09,
                           arguments: [varStore, backlightLED, 0x07, 0x00, speed, 0x01, color.r, color.g, color.b])
    }

    /// Device mode: 0x00 normal, 0x03 driver mode. Mode 0x02 (factory test) is deliberately not offered.
    public static func getDeviceMode() -> RazerReport {
        RazerReport(transactionID: standardTransactionID, commandClass: 0x00, commandID: 0x84, dataSize: 0x02)
    }

    public static func setDeviceMode(_ mode: UInt8) -> RazerReport {
        precondition(mode == 0x00 || mode == 0x03, "only normal (0) and driver (3) modes are allowed")
        return RazerReport(transactionID: standardTransactionID, commandClass: 0x00, commandID: 0x04, dataSize: 0x02,
                           arguments: [mode, 0x00])
    }

    // MARK: Breathing, dual colors, custom frame (M11)

    /// Breathing (effect 0x02). OpenRazer `razer_chroma_extended_matrix_effect_breathing_random/single/dual`.
    /// Random: data size 6, no colors. Single: size 9, arg3 = 1, arg5 = 1, RGB at args 6...8.
    /// Dual: size 0x0C, arg3 = 2, arg5 = 2, RGB1 at 6...8, RGB2 at 9...11.
    public static func breathing(color: RGBColor?, secondColor: RGBColor?, transactionID: UInt8) -> RazerReport {
        switch (color, secondColor) {
        case (let first?, let second?):
            return RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x0C,
                               arguments: [varStore, backlightLED, 0x02, 0x02, 0x00, 0x02,
                                           first.r, first.g, first.b, second.r, second.g, second.b])
        case (let first?, nil):
            return RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x09,
                               arguments: [varStore, backlightLED, 0x02, 0x01, 0x00, 0x01, first.r, first.g, first.b])
        default:
            return RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x06,
                               arguments: [varStore, backlightLED, 0x02])
        }
    }

    /// Starlight with two colors (size 0x0C, arg5 = 2). OpenRazer `razer_chroma_extended_matrix_effect_starlight_dual`.
    public static func starlight(speed: UInt8, color: RGBColor, secondColor: RGBColor, transactionID: UInt8) -> RazerReport {
        RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x0C,
                    arguments: [varStore, backlightLED, 0x07, 0x00, min(max(speed, 1), 3), 0x02,
                                color.r, color.g, color.b, secondColor.r, secondColor.g, secondColor.b])
    }

    /// One row of the custom frame (class 0x0F, command 0x03, data size 0x47). Layout from OpenRazer
    /// `razer_chroma_extended_matrix_set_custom_frame2`: args 0...1 = 0, arg2 = row, arg3 = first column,
    /// arg4 = last column (inclusive), RGB triplets from arg5. Huntsman Mini uses transaction id 0x3F
    /// (`razer_attr_write_matrix_custom_frame` in razerkbd_driver.c).
    public static func customFrameRow(row: UInt8, startColumn: UInt8, colors: [RGBColor], transactionID: UInt8) -> RazerReport {
        precondition(!colors.isEmpty && colors.count <= 25, "a row carries 1...25 cells")
        let stop = startColumn + UInt8(colors.count - 1)
        let rgb = colors.flatMap { [$0.r, $0.g, $0.b] }
        return RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x03, dataSize: 0x47,
                           arguments: [0x00, 0x00, row, startColumn, stop] + rgb)
    }

    /// Shows the frame sent with `customFrameRow` (effect 0x08, data size 0x0C, no storage byte set).
    /// OpenRazer `razer_chroma_extended_matrix_effect_custom_frame`.
    public static func activateCustomFrame(transactionID: UInt8) -> RazerReport {
        RazerReport(transactionID: transactionID, commandClass: 0x0F, commandID: 0x02, dataSize: 0x0C,
                    arguments: [0x00, 0x00, 0x08])
    }
}
