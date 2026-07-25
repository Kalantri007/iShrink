// iShrink Phase 1 plan, U4 "Media classifier & storage analytics" (enum) and
// U8 "App UI" (the copy table added below).
//
// Exclusion classes that `MediaClassifier` (this directory) attaches when it
// marks a photo `.excluded` rather than `.compressible`. Kept in its own
// file per the plan's Output Structure (`Classify/ExclusionReason.swift`),
// because the plan calls for "enum + user-facing copy table" living
// together here. U4 defined the reasons themselves; U8's
// `AnalyticsDashboardView` count-per-reason exclusion summary is the first
// consumer of `displayText` below.

/// Why a photo was excluded from compression eligibility (R3/R5/R6).
///
/// Note: video assets are *not* represented here. Phase 1 excludes video
/// from compression entirely (Scope Boundaries: "No video compression"),
/// but that's a blanket phase limitation, not a per-asset exclusion
/// reason — `MediaClassifier` models it as a distinct `.analyticsOnly`
/// eligibility case instead (see `MediaClassifier.swift`), so it isn't
/// double-counted under any of these reasons.
public enum ExclusionReason: Sendable, Equatable, Hashable, CaseIterable {
    /// RAW/ProRAW master file — Phase 1 never compresses master formats
    /// (R5), detected via `UTType.conforms(to: .rawImage)` so any vendor RAW
    /// UTI (Adobe DNG, Sony ARW, Canon CR2, ...) is caught in one check.
    case rawMaster

    /// HDR — detected via the `.photoHDR` media subtype **or** a gain-map
    /// auxiliary-data probe (the subtype alone under-detects modern
    /// gain-map captures). Phase 1 never silently flattens HDR to SDR (R5);
    /// HDR-preserving transcode is deferred (Scope Boundaries: "HDR-
    /// preserving transcode").
    case hdrUnpreservable

    /// Not locally available (iCloud-only) — Phase 1 processes only
    /// locally-present originals and never triggers a download to check
    /// further (R6). This reason wins over every other classification for
    /// a given asset.
    case iCloudOnly

    /// Already `public.heic`. No resize flag exists yet in Phase 1, so this
    /// is unconditional for now (re-encoding an already-HEIC file with no
    /// resize requested would be pointless churn) — plan: "unless resizing
    /// is explicitly requested" (R3), which Phase 1 doesn't yet expose.
    case alreadyHeic

    /// Live Photo — its still image is excluded rather than exported as an
    /// orphaned still detached from its paired video (analytics stay
    /// honest: we never silently break the Live Photo pairing).
    case livePhoto

    /// Has adjustment data (a user edit present in `resourceKinds`) —
    /// Phase 1 does not re-render user edits, so an edited photo is
    /// excluded rather than exported from its unedited original resource.
    case editedPhoto

    /// Whether this reason is something the user can resolve themselves
    /// from outside iShrink (as opposed to an inherent, unresolvable
    /// property of the asset in Phase 1). This is a small piece of logic
    /// U8's copy table will want (e.g. to decide whether to show a "how to
    /// fix" hint) — it is not itself the UI copy table the plan mentions;
    /// that string table is U8's job.
    public var isUserActionable: Bool {
        switch self {
        case .iCloudOnly:
            // The user can enable "Download Originals to this Mac" in the
            // Photos app, or wait for iCloud sync, to make the asset local.
            return true
        case .rawMaster, .hdrUnpreservable, .alreadyHeic, .livePhoto, .editedPhoto:
            return false
        }
    }

    /// User-facing copy table (plan U8: "`ExclusionReason` → copy string
    /// table, defined alongside the enum so phrasing is consistent"). This
    /// is the single source of truth `AnalyticsDashboardView`'s
    /// count-per-reason exclusion summary reads from — the View itself
    /// carries no reason-to-string logic of its own.
    public var displayText: String {
        switch self {
        case .rawMaster:
            return "RAW / ProRAW master file"
        case .hdrUnpreservable:
            return "HDR (can't be preserved yet)"
        case .iCloudOnly:
            return "iCloud-only (not downloaded to this Mac)"
        case .alreadyHeic:
            return "Already HEIC"
        case .livePhoto:
            return "Live Photo"
        case .editedPhoto:
            return "Edited photo"
        }
    }
}
