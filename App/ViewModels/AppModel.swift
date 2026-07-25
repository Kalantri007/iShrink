import Foundation
import SwiftUI
import AppKit
import iShrinkCore

// iShrink Phase 1 plan, U8 "App UI: permission → scan → analytics →
// selection → confirmation".
//
// `@MainActor` observable app state tying the five U8 screens together.
// Kept intentionally thin (plan: "this is Phase 1 UI wiring, not a full
// app; don't over-build navigation infrastructure beyond what these 5
// screens need") — a single linear `Stage` enum plus one modal flag for the
// iCloud first-run question, rather than a generic navigation stack/router.
// U9's `CompressionRunView`/`ReportView` are out of scope here; the
// "Start Compression" action on `ConfirmationView` is a stub this unit
// leaves for U9 to wire to `CompressionPipeline`.

/// Persists the one-time "does this Mac have iCloud Photos enabled?" answer
/// (R6 / plan "iCloud first-run question") behind a small injectable seam,
/// so `AppModel`'s "ask once, remember the answer" behavior isn't hard-wired
/// to `UserDefaults`. Deliberately minimal — a single optional `Bool`, not a
/// general persistence layer (plan: "your call on how much to abstract this,
/// but don't over-engineer a whole persistence layer for one boolean").
protocol ICloudPreferenceStoring: AnyObject {
    var iCloudPhotosEnabled: Bool? { get set }
}

/// Real, `UserDefaults`-backed conformer used in production.
final class UserDefaultsICloudPreferenceStore: ICloudPreferenceStoring {
    private static let key = "iShrink.iCloudPhotosEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var iCloudPhotosEnabled: Bool? {
        get { defaults.object(forKey: Self.key) as? Bool }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// The five U8 screens, in the order the plan's flow visits them
    /// (Scan → Analyze/estimate → Select → Confirm; permission gates entry
    /// to all of it). A flat enum is enough for this unit's linear flow —
    /// no back-stack is needed since each stage's "back" affordance (where
    /// one exists) just calls the relevant `proceedTo...`/`stage =` setter
    /// directly.
    enum Stage: Equatable {
        case permission
        case scanning
        case analytics
        case selection
        case confirmation
    }

    @Published private(set) var stage: Stage
    @Published private(set) var authState: AuthState

    /// Whether the one-time iCloud question modal should be presented.
    @Published var showICloudQuestion = false
    @Published private(set) var iCloudPhotosEnabled: Bool?
    /// Persistent, dismissible banner shown on `AnalyticsDashboardView`/
    /// `SelectionView` when the answer was "yes" (plan: "sets expectations
    /// ... does not change the exclusion logic").
    @Published var showICloudBanner: Bool

    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var isScanning = false
    @Published private(set) var scanWasCancelled = false
    @Published private(set) var scanStartedAt: Date?

    @Published private(set) var classifiedAssets: [ClassifiedAsset] = []
    @Published private(set) var analytics: StorageAnalytics?
    @Published private(set) var savingsEstimate: SavingsEstimator.Estimate?

    @Published var selectionFilter = SelectionFilter()
    @Published private(set) var selection: [ClassifiedAsset] = []

    @Published var destinationURL: URL?
    @Published private(set) var destinationValidation: DestinationValidation?
    @Published var cloudSyncAcknowledged = false

    let authorization: PhotoAuthorization
    private let library: PhotoLibraryProviding
    private let classifier: MediaClassifier
    private let iCloudStore: ICloudPreferenceStoring
    private var scanTask: Task<Void, Never>?

    init(
        // `PhotoAuthorization` is `@MainActor`-isolated, and a default
        // parameter *expression* is evaluated outside the initializer's own
        // isolation context (a Swift quirk, not specific to this type) —
        // so it can't be constructed as a plain default argument value here.
        // `nil` defaults to constructing the real one below, inside the
        // (actually MainActor-isolated) init body.
        authorization: PhotoAuthorization? = nil,
        library: PhotoLibraryProviding = PhotoKitLibrary(),
        classifier: MediaClassifier = MediaClassifier(),
        iCloudStore: ICloudPreferenceStoring = UserDefaultsICloudPreferenceStore()
    ) {
        let resolvedAuthorization = authorization ?? PhotoAuthorization()
        self.authorization = resolvedAuthorization
        self.library = library
        self.classifier = classifier
        self.iCloudStore = iCloudStore
        self.authState = resolvedAuthorization.state
        let storedICloudPreference = iCloudStore.iCloudPhotosEnabled
        self.iCloudPhotosEnabled = storedICloudPreference
        self.showICloudBanner = storedICloudPreference == true
        self.stage = resolvedAuthorization.state == .authorized ? .scanning : .permission
        if resolvedAuthorization.state == .authorized {
            beginScan()
        }
    }

    // MARK: - Permission (R7)

    func requestPhotoAccess() async {
        authState = await authorization.requestAccess()
        advancePastPermissionGateIfNeeded()
    }

    /// Called on `NSApplication.didBecomeActiveNotification` (wired in
    /// `iShrinkApp`), so a user who grants access in System Settings
    /// advances past the gate without relaunching (plan: "Re-check
    /// authorization on app foreground").
    func refreshAuthorizationOnForeground() {
        guard stage == .permission else { return }
        authState = authorization.refresh()
        advancePastPermissionGateIfNeeded()
    }

    private func advancePastPermissionGateIfNeeded() {
        guard stage == .permission, authState == .authorized else { return }
        if iCloudPhotosEnabled == nil {
            showICloudQuestion = true
        }
        beginScan()
    }

    // MARK: - iCloud first-run question (R6)

    func answerICloudQuestion(enabled: Bool) {
        iCloudPhotosEnabled = enabled
        iCloudStore.iCloudPhotosEnabled = enabled
        showICloudBanner = enabled
        showICloudQuestion = false
    }

    // MARK: - Scan (R1/R2/R11)

    func beginScan() {
        scanTask?.cancel()
        stage = .scanning
        isScanning = true
        scanWasCancelled = false
        scanStartedAt = Date()
        scanProgress = nil
        classifiedAssets = []

        let scanner = LibraryScanner(library: library)
        let classifier = self.classifier

        scanTask = Task { [weak self] in
            // Accumulate into an actor, not a plain captured `var` — the
            // `onRecord` callback is `@Sendable` (`LibraryScanner.scan`'s
            // signature), and the compiler correctly flags an
            // unsynchronized mutation of a captured var from inside a
            // `@Sendable` closure even though this particular scanner only
            // ever calls it sequentially. Mirrors the `ScanCollector` test
            // helper's shape (`LibraryScannerTests.swift`).
            let collector = ScanRecordCollector()
            await scanner.scan(
                onRecord: { record in await collector.add(record) },
                onProgress: { progress in
                    await MainActor.run { self?.scanProgress = progress }
                }
            )
            let collected = await collector.records

            var classified: [ClassifiedAsset] = []
            if !Task.isCancelled {
                classified.reserveCapacity(collected.count)
                for record in collected {
                    if Task.isCancelled { break }
                    classified.append(await classifier.classify(record))
                }
            }

            await MainActor.run {
                guard let self else { return }
                if Task.isCancelled {
                    self.isScanning = false
                    self.scanWasCancelled = true
                    return
                }
                self.finishScan(with: classified)
            }
        }
    }

    /// Cancel affordance for a long 100k-asset scan (plan: "with a Cancel
    /// affordance to abort a long scan without force-quitting").
    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        scanWasCancelled = true
    }

    private func finishScan(with classified: [ClassifiedAsset]) {
        classifiedAssets = classified
        isScanning = false

        let aggregated = StorageAnalytics.aggregate(classified)
        analytics = aggregated

        var compressibleBytesByCodec: [MediaCodec: Int64] = [:]
        for asset in classified where asset.eligibility == .compressible {
            compressibleBytesByCodec[asset.codec, default: 0] += asset.record.byteSize
        }
        savingsEstimate = SavingsEstimator.estimate(compressibleBytesByCodec: compressibleBytesByCodec)

        selectionFilter = .none
        selection = SelectionRules.smartDefault(classified)
        stage = .analytics
    }

    // MARK: - Selection (R8's entry point; smart default + filters)

    /// Re-applies `selectionFilter` to `classifiedAssets`. `SelectionView`
    /// calls this after changing the filter; all the actual predicate logic
    /// lives in `SelectionRules` (Core), not here.
    func updateSelection() {
        selection = SelectionRules.apply(selectionFilter, to: classifiedAssets)
    }

    var zeroSelectionReason: ZeroSelectionReason? {
        SelectionRules.zeroSelectionReason(filter: selectionFilter, classified: classifiedAssets)
    }

    func proceedToSelection() {
        stage = .selection
    }

    func proceedToConfirmation() {
        updateSelection()
        destinationValidation = destinationURL.map { DestinationValidator.validate(destination: $0) }
        cloudSyncAcknowledged = false
        stage = .confirmation
    }

    func backToAnalytics() {
        stage = .analytics
    }

    func backToSelection() {
        stage = .selection
    }

    // MARK: - Confirmation / destination (R8)

    /// Confirmation-screen numbers for the **current selection**, not the
    /// whole library (plan Integration test scenario).
    var confirmationSummary: ConfirmationSummary {
        SelectionRules.confirmationSummary(for: selection)
    }

    /// Presents `NSOpenPanel` for the output-folder picker (plan:
    /// "output-folder picker (`NSOpenPanel`)") and validates the choice via
    /// `DestinationValidator`.
    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for the compressed HEIC output. Your Photos library is never modified."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationURL = url
        destinationValidation = DestinationValidator.validate(destination: url)
        cloudSyncAcknowledged = false
    }

    /// Whether `ConfirmationView`'s Start button may be enabled: a
    /// non-empty selection, a writable destination, and — if the
    /// destination resolves under a known cloud-sync container — explicit
    /// acknowledgement of that warning (plan: "warns with explicit
    /// acknowledgement").
    var canStartCompression: Bool {
        guard !selection.isEmpty else { return false }
        guard let validation = destinationValidation, !validation.isRejected else { return false }
        if validation.requiresCloudSyncAcknowledgement, !cloudSyncAcknowledged {
            return false
        }
        return true
    }
}

/// Actor-isolated accumulator for `beginScan()`'s scan results — see the
/// call site's comment for why a plain captured `var` isn't safe here.
private actor ScanRecordCollector {
    private(set) var records: [AssetRecord] = []

    func add(_ record: AssetRecord) {
        records.append(record)
    }
}
