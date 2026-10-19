import MacHIDDomain

/// The 90-byte Razer control report (sent and read as a HID feature report, report ID 0).
///
/// Layout: status, transaction id, remaining packets (2, big-endian), protocol type, data size,
/// command class, command id, 80 argument bytes, CRC, reserved.
public struct RazerReport: Equatable, Sendable {
    public static let size = 90
    public static let argumentCapacity = 80

    public enum Status: UInt8, Sendable {
        case new = 0x00, busy = 0x01, successful = 0x02, failure = 0x03, timeout = 0x04, notSupported = 0x05
    }

    public var status: UInt8
    public var transactionID: UInt8
    public var commandClass: UInt8
    public var commandID: UInt8
    public var dataSize: UInt8
    public var arguments: [UInt8]

    /// - Parameter arguments: padded with zeros to 80 bytes; must not exceed 80.
    public init(transactionID: UInt8, commandClass: UInt8, commandID: UInt8, dataSize: UInt8,
                arguments: [UInt8] = [], status: UInt8 = 0x00) {
        precondition(arguments.count <= Self.argumentCapacity, "too many arguments")
        precondition(Int(dataSize) <= Self.argumentCapacity, "data size too large")
        self.status = status
        self.transactionID = transactionID
        self.commandClass = commandClass
        self.commandID = commandID
        self.dataSize = dataSize
        self.arguments = arguments + [UInt8](repeating: 0, count: Self.argumentCapacity - arguments.count)
    }

    /// XOR of bytes 2..<88, as the devices expect.
    public static func crc(of bytes: [UInt8]) -> UInt8 {
        bytes[2..<88].reduce(0, ^)
    }

    public func encoded() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.size)
        bytes[0] = status
        bytes[1] = transactionID
        // bytes[2...3] remaining packets and bytes[4] protocol type stay 0
        bytes[5] = dataSize
        bytes[6] = commandClass
        bytes[7] = commandID
        bytes.replaceSubrange(8..<88, with: arguments)
        bytes[88] = Self.crc(of: bytes)
        return bytes
    }

    public static func decode(_ bytes: [UInt8]) throws -> RazerReport {
        guard bytes.count == size else {
            throw DriverError.deviceFailure("response has \(bytes.count) bytes, expected \(size)")
        }
        // A device never reports more argument bytes than the report can hold; clamp defensively.
        let dataSize = min(bytes[5], UInt8(argumentCapacity))
        return RazerReport(transactionID: bytes[1], commandClass: bytes[6], commandID: bytes[7],
                           dataSize: dataSize, arguments: Array(bytes[8..<88]), status: bytes[0])
    }
}
