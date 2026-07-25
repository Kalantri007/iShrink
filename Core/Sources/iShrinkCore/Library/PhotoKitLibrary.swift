@preconcurrency import Photos

// iShrink Phase 1 plan, U3 "Library scanner & asset sizing".
//
// Real `PhotoLibraryProviding` conformer. Per the plan's execution note,
// this file is characterized manually against a live Photos library rather
// than in the automated suite (PhotoKit can't run headless in CI) — the
// automated tests exercise `LibraryScanner`/`AssetSizeReader` logic against
// `FakeLibrary` / fake `ResourceSizeSource`s instead.
//
// Research (`scanning at scale`): `PHFetchResult` is lazy/faulting — keep it,
// page by index, never copy to an `Array`. `includeAssetSourceTypes =
// .typeUserLibrary` excludes shared/synced assets; `wantsIncrementalChangeDetails
// = false` since this is a one-shot scan, not a live-updating fetch.
public actor PhotoKitLibrary: PhotoLibraryProviding {
    private let fetchResult: PHFetchResult<PHAsset>
    private let sizeReader: AssetSizeReader

    public init(sizeReader: AssetSizeReader = AssetSizeReader()) {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = .typeUserLibrary
        options.wantsIncrementalChangeDetails = false
        self.fetchResult = PHAsset.fetchAssets(with: options)
        self.sizeReader = sizeReader
    }

    public var assetCount: Int {
        fetchResult.count
    }

    public func fetchRecords(offset: Int, limit: Int) async -> [AssetRecord] {
        guard limit > 0, offset < fetchResult.count else {
            return []
        }
        let upper = min(offset + limit, fetchResult.count)

        // Synchronous PhotoKit object access (PHAsset + its PHAssetResources)
        // for this page happens inside one autoreleasepool scope, per plan
        // ("wraps each batch in autoreleasepool") — ObjC-bridged objects for
        // this page are released promptly instead of accumulating across the
        // whole scan. The async size/availability reads happen afterward,
        // outside the pool, since `autoreleasepool { }`'s closure can't await.
        struct RawEntry {
            let asset: PHAsset
            let resources: [PHAssetResource]
        }
        var entries: [RawEntry] = []
        entries.reserveCapacity(upper - offset)
        autoreleasepool {
            for index in offset..<upper {
                let asset = fetchResult.object(at: index)
                let resources = PHAssetResource.assetResources(for: asset)
                entries.append(RawEntry(asset: asset, resources: resources))
            }
        }

        var records: [AssetRecord] = []
        records.reserveCapacity(entries.count)
        for entry in entries {
            records.append(await buildRecord(asset: entry.asset, resources: entry.resources))
        }
        return records
    }

    private func buildRecord(asset: PHAsset, resources: [PHAssetResource]) async -> AssetRecord {
        let sizeSources = resources.map { PHAssetResourceSizeSource(resource: $0) }
        let byteSize = await sizeReader.size(ofResources: sizeSources)
        let isLocallyAvailable = await Self.probeIsLocallyAvailable(resources: resources)

        let primary = Self.primaryResource(among: resources)

        return AssetRecord(
            localIdentifier: asset.localIdentifier,
            mediaType: AssetMediaType(asset.mediaType),
            mediaSubtypes: AssetMediaSubtypes(asset.mediaSubtypes),
            primaryUTI: primary?.uniformTypeIdentifier,
            resourceUTIs: resources.map { $0.uniformTypeIdentifier },
            resourceKinds: resources.map { AssetResourceKind($0.type) },
            byteSize: byteSize,
            isLocallyAvailable: isLocallyAvailable,
            originalFilename: primary?.originalFilename ?? resources.first?.originalFilename,
            creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    /// Picks the resource that represents the asset's main content (photo or
    /// video), preferring the full-size variant, over auxiliary resources
    /// like `.adjustmentData` or `.pairedVideo`. Falls back to the first
    /// resource if none of the "main content" kinds are present.
    private static func primaryResource(among resources: [PHAssetResource]) -> PHAssetResource? {
        let priority: [PHAssetResourceType] = [.fullSizePhoto, .photo, .fullSizeVideo, .video, .audio]
        for kind in priority {
            if let match = resources.first(where: { $0.type == kind }) {
                return match
            }
        }
        return resources.first
    }

    /// Per-asset local-availability probe (research: "Local-vs-iCloud").
    /// Prefers the undocumented `locallyAvailable` KVC key on
    /// `PHAssetResource` (no network fetch, no data read); falls back to a
    /// network-off `requestData` probe only when that KVC key is
    /// unavailable. Both paths are network-off — this never triggers an
    /// iCloud download. An asset counts as locally available only if *all*
    /// of its resources are (exporting it would otherwise need a network
    /// fetch for at least one resource).
    private static func probeIsLocallyAvailable(resources: [PHAssetResource]) async -> Bool {
        guard !resources.isEmpty else { return true }
        for resource in resources {
            if let quick = resource.value(forKey: "locallyAvailable") as? Bool {
                if !quick { return false }
                continue
            }
            if await !probeLocalAvailabilityViaNetworkOffRequest(resource: resource) {
                return false
            }
        }
        return true
    }

    private static func probeLocalAvailabilityViaNetworkOffRequest(resource: PHAssetResource) async -> Bool {
        await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false
            var didResume = false
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { _ in
                    // Presence of any data implies local availability; we
                    // don't need the bytes themselves here (size is read
                    // separately by AssetSizeReader).
                },
                completionHandler: { error in
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: error == nil)
                }
            )
        }
    }
}

private extension AssetMediaType {
    init(_ phMediaType: PHAssetMediaType) {
        switch phMediaType {
        case .unknown:
            self = .unknown
        case .image:
            self = .image
        case .video:
            self = .video
        case .audio:
            self = .audio
        @unknown default:
            self = .unknown
        }
    }
}

private extension AssetMediaSubtypes {
    init(_ phSubtypes: PHAssetMediaSubtype) {
        var result: AssetMediaSubtypes = []
        if phSubtypes.contains(.photoPanorama) { result.insert(.panorama) }
        if phSubtypes.contains(.photoHDR) { result.insert(.hdr) }
        if phSubtypes.contains(.photoScreenshot) { result.insert(.screenshot) }
        if phSubtypes.contains(.photoLive) { result.insert(.livePhoto) }
        if phSubtypes.contains(.photoDepthEffect) { result.insert(.depthEffect) }
        if phSubtypes.contains(.videoStreamed) { result.insert(.streamedVideo) }
        if phSubtypes.contains(.videoHighFrameRate) { result.insert(.highFrameRateVideo) }
        if phSubtypes.contains(.videoTimelapse) { result.insert(.timelapseVideo) }
        self = result
    }
}

private extension AssetResourceKind {
    init(_ phType: PHAssetResourceType) {
        switch phType {
        case .photo:
            self = .photo
        case .video:
            self = .video
        case .audio:
            self = .audio
        case .pairedVideo:
            self = .pairedVideo
        case .fullSizePhoto:
            self = .fullSizePhoto
        case .fullSizeVideo:
            self = .fullSizeVideo
        case .alternatePhoto:
            self = .alternatePhoto
        case .fullSizePairedVideo:
            self = .fullSizePairedVideo
        case .adjustmentData:
            self = .adjustmentData
        case .adjustmentBasePhoto:
            self = .adjustmentBasePhoto
        case .adjustmentBaseVideo:
            self = .adjustmentBaseVideo
        case .adjustmentBasePairedVideo:
            self = .adjustmentBasePairedVideo
        case .photoProxy:
            self = .photoProxy
        @unknown default:
            self = .unknown(phType.rawValue)
        }
    }
}
