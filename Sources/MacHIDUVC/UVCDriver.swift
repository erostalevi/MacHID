import MacHIDDomain

/// A UVC processing-unit control the driver can read and set.
struct UVCControl: Sendable {
    enum Kind: Sendable { case range, flag, enumeration(ClosedRange<Int>), autoExposure }
    /// Which unit of the camera owns the control, and so which `bmControls` bitmap the `bit` indexes.
    enum Entity: Sendable { case processing, camera }

    let id: String
    let selector: UInt8
    let size: Int
    let bit: Int
    let signed: Bool
    let kind: Kind
    let entity: Entity

    init(id: String, selector: UInt8, size: Int, bit: Int, signed: Bool, kind: Kind, entity: Entity = .processing) {
        self.id = id
        self.selector = selector
        self.size = size
        self.bit = bit
        self.signed = signed
        self.kind = kind
        self.entity = entity
    }

    /// Selectors, sizes and bit positions follow the USB Video Class spec as implemented by Linux uvcvideo.
    static let all: [UVCControl] = [
        UVCControl(id: "brightness", selector: 0x02, size: 2, bit: 0, signed: true, kind: .range),
        UVCControl(id: "contrast", selector: 0x03, size: 2, bit: 1, signed: false, kind: .range),
        UVCControl(id: "saturation", selector: 0x07, size: 2, bit: 3, signed: false, kind: .range),
        UVCControl(id: "sharpness", selector: 0x08, size: 2, bit: 4, signed: false, kind: .range),
        UVCControl(id: "white_balance_temperature", selector: 0x0A, size: 2, bit: 6, signed: false, kind: .range),
        UVCControl(id: "backlight_compensation", selector: 0x01, size: 2, bit: 8, signed: false, kind: .range),
        UVCControl(id: "gain", selector: 0x04, size: 2, bit: 9, signed: false, kind: .range),
        UVCControl(id: "power_line_frequency", selector: 0x05, size: 1, bit: 10, signed: false, kind: .enumeration(0...2)),
        UVCControl(id: "white_balance_auto", selector: 0x0B, size: 1, bit: 12, signed: false, kind: .flag),
        // Camera terminal: auto-exposure mode, and the exposure time in units of 100 microseconds.
        UVCControl(id: "exposure_auto", selector: 0x02, size: 1, bit: 1, signed: false, kind: .autoExposure, entity: .camera),
        UVCControl(id: "exposure_time", selector: 0x04, size: 4, bit: 3, signed: false, kind: .range, entity: .camera),
    ]

    static func control(id: String) -> UVCControl? { all.first { $0.id == id } }
}

/// Generic USB Video Class driver (processing-unit controls). Values are applied to the camera's current
/// state; UVC cameras keep no onboard profile, and values reset when the camera is reconnected.
///
/// Capability ids: `info` (read: the controls the camera supports) plus the ids in `UVCControl.all`.
public struct UVCDriver: DeviceDriver {
    public let familyID = "uvc"

    private enum Request {
        static let setCur: UInt8 = 0x01
        static let getCur: UInt8 = 0x81, getMin: UInt8 = 0x82, getMax: UInt8 = 0x83, getRes: UInt8 = 0x84, getDef: UInt8 = 0x87
        static let toDevice: UInt8 = 0x21     // class request, interface recipient
        static let toHost: UInt8 = 0xA1
    }

    public init() {}

    public func read(_ capability: CapabilityDescriptor, using transport: any Transport) async throws -> SettingValue {
        let descriptor = try await UVCDescriptor.parse(configuration: transport.usbConfigurationDescriptor())
        if capability.id == "info" {
            let supported = UVCControl.all.filter { isSupported($0, in: descriptor) }.map(\.id)
            return .text(supported.joined(separator: " "))
        }
        guard let control = UVCControl.control(id: capability.id) else { throw DriverError.unsupportedCapability(capability.id) }
        let unit = try unitID(for: control, in: descriptor)
        let current = try await query(Request.getCur, control, unit: unit, descriptor: descriptor, transport: transport)
        if case .autoExposure = control.kind { return .int(current == Self.manualExposure ? 0 : 1) }
        return .int(current)
    }

    public func write(_ value: SettingValue, to capability: CapabilityDescriptor, using transport: any Transport) async throws {
        guard let control = UVCControl.control(id: capability.id) else { throw DriverError.unsupportedCapability(capability.id) }
        guard case .int(let requested) = value else { throw DriverError.invalidValue("wrong value type for '\(control.id)'") }
        let descriptor = try await UVCDescriptor.parse(configuration: transport.usbConfigurationDescriptor())
        let unit = try unitID(for: control, in: descriptor)

        var number = requested
        switch control.kind {
        case .autoExposure:
            guard number == 0 || number == 1 else { throw DriverError.invalidValue("\(control.id) must be 0 or 1") }
            if number == 1 {
                // GET_RES of the AE mode lists the modes the camera supports as a bit field.
                let modes = try await query(Request.getRes, control, unit: unit, descriptor: descriptor, transport: transport)
                guard let automatic = Self.automaticExposureMode(supported: modes) else {
                    throw DriverError.deviceFailure("this camera reports no automatic exposure mode")
                }
                number = automatic
            } else {
                number = Self.manualExposure
            }
        case .flag:
            guard number == 0 || number == 1 else { throw DriverError.invalidValue("\(control.id) must be 0 or 1") }
        case .enumeration(let allowed):
            guard allowed.contains(number) else { throw DriverError.invalidValue("\(control.id) must be in \(allowed)") }
        case .range:
            // The camera reports its own limits; never send a value outside them.
            let low = try await query(Request.getMin, control, unit: unit, descriptor: descriptor, transport: transport)
            let high = try await query(Request.getMax, control, unit: unit, descriptor: descriptor, transport: transport)
            let step = max(1, (try? await query(Request.getRes, control, unit: unit, descriptor: descriptor, transport: transport)) ?? 1)
            guard (low...high).contains(number) else {
                throw DriverError.invalidValue("\(control.id) must be between \(low) and \(high)")
            }
            guard (number - low) % step == 0 else {
                throw DriverError.invalidValue("\(control.id) must be \(low) plus a multiple of \(step)")
            }
        }
        try await transport.controlWrite(requestType: Request.toDevice, request: Request.setCur,
                                         value: UInt16(control.selector) << 8,
                                         index: UInt16(unit) << 8 | UInt16(descriptor.videoControlInterface),
                                         data: Self.encode(number, size: control.size))
    }

    public func limits(for capability: CapabilityDescriptor, using transport: any Transport) async throws -> ValueLimits? {
        guard let control = UVCControl.control(id: capability.id), case .range = control.kind else { return nil }
        let descriptor = try await UVCDescriptor.parse(configuration: transport.usbConfigurationDescriptor())
        let unit = try unitID(for: control, in: descriptor)
        let low = try await query(Request.getMin, control, unit: unit, descriptor: descriptor, transport: transport)
        let high = try await query(Request.getMax, control, unit: unit, descriptor: descriptor, transport: transport)
        let step = max(1, (try? await query(Request.getRes, control, unit: unit, descriptor: descriptor, transport: transport)) ?? 1)
        let preset = try? await query(Request.getDef, control, unit: unit, descriptor: descriptor, transport: transport)
        return ValueLimits(min: low, max: high, step: step, defaultValue: preset.flatMap { (low...high).contains($0) ? $0 : nil })
    }

    // MARK: Helpers

    /// AE mode values (UVC spec): 1 manual, 2 auto, 4 shutter priority, 8 aperture priority.
    static let manualExposure = 1

    /// "Auto" prefers aperture priority (what most webcams offer), then full auto, then shutter priority.
    static func automaticExposureMode(supported modes: Int) -> Int? {
        [8, 2, 4].first { modes & $0 != 0 }
    }

    private func entityID(for control: UVCControl, in descriptor: UVCDescriptor) -> (id: UInt8, bitmap: UInt32)? {
        switch control.entity {
        case .processing: descriptor.processingUnitID.map { ($0, descriptor.processingControls) }
        case .camera: descriptor.cameraTerminalID.map { ($0, descriptor.cameraControls) }
        }
    }

    private func isSupported(_ control: UVCControl, in descriptor: UVCDescriptor) -> Bool {
        guard let entity = entityID(for: control, in: descriptor) else { return false }
        return entity.bitmap & (1 << UInt32(control.bit)) != 0
    }

    private func unitID(for control: UVCControl, in descriptor: UVCDescriptor) throws -> UInt8 {
        guard let entity = entityID(for: control, in: descriptor), isSupported(control, in: descriptor) else {
            throw DriverError.unsupportedCapability("\(control.id) (this camera does not support it)")
        }
        return entity.id
    }

    private func query(_ request: UInt8, _ control: UVCControl, unit: UInt8, descriptor: UVCDescriptor,
                       transport: any Transport) async throws -> Int {
        let bytes = try await transport.controlRead(requestType: Request.toHost, request: request,
                                                    value: UInt16(control.selector) << 8,
                                                    index: UInt16(unit) << 8 | UInt16(descriptor.videoControlInterface),
                                                    length: control.size)
        return Self.decode(bytes, size: control.size, signed: control.signed)
    }

    /// Little-endian. Some cameras answer with fewer bytes than asked for; missing bytes count as zero.
    static func decode(_ bytes: [UInt8], size: Int, signed: Bool) -> Int {
        var value = 0
        for (offset, byte) in bytes.prefix(size).enumerated() { value |= Int(byte) << (8 * offset) }
        if signed, size < MemoryLayout<Int>.size, value & (1 << (8 * size - 1)) != 0 { value -= 1 << (8 * size) }
        return value
    }

    static func encode(_ value: Int, size: Int) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
