import Foundation

// iShrink Phase 1 plan, U7 "Bounded streaming pipeline".
//
// App-private temp directory management: the pipeline's own working area
// (distinct from `ImageCompressor.tempDirectory`, which is injected the
// same way — see that file's header comment — but this type is the one
// `CompressionPipeline` owns and sweeps at startup). Two responsibilities:
//
//  - **Startup orphan sweep**: before a run begins, delete any leftover
//    files already present in the temp dir. They may be the unredacted-
//    GPS/EXIF working copy of a crashed or force-quit prior run, so they
//    must not linger (Context & Research: temp dir "removed immediately
//    after each item" — this is the crash-time complement to that).
//  - **Per-item cleanup**: remove one item's temp file immediately once
//    that item is done (success or failure), so nothing outlives its own
//    item's processing.
//
// The directory is an injectable constructor parameter, never hardcoded —
// same pattern U6's `ImageCompressor.tempDirectory` already established, so
// tests point this at scratch directories instead of the real
// `~/Library/Application Support/iShrink/tmp`.
public struct TempStore: Sendable {
    /// Where per-item working files live. Created on demand by
    /// `sweepOrphans()` if it doesn't exist yet.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Deletes every file currently present in `directory` and returns how
    /// many were removed. Call this once, before a run's first item is
    /// admitted — anything found here predates this run and cannot be
    /// trusted (Key Technical Decisions: crash leftovers "carry unredacted
    /// GPS/EXIF").
    @discardableResult
    public func sweepOrphans() throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
        return contents.count
    }

    /// Removes one item's temp file immediately after that item finishes
    /// (success or failure). Safe to call even if nothing exists at `url`
    /// — a completed/failed item may never have had a real temp file in
    /// this store at all (e.g. a real `ImageCompressor` already cleaned up
    /// its own temp file internally; this is a defensive second cleanup
    /// call, not the only one).
    public func cleanupAfterItem(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The temp file location this store would use for one asset, namespaced
    /// by `localIdentifier` the same collision-safe way `ImageCompressor`
    /// names its destination output (see `ImageCompressor.sanitizedFilename`)
    /// — a `PHAsset.localIdentifier` contains `/`, which isn't filesystem-safe
    /// on its own.
    public func tempURL(for localIdentifier: String) -> URL {
        directory.appendingPathComponent(ImageCompressor.sanitizedFilename(for: localIdentifier))
    }
}
