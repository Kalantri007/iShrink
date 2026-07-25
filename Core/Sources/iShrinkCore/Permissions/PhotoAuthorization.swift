import Photos

// iShrink Phase 1 plan, U2 "Photos authorization service".
//
// `.readWrite` is requested because it is the only macOS `PHAccessLevel` that
// grants full-library read (`.addOnly` cannot read) — see Key Technical
// Decisions "Read-only invariant is enforced, not just asserted". Requesting
// it here does NOT authorize any mutation: `scripts/check-readonly.sh`
// separately guards that `iShrinkCore` never references a PhotoKit mutation
// API. This file only reads/observes authorization state.

/// Sendable, UI-agnostic view of PhotoKit's `PHAuthorizationStatus`.
///
/// macOS only actually produces `.notDetermined` / `.authorized` / `.denied` /
/// `.restricted` in practice; `.limited` is really an iOS concept (partial
/// photo selection), but PhotoKit's status enum is shared across platforms,
/// so `.limited` is mapped here defensively rather than assumed unreachable.
public enum AuthState: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    /// Covers both a real `.limited` status (defensive, macOS shouldn't
    /// produce this) and any future/unknown status PhotoKit might add —
    /// both are treated the same way: the user needs to grant full access.
    case needsFullAccess

    /// Whether the UI (U8) should offer a "Open Settings" deep-link.
    ///
    /// `.denied` and `.needsFullAccess` are user-resolvable via
    /// System Settings > Privacy & Security > Photos. `.restricted` is
    /// enforced by MDM/parental controls and is **not** resolvable by the
    /// user from within this app or from Settings, so no deep-link is
    /// offered — only explanatory copy. `.notDetermined` and `.authorized`
    /// don't need a Settings affordance at all.
    public var canDeepLinkToSettings: Bool {
        switch self {
        case .denied, .needsFullAccess:
            return true
        case .notDetermined, .authorized, .restricted:
            return false
        }
    }

    /// Short, user-facing explanation of the current state, for the U8 gate
    /// screen. Kept here (not in the app target) so the copy stays coupled
    /// to the state it describes.
    public var explanation: String {
        switch self {
        case .notDetermined:
            return "iShrink hasn't asked for Photos access yet."
        case .authorized:
            return "Photos access is granted."
        case .denied:
            return "Photos access was denied. Open Settings to grant iShrink access to your photo library."
        case .needsFullAccess:
            return "iShrink needs full access to your photo library. Open Settings to grant full access."
        case .restricted:
            return "Photos access is restricted on this Mac by a device policy (such as parental controls or an organization's device management), and can't be changed from within iShrink or from Settings."
        }
    }
}

/// Result of a `PhotoAuthorization.poll()` call: either nothing of note
/// changed, or access was revoked since the last check (`.authorized` →
/// anything else), which the compression pipeline should treat as a signal
/// to pause safely at the next batch boundary.
public enum AuthPollResult: Sendable, Equatable {
    case unchanged(AuthState)
    case revoked(previous: AuthState, current: AuthState)

    /// The freshest known state, regardless of case.
    public var currentState: AuthState {
        switch self {
        case .unchanged(let state):
            return state
        case .revoked(_, let current):
            return current
        }
    }
}

/// The raw PhotoKit call, kept behind a tiny protocol so
/// `PhotoAuthorization`'s state-mapping logic is unit-testable with an
/// injected fake — no real TCC prompt or real photo library needed to run
/// the test suite (plan U2 verification: "no real TCC needed to run the
/// suite").
public protocol PhotoAuthorizationStatusSource: Sendable {
    /// Synchronous, non-prompting read of the current status — mirrors
    /// `PHPhotoLibrary.authorizationStatus(for:)`.
    func currentStatus(for accessLevel: PHAccessLevel) -> PHAuthorizationStatus

    /// Prompts the user if needed and returns the resulting status — mirrors
    /// the async `PHPhotoLibrary.requestAuthorization(for:)`.
    func requestAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus
}

/// Real PhotoKit-backed implementation used in production.
public struct PhotoKitAuthorizationStatusSource: PhotoAuthorizationStatusSource {
    public init() {}

    public func currentStatus(for accessLevel: PHAccessLevel) -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: accessLevel)
    }

    public func requestAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: accessLevel)
    }
}

/// Photos authorization gate for the scan/compress pipeline.
///
/// Owns the current `AuthState`, requests access on the main actor (PhotoKit
/// authorization UI must be presented from the main thread), and gives the
/// pipeline two distinct ways to re-check status:
///  - `refresh()` — a one-off foreground re-check (e.g. the app became
///    active again after the user visited Settings) that can report the
///    gate is now clear to advance without relaunching.
///  - `poll()` — called by the pipeline at batch boundaries during a run;
///    reports a `.revoked` event specifically when access that was
///    `.authorized` stops being `.authorized`, so the pipeline can pause.
@MainActor
public final class PhotoAuthorization {
    private let source: PhotoAuthorizationStatusSource
    private let accessLevel: PHAccessLevel

    /// The most recently observed state. Updated by `init`, `requestAccess()`,
    /// `refresh()`, and `poll()`.
    public private(set) var state: AuthState

    public init(
        source: PhotoAuthorizationStatusSource = PhotoKitAuthorizationStatusSource(),
        accessLevel: PHAccessLevel = .readWrite
    ) {
        self.source = source
        self.accessLevel = accessLevel
        self.state = Self.map(source.currentStatus(for: accessLevel))
    }

    /// Prompts for access (if `.notDetermined`) or otherwise resolves
    /// immediately, and updates `state` with the result.
    @discardableResult
    public func requestAccess() async -> AuthState {
        let raw = await source.requestAuthorization(for: accessLevel)
        state = Self.map(raw)
        return state
    }

    /// One-off foreground re-check: re-reads the current status without
    /// prompting. Use this when the app returns to the foreground and might
    /// find the user granted access from System Settings in the meantime —
    /// no relaunch needed for the gate to notice.
    @discardableResult
    public func refresh() -> AuthState {
        state = Self.map(source.currentStatus(for: accessLevel))
        return state
    }

    /// Batch-boundary check for the running pipeline: re-reads status and
    /// reports whether access was just revoked (previously `.authorized`,
    /// no longer). The pipeline should treat `.revoked` as "pause safely at
    /// the next opportunity", not "crash".
    public func poll() -> AuthPollResult {
        let previous = state
        let updated = Self.map(source.currentStatus(for: accessLevel))
        state = updated
        if previous == .authorized && updated != .authorized {
            return .revoked(previous: previous, current: updated)
        }
        return .unchanged(updated)
    }

    static func map(_ raw: PHAuthorizationStatus) -> AuthState {
        switch raw {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .limited:
            return .needsFullAccess
        @unknown default:
            return .needsFullAccess
        }
    }
}
