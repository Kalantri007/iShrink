@preconcurrency import Photos

// iShrink Phase 1 plan, U3 "Library scanner & asset sizing".
//
// Key Technical Decisions: "Guarded fast size read, cross-validated, summed
// across resources." There is no public API for a `PHAssetResource`'s
// on-disk byte size. The fast path is the undocumented KVC key `fileSize`
// (does not trigger an iCloud download); the guard is a documented fallback
// (`PHAssetResourceManager.requestData` with `isNetworkAccessAllowed =
// false`, summing received chunk lengths) used whenever the fast path is
// unavailable *or* looks untrustworthy.
//
// `isNetworkAccessAllowed` is set to `false` in exactly one place in this
// file (`PHAssetResourceSizeSource.fallbackSize()`) and is never set to
// `true` anywhere in `iShrinkCore` — this is the load-bearing "never
// triggers an iCloud download" guarantee for R6/R13.

/// One resource's two size-read paths, abstracted so `AssetSizeReader`'s
/// cross-validation logic is unit-testable without a real `PHAssetResource`
/// (plan test scenarios: nil-primary fallback, plausible-but-wrong
/// divergence, multi-resource sum — all driven by fakes, no real PhotoKit).
public protocol ResourceSizeSource: Sendable {
    /// Undocumented, fast read. `nil` means "unavailable or untrustworthy at
    /// face value" (e.g. KVC returned nil, or a non-positive value) — the
    /// caller must fall back rather than trust a bare `nil` check alone.
    func quickSize() -> Int64?

    /// Documented, guaranteed-network-off fallback read. Always safe to call
    /// for an iCloud-only resource: it will simply read whatever is already
    /// local rather than downloading anything.
    func fallbackSize() async -> Int64
}

/// Real conformer wrapping one `PHAssetResource`.
public struct PHAssetResourceSizeSource: ResourceSizeSource {
    private let resource: PHAssetResource

    public init(resource: PHAssetResource) {
        self.resource = resource
    }

    /// Undocumented KVC key, per research (`external references`: "forum:
    /// fileSize KVC"). Guarded: a non-positive or missing value is treated
    /// as "unavailable", never as a legitimate zero-byte file.
    public func quickSize() -> Int64? {
        guard let value = resource.value(forKey: "fileSize") as? Int64, value > 0 else {
            return nil
        }
        return value
    }

    /// Documented fallback: reads resource data with network access
    /// explicitly disabled, summing delivered chunk lengths. This is the
    /// **only** place in `iShrinkCore` that constructs a
    /// `PHAssetResourceRequestOptions`, and `isNetworkAccessAllowed` is
    /// hardcoded `false` here — never flipped to `true`.
    public func fallbackSize() async -> Int64 {
        await withCheckedContinuation { continuation in
            var total: Int64 = 0
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false
            var didResume = false
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { data in
                    total += Int64(data.count)
                },
                completionHandler: { _ in
                    // A non-nil error here typically means the resource
                    // isn't locally available (network was disallowed) —
                    // in that case `total` simply stays at whatever was
                    // received before the error (often 0), which is the
                    // honest answer: we deliberately did not download it.
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: total)
                }
            )
        }
    }
}

/// Guarded, cross-validated, per-asset size reader (Key Technical
/// Decisions). One instance is meant to live for the duration of a single
/// scan run: its cross-validation state (`forcedFallbackForRun`) is
/// deliberately per-instance, not per-call, so that a detected divergence
/// switches the *rest of the run* to the fallback path, not just the one
/// resource that triggered it.
public actor AssetSizeReader {
    public typealias Sampler = @Sendable () -> Bool

    private let relativeTolerance: Double
    private let absoluteToleranceBytes: Int64
    private let sampler: Sampler

    /// Once a cross-validation check finds the fast path untrustworthy, this
    /// flips to `true` and stays `true` for the rest of this reader's
    /// lifetime (= the rest of the run). Records already read before the
    /// flip are not retroactively recomputed — the scanner streams records
    /// as it goes (plan R9) and never buffers the whole run to revisit, so
    /// "switches the whole run" means "from this point forward", which is
    /// the only thing achievable without breaking the streaming design.
    private var forcedFallbackForRun = false

    /// - Parameters:
    ///   - relativeTolerance: allowed fractional difference between the
    ///     quick and fallback reads before they're considered diverged.
    ///   - absoluteToleranceBytes: allowed absolute difference (bytes),
    ///     whichever of the two tolerances is larger wins — guards small
    ///     files where a purely relative tolerance would be too strict.
    ///   - sampler: decides, per resource, whether to cross-validate this
    ///     call. Defaults to a small random sampling rate; tests inject a
    ///     deterministic sampler (`{ true }` / `{ false }`) to make specific
    ///     scenarios reproducible.
    public init(
        relativeTolerance: Double = 0.02,
        absoluteToleranceBytes: Int64 = 4096,
        sampler: @escaping Sampler = { Double.random(in: 0..<1) < 0.05 }
    ) {
        self.relativeTolerance = relativeTolerance
        self.absoluteToleranceBytes = absoluteToleranceBytes
        self.sampler = sampler
    }

    /// Sums the on-disk size across **all** of an asset's resources (edited
    /// photos carry original + adjustment; Live Photos carry photo +
    /// pairedVideo) — plan: "sum across all resources".
    public func size(ofResources resources: [any ResourceSizeSource]) async -> Int64 {
        var total: Int64 = 0
        for resource in resources {
            total += await sizeForSingleResource(resource)
        }
        return total
    }

    private func sizeForSingleResource(_ resource: any ResourceSizeSource) async -> Int64 {
        if forcedFallbackForRun {
            return await resource.fallbackSize()
        }

        guard let quick = resource.quickSize() else {
            // Bare nil/≤0 case: no cross-validation needed, just fall back.
            return await resource.fallbackSize()
        }

        guard sampler() else {
            return quick
        }

        // Sampled: cross-validate the plausible-but-possibly-wrong quick
        // value against the documented fallback.
        let fallback = await resource.fallbackSize()
        if diverges(quick: quick, fallback: fallback) {
            forcedFallbackForRun = true
            return fallback
        }
        return quick
    }

    private func diverges(quick: Int64, fallback: Int64) -> Bool {
        let difference = abs(quick - fallback)
        let allowed = max(absoluteToleranceBytes, Int64(Double(fallback) * relativeTolerance))
        return difference > allowed
    }
}
