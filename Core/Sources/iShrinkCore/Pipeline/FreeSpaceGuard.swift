import Foundation

// iShrink Phase 1 plan, U7 "Bounded streaming pipeline".
//
// Reads free space on the *destination* volume (never the Photos library,
// which this package never writes to) at batch boundaries, so the pipeline
// can stop admitting new items before the disk actually fills up (R9's
// "live free-space guardrail").
//
// Nil-capacity policy (Key Technical Decisions / Context & Research "Free-
// space guardrail"): the real conformer tries
// `volumeAvailableCapacityForImportantUsage` first, falls back to
// `volumeAvailableCapacity` if that key is nil (some network shares/exotic
// volumes don't support the "important usage" key), and if *that* is also
// nil, the guard reports `.cannotMonitor` rather than silently proceeding —
// silently proceeding risks filling the disk with no guardrail at all,
// which is worse than stopping the run. The two reads are split into their
// own `FreeSpaceReading` protocol precisely so this fallback chain is
// testable: a fake can return (value, nil), (nil, value), or (nil, nil)
// without touching a real volume.

/// Result of a free-space check against the destination volume.
public enum FreeSpaceStatus: Sendable, Equatable {
    /// Enough free space to keep admitting new items.
    case ok(availableBytes: Int64)

    /// Below the configured threshold — the pipeline should stop admitting
    /// new items and pause with `.lowDiskSpace`, not corrupt or truncate an
    /// in-flight write.
    case low(availableBytes: Int64)

    /// Neither the primary nor the fallback capacity read produced a value.
    /// This is a blocking setup condition, not "assume there's space" — see
    /// file header.
    case cannotMonitor
}

/// Seam around the two `URLResourceValues` capacity reads, so
/// `FreeSpaceGuard`'s fallback-chain logic is unit-testable without
/// depending on the real disk or a real (possibly-exotic) volume.
public protocol FreeSpaceReading: Sendable {
    /// Mirrors `URLResourceValues.volumeAvailableCapacityForImportantUsage`
    /// — the preferred, more accurate read. `nil` when the volume doesn't
    /// support the key.
    func importantUsageAvailableCapacity(for url: URL) -> Int64?

    /// Mirrors `URLResourceValues.volumeAvailableCapacity` — the documented
    /// fallback. `nil` when even this can't be read.
    func availableCapacity(for url: URL) -> Int64?
}

/// Real, `URLResourceValues`-backed `FreeSpaceReading` conformer.
public struct URLResourceFreeSpaceReader: FreeSpaceReading {
    public init() {}

    public func importantUsageAvailableCapacity(for url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    public func availableCapacity(for url: URL) -> Int64? {
        guard
            let capacity = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                .volumeAvailableCapacity
        else {
            return nil
        }
        return Int64(capacity)
    }
}

/// Live free-space guardrail for the destination volume (R9). A plain,
/// stateless value type — every call re-reads current capacity rather than
/// caching, since the whole point is catching space draining *during* a
/// run.
public struct FreeSpaceGuard: Sendable {
    /// The destination the pipeline is writing compressed output into —
    /// deliberately *not* the app-private temp directory, which lives on
    /// whatever volume the app's own container is on. Free space is judged
    /// against where the finished files actually land.
    public let destinationURL: URL

    /// Below this many available bytes, admission of new items pauses.
    public let thresholdBytes: Int64

    private let reader: FreeSpaceReading

    public init(destinationURL: URL, thresholdBytes: Int64, reader: FreeSpaceReading = URLResourceFreeSpaceReader()) {
        self.destinationURL = destinationURL
        self.thresholdBytes = thresholdBytes
        self.reader = reader
    }

    /// Checks free space now, following the nil-capacity fallback chain
    /// described in the file header.
    public func checkStatus() -> FreeSpaceStatus {
        if let important = reader.importantUsageAvailableCapacity(for: destinationURL) {
            return important < thresholdBytes ? .low(availableBytes: important) : .ok(availableBytes: important)
        }
        if let fallback = reader.availableCapacity(for: destinationURL) {
            return fallback < thresholdBytes ? .low(availableBytes: fallback) : .ok(availableBytes: fallback)
        }
        return .cannotMonitor
    }
}
