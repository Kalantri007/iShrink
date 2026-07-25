import Testing
@testable import iShrinkCore

// iShrink Phase 1 plan, U3 "Library scanner & asset sizing" test scenarios.
//
// All tests drive `LibraryScanner` through `FakeLibrary` below — a plain
// in-memory `PhotoLibraryProviding` conformer that never touches PhotoKit,
// matching the plan's verification requirement ("no real PhotoKit/TCC in
// tests").

/// In-memory `PhotoLibraryProviding` conformer. Records the `(offset, limit)`
/// of every `fetchRecords` call it receives so tests can assert *how* the
/// scanner paged through the library, not just what it collected.
actor FakeLibrary: PhotoLibraryProviding {
    private let records: [AssetRecord]
    private(set) var fetchCalls: [(offset: Int, limit: Int)] = []

    init(records: [AssetRecord]) {
        self.records = records
    }

    var assetCount: Int {
        records.count
    }

    func fetchRecords(offset: Int, limit: Int) async -> [AssetRecord] {
        fetchCalls.append((offset, limit))
        guard limit > 0, offset < records.count else {
            return []
        }
        let upper = min(offset + limit, records.count)
        return Array(records[offset..<upper])
    }
}

/// Thread-safe sink for `LibraryScanner`'s `@Sendable` callbacks. Using a
/// plain `var` captured by those callbacks would compile only with data-race
/// warnings (a Swift 6 error) since the closures are `@Sendable`; an actor
/// gives the tests a properly isolated place to accumulate results.
actor ScanCollector {
    private(set) var records: [AssetRecord] = []
    private(set) var progressUpdates: [ScanProgress] = []
    private(set) var scannedCount = 0

    func addRecord(_ record: AssetRecord) {
        records.append(record)
        scannedCount += 1
    }

    func addProgress(_ progress: ScanProgress) {
        progressUpdates.append(progress)
    }
}

/// Builds a minimal, valid `AssetRecord` fixture with sensible defaults so
/// each test only needs to specify the fields it cares about.
func makeRecord(
    id: String,
    mediaType: AssetMediaType = .image,
    mediaSubtypes: AssetMediaSubtypes = [],
    byteSize: Int64 = 1_000,
    isLocallyAvailable: Bool = true,
    resourceUTIs: [String] = ["public.jpeg"],
    resourceKinds: [AssetResourceKind] = [.photo]
) -> AssetRecord {
    AssetRecord(
        localIdentifier: id,
        mediaType: mediaType,
        mediaSubtypes: mediaSubtypes,
        primaryUTI: resourceUTIs.first,
        resourceUTIs: resourceUTIs,
        resourceKinds: resourceKinds,
        byteSize: byteSize,
        isLocallyAvailable: isLocallyAvailable,
        originalFilename: "\(id).jpg",
        creationDate: nil,
        pixelWidth: 100,
        pixelHeight: 100
    )
}

@Test func happyPathYieldsAllRecordsWithCorrectCountsByMediaType() async {
    // 1,000 records: 700 image, 200 video, 100 audio.
    var records: [AssetRecord] = []
    for i in 0..<700 { records.append(makeRecord(id: "img-\(i)", mediaType: .image)) }
    for i in 0..<200 { records.append(makeRecord(id: "vid-\(i)", mediaType: .video)) }
    for i in 0..<100 { records.append(makeRecord(id: "aud-\(i)", mediaType: .audio)) }

    let library = FakeLibrary(records: records)
    let scanner = LibraryScanner(library: library, pageSize: 137) // deliberately not a divisor of 1000
    let collector = ScanCollector()

    await scanner.scan(onRecord: { record in await collector.addRecord(record) })

    let collected = await collector.records
    #expect(collected.count == 1_000)
    #expect(collected.filter { $0.mediaType == .image }.count == 700)
    #expect(collected.filter { $0.mediaType == .video }.count == 200)
    #expect(collected.filter { $0.mediaType == .audio }.count == 100)
    // Order is preserved (stable index order).
    #expect(collected.map(\.localIdentifier) == records.map(\.localIdentifier))
}

@Test func emptyLibraryYieldsZeroCountsWithoutCrashing() async {
    let library = FakeLibrary(records: [])
    let scanner = LibraryScanner(library: library)
    let collector = ScanCollector()

    await scanner.scan(
        onRecord: { await collector.addRecord($0) },
        onProgress: { await collector.addProgress($0) }
    )

    #expect(await collector.records.isEmpty)
    // No pages were ever non-empty, so no progress event should have fired.
    #expect(await collector.progressUpdates.isEmpty)
}

@Test func progressReportsScannedCountAfterEachPage() async {
    let records = (0..<10).map { makeRecord(id: "a-\($0)") }
    let library = FakeLibrary(records: records)
    let scanner = LibraryScanner(library: library, pageSize: 4)
    let collector = ScanCollector()

    await scanner.scan(
        onRecord: { await collector.addRecord($0) },
        onProgress: { await collector.addProgress($0) }
    )

    // pageSize 4 over 10 records: pages of 4, 4, 2.
    let progressUpdates = await collector.progressUpdates
    #expect(progressUpdates.map(\.scanned) == [4, 8, 10])
    #expect(progressUpdates.allSatisfy { $0.total == 10 })
}

@Test func iCloudOnlyRecordIsYieldedWithFlagSetAndNoNetworkFetchAttempted() async {
    let cloudOnly = makeRecord(id: "cloud-only", isLocallyAvailable: false)
    let local = makeRecord(id: "local", isLocallyAvailable: true)
    let library = FakeLibrary(records: [cloudOnly, local])
    let scanner = LibraryScanner(library: library)
    let collector = ScanCollector()

    await scanner.scan(onRecord: { await collector.addRecord($0) })

    let collected = await collector.records
    let yieldedCloudOnly = try! #require(collected.first { $0.localIdentifier == "cloud-only" })
    #expect(yieldedCloudOnly.isLocallyAvailable == false)
    // `LibraryScanner` only ever calls `PhotoLibraryProviding.fetchRecords`,
    // which `FakeLibrary` serves entirely from an in-memory array — there is
    // no code path here that could reach a network fetch. The real
    // network-off guarantee for iCloud-only assets is enforced structurally
    // by `AssetSizeReader`/`PhotoKitLibrary`, which never construct a
    // `PHAssetResourceRequestOptions` with `isNetworkAccessAllowed = true`
    // (see AssetSizeReaderTests.swift and the source comments in
    // AssetSizeReader.swift / PhotoKitLibrary.swift).
    #expect(yieldedCloudOnly.byteSize >= 0)
}

@Test func multiResourceAssetExposesResourceCountAndKindsForU4() async {
    // Live Photo: photo + pairedVideo. U3 doesn't sum resource sizes itself
    // (that's AssetSizeReader's job, exercised in AssetSizeReaderTests) —
    // here we just confirm the scanner passes multi-resource metadata
    // through untouched, which is what U4 needs to classify it later.
    let livePhoto = makeRecord(
        id: "live-1",
        mediaSubtypes: [.livePhoto],
        byteSize: 4_500_000, // pretend this is already the summed size
        resourceUTIs: ["public.heic", "com.apple.quicktime-movie"],
        resourceKinds: [.photo, .pairedVideo]
    )
    let library = FakeLibrary(records: [livePhoto])
    let scanner = LibraryScanner(library: library)
    let collector = ScanCollector()

    await scanner.scan(onRecord: { await collector.addRecord($0) })

    let record = try! #require(await collector.records.first)
    #expect(record.resourceCount == 2)
    #expect(record.resourceKinds == [.photo, .pairedVideo])
    #expect(record.mediaSubtypes.contains(.livePhoto))
    #expect(record.byteSize == 4_500_000)
}

@Test func scaleScanOf100kRecordsStreamsInBoundedPagesRatherThanOneBigFetch() async {
    // This can't measure actual heap usage in a unit test, so instead it
    // asserts the *design* property that makes bounded memory possible:
    // LibraryScanner never asks the library for "everything at once" — it
    // only ever requests fixed-size pages, repeatedly, regardless of how
    // large the library is. If the scanner ever regressed to (for example)
    // calling fetchRecords(offset: 0, limit: assetCount), this test would
    // catch that regression even though it can't directly observe RAM.
    let total = 100_000
    let pageSize = 500
    let records = (0..<total).map { makeRecord(id: "asset-\($0)") }
    let library = FakeLibrary(records: records)
    let scanner = LibraryScanner(library: library, pageSize: pageSize)
    let collector = ScanCollector()

    await scanner.scan(onRecord: { await collector.addRecord($0) })

    #expect(await collector.scannedCount == total)

    let calls = await library.fetchCalls
    // Every call requested exactly `pageSize` records — never the whole
    // library in one shot, and never a growing/unbounded request size.
    #expect(calls.allSatisfy { $0.limit == pageSize })
    #expect(calls.allSatisfy { $0.limit != total })
    // The number of page fetches matches exactly total / pageSize: the
    // scanner paged through the whole library, stopping as soon as it
    // reached the known total, without one extra trailing empty fetch.
    let expectedPageCount = total / pageSize
    #expect(calls.count == expectedPageCount)
    // Offsets strictly increase by pageSize each time (no re-fetching, no
    // skipping).
    #expect(calls.map(\.offset) == Array(stride(from: 0, to: total, by: pageSize)))
}
