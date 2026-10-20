import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDSystem

@Test func lightingRepositoryDefaultsRoundTripAndBadFile() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("machid-light-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("lighting-scenes.json")
    let repo = FileLightingSceneRepository(url: url)
    #expect(await repo.load() == .defaults)

    var setup = LightingSetup.defaults
    setup.baseSceneID = "ember"
    setup.shiftScenes = [ShiftSceneRule(modeIDs: ["fn"], sceneID: "focus")]
    try await repo.save(setup)
    #expect(await repo.load() == setup)

    try Data("not json".utf8).write(to: url)
    #expect(await repo.load() == .defaults)
    try Data(#"{"schemaVersion":99,"baseSceneID":"a","scenes":[{"id":"a"}]}"#.utf8).write(to: url)
    #expect(await repo.load() == .defaults)
}
