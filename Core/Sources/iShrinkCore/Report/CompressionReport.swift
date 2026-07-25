import Foundation
import CoreGraphics
import ImageIO

// iShrink Phase 1 plan, U9 "App UI: compression run & report".
//
// The post-run report (R12): total storage saved, compression ratio,
// per-type breakdown, largest savers, and the failure list — derived from
// whatever a run (or a paused-then-resumed run) actually produced, never
// re-deriving anything PhotoKit-specific itself.
//
// Input-shape note (same judgment call U5's `SavingsEstimator` file header
// documents for its own input): neither `PipelineRunResult`/
// `PipelineItemSuccess` (U7) nor `CompressionResult` (U6) alone carries
// everything a report needs per item. `PipelineItemSuccess` only carries
// `outputURL` (the pipeline itself never needs the byte sizes or codec —
// it only needs to know *where the output landed* for its own manifest
// bookkeeping). `CompressionResult` carries the byte sizes and metadata
// fidelity, but not the source *codec* (`ImageCompressor` never sees a
// `MediaCodec` — it just encodes whatever file it's handed) or a
// human-readable filename. So, mirroring U5's established pattern ("accept
// a purpose-built input rather than retrofitting an earlier type"),
// `CompressionReportItem` below is a small, purpose-built value type that a
// caller (the App layer, which has both a `ClassifiedAsset.codec` and a
// `CompressionResult` for every item it successfully compressed) assembles
// per succeeded item. `CompressionReport` itself takes a flat array of
// these plus the pipeline's own `[PipelineFailureLogEntry]` and an
// `excludedCount` — it does no PhotoKit/file work of its own, which is what
// keeps it fully unit-testable without a real compressor or library.
//
// Resumed-run design note (plan: "design this as 'the report can be built
// from the union of two RunManifest-recorded sets of completions' or
// similar — whatever's cleanest given RunManifest's actual shape"):
// `RunManifest`/`ManifestEntry` (U7) is keyed on `localIdentifier` and
// records *that* an item completed plus its output path — it deliberately
// carries no byte-size/codec data (the manifest's whole job is O(1)
// resume-skip bookkeeping, not reporting). So this file does not attempt to
// rebuild a report directly from `ManifestEntry` values. Instead, the
// natural "combined totals across both runs" shape is: whichever caller
// drives `CompressionPipeline` across a pause-then-resume sequence
// maintains its own small `localIdentifier -> CompressionReportItem`
// lookup (built the same way it already resolves `localIdentifier ->
// codec` for every succeeded item), and reads back the *union* of
// completed identifiers from the manifest's durable store (`loadAll()`,
// already public via `ManifestPersisting`) to know which lookup entries to
// include — see `CompressionReportTests.swift`'s resumed-run scenario for
// exactly this, grounded in the real `RunManifest`/`InMemoryManifestStore`
// API rather than a hand-waved array concatenation. `CompressionReport`
// itself stays agnostic of *how* its `succeededItems` array was assembled;
// it only aggregates whatever it's given. Building a full cross-run
// history store is explicitly out of scope (Scope Boundaries: "Cross-run
// compression history: deferred").

/// A GPS coordinate pair, kept as our own tiny type (not a `CLLocation`
/// dependency) purely so a report item can carry an optional coordinate
/// that `CompressionReport.exportText(redactGPS:)` can choose to omit.
public struct GPSCoordinate: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Reads the GPS coordinate embedded in `url`'s image properties, if
    /// any. Used by a real caller (the App layer, after a successful
    /// compression) to populate `CompressionReportItem.gpsCoordinate` from
    /// the freshly-written output file — a real ImageIO read, not a
    /// fabricated value, mirroring `ImageCompressor`'s own
    /// `assessMetadataFidelity` read (which checks *whether* GPS survived,
    /// but does not itself expose the coordinate values a report might want
    /// to show).
    public static func read(from url: URL) -> GPSCoordinate? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
            let longitude = gps[kCGImagePropertyGPSLongitude] as? Double
        else {
            return nil
        }
        let signedLatitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -latitude : latitude
        let signedLongitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -longitude : longitude
        return GPSCoordinate(latitude: signedLatitude, longitude: signedLongitude)
    }
}

/// One successfully-compressed item's outcome, as far as the report needs
/// to know: enough to drive per-type breakdowns, largest-savers, and total
/// bytes saved, without re-deriving any of it from `PipelineItemSuccess`/
/// `CompressionResult` (see file header for why neither alone is enough).
public struct CompressionReportItem: Sendable, Equatable {
    public let localIdentifier: String
    public let filename: String
    public let codec: MediaCodec
    public let inputByteSize: Int64
    public let outputByteSize: Int64

    /// `nil` when the source had no GPS to begin with, or the caller chose
    /// not to read it. Redaction of a *present* coordinate happens at
    /// export time (`CompressionReport.exportText(redactGPS:)`), not here —
    /// this type just carries whatever the caller found.
    public let gpsCoordinate: GPSCoordinate?

    public init(
        localIdentifier: String,
        filename: String,
        codec: MediaCodec,
        inputByteSize: Int64,
        outputByteSize: Int64,
        gpsCoordinate: GPSCoordinate? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.filename = filename
        self.codec = codec
        self.inputByteSize = inputByteSize
        self.outputByteSize = outputByteSize
        self.gpsCoordinate = gpsCoordinate
    }

    public var savedBytes: Int64 { inputByteSize - outputByteSize }
}

/// The post-run compression report (R12, plan U9).
///
/// A plain aggregation over whatever it's constructed with — no PhotoKit,
/// no filesystem access of its own (bar `exportText`'s pure string
/// building), so it's fully unit-testable with hand-built fixtures.
public struct CompressionReport: Sendable, Equatable {
    /// Every item that finished successfully. Order is caller-defined (not
    /// assumed sorted) — `largestSavers(limit:)` does its own sort.
    public let succeededItems: [CompressionReportItem]

    /// Every per-item failure, safe to render/export as-is: identifier,
    /// filename, error code only — never raw EXIF/GPS (already enforced by
    /// `PipelineFailureLogEntry`'s own shape, U7).
    public let failures: [PipelineFailureLogEntry]

    /// How many selected items were excluded before compression was even
    /// attempted (e.g. a re-classification/second-guard refusal at
    /// `CompressionPolicy` time) — distinct from `failures`, which only
    /// covers items that were *attempted* and then failed. Needed for the
    /// plan's own test scenario 1 ("90 ok, 10 excluded, 0 failed").
    public let excludedCount: Int

    public init(
        succeededItems: [CompressionReportItem],
        failures: [PipelineFailureLogEntry],
        excludedCount: Int
    ) {
        self.succeededItems = succeededItems
        self.failures = failures
        self.excludedCount = excludedCount
    }

    // MARK: - Totals

    public var totalInputBytes: Int64 {
        succeededItems.reduce(0) { $0 + $1.inputByteSize }
    }

    public var totalOutputBytes: Int64 {
        succeededItems.reduce(0) { $0 + $1.outputByteSize }
    }

    public var totalSavedBytes: Int64 {
        totalInputBytes - totalOutputBytes
    }

    /// Items actually attempted (succeeded + failed) — excludes
    /// `excludedCount`, which was never attempted at all.
    public var attemptedCount: Int {
        succeededItems.count + failures.count
    }

    /// Explicit all-failed/zero-success state (plan: "when no item
    /// succeeded, the report renders as a failure summary"). Deliberately
    /// requires at least one failure — a run that excluded everything and
    /// attempted nothing at all is a different (out-of-scope-here) "nothing
    /// to compress" state, not a failed run.
    public var isZeroSuccess: Bool {
        succeededItems.isEmpty && !failures.isEmpty
    }

    /// Fraction of original bytes remaining after compression (same
    /// convention as `SavingsEstimator.RatioRange` — smaller means more
    /// saved). `nil` precisely when there is nothing successful to compute
    /// a ratio from, so callers never divide by zero (plan test scenario
    /// 3) and never render a ratio on a failure-summary screen.
    public var compressionRatio: Double? {
        guard !succeededItems.isEmpty, totalInputBytes > 0 else { return nil }
        return Double(totalOutputBytes) / Double(totalInputBytes)
    }

    // MARK: - Per-type breakdown

    public struct CodecBreakdown: Sendable, Equatable {
        public let count: Int
        public let inputBytes: Int64
        public let outputBytes: Int64

        public init(count: Int, inputBytes: Int64, outputBytes: Int64) {
            self.count = count
            self.inputBytes = inputBytes
            self.outputBytes = outputBytes
        }

        public var savedBytes: Int64 { inputBytes - outputBytes }
    }

    /// Per-source-codec rollup of `succeededItems` only (an excluded or
    /// failed item never contributed bytes, so it never appears here).
    public var byCodec: [MediaCodec: CodecBreakdown] {
        var counts: [MediaCodec: Int] = [:]
        var inputBytes: [MediaCodec: Int64] = [:]
        var outputBytes: [MediaCodec: Int64] = [:]

        for item in succeededItems {
            counts[item.codec, default: 0] += 1
            inputBytes[item.codec, default: 0] += item.inputByteSize
            outputBytes[item.codec, default: 0] += item.outputByteSize
        }

        var result: [MediaCodec: CodecBreakdown] = [:]
        for codec in counts.keys {
            result[codec] = CodecBreakdown(
                count: counts[codec] ?? 0,
                inputBytes: inputBytes[codec] ?? 0,
                outputBytes: outputBytes[codec] ?? 0
            )
        }
        return result
    }

    /// The `limit` succeeded items with the largest absolute bytes saved,
    /// descending. A tie keeps the caller's original relative order
    /// (`sorted` is stable).
    public func largestSavers(limit: Int = 10) -> [CompressionReportItem] {
        Array(succeededItems.sorted { $0.savedBytes > $1.savedBytes }.prefix(max(0, limit)))
    }

    // MARK: - Export (R12: GPS redaction)

    /// Renders a plain-text export of this report.
    ///
    /// - Parameter redactGPS: when `true` (the default), every item's
    ///   `gpsCoordinate` — even if populated — is omitted from the
    ///   rendered text. Exact photo locations only ever appear in the
    ///   export when this is explicitly `false`; the plan requires the
    ///   caller (`ReportView`) to gate flipping it behind an explicit
    ///   confirmation dialog ("This report will include exact photo
    ///   locations — continue?"), not a bare toggle — that confirmation is
    ///   a UI-level responsibility this type doesn't itself enforce (it has
    ///   no notion of "confirmed"), but it does guarantee the redaction
    ///   default and behavior share this one code path, so there's no
    ///   second, forgettable place raw coordinates could leak from.
    public func exportText(redactGPS: Bool = true) -> String {
        var lines: [String] = ["iShrink Compression Report", ""]

        if isZeroSuccess {
            lines.append("All \(failures.count) item(s) failed to compress. No output was produced.")
        } else {
            lines.append("Compressed \(succeededItems.count) item(s).")
            lines.append("Total saved: \(totalSavedBytes) bytes (\(totalInputBytes) -> \(totalOutputBytes)).")
            if let ratio = compressionRatio {
                lines.append(String(format: "Compression ratio: %.1f%% of original size.", ratio * 100))
            }
        }

        if excludedCount > 0 {
            lines.append("\(excludedCount) item(s) excluded (not eligible for compression).")
        }

        if !failures.isEmpty {
            lines.append("")
            lines.append("Failures:")
            for failure in failures {
                let retriedNote = failure.wasRetried ? ", retried" : ""
                lines.append("- \(failure.filename) [\(failure.errorCode)\(retriedNote)]")
            }
        }

        if !succeededItems.isEmpty {
            lines.append("")
            lines.append("Per-type breakdown:")
            for (codec, breakdown) in byCodec.sorted(by: { "\($0.key)" < "\($1.key)" }) {
                lines.append("- \(codec): \(breakdown.count) item(s), saved \(breakdown.savedBytes) bytes")
            }

            lines.append("")
            lines.append("Items:")
            for item in succeededItems {
                var line = "- \(item.filename): \(item.inputByteSize) -> \(item.outputByteSize) bytes"
                if !redactGPS, let gps = item.gpsCoordinate {
                    line += " [GPS \(gps.latitude), \(gps.longitude)]"
                }
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n")
    }
}
