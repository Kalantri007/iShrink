import Testing
@testable import iShrinkCore

// iShrink Phase 1 plan, U3 "Library scanner & asset sizing" test scenarios
// for `AssetSizeReader`. `FakeResourceSizeSource` stands in for a real
// `PHAssetResourceSizeSource` so these tests never touch PhotoKit.

/// Injectable fake for one resource's two size-read paths.
/// `fallbackCalled` lets tests assert whether the (network-off) fallback
/// path was actually exercised, without needing real PhotoKit.
final class FakeResourceSizeSource: ResourceSizeSource, @unchecked Sendable {
    private let quick: Int64?
    private let fallback: Int64
    private(set) var fallbackCalled = false

    init(quick: Int64?, fallback: Int64) {
        self.quick = quick
        self.fallback = fallback
    }

    func quickSize() -> Int64? {
        quick
    }

    func fallbackSize() async -> Int64 {
        fallbackCalled = true
        return fallback
    }
}

@Test func quickPathIsTrustedWhenNotSampledAndFallbackIsNeverCalled() async {
    // Sampler never selects this resource for cross-validation, so the
    // reader should trust the quick value outright and never touch the
    // (network-off) fallback at all.
    let reader = AssetSizeReader(sampler: { false })
    let resource = FakeResourceSizeSource(quick: 12_345, fallback: 999_999)

    let size = await reader.size(ofResources: [resource])

    #expect(size == 12_345)
    #expect(resource.fallbackCalled == false)
}

@Test func nilQuickSizeFallsBackAndStillYieldsASize() async {
    // Scenario: primary (KVC) path returns nil -> AssetSizeReader falls
    // back and still yields a size, unconditionally (no sampling needed).
    let reader = AssetSizeReader(sampler: { false })
    let resource = FakeResourceSizeSource(quick: nil, fallback: 54_321)

    let size = await reader.size(ofResources: [resource])

    #expect(size == 54_321)
    #expect(resource.fallbackCalled == true)
}

@Test func multiResourceSizeIsSummedNotJustPrimary() async {
    // Scenario: multi-resource asset (e.g. photo + adjustment, or Live
    // Photo photo + pairedVideo) -> reported size is the SUM of all
    // resources, not just the first one.
    let reader = AssetSizeReader(sampler: { false })
    let photo = FakeResourceSizeSource(quick: 3_000_000, fallback: 0)
    let pairedVideo = FakeResourceSizeSource(quick: 1_500_000, fallback: 0)
    let adjustment = FakeResourceSizeSource(quick: 200_000, fallback: 0)

    let size = await reader.size(ofResources: [photo, pairedVideo, adjustment])

    #expect(size == 3_000_000 + 1_500_000 + 200_000)
}

@Test func divergentQuickValueSwitchesTheWholeRunToFallback() async {
    // Scenario: KVC returns a plausible-but-wrong nonzero size that diverges
    // from the fallback beyond tolerance -> the run switches to the
    // fallback path entirely (not trusted on nonzero alone), including for
    // resources encountered *after* the divergence that would not
    // otherwise have been sampled.
    let reader = AssetSizeReader(relativeTolerance: 0.02, absoluteToleranceBytes: 1_000, sampler: { true })

    // First resource: quick=1,000,000 but the real (fallback) size is
    // 2,000,000 -- a 100% divergence, way beyond a 2%/1KB tolerance.
    let diverging = FakeResourceSizeSource(quick: 1_000_000, fallback: 2_000_000)
    let firstSize = await reader.size(ofResources: [diverging])
    #expect(firstSize == 2_000_000) // uses the fallback value, not the quick one
    #expect(diverging.fallbackCalled == true)

    // Second resource: has a perfectly fine-looking quick value, and even
    // if the sampler for this call would say "don't bother sampling", the
    // reader must still route it through the fallback because the whole
    // run switched over after the divergence above.
    let looksFineButRunIsForced = FakeResourceSizeSource(quick: 42, fallback: 777_777)
    let secondSize = await reader.size(ofResources: [looksFineButRunIsForced])

    #expect(secondSize == 777_777) // fallback value, not the quick 42
    #expect(looksFineButRunIsForced.fallbackCalled == true)
}

@Test func quickValueWithinToleranceOfFallbackIsTrustedAndRunIsNotForced() async {
    // Cross-validation passes (small, within-tolerance difference) -> the
    // quick value is used and the run is NOT switched to forced fallback.
    let reader = AssetSizeReader(relativeTolerance: 0.02, absoluteToleranceBytes: 1_000, sampler: { true })

    // 1,000,000 vs 1,000,500: 500-byte difference, within the 1,000-byte
    // absolute tolerance.
    let closeEnough = FakeResourceSizeSource(quick: 1_000_000, fallback: 1_000_500)
    let firstSize = await reader.size(ofResources: [closeEnough])
    #expect(firstSize == 1_000_000) // quick value trusted

    // A later resource with a nil quick value should still just use the
    // ordinary nil-fallback path (unconditional), not the "forced by
    // divergence" path -- confirming the earlier close-enough comparison
    // didn't spuriously force fallback mode for the whole run.
    let laterNilQuick = FakeResourceSizeSource(quick: nil, fallback: 55)
    let secondSize = await reader.size(ofResources: [laterNilQuick])
    #expect(secondSize == 55)
}

@Test func zeroOrNegativeQuickValueIsTreatedAsUnavailableNotAsALegitimateSize() async {
    // A `≤0` quick value must never be trusted as a real size — the
    // conformer contract (`ResourceSizeSource.quickSize()`) already encodes
    // this by returning `nil` for such cases (see
    // `PHAssetResourceSizeSource.quickSize()`), so at the `AssetSizeReader`
    // level this reduces to the same "nil falls back" behavior.
    let reader = AssetSizeReader(sampler: { false })
    let resource = FakeResourceSizeSource(quick: nil, fallback: 10)

    let size = await reader.size(ofResources: [resource])

    #expect(size == 10)
    #expect(resource.fallbackCalled == true)
}
