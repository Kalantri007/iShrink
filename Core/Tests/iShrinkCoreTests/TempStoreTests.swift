import Testing
import Foundation
@testable import iShrinkCore

// iShrink Phase 1 plan, U7 "Bounded streaming pipeline" — TempStore test
// scenarios.
//
// Reuses `makeScratchDirectory()` from `ImageCompressorTests.swift` (same
// test target/module) for scratch directories that already exist; a
// couple of tests below deliberately construct a URL that does *not* yet
// exist, to prove `sweepOrphans()` creates the directory itself.

@Test func sweepOrphansCreatesTheDirectoryWhenItDoesNotYetExist() throws {
    let parent = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let notYetCreated = parent.appendingPathComponent("not-created-yet", isDirectory: true)

    let store = TempStore(directory: notYetCreated)
    let removedCount = try store.sweepOrphans()
    #expect(removedCount == 0)

    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: notYetCreated.path, isDirectory: &isDirectory)
    #expect(exists)
    #expect(isDirectory.boolValue)
}

@Test func sweepOrphansRemovesLeftoverFilesFromACrashedPriorRun() throws {
    let dir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Simulate a crash leftover: a working copy that could carry
    // unredacted GPS/EXIF from an interrupted prior run.
    try Data("leftover-with-unredacted-gps-exif".utf8).write(to: dir.appendingPathComponent("orphan1.heic"))
    try Data("leftover-2".utf8).write(to: dir.appendingPathComponent("orphan2.heic"))

    let store = TempStore(directory: dir)
    let removedCount = try store.sweepOrphans()
    #expect(removedCount == 2)

    let contentsAfter = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(contentsAfter.isEmpty)
}

@Test func cleanupAfterItemRemovesOnlyTheSpecifiedFile() throws {
    let dir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = TempStore(directory: dir)
    let targetURL = store.tempURL(for: "asset-1")
    let otherURL = store.tempURL(for: "asset-2")
    try Data("a".utf8).write(to: targetURL)
    try Data("b".utf8).write(to: otherURL)

    store.cleanupAfterItem(at: targetURL)

    #expect(!FileManager.default.fileExists(atPath: targetURL.path))
    #expect(FileManager.default.fileExists(atPath: otherURL.path))
}

@Test func cleanupAfterItemIsASafeNoOpWhenTheFileIsAlreadyGone() {
    let dir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = TempStore(directory: dir)
    let missingURL = store.tempURL(for: "never-existed")

    // Must not throw or crash.
    store.cleanupAfterItem(at: missingURL)
    #expect(!FileManager.default.fileExists(atPath: missingURL.path))
}

@Test func tempURLIsStableAndFilesystemSafeForIdentifiersContainingSlashes() {
    let dir = makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = TempStore(directory: dir)
    // A realistic `PHAsset.localIdentifier` shape: contains slashes.
    let identifier = "AAAA-BBBB-CCCC/L0/001"
    let first = store.tempURL(for: identifier)
    let second = store.tempURL(for: identifier)

    #expect(first == second)
    #expect(first.deletingLastPathComponent().path == dir.path)
    #expect(!first.lastPathComponent.contains("/"))
}
