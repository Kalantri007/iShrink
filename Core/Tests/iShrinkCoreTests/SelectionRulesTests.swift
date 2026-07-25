import Testing
import Foundation
@testable import iShrinkCore

// iShrink Phase 1 plan, U8 "App UI" — `SelectionRules` test scenarios.
// Shares the `makeRecord` top-level test helper defined in
// `LibraryScannerTests.swift` (same test target).

@Suite struct SelectionRulesTests {

    private func makeAsset(
        id: String,
        codec: MediaCodec,
        byteSize: Int64,
        creationDate: Date?,
        eligibility: ClassificationEligibility
    ) -> ClassifiedAsset {
        ClassifiedAsset(
            record: makeRecord(id: id, byteSize: byteSize, creationDate: creationDate),
            codec: codec,
            isLivePhoto: false,
            isHDR: false,
            eligibility: eligibility
        )
    }

    // MARK: - 1. Happy path: a "large + old" filter selects exactly the
    // matching records (plan: "videos > 200 MB, older than 2 years" over a
    // fixture set — adapted here to a size/age filter over `ClassifiedAsset`
    // per the plan's own note that the "videos" wording is illustrative).

    @Test func filterBySizeAndAgeSelectsExactlyMatchingRecords() {
        let now = Date()
        let twoYearsAgo = Calendar.current.date(byAdding: .year, value: -2, to: now)!
        let threeYearsAgo = Calendar.current.date(byAdding: .year, value: -3, to: now)!
        let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: now)!

        let bigOld = makeAsset(
            id: "big-old", codec: .jpeg, byteSize: 300_000_000, creationDate: threeYearsAgo,
            eligibility: .compressible
        )
        let bigRecent = makeAsset(
            id: "big-recent", codec: .jpeg, byteSize: 300_000_000, creationDate: oneYearAgo,
            eligibility: .compressible
        )
        let smallOld = makeAsset(
            id: "small-old", codec: .jpeg, byteSize: 10_000_000, creationDate: threeYearsAgo,
            eligibility: .compressible
        )
        // Would match size+age, but isn't `.compressible` — must never be
        // selected regardless of the filter (excluded wins).
        let excludedBigOld = makeAsset(
            id: "excluded-big-old", codec: .rawOrProRaw, byteSize: 300_000_000, creationDate: threeYearsAgo,
            eligibility: .excluded(.rawMaster)
        )

        let classified = [bigOld, bigRecent, smallOld, excludedBigOld]
        let filter = SelectionFilter(minimumBytes: 200_000_000, createdBefore: twoYearsAgo)

        let selected = SelectionRules.apply(filter, to: classified)

        #expect(selected.map(\.record.localIdentifier) == ["big-old"])
    }

    // MARK: - 2a. Edge case: a filter matching zero of a non-empty
    // compressible library -> "adjust filter" messaging.

    @Test func filterMatchingNothingReportsAdjustFilterMessage() {
        let compressible = makeAsset(
            id: "small", codec: .jpeg, byteSize: 1_000, creationDate: Date(), eligibility: .compressible
        )
        let filter = SelectionFilter(minimumBytes: 999_999_999)

        let reason = SelectionRules.zeroSelectionReason(filter: filter, classified: [compressible])

        #expect(reason == .filterMatchesNothing)
    }

    // MARK: - 2b. Edge case: an all-HEIC/RAW/iCloud library with zero
    // compressible assets -> "nothing compressible" messaging (distinct copy
    // from 2a; both disable Start).

    @Test func libraryWithNoCompressibleAssetsReportsNothingCompressibleMessage() {
        let heic = makeAsset(
            id: "heic", codec: .heic, byteSize: 1_000, creationDate: nil, eligibility: .excluded(.alreadyHeic)
        )
        let raw = makeAsset(
            id: "raw", codec: .rawOrProRaw, byteSize: 1_000, creationDate: nil, eligibility: .excluded(.rawMaster)
        )
        let iCloudOnly = makeAsset(
            id: "icloud", codec: .jpeg, byteSize: 1_000, creationDate: nil, eligibility: .excluded(.iCloudOnly)
        )

        // No filter at all — the library itself has nothing compressible,
        // independent of any filter.
        let reason = SelectionRules.zeroSelectionReason(filter: .none, classified: [heic, raw, iCloudOnly])

        #expect(reason == .libraryHasNothingCompressible)
    }

    @Test func theTwoZeroSelectionMessagesReadDifferently() {
        let filterMessage = ZeroSelectionReason.filterMatchesNothing.message
        let libraryMessage = ZeroSelectionReason.libraryHasNothingCompressible.message

        #expect(filterMessage != libraryMessage)
        #expect(!filterMessage.isEmpty)
        #expect(!libraryMessage.isEmpty)
    }

    // MARK: - 3. Edge case: the smart default excludes all `.excluded(reason)`
    // assets automatically, for every reason the enum has.

    @Test func smartDefaultExcludesAllExcludedReasonAssetsAutomatically() {
        let compressible = makeAsset(
            id: "ok", codec: .jpeg, byteSize: 1_000, creationDate: nil, eligibility: .compressible
        )
        let excludedOnes = ExclusionReason.allCases.enumerated().map { index, reason in
            makeAsset(
                id: "excluded-\(index)", codec: .jpeg, byteSize: 1_000, creationDate: nil,
                eligibility: .excluded(reason)
            )
        }
        let analyticsOnlyVideo = makeAsset(
            id: "video", codec: .h264, byteSize: 1_000, creationDate: nil, eligibility: .analyticsOnly
        )

        let classified = [compressible] + excludedOnes + [analyticsOnlyVideo]
        let selected = SelectionRules.smartDefault(classified)

        #expect(selected.map(\.record.localIdentifier) == ["ok"])
        // Sanity: this fixture actually contains every exclusion reason, so
        // the assertion above genuinely exercises all of them, not just a
        // subset.
        #expect(excludedOnes.count == ExclusionReason.allCases.count)
    }

    // MARK: - 5. Integration: confirmation numbers equal the estimator
    // output for the selected subset, not the whole library.

    @Test func confirmationSummaryReflectsSelectedSubsetNotWholeLibrary() {
        let selectedAsset = makeAsset(
            id: "selected", codec: .jpeg, byteSize: 10_000_000, creationDate: nil, eligibility: .compressible
        )
        let unselectedAsset = makeAsset(
            id: "unselected", codec: .png, byteSize: 50_000_000, creationDate: nil, eligibility: .compressible
        )

        let selection = [selectedAsset]
        let wholeLibrary = [selectedAsset, unselectedAsset]

        let summary = SelectionRules.confirmationSummary(for: selection)
        let expectedEstimate = SavingsEstimator.estimate(compressibleBytesByCodec: [.jpeg: 10_000_000])

        #expect(summary.itemCount == 1)
        #expect(summary.currentBytes == 10_000_000)
        #expect(summary.estimate == expectedEstimate)

        // Proves the summary is genuinely scoped to the selection, not the
        // whole library — a buggy implementation that read from
        // `wholeLibrary` instead of `selection` would produce the same
        // numbers as the whole-library summary below; this asserts they
        // actually differ.
        let wholeLibrarySummary = SelectionRules.confirmationSummary(for: wholeLibrary)
        let itemCountsDiffer = wholeLibrarySummary.itemCount != summary.itemCount
        let bytesDiffer = wholeLibrarySummary.currentBytes != summary.currentBytes
        let estimatesDiffer = wholeLibrarySummary.estimate != summary.estimate

        #expect(itemCountsDiffer)
        #expect(bytesDiffer)
        #expect(estimatesDiffer)
    }
}
