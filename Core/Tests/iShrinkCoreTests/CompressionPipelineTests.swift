import Testing
import Foundation
@testable import iShrinkCore

// iShrink Phase 1 plan, U7 "Bounded streaming pipeline" — CompressionPipeline
// test scenarios (the plan's numbered list 1-12, minus the nil/nil
// FreeSpaceGuard case which is primarily covered in FreeSpaceGuardTests.swift
// and re-verified here at the pipeline level as scenario 6).
//
// `FakeCompressor` is this suite's "compress one item" seam (plan:
// "Drive with a FakeCompressor (deterministic success/fail/slow)"). It is
// an `actor` so its own bookkeeping (in-flight counter, attempt counts,
// which identifiers were asked to compress) can never race with the
// pipeline's concurrent calls into it — the same reasoning the plan gives
// for making `CompressionPipeline` itself an actor.
//
// Concurrency-bound determinism (plan: "a flaky concurrency test is worse
// than a slower, more deterministic one"): the "never exceeds the window"
// assertion (test 1) holds *structurally* — `CompressionPipeline` never
// admits more than `concurrencyWindow` items at once regardless of timing,
// so `maxInFlight <= window` can't flake under CI load. The pause/cancel
// tests (9a/9b) are the only genuinely concurrent scenarios (a "user
// action" arriving mid-run); they avoid a raw `sleep`-based race by having
// `FakeCompressor` expose `waitUntilStarted(atLeast:)`, an actor-backed
// rendezvous that resumes only once a specific number of items have
// actually begun compressing, so the test knows *for a fact* that the
// window is full before it requests pause/cancel — no guessing at timing.

// MARK: - FakeCompressor: the injected "compress one item" seam

actor FakeCompressor: ItemCompressing {
    enum Behavior {
        case succeed
        case alwaysFail(ItemFailureReason)
        case failOnceThenSucceed(ItemFailureReason)
    }

    private let behaviors: [String: Behavior]
    private let defaultBehavior: Behavior
    private let delayNanoseconds: UInt64
    private let outputDirectory: URL?

    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var attemptCounts: [String: Int] = [:]
    private(set) var compressedIdentifiers: [String] = []

    private var startedCount = 0
    private var waiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(
        behaviors: [String: Behavior] = [:],
        defaultBehavior: Behavior = .succeed,
        delayNanoseconds: UInt64 = 0,
        outputDirectory: URL? = nil
    ) {
        self.behaviors = behaviors
        self.defaultBehavior = defaultBehavior
        self.delayNanoseconds = delayNanoseconds
        self.outputDirectory = outputDirectory
    }

    /// Resumes once at least `threshold` `compress(_:)` calls have begun —
    /// the deterministic rendezvous the pause/cancel tests use instead of a
    /// raw sleep.
    func waitUntilStarted(atLeast threshold: Int) async {
        if startedCount >= threshold { return }
        await withCheckedContinuation { continuation in
            waiters.append((threshold, continuation))
        }
    }

    func compress(_ item: PipelineItem) async -> ItemCompressionOutcome {
        startedCount += 1
        resumeReadyWaiters()
        compressedIdentifiers.append(item.localIdentifier)

        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        inFlight -= 1

        let attempt = (attemptCounts[item.localIdentifier] ?? 0) + 1
        attemptCounts[item.localIdentifier] = attempt

        let behavior = behaviors[item.localIdentifier] ?? defaultBehavior
        switch behavior {
        case .succeed:
            return .success(writeOutput(for: item))
        case .alwaysFail(let reason):
            return .failure(reason)
        case .failOnceThenSucceed(let reason):
            return attempt == 1 ? .failure(reason) : .success(writeOutput(for: item))
        }
    }

    private func writeOutput(for item: PipelineItem) -> PipelineItemSuccess {
        guard let outputDirectory else {
            return PipelineItemSuccess(outputURL: item.sourceURL)
        }
        let outputURL = outputDirectory.appendingPathComponent("\(item.localIdentifier).heic")
        // `.atomic` overwrites unconditionally — this is what proves the
        // "stray file gets overwritten, not skipped" scenario (test 11):
        // the fake always writes here regardless of what (if anything)
        // already exists at the path.
        try? Data("compressed-output-for-\(item.localIdentifier)".utf8).write(to: outputURL, options: .atomic)
        return PipelineItemSuccess(outputURL: outputURL)
    }

    private func resumeReadyWaiters() {
        let ready = waiters.filter { startedCount >= $0.threshold }
        waiters.removeAll { startedCount >= $0.threshold }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

// MARK: - Boundary-check fakes (all call-count-driven -- deterministic, no timing)

struct AlwaysOkFreeSpaceReader: FreeSpaceReading {
    func importantUsageAvailableCapacity(for url: URL) -> Int64? { 1_000_000_000_000 }
    func availableCapacity(for url: URL) -> Int64? { 1_000_000_000_000 }
}

/// Reports OK for the first `lowAfterCall` calls, then low forever after —
/// driven purely by call count, not wall-clock time, so tests using it
/// never flake under CI load.
final class CountingFreeSpaceReader: FreeSpaceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let lowAfterCall: Int

    init(lowAfterCall: Int) {
        self.lowAfterCall = lowAfterCall
    }

    func importantUsageAvailableCapacity(for url: URL) -> Int64? {
        lock.lock()
        callCount += 1
        let count = callCount
        lock.unlock()
        return count > lowAfterCall ? 1 : 1_000_000_000_000
    }

    func availableCapacity(for url: URL) -> Int64? { nil }
}

/// Reports authorized for the first `revokeAfterCall` polls, then revoked.
final class CountingAuthorizationPolling: AuthorizationPolling, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let revokeAfterCall: Int

    init(revokeAfterCall: Int) {
        self.revokeAfterCall = revokeAfterCall
    }

    func poll() async -> AuthPollResult {
        let count = nextCallCount()
        if count > revokeAfterCall {
            return .revoked(previous: .authorized, current: .denied)
        }
        return .unchanged(.authorized)
    }

    /// Plain synchronous helper so the `NSLock` lock/unlock pair never
    /// appears textually inside `poll()`'s `async` body (Swift flags direct
    /// `NSLock` use in an `async` context as a Swift 6 error-to-be).
    private func nextCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return callCount
    }
}

/// Reports available for the first `unavailableAfterCall` checks, then
/// unavailable — the pipeline's injected seam for "destination volume
/// unmounted mid-run".
final class CountingDestinationAvailability: DestinationAvailabilityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let unavailableAfterCall: Int

    init(unavailableAfterCall: Int) {
        self.unavailableAfterCall = unavailableAfterCall
    }

    func isAvailable() -> Bool {
        lock.lock()
        callCount += 1
        let count = callCount
        lock.unlock()
        return count <= unavailableAfterCall
    }
}

private func makeItems(_ count: Int, prefix: String = "asset") -> [PipelineItem] {
    (0..<count).map {
        PipelineItem(localIdentifier: "\(prefix)-\($0)", sourceURL: URL(fileURLWithPath: "/fake/\(prefix)-\($0).jpg"))
    }
}

// MARK: - 1. Happy path: bounded concurrency

@Test func happyPath100ItemsWindow4AllCompleteNeverExceedingTheConcurrencyBound() async throws {
    let compressor = FakeCompressor(delayNanoseconds: 5_000_000)
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 0, reader: AlwaysOkFreeSpaceReader()),
        concurrencyWindow: 4
    )

    let result = await pipeline.run(items: makeItems(100))

    #expect(result.outcome == .completed)
    #expect(result.succeededCount == 100)
    #expect(result.failures.isEmpty)
    let observedMax = await compressor.maxInFlight
    #expect(observedMax <= 4)
}

// MARK: - 2. Error path: an item that always fails

@Test func itemThatAlwaysFailsIsLoggedInputUntouchedBatchStillFinishesTheRest() async throws {
    let compressor = FakeCompressor(behaviors: ["asset-42": .alwaysFail(.unsupportedFormat)])
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 0, reader: AlwaysOkFreeSpaceReader()),
        concurrencyWindow: 4
    )

    let result = await pipeline.run(items: makeItems(100))

    #expect(result.outcome == .completed)
    #expect(result.succeededCount == 99)
    #expect(result.failures.count == 1)
    let failure = result.failures[0]
    #expect(failure.localIdentifier == "asset-42")
    #expect(!failure.wasRetried)
}

// MARK: - 3. Error path: transient failure, retried once, ends successful

@Test func itemThatFailsOnceThenSucceedsGetsExactlyOneRetryAndEndsSuccessful() async throws {
    let compressor = FakeCompressor(behaviors: ["asset-7": .failOnceThenSucceed(.temporaryIOError)])
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 0, reader: AlwaysOkFreeSpaceReader()),
        concurrencyWindow: 4
    )

    let items = makeItems(20)
    let result = await pipeline.run(items: items)

    #expect(result.outcome == .completed)
    #expect(result.succeededCount == items.count)
    #expect(result.failures.isEmpty)
    let attempts = await compressor.attemptCounts["asset-7"]
    #expect(attempts == 2)
}

// MARK: - 4. Error path: permanent failure, not retried

@Test func permanentCorruptInputFailureIsNotRetriedLoggedOnceBatchContinues() async throws {
    let compressor = FakeCompressor(behaviors: ["asset-3": .alwaysFail(.corruptInput)])
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 0, reader: AlwaysOkFreeSpaceReader()),
        concurrencyWindow: 4
    )

    let items = makeItems(20)
    let result = await pipeline.run(items: items)

    #expect(result.succeededCount == items.count - 1)
    #expect(result.failures.count == 1)
    let failure = result.failures[0]
    #expect(failure.errorCode == ItemFailureReason.corruptInput.rawValue)
    #expect(!failure.wasRetried)
    let attempts = await compressor.attemptCounts["asset-3"]
    #expect(attempts == 1)
}

// MARK: - 5. FreeSpaceGuard low mid-run: pause, then resume when recovered

@Test func lowDiskSpaceMidRunPausesThenResumesOnceSpaceRecovers() async throws {
    let compressor = FakeCompressor()
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let tempStore = TempStore(directory: tempDir)

    let lowingReader = CountingFreeSpaceReader(lowAfterCall: 3)
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: tempStore,
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 1_000, reader: lowingReader),
        concurrencyWindow: 2
    )

    let items = makeItems(10)
    let firstResult = await pipeline.run(items: items)

    #expect(firstResult.outcome == .paused(.lowDiskSpace))
    let firstSucceeded = firstResult.succeededCount
    #expect(firstSucceeded > 0)
    #expect(firstSucceeded < items.count)

    // Space "recovers": a fresh pipeline instance (simulating resuming the
    // run) sharing the same manifest/tempStore/compressor, with a reader
    // that always reports plenty of space.
    let resumedPipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: tempStore,
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 1_000, reader: AlwaysOkFreeSpaceReader()),
        concurrencyWindow: 2
    )
    let secondResult = await resumedPipeline.run(items: items)

    #expect(secondResult.outcome == .completed)
    let allCompressed = await compressor.compressedIdentifiers
    let uniqueCompressed = Set(allCompressed)
    #expect(uniqueCompressed.count == items.count)
    // No item was ever re-compressed once recorded complete (no item was
    // interrupted mid-write to require a redo).
    #expect(allCompressed.count == items.count)
}

// MARK: - 6. Nil/nil free-space capacity: blocking setup error, no item runs

@Test func cannotMonitorFreeSpaceSurfacesABlockingSetupErrorBeforeAnyItemRuns() async throws {
    let compressor = FakeCompressor()
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let unmonitorableReader = FakeFreeSpaceReader(importantUsage: nil, fallback: nil)
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 1_000, reader: unmonitorableReader),
        concurrencyWindow: 4
    )

    let result = await pipeline.run(items: makeItems(5))

    #expect(result.outcome == .setupError(.cannotMonitorFreeSpace))
    #expect(result.succeededCount == 0)
    let attempted = await compressor.compressedIdentifiers
    #expect(attempted.isEmpty)
}

// MARK: - 7. Orphan temp file swept before any new work starts

@Test func orphanTempFileIsSweptBeforeAnyItemProcessingBegins() async throws {
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try Data("leftover-with-unredacted-gps-exif".utf8).write(to: tempDir.appendingPathComponent("orphan.heic"))

    let compressor = FakeCompressor()
    let manifest = RunManifest(store: InMemoryManifestStore())
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 0, reader: AlwaysOkFreeSpaceReader()),
        concurrencyWindow: 2
    )

    let result = await pipeline.run(items: makeItems(3))

    #expect(result.outcome == .completed)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    #expect(!remaining.contains("orphan.heic"))
}

// MARK: - 8. Destination unavailable mid-run: structural, not per-item

@Test func destinationUnavailableMidRunEntersBlockingStateNotPerItemIsolation() async throws {
    let compressor = FakeCompressor()
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 0, reader: AlwaysOkFreeSpaceReader()),
        destinationAvailability: CountingDestinationAvailability(unavailableAfterCall: 2),
        concurrencyWindow: 2
    )

    let items = makeItems(10)
    let result = await pipeline.run(items: items)

    #expect(result.outcome == .paused(.destinationUnavailable))
    // Structural, whole-run stop -- proven by there being *no* per-item
    // failure log entries at all, not by any single asset's encode having
    // been attempted and failed.
    #expect(result.failures.isEmpty)
    #expect(result.succeededCount < items.count)
}

// MARK: - 9a. Pause: in-flight items finish, no new ones start

@Test func pauseLetsInFlightItemsFinishButAdmitsNoNewOnes() async throws {
    let compressor = FakeCompressor(delayNanoseconds: 40_000_000)
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 0, reader: AlwaysOkFreeSpaceReader()),
        concurrencyWindow: 4
    )

    let runTask = Task { await pipeline.run(items: makeItems(50)) }

    // Deterministic rendezvous: wait until exactly the window's worth of
    // items have actually begun, so pause is requested only once we know
    // for a fact the window is full -- no guessing at timing.
    await compressor.waitUntilStarted(atLeast: 4)
    await pipeline.requestPause()

    let result = await runTask.value

    #expect(result.outcome == .paused(.userRequested))
    #expect(result.succeededCount == 4)
    let totalAttempts = await compressor.compressedIdentifiers.count
    #expect(totalAttempts == 4)
}

// MARK: - 9b. Cancel: same draining behavior, then stops

@Test func cancelLetsInFlightItemsFinishThenStopsWithoutAdmittingMore() async throws {
    let compressor = FakeCompressor(delayNanoseconds: 40_000_000)
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 0, reader: AlwaysOkFreeSpaceReader()),
        concurrencyWindow: 4
    )

    let runTask = Task { await pipeline.run(items: makeItems(50)) }

    await compressor.waitUntilStarted(atLeast: 4)
    await pipeline.requestCancel()

    let result = await runTask.value

    #expect(result.outcome == .cancelled)
    #expect(result.succeededCount == 4)
    let totalAttempts = await compressor.compressedIdentifiers.count
    #expect(totalAttempts == 4)
}

// MARK: - 10. Interrupted run leaves a manifest; re-run skips completed items

@Test func interruptedRunResumesAndSkipsAlreadyCompletedItemsByLocalIdentifier() async throws {
    let compressor = FakeCompressor(delayNanoseconds: 20_000_000)
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 0, reader: AlwaysOkFreeSpaceReader()),
        concurrencyWindow: 4
    )

    let items = makeItems(20)

    let firstRunTask = Task { await pipeline.run(items: items) }
    await compressor.waitUntilStarted(atLeast: 4)
    await pipeline.requestCancel()
    let firstResult = await firstRunTask.value

    #expect(firstResult.outcome == .cancelled)
    let firstSucceeded = firstResult.succeededCount
    #expect(firstSucceeded > 0)
    #expect(firstSucceeded < items.count)

    // Re-run on the same pipeline/manifest with the *full* item list --
    // already-completed items must be skipped (by localIdentifier, per the
    // manifest), not recompressed.
    let secondResult = await pipeline.run(items: items)

    #expect(secondResult.outcome == .completed)
    let allCompressed = await compressor.compressedIdentifiers
    let uniqueIdentifiers = Set(allCompressed)
    #expect(uniqueIdentifiers.count == items.count)
    #expect(allCompressed.count == items.count) // each item compressed exactly once, total
}

// MARK: - 11. Stray output not in the manifest is overwritten, not skipped

@Test func strayOutputFileNotRecordedInManifestIsOverwrittenNotSkipped() async throws {
    let outputDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: outputDir) }
    let strayURL = outputDir.appendingPathComponent("stray-item.heic")
    try Data("OLD-TRUNCATED-LEFTOVER-FROM-A-PRIOR-RUN".utf8).write(to: strayURL)

    let compressor = FakeCompressor(outputDirectory: outputDir)
    // "stray-item" is deliberately NOT recorded complete in this manifest.
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 0, reader: AlwaysOkFreeSpaceReader()),
        concurrencyWindow: 2
    )

    let items = [PipelineItem(localIdentifier: "stray-item", sourceURL: URL(fileURLWithPath: "/fake/stray-item.jpg"))]
    let result = await pipeline.run(items: items)

    #expect(result.outcome == .completed)
    #expect(result.succeededCount == 1)

    let compressedIdentifiers = await compressor.compressedIdentifiers
    #expect(compressedIdentifiers.contains("stray-item")) // processed, not skipped for existing at path

    let finalContent = try String(contentsOf: strayURL, encoding: .utf8)
    #expect(finalContent == "compressed-output-for-stray-item")
}

// MARK: - 12. Authorization revoked mid-run: pause at the next boundary

@Test func authorizationRevokedPausesAtTheNextBoundary() async throws {
    let compressor = FakeCompressor()
    let manifest = RunManifest(store: InMemoryManifestStore())
    let tempDir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let pipeline = CompressionPipeline(
        compressor: compressor,
        manifest: manifest,
        tempStore: TempStore(directory: tempDir),
        freeSpaceGuard: FreeSpaceGuard(destinationURL: tempDir, thresholdBytes: 0, reader: AlwaysOkFreeSpaceReader()),
        authorizationPolling: CountingAuthorizationPolling(revokeAfterCall: 2),
        concurrencyWindow: 2
    )

    let items = makeItems(10)
    let result = await pipeline.run(items: items)

    #expect(result.outcome == .paused(.authorizationRevoked))
    let succeeded = result.succeededCount
    #expect(succeeded > 0)
    #expect(succeeded < items.count)
}
