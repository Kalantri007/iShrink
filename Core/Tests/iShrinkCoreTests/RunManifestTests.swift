import Testing
import Foundation
@testable import iShrinkCore

// iShrink Phase 1 plan, U7 "Bounded streaming pipeline" — RunManifest test
// scenarios.
//
// `InMemoryManifestStore` exercises the append/checkpoint/skip logic with
// no disk I/O at all (and exposes call counts so the O(1)-hot-path shape
// is directly assertable, not just inferred from end-to-end behavior).
// `FileManifestStore` tests below are the real, file-backed conformer's
// own round-trip proof — a fresh instance pointed at the same directory
// stands in for "the app relaunched".

@Test func recordCompletionMakesIsCompleteTrueImmediately() async throws {
    let store = InMemoryManifestStore()
    let manifest = RunManifest(store: store, checkpointInterval: 50)

    let beforeRecording = await manifest.isComplete("asset-1")
    #expect(!beforeRecording)

    try await manifest.recordCompletion(ManifestEntry(localIdentifier: "asset-1", outputPath: "/tmp/asset-1.heic"))

    let afterRecording = await manifest.isComplete("asset-1")
    #expect(afterRecording)
}

@Test func loadHydratesFromAPreExistingStoreSimulatingResumeAfterRelaunch() async throws {
    let seed = [
        ManifestEntry(localIdentifier: "asset-1", outputPath: "/tmp/asset-1.heic"),
        ManifestEntry(localIdentifier: "asset-2", outputPath: "/tmp/asset-2.heic"),
    ]
    let store = InMemoryManifestStore(seed: seed)
    let manifest = RunManifest(store: store)

    // A fresh actor that hasn't called load() yet doesn't know about prior
    // entries — proves `isComplete` isn't secretly reaching into the store
    // on every call.
    let beforeLoad = await manifest.isComplete("asset-1")
    #expect(!beforeLoad)

    try await manifest.load()

    let asset1Complete = await manifest.isComplete("asset-1")
    let asset2Complete = await manifest.isComplete("asset-2")
    let asset3Complete = await manifest.isComplete("asset-3")
    #expect(asset1Complete)
    #expect(asset2Complete)
    #expect(!asset3Complete)
}

@Test func hotPathIsAppendOnlyWithNoCheckpointBelowTheInterval() async throws {
    let store = InMemoryManifestStore()
    let manifest = RunManifest(store: store, checkpointInterval: 10)

    for index in 0..<9 {
        try await manifest.recordCompletion(
            ManifestEntry(localIdentifier: "asset-\(index)", outputPath: "/tmp/asset-\(index).heic")
        )
    }

    let appendCount = store.appendCallCount
    let checkpointCount = store.checkpointCallCount
    #expect(appendCount == 9)
    #expect(checkpointCount == 0)
}

@Test func periodicCheckpointFiresOnceTheIntervalIsReachedThenResets() async throws {
    let store = InMemoryManifestStore()
    let manifest = RunManifest(store: store, checkpointInterval: 5)

    for index in 0..<5 {
        try await manifest.recordCompletion(
            ManifestEntry(localIdentifier: "asset-\(index)", outputPath: "/tmp/asset-\(index).heic")
        )
    }
    let checkpointCountAtInterval = store.checkpointCallCount
    #expect(checkpointCountAtInterval == 1)

    try await manifest.recordCompletion(ManifestEntry(localIdentifier: "asset-5", outputPath: "/tmp/asset-5.heic"))
    let checkpointCountAfterOneMore = store.checkpointCallCount
    #expect(checkpointCountAfterOneMore == 1) // not due again yet
}

@Test func fileManifestStoreAppendPersistsAcrossFreshInstancesSimulatingRelaunch() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iShrinkRunManifestTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let firstLaunch = FileManifestStore(directory: dir)
    try firstLaunch.append(ManifestEntry(localIdentifier: "asset-1", outputPath: "/tmp/asset-1.heic"))
    try firstLaunch.append(ManifestEntry(localIdentifier: "asset-2", outputPath: "/tmp/asset-2.heic"))

    // A brand new store instance pointed at the same directory, with no
    // in-memory state carried over — models a relaunch.
    let secondLaunch = FileManifestStore(directory: dir)
    let loaded = try secondLaunch.loadAll()
    let loadedIdentifiers = Set(loaded.map(\.localIdentifier))
    #expect(loadedIdentifiers == Set(["asset-1", "asset-2"]))
}

@Test func fileManifestStoreCheckpointRollsUpTheLogAndStillPersists() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iShrinkRunManifestTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Append two entries, but checkpoint with only the first. If checkpoint()
    // failed to clear the log afterward, a fresh load would still find
    // "asset-2" sitting in the un-cleared log file even though the
    // checkpoint intentionally dropped it — that's the scenario a same-entry
    // round-trip can't distinguish from correct behavior.
    let firstLaunch = FileManifestStore(directory: dir)
    try firstLaunch.append(ManifestEntry(localIdentifier: "asset-1", outputPath: "/tmp/asset-1.heic"))
    try firstLaunch.append(ManifestEntry(localIdentifier: "asset-2", outputPath: "/tmp/asset-2.heic"))
    try firstLaunch.checkpoint([ManifestEntry(localIdentifier: "asset-1", outputPath: "/tmp/asset-1.heic")])

    let secondLaunch = FileManifestStore(directory: dir)
    let loaded = try secondLaunch.loadAll()
    let loadedIdentifiers = Set(loaded.map(\.localIdentifier))
    #expect(loadedIdentifiers == Set(["asset-1"]))
}
