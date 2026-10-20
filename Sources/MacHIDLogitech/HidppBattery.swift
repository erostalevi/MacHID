import MacHIDDomain

/// Decoders for the HID++ 2.0 battery features. Layouts follow Solaar's `decipher_battery_*`
/// (lib/logitech_receiver/hidpp20.py) and libratbag's hidpp20.c. Pure functions: they take the 16 reply parameters.
public enum HidppBattery {
    /// Charging flag from the shared status byte: 1 recharging, 2 charging in final state and 4 slow recharge
    /// mean charging; 0 discharging and 3 charge complete mean not charging; anything else is unknown.
    static func charging(statusByte: UInt8) -> Bool? {
        switch statusByte {
        case 1, 2, 4: true
        case 0, 3: false
        default: nil
        }
    }

    /// 0x1000 function 0: `[level %, next level %, status]`. A level of 0 means "unknown".
    public static func levelStatus(_ parameters: [UInt8]) -> SettingValue {
        let level = Int(parameters[0])
        return .battery(percent: level == 0 ? nil : min(level, 100), charging: charging(statusByte: parameters[2]))
    }

    /// 0x1004 function 1: `[state of charge %, level flags, status, ...]`. When the percentage is 0 the
    /// coarse level flags are mapped to Solaar's approximations (full 90, good 50, low 20, critical 5).
    public static func unified(_ parameters: [UInt8]) -> SettingValue {
        let soc = Int(parameters[0])
        let percent: Int?
        if soc > 0 {
            percent = min(soc, 100)
        } else {
            switch parameters[1] {
            case 8: percent = 90
            case 4: percent = 50
            case 2: percent = 20
            case 1: percent = 5
            default: percent = nil
            }
        }
        return .battery(percent: percent, charging: charging(statusByte: parameters[2]))
    }

    /// 0x1001 function 0: `[voltage mV (BE16), flags]`; flag bit 7 = charging. Percent is estimated from voltage
    /// with Solaar's table, so it is approximate.
    public static func voltage(_ parameters: [UInt8]) -> SettingValue {
        let millivolts = Int(parameters[0]) << 8 | Int(parameters[1])
        return .battery(percent: percent(forMillivolts: millivolts), charging: parameters[2] & 0x80 != 0)
    }

    private static let voltageTable: [(mv: Int, percent: Int)] = [
        (4186, 100), (4067, 90), (3989, 80), (3922, 70), (3859, 60), (3811, 50),
        (3778, 40), (3751, 30), (3717, 20), (3671, 10), (3646, 5), (3579, 2), (3500, 0),
    ]

    static func percent(forMillivolts mv: Int) -> Int {
        if mv >= voltageTable[0].mv { return 100 }
        if mv <= voltageTable[voltageTable.count - 1].mv { return 0 }
        for index in 0..<(voltageTable.count - 1) {
            let high = voltageTable[index], low = voltageTable[index + 1]
            if mv >= low.mv && mv <= high.mv {
                let fraction = Double(mv - low.mv) / Double(high.mv - low.mv)
                return Int((Double(low.percent) + Double(high.percent - low.percent) * fraction).rounded())
            }
        }
        return 0
    }
}
