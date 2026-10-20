import Foundation
import MacHIDDomain

/// Debug decorator (`--trace`): prints each report sent and received to stderr.
/// Payloads are device protocol bytes (no keystrokes), shown trimmed of trailing zeros.
struct TracingTransport: Transport {
    let inner: any Transport

    private func hex(_ bytes: [UInt8]) -> String {
        var trimmed = bytes
        while trimmed.count > 16, trimmed.last == 0 { trimmed.removeLast() }
        return trimmed.map { String(format: "%02x", $0) }.joined(separator: " ")
            + (trimmed.count < bytes.count ? " …(\(bytes.count) bytes)" : "")
    }

    private func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {
        log("→ feature id=\(reportID): \(hex(data))")
        try await inner.sendFeatureReport(reportID: reportID, data)
    }

    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] {
        let data = try await inner.getFeatureReport(reportID: reportID, length: length)
        log("← feature id=\(reportID): \(hex(data))")
        return data
    }

    func sendOutputReport(reportID: UInt8, _ data: [UInt8]) async throws {
        log("→ output id=\(reportID): \(hex(data))")
        try await inner.sendOutputReport(reportID: reportID, data)
    }

    func nextInputReport(timeout: Duration) async throws -> (reportID: UInt8, data: [UInt8]) {
        let report = try await inner.nextInputReport(timeout: timeout)
        log("← input id=\(report.reportID): \(hex(report.data))")
        return report
    }
}
