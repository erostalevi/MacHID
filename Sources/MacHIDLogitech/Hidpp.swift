import MacHIDDomain

/// HID++ 2.0 long message (report ID 0x11, 20 bytes on the wire):
/// `[0x11][device index][feature index][function << 4 | software id][16 parameter bytes]`.
public struct HidppMessage: Equatable, Sendable {
    public static let longReportID: UInt8 = 0x11
    public static let shortReportID: UInt8 = 0x10
    public static let parameterCount = 16
    /// Feature index 0xFF in a reply marks an error report.
    public static let errorFeatureIndex: UInt8 = 0xFF

    public var deviceIndex: UInt8
    public var featureIndex: UInt8
    public var function: UInt8
    public var softwareID: UInt8
    public var parameters: [UInt8]

    public init(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, softwareID: UInt8, parameters: [UInt8] = []) {
        precondition(function <= 0x0F && softwareID <= 0x0F, "function and software id are 4-bit values")
        precondition(parameters.count <= Self.parameterCount, "too many parameters")
        self.deviceIndex = deviceIndex
        self.featureIndex = featureIndex
        self.function = function
        self.softwareID = softwareID
        self.parameters = parameters + [UInt8](repeating: 0, count: Self.parameterCount - parameters.count)
    }

    /// Bytes after the report ID (19 bytes).
    public func encodedPayload() -> [UInt8] {
        [deviceIndex, featureIndex, function << 4 | softwareID] + parameters
    }

    /// Parses the bytes after the report ID of a long report.
    public static func decode(payload: [UInt8]) -> HidppMessage? {
        guard payload.count == 3 + parameterCount else { return nil }
        return HidppMessage(deviceIndex: payload[0], featureIndex: payload[1], function: payload[2] >> 4,
                            softwareID: payload[2] & 0x0F, parameters: Array(payload[3...]))
    }
}

public enum HidppError: Error, Equatable, CustomStringConvertible {
    case device(code: UInt8)
    case featureNotFound(UInt16)
    case malformed(String)

    public var description: String {
        switch self {
        case .device(let code): "device returned HID++ error 0x\(String(code, radix: 16))"
        case .featureNotFound(let id): "feature 0x\(String(id, radix: 16)) is not available on this device"
        case .malformed(let why): "unexpected HID++ reply: \(why)"
        }
    }
}

/// Request/response exchange over a `Transport` that supports output and input reports.
public struct HidppClient: Sendable {
    /// 0xFF addresses a device connected by cable.
    public static let wiredDeviceIndex: UInt8 = 0xFF
    public static let softwareID: UInt8 = 0x08

    private let transport: any Transport
    private let deviceIndex: UInt8
    private let timeout: Duration

    public init(transport: any Transport, deviceIndex: UInt8 = HidppClient.wiredDeviceIndex, timeout: Duration = .seconds(1)) {
        self.transport = transport
        self.deviceIndex = deviceIndex
        self.timeout = timeout
    }

    /// Sends a request and returns the 16 reply parameters. Unrelated reports (notifications) are skipped.
    public func request(featureIndex: UInt8, function: UInt8, parameters: [UInt8] = []) async throws -> [UInt8] {
        let message = HidppMessage(deviceIndex: deviceIndex, featureIndex: featureIndex, function: function,
                                   softwareID: Self.softwareID, parameters: parameters)
        try await transport.sendOutputReport(reportID: HidppMessage.longReportID, message.encodedPayload())

        let deadline = ContinuousClock.now + timeout
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw DriverError.deviceFailure("timed out waiting for the device") }
            let report = try await transport.nextInputReport(timeout: remaining)
            guard report.reportID == HidppMessage.longReportID || report.reportID == HidppMessage.shortReportID,
                  let reply = Self.decodeReply(report) else { continue }
            guard reply.deviceIndex == deviceIndex else { continue }

            if reply.featureIndex == HidppMessage.errorFeatureIndex {
                // Error layout: [dev][0xFF][failed feature index][failed function << 4 | swid][error code]
                // The failed feature index lands in the "function/software id" byte of the decoded message.
                let failedFeature = reply.function << 4 | reply.softwareID
                let failedFunction = reply.parameters[0]
                if failedFeature == featureIndex, failedFunction == message.encodedPayload()[2] {
                    throw HidppError.device(code: reply.parameters[1])
                }
                continue
            }
            if reply.featureIndex == featureIndex, reply.function == function, reply.softwareID == Self.softwareID {
                return reply.parameters
            }
        }
    }

    /// Short reports (7 bytes) are only expected for errors; pad them so one decoder handles both.
    static func decodeReply(_ report: (reportID: UInt8, data: [UInt8])) -> HidppMessage? {
        var payload = report.data
        if report.reportID == HidppMessage.shortReportID {
            guard payload.count == 6 else { return nil }
            payload += [UInt8](repeating: 0, count: HidppMessage.parameterCount - 3)
        }
        return HidppMessage.decode(payload: payload)
    }

    /// IRoot (feature 0x0000, index 0): resolves a feature id to its runtime index.
    public func featureIndex(for featureID: UInt16) async throws -> UInt8 {
        let reply = try await request(featureIndex: 0x00, function: 0, parameters: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)])
        guard reply[0] != 0 else { throw HidppError.featureNotFound(featureID) }
        return reply[0]
    }

    /// IRoot ping: returns the protocol version (major, minor).
    public func protocolVersion() async throws -> (major: UInt8, minor: UInt8) {
        let reply = try await request(featureIndex: 0x00, function: 1, parameters: [0, 0, 0x5A])
        guard reply[2] == 0x5A else { throw HidppError.malformed("ping data was not echoed") }
        return (reply[0], reply[1])
    }
}

/// Feature ids (from Solaar's public feature table).
public enum HidppFeature {
    public static let adjustableDPI: UInt16 = 0x2201
    public static let colorLEDEffects: UInt16 = 0x8070
    public static let rgbEffects: UInt16 = 0x8071
}
