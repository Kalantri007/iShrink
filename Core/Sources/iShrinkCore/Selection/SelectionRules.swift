import Foundation

// iShrink Phase 1 plan, U8 "App UI" — `SelectionView`'s filter/predicate
// logic and the confirmation-number math, both kept in Core so they're
// unit-testable headlessly (plan: "Put the filter/predicate logic in a Core
// `SelectionRules` type so it's unit-tested headlessly" / "selection/filter/
// validation logic lives in Core, not the View").

/// A rule-based filter layered on top of the smart default
/// (`SelectionRules.smartDefault`, itself an unconditional "every
/// `.compressible` asset" filter). Every field is optional; `nil` means
/// "don't filter on this dimension" — an unfiltered `SelectionFilter` (see
/// `.none`) selects exactly the smart default.
public struct SelectionFilter: Sendable, Equatable {
    /// Restrict to these source codecs. `nil` or empty means any codec.
    public var codecs: Set<MediaCodec>?

    /// Only assets at least this many bytes. `nil` means no size threshold.
    public var minimumBytes: Int64?

    /// Only assets created strictly before this date (e.g. "older than 2
    /// years" becomes `Date() - 2 years`). `nil` means no age filter. An
    /// asset with no `creationDate` never matches a non-nil age filter —
    /// there's nothing to compare it against, so it's excluded rather than
    /// assumed to pass.
    public var createdBefore: Date?

    public init(
        codecs: Set<MediaCodec>? = nil,
        minimumBytes: Int64? = nil,
        createdBefore: Date? = nil
    ) {
        self.codecs = codecs
        self.minimumBytes = minimumBytes
        self.createdBefore = createdBefore
    }

    /// No filtering at all — resolves to exactly the smart default.
    public static let none = SelectionFilter()
}

/// Why the current filter/library combination produced zero selected
/// items. The plan requires these two to read differently (U8 test
/// scenario 2) so a disabled Start button on `SelectionView`/
/// `ConfirmationView` is never left unexplained.
public enum ZeroSelectionReason: Sendable, Equatable {
    /// The library has at least one `.compressible` asset, but the active
    /// filter matched none of them — the fix is to widen the filter.
    case filterMatchesNothing

    /// The whole library has zero `.compressible` assets (e.g. everything
    /// is already HEIC, a RAW/HDR master, iCloud-only, Live, or edited) —
    /// no filter change would help; this is independent of whatever filter
    /// happens to be set.
    case libraryHasNothingCompressible

    /// User-facing copy for this zero-state. Deliberately distinct between
    /// the two cases (plan: "these must read differently").
    public var message: String {
        switch self {
        case .filterMatchesNothing:
            return "No photos match this filter. Try widening the type, size, or age filter."
        case .libraryHasNothingCompressible:
            return "Nothing in this library is compressible right now — everything is already HEIC, a RAW/HDR master, iCloud-only, a Live Photo, or an edited photo."
        }
    }
}

/// Confirmation-screen numbers for one specific selection: item count,
/// current total size, and the savings estimate computed **from that
/// selection alone**. Never derived from the whole library (plan U8
/// Integration scenario: "confirmation numbers equal the estimator output
/// for the selected subset, not the whole library").
public struct ConfirmationSummary: Sendable, Equatable {
    public let itemCount: Int
    public let currentBytes: Int64
    public let estimate: SavingsEstimator.Estimate

    public init(itemCount: Int, currentBytes: Int64, estimate: SavingsEstimator.Estimate) {
        self.itemCount = itemCount
        self.currentBytes = currentBytes
        self.estimate = estimate
    }
}

/// Smart-default + rule-filter selection logic (plan Approach, U8
/// `SelectionView`), plus the zero-state and confirmation-number helpers
/// the plan's test scenarios call for at the Core level. Pure namespace —
/// nothing to construct.
public enum SelectionRules {
    /// The smart default: every `.compressible` asset, nothing else. This
    /// unconditionally excludes every `.excluded(reason)` and
    /// `.analyticsOnly` asset (plan test scenario 3: "smart default
    /// excludes all `.excluded(reason)` assets automatically").
    public static func smartDefault(_ classified: [ClassifiedAsset]) -> [ClassifiedAsset] {
        classified.filter { $0.eligibility == .compressible }
    }

    /// Applies `filter` on top of the smart default. An unfiltered
    /// (`.none`) filter returns exactly the smart default.
    public static func apply(_ filter: SelectionFilter, to classified: [ClassifiedAsset]) -> [ClassifiedAsset] {
        smartDefault(classified).filter { asset in
            if let codecs = filter.codecs, !codecs.isEmpty, !codecs.contains(asset.codec) {
                return false
            }
            if let minimumBytes = filter.minimumBytes, asset.record.byteSize < minimumBytes {
                return false
            }
            if let createdBefore = filter.createdBefore {
                guard let creationDate = asset.record.creationDate, creationDate < createdBefore else {
                    return false
                }
            }
            return true
        }
    }

    /// Which zero-state message applies (if any) for the current
    /// filter/library combination. `nil` means the filtered selection is
    /// non-empty — no zero-state to show.
    public static func zeroSelectionReason(
        filter: SelectionFilter,
        classified: [ClassifiedAsset]
    ) -> ZeroSelectionReason? {
        guard apply(filter, to: classified).isEmpty else { return nil }
        return smartDefault(classified).isEmpty ? .libraryHasNothingCompressible : .filterMatchesNothing
    }

    /// Confirmation-screen numbers computed from `selection` alone — never
    /// from the whole library. Groups `selection`'s bytes by codec and
    /// feeds them straight into `SavingsEstimator.estimate`.
    public static func confirmationSummary(
        for selection: [ClassifiedAsset],
        ratios: [MediaCodec: SavingsEstimator.RatioRange] = SavingsEstimator.defaultRatios
    ) -> ConfirmationSummary {
        var bytesByCodec: [MediaCodec: Int64] = [:]
        var totalBytes: Int64 = 0
        for asset in selection {
            bytesByCodec[asset.codec, default: 0] += asset.record.byteSize
            totalBytes += asset.record.byteSize
        }
        let estimate = SavingsEstimator.estimate(compressibleBytesByCodec: bytesByCodec, ratios: ratios)
        return ConfirmationSummary(itemCount: selection.count, currentBytes: totalBytes, estimate: estimate)
    }
}
