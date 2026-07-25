import Foundation

// iShrink Phase 1 plan, U7 "Bounded streaming pipeline".
//
// Drives many assets through a compressor with a bounded concurrency
// window ("sliding window", Context & Research "Streaming/concurrency"),
// a live free-space guardrail, per-item failure isolation with exactly one
// retry for transient errors, immediate temp cleanup, a resume manifest,
// and cooperative pause/cancel that never interrupts an item mid-flight
// (R9, R10, R11).
//
// `CompressionPipeline` is driven against the `ItemCompressing` protocol,
// not a real `ImageCompressor` directly (plan: "drive the pipeline with an
// injected 'compress one item' closure/protocol ... rather than requiring
// a real ImageCompressor, so concurrency/retry/pause/resume are all
// testable without real encoding"). A real conformer wiring this to
// `ImageCompressor` + `TempStore` per-item paths is the App layer's job
// (U8+); this unit only needs the seam and a deterministic fake to prove
// the pipeline mechanics.
//
// Shared state (running totals, failure log, cooperative pause/cancel
// flags) lives on this type itself, which is declared `actor` so
// concurrent tasks touching it can never race (Context & Research:
// "serialize shared state ... in an actor").

// MARK: - Item-level seam ("compress one item")

/// One asset queued for compression: just enough for the pipeline and a
/// fake/real compressor to do their jobs, independent of PhotoKit.
public struct PipelineItem: Sendable, Equatable, Hashable {
    public let localIdentifier: String
    public let sourceURL: URL

    public init(localIdentifier: String, sourceURL: URL) {
        self.localIdentifier = localIdentifier
        self.sourceURL = sourceURL
    }
}

/// A successfully compressed item's result, as far as the pipeline needs
/// to know (where the output landed).
public struct PipelineItemSuccess: Sendable, Equatable {
    public let outputURL: URL

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }
}

/// Why one item's compression attempt failed, restricted to a **bounded**
/// set so the pipeline can classify transient-vs-permanent without any
/// stringly-typed guessing (Key Technical Decisions: "Transient-vs-
/// permanent failure classification? Bounded transient set ... gets one
/// retry; permanent errors are not retried").
///
/// Deliberately holds no message strings, paths beyond what the pipeline
/// already has, or any metadata payload — the failure log built from this
/// (`PipelineFailureLogEntry`) carries only identifier/filename/this
/// reason's raw value, never raw EXIF/GPS (plan: "Failure-log entries
/// carry identifier/filename/error-code only").
public enum ItemFailureReason: String, Sendable, Equatable {
    /// Disk-pressure error (`ENOSPC`/`EDQUOT`) — transient.
    case diskPressure
    /// The source (or a lock file) was briefly locked by another process —
    /// transient.
    case fileTemporarilyLocked
    /// A transient I/O error unrelated to disk pressure or locking —
    /// transient.
    case temporaryIOError
    /// The source file itself is corrupt/unreadable — permanent.
    case corruptInput
    /// The source's format isn't one this pipeline can encode — permanent.
    case unsupportedFormat
    /// The file was readable but the encoder still reported failure
    /// (`Finalize == false` on a readable file) — permanent.
    case encodeFailedOnReadableFile

    /// Whether this reason is in the bounded transient set (gets one
    /// retry) or is permanent (never retried).
    public var isTransient: Bool {
        switch self {
        case .diskPressure, .fileTemporarilyLocked, .temporaryIOError:
            return true
        case .corruptInput, .unsupportedFormat, .encodeFailedOnReadableFile:
            return false
        }
    }
}

/// One `ItemCompressing.compress(_:)` call's result.
public enum ItemCompressionOutcome: Sendable, Equatable {
    case success(PipelineItemSuccess)
    case failure(ItemFailureReason)
}

/// The "compress one item" seam the pipeline is driven against. A real
/// conformer (App layer, later) wraps `ImageCompressor`; tests drive the
/// pipeline with a deterministic fake (`FakeCompressor` in
/// `CompressionPipelineTests.swift`) that can script success, always-fail,
/// fail-once-then-succeed, and track observed concurrency — all without
/// touching ImageIO or the filesystem.
public protocol ItemCompressing: Sendable {
    func compress(_ item: PipelineItem) async -> ItemCompressionOutcome
}

// MARK: - Authorization polling seam

/// The pipeline's view of `PhotoAuthorization.poll()` — kept as its own
/// tiny protocol (rather than depending on the concrete `@MainActor`
/// `PhotoAuthorization` type directly) so a fake can simulate revocation at
/// a specific point in a run without needing a real `PHPhotoLibrary`
/// authorization source or a main-actor hop in tests.
public protocol AuthorizationPolling: Sendable {
    func poll() async -> AuthPollResult
}

/// Trivial "always authorized" conformer — the sensible default for
/// callers/tests that don't care about the authorization dimension at all.
public struct AlwaysAuthorizedPolling: AuthorizationPolling {
    public init() {}
    public func poll() async -> AuthPollResult { .unchanged(.authorized) }
}

// MARK: - Destination-availability seam

/// Whether the destination volume is currently mounted/writable. Checked
/// at admission boundaries so a volume going away mid-run (unmounted
/// external disk, disconnected network share) is caught structurally,
/// distinct from any single item's own encode failure — see
/// `PauseReason.destinationUnavailable` below.
public protocol DestinationAvailabilityChecking: Sendable {
    func isAvailable() -> Bool
}

/// Trivial "always available" conformer — the sensible default for
/// callers/tests that don't care about this dimension.
public struct AlwaysAvailableDestination: DestinationAvailabilityChecking {
    public init() {}
    public func isAvailable() -> Bool { true }
}

// MARK: - Pause / outcome model

/// Why the pipeline stopped short of processing every item, distinct from
/// a per-item failure. Exactly the four cases the plan calls out (Context
/// & Research: "Typed pause reasons").
///
/// `.destinationUnavailable` is a *structural*, whole-run condition (the
/// destination volume itself went away), never raised by a single item's
/// encode failure — that distinction ("Structural (non-per-item)
/// failures ... transition the whole run to a blocking error state,
/// distinct from per-item isolation") is what separates it from
/// `failureLog`/`PipelineFailureLogEntry` entries, which only ever record
/// per-asset encode failures.
public enum PauseReason: Sendable, Equatable {
    case userRequested
    case lowDiskSpace
    case authorizationRevoked
    case destinationUnavailable
}

/// A setup-time condition that blocks the run before it can meaningfully
/// start (or continue) at all — distinct from a resumable `PauseReason`
/// because there is nothing about "waiting" that fixes it; the caller must
/// fix the underlying setup problem (e.g. supply a volume this OS can
/// monitor) before trying again.
public enum PipelineSetupError: Sendable, Equatable {
    /// Neither `volumeAvailableCapacityForImportantUsage` nor
    /// `volumeAvailableCapacity` produced a value for the destination
    /// volume — `FreeSpaceGuard` refuses to silently proceed without any
    /// guardrail at all (Context & Research nil-capacity policy).
    case cannotMonitorFreeSpace
}

/// How a `run(items:)` call ended.
public enum PipelineOutcome: Sendable, Equatable {
    case completed
    case paused(PauseReason)
    case cancelled
    case setupError(PipelineSetupError)
}

/// One per-item failure, safe to log or export: identifier, filename, and
/// an error code only — never a raw EXIF/GPS payload (plan: "Failure-log
/// entries carry identifier/filename/error-code only — never raw
/// EXIF/GPS payloads").
public struct PipelineFailureLogEntry: Sendable, Equatable {
    public let localIdentifier: String
    public let filename: String
    public let errorCode: String
    public let wasRetried: Bool
}

/// What one `run(items:)` call produced.
public struct PipelineRunResult: Sendable, Equatable {
    public let outcome: PipelineOutcome
    public let succeededCount: Int
    public let failures: [PipelineFailureLogEntry]
}

// MARK: - The pipeline

/// Bounded, streaming, resumable compression pipeline (U7). An `actor` so
/// the many tasks it spawns per batch can safely share `failureLog`,
/// `succeededIdentifiers`, and the cooperative pause/cancel flags without a
/// separate lock.
public actor CompressionPipeline {
    private let compressor: ItemCompressing
    private let manifest: RunManifest
    private let tempStore: TempStore
    private let freeSpaceGuard: FreeSpaceGuard
    private let authorizationPolling: AuthorizationPolling
    private let destinationAvailability: DestinationAvailabilityChecking
    private let concurrencyWindow: Int

    private var pauseRequested = false
    private var cancelRequested = false

    /// Every per-item failure recorded so far, across every `run(items:)`
    /// call this instance has made (i.e. it accumulates across a
    /// pause-then-resume sequence on the same instance). At most one entry
    /// per `localIdentifier` — see `recordFailure`.
    public private(set) var failureLog: [PipelineFailureLogEntry] = []

    /// Every `localIdentifier` this instance has itself completed
    /// successfully, across every `run(items:)` call.
    public private(set) var succeededIdentifiers: Set<String> = []

    /// Every `localIdentifier` that has already exhausted its attempt(s)
    /// (a permanent failure, or a transient failure whose one retry also
    /// failed) on this instance. The manifest only ever records successes,
    /// so without this, a resumed run would re-admit and re-attempt an
    /// already-known-bad item on every pause/resume cycle and pile up
    /// duplicate `failureLog` entries for it.
    private var failedIdentifiers: Set<String> = []

    public init(
        compressor: ItemCompressing,
        manifest: RunManifest,
        tempStore: TempStore,
        freeSpaceGuard: FreeSpaceGuard,
        authorizationPolling: AuthorizationPolling = AlwaysAuthorizedPolling(),
        destinationAvailability: DestinationAvailabilityChecking = AlwaysAvailableDestination(),
        concurrencyWindow: Int
    ) {
        self.compressor = compressor
        self.manifest = manifest
        self.tempStore = tempStore
        self.freeSpaceGuard = freeSpaceGuard
        self.authorizationPolling = authorizationPolling
        self.destinationAvailability = destinationAvailability
        self.concurrencyWindow = max(1, concurrencyWindow)
    }

    /// `activeProcessorCount / 2`, floored at 1 — the plan's starting-point
    /// sizing for a real run. Real callers (the App layer) use this as
    /// `concurrencyWindow`'s default; **tests must pass a fixed window
    /// explicitly** so the concurrency-bound assertion isn't tied to
    /// whatever machine happens to run the suite.
    public static func defaultConcurrencyWindow(
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int {
        max(1, processorCount / 2)
    }

    /// Cooperative pause request: in-flight items finish; no new item is
    /// admitted after this. Checked at the top of each admission, same as
    /// `requestCancel()`.
    public func requestPause() {
        pauseRequested = true
    }

    /// Cooperative cancel request: same draining behavior as pause, but
    /// the run reports `.cancelled` instead of `.paused` once drained.
    public func requestCancel() {
        cancelRequested = true
    }

    /// Runs `items` through the compressor.
    ///
    /// - Skips any item already recorded complete in the manifest (resume
    ///   support — never based on whether a file exists at an output path;
    ///   see `RunManifest`).
    /// - Admits at most `concurrencyWindow` items concurrently, refilling
    ///   the window as each finishes (a true sliding window, not
    ///   fixed-size waves), so the observed "currently in flight" count
    ///   never exceeds `concurrencyWindow`.
    /// - Before admitting each new item, checks (in order) cancel, pause,
    ///   authorization revocation, destination availability, and free
    ///   space. The first one that fires ends admission; every item
    ///   already admitted is still allowed to finish (never interrupted
    ///   mid-item) before this call returns.
    /// - A transient-classified per-item failure gets exactly one retry;
    ///   a permanent one does not. Either way, one item's failure never
    ///   halts the batch — it's recorded in `failureLog` and the next item
    ///   proceeds.
    ///
    /// - Parameters:
    ///   - onItemStarted/onItemFinished: optional, additive progress hooks
    ///     (U9's `CompressionRunView` needs "items done/total, current
    ///     file" — mirrors `LibraryScanner`'s own `onRecord`/`onProgress`
    ///     callback shape, U3). Both default to `nil` so every pre-U9 call
    ///     site and test keeps compiling unchanged; neither callback
    ///     carries byte-size/codec data — that's the report accumulator's
    ///     job (a real `ItemCompressing` conformer records it directly at
    ///     success time, since only it has a `CompressionResult` to read
    ///     from), not this pipeline's.
    public func run(
        items: [PipelineItem],
        onItemStarted: (@Sendable (PipelineItem) -> Void)? = nil,
        onItemFinished: (@Sendable (PipelineItem, ItemCompressionOutcome) -> Void)? = nil
    ) async -> PipelineRunResult {
        // A Cancel confirmed while this instance was paused (between run()
        // calls, with no admission loop running to consume the flag) must
        // still be honored here — resetting it unconditionally below would
        // silently discard the user's confirmed cancellation and resume as
        // if it never happened.
        if cancelRequested {
            cancelRequested = false
            return PipelineRunResult(
                outcome: .cancelled,
                succeededCount: succeededIdentifiers.count,
                failures: failureLog
            )
        }
        pauseRequested = false

        _ = try? tempStore.sweepOrphans()
        try? await manifest.load()

        if case .cannotMonitor = freeSpaceGuard.checkStatus() {
            return PipelineRunResult(
                outcome: .setupError(.cannotMonitorFreeSpace),
                succeededCount: succeededIdentifiers.count,
                failures: failureLog
            )
        }

        var queue: [PipelineItem] = []
        for item in items {
            if await manifest.isComplete(item.localIdentifier) {
                continue
            }
            if failedIdentifiers.contains(item.localIdentifier) {
                continue
            }
            queue.append(item)
        }

        var cursor = 0
        var outcome: PipelineOutcome = .completed
        var stopAdmitting = false

        func evaluateBoundary() async -> PipelineOutcome? {
            if self.cancelRequested {
                // Consume the flag now, since it has just been acted upon —
                // otherwise it would still read `true` at the top of the
                // *next* `run()` call and be mistaken for a fresh cancel
                // requested while idle (see that check above), incorrectly
                // short-circuiting a legitimate subsequent run.
                self.cancelRequested = false
                return .cancelled
            }
            if self.pauseRequested {
                return .paused(.userRequested)
            }
            if case .revoked = await self.authorizationPolling.poll() {
                return .paused(.authorizationRevoked)
            }
            if !self.destinationAvailability.isAvailable() {
                return .paused(.destinationUnavailable)
            }
            switch self.freeSpaceGuard.checkStatus() {
            case .cannotMonitor:
                return .setupError(.cannotMonitorFreeSpace)
            case .low:
                return .paused(.lowDiskSpace)
            case .ok:
                return nil
            }
        }

        await withTaskGroup(of: Void.self) { group in
            func admitNext() async -> Bool {
                guard !stopAdmitting, cursor < queue.count else { return false }
                if let stop = await evaluateBoundary() {
                    outcome = stop
                    stopAdmitting = true
                    return false
                }
                let item = queue[cursor]
                cursor += 1
                group.addTask {
                    await self.processItem(item, onItemStarted: onItemStarted, onItemFinished: onItemFinished)
                }
                return true
            }

            var active = 0
            while active < self.concurrencyWindow {
                guard await admitNext() else { break }
                active += 1
            }

            while active > 0 {
                await group.next()
                active -= 1
                if await admitNext() {
                    active += 1
                }
            }
        }

        // Always leave the manifest durably checkpointed at the end of a
        // run call, regardless of how it ended, rather than only relying
        // on whatever periodic checkpoint happened to fall last.
        try? await manifest.checkpointNow()

        return PipelineRunResult(
            outcome: outcome,
            succeededCount: succeededIdentifiers.count,
            failures: failureLog
        )
    }

    // MARK: - Per-item processing

    private func processItem(
        _ item: PipelineItem,
        onItemStarted: (@Sendable (PipelineItem) -> Void)?,
        onItemFinished: (@Sendable (PipelineItem, ItemCompressionOutcome) -> Void)?
    ) async {
        onItemStarted?(item)

        let finalOutcome: ItemCompressionOutcome
        let firstAttempt = await compressor.compress(item)
        switch firstAttempt {
        case .success(let success):
            await recordSuccess(item: item, success: success)
            finalOutcome = firstAttempt
        case .failure(let reason):
            if reason.isTransient {
                let retryAttempt = await compressor.compress(item)
                switch retryAttempt {
                case .success(let success):
                    await recordSuccess(item: item, success: success)
                    finalOutcome = retryAttempt
                case .failure(let retryReason):
                    recordFailure(item: item, reason: retryReason, wasRetried: true)
                    finalOutcome = .failure(retryReason)
                }
            } else {
                recordFailure(item: item, reason: reason, wasRetried: false)
                finalOutcome = firstAttempt
            }
        }
        tempStore.cleanupAfterItem(at: tempStore.tempURL(for: item.localIdentifier))
        onItemFinished?(item, finalOutcome)
    }

    private func recordSuccess(item: PipelineItem, success: PipelineItemSuccess) async {
        succeededIdentifiers.insert(item.localIdentifier)
        let entry = ManifestEntry(localIdentifier: item.localIdentifier, outputPath: success.outputURL.path)
        try? await manifest.recordCompletion(entry)
    }

    private func recordFailure(item: PipelineItem, reason: ItemFailureReason, wasRetried: Bool) {
        // This item has exhausted its attempt(s) for good on this instance —
        // skip it on any later resume rather than re-attempting it forever.
        failedIdentifiers.insert(item.localIdentifier)
        // At most one log entry per identifier: replace rather than append,
        // so a re-attempt (if one ever did occur) can't pile up duplicates.
        failureLog.removeAll { $0.localIdentifier == item.localIdentifier }
        failureLog.append(PipelineFailureLogEntry(
            localIdentifier: item.localIdentifier,
            filename: item.sourceURL.lastPathComponent,
            errorCode: reason.rawValue,
            wasRetried: wasRetried
        ))
    }
}
