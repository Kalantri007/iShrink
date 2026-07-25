import Testing
@testable import iShrinkCore

// iShrink Phase 1 plan, U4 "Media classifier & storage analytics" test
// scenarios (StorageAnalytics half).
//
// Builds `ClassifiedAsset` fixtures directly (rather than running them
// through `MediaClassifier`) so these tests characterize the *aggregation*
// math in isolation from classification decisions, which are already
// covered by MediaClassifierTests.swift.

private func makeClassified(
    id: String,
    codec: MediaCodec,
    bytes: Int64,
    eligibility: ClassificationEligibility,
    filename: String? = nil
) -> ClassifiedAsset {
    let record = makeRecord(id: id, byteSize: bytes, resourceUTIs: ["public.jpeg"])
    return ClassifiedAsset(
        record: record,
        codec: codec,
        isLivePhoto: false,
        isHDR: false,
        eligibility: eligibility
    )
}

@Test func mixedFixtureSetProducesCorrectCodecBytesTotalsAndSplit() {
    let classified: [ClassifiedAsset] = [
        makeClassified(id: "j1", codec: .jpeg, bytes: 1_000, eligibility: .compressible, filename: "j1.jpg"),
        makeClassified(id: "j2", codec: .jpeg, bytes: 3_000, eligibility: .compressible, filename: "j2.jpg"),
        makeClassified(id: "p1", codec: .png, bytes: 500, eligibility: .compressible, filename: "p1.png"),
        makeClassified(id: "h1", codec: .heic, bytes: 2_000, eligibility: .excluded(.alreadyHeic), filename: "h1.heic"),
        makeClassified(id: "r1", codec: .rawOrProRaw, bytes: 10_000, eligibility: .excluded(.rawMaster), filename: "r1.dng"),
        makeClassified(id: "hd1", codec: .jpeg, bytes: 4_000, eligibility: .excluded(.hdrUnpreservable), filename: "hd1.jpg"),
        makeClassified(id: "ic1", codec: .jpeg, bytes: 1_500, eligibility: .excluded(.iCloudOnly), filename: "ic1.jpg"),
        makeClassified(id: "lp1", codec: .jpeg, bytes: 2_500, eligibility: .excluded(.livePhoto), filename: "lp1.jpg"),
        makeClassified(id: "ed1", codec: .jpeg, bytes: 1_200, eligibility: .excluded(.editedPhoto), filename: "ed1.jpg"),
        makeClassified(id: "v1", codec: .h264, bytes: 50_000, eligibility: .analyticsOnly, filename: "v1.mp4"),
        makeClassified(id: "v2", codec: .hevc, bytes: 60_000, eligibility: .analyticsOnly, filename: "v2.mov"),
    ]

    let analytics = StorageAnalytics.aggregate(classified, topN: 3)

    // Totals.
    #expect(analytics.totalCount == 11)
    let expectedTotal: Int64 = 1_000 + 3_000 + 500 + 2_000 + 10_000 + 4_000 + 1_500 + 2_500 + 1_200 + 50_000 + 60_000
    #expect(analytics.totalBytes == expectedTotal)

    // Compressible vs excluded split.
    #expect(analytics.compressibleCount == 3)
    #expect(analytics.compressibleBytes == 1_000 + 3_000 + 500)

    #expect(analytics.analyticsOnlyCount == 2)
    #expect(analytics.analyticsOnlyBytes == 50_000 + 60_000)

    #expect(analytics.excludedCountByReason[.alreadyHeic] == 1)
    #expect(analytics.excludedBytesByReason[.alreadyHeic] == 2_000)
    #expect(analytics.excludedCountByReason[.rawMaster] == 1)
    #expect(analytics.excludedBytesByReason[.rawMaster] == 10_000)
    #expect(analytics.excludedCountByReason[.hdrUnpreservable] == 1)
    #expect(analytics.excludedBytesByReason[.hdrUnpreservable] == 4_000)
    #expect(analytics.excludedCountByReason[.iCloudOnly] == 1)
    #expect(analytics.excludedBytesByReason[.iCloudOnly] == 1_500)
    #expect(analytics.excludedCountByReason[.livePhoto] == 1)
    #expect(analytics.excludedBytesByReason[.livePhoto] == 2_500)
    #expect(analytics.excludedCountByReason[.editedPhoto] == 1)
    #expect(analytics.excludedBytesByReason[.editedPhoto] == 1_200)

    // Per-codec breakdown: jpeg appears across compressible+excluded
    // buckets, so its aggregate must sum across all of them.
    let jpegEntry = analytics.codecBreakdown.first { $0.codec == .jpeg }
    let expectedJPEGBytes: Int64 = 1_000 + 3_000 + 4_000 + 1_500 + 2_500 + 1_200
    #expect(jpegEntry?.count == 6) // j1, j2, hd1, ic1, lp1, ed1
    #expect(jpegEntry?.bytes == expectedJPEGBytes)

    let heicEntry = analytics.codecBreakdown.first { $0.codec == .heic }
    #expect(heicEntry?.count == 1)
    #expect(heicEntry?.bytes == 2_000)

    let rawEntry = analytics.codecBreakdown.first { $0.codec == .rawOrProRaw }
    #expect(rawEntry?.count == 1)
    #expect(rawEntry?.bytes == 10_000)

    // Top-N largest files (topN: 3) — descending by size:
    // v2 (60000), v1 (50000), r1 (10000).
    #expect(analytics.largestFiles.count == 3)
    #expect(analytics.largestFiles.map(\.localIdentifier) == ["v2", "v1", "r1"])
    #expect(analytics.largestFiles.map(\.bytes) == [60_000, 50_000, 10_000])

    // Reconciliation: every byte lands in exactly one of the three buckets.
    #expect(analytics.reconcilesToTotal)
    #expect(analytics.compressibleBytes + analytics.excludedBytesTotal + analytics.analyticsOnlyBytes == analytics.totalBytes)
}

@Test func excludedBytesPlusCompressibleBytesReconcileToTotalWithNoVideoPresent() {
    // The plan's literal reconciliation wording ("excluded-bytes-by-reason +
    // compressible-bytes == total-bytes") is a two-term equation; it
    // predates U4 introducing the third `.analyticsOnly` (video) bucket.
    // This fixture set has no video/analytics-only assets at all, so the
    // two-term equation holds exactly as written, independent of the more
    // general three-way `reconcilesToTotal` check exercised above.
    let classified: [ClassifiedAsset] = [
        makeClassified(id: "j1", codec: .jpeg, bytes: 2_000, eligibility: .compressible),
        makeClassified(id: "j2", codec: .jpeg, bytes: 3_000, eligibility: .compressible),
        makeClassified(id: "h1", codec: .heic, bytes: 1_000, eligibility: .excluded(.alreadyHeic)),
        makeClassified(id: "r1", codec: .rawOrProRaw, bytes: 7_000, eligibility: .excluded(.rawMaster)),
    ]

    let analytics = StorageAnalytics.aggregate(classified)

    #expect(analytics.analyticsOnlyBytes == 0)
    #expect(analytics.excludedBytesTotal + analytics.compressibleBytes == analytics.totalBytes)
}

@Test func emptyClassifiedSetProducesZeroedAnalyticsNoCrash() {
    let analytics = StorageAnalytics.aggregate([])

    #expect(analytics.totalCount == 0)
    #expect(analytics.totalBytes == 0)
    #expect(analytics.compressibleBytes == 0)
    #expect(analytics.analyticsOnlyBytes == 0)
    #expect(analytics.excludedBytesTotal == 0)
    #expect(analytics.largestFiles.isEmpty)
    #expect(analytics.codecBreakdown.isEmpty)
    #expect(analytics.reconcilesToTotal)
}

@Test func topNCappedBelowAvailableRecordsReturnsOnlyLargest() {
    let classified: [ClassifiedAsset] = [
        makeClassified(id: "a", codec: .jpeg, bytes: 100, eligibility: .compressible),
        makeClassified(id: "b", codec: .jpeg, bytes: 300, eligibility: .compressible),
        makeClassified(id: "c", codec: .jpeg, bytes: 200, eligibility: .compressible),
    ]

    let analytics = StorageAnalytics.aggregate(classified, topN: 1)

    #expect(analytics.largestFiles.count == 1)
    #expect(analytics.largestFiles.first?.localIdentifier == "b")
}
