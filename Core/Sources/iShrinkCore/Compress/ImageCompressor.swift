import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// iShrink Phase 1 plan, U6 "Non-destructive HEIC compression engine".
//
// Compresses one eligible photo to `.heic` in a user-chosen destination
// folder, non-destructively: encode to a temp `.heic` in an app-private
// temp directory first, and only atomically move the finished file into the
// destination once `CGImageDestinationFinalize` reports success (Key
// Technical Decisions: "Non-destructive output, written
// app-private-then-atomically-moved"). The real Photos library is never
// touched — this type only ever reads a source file URL and writes to a
// temp dir / destination folder (both plain `FileManager` locations), which
// is why `scripts/check-readonly.sh` (grep for PhotoKit mutation APIs) stays
// green with this file in the tree.
//
// U6 specifically does *not* wire up the real app-private temp directory
// (`~/Library/Application Support/iShrink/tmp`) — that's U7's `TempStore`
// job (startup orphan sweep, real location, etc). `ImageCompressor` instead
// takes an **injectable temp-directory URL** in its initializer, so tests
// point it at a scratch directory under the test's own temp scope rather
// than writing into the real user's Application Support (judgment call
// flagged in the U6 report).
//
// `AddImageFromSource` (not `AddImage` + a properties dictionary) is the
// default primitive here — it carries metadata/orientation/color-profile
// through automatically at low memory (research §2a). The properties-dict
// fallback is reserved for resize, which Phase 1 doesn't do by default, so
// it isn't implemented in this unit.

/// Best-effort, honestly-reported metadata preservation result for one
/// compression (Key Technical Decisions: "Metadata preservation is
/// best-effort and honestly labelled").
///
/// Every field is `Bool?`:
/// - `nil` means the *source* didn't carry that field at all — there was
///   nothing to preserve or lose, so "preserved" isn't a meaningful
///   true/false answer.
/// - `true`/`false` means the source had the field, and it was (or
///   wasn't) found, byte-for-byte-equal, on the re-encoded output.
///
/// `gpsPreserved`, `dateTimeOriginalPreserved`, `cameraMakeModelPreserved`,
/// `orientationPreserved`, and `timezonePreserved` are the fields the plan
/// (R4, Key Technical Decisions) says ride through `AddImageFromSource`
/// reliably — expected `true` whenever non-`nil` for a real photo, and a
/// test asserts exactly that (R4 test scenario). `lensPreserved` is called
/// out separately because lens info is frequently MakerNote-resident and
/// ImageIO's public metadata APIs can't promise it survives — this field is
/// reported (checked, not guaranteed) rather than silently folded into the
/// asserted set, so callers can't mistake "best-effort" for "guaranteed".
public struct MetadataFidelityResult: Sendable, Equatable {
    public let gpsPreserved: Bool?
    public let dateTimeOriginalPreserved: Bool?
    public let cameraMakeModelPreserved: Bool?
    public let orientationPreserved: Bool?
    public let timezonePreserved: Bool?

    /// Best-effort: whether Exif `LensModel` (often MakerNote-resident)
    /// happened to survive the re-encode. `nil` if the source had no lens
    /// info to check in the first place.
    public let lensPreserved: Bool?

    public init(
        gpsPreserved: Bool?,
        dateTimeOriginalPreserved: Bool?,
        cameraMakeModelPreserved: Bool?,
        orientationPreserved: Bool?,
        timezonePreserved: Bool?,
        lensPreserved: Bool?
    ) {
        self.gpsPreserved = gpsPreserved
        self.dateTimeOriginalPreserved = dateTimeOriginalPreserved
        self.cameraMakeModelPreserved = cameraMakeModelPreserved
        self.orientationPreserved = orientationPreserved
        self.timezonePreserved = timezonePreserved
        self.lensPreserved = lensPreserved
    }

    /// A result with every field `nil` — used when metadata can't be
    /// assessed at all (e.g. the source itself couldn't be re-opened for
    /// comparison after a successful encode, which should not normally
    /// happen but is handled without crashing).
    public static let unknown = MetadataFidelityResult(
        gpsPreserved: nil,
        dateTimeOriginalPreserved: nil,
        cameraMakeModelPreserved: nil,
        orientationPreserved: nil,
        timezonePreserved: nil,
        lensPreserved: nil
    )
}

/// Successful compression: where the `.heic` landed, before/after sizes,
/// and the metadata fidelity assessment.
public struct CompressionResult: Sendable, Equatable {
    public let outputURL: URL
    public let inputByteSize: Int64
    public let outputByteSize: Int64
    public let metadataFidelity: MetadataFidelityResult

    public init(
        outputURL: URL,
        inputByteSize: Int64,
        outputByteSize: Int64,
        metadataFidelity: MetadataFidelityResult
    ) {
        self.outputURL = outputURL
        self.inputByteSize = inputByteSize
        self.outputByteSize = outputByteSize
        self.metadataFidelity = metadataFidelity
    }
}

/// Why a compression attempt failed. Every case leaves the destination
/// folder untouched and the input file untouched (R10 handoff to U7 — this
/// unit surfaces a clear failure, it does not retry).
public enum CompressionError: Error, Sendable, Equatable {
    /// The source couldn't be decoded, the temp destination couldn't be
    /// created, or `CGImageDestinationFinalize` returned `false`. These are
    /// deliberately folded into one case: the plan treats
    /// `Finalize == false` and an unreadable source identically ("no
    /// partial output reaches the destination; input untouched"), and the
    /// encoder seam (`HEICEncoding`) reports all three as a single `Bool`
    /// for exactly that reason — there is nothing a caller does
    /// differently for one versus the other in Phase 1.
    case encodeFailed

    /// The encode succeeded (temp `.heic` finalized) but the atomic move
    /// into the destination directory failed (e.g. destination unwritable).
    /// The temp file is removed before this is returned — no truncated or
    /// half-written file is left in the destination.
    case moveFailed(String)
}

/// Seam around the actual ImageIO encode step
/// (`CGImageDestinationCreateWithURL` + `CGImageDestinationAddImageFromSource`
/// + `CGImageDestinationFinalize`). `ImageCompressor` is built against this
/// protocol, not the concrete ImageIO calls directly, so the Atomicity test
/// scenario ("inject a Finalize-fails condition ... prove no file lands at
/// the destination") can inject a fake that deterministically reports
/// failure, rather than relying on a filesystem trick (chmod'd read-only
/// dir, etc.) to coax a real `Finalize` failure out of ImageIO — that would
/// be flaky and platform-dependent. `ImageIOHEICEncoder` below is the real
/// conformer used in production.
public protocol HEICEncoding: Sendable {
    /// Encodes `sourceURL` to an HEIC at `destinationURL`. Returns `true`
    /// only when the encode is fully finalized and safe to move;`false` for
    /// any failure (unreadable source, destination-creation failure, or
    /// `CGImageDestinationFinalize == false`) — callers treat all of those
    /// identically.
    func encode(sourceURL: URL, destinationURL: URL, quality: CGFloat) -> Bool
}

/// Real, ImageIO-backed `HEICEncoding` conformer — the default primitive
/// from the plan: `CGImageDestinationCreateWithURL` +
/// `CGImageDestinationAddImageFromSource` + `CGImageDestinationFinalize`.
/// `AddImageFromSource` (not `AddImage`) is what carries metadata,
/// orientation, and the color profile through automatically.
public struct ImageIOHEICEncoder: HEICEncoding {
    public init() {}

    public func encode(sourceURL: URL, destinationURL: URL, quality: CGFloat) -> Bool {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return false
        }
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL, UTType.heic.identifier as CFString, 1, nil
        ) else {
            return false
        }

        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

/// Compresses one photo to HEIC, non-destructively (plan Approach, U6).
///
/// Construct with an app-private-ish temp directory (injectable — see the
/// file header comment on why U6 doesn't wire up the real
/// `~/Library/Application Support/iShrink/tmp` location) and call
/// `compress(sourceURL:localIdentifier:destinationDirectory:)` per asset.
/// `CompressionPolicy` is a separate, upstream guard — this type does not
/// re-check eligibility itself; it assumes its caller already consulted
/// `CompressionPolicy.evaluate`.
public struct ImageCompressor: Sendable {
    /// Where temp `.heic` files are encoded before the atomic move. Created
    /// on first use if it doesn't already exist. Never the destination
    /// volume (Key Technical Decisions: "the working copy carries
    /// unredacted GPS/EXIF, so it must never touch ... the destination
    /// volume before it's a finished output").
    public let tempDirectory: URL

    /// `kCGImageDestinationLossyCompressionQuality`, `0.0...1.0`.
    public let quality: CGFloat

    private let encoder: HEICEncoding

    public init(tempDirectory: URL, quality: CGFloat = 0.8, encoder: HEICEncoding = ImageIOHEICEncoder()) {
        self.tempDirectory = tempDirectory
        self.quality = quality
        self.encoder = encoder
    }

    /// Compresses the photo at `sourceURL` into `destinationDirectory`,
    /// namespaced by `localIdentifier` (collision-safe naming — see
    /// `sanitizedFilename(for:)`).
    ///
    /// - Never writes anything to `destinationDirectory` unless the encode
    ///   fully finalized (`Finalize == true`); a failed encode leaves
    ///   `sourceURL` and `destinationDirectory` both untouched, and removes
    ///   its own temp file.
    /// - The move into `destinationDirectory` is atomic with respect to any
    ///   existing file at the target path (replace-in-place), so a crash
    ///   mid-move never leaves a truncated file visible at the destination.
    public func compress(
        sourceURL: URL,
        localIdentifier: String,
        destinationDirectory: URL
    ) -> Result<CompressionResult, CompressionError> {
        try? FileManager.default.createDirectory(
            at: tempDirectory, withIntermediateDirectories: true
        )

        let tempURL = tempDirectory.appendingPathComponent(UUID().uuidString + ".heic")

        let finalized = encoder.encode(sourceURL: sourceURL, destinationURL: tempURL, quality: quality)
        guard finalized else {
            // Discard any partial temp output. Input untouched; nothing
            // reaches the destination.
            try? FileManager.default.removeItem(at: tempURL)
            return .failure(.encodeFailed)
        }

        let fidelity = Self.assessMetadataFidelity(sourceURL: sourceURL, outputURL: tempURL)
        let inputByteSize = Self.fileSize(at: sourceURL)
        let outputByteSize = Self.fileSize(at: tempURL)

        do {
            try FileManager.default.createDirectory(
                at: destinationDirectory, withIntermediateDirectories: true
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return .failure(.moveFailed("could not create destination directory: \(error)"))
        }

        let destinationURL = destinationDirectory.appendingPathComponent(
            Self.sanitizedFilename(for: localIdentifier)
        )

        do {
            try Self.atomicMove(from: tempURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return .failure(.moveFailed("\(error)"))
        }

        return .success(CompressionResult(
            outputURL: destinationURL,
            inputByteSize: inputByteSize,
            outputByteSize: outputByteSize,
            metadataFidelity: fidelity
        ))
    }

    // MARK: - Collision-safe naming

    /// Namespaces the output filename by the asset's stable
    /// `localIdentifier` rather than `originalFilename` (Key Technical
    /// Decisions: "`originalFilename` is not unique across a library —
    /// burst frames, re-imports, `IMG_9999 -> IMG_0001` rollover").
    /// `PHAsset.localIdentifier` contains a `/` (e.g.
    /// `"XXXX-XXXX/L0/001"`), which isn't filesystem-safe, so every
    /// path-separator-like character is replaced before appending `.heic`.
    static func sanitizedFilename(for localIdentifier: String) -> String {
        var sanitized = ""
        sanitized.reserveCapacity(localIdentifier.count)
        for character in localIdentifier {
            switch character {
            case "/", ":", "\\":
                sanitized.append("_")
            default:
                sanitized.append(character)
            }
        }
        return "\(sanitized).heic"
    }

    // MARK: - Atomic move

    /// Moves `sourceURL` (the finalized temp `.heic`, on the app-private
    /// temp volume) to `destinationURL` (on the user-chosen, often different,
    /// destination volume). `sourceURL` is first copied to a hidden staging
    /// file *on the destination volume*, then placed at `destinationURL` via
    /// `replaceItemAt`/`moveItem` between two paths on the same volume —
    /// which is a true atomic rename, unlike moving directly from
    /// `sourceURL` across volumes (that falls back to a non-atomic
    /// copy-then-delete, which can leave a truncated file at `destinationURL`
    /// if interrupted mid-copy). If a file already exists at `destinationURL`
    /// (e.g. a stray output from a prior interrupted run — U7's territory,
    /// but this unit's move primitive needs to not crash on it), it is
    /// atomically replaced; otherwise a same-volume move is used. Either way,
    /// `sourceURL` no longer exists once this returns successfully — there is
    /// no leftover temp file on the success path.
    private static func atomicMove(from sourceURL: URL, to destinationURL: URL) throws {
        let stagingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(destinationURL.lastPathComponent).tmp")
        try FileManager.default.copyItem(at: sourceURL, to: stagingURL)

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }

        try? FileManager.default.removeItem(at: sourceURL)
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: - Metadata fidelity assessment

    /// Compares ImageIO-visible properties between `sourceURL` (the
    /// original) and `outputURL` (the freshly-encoded temp `.heic`, read
    /// before the atomic move — its bytes are identical to whatever lands
    /// at the destination) to build a `MetadataFidelityResult`.
    ///
    /// This is a real re-read of both files via `CGImageSourceCopyProperties
    /// AtIndex` — it does not trust that `AddImageFromSource` "must have"
    /// carried the fields through; the plan's whole point (R4 / "extend the
    /// spike") is verifying that with real files.
    static func assessMetadataFidelity(sourceURL: URL, outputURL: URL) -> MetadataFidelityResult {
        guard
            let sourceProps = properties(of: sourceURL),
            let outputProps = properties(of: outputURL)
        else {
            return .unknown
        }

        let sourceGPS = sourceProps[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let outputGPS = outputProps[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let gpsPreserved: Bool? = sourceGPS == nil ? nil : gpsMatches(sourceGPS, outputGPS)

        let sourceExif = sourceProps[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let outputExif = outputProps[kCGImagePropertyExifDictionary] as? [CFString: Any]

        let sourceDateTimeOriginal = sourceExif?[kCGImagePropertyExifDateTimeOriginal] as? String
        let dateTimeOriginalPreserved: Bool? = sourceDateTimeOriginal == nil
            ? nil
            : (sourceDateTimeOriginal == outputExif?[kCGImagePropertyExifDateTimeOriginal] as? String)

        let sourceTIFF = sourceProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let outputTIFF = outputProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let sourceMake = sourceTIFF?[kCGImagePropertyTIFFMake] as? String
        let sourceModel = sourceTIFF?[kCGImagePropertyTIFFModel] as? String
        let cameraMakeModelPreserved: Bool?
        if sourceMake == nil && sourceModel == nil {
            cameraMakeModelPreserved = nil
        } else {
            let outputMake = outputTIFF?[kCGImagePropertyTIFFMake] as? String
            let outputModel = outputTIFF?[kCGImagePropertyTIFFModel] as? String
            cameraMakeModelPreserved = (sourceMake == outputMake) && (sourceModel == outputModel)
        }

        let sourceOrientation = sourceProps[kCGImagePropertyOrientation] as? Int
        let orientationPreserved: Bool? = sourceOrientation == nil
            ? nil
            : (sourceOrientation == outputProps[kCGImagePropertyOrientation] as? Int)

        let sourceTimezone = sourceExif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let timezonePreserved: Bool? = sourceTimezone == nil
            ? nil
            : (sourceTimezone == outputExif?[kCGImagePropertyExifOffsetTimeOriginal] as? String)

        // Best-effort, checked-not-guaranteed (Key Technical Decisions:
        // "lens info stored in proprietary MakerNote/XMP is best-effort,
        // not guaranteed").
        let sourceLens = sourceExif?[kCGImagePropertyExifLensModel] as? String
        let lensPreserved: Bool? = sourceLens == nil
            ? nil
            : (sourceLens == outputExif?[kCGImagePropertyExifLensModel] as? String)

        return MetadataFidelityResult(
            gpsPreserved: gpsPreserved,
            dateTimeOriginalPreserved: dateTimeOriginalPreserved,
            cameraMakeModelPreserved: cameraMakeModelPreserved,
            orientationPreserved: orientationPreserved,
            timezonePreserved: timezonePreserved,
            lensPreserved: lensPreserved
        )
    }

    private static func gpsMatches(_ source: [CFString: Any]?, _ output: [CFString: Any]?) -> Bool {
        guard
            let source, let output,
            let sourceLat = source[kCGImagePropertyGPSLatitude] as? Double,
            let outputLat = output[kCGImagePropertyGPSLatitude] as? Double,
            let sourceLon = source[kCGImagePropertyGPSLongitude] as? Double,
            let outputLon = output[kCGImagePropertyGPSLongitude] as? Double
        else {
            return false
        }
        // Small tolerance for rational-number rounding through the EXIF
        // GPS encoding, not because we expect meaningful drift.
        return abs(sourceLat - outputLat) < 0.0001 && abs(sourceLon - outputLon) < 0.0001
    }

    private static func properties(of url: URL) -> [CFString: Any]? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }
        return props
    }
}
