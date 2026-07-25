import Foundation

// iShrink Phase 1 plan, U5 "Savings estimator" — Tier 1 (heuristic) only.
//
// Tier 1 projects a realistic post-compression size/savings range from the
// real codec mix using a default expected-ratio table by source codec,
// applied to *compressible* bytes only. It is pure math over injected
// ratios — no PhotoKit, no `ImageCompressor` (which doesn't exist yet; U6
// builds it). Tier 2 (calibration, needs U6) will re-project using a
// *measured* ratio from a small compressed sample instead of this
// heuristic table — see the doc comments below on why `estimate(...)` takes
// ratios as a parameter rather than baking them into stored state, and why
// `defaultRatios` is `public` rather than `private`: both are the seams
// Tier 2 needs, deliberately left open now (plan: "Module dependency build
// order ... `SavingsEstimator` (heuristic tier) → ... → `SavingsEstimator`
// (calibration tier, needs the compressor)").
//
// Input shape note (design decision / minor gap filled here, not in
// `StorageAnalytics`): U5 needs per-*codec* *compressible* bytes to apply
// per-codec ratios, but `StorageAnalytics.codecBreakdown` aggregates bytes
// per codec across *all* eligibilities (compressible + excluded +
// analytics-only combined), and `StorageAnalytics.compressibleBytes` is a
// flat total with no per-codec split. Neither shape alone is what this unit
// needs, and `StorageAnalytics` is deliberately not modified to add one (out
// of scope for this pass). So `SavingsEstimator.estimate` takes a plain
// `[MediaCodec: Int64]` of compressible-bytes-per-codec directly — a caller
// (a later UI/reporting unit) assembles this by refiltering the classified
// set to `.compressible` assets and grouping by `codec`, since only the
// caller has both the per-asset codec *and* per-asset eligibility at once.

/// Coarse projection of realistic post-compression size and savings from a
/// real codec mix (plan Approach, U5 Tier 1). Pure namespace — holds no
/// instance state, so there is nothing to construct; call `estimate`
/// directly. (A stateless `enum` rather than a `struct` you'd instantiate,
/// since there is no meaningful instance.)
public enum SavingsEstimator {
    /// Expected compression ratio range for one source codec: the fraction
    /// of original bytes remaining after compression (e.g. `0.5` means the
    /// output is half the input size — smaller fraction means more
    /// savings). `low` and `high` bound the range of plausible outcomes;
    /// `low <= high` is an invariant enforced at construction.
    ///
    /// A single expected ratio (no range) is expressed via `.fixed(_:)`,
    /// which collapses `low == high` — this is what the plan's "10 GB
    /// compressible JPEG at injected 0.5 ratio → 5 GB estimate" scenario
    /// uses: a degenerate range, not a special case in the projection math.
    public struct RatioRange: Sendable, Equatable {
        public let low: Double
        public let high: Double

        public init(low: Double, high: Double) {
            precondition(low <= high, "RatioRange requires low <= high (got \(low)...\(high))")
            self.low = low
            self.high = high
        }

        /// A degenerate range expressing a single expected ratio rather
        /// than a low/high spread.
        public static func fixed(_ ratio: Double) -> RatioRange {
            RatioRange(low: ratio, high: ratio)
        }
    }

    /// The projected result: an honest low/high range rather than a single
    /// false-precision number (plan: "Report a range ... origin honesty
    /// about savings").
    ///
    /// `estimatedBytesLow`/`estimatedBytesHigh` are the projected
    /// post-compression size bounds; `savingsBytesLow`/`savingsBytesHigh`
    /// are the corresponding savings bounds (derived, not independently
    /// computed, so they can never disagree with the size bounds).
    public struct Estimate: Sendable, Equatable {
        /// Total compressible bytes this estimate was projected from (the
        /// sum of the input dictionary's values).
        public let compressibleBytes: Int64

        /// Smallest plausible projected post-compression size (uses each
        /// codec's most optimistic — smallest-fraction — ratio).
        public let estimatedBytesLow: Int64

        /// Largest plausible projected post-compression size (uses each
        /// codec's least optimistic — largest-fraction — ratio).
        public let estimatedBytesHigh: Int64

        public init(compressibleBytes: Int64, estimatedBytesLow: Int64, estimatedBytesHigh: Int64) {
            self.compressibleBytes = compressibleBytes
            self.estimatedBytesLow = estimatedBytesLow
            self.estimatedBytesHigh = estimatedBytesHigh
        }

        /// Smallest plausible savings (corresponds to `estimatedBytesHigh`
        /// — the least optimistic size projection).
        public var savingsBytesLow: Int64 { compressibleBytes - estimatedBytesHigh }

        /// Largest plausible savings (corresponds to `estimatedBytesLow` —
        /// the most optimistic size projection).
        public var savingsBytesHigh: Int64 { compressibleBytes - estimatedBytesLow }
    }

    /// Default heuristic ratio table by source codec (Tier 1). Deliberately
    /// `public`, not `private` — a stored property/table with no override
    /// seam is exactly what the plan warns against ("don't make the ratio
    /// table `private` with no way to override per-call"). Tier 2 will
    /// build its own table from a measured calibration sample and pass it
    /// to the same `estimate(...)` function in place of this one; nothing
    /// about `estimate`'s signature needs to change when that lands.
    ///
    /// Codecs absent from a ratio table (e.g. `.heic`, `.hevc`, or any
    /// codec `MediaClassifier` never marks `.compressible` in the first
    /// place) are not given a fabricated ratio here — `estimate` treats a
    /// missing entry as "no known savings for this codec" and assumes the
    /// bytes pass through unchanged, rather than guessing. In practice
    /// `MediaClassifier` only ever marks JPEG/PNG sources `.compressible`,
    /// so this table only needs entries for those, but the lookup is
    /// defensive against a wider `compressibleBytesByCodec` input.
    public static let defaultRatios: [MediaCodec: RatioRange] = [
        .jpeg: RatioRange(low: 0.5, high: 0.7),
        .png: RatioRange(low: 0.2, high: 0.5),
    ]

    /// Projects an estimated post-compression size/savings range from
    /// per-codec compressible bytes and a per-codec ratio table.
    ///
    /// Pure math, no compressor involved (Tier 1). Sums each codec's own
    /// projection rather than applying one blended ratio to the whole
    /// compressible total, so a mixed library (e.g. some JPEG, some PNG)
    /// gets a correctly weighted result.
    ///
    /// - Parameters:
    ///   - compressibleBytesByCodec: compressible bytes per source codec,
    ///     assembled by the caller (see this file's header comment for why
    ///     `StorageAnalytics` doesn't supply this shape directly today).
    ///     Codecs with zero or negative bytes are ignored.
    ///   - ratios: expected compression ratio range per source codec.
    ///     Defaults to `defaultRatios` (Tier 1's heuristic table); Tier 2
    ///     will pass a table built from a measured calibration sample
    ///     instead — the same function serves both tiers.
    public static func estimate(
        compressibleBytesByCodec: [MediaCodec: Int64],
        ratios: [MediaCodec: RatioRange] = defaultRatios
    ) -> Estimate {
        var totalCompressibleBytes: Int64 = 0
        var estimatedBytesLow: Int64 = 0
        var estimatedBytesHigh: Int64 = 0

        for (codec, bytes) in compressibleBytesByCodec {
            guard bytes > 0 else { continue }
            totalCompressibleBytes += bytes

            guard let ratio = ratios[codec] else {
                // No known ratio for this codec — honestly assume no
                // savings rather than fabricating a number, so a library
                // whose "compressible" bytes are dominated by a codec we
                // have no ratio for reports near-zero savings instead of an
                // inflated default.
                estimatedBytesLow += bytes
                estimatedBytesHigh += bytes
                continue
            }

            estimatedBytesLow += Self.projected(bytes: bytes, ratio: ratio.low)
            estimatedBytesHigh += Self.projected(bytes: bytes, ratio: ratio.high)
        }

        return Estimate(
            compressibleBytes: totalCompressibleBytes,
            estimatedBytesLow: estimatedBytesLow,
            estimatedBytesHigh: estimatedBytesHigh
        )
    }

    private static func projected(bytes: Int64, ratio: Double) -> Int64 {
        Int64((Double(bytes) * ratio).rounded())
    }
}
