import Foundation
import Photos

// iShrink Phase 1 plan, U9 "App UI: compression run & report" — the real,
// PhotoKit-backed `ItemCompressing` conformer that lets `CompressionPipeline`
// (U7) actually run against a live library. U6 built `ImageCompressor`
// against a plain `sourceURL`, and U7 built the pipeline against the
// `ItemCompressing` protocol, precisely so this piece — the one that
// resolves a `PHAsset.localIdentifier` to real bytes — could be slotted in
// later without touching either (U6's own header comment already flagged
// "tests operate directly on fixture file URLs, no PhotoKit ... the real
// conformer" as a later piece of work; this file is that conformer).
//
// Real PhotoKit conformer, validated manually against a live library, same
// as `PhotoKitLibrary` (U3) and `PhotoAuthorization`'s real authorization
// call — PhotoKit can't run in CI/headless, so this file has no unit-test
// coverage of its own (mirrors the established pattern); `ItemCompressing`
// is exactly the seam that lets `CompressionPipelineTests` prove the
// pipeline's mechanics with `FakeCompressor` instead.
//
// `PipelineItem.sourceURL` is used here as a *scratch staging path*, not a
// pre-existing file: this type exports the asset's primary photo resource
// into that path fresh, immediately before compressing it, so resource
// export happens inside the same bounded concurrency window as everything
// else (R9 — never materializing every selected asset's bytes up front).
public struct PhotoKitItemCompressor: ItemCompressing {
    /// Per-asset info the report needs that neither `PipelineItem` nor
    /// `CompressionResult` carries on its own — see `CompressionReport.swift`'s
    /// file header for why this is a small, purpose-built type rather than
    /// retrofitting an earlier one.
    public struct AssetReportInfo: Sendable, Equatable {
        public let filename: String
        public let codec: MediaCodec

        public init(filename: String, codec: MediaCodec) {
            self.filename = filename
            self.codec = codec
        }
    }

    private let imageCompressor: ImageCompressor
    private let destinationDirectory: URL
    private let reportAccumulator: CompressionReportAccumulator
    private let assetInfo: [String: AssetReportInfo]
    private let policyDecisions: [String: CompressionPolicyDecision]

    public init(
        imageCompressor: ImageCompressor,
        destinationDirectory: URL,
        reportAccumulator: CompressionReportAccumulator,
        assetInfo: [String: AssetReportInfo],
        policyDecisions: [String: CompressionPolicyDecision] = [:]
    ) {
        self.imageCompressor = imageCompressor
        self.destinationDirectory = destinationDirectory
        self.reportAccumulator = reportAccumulator
        self.assetInfo = assetInfo
        self.policyDecisions = policyDecisions
    }

    public func compress(_ item: PipelineItem) async -> ItemCompressionOutcome {
        // Re-assert `CompressionPolicy`'s decision here, independent of
        // whatever upstream selection logic produced `item` — this is the
        // "second guard" U6 built specifically to protect against a stale
        // or replayed manifest resurfacing an ineligible asset; it was
        // previously computed (AppModel) but never actually consulted on
        // this, the real compression path.
        if let decision = policyDecisions[item.localIdentifier], decision != .proceed {
            return .failure(.unsupportedFormat)
        }

        guard await Self.exportPrimaryPhotoResource(localIdentifier: item.localIdentifier, to: item.sourceURL) else {
            // Couldn't resolve/export the asset at all (deleted since scan,
            // no photo resource, or the export itself failed) — treated as
            // a permanent per-item failure, same as an unreadable/corrupt
            // source file (R10: keeps the input untouched, doesn't halt the
            // batch).
            return .failure(.corruptInput)
        }
        defer { try? FileManager.default.removeItem(at: item.sourceURL) }

        switch imageCompressor.compress(
            sourceURL: item.sourceURL,
            localIdentifier: item.localIdentifier,
            destinationDirectory: destinationDirectory
        ) {
        case .success(let result):
            let info = assetInfo[item.localIdentifier]
            let reportItem = CompressionReportItem(
                localIdentifier: item.localIdentifier,
                filename: info?.filename ?? item.sourceURL.lastPathComponent,
                codec: info?.codec ?? .unknown,
                inputByteSize: result.inputByteSize,
                outputByteSize: result.outputByteSize,
                gpsCoordinate: GPSCoordinate.read(from: result.outputURL)
            )
            await reportAccumulator.record(reportItem)
            return .success(PipelineItemSuccess(outputURL: result.outputURL))
        case .failure(let error):
            switch error {
            case .encodeFailed:
                return .failure(.encodeFailedOnReadableFile)
            case .moveFailed:
                return .failure(.temporaryIOError)
            }
        }
    }

    /// Exports `localIdentifier`'s primary photo resource to `destination`,
    /// never triggering an iCloud download (`isNetworkAccessAllowed =
    /// false` — R6: process only locally-present originals; the asset
    /// should already have been filtered to `isLocallyAvailable` well
    /// before it reaches this conformer, but this is the same defensive
    /// belt-and-suspenders the rest of the codebase uses).
    ///
    /// Uses `PhotoKitLibrary.primaryResource(among:)` — the same
    /// full-size-preferring priority order the scanner used to attribute
    /// this asset's size/filename — so the resource actually compressed
    /// here always matches the one the analytics/confirmation screens
    /// described.
    private static func exportPrimaryPhotoResource(localIdentifier: String, to destination: URL) async -> Bool {
        guard
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else {
            return false
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = PhotoKitLibrary.primaryResource(among: resources) else {
            return false
        }

        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}

/// Accumulates `CompressionReportItem`s across one or more
/// `CompressionPipeline.run(items:)` calls made against the same instance —
/// including a pause-then-resume sequence — mirroring the "persists across
/// resumed calls on the same instance" shape `CompressionPipeline` itself
/// already uses for `succeededIdentifiers`/`failureLog` (U7). Keyed on
/// `localIdentifier` so a value simply gets replaced rather than
/// double-counted if the same item is ever recorded twice.
///
/// This is deliberately *not* derived from `RunManifest`/`ManifestEntry`
/// directly — see `CompressionReport.swift`'s file header for why
/// (`ManifestEntry` carries no byte-size/codec data to report from). This
/// accumulator is the App layer's parallel, report-specific bookkeeping,
/// populated by `PhotoKitItemCompressor` at the moment it already has a
/// `CompressionResult` to read from.
public actor CompressionReportAccumulator {
    private var itemsByIdentifier: [String: CompressionReportItem] = [:]

    /// Sum of `savedBytes` across every recorded item, maintained
    /// incrementally in `record()` (O(1) per call) so a caller wanting a
    /// live running total during a run doesn't need to re-sum `allItems`
    /// (O(n)) on every single item completion — which would make a whole
    /// run's worth of progress updates O(n^2).
    private var totalSavedBytes: Int64 = 0

    public init() {}

    public func record(_ item: CompressionReportItem) {
        if let previous = itemsByIdentifier[item.localIdentifier] {
            totalSavedBytes -= previous.savedBytes
        }
        itemsByIdentifier[item.localIdentifier] = item
        totalSavedBytes += item.savedBytes
    }

    public var allItems: [CompressionReportItem] {
        Array(itemsByIdentifier.values)
    }

    /// O(1) running total — see `totalSavedBytes`.
    public var runningSavedBytes: Int64 {
        totalSavedBytes
    }
}
