import Foundation
import Testing
@testable import MacHIDUI

@Suite struct UpdaterConfigurationTests {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    @Test func needsAValidKeyAndAnHTTPSFeed() {
        #expect(UpdaterConfiguration.isConfigured(infoDictionary: ["SUPublicEDKey": key, "SUFeedURL": "https://example.com/appcast.xml"]))
        #expect(!UpdaterConfiguration.isConfigured(infoDictionary: nil))
        #expect(!UpdaterConfiguration.isConfigured(infoDictionary: ["SUFeedURL": "https://example.com/appcast.xml"]))                    // no key
        #expect(!UpdaterConfiguration.isConfigured(infoDictionary: ["SUPublicEDKey": "", "SUFeedURL": "https://example.com/a.xml"]))
        #expect(!UpdaterConfiguration.isConfigured(infoDictionary: ["SUPublicEDKey": "short", "SUFeedURL": "https://example.com/a.xml"]))
        #expect(!UpdaterConfiguration.isConfigured(infoDictionary: ["SUPublicEDKey": key, "SUFeedURL": "http://example.com/appcast.xml"])) // not https
        #expect(!UpdaterConfiguration.isConfigured(infoDictionary: ["SUPublicEDKey": key]))
    }

    @MainActor @Test func aBuildWithoutTheKeyDoesNotStartUpdating() {
        let model = UpdaterModel(infoDictionary: [:])
        #expect(!model.isAvailable && !model.canCheck && !model.automaticChecks)
        model.checkForUpdates()                      // harmless
    }
}
