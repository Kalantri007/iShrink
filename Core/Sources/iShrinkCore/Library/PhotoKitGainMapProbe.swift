import Foundation
import Photos
import ImageIO

// iShrink Phase 1 plan, U4 "Media classifier & storage analytics" —
// production wiring fix for a code-review finding: `ImageIOGainMapProbe`
// (MediaClassifier.swift) was built as the real gain-map conformer but was
// never actually instantiated anywhere in the app, because its `urlProvider`
// seam needs a file URL, and resolving `localIdentifier -> URL` for a
// not-yet-exported asset was left unsolved by U4. This conformer sidesteps
// that gap entirely: it fetches the asset's primary photo resource's bytes
// into memory via `PHAssetResourceManager` (never touching disk, never
// allowing network access — matching every other real PhotoKit resource
// read in this package) and probes those in-memory bytes directly, so no
// file URL is ever needed.

/// Real, production `GainMapProbing` conformer wired into `AppModel`'s
/// `MediaClassifier`. Resolves `record.localIdentifier` to a `PHAsset`,
/// reads its primary photo resource's bytes with network access disallowed,
/// and reuses `ImageIOGainMapProbe`'s own auxiliary-data check against the
/// resulting in-memory `CGImageSource`.
public struct PhotoKitGainMapProbe: GainMapProbing {
    public init() {}

    public func hasGainMap(for record: AssetRecord) async -> Bool {
        guard
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [record.localIdentifier], options: nil).firstObject
        else {
            return false
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo }) ?? resources.first(where: { $0.type == .fullSizePhoto }) else {
            return false
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        var data = Data()
        let succeeded: Bool = await withCheckedContinuation { continuation in
            var didResume = false
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in data.append(chunk) },
                completionHandler: { error in
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: error == nil)
                }
            )
        }

        guard succeeded, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return ImageIOGainMapProbe.sourceHasGainMap(source)
    }
}
