import Foundation
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO

// iShrink Phase 1 plan, U4 "Media classifier & storage analytics".
//
// Maps an `AssetRecord` (U3's pure value type — no PhotoKit, no file handle)
// to a codec, Live Photo / HDR flags, and a compression eligibility. Codec
// and RAW detection use `UTType` conformance/identity against
// `record.primaryUTI` only — no decoding (research: "Codec/format without
// decoding"). HDR detection additionally needs a gain-map auxiliary-data
// probe, which is a real per-file ImageIO read — `AssetRecord` alone can't
// supply that (it carries no URL), so it's abstracted behind
// `GainMapProbing` below (see that type's doc comment for the seam design).

/// Coarse codec classification, independent of exclusion/eligibility.
public enum MediaCodec: Sendable, Equatable, Hashable {
    case jpeg
    case heic
    case png
    case rawOrProRaw
    case h264
    case hevc
    case otherVideo
    case unknown
}

/// What `MediaClassifier` decided about a record's compression eligibility.
public enum ClassificationEligibility: Sendable, Equatable {
    /// Eligible for JPEG/PNG → HEIC compression (subject to further,
    /// second-guard policy in U6's `CompressionPolicy`).
    case compressible

    /// Not eligible, for one of `ExclusionReason`'s reasons.
    case excluded(ExclusionReason)

    /// Not a candidate for compression at all in Phase 1, but still counted
    /// in storage analytics — this is video (Scope Boundaries: "No video
    /// compression. Video assets are counted and codec-classified for
    /// analytics only"). Deliberately distinct from `.excluded(reason)`:
    /// there is no `ExclusionReason` case for "it's a video" because
    /// exclusion reasons describe *photos* iShrink chose not to touch for a
    /// specific cause, whereas video is out of scope for the whole phase.
    case analyticsOnly
}

/// The result of classifying one `AssetRecord`.
public struct ClassifiedAsset: Sendable, Equatable {
    public let record: AssetRecord
    public let codec: MediaCodec
    public let isLivePhoto: Bool
    public let isHDR: Bool
    public let eligibility: ClassificationEligibility

    public init(
        record: AssetRecord,
        codec: MediaCodec,
        isLivePhoto: Bool,
        isHDR: Bool,
        eligibility: ClassificationEligibility
    ) {
        self.record = record
        self.codec = codec
        self.isLivePhoto = isLivePhoto
        self.isHDR = isHDR
        self.eligibility = eligibility
    }
}

/// Seam for the gain-map auxiliary-data probe (Key Technical Decisions:
/// "HDR ... detection uses both `mediaSubtypes.contains(.photoHDR)` and a
/// gain-map auxiliary-data probe"). This has to be a protocol rather than a
/// free function because the real check
/// (`CGImageSourceCopyAuxiliaryDataInfoAtIndex` for
/// `kCGImageAuxiliaryDataTypeHDRGainMap`) is a per-file ImageIO read, and
/// `AssetRecord` is a pure value type with no file handle — U3 deliberately
/// kept PhotoKit/file access out of it. So this protocol is keyed on the
/// whole `AssetRecord` (its `localIdentifier` is the stable key a real
/// conformer would use to resolve actual bytes) rather than on a URL
/// directly, which lets `MediaClassifier` stay agnostic about *how* a
/// conformer gets from "this asset" to "these bytes".
///
/// `ImageIOGainMapProbe` below is a real, ImageIO-backed conformer for when
/// a URL *is* available (e.g. once U6's compressor has exported a resource
/// to the app-private temp dir, or a future scan-time export step supplies
/// one) — but resolving `localIdentifier -> URL` for a not-yet-exported
/// asset is not solved by U4 or by `AssetRecord`'s current shape; wiring
/// that resolution is left to whichever later unit first needs a live
/// gain-map probe against un-exported library assets. Until then,
/// `MediaClassifier` is passed `nil` (no probe: HDR detection is
/// subtype-only) or a test fake.
public protocol GainMapProbing: Sendable {
    /// Whether this asset's primary photo resource carries an HDR gain-map
    /// auxiliary image. `MediaClassifier` calls this only for candidates
    /// that already passed the cheap subtype/UTI filters (see
    /// `MediaClassifier.classify`), never for every asset.
    func hasGainMap(for record: AssetRecord) async -> Bool
}

/// Real, ImageIO-backed `GainMapProbing` conformer, for use once a caller
/// can resolve an `AssetRecord` to a readable file URL (see the protocol's
/// doc comment for why that resolution isn't attempted here). Not exercised
/// by the U4 test suite (no fixture files exist yet in this unit — those
/// arrive with U6's `ImageCompressorTests`); it mirrors the codebase's
/// established pattern of a real-API conformer validated manually rather
/// than in CI (c.f. `PhotoKitLibrary`).
public struct ImageIOGainMapProbe: GainMapProbing {
    private let urlProvider: @Sendable (AssetRecord) -> URL?

    public init(urlProvider: @escaping @Sendable (AssetRecord) -> URL?) {
        self.urlProvider = urlProvider
    }

    public func hasGainMap(for record: AssetRecord) async -> Bool {
        guard let url = urlProvider(record),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            return false
        }
        return Self.sourceHasGainMap(source)
    }

    private static func sourceHasGainMap(_ source: CGImageSource) -> Bool {
        if #available(macOS 13.0, *) {
            guard
                let auxData = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                    source, 0, kCGImageAuxiliaryDataTypeHDRGainMap
                ) as? [CFString: Any]
            else {
                return false
            }
            return !auxData.isEmpty
        }
        // `kCGImageAuxiliaryDataTypeHDRGainMap` isn't available before
        // macOS 13; on an older OS we can't probe for it at all, so we
        // honestly report "no gain map found" rather than crash. This is a
        // real detection gap on old OS versions (mirrors the plan's own
        // "HDR gain maps ... reliable preservation needs macOS 14+" note) —
        // the `.photoHDR` subtype path still catches the classic case.
        return false
    }
}

/// Maps `AssetRecord`s to codec + Live Photo/HDR flags + eligibility
/// (plan Approach, U4).
public struct MediaClassifier: Sendable {
    private let gainMapProbe: GainMapProbing?

    /// - Parameter gainMapProbe: optional seam for the gain-map auxiliary
    ///   probe. `nil` means HDR detection falls back to subtype-only (still
    ///   correct, just narrower) — tests inject a fake that reports a fixed
    ///   "has gain map" / "no gain map" answer per plan test scenario 4.
    public init(gainMapProbe: GainMapProbing? = nil) {
        self.gainMapProbe = gainMapProbe
    }

    public func classify(_ record: AssetRecord) async -> ClassifiedAsset {
        let codec = Self.codec(forUTI: record.primaryUTI, mediaType: record.mediaType)
        let isLivePhoto = record.mediaSubtypes.contains(.livePhoto)
        let subtypeHDR = record.mediaSubtypes.contains(.hdr)

        // iCloud-only wins over every other classification (check first,
        // per the plan: "check this before other classification since it
        // should win").
        guard record.isLocallyAvailable else {
            return ClassifiedAsset(
                record: record, codec: codec, isLivePhoto: isLivePhoto, isHDR: subtypeHDR,
                eligibility: .excluded(.iCloudOnly)
            )
        }

        // Video is analytics-only in Phase 1 — never a compression
        // candidate, so it also never runs the (photo-oriented) gain-map
        // probe (plan: "skip the probe entirely for RAW/video ... assets").
        guard record.mediaType != .video else {
            return ClassifiedAsset(
                record: record, codec: codec, isLivePhoto: isLivePhoto, isHDR: subtypeHDR,
                eligibility: .analyticsOnly
            )
        }

        // RAW/ProRAW is a master format, excluded regardless of anything
        // else, and — like video — never runs the gain-map probe.
        guard codec != .rawOrProRaw else {
            return ClassifiedAsset(
                record: record, codec: codec, isLivePhoto: isLivePhoto, isHDR: subtypeHDR,
                eligibility: .excluded(.rawMaster)
            )
        }

        // HDR: subtype OR gain-map probe. By this point RAW/video/iCloud-
        // only candidates have already returned above, so the probe (when
        // one is injected) only ever runs on the narrowed-down remainder —
        // bounding classification cost at scale (plan: "run the gain-map
        // probe only on candidates that pass cheap subtype/UTI filters
        // first"). If the subtype already says HDR, skip the probe call
        // entirely (no need to pay for it).
        var isHDR = subtypeHDR
        if !isHDR, let gainMapProbe {
            isHDR = await gainMapProbe.hasGainMap(for: record)
        }
        guard !isHDR else {
            return ClassifiedAsset(
                record: record, codec: codec, isLivePhoto: isLivePhoto, isHDR: true,
                eligibility: .excluded(.hdrUnpreservable)
            )
        }

        // A Live Photo's still is excluded, not exported as an orphaned
        // still detached from its paired video.
        guard !isLivePhoto else {
            return ClassifiedAsset(
                record: record, codec: codec, isLivePhoto: true, isHDR: isHDR,
                eligibility: .excluded(.livePhoto)
            )
        }

        // Edited photos: Phase 1 doesn't re-render user edits.
        guard !record.resourceKinds.contains(.adjustmentData) else {
            return ClassifiedAsset(
                record: record, codec: codec, isLivePhoto: isLivePhoto, isHDR: isHDR,
                eligibility: .excluded(.editedPhoto)
            )
        }

        // Already HEIC: unconditional exclusion in Phase 1 (no resize flag
        // exists yet).
        guard codec != .heic else {
            return ClassifiedAsset(
                record: record, codec: codec, isLivePhoto: isLivePhoto, isHDR: isHDR,
                eligibility: .excluded(.alreadyHeic)
            )
        }

        return ClassifiedAsset(
            record: record, codec: codec, isLivePhoto: isLivePhoto, isHDR: isHDR,
            eligibility: .compressible
        )
    }

    /// Codec detection from UTI alone, no decoding (research: "Codec/format
    /// without decoding").
    ///
    /// Judgment call: unlike RAW (caught in one `conforms(to: .rawImage)`
    /// check regardless of vendor) there is no public `UTType` that
    /// distinguishes an H.264 stream from an HEVC stream inside a QuickTime/
    /// MPEG-4 *container* without opening the track (research: "Video codec
    /// needs `AVAsset` format descriptions ... Phase 2"). U4 maps the two
    /// container UTIs PhotoKit most commonly reports for exported video
    /// resources as a best-effort default (`public.mpeg-4` → `.h264`,
    /// `com.apple.quicktime-movie` → `.hevc`) so the analytics-only codec
    /// breakdown has *a* value rather than everything collapsing to
    /// `.otherVideo`; this mapping is a documented approximation, not a
    /// guarantee, and is exactly the kind of thing flagged "Deferred to
    /// Implementation" in the plan ("whether video codec detection runs
    /// during the Phase-1 scan ... decide when U4 measures scan cost on a
    /// real library" — the mapping itself inherits that same uncertainty).
    /// Any other video UTI conforming to `.movie` is `.otherVideo`.
    static func codec(forUTI uti: String?, mediaType: AssetMediaType) -> MediaCodec {
        guard let uti, let type = UTType(uti) else { return .unknown }

        if type.conforms(to: .rawImage) {
            return .rawOrProRaw
        }

        if mediaType == .video {
            switch uti {
            case "public.mpeg-4":
                return .h264
            case "com.apple.quicktime-movie":
                return .hevc
            default:
                return type.conforms(to: .movie) ? .otherVideo : .unknown
            }
        }

        switch uti {
        case UTType.jpeg.identifier:
            return .jpeg
        case UTType.heic.identifier:
            return .heic
        case UTType.png.identifier:
            return .png
        default:
            return .unknown
        }
    }
}
