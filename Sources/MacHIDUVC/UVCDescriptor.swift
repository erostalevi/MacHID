import MacHIDDomain

/// The parts of a UVC camera's descriptors the driver needs: which units exist and which controls
/// each one supports (the `bmControls` bitmaps).
public struct UVCDescriptor: Equatable, Sendable {
    public var videoControlInterface: UInt8
    public var processingUnitID: UInt8?
    public var processingControls: UInt32
    public var cameraTerminalID: UInt8?
    public var cameraControls: UInt32

    public static let cameraTerminalType: UInt16 = 0x0201

    /// Parses a USB configuration descriptor. Throws when it contains no Video Control interface.
    public static func parse(configuration bytes: [UInt8]) throws -> UVCDescriptor {
        var result = UVCDescriptor(videoControlInterface: 0, processingUnitID: nil, processingControls: 0,
                                   cameraTerminalID: nil, cameraControls: 0)
        var foundVideoControl = false
        var inVideoControl = false
        var index = 0
        while index + 2 <= bytes.count {
            let length = Int(bytes[index])
            guard length >= 2, index + length <= bytes.count else { break }
            let type = bytes[index + 1]
            if type == 0x04, length >= 9 {                     // interface descriptor
                let isVideoControl = bytes[index + 5] == 0x0E && bytes[index + 6] == 0x01
                if isVideoControl, !foundVideoControl {
                    foundVideoControl = true
                    result.videoControlInterface = bytes[index + 2]
                }
                inVideoControl = isVideoControl && bytes[index + 2] == result.videoControlInterface
            } else if type == 0x24, inVideoControl, length >= 4 {   // class-specific interface descriptor
                let descriptor = Array(bytes[index..<index + length])
                switch descriptor[2] {
                case 0x02 where length >= 16:                       // input terminal
                    let terminalType = UInt16(descriptor[4]) | UInt16(descriptor[5]) << 8
                    if terminalType == cameraTerminalType {
                        result.cameraTerminalID = descriptor[3]
                        result.cameraControls = bitmap(descriptor, sizeAt: 14)
                    }
                case 0x05 where length >= 8:                        // processing unit
                    result.processingUnitID = descriptor[3]
                    result.processingControls = bitmap(descriptor, sizeAt: 7)
                default: break
                }
            }
            index += length
        }
        guard foundVideoControl else { throw DriverError.deviceFailure("no UVC Video Control interface found") }
        return result
    }

    /// Little-endian `bmControls` that follows a one-byte size field (at most 4 bytes are kept).
    private static func bitmap(_ descriptor: [UInt8], sizeAt offset: Int) -> UInt32 {
        guard offset < descriptor.count else { return 0 }
        let size = min(Int(descriptor[offset]), 4)
        var value: UInt32 = 0
        for byte in 0..<size where offset + 1 + byte < descriptor.count {
            value |= UInt32(descriptor[offset + 1 + byte]) << (8 * UInt32(byte))
        }
        return value
    }
}
