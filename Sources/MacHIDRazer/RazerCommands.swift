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
}
