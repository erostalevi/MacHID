import AVFoundation
import Testing
@testable import MacHIDUI

@Suite struct CameraPreviewTests {
    private let brio = CameraCandidate(name: "Brio 100", modelID: "UVC Camera VendorID_1133 ProductID_2380", uniqueID: "a")
    private let other = CameraCandidate(name: "FaceTime HD Camera", modelID: "Apple Camera", uniqueID: "b")

    @Test func parsesUSBID() {
        #expect(CameraMatcher.parseUSBID("046d:094c")?.vendor == 0x046d)
        #expect(CameraMatcher.parseUSBID("0x046D:0x094C")?.product == 0x094c)
        #expect(CameraMatcher.parseUSBID("nonsense") == nil)
    }

    @Test func matchesByModelID() {
        #expect(CameraMatcher.match([other, brio], deviceName: "Something else", usbID: "046d:094c") == 1)
    }

    @Test func matchesByNameWhenIDMissing() {
        #expect(CameraMatcher.match([other, brio], deviceName: "brio 100", usbID: "") == 1)
        #expect(CameraMatcher.match([other], deviceName: "Brio 100", usbID: "046d:094c") == nil)
    }

    @Test func productIDIsNotPrefixMatched() {
        let near = CameraCandidate(name: "X", modelID: "VendorID_1133 ProductID_23801", uniqueID: "c")
        #expect(CameraMatcher.match([near], deviceName: "", usbID: "046d:094c") == nil)
    }

    @Test func authorizationMapping() {
        #expect(CameraAuthorization(.authorized) == .authorized)
        #expect(CameraAuthorization(.notDetermined) == .notDetermined)
        #expect(CameraAuthorization(.denied) == .denied)
        #expect(CameraAuthorization(.restricted) == .denied)
    }
}
