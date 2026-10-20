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
