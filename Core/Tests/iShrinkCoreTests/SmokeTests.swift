import Testing
@testable import iShrinkCore

// U1 scaffolding check: proves the `iShrinkCore` package builds and its test
// target actually links against it (not just a dead `import`), before any
// real feature logic exists.
//
// Uses Swift Testing (`import Testing`) rather than XCTest: this dev
// environment has Xcode Command Line Tools without full Xcode, and
// XCTest.framework is Xcode-only, while Swift Testing ships with the open
// source Swift toolchain and runs fine under plain `swift test`.
@Test func moduleImportsAndLinks() {
    #expect(iShrinkCoreModule.name == "iShrinkCore")
}
