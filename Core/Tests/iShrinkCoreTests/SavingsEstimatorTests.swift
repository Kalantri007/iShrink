import Testing
import Foundation
@testable import iShrinkCore

// iShrink Phase 1 plan, U5 "Savings estimator" — Tier 1 (heuristic) test
// scenarios, plus Tier 2 (calibration re-projection, needs U6's
// `ImageCompressor`) below. `makeRecord`, `fixtureURL`, and
// `makeScratchDirectory` are shared top-level test helpers defined in
// `LibraryScannerTests.swift` / `ImageCompressorTests.swift` (same test
// target).

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

// iShrink Phase 1 plan, U5 "Savings estimator" — Tier 2 (calibration) test
// scenarios, now that U6's `ImageCompressor` exists. Uses the real committed
// fixtures and a real `ImageCompressor` (default `ImageIOHEICEncoder`), not a
// faked encoder, per the plan's "Integration" scenario label. Shares
// `makeRecord`/`fixtureURL`/`makeScratchDirectory` with
// `LibraryScannerTests.swift`/`ImageCompressorTests.swift`.
@Suite struct SavingsEstimatorCalibrationTests {

    /// Builds a minimal `ClassifiedAsset` labeled `.compressible` with the
    /// given codec — calibration only reads `asset.codec` and
    /// `asset.record.localIdentifier`, so the rest of the classification is
    /// irrelevant filler.
    private func makeCompressibleAsset(id: String, codec: MediaCodec) -> ClassifiedAsset {
        ClassifiedAsset(
            record: makeRecord(id: id),
            codec: codec,
            isLivePhoto: false,
            isHDR: false,
            eligibility: .compressible
        )
    }

    // MARK: - 1. Integration: calibration replaces the heuristic ratio and
    // shifts the confirmation number.

    @Test func calibrationReplacesHeuristicRatioAndShiftsConfirmationEstimate() throws {
        let tempDir = makeScratchDirectory()
        let destDir = makeScratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let source = fixtureURL("happy_path_fixture", extension: "jpg")
        let asset = makeCompressibleAsset(id: "calibration-happy-path", codec: .jpeg)
        let compressor = ImageCompressor(tempDirectory: tempDir)

        let measuredRatios = SavingsEstimator.calibrate(
            sample: [(asset: asset, sourceURL: source)],
            compressor: compressor,
            destinationDirectory: destDir
        )

        guard let measuredJPEGRatio = measuredRatios[.jpeg] else {
            Issue.record("expected a measured .jpeg ratio from a successful compression")
            return
        }

        // A single successful sample collapses to a degenerate range
        // (low == high), the same shape as `.fixed(_:)`.
        #expect(measuredJPEGRatio.low == measuredJPEGRatio.high)
        // Real HEIC re-encode of this fixture actually shrinks it (already
        // asserted directly against `ImageCompressor` in
        // ImageCompressorTests' happy-path test), so the measured ratio is a
        // genuine fraction, not a degenerate 1.0 passthrough.
        #expect(measuredJPEGRatio.low > 0 && measuredJPEGRatio.low < 1)
        // The measured ratio is real compression output, not coincidentally
        // equal to Tier 1's hand-picked heuristic range boundaries.
        #expect(measuredJPEGRatio != SavingsEstimator.defaultRatios[.jpeg])

        let libraryJPEGBytes: Int64 = 10 * 1_000 * 1_000 * 1_000
        let heuristicEstimate = SavingsEstimator.estimate(
            compressibleBytesByCodec: [.jpeg: libraryJPEGBytes],
            ratios: SavingsEstimator.defaultRatios
        )
        let calibratedEstimate = SavingsEstimator.estimate(
            compressibleBytesByCodec: [.jpeg: libraryJPEGBytes],
            ratios: measuredRatios
        )

        // The confirmation number (the `Estimate` from `estimate(...)`)
        // genuinely shifts once calibration's measured ratio replaces the
        // heuristic table — same `estimate` function, different ratio
        // table, different projected size.
        let estimatesDiffer = calibratedEstimate.estimatedBytesLow != heuristicEstimate.estimatedBytesLow
            || calibratedEstimate.estimatedBytesHigh != heuristicEstimate.estimatedBytesHigh
        #expect(estimatesDiffer)
    }

    // MARK: - 2. Edge case: a sample item that fails to compress is skipped,
    // not crashed on, and doesn't corrupt another codec's ratio in the same
    // batch.

    @Test func failedSampleIsSkippedWithoutCorruptingOtherCodecsInBatch() throws {
        let tempDir = makeScratchDirectory()
        let destDir = makeScratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let compressor = ImageCompressor(tempDirectory: tempDir)

        // Ground truth: compress the good fixture directly (outside
        // `calibrate`) to know the expected ratio independently.
        let goodSource = fixtureURL("happy_path_fixture", extension: "jpg")
        guard case .success(let groundTruth) = compressor.compress(
            sourceURL: goodSource, localIdentifier: "ground-truth-good", destinationDirectory: destDir
        ) else {
            Issue.record("expected the good fixture to compress successfully for ground truth")
            return
        }
        let expectedRatio = Double(groundTruth.outputByteSize) / Double(groundTruth.inputByteSize)

        let corruptSource = fixtureURL("corrupt_fixture", extension: "jpg")
        let corruptAsset = makeCompressibleAsset(id: "corrupt-1", codec: .jpeg)
        let goodAsset = makeCompressibleAsset(id: "good-1", codec: .png)

        let measuredRatios = SavingsEstimator.calibrate(
            sample: [
                (asset: corruptAsset, sourceURL: corruptSource),
                (asset: goodAsset, sourceURL: goodSource),
            ],
            compressor: compressor,
            destinationDirectory: destDir
        )

        // The corrupt sample's codec has zero successful samples — absent,
        // not a crash, not a fabricated ratio.
        #expect(measuredRatios[.jpeg] == nil)

        // The other codec in the same batch is unaffected by the corrupt
        // item's failure — its ratio matches the independently-computed
        // ground truth exactly.
        guard let pngRatio = measuredRatios[.png] else {
            Issue.record("expected a measured .png ratio despite the other sample failing")
            return
        }
        #expect(pngRatio == .fixed(expectedRatio))
    }

    // MARK: - 3. Edge case: multiple samples of the same codec with
    // different measured ratios produce a min/max spread, not an averaged
    // (spread-hiding) single value.
    //
    // Design choice: `RatioRange.low`/`.high` for a calibrated codec are the
    // min/max *observed* ratio across that codec's successful samples — an
    // honest empirical spread — rather than an average. An average would
    // hide exactly how much the measured ratio varied across the sample,
    // which is the opposite of the plan's "report a range, not false
    // precision" instruction applied to Tier 2's own measurement noise.

    @Test func multipleSamplesOfSameCodecYieldMinMaxSpreadNotAverage() throws {
        let tempDir = makeScratchDirectory()
        let destDir = makeScratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let compressor = ImageCompressor(tempDirectory: tempDir)

        let sourceA = fixtureURL("happy_path_fixture", extension: "jpg")
        let sourceB = fixtureURL("gps_exif_fixture", extension: "jpg")

        // Ground truth ratios, computed directly (outside `calibrate`) so
        // the assertions below don't depend on `calibrate`'s own math.
        guard case .success(let resultA) = compressor.compress(
            sourceURL: sourceA, localIdentifier: "ground-truth-a", destinationDirectory: destDir
        ), case .success(let resultB) = compressor.compress(
            sourceURL: sourceB, localIdentifier: "ground-truth-b", destinationDirectory: destDir
        ) else {
            Issue.record("expected both fixtures to compress successfully for ground truth")
            return
        }
        let ratioA = Double(resultA.outputByteSize) / Double(resultA.inputByteSize)
        let ratioB = Double(resultB.outputByteSize) / Double(resultB.inputByteSize)

        let assetA = makeCompressibleAsset(id: "same-codec-a", codec: .jpeg)
        let assetB = makeCompressibleAsset(id: "same-codec-b", codec: .jpeg)

        let measuredRatios = SavingsEstimator.calibrate(
            sample: [
                (asset: assetA, sourceURL: sourceA),
                (asset: assetB, sourceURL: sourceB),
            ],
            compressor: compressor,
            destinationDirectory: destDir
        )

        guard let jpegRange = measuredRatios[.jpeg] else {
            Issue.record("expected a measured .jpeg ratio range from two successful samples")
            return
        }

        let expectedLow = min(ratioA, ratioB)
        let expectedHigh = max(ratioA, ratioB)

        #expect(jpegRange.low == expectedLow)
        #expect(jpegRange.high == expectedHigh)

        // The two fixtures are different sizes/content, so the two ground
        // truth ratios are expected to genuinely differ — otherwise this
        // test wouldn't actually exercise the min/max-spread behavior it
        // claims to.
        #expect(ratioA != ratioB)

        // An averaging design would hide the spread; assert the range this
        // implementation returns is not collapsed to a single value here,
        // proving the spread survived into the returned `RatioRange`.
        #expect(jpegRange.low != jpegRange.high)
    }

    // MARK: - 4. Edge case: a codec with zero successful samples is absent
    // from the returned ratio table, and `estimate` handles the missing
    // entry exactly as it already does for Tier 1 (assume no savings).

    @Test func codecWithZeroSuccessfulSamplesIsAbsentAndEstimateAssumesNoSavings() throws {
        let tempDir = makeScratchDirectory()
        let destDir = makeScratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let corruptSource = fixtureURL("corrupt_fixture", extension: "jpg")
        let corruptAsset = makeCompressibleAsset(id: "corrupt-only", codec: .jpeg)
        let compressor = ImageCompressor(tempDirectory: tempDir)

        let measuredRatios = SavingsEstimator.calibrate(
            sample: [(asset: corruptAsset, sourceURL: corruptSource)],
            compressor: compressor,
            destinationDirectory: destDir
        )

        // Zero successful samples for .jpeg — absent, not fabricated.
        #expect(measuredRatios[.jpeg] == nil)
        #expect(measuredRatios.isEmpty)

        // `estimate` falls back to its existing "no known ratio, assume no
        // savings" behavior for the missing codec — this should just work
        // via `estimate`'s existing logic, verified here rather than
        // asserted by inspection.
        let bytes: Int64 = 1_000
        let estimate = SavingsEstimator.estimate(
            compressibleBytesByCodec: [.jpeg: bytes],
            ratios: measuredRatios
        )

        #expect(estimate.estimatedBytesLow == bytes)
        #expect(estimate.estimatedBytesHigh == bytes)
        #expect(estimate.savingsBytesLow == 0)
        #expect(estimate.savingsBytesHigh == 0)
    }
}
