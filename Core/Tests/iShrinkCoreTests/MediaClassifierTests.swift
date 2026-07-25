import Testing
@testable import iShrinkCore

// iShrink Phase 1 plan, U4 "Media classifier & storage analytics" test
// scenarios (MediaClassifier half).
//
// Reuses `makeRecord(...)` from LibraryScannerTests.swift (same test
// target) for fixtures, passing only the fields each scenario cares about.

/// Deterministic `GainMapProbing` fake: always answers the injected fixed
/// result, and records how many times it was called so tests can also
/// assert the classifier *doesn't* probe when it shouldn't have to (bounding
/// classification cost, per the plan).
actor FakeGainMapProbe: GainMapProbing {
    private let result: Bool
    private(set) var callCount = 0

    init(hasGainMap: Bool) {
        self.result = hasGainMap
    }

    func hasGainMap(for record: AssetRecord) async -> Bool {
        callCount += 1
        return result
    }
}

// MARK: - Happy path

@Test func jpegRecordClassifiesAsCompressible() async {
    let classifier = MediaClassifier()
    let record = makeRecord(id: "jpeg-1", resourceUTIs: ["public.jpeg"])

    let classified = await classifier.classify(record)

    #expect(classified.codec == .jpeg)
    #expect(classified.eligibility == .compressible)
    #expect(!classified.isLivePhoto)
    #expect(!classified.isHDR)
}

@Test func h264VideoRecordIsAnalyticsOnlyNotCompressible() async {
    let classifier = MediaClassifier()
    let record = makeRecord(
        id: "vid-1",
        mediaType: .video,
        resourceUTIs: ["public.mpeg-4"],
        resourceKinds: [.video]
    )

    let classified = await classifier.classify(record)

    #expect(classified.codec == .h264)
    #expect(classified.eligibility == .analyticsOnly)
}

// MARK: - RAW / ProRAW

@Test func adobeRawUTIClassifiesAsRawMasterExcluded() async {
    let classifier = MediaClassifier()
    let record = makeRecord(id: "raw-adobe", resourceUTIs: ["com.adobe.raw-image"])

    let classified = await classifier.classify(record)

    #expect(classified.codec == .rawOrProRaw)
    #expect(classified.eligibility == .excluded(.rawMaster))
}

@Test func vendorRawUTIClassifiesAsRawMasterExcluded() async {
    // Any vendor RAW UTI should be caught by the single
    // `conforms(to: .rawImage)` check, not just Adobe's.
    let classifier = MediaClassifier()
    let record = makeRecord(id: "raw-sony", resourceUTIs: ["com.sony.arw-raw-image"])

    let classified = await classifier.classify(record)

    #expect(classified.codec == .rawOrProRaw)
    #expect(classified.eligibility == .excluded(.rawMaster))
}

@Test func rawAssetNeverProbesForGainMap() async {
    // Plan: "skip the probe entirely for RAW/video ... assets" — bounding
    // classification cost. A RAW asset should never reach the gain-map
    // probe at all.
    let probe = FakeGainMapProbe(hasGainMap: true)
    let classifier = MediaClassifier(gainMapProbe: probe)
    let record = makeRecord(id: "raw-1", resourceUTIs: ["com.adobe.raw-image"])

    _ = await classifier.classify(record)

    #expect(await probe.callCount == 0)
}

@Test func videoAssetNeverProbesForGainMap() async {
    let probe = FakeGainMapProbe(hasGainMap: true)
    let classifier = MediaClassifier(gainMapProbe: probe)
    let record = makeRecord(id: "vid-1", mediaType: .video, resourceUTIs: ["public.mpeg-4"])

    _ = await classifier.classify(record)

    #expect(await probe.callCount == 0)
}

// MARK: - HDR

@Test func hdrSubtypeClassifiesAsHDRUnpreservableExcluded() async {
    let classifier = MediaClassifier()
    let record = makeRecord(id: "hdr-subtype", mediaSubtypes: [.hdr], resourceUTIs: ["public.jpeg"])

    let classified = await classifier.classify(record)

    #expect(classified.isHDR)
    #expect(classified.eligibility == .excluded(.hdrUnpreservable))
}

@Test func hdrSubtypeSkipsGainMapProbeEntirely() async {
    // When the subtype already says HDR, there's no need to pay for the
    // probe call.
    let probe = FakeGainMapProbe(hasGainMap: false)
    let classifier = MediaClassifier(gainMapProbe: probe)
    let record = makeRecord(id: "hdr-subtype", mediaSubtypes: [.hdr], resourceUTIs: ["public.jpeg"])

    _ = await classifier.classify(record)

    #expect(await probe.callCount == 0)
}

@Test func gainMapWithoutSubtypeStillClassifiesAsHDRUnpreservableExcluded() async {
    // This is the under-detection case R5 depends on: no `.hdr` subtype,
    // but the injected gain-map probe reports true. Uses a HEIC still
    // (real-world Apple HDR gain-map photos are commonly HEIC) to also
    // prove HDR is checked *before* the already-HEIC exclusion — otherwise
    // this would misreport `.excluded(.alreadyHeic)` instead.
    let probe = FakeGainMapProbe(hasGainMap: true)
    let classifier = MediaClassifier(gainMapProbe: probe)
    let record = makeRecord(id: "gainmap-1", mediaSubtypes: [], resourceUTIs: ["public.heic"])

    let classified = await classifier.classify(record)

    #expect(classified.isHDR)
    #expect(classified.eligibility == .excluded(.hdrUnpreservable))
    #expect(await probe.callCount == 1)
}

@Test func noGainMapAndNoSubtypeIsNotHDR() async {
    let probe = FakeGainMapProbe(hasGainMap: false)
    let classifier = MediaClassifier(gainMapProbe: probe)
    let record = makeRecord(id: "plain-jpeg", resourceUTIs: ["public.jpeg"])

    let classified = await classifier.classify(record)

    #expect(!classified.isHDR)
    #expect(classified.eligibility == .compressible)
}

@Test func nilGainMapProbeFallsBackToSubtypeOnlyDetection() async {
    // No probe injected at all: HDR detection is subtype-only, still
    // correct (just narrower) — must not crash.
    let classifier = MediaClassifier(gainMapProbe: nil)
    let record = makeRecord(id: "plain-jpeg-no-probe", resourceUTIs: ["public.jpeg"])

    let classified = await classifier.classify(record)

    #expect(!classified.isHDR)
    #expect(classified.eligibility == .compressible)
}

// MARK: - Live Photo

@Test func livePhotoWithJPEGStillIsExcludedNotExportedAsOrphanStill() async {
    let classifier = MediaClassifier()
    let record = makeRecord(
        id: "live-1",
        mediaSubtypes: [.livePhoto],
        resourceUTIs: ["public.jpeg", "com.apple.quicktime-movie"],
        resourceKinds: [.photo, .pairedVideo]
    )

    let classified = await classifier.classify(record)

    #expect(classified.isLivePhoto)
    #expect(classified.eligibility == .excluded(.livePhoto))
}

// MARK: - Already HEIC

@Test func alreadyHeicStillImageIsExcluded() async {
    let classifier = MediaClassifier()
    let record = makeRecord(id: "heic-1", resourceUTIs: ["public.heic"])

    let classified = await classifier.classify(record)

    #expect(classified.codec == .heic)
    #expect(classified.eligibility == .excluded(.alreadyHeic))
}

// MARK: - iCloud-only wins

@Test func iCloudOnlyExcludesRegardlessOfCodec() async {
    // A JPEG that's also iCloud-only: iCloud wins over everything else.
    let classifier = MediaClassifier()
    let record = makeRecord(id: "icloud-1", isLocallyAvailable: false, resourceUTIs: ["public.jpeg"])

    let classified = await classifier.classify(record)

    #expect(classified.eligibility == .excluded(.iCloudOnly))
}

@Test func iCloudOnlyWinsEvenOverHDR() async {
    // iCloud-only should win even when the asset would otherwise also be
    // excluded for a different reason (HDR here) — proves ordering, not
    // just "iCloud alone works".
    let classifier = MediaClassifier()
    let record = makeRecord(
        id: "icloud-hdr-1",
        mediaSubtypes: [.hdr],
        isLocallyAvailable: false,
        resourceUTIs: ["public.jpeg"]
    )

    let classified = await classifier.classify(record)

    #expect(classified.eligibility == .excluded(.iCloudOnly))
}

// MARK: - Edited photo

@Test func editedPhotoWithAdjustmentDataIsExcluded() async {
    let classifier = MediaClassifier()
    let record = makeRecord(
        id: "edited-1",
        resourceUTIs: ["public.jpeg", "com.apple.some-adjustment-data"],
        resourceKinds: [.photo, .adjustmentData]
    )

    let classified = await classifier.classify(record)

    #expect(classified.eligibility == .excluded(.editedPhoto))
}
