import Foundation

// iShrink Phase 1 plan, U3 "Library scanner & asset sizing".
//
// This file deliberately imports nothing from PhotoKit (Foundation only, for
// `Date`). `AssetRecord` and its
// supporting types are plain Swift value types so that a `FakeLibrary` test
// conformer (see LibraryScannerTests.swift) can hand the scanner canned
// records without ever constructing a `PHAsset`/`PHAssetResource`/
// `PHFetchResult` — those PhotoKit types only appear in the real conformer,
// `PhotoKitLibrary.swift` (Key Technical Decisions: "PhotoKit behind a
// protocol").

/// Lightweight, `Sendable` view of `PHAssetMediaType`, kept as our own type
/// (rather than re-exporting PhotoKit's enum) so this file has no PhotoKit
/// dependency.
public enum AssetMediaType: Sendable, Equatable, Hashable {
    case unknown
    case image
    case video
    case audio
}

/// Our own bit-flag mirror of the subset of `PHAssetMediaSubtype` that the
/// scan/classify/analytics pipeline cares about (U3 exposes them; U4 reads
/// them for HDR/Live Photo classification). Deliberately re-derived rather
/// than reusing PhotoKit's raw bit values, since those aren't a documented
/// contract — the real conformer maps `PHAssetMediaSubtype.contains(...)`
/// checks onto these flags one at a time (see `PhotoKitLibrary.swift`).
public struct AssetMediaSubtypes: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let panorama = AssetMediaSubtypes(rawValue: 1 << 0)
    public static let hdr = AssetMediaSubtypes(rawValue: 1 << 1)
    public static let screenshot = AssetMediaSubtypes(rawValue: 1 << 2)
    public static let livePhoto = AssetMediaSubtypes(rawValue: 1 << 3)
    public static let depthEffect = AssetMediaSubtypes(rawValue: 1 << 4)
    public static let streamedVideo = AssetMediaSubtypes(rawValue: 1 << 5)
    public static let highFrameRateVideo = AssetMediaSubtypes(rawValue: 1 << 6)
    public static let timelapseVideo = AssetMediaSubtypes(rawValue: 1 << 7)
}

/// Plain mirror of `PHAssetResourceType`. U3's job is only to expose which
/// resources back an asset (and how many) so U4 can later decide edited-photo
/// / Live-Photo classification (plan: "resource-selection policy" — U3
/// exposes resource count/kinds, U4 decides exclusion). `.unknown` carries
/// the raw PhotoKit value forward for any future resource type this enum
/// doesn't yet name explicitly.
public enum AssetResourceKind: Sendable, Equatable, Hashable {
    case photo
    case video
    case audio
    case pairedVideo
    case fullSizePhoto
    case fullSizeVideo
    case alternatePhoto
    case fullSizePairedVideo
    case adjustmentData
    case adjustmentBasePhoto
    case adjustmentBaseVideo
    case adjustmentBasePairedVideo
    case photoProxy
    case unknown(Int)
}

/// A lightweight, value-type snapshot of one PhotoKit asset: everything the
/// scan/classify/analytics/estimate pipeline needs, with no PhotoKit types in
/// sight. Built once per asset by `PhotoKitLibrary` (or, in tests, handed
/// directly by `FakeLibrary`).
public struct AssetRecord: Sendable, Equatable {
    public let localIdentifier: String
    public let mediaType: AssetMediaType
    public let mediaSubtypes: AssetMediaSubtypes

    /// UTI of the asset's "primary" resource (the main photo/video content,
    /// not an adjustment or paired-video resource). `nil` only if the asset
    /// somehow has zero resources.
    public let primaryUTI: String?

    /// UTIs of every resource backing this asset, in the same order as
    /// `resourceKinds`. Edited photos and Live Photos have more than one.
    public let resourceUTIs: [String]

    /// Resource kind for each entry in `resourceUTIs`, same order/count.
    /// U4 uses this (e.g. presence of `.adjustmentData` or `.pairedVideo`)
    /// to classify edited photos / Live Photos — U3 does not itself decide
    /// exclusion.
    public let resourceKinds: [AssetResourceKind]

    /// On-disk byte size **summed across all resources** (guarded KVC +
    /// documented fallback, cross-validated — see `AssetSizeReader`).
    public let byteSize: Int64

    /// Whether the asset's resources are locally available without a
    /// network fetch. Read via a network-off probe; never triggers an
    /// iCloud download (plan: "used only to skip non-local assets, not for
    /// library-wide detection").
    public let isLocallyAvailable: Bool

    public let originalFilename: String?
    public let creationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        localIdentifier: String,
        mediaType: AssetMediaType,
        mediaSubtypes: AssetMediaSubtypes,
        primaryUTI: String?,
        resourceUTIs: [String],
        resourceKinds: [AssetResourceKind],
        byteSize: Int64,
        isLocallyAvailable: Bool,
        originalFilename: String?,
        creationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.localIdentifier = localIdentifier
        self.mediaType = mediaType
        self.mediaSubtypes = mediaSubtypes
        self.primaryUTI = primaryUTI
        self.resourceUTIs = resourceUTIs
        self.resourceKinds = resourceKinds
        self.byteSize = byteSize
        self.isLocallyAvailable = isLocallyAvailable
        self.originalFilename = originalFilename
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Number of PhotoKit resources backing this asset (e.g. photo +
    /// adjustmentData for an edited photo, photo + pairedVideo for a Live
    /// Photo). Exposed so U4 doesn't need to re-derive it from the arrays.
    public var resourceCount: Int {
        resourceUTIs.count
    }
}

/// Seam between the scan pipeline and PhotoKit (Key Technical Decisions:
/// "PhotoKit behind a protocol"). `PhotoKitLibrary` is the real conformer;
/// `FakeLibrary` (test-only) supplies canned records with no PhotoKit
/// dependency at all.
///
/// Conformers must page rather than materialize the whole library: real
/// PhotoKit backs this with a lazy `PHFetchResult` indexed per page: never
/// copied to an `Array` (plan R9, "scanning at scale").
public protocol PhotoLibraryProviding: Sendable {
    /// Total number of assets in scope, read cheaply (e.g. `PHFetchResult.count`)
    /// without materializing any `AssetRecord`s. Used as the scanner's
    /// progress denominator.
    var assetCount: Int { get async }

    /// Returns up to `limit` records starting at `offset`, in stable index
    /// order. Returns fewer than `limit` (possibly empty) once the end of
    /// the library is reached — that's how `LibraryScanner` knows to stop.
    func fetchRecords(offset: Int, limit: Int) async -> [AssetRecord]
}
