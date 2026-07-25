// iShrink Phase 1 plan, U6 "Non-destructive HEIC compression engine".
//
// A *second* guard in front of `ImageCompressor`, even though U4's
// `MediaClassifier` already decided eligibility (plan: "a second guard even
// though MediaClassifier/U4 already filtered"). This exists because the
// classified-and-eligibility-checked set that reaches the compressor could
//, in a later unit, be re-selected/re-ordered/replayed (e.g. resume off a
// stale manifest, a UI selection bug) without re-running `MediaClassifier`
// — `CompressionPolicy` is the last line of defense that guarantees the
// compressor itself never runs on RAW/HDR/iCloud-only/already-HEIC/Live/
// edited input, independent of whatever upstream selection logic did.
//
// Deliberately reuses `ExclusionReason` (defined in
// `Classify/ExclusionReason.swift`) rather than inventing a parallel
// "CompressionRefusalReason" enum with the same six cases under different
// names — that duplication is exactly what the plan warns against.

/// What `CompressionPolicy` decided about one classified asset.
public enum CompressionPolicyDecision: Sendable, Equatable {
    /// Eligible — `ImageCompressor` may proceed.
    case proceed

    /// Refused for one of `MediaClassifier`'s exclusion reasons (RAW/
    /// ProRAW, HDR, iCloud-only, already-HEIC, Live Photo, edited photo).
    case refuse(ExclusionReason)

    /// Not a photo-compression candidate at all: video, which `U4` models as
    /// `ClassificationEligibility.analyticsOnly`, a distinct eligibility
    /// tier from `.excluded(reason)` (see that case's doc comment in
    /// `MediaClassifier.swift` — video isn't "a photo iShrink chose not to
    /// touch for a specific cause", it's out of compression scope for the
    /// whole phase). There is no `ExclusionReason` case for "it's a video",
    /// so this is kept as a separate `CompressionPolicyDecision` case rather
    /// than forcing an artificial `ExclusionReason` onto it. In practice the
    /// pipeline never calls `CompressionPolicy` for a video asset — this
    /// case exists so the function stays total instead of crashing if one
    /// ever slipped through.
    case notApplicable
}

/// Eligibility guard from classification + (implicitly, via
/// `ClassifiedAsset.eligibility`) whatever user options `MediaClassifier`
/// was given. Stateless — a namespace, not a type you construct.
public enum CompressionPolicy {
    /// Decides whether `asset` may be handed to `ImageCompressor`.
    ///
    /// This does not re-derive eligibility from scratch (that would
    /// duplicate `MediaClassifier`'s logic); it re-asserts the *result* of
    /// that classification as a guard the compressor can trust
    /// independently of how `asset` arrived here.
    public static func evaluate(_ asset: ClassifiedAsset) -> CompressionPolicyDecision {
        switch asset.eligibility {
        case .compressible:
            return .proceed
        case .excluded(let reason):
            return .refuse(reason)
        case .analyticsOnly:
            return .notApplicable
        }
    }
}
