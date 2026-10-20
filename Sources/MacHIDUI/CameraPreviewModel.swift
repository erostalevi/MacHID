import AVFoundation
import AppKit
import Foundation
import SwiftUI

/// Authorization as the preview cares about it (decoupled from AVFoundation so it can be tested).
enum CameraAuthorization: Equatable, Sendable {
    case notDetermined, authorized, denied

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .notDetermined: self = .notDetermined
        case .denied, .restricted: self = .denied
        @unknown default: self = .denied
        }
    }
}

/// What the matcher needs from an AVCaptureDevice.
struct CameraCandidate: Equatable, Sendable {
    var name: String
    var modelID: String
    var uniqueID: String
}

enum CameraMatcher {
    /// Parses "046d:094c" (also "0x046d:0x094c", any case) into VID/PID.
    static func parseUSBID(_ text: String) -> (vendor: Int, product: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2 else { return nil }
        func hex(_ s: Substring) -> Int? {
            var t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("0x") { t.removeFirst(2) }
            return Int(t, radix: 16)
        }
        guard let v = hex(parts[0]), let p = hex(parts[1]) else { return nil }
        return (v, p)
    }

    /// Index of the best candidate: USB VID/PID in the model ID wins (exact, decimal like macOS reports it),
    /// then a case-insensitive name match. nil when nothing matches.
    static func match(_ candidates: [CameraCandidate], deviceName: String, usbID: String) -> Int? {
        if let (v, p) = parseUSBID(usbID) {
            let vendor = "VendorID_\(v)", product = "ProductID_\(p)"
            if let i = candidates.firstIndex(where: { hasToken($0.modelID, vendor) && hasToken($0.modelID, product) }) { return i }
        }
        let needle = deviceName.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        return candidates.firstIndex { $0.name.range(of: needle, options: .caseInsensitive) != nil }
    }

    /// Token match that does not let ProductID_2380 match ProductID_23801.
    private static func hasToken(_ text: String, _ token: String) -> Bool {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" }).contains { $0 == Substring(token) }
    }
}

/// Owns the AVCaptureSession. Everything touching it runs on one serial queue, never on main.
final class CameraSessionController: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.machid.camera-preview", qos: .userInitiated)
    private var configuredDeviceID: String?   // queue-confined

    enum Outcome: Sendable { case running, notFound, busy }

    func start(deviceName: String, usbID: String, completion: @escaping @Sendable (Outcome) -> Void) {
        queue.async { [self] in
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera],
                                                             mediaType: .video, position: .unspecified)
            let devices = discovery.devices
            let candidates = devices.map { CameraCandidate(name: $0.localizedName, modelID: $0.modelID, uniqueID: $0.uniqueID) }
            guard let index = CameraMatcher.match(candidates, deviceName: deviceName, usbID: usbID) else {
                completion(.notFound); return
            }
            let device = devices[index]
            if configuredDeviceID != device.uniqueID {
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { session.commitConfiguration(); completion(.busy); return }
                    session.addInput(input)
                } catch {
                    session.commitConfiguration(); completion(.busy); return
                }
                session.commitConfiguration()
                configuredDeviceID = device.uniqueID
            }
            if !session.isRunning { session.startRunning() }
            completion(session.isRunning ? .running : .busy)
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }
}

@MainActor
final class CameraPreviewModel: ObservableObject {
    enum State: Equatable { case needsPermission, denied, starting, live, notFound, busy }

    @Published private(set) var state: State
    let controller = CameraSessionController()
    private var deviceName = "", usbID = ""
    private var visible = false, appActive = true
    private var observers: [NSObjectProtocol] = []

    init() {
        switch CameraAuthorization(AVCaptureDevice.authorizationStatus(for: .video)) {
        case .authorized: state = .starting
        case .notDetermined: state = .needsPermission
        case .denied: state = .denied
        }
    }

    func appear(deviceName: String, usbID: String) {
        self.deviceName = deviceName; self.usbID = usbID
        visible = true
        if observers.isEmpty { observe() }
        refreshAuthorization()
        startIfPossible()
    }

    func disappear() {
        visible = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        controller.stop()
    }

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor in self?.refreshAuthorization(); self?.startIfPossible() }
        }
    }

    func retry() { state = .starting; startIfPossible() }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshAuthorization() {
        switch CameraAuthorization(AVCaptureDevice.authorizationStatus(for: .video)) {
        case .notDetermined: state = .needsPermission
        case .denied: state = .denied
        case .authorized: if state == .needsPermission || state == .denied { state = .starting }
        }
    }

    private func startIfPossible() {
        guard visible, appActive, CameraAuthorization(AVCaptureDevice.authorizationStatus(for: .video)) == .authorized else { return }
        controller.start(deviceName: deviceName, usbID: usbID) { [weak self] outcome in
            Task { @MainActor in
                guard let self, self.visible else { return }
                switch outcome {
                case .running: self.state = .live
                case .notFound: self.state = .notFound
                case .busy: self.state = .busy
                }
            }
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        func add(_ name: Notification.Name, _ handler: @escaping @MainActor (CameraPreviewModel) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { handler(self) } }
            })
        }
        add(NSApplication.didResignActiveNotification) { m in m.appActive = false; m.controller.stop() }
        add(NSApplication.didBecomeActiveNotification) { m in m.appActive = true; m.startIfPossible() }
        add(.AVCaptureSessionRuntimeError) { m in if m.visible { m.state = .busy } }
        add(.AVCaptureDeviceWasDisconnected) { m in if m.visible { m.state = .notFound; m.controller.stop() } }
        add(.AVCaptureDeviceWasConnected) { m in if m.visible, m.state == .notFound { m.retry() } }
    }
}
