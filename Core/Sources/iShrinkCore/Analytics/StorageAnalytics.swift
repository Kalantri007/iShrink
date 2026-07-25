// iShrink Phase 1 plan, U4 "Media classifier & storage analytics".
//
// Folds `MediaClassifier` output into per-codec totals, an overall total,
// a compressible/excluded/analytics-only byte split, and a top-N
// largest-files list. Largest-*albums* and cross-run compression *history*
// are explicitly out of scope (Scope Boundaries: Deferred to Follow-Up
// Work) — this is a single run's numbers only.

/// One codec's aggregate count + bytes.
public struct CodecBreakdownEntry: Sendable, Equatable {
    public let codec: MediaCodec
    public let count: Int
    public let bytes: Int64
}

/// One entry in the top-N largest-files list.
public struct LargestFile: Sendable, Equatable {
    public let localIdentifier: String
    public let originalFilename: String?
    public let bytes: Int64
}

/// Aggregated storage analytics over a set of classified assets.
public struct StorageAnalytics: Sendable, Equatable {
    public let totalCount: Int
    public let totalBytes: Int64

    public let compressibleCount: Int
    public let compressibleBytes: Int64

    /// Video: counted and sized for analytics, but never a compression
    /// candidate in Phase 1 and never attached to an `ExclusionReason`
    /// (Scope Boundaries: "No video compression").
    public let analyticsOnlyCount: Int
    public let analyticsOnlyBytes: Int64

    public let excludedCountByReason: [ExclusionReason: Int]
    public let excludedBytesByReason: [ExclusionReason: Int64]

    public let codecBreakdown: [CodecBreakdownEntry]

    /// Largest files across the whole classified set, descending by size,
    /// capped at the `topN` requested at aggregation time.
    public let largestFiles: [LargestFile]

    /// Sum of `excludedBytesByReason`'s values. Exposed so callers (and
    /// tests) don't have to re-derive it to check the reconciliation
    /// invariant below.
    public var excludedBytesTotal: Int64 {
        excludedBytesByReason.values.reduce(0, +)
    }

    /// The plan's explicit reconciliation requirement ("excluded-bytes-by-
    /// reason + compressible-bytes == total-bytes"), generalized to the
    /// three eligibility buckets `MediaClassifier` actually produces.
    /// `MediaClassifier.classify` returns exactly one of
    /// `.compressible` / `.excluded(reason)` / `.analyticsOnly` per record
    /// (see its `guard`-chain), so every classified record's bytes land in
    /// exactly one of the three sums below — no double counting, nothing
    /// falls through the cracks. (When a fixture set contains no video/
    /// analytics-only assets, `analyticsOnlyBytes` is simply zero and this
    /// collapses to the plan's literal two-term equation.)
    public var reconcilesToTotal: Bool {
        compressibleBytes + excludedBytesTotal + analyticsOnlyBytes == totalBytes
    }

    public init(
        totalCount: Int,
        totalBytes: Int64,
        compressibleCount: Int,
        compressibleBytes: Int64,
        analyticsOnlyCount: Int,
        analyticsOnlyBytes: Int64,
        excludedCountByReason: [ExclusionReason: Int],
        excludedBytesByReason: [ExclusionReason: Int64],
        codecBreakdown: [CodecBreakdownEntry],
        largestFiles: [LargestFile]
    ) {
        self.totalCount = totalCount
        self.totalBytes = totalBytes
        self.compressibleCount = compressibleCount
        self.compressibleBytes = compressibleBytes
        self.analyticsOnlyCount = analyticsOnlyCount
        self.analyticsOnlyBytes = analyticsOnlyBytes
        self.excludedCountByReason = excludedCountByReason
        self.excludedBytesByReason = excludedBytesByReason
        self.codecBreakdown = codecBreakdown
        self.largestFiles = largestFiles
    }

    /// Folds a set of already-classified assets into aggregate analytics.
    /// - Parameter topN: how many entries `largestFiles` keeps, largest
    ///   first.
    public static func aggregate(_ classified: [ClassifiedAsset], topN: Int = 10) -> StorageAnalytics {
        var totalBytes: Int64 = 0
        var compressibleBytes: Int64 = 0
        var compressibleCount = 0
        var analyticsOnlyBytes: Int64 = 0
        var analyticsOnlyCount = 0
        var excludedCountByReason: [ExclusionReason: Int] = [:]
        var excludedBytesByReason: [ExclusionReason: Int64] = [:]
        var codecCounts: [MediaCodec: Int] = [:]
        var codecBytes: [MediaCodec: Int64] = [:]

        for asset in classified {
            let bytes = asset.record.byteSize
            totalBytes += bytes
            codecCounts[asset.codec, default: 0] += 1
            codecBytes[asset.codec, default: 0] += bytes

            switch asset.eligibility {
            case .compressible:
                compressibleBytes += bytes
                compressibleCount += 1
            case .analyticsOnly:
                analyticsOnlyBytes += bytes
                analyticsOnlyCount += 1
            case .excluded(let reason):
                excludedCountByReason[reason, default: 0] += 1
                excludedBytesByReason[reason, default: 0] += bytes
            }
        }

        let largestFiles = classified
            .sorted { $0.record.byteSize > $1.record.byteSize }
            .prefix(max(topN, 0))
            .map {
                LargestFile(
                    localIdentifier: $0.record.localIdentifier,
                    originalFilename: $0.record.originalFilename,
                    bytes: $0.record.byteSize
                )
            }

        let codecBreakdown = codecCounts.keys
            .map { codec in
                CodecBreakdownEntry(codec: codec, count: codecCounts[codec] ?? 0, bytes: codecBytes[codec] ?? 0)
            }
            .sorted { lhs, rhs in
                lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : lhs.count > rhs.count
            }

        return StorageAnalytics(
            totalCount: classified.count,
            totalBytes: totalBytes,
            compressibleCount: compressibleCount,
            compressibleBytes: compressibleBytes,
            analyticsOnlyCount: analyticsOnlyCount,
            analyticsOnlyBytes: analyticsOnlyBytes,
            excludedCountByReason: excludedCountByReason,
            excludedBytesByReason: excludedBytesByReason,
            codecBreakdown: codecBreakdown,
            largestFiles: Array(largestFiles)
        )
    }
}
