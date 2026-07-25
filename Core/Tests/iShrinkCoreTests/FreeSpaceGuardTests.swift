import Testing
import Foundation
@testable import iShrinkCore

// iShrink Phase 1 plan, U7 "Bounded streaming pipeline" — FreeSpaceGuard
// test scenarios.
//
// Every test injects a fake `FreeSpaceReading` conformer so none of this
// depends on the real disk's actual free space (which is unbounded /
// environment-dependent) — only the last test smoke-checks the real
// conformer, and only for "returns something", not an exact value.

/// Deterministic `FreeSpaceReading` fake: returns fixed, injected values
/// for both reads (either of which may be `nil`, to drive the fallback
/// chain and the nil/nil blocking case).
struct FakeFreeSpaceReader: FreeSpaceReading {
    let importantUsage: Int64?
    let fallback: Int64?

    func importantUsageAvailableCapacity(for url: URL) -> Int64? { importantUsage }
    func availableCapacity(for url: URL) -> Int64? { fallback }
}

@Test func reportsOkWhenImportantUsageCapacityIsAboveThreshold() {
    let reader = FakeFreeSpaceReader(importantUsage: 10_000_000_000, fallback: nil)
    let spaceGuard = FreeSpaceGuard(
        destinationURL: URL(fileURLWithPath: "/tmp"), thresholdBytes: 1_000_000_000, reader: reader
    )
    #expect(spaceGuard.checkStatus() == .ok(availableBytes: 10_000_000_000))
}

@Test func reportsLowWhenImportantUsageCapacityIsBelowThreshold() {
    let reader = FakeFreeSpaceReader(importantUsage: 500_000_000, fallback: nil)
    let spaceGuard = FreeSpaceGuard(
        destinationURL: URL(fileURLWithPath: "/tmp"), thresholdBytes: 1_000_000_000, reader: reader
    )
    #expect(spaceGuard.checkStatus() == .low(availableBytes: 500_000_000))
}

@Test func fallsBackToSecondaryReadWhenImportantUsageIsNil() {
    // The primary key is unsupported on this (fake) volume; the guard
    // must fall back rather than treating nil as "no space".
    let reader = FakeFreeSpaceReader(importantUsage: nil, fallback: 5_000_000_000)
    let spaceGuard = FreeSpaceGuard(
        destinationURL: URL(fileURLWithPath: "/tmp"), thresholdBytes: 1_000_000_000, reader: reader
    )
    #expect(spaceGuard.checkStatus() == .ok(availableBytes: 5_000_000_000))
}

@Test func fallsBackAndStillReportsLowWhenSecondaryReadIsBelowThreshold() {
    let reader = FakeFreeSpaceReader(importantUsage: nil, fallback: 100)
    let spaceGuard = FreeSpaceGuard(destinationURL: URL(fileURLWithPath: "/tmp"), thresholdBytes: 1_000, reader: reader)
    #expect(spaceGuard.checkStatus() == .low(availableBytes: 100))
}

@Test func bothPrimaryAndFallbackNilSurfacesBlockingCannotMonitorSetupError() {
    // The nil-capacity policy's whole point: never silently proceed as if
    // there were plenty of space just because neither read produced a
    // value.
    let reader = FakeFreeSpaceReader(importantUsage: nil, fallback: nil)
    let spaceGuard = FreeSpaceGuard(destinationURL: URL(fileURLWithPath: "/tmp"), thresholdBytes: 1_000, reader: reader)
    #expect(spaceGuard.checkStatus() == .cannotMonitor)
}

@Test func realURLResourceReaderReturnsSomeCapacityForARealTempDirectory() {
    // Smoke-check the real conformer against an actual, always-present
    // volume (the system temp dir). Not asserting an exact value — just
    // that the real reader can produce *something* on a normal Mac
    // filesystem, since the fallback-chain unit tests above already cover
    // every nil/non-nil combination against fakes.
    let reader = URLResourceFreeSpaceReader()
    let capacity = reader.availableCapacity(for: FileManager.default.temporaryDirectory)
    #expect(capacity != nil)
}
