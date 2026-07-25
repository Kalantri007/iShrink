import Testing
@testable import iShrinkCore

// iShrink Phase 1 plan, U5 "Savings estimator" — Tier 1 (heuristic) test
// scenarios only. Tier 2 (calibration re-projection) is a follow-up pass
// that lands with U6 and is intentionally not covered here.

@Suite struct SavingsEstimatorTests {

    // Happy path: 10 GB compressible JPEG at injected 0.5 ratio → 5 GB
    // estimate, 5 GB savings.
    @Test func fixedRatioProjectsExactEstimateAndSavings() {
        let tenGB: Int64 = 10 * 1_000 * 1_000 * 1_000
        let estimate = SavingsEstimator.estimate(
            compressibleBytesByCodec: [.jpeg: tenGB],
            ratios: [.jpeg: .fixed(0.5)]
        )

        let expectedBytes: Int64 = 5 * 1_000 * 1_000 * 1_000

        #expect(estimate.compressibleBytes == tenGB)
        #expect(estimate.estimatedBytesLow == expectedBytes)
        #expect(estimate.estimatedBytesHigh == expectedBytes)
        #expect(estimate.savingsBytesLow == expectedBytes)
        #expect(estimate.savingsBytesHigh == expectedBytes)
    }

    // Edge case: 0 compressible bytes → 0 savings, no divide-by-zero.
    @Test func zeroCompressibleBytesProducesZeroSavings() {
        let estimate = SavingsEstimator.estimate(
            compressibleBytesByCodec: [.jpeg: 0, .png: 0],
            ratios: SavingsEstimator.defaultRatios
        )

        #expect(estimate.compressibleBytes == 0)
        #expect(estimate.estimatedBytesLow == 0)
        #expect(estimate.estimatedBytesHigh == 0)
        #expect(estimate.savingsBytesLow == 0)
        #expect(estimate.savingsBytesHigh == 0)
    }

    // Also covers the empty-map case (no entries at all, not just
    // zero-valued ones) — same no-divide-by-zero guarantee.
    @Test func emptyCodecMapProducesZeroSavings() {
        let estimate = SavingsEstimator.estimate(compressibleBytesByCodec: [:])

        #expect(estimate.compressibleBytes == 0)
        #expect(estimate.estimatedBytesLow == 0)
        #expect(estimate.estimatedBytesHigh == 0)
    }

    // Edge case: all-HEIC/HEVC library → near-zero compressible → estimate
    // honestly reports small savings, not an inflated default. Simulates a
    // library that's almost entirely already-HEIC (so `MediaClassifier`
    // marked it excluded, not compressible) with just a handful of
    // leftover JPEG bytes still eligible.
    @Test func nearZeroCompressibleLibraryReportsHonestlySmallSavings() {
        let tinyJPEGBytes: Int64 = 200

        let estimate = SavingsEstimator.estimate(
            compressibleBytesByCodec: [.jpeg: tinyJPEGBytes],
            ratios: SavingsEstimator.defaultRatios
        )

        #expect(estimate.compressibleBytes == tinyJPEGBytes)
        // Savings bounded by the tiny input itself — nowhere near a
        // library-scale number, and never negative or inflated beyond the
        // compressible bytes actually fed in.
        #expect(estimate.savingsBytesHigh <= tinyJPEGBytes)
        #expect(estimate.savingsBytesLow >= 0)
        #expect(estimate.estimatedBytesLow <= estimate.estimatedBytesHigh)
    }

    // Edge case: a codec with no entry in the ratio table (e.g. HEIC/HEVC,
    // or anything the caller passes that the heuristic table doesn't know
    // about) is treated as zero savings rather than a guessed default.
    @Test func codecMissingFromRatioTableAssumesNoSavings() {
        let bytes: Int64 = 1_000

        let estimate = SavingsEstimator.estimate(
            compressibleBytesByCodec: [.heic: bytes],
            ratios: SavingsEstimator.defaultRatios
        )

        #expect(estimate.compressibleBytes == bytes)
        #expect(estimate.estimatedBytesLow == bytes)
        #expect(estimate.estimatedBytesHigh == bytes)
        #expect(estimate.savingsBytesLow == 0)
        #expect(estimate.savingsBytesHigh == 0)
    }

    // Sanity on the range shape itself: low <= high, for both the size and
    // savings projections, when a codec has a genuine (non-degenerate)
    // ratio range.
    @Test func rangeOutputHasLowLessThanOrEqualToHigh() {
        let bytes: Int64 = 4_000

        let estimate = SavingsEstimator.estimate(
            compressibleBytesByCodec: [.png: bytes],
            ratios: [.png: SavingsEstimator.RatioRange(low: 0.2, high: 0.5)]
        )

        #expect(estimate.estimatedBytesLow <= estimate.estimatedBytesHigh)
        #expect(estimate.savingsBytesLow <= estimate.savingsBytesHigh)
    }

    // A per-codec mix (some JPEG, some PNG, each with a different injected
    // ratio) produces a correctly weighted total — the sum of each codec's
    // own projection — not a single blended ratio applied to the whole
    // compressible total.
    @Test func mixedCodecsAreWeightedPerCodecNotBlended() {
        let jpegBytes: Int64 = 8_000
        let pngBytes: Int64 = 2_000

        let estimate = SavingsEstimator.estimate(
            compressibleBytesByCodec: [.jpeg: jpegBytes, .png: pngBytes],
            ratios: [
                .jpeg: .fixed(0.5),
                .png: .fixed(0.25),
            ]
        )

        let expectedJPEGProjection: Int64 = 4_000
        let expectedPNGProjection: Int64 = 500
        let expectedLow = expectedJPEGProjection + expectedPNGProjection
        let expectedTotal = jpegBytes + pngBytes

        #expect(estimate.compressibleBytes == expectedTotal)
        #expect(estimate.estimatedBytesLow == expectedLow)
        #expect(estimate.estimatedBytesHigh == expectedLow)

        let expectedSavings: Int64 = (jpegBytes - expectedJPEGProjection) + (pngBytes - expectedPNGProjection)
        #expect(estimate.savingsBytesLow == expectedSavings)
        #expect(estimate.savingsBytesHigh == expectedSavings)

        // A wrong "single blended ratio over the whole total" implementation
        // would instead produce something like (jpegBytes + pngBytes) * a
        // single ratio, which does not equal the correctly weighted sum
        // above whenever the per-codec ratios differ — assert the two
        // approaches would disagree here, to make sure this test would
        // actually catch that bug.
        let blendedRatio = 0.5
        let blendedProjection = Int64((Double(expectedTotal) * blendedRatio).rounded())
        #expect(blendedProjection != expectedLow)
    }

    @Test func defaultRatiosCoverJPEGAndPNG() {
        #expect(SavingsEstimator.defaultRatios[.jpeg] != nil)
        #expect(SavingsEstimator.defaultRatios[.png] != nil)
    }
}
