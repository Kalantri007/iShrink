import Foundation
import SwiftUI
import AppKit
import CryptoKit
import iShrinkCore

// iShrink Phase 1 plan, U8 "App UI: permission → scan → analytics →
// selection → confirmation" (original five stages), extended by U9 "App
// UI: compression run & report" with two more (`.running`/`.report`).
//
// `@MainActor` observable app state tying all seven screens together.
// Kept intentionally thin (plan: "this is Phase 1 UI wiring, not a full
// app; don't over-build navigation infrastructure beyond what these
// screens need") — a single linear `Stage` enum plus one modal flag for the
// iCloud first-run question, rather than a generic navigation stack/router.
//
// U9 additions: `startCompressionFlow()` (called from `ConfirmationView`'s
// Start button) wires the real `CompressionPipeline` (U7) to a real,
// PhotoKit-backed `ItemCompressing` conformer (`PhotoKitItemCompressor`,
// Core) and a durable `RunManifest`, with a Resume/Discard prompt when an
// incomplete manifest already exists for the same selection+destination.
// `CompressionRunView` renders the live run; `ReportView` renders the
// `CompressionReport` built from the run's results once it ends.

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
        case running
        case report
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

    // MARK: - Compression run & report (R9/R10/R11/R12, U9)

    /// Live "items done/total, current file" state `CompressionRunView`
    /// renders — built from `CompressionPipeline.run`'s new
    /// `onItemStarted`/`onItemFinished` hooks (U9's additive extension to
    /// U7's pipeline; neither hook carries byte data, only identity — see
    /// `CompressionPipeline.swift`).
    struct CompressionRunProgress: Equatable {
        var itemsDone: Int
        var itemsTotal: Int
        var currentFilename: String?
    }

    /// Shown instead of silently re-running when an incomplete manifest is
    /// found for the same selection+destination (plan: "present a Resume /
    /// Discard prompt (items done/remaining) rather than silently
    /// re-running").
    struct ResumePrompt: Equatable {
        var itemsDone: Int
        var itemsRemaining: Int
    }

    @Published private(set) var runProgress: CompressionRunProgress?
    @Published private(set) var pauseReason: PauseReason?
    @Published var showCancelConfirmation = false
    @Published private(set) var resumePrompt: ResumePrompt?
    @Published private(set) var runningSavedBytes: Int64 = 0
    @Published private(set) var runStartedAt: Date?
    @Published private(set) var compressionReport: CompressionReport?

    /// GPS export gating (R12): flipping this to `true` only ever happens
    /// via `confirmIncludeGPSInExport()`, never directly — see that
    /// method's doc comment.
    @Published private(set) var gpsIncludedInExport = false
    @Published var showGPSExportConfirmation = false

    private var pipeline: CompressionPipeline?
    private var runTask: Task<Void, Never>?
    private var reportAccumulator: CompressionReportAccumulator?
    private var runManifest: RunManifest?
    private var pipelineItems: [PipelineItem] = []

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
        classifier: MediaClassifier = MediaClassifier(gainMapProbe: PhotoKitGainMapProbe()),
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

    // MARK: - Starting a run (R9/R10/R11, U9)

    /// `ConfirmationView`'s Start button calls this. Before running
    /// anything, checks the durable manifest for the same selection +
    /// destination pair for an *incomplete* prior run and, if one exists,
    /// shows the Resume/Discard prompt instead of silently re-running (plan
    /// "Resume affordance"). A fresh or already-fully-complete manifest
    /// starts the run immediately.
    func startCompressionFlow() {
        guard let destinationURL, canStartCompression else { return }

        let items = selection.map { asset in
            PipelineItem(
                localIdentifier: asset.record.localIdentifier,
                sourceURL: Self.sourceStagingURL(
                    for: asset.record.localIdentifier, in: Self.sourceStagingDirectory()
                )
            )
        }
        pipelineItems = items

        let manifestStore = FileManifestStore(
            directory: Self.manifestDirectory(destination: destinationURL, selection: selection)
        )
        let manifest = RunManifest(store: manifestStore)
        runManifest = manifest
        stage = .running
        pauseReason = nil
        runProgress = CompressionRunProgress(itemsDone: 0, itemsTotal: items.count, currentFilename: nil)

        Task { [weak self] in
            try? await manifest.load()
            let doneCount = await manifest.completedCount
            await MainActor.run {
                guard let self else { return }
                // Reflect items the manifest already recorded complete
                // (e.g. a crash-then-resume) so the progress bar starts
                // from the true count instead of always from 0.
                self.runProgress?.itemsDone = doneCount
                if doneCount > 0, doneCount < items.count {
                    self.resumePrompt = ResumePrompt(itemsDone: doneCount, itemsRemaining: items.count - doneCount)
                } else {
                    self.resumePrompt = nil
                    self.beginCompressionRun()
                }
            }
        }
    }

    /// User chose "Resume" on the resume/discard prompt: proceed with the
    /// existing (already-loaded) manifest, skipping items it already
    /// recorded complete.
    func resumeFromPrompt() {
        resumePrompt = nil
        beginCompressionRun()
    }

    /// User chose "Discard": abandon the prior run's recorded progress and
    /// start over from zero. Clears the manifest's durable state first so a
    /// fresh run doesn't just re-load the old completions on its own
    /// `load()` call.
    func discardAndRestartFromPrompt() {
        resumePrompt = nil
        guard let destinationURL else { return }
        let directory = Self.manifestDirectory(destination: destinationURL, selection: selection)
        try? FileManager.default.removeItem(at: directory)
        runManifest = RunManifest(store: FileManifestStore(directory: directory))
        beginCompressionRun()
    }

    /// Sets up the real `CompressionPipeline` (first call) and kicks off —
    /// or resumes — the run task. Safe to call again after a pause: the
    /// pipeline instance and manifest are reused, and `RunManifest`'s own
    /// skip-if-complete logic means already-finished items aren't redone.
    private func beginCompressionRun() {
        guard let destinationURL, let runManifest else { return }
        stage = .running
        pauseReason = nil
        runStartedAt = runStartedAt ?? Date()

        let accumulator = reportAccumulator ?? CompressionReportAccumulator()
        reportAccumulator = accumulator

        let currentPipeline: CompressionPipeline
        if let pipeline {
            currentPipeline = pipeline
        } else {
            let tempDirectory = Self.sourceStagingDirectory()
            let imageCompressor = ImageCompressor(tempDirectory: tempDirectory)
            var assetInfo: [String: PhotoKitItemCompressor.AssetReportInfo] = [:]
            var policyDecisions: [String: CompressionPolicyDecision] = [:]
            for asset in selection {
                assetInfo[asset.record.localIdentifier] = PhotoKitItemCompressor.AssetReportInfo(
                    filename: asset.record.originalFilename ?? asset.record.localIdentifier,
                    codec: asset.codec
                )
                policyDecisions[asset.record.localIdentifier] = CompressionPolicy.evaluate(asset)
            }
            let compressor = PhotoKitItemCompressor(
                imageCompressor: imageCompressor,
                destinationDirectory: destinationURL,
                reportAccumulator: accumulator,
                assetInfo: assetInfo,
                policyDecisions: policyDecisions
            )
            currentPipeline = CompressionPipeline(
                compressor: compressor,
                manifest: runManifest,
                tempStore: TempStore(directory: tempDirectory),
                freeSpaceGuard: FreeSpaceGuard(destinationURL: destinationURL, thresholdBytes: 500_000_000),
                authorizationPolling: MainActorAuthorizationPolling(authorization: authorization),
                destinationAvailability: FileManagerDestinationAvailability(url: destinationURL),
                concurrencyWindow: CompressionPipeline.defaultConcurrencyWindow()
            )
            pipeline = currentPipeline
        }

        let items = pipelineItems
        runTask = Task { [weak self] in
            let result = await currentPipeline.run(
                items: items,
                onItemStarted: { item in
                    Task { @MainActor in
                        self?.runProgress?.currentFilename = item.sourceURL.lastPathComponent
                    }
                },
                onItemFinished: { _, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.runProgress?.itemsDone += 1
                        self.runningSavedBytes = await accumulator.runningSavedBytes
                    }
                }
            )
            let succeededItems = await accumulator.allItems
            await MainActor.run {
                guard let self else { return }
                self.runningSavedBytes = succeededItems.reduce(0) { $0 + $1.savedBytes }
                self.handleRunResult(result, succeededItems: succeededItems)
            }
        }
    }

    private func handleRunResult(_ result: PipelineRunResult, succeededItems: [CompressionReportItem]) {
        switch result.outcome {
        case .completed, .cancelled:
            let excludedCount = selection.filter { CompressionPolicy.evaluate($0) != .proceed }.count
            compressionReport = CompressionReport(
                succeededItems: succeededItems,
                failures: result.failures,
                excludedCount: excludedCount
            )
            pauseReason = nil
            stage = .report
        case .paused(let reason):
            pauseReason = reason
        case .setupError:
            // No volume this OS can monitor free space on at all — a
            // blocking condition the user must fix outside iShrink (e.g.
            // choose a different destination volume); shown with the same
            // "blocking" styling as `.destinationUnavailable`.
            pauseReason = .destinationUnavailable
        }
    }

    // MARK: - Pause / Cancel / Resume mid-run (R11)

    func pauseCompression() {
        guard let pipeline else { return }
        Task { await pipeline.requestPause() }
    }

    /// Cancel requires a confirmation before it actually stops anything
    /// (plan: "so an accidental click doesn't silently abort a long run").
    func requestCancelCompression() {
        showCancelConfirmation = true
    }

    func confirmCancelCompression() {
        showCancelConfirmation = false
        guard let pipeline else { return }
        Task { await pipeline.requestCancel() }
    }

    func dismissCancelConfirmation() {
        showCancelConfirmation = false
    }

    /// "Resume" after a pause (any `PauseReason`, once its remediation is
    /// done — re-granting access, freeing space, reconnecting a volume):
    /// re-invokes the same pipeline instance, which skips everything the
    /// manifest already recorded complete.
    func resumeAfterPause() {
        guard pipeline != nil else { return }
        beginCompressionRun()
    }

    // MARK: - Report (R12)

    /// Whether GPS coordinates are currently included when the report is
    /// exported. Never settable directly — only via
    /// `confirmIncludeGPSInExport()` (plan: "enabling GPS inclusion
    /// requires an explicit confirmation ... not a bare toggle").
    func requestIncludeGPSInExport() {
        showGPSExportConfirmation = true
    }

    func confirmIncludeGPSInExport() {
        gpsIncludedInExport = true
        showGPSExportConfirmation = false
    }

    func cancelIncludeGPSInExportRequest() {
        showGPSExportConfirmation = false
    }

    func excludeGPSFromExport() {
        gpsIncludedInExport = false
    }

    /// The report rendered as exported text, honoring the current GPS
    /// inclusion setting (`redactGPS` defaults to `true` in
    /// `CompressionReport.exportText`; this only ever passes `false` after
    /// the explicit confirmation above).
    var exportedReportText: String? {
        compressionReport?.exportText(redactGPS: !gpsIncludedInExport)
    }

    func revealOutputInFinder() {
        guard let destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
    }

    /// Post-report "start another selection" action: back to `SelectionView`
    /// with a clean run/report state, keeping the same scanned library
    /// (no need to re-scan for a second compression pass in the same
    /// session).
    func startAnotherSelectionAfterReport() {
        compressionReport = nil
        gpsIncludedInExport = false
        showGPSExportConfirmation = false
        pipeline = nil
        runTask?.cancel()
        runTask = nil
        runManifest = nil
        reportAccumulator = nil
        pipelineItems = []
        runProgress = nil
        pauseReason = nil
        runStartedAt = nil
        runningSavedBytes = 0
        destinationURL = nil
        destinationValidation = nil
        cloudSyncAcknowledged = false
        stage = .selection
        updateSelection()
    }

    // MARK: - App-private locations (mirrors U6/U7's injectable-directory pattern)

    private static func appSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("iShrink", isDirectory: true)
    }

    /// The single app-private temp directory used for *both* `ImageCompressor`'s
    /// in-progress `.heic` encode (U6) and each selected asset's freshly-
    /// exported source staging file (`PhotoKitItemCompressor`, U9) — the
    /// same directory `TempStore.sweepOrphans()` clears at the start of
    /// every run. Deliberately **not** two separate directories: a crash
    /// between "export this asset's source bytes" and the per-item cleanup
    /// `PhotoKitItemCompressor.compress`'s `defer` normally performs would
    /// otherwise leave an unredacted-GPS/EXIF source copy in a directory
    /// nothing ever sweeps (Key Technical Decisions: "Orphaned temp copy
    /// with GPS/EXIF survives a crash" → "App-private temp location +
    /// startup orphan sweep" — that mitigation only holds if every
    /// GPS-bearing working copy actually lives under the one directory
    /// `TempStore` sweeps).
    private static func sourceStagingDirectory() -> URL {
        appSupportDirectory().appendingPathComponent("tmp", isDirectory: true)
    }

    /// Reuses `TempStore`'s collision-safe, filesystem-safe naming
    /// (`localIdentifier` contains `/`, which isn't filesystem-safe on its
    /// own — same reasoning as `ImageCompressor`'s own output naming)
    /// rather than re-deriving the same sanitization here.
    private static func sourceStagingURL(for localIdentifier: String, in directory: URL) -> URL {
        TempStore(directory: directory).tempURL(for: localIdentifier)
    }

    /// A stable (across relaunches) directory for this exact selection +
    /// destination pair's run manifest, so the resume-affordance check in
    /// `startCompressionFlow()` can find a prior incomplete run for the
    /// *same* selection+destination — and only that combination, not some
    /// unrelated previous run. Built from a SHA-256 of the sorted selected
    /// `localIdentifier`s plus the destination path, rather than the
    /// selection's `Array` order (which isn't guaranteed stable) or its
    /// count alone (which doesn't identify *which* items).
    private static func manifestDirectory(destination: URL, selection: [ClassifiedAsset]) -> URL {
        let sortedIdentifiers = selection.map(\.record.localIdentifier).sorted().joined(separator: "\n")
        let combined = destination.standardizedFileURL.path + "\n" + sortedIdentifiers
        let digest = SHA256.hash(data: Data(combined.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return appSupportDirectory().appendingPathComponent("manifests", isDirectory: true)
            .appendingPathComponent(hex, isDirectory: true)
    }
}

/// Bridges the `@MainActor`-isolated `PhotoAuthorization` (Core, U2) into
/// `CompressionPipeline`'s `AuthorizationPolling` seam (Core, U7), which
/// requires a `Sendable` conformer. `PhotoAuthorization` itself isn't
/// `Sendable` (it's a plain `@MainActor` class, not meant to be shared
/// across isolation domains directly) — `@unchecked Sendable` here is safe
/// because every actual access to it happens via `await poll()`, which
/// Swift hops onto the main actor to perform; this wrapper holds the
/// reference but never touches its state off that actor.
private final class MainActorAuthorizationPolling: AuthorizationPolling, @unchecked Sendable {
    private let authorization: PhotoAuthorization

    init(authorization: PhotoAuthorization) {
        self.authorization = authorization
    }

    func poll() async -> AuthPollResult {
        await authorization.poll()
    }
}

/// Real `DestinationAvailabilityChecking` conformer (Core, U7's seam):
/// treats the destination as unavailable the moment it's no longer present
/// at its path (e.g. an external/network volume was unmounted mid-run) —
/// the structural, whole-run condition `PauseReason.destinationUnavailable`
/// exists for (Core System-Wide Impact: distinct from any single item's own
/// encode failure).
private struct FileManagerDestinationAvailability: DestinationAvailabilityChecking {
    let url: URL

    func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
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
