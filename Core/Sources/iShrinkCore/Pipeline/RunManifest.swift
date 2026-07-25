import Foundation

// iShrink Phase 1 plan, U7 "Bounded streaming pipeline".
//
// Run manifest: an append-only log of completed items + periodic
// checkpoints, keyed on `localIdentifier` (Key Technical Decisions: "Run
// manifest = append-only log + periodic checkpoint, keyed on
// localIdentifier"). Resume means "skip items *recorded complete in the
// manifest*" — never "a file exists at the destination path"; a stray file
// at a path whose item isn't in the manifest is presumed a truncated
// leftover from an interrupted run and gets overwritten, not treated as
// done (that decision lives in `CompressionPipeline`/`ImageCompressor`,
// which never consult the filesystem to decide "already done" — only this
// manifest does).
//
// The hot path (`recordCompletion`) is a single dictionary insert plus one
// `append` call — O(1) per completed item. Rewriting the *entire* manifest
// on every completion would be O(n^2) at 100k assets; instead, a full
// atomic rewrite only happens periodically, in `checkpointNow()`.
//
// Split into three layers so each is independently testable:
//  - `ManifestEntry` — the persisted value.
//  - `ManifestPersisting` — the storage seam (`InMemoryManifestStore` for
//    tests with no disk I/O at all; `FileManifestStore` for the real,
//    file-backed conformer).
//  - `RunManifest` — the actor that holds the in-memory "what's done"
//    index and drives the append/checkpoint cadence. It's an actor (not a
//    plain struct) because many concurrent pipeline tasks call
//    `recordCompletion` at once, and the completed-index + checkpoint
//    counter must stay consistent under that concurrency.

/// One completed item, as persisted in the manifest.
public struct ManifestEntry: Sendable, Equatable, Codable {
    public let localIdentifier: String
    public let outputPath: String
    public let completedAt: Date

    public init(localIdentifier: String, outputPath: String, completedAt: Date = Date()) {
        self.localIdentifier = localIdentifier
        self.outputPath = outputPath
        self.completedAt = completedAt
    }
}

/// Storage seam for the manifest's durable side. `append` is the hot path
/// (called once per completed item); `checkpoint` is the periodic, full
/// atomic rewrite; `loadAll` reconstructs the full completed set (log +
/// last checkpoint) at startup/resume.
public protocol ManifestPersisting: Sendable {
    func append(_ entry: ManifestEntry) throws
    func checkpoint(_ entries: [ManifestEntry]) throws
    func loadAll() throws -> [ManifestEntry]
}

/// In-memory `ManifestPersisting` conformer — no real disk I/O, so
/// append/resume/skip logic is unit-testable without a filesystem. Also
/// exposes call counts so tests can assert the O(1)-hot-path /
/// periodic-checkpoint shape directly (append called every time,
/// checkpoint called only periodically), not just the end-to-end behavior.
public final class InMemoryManifestStore: ManifestPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ManifestEntry]

    public private(set) var appendCallCount = 0
    public private(set) var checkpointCallCount = 0

    public init(seed: [ManifestEntry] = []) {
        entries = seed
    }

    public func append(_ entry: ManifestEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        appendCallCount += 1
    }

    public func checkpoint(_ entries: [ManifestEntry]) throws {
        lock.lock()
        defer { lock.unlock() }
        self.entries = entries
        checkpointCallCount += 1
    }

    public func loadAll() throws -> [ManifestEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// Real, file-backed `ManifestPersisting` conformer: a JSON-Lines
/// append-only log for the hot path, plus a single JSON array file for
/// periodic checkpoints. A checkpoint rolls the log back to empty (its
/// entries are now durable in the checkpoint file), keeping the log itself
/// bounded between checkpoints rather than growing forever.
public final class FileManifestStore: ManifestPersisting, @unchecked Sendable {
    private let logURL: URL
    private let checkpointURL: URL
    private let lock = NSLock()

    public init(directory: URL) {
        logURL = directory.appendingPathComponent("manifest.log.jsonl")
        checkpointURL = directory.appendingPathComponent("manifest.checkpoint.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func append(_ entry: ManifestEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        var line = try JSONEncoder().encode(entry)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try line.write(to: logURL)
        }
    }

    public func checkpoint(_ entries: [ManifestEntry]) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try JSONEncoder().encode(entries)
        let tmpURL = checkpointURL.appendingPathExtension("tmp")
        try data.write(to: tmpURL)
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            _ = try FileManager.default.replaceItemAt(checkpointURL, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: checkpointURL)
        }
        // The log's contents are now folded into the checkpoint; reset it
        // so it doesn't grow without bound across many checkpoints.
        try? FileManager.default.removeItem(at: logURL)
    }

    public func loadAll() throws -> [ManifestEntry] {
        lock.lock()
        defer { lock.unlock() }
        var result: [ManifestEntry] = []
        if
            let checkpointData = try? Data(contentsOf: checkpointURL),
            let checkpointEntries = try? JSONDecoder().decode([ManifestEntry].self, from: checkpointData)
        {
            result = checkpointEntries
        }
        if let logData = try? Data(contentsOf: logURL) {
            for line in logData.split(separator: 0x0A) where !line.isEmpty {
                if let entry = try? JSONDecoder().decode(ManifestEntry.self, from: Data(line)) {
                    result.append(entry)
                }
            }
        }
        return result
    }
}

/// The pipeline's view of "what's already done", keyed on `localIdentifier`.
/// An actor because many concurrent `CompressionPipeline` tasks call
/// `recordCompletion` on the same manifest at once.
public actor RunManifest {
    private let store: ManifestPersisting
    private let checkpointInterval: Int
    private var completed: [String: ManifestEntry] = [:]
    private var sinceLastCheckpoint = 0

    /// - Parameter checkpointInterval: how many `recordCompletion` calls
    ///   happen between full checkpoints. Keeping this well above 1 is what
    ///   keeps the hot path O(1) instead of O(n) (let alone O(n^2)) at
    ///   100k-asset scale.
    public init(store: ManifestPersisting, checkpointInterval: Int = 50) {
        self.store = store
        self.checkpointInterval = max(1, checkpointInterval)
    }

    /// Hydrates the in-memory completed-index from the durable store —
    /// call this once before consulting `isComplete` on a resumed run (a
    /// fresh `RunManifest` that hasn't loaded anything yet reports nothing
    /// as complete, even if the underlying store has prior entries).
    public func load() throws {
        for entry in try store.loadAll() {
            completed[entry.localIdentifier] = entry
        }
    }

    /// Whether `localIdentifier` is recorded complete. This is the *only*
    /// signal the pipeline uses to decide "skip this item on resume" — it
    /// deliberately never inspects the filesystem for an existing output
    /// file (see file header).
    public func isComplete(_ localIdentifier: String) -> Bool {
        completed[localIdentifier] != nil
    }

    public var completedCount: Int {
        completed.count
    }

    /// Records one item as done: O(1) — a dictionary insert plus a single
    /// `append` call to the durable store. Triggers a checkpoint only every
    /// `checkpointInterval` calls, or less often as the completed set grows
    /// (see `nextCheckpointThreshold`) — a full checkpoint rewrites the
    /// *entire* completed set, so checkpointing at a fixed count interval
    /// would make the cumulative rewritten-entry total grow quadratically
    /// with the run size; scaling the gap keeps it near O(n log n).
    public func recordCompletion(_ entry: ManifestEntry) throws {
        completed[entry.localIdentifier] = entry
        try store.append(entry)
        sinceLastCheckpoint += 1
        if sinceLastCheckpoint >= nextCheckpointThreshold {
            try checkpointNow()
        }
    }

    /// How many completions must accumulate before the next checkpoint:
    /// `checkpointInterval`, or 2% of the current completed-set size,
    /// whichever is larger. Widening the gap as the set grows keeps a
    /// checkpoint's O(current size) rewrite cost from being paid at a fixed
    /// small cadence all the way to 100k+ assets.
    private var nextCheckpointThreshold: Int {
        max(checkpointInterval, completed.count / 50)
    }

    /// Forces an atomic full-rewrite checkpoint now, regardless of the
    /// interval counter. `CompressionPipeline` calls this at the end of a
    /// run so the final state is always durable, not just "durable up to
    /// the last periodic checkpoint".
    public func checkpointNow() throws {
        try store.checkpoint(Array(completed.values))
        sinceLastCheckpoint = 0
    }
}
