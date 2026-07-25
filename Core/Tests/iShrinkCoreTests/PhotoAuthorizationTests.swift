import Photos
import Testing
@testable import iShrinkCore

// iShrink Phase 1 plan, U2 "Photos authorization service" test scenarios.
//
// All tests use `FakeStatusSource` below instead of real PhotoKit — no real
// TCC prompt or photo library is touched, matching the plan's verification
// requirement ("no real TCC needed to run the suite").

/// Injectable fake standing in for real PhotoKit. `currentStatus(for:)`
/// walks through a fixed sequence of statuses, one per call (staying on the
/// last value once exhausted), so tests can model a status changing between
/// successive checks (foreground re-check, `poll()`).
final class FakeStatusSource: PhotoAuthorizationStatusSource, @unchecked Sendable {
    private var statuses: [PHAuthorizationStatus]
    private var index = 0
    private let requestResult: PHAuthorizationStatus

    init(statuses: [PHAuthorizationStatus], requestResult: PHAuthorizationStatus? = nil) {
        precondition(!statuses.isEmpty, "FakeStatusSource needs at least one status")
        self.statuses = statuses
        self.requestResult = requestResult ?? statuses[0]
    }

    func currentStatus(for accessLevel: PHAccessLevel) -> PHAuthorizationStatus {
        let value = statuses[index]
        if index < statuses.count - 1 {
            index += 1
        }
        return value
    }

    func requestAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus {
        requestResult
    }
}

@MainActor
@Test func happyPathAuthorizedMapsToAuthorizedState() {
    let gate = PhotoAuthorization(source: FakeStatusSource(statuses: [.authorized]))
    #expect(gate.state == .authorized)
}

@MainActor
@Test func limitedMapsToNeedsFullAccessDefensively() {
    // macOS `.limited` is really an iOS concept (research: defensive-only on
    // macOS), but PhotoAuthorization must still map it safely if PhotoKit
    // ever reports it.
    let gate = PhotoAuthorization(source: FakeStatusSource(statuses: [.limited]))
    #expect(gate.state == .needsFullAccess)
}

@MainActor
@Test func deniedAndNeedsFullAccessSurfaceSettingsDeepLink() {
    let deniedGate = PhotoAuthorization(source: FakeStatusSource(statuses: [.denied]))
    #expect(deniedGate.state == .denied)
    #expect(deniedGate.state.canDeepLinkToSettings)

    let needsFullAccessGate = PhotoAuthorization(source: FakeStatusSource(statuses: [.limited]))
    #expect(needsFullAccessGate.state == .needsFullAccess)
    #expect(needsFullAccessGate.state.canDeepLinkToSettings)
}

@MainActor
@Test func restrictedSurfacesExplanationWithNoSettingsDeepLink() {
    let gate = PhotoAuthorization(source: FakeStatusSource(statuses: [.restricted]))
    #expect(gate.state == .restricted)
    #expect(!gate.state.canDeepLinkToSettings)
    #expect(!gate.state.explanation.isEmpty)
}

@MainActor
@Test func foregroundRecheckDeniedThenAuthorizedCanAdvance() {
    // Status flips .denied -> .authorized between checks (e.g. user granted
    // access in System Settings while iShrink was backgrounded). `refresh()`
    // must pick this up without a relaunch.
    let source = FakeStatusSource(statuses: [.denied, .authorized])
    let gate = PhotoAuthorization(source: source)
    #expect(gate.state == .denied)

    let refreshed = gate.refresh()
    #expect(refreshed == .authorized)
    #expect(gate.state == .authorized)
}

@MainActor
@Test func pollReportsRevocationWhenAuthorizedTransitionsToDenied() {
    let source = FakeStatusSource(statuses: [.authorized, .denied])
    let gate = PhotoAuthorization(source: source)
    #expect(gate.state == .authorized)

    let result = gate.poll()
    #expect(result == .revoked(previous: .authorized, current: .denied))
    #expect(gate.state == .denied)
}

@MainActor
@Test func pollReportsUnchangedWhenStatusIsStable() {
    let source = FakeStatusSource(statuses: [.authorized, .authorized])
    let gate = PhotoAuthorization(source: source)

    let result = gate.poll()
    #expect(result == .unchanged(.authorized))
}

@MainActor
@Test func requestAccessWrapsAsyncPhotoKitCallAndUpdatesState() async {
    let source = FakeStatusSource(statuses: [.notDetermined], requestResult: .authorized)
    let gate = PhotoAuthorization(source: source)
    #expect(gate.state == .notDetermined)

    let result = await gate.requestAccess()
    #expect(result == .authorized)
    #expect(gate.state == .authorized)
}
