import Testing
import Foundation
@testable import iShrinkCore

// iShrink Phase 1 plan, U9 "App UI: compression run & report" —
// `CompressionReport` test scenarios (the plan's numbered list 1-5).

@Suite struct CompressionReportTests {

    // MARK: - Fixtures

    private static func item(
        _ id: String,
        codec: MediaCodec,
        input: Int64,
        output: Int64,
        gps: GPSCoordinate? = nil
    ) -> CompressionReportItem {
        CompressionReportItem(
            localIdentifier: id,
            filename: "\(id).jpg",
            codec: codec,
            inputByteSize: input,
            outputByteSize: output,
            gpsCoordinate: gps
        )
    }

    // Happy path: run of 100 items (90 ok, 10 excluded, 0 failed) → report
    // shows correct saved bytes, ratio, and per-type split.
    @Test func happyPathReportsCorrectTotalsRatioAndPerTypeSplit() {
        var succeeded: [CompressionReportItem] = []
        for index in 0..<60 {
            succeeded.append(Self.item("jpeg-\(index)", codec: .jpeg, input: 10_000_000, output: 6_000_000))
        }
        for index in 0..<30 {
            succeeded.append(Self.item("png-\(index)", codec: .png, input: 4_000_000, output: 1_000_000))
        }

        let report = CompressionReport(succeededItems: succeeded, failures: [], excludedCount: 10)

        #expect(report.succeededItems.count == 90)
        #expect(report.attemptedCount == 90)
        #expect(report.excludedCount == 10)

        let expectedInput: Int64 = 60 * 10_000_000 + 30 * 4_000_000
        let expectedOutput: Int64 = 60 * 6_000_000 + 30 * 1_000_000
        #expect(report.totalInputBytes == expectedInput)
        #expect(report.totalOutputBytes == expectedOutput)
        #expect(report.totalSavedBytes == expectedInput - expectedOutput)

        let ratio = try! #require(report.compressionRatio)
        let expectedRatio = Double(expectedOutput) / Double(expectedInput)
        #expect(abs(ratio - expectedRatio) < 0.000_001)

        let byCodec = report.byCodec
        let expectedJPEGInput: Int64 = 60 * 10_000_000
        let expectedJPEGOutput: Int64 = 60 * 6_000_000
        let expectedPNGInput: Int64 = 30 * 4_000_000
        let expectedPNGOutput: Int64 = 30 * 1_000_000
        #expect(byCodec[.jpeg]?.count == 60)
        #expect(byCodec[.jpeg]?.inputBytes == expectedJPEGInput)
        #expect(byCodec[.jpeg]?.outputBytes == expectedJPEGOutput)
        #expect(byCodec[.png]?.count == 30)
        #expect(byCodec[.png]?.inputBytes == expectedPNGInput)
        #expect(byCodec[.png]?.outputBytes == expectedPNGOutput)
        #expect(!report.isZeroSuccess)
    }

    // Edge case: run with failures → failures listed with reasons;
    // saved-bytes counts only successful items.
    @Test func failuresAreListedAndDoNotCountTowardSavedBytes() {
        let succeeded = [
            Self.item("ok-1", codec: .jpeg, input: 5_000_000, output: 2_000_000),
            Self.item("ok-2", codec: .jpeg, input: 3_000_000, output: 1_500_000),
        ]
        let failures = [
            PipelineFailureLogEntry(
                localIdentifier: "bad-1", filename: "bad-1.jpg",
                errorCode: ItemFailureReason.corruptInput.rawValue, wasRetried: false
            ),
            PipelineFailureLogEntry(
                localIdentifier: "bad-2", filename: "bad-2.jpg",
                errorCode: ItemFailureReason.encodeFailedOnReadableFile.rawValue, wasRetried: false
            ),
        ]

        let report = CompressionReport(succeededItems: succeeded, failures: failures, excludedCount: 0)

        #expect(report.failures.count == 2)
        #expect(report.failures.map(\.localIdentifier) == ["bad-1", "bad-2"])
        #expect(report.attemptedCount == 4)

        // Saved bytes reflect only the two successful items, never the
        // failed ones (which contributed no bytes at all).
        let savedOk1: Int64 = 5_000_000 - 2_000_000
        let savedOk2: Int64 = 3_000_000 - 1_500_000
        let expectedSaved: Int64 = savedOk1 + savedOk2
        #expect(report.totalSavedBytes == expectedSaved)
        #expect(!report.isZeroSuccess)

        let exported = report.exportText()
        #expect(exported.contains("bad-1.jpg"))
        #expect(exported.contains("bad-2.jpg"))
        #expect(exported.contains(ItemFailureReason.corruptInput.rawValue))
    }

    // Edge case: all-failed/zero-success run → report renders a failure
    // summary with no divide-by-zero ratio and no success styling.
    @Test func allFailedRunRendersFailureSummaryWithNoDivideByZeroRatio() {
        let failures = [
            PipelineFailureLogEntry(
                localIdentifier: "bad-1", filename: "bad-1.jpg",
                errorCode: ItemFailureReason.corruptInput.rawValue, wasRetried: false
            ),
            PipelineFailureLogEntry(
                localIdentifier: "bad-2", filename: "bad-2.jpg",
                errorCode: ItemFailureReason.diskPressure.rawValue, wasRetried: true
            ),
        ]

        let report = CompressionReport(succeededItems: [], failures: failures, excludedCount: 0)

        #expect(report.isZeroSuccess)
        #expect(report.compressionRatio == nil)
        #expect(report.totalInputBytes == 0)
        #expect(report.totalOutputBytes == 0)
        #expect(report.totalSavedBytes == 0)
        #expect(report.byCodec.isEmpty)
        #expect(report.largestSavers().isEmpty)

        let exported = report.exportText()
        #expect(exported.contains("All 2 item(s) failed to compress"))
        #expect(!exported.contains("Compression ratio"))
        #expect(!exported.contains("Per-type breakdown"))
    }

    // Covers R12: exported report with `redactGPS = true` (default) omits
    // coordinates; opt-in includes them.
    @Test func exportRedactsGPSByDefaultAndIncludesItOnlyWhenOptedIn() {
        let gps = GPSCoordinate(latitude: 37.334_900, longitude: -122.009_020)
        let succeeded = [
            Self.item("with-gps", codec: .jpeg, input: 5_000_000, output: 2_000_000, gps: gps),
        ]
        let report = CompressionReport(succeededItems: succeeded, failures: [], excludedCount: 0)

        let redacted = report.exportText()
        #expect(!redacted.contains("37.3349"))
        #expect(!redacted.contains("GPS"))

        let redactedExplicit = report.exportText(redactGPS: true)
        #expect(!redactedExplicit.contains("37.3349"))

        let unredacted = report.exportText(redactGPS: false)
        #expect(unredacted.contains("37.3349"))
        #expect(unredacted.contains("-122.00902"))
    }

    // Edge case: resumed run → report reflects combined totals across both
    // runs via the manifest. Grounded in the real `RunManifest`/
    // `InMemoryManifestStore` API: run 1 records two completions and
    // checkpoints (simulating a pause); a *fresh* `RunManifest` instance
    // (simulating relaunch/resume) loads from the same durable store and
    // records one more completion. The report is built from the union of
    // every identifier the durable store now holds (i.e. across both
    // runs), resolved through a per-item lookup a real caller (the App
    // layer) maintains alongside the manifest — `CompressionReport` itself
    // never inspects `ManifestEntry` directly (see file header note in
    // `CompressionReport.swift` for why: `ManifestEntry` carries no
    // byte/codec data to build a report from in the first place).
    @Test func resumedRunReflectsCombinedTotalsAcrossBothRunsViaTheManifest() async throws {
        let store = InMemoryManifestStore()

        let run1Manifest = RunManifest(store: store)
        try await run1Manifest.recordCompletion(ManifestEntry(localIdentifier: "A", outputPath: "/out/A.heic"))
        try await run1Manifest.recordCompletion(ManifestEntry(localIdentifier: "B", outputPath: "/out/B.heic"))
        try await run1Manifest.checkpointNow()

        // Simulate relaunch: a brand-new RunManifest instance over the same
        // durable store starts with nothing loaded until `load()` is called.
        let resumedManifest = RunManifest(store: store)
        let completeBeforeLoad = await resumedManifest.isComplete("A")
        #expect(!completeBeforeLoad)
        try await resumedManifest.load()
        try await resumedManifest.recordCompletion(ManifestEntry(localIdentifier: "C", outputPath: "/out/C.heic"))

        let lookup: [String: CompressionReportItem] = [
            "A": Self.item("A", codec: .jpeg, input: 1_000_000, output: 400_000),
            "B": Self.item("B", codec: .jpeg, input: 2_000_000, output: 900_000),
            "C": Self.item("C", codec: .png, input: 3_000_000, output: 1_000_000),
        ]

        // The union of both runs' completions, read back from the shared
        // durable store.
        let completedEntries = try store.loadAll()
        #expect(Set(completedEntries.map(\.localIdentifier)) == ["A", "B", "C"])

        let succeededItems = completedEntries.compactMap { lookup[$0.localIdentifier] }
        let report = CompressionReport(succeededItems: succeededItems, failures: [], excludedCount: 0)

        #expect(report.succeededItems.count == 3)
        let savedA: Int64 = 1_000_000 - 400_000
        let savedB: Int64 = 2_000_000 - 900_000
        let savedC: Int64 = 3_000_000 - 1_000_000
        let expectedSaved: Int64 = savedA + savedB + savedC
        #expect(report.totalSavedBytes == expectedSaved)
        #expect(report.byCodec[.jpeg]?.count == 2)
        #expect(report.byCodec[.png]?.count == 1)
    }

    // Additional edge case: `largestSavers(limit:)` sorts descending by
    // bytes saved and honors the limit.
    @Test func largestSaversSortsDescendingAndHonorsLimit() {
        let succeeded = [
            Self.item("small", codec: .jpeg, input: 1_000_000, output: 900_000), // saved 100k
            Self.item("big", codec: .jpeg, input: 10_000_000, output: 1_000_000), // saved 9M
            Self.item("medium", codec: .jpeg, input: 5_000_000, output: 2_000_000), // saved 3M
        ]
        let report = CompressionReport(succeededItems: succeeded, failures: [], excludedCount: 0)

        let top2 = report.largestSavers(limit: 2)
        #expect(top2.map(\.localIdentifier) == ["big", "medium"])
    }
}
