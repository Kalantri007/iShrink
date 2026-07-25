import Testing
import Foundation
@testable import iShrinkCore

// iShrink Phase 1 plan, U8 "App UI" — `DestinationValidator` test
// scenarios. Uses real `FileManager` calls against real scratch temp
// directories (chmod'd read-only, and simulated cloud-sync-like paths) per
// the plan's own guidance: "You'll need to actually create a real read-only
// temp directory and a real path under a simulated cloud-sync-like
// structure ... construct URLs that *look like* they're under `~/Library/
// Mobile Documents`/`~/Dropbox`, which should be string/path-based
// detection, not a real iCloud Drive dependency."
//
// Shares `makeScratchDirectory` from `ImageCompressorTests.swift` (same
// test target) for the "ordinary local folder" case; the read-only and
// cloud-sync-like cases build their own directories directly since they
// need specific structure/permissions `makeScratchDirectory` doesn't offer.

@Suite struct DestinationValidatorTests {

    private func makeDirectory(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - 1. Read-only folder -> rejected.

    @Test func readOnlyFolderIsRejected() throws {
        let scratchRoot = makeScratchDirectory()
        defer {
            // Restore write permission before cleanup, or `removeItem`
            // itself could fail on some filesystems.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratchRoot.path)
            try? FileManager.default.removeItem(at: scratchRoot)
        }

        let readOnlyDir = scratchRoot.appendingPathComponent("read-only-output", isDirectory: true)
        makeDirectory(at: readOnlyDir)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDir.path)

        let validation = DestinationValidator.validate(destination: readOnlyDir)

        #expect(validation.isWritable == false)
        #expect(validation.isRejected == true)
        #expect(validation.isClean == false)
    }

    // MARK: - 2. Path under a known cloud-sync container -> cloud-sync
    // warning flag set.

    @Test func pathUnderSimulatedMobileDocumentsSetsCloudSyncFlag() {
        let scratchRoot = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        // Simulated `~/Library/Mobile Documents/.../output` structure under
        // a scratch dir — detection is path-substring based, not a real
        // iCloud Drive dependency, so this exercises the same code path a
        // real iCloud Drive destination would.
        let simulatedICloudDir = scratchRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("output", isDirectory: true)
        makeDirectory(at: simulatedICloudDir)

        let validation = DestinationValidator.validate(destination: simulatedICloudDir)

        #expect(validation.isWritable == true)
        #expect(validation.isCloudSyncPath == true)
        #expect(validation.requiresCloudSyncAcknowledgement == true)
        #expect(validation.isRejected == false)
        #expect(validation.isClean == false)
    }

    @Test func pathUnderSimulatedDropboxSetsCloudSyncFlag() {
        let scratchRoot = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let simulatedDropboxDir = scratchRoot
            .appendingPathComponent("Dropbox", isDirectory: true)
            .appendingPathComponent("output", isDirectory: true)
        makeDirectory(at: simulatedDropboxDir)

        let validation = DestinationValidator.validate(destination: simulatedDropboxDir)

        #expect(validation.isCloudSyncPath == true)
        #expect(validation.requiresCloudSyncAcknowledgement == true)
    }

    // MARK: - 3. Ordinary local folder -> clean.

    @Test func ordinaryLocalFolderIsClean() {
        let ordinaryDir = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: ordinaryDir) }

        // A trivially low threshold (1 byte) so this test doesn't depend on
        // how much real free space happens to exist on the test host's
        // volume — any real volume has more than 1 byte free.
        let validation = DestinationValidator.validate(destination: ordinaryDir, lowFreeSpaceThresholdBytes: 1)

        #expect(validation.isWritable == true)
        #expect(validation.isCloudSyncPath == false)
        #expect(validation.isRejected == false)
        #expect(validation.requiresCloudSyncAcknowledgement == false)
        #expect(validation.isLowOnFreeSpace == false)
        #expect(validation.isClean == true)
    }

    // MARK: - Edge case: low free space warning fires when the configured
    // threshold is unrealistically high (deterministic without needing a
    // near-full real disk).

    @Test func unrealisticallyHighThresholdTriggersLowFreeSpaceWarning() {
        let ordinaryDir = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: ordinaryDir) }

        let validation = DestinationValidator.validate(
            destination: ordinaryDir,
            lowFreeSpaceThresholdBytes: Int64.max
        )

        // Only meaningful if free space could actually be read on this
        // host/volume; if it genuinely can't be read, `isLowOnFreeSpace`
        // stays `false` by design (unknown is not warned on) and this
        // assertion is skipped rather than spuriously failing.
        if validation.availableBytes != nil {
            #expect(validation.isLowOnFreeSpace == true)
            #expect(validation.isClean == false)
        }
    }
}
