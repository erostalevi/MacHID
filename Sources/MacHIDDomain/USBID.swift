/// Vendor/product pair identifying a USB (or Bluetooth HID) device. Text form: `046d:c092`.
public struct USBID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let vendor: UInt16
    public let product: UInt16

    public init(vendor: UInt16, product: UInt16) {
        self.vendor = vendor
        self.product = product
    }

    public init?(string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 4, parts[1].count == 4,
              let vendor = UInt16(parts[0], radix: 16),
              let product = UInt16(parts[1], radix: 16)
        else { return nil }
        self.init(vendor: vendor, product: product)
    }

    public var description: String {
        func hex(_ value: UInt16) -> String {
            let text = String(value, radix: 16)
            return String(repeating: "0", count: 4 - text.count) + text
        }
        return "\(hex(vendor)):\(hex(product))"
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = USBID(string: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid USB ID '\(text)', expected 'vvvv:pppp' in hex"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
