import Testing
import MacHIDDomain
@testable import MacHIDQuartz

@Suite struct SystemActionRunnerTests {
    @Test func mediaKeyPayloadMatchesSystemDefinedEvents() {
        #expect(SystemActionRunner.mediaData(type: 16, down: true) == 0x10_0A00)
        #expect(SystemActionRunner.mediaData(type: 16, down: false) == 0x10_0B00)
    }

    @Test func unknownIdIsRefusedWithoutPostingAnything() {
        #expect(SystemActionRunner().run(id: "does-not-exist") == false)
    }
}
