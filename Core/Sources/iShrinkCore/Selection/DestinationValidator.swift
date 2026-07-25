import Foundation

// iShrink Phase 1 plan, U8 "App UI" — `ConfirmationView`'s destination
// validation, kept in Core so it's unit-tested headlessly (plan:
// "Validates the chosen destination via `DestinationValidator` (Core,
// unit-tested)").
//
// Free-space reads reuse U7's `FreeSpaceReading` seam
// (`Pipeline/FreeSpaceGuard.swift`) rather than re-implementing the same
// `volumeAvailableCapacityForImportantUsage` → `volumeAvailableCapacity`
// fallback chain a second time — this type asks the same question
// (`FreeSpaceGuard` does for the *in-run* guardrail, this does for the
// *pre-run* confirmation-screen warning), just with a different, coarser
// threshold and without `FreeSpaceGuard`'s "blocking setup error on double
// nil" semantics (a confirmation-screen warning is advisory, not a hard
// pipeline-stopping condition, so an unknown free-space reading here simply
// isn't flagged rather than blocking confirmation outright).

/// Result of validating one destination folder for compression output.
public struct DestinationValidation: Sendable, Equatable {
    public let url: URL
    public let isWritable: Bool
    public let isCloudSyncPath: Bool

    /// Free space on the destination volume, if it could be read at all.
    /// `nil` means unknown (e.g. the folder doesn't exist, or the volume
    /// supports neither capacity key) — treated as "don't warn", not as a
    /// fabricated zero.
    public let availableBytes: Int64?
    public let isLowOnFreeSpace: Bool

    public init(
        url: URL,
        isWritable: Bool,
        isCloudSyncPath: Bool,
        availableBytes: Int64?,
        isLowOnFreeSpace: Bool
    ) {
        self.url = url
        self.isWritable = isWritable
        self.isCloudSyncPath = isCloudSyncPath
        self.availableBytes = availableBytes
        self.isLowOnFreeSpace = isLowOnFreeSpace
    }

    /// A read-only/unwritable destination is an outright rejection (plan:
    /// "rejects read-only/unwritable folders") — distinct from the
    /// cloud-sync case below, which only *warns*.
    public var isRejected: Bool { !isWritable }

    /// Whether `ConfirmationView` must collect an explicit acknowledgement
    /// before proceeding (plan: "warns with explicit acknowledgement ...
    /// because outputs carry GPS/EXIF and would otherwise be auto-uploaded
    /// — a real egress path against R13"). Only meaningful when
    /// `isRejected` is `false` — a rejected destination must be changed,
    /// not acknowledged past.
    public var requiresCloudSyncAcknowledgement: Bool { isCloudSyncPath }

    /// The plan's "ordinary local folder → clean" case: writable, not a
    /// known cloud-sync container, and not low on free space.
    public var isClean: Bool {
        !isRejected && !isCloudSyncPath && !isLowOnFreeSpace
    }
}

/// Validates a user-chosen output folder at confirmation time (plan
/// Approach, `ConfirmationView`).
public enum DestinationValidator {
    /// Known cloud-sync container path fragments (plan: "`~/Library/Mobile
    /// Documents`, `~/Dropbox`, `~/OneDrive`"). Detection is deliberately a
    /// **path-substring check**, not a real iCloud Drive/Dropbox/OneDrive
    /// API dependency — the plan calls for exactly this ("string/path-based
    /// detection, not a real iCloud Drive dependency"), and it also means a
    /// test can exercise the check against a simulated cloud-sync-like
    /// directory structure under a scratch temp dir without needing a real
    /// `~/Library/Mobile Documents`.
    public static let cloudSyncPathMarkers = [
        "Library/Mobile Documents",
        "Dropbox",
        "OneDrive",
    ]

    /// Validates `destination` folder for compression output.
    ///
    /// - Parameters:
    ///   - destination: the destination folder. Expected to already exist
    ///     — the `NSOpenPanel` picker in `ConfirmationView` only lets the
    ///     user choose an existing folder.
    ///   - fileManager: injectable for tests (e.g. a chmod'd read-only
    ///     scratch directory).
    ///   - freeSpaceReader: injectable for tests; defaults to the same
    ///     real `URLResourceValues`-backed reader U7's `FreeSpaceGuard`
    ///     uses.
    ///   - lowFreeSpaceThresholdBytes: below this many available bytes on
    ///     the destination volume, `isLowOnFreeSpace` is set. This is a
    ///     coarse, advisory Phase-1 confirmation-screen threshold —
    ///     distinct from `FreeSpaceGuard`'s own in-run pause threshold
    ///     (U7), which this type does not replace or share state with.
    public static func validate(
        destination url: URL,
        fileManager: FileManager = .default,
        freeSpaceReader: FreeSpaceReading = URLResourceFreeSpaceReader(),
        lowFreeSpaceThresholdBytes: Int64 = 1_000_000_000
    ) -> DestinationValidation {
        let isWritable = fileManager.isWritableFile(atPath: url.path)
        let isCloudSync = isCloudSyncPath(url)
        let availableBytes = freeSpaceReader.importantUsageAvailableCapacity(for: url)
            ?? freeSpaceReader.availableCapacity(for: url)
        let isLowOnFreeSpace = availableBytes.map { $0 < lowFreeSpaceThresholdBytes } ?? false

        return DestinationValidation(
            url: url,
            isWritable: isWritable,
            isCloudSyncPath: isCloudSync,
            availableBytes: availableBytes,
            isLowOnFreeSpace: isLowOnFreeSpace
        )
    }

    /// Path-substring check against `cloudSyncPathMarkers`. Not anchored to
    /// the real home directory, so it also matches a simulated cloud-sync
    /// structure a test builds under its own scratch directory.
    ///
    /// Resolves symlinks/mount indirection first (`resolvingSymlinksInPath`)
    /// — a destination folder that merely *looks* ordinary but is, or is
    /// nested inside, a symlink into a cloud-sync tree must still trigger
    /// the warning; checking only the as-picked path would let compressed
    /// output (carrying unredacted GPS/EXIF) land in a synced folder with no
    /// acknowledgement gate at all.
    static func isCloudSyncPath(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return cloudSyncPathMarkers.contains { path.contains($0) }
    }
}
