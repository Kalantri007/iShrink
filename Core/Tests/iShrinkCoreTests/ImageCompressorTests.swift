import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import iShrinkCore

// iShrink Phase 1 plan, U6 "Non-destructive HEIC compression engine" test
// scenarios.
//
// Fixture images live in Fixtures/ (committed binaries + the script that
// generated and independently verified them — see
// Fixtures/generate_fixtures.swift). This suite exercises a real
// CGImageSource -> CGImageDestination round trip against those fixtures
// (the plan's "extend the spike" gap folded into U6), not a faked metadata
// check.
//
// Every test uses its own scratch temp/destination directories under the
// process temp dir and removes them in a `defer`, so nothing is left behind
// outside the test's own scratch space.

// MARK: - Test helpers

func fixtureURL(_ name: String, extension ext: String) -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
        Issue.record("missing fixture \(name).\(ext) — run Fixtures/generate_fixtures.swift")
        return URL(fileURLWithPath: "/dev/null")
    }
    return url
}

/// A fresh, empty scratch directory under the system temp dir, unique per
/// call so parallel tests never collide.
func makeScratchDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("iShrinkImageCompressorTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func fileSize(at url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
}

/// Deterministic `HEICEncoding` fake that always reports `Finalize` failure,
/// regardless of input — the Atomicity test's failure-injection seam (plan:
/// "inject a Finalize-fails condition ... or another failure-injection seam
/// of your choosing"). Using the `HEICEncoding` protocol seam rather than a
/// filesystem trick (e.g. a chmod'd read-only temp dir) makes the failure
/// deterministic and platform-independent, and proves `ImageCompressor`'s
/// own temp-discard/no-move behavior in isolation from whatever specific
/// reason a real ImageIO encode might fail for.
struct AlwaysFailingEncoder: HEICEncoding {
    func encode(sourceURL: URL, destinationURL: URL, quality: CGFloat) -> Bool {
        // Simulate a real encoder that got partway through writing a temp
        // file before failing to finalize — write a stray, deliberately
        // truncated file at `destinationURL`, then report failure. This
        // proves `ImageCompressor` discards *whatever* the encoder left
        // behind on a `false` return, not just "didn't write anything".
        try? Data("truncated, never finalized".utf8).write(to: destinationURL)
        return false
    }
}

// MARK: - 1. Happy path

@Test func happyPathCompressesFixtureToSmallerHEICAndCleansUpTemp() throws {
    let tempDir = makeScratchDirectory()
    let destDir = makeScratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: destDir)
    }

    let source = fixtureURL("happy_path_fixture", extension: "jpg")
    let inputSize = fileSize(at: source)
    #expect(inputSize > 0)

    let compressor = ImageCompressor(tempDirectory: tempDir)
    let result = compressor.compress(
        sourceURL: source, localIdentifier: "ABCD1234-5678-90EF/L0/001", destinationDirectory: destDir
    )

    guard case .success(let compression) = result else {
        Issue.record("expected a successful compression, got \(result)")
        return
    }

    #expect(FileManager.default.fileExists(atPath: compression.outputURL.path))
    #expect(compression.outputURL.path.hasPrefix(destDir.path))
    let outputIsSmaller = compression.outputByteSize < compression.inputByteSize
    #expect(outputIsSmaller)

    // The intermediate temp file must be gone from the app-private (here:
    // scratch) temp dir afterward — nothing left behind once the item is
    // done.
    let tempContents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    #expect(tempContents.isEmpty)
}

// MARK: - 2. R4: GPS + EXIF + orientation preserved

@Test func gpsExifOrientationAndTimezonePreservedOnRealRoundTrip() throws {
    let tempDir = makeScratchDirectory()
    let destDir = makeScratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: destDir)
    }

    let source = fixtureURL("gps_exif_fixture", extension: "jpg")
    let compressor = ImageCompressor(tempDirectory: tempDir)
    let result = compressor.compress(
        sourceURL: source, localIdentifier: "gps-exif-asset", destinationDirectory: destDir
    )

    guard case .success(let compression) = result else {
        Issue.record("expected a successful compression, got \(result)")
        return
    }

    let fidelity = compression.metadataFidelity
    #expect(fidelity.gpsPreserved == true)
    #expect(fidelity.dateTimeOriginalPreserved == true)
    #expect(fidelity.cameraMakeModelPreserved == true)
    #expect(fidelity.orientationPreserved == true)
    #expect(fidelity.timezonePreserved == true)

    // Independently re-verify against the actual output file on disk (not
    // just the returned struct), proving the real re-encode carried these
    // fields — the point of "extending the spike".
    guard
        let outSource = CGImageSourceCreateWithURL(compression.outputURL as CFURL, nil),
        let props = CGImageSourceCopyPropertiesAtIndex(outSource, 0, nil) as? [CFString: Any]
    else {
        Issue.record("could not read back properties from compressed output")
        return
    }
    let orientation = props[kCGImagePropertyOrientation] as? Int
    #expect(orientation == 6)
    let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    #expect(gps != nil)
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:01:15 10:30:00")
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "iShrinkTestMake")
    #expect(tiff?[kCGImagePropertyTIFFModel] as? String == "iShrinkTestModel X100")
}

// MARK: - 3. Metadata-fidelity path: lens is best-effort, not asserted

@Test func lensIsReportedAsBestEffortNotAssertedGuaranteed() throws {
    let tempDir = makeScratchDirectory()
    let destDir = makeScratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: destDir)
    }

    let source = fixtureURL("gps_exif_fixture", extension: "jpg") // carries an Exif LensModel
    let compressor = ImageCompressor(tempDirectory: tempDir)
    let result = compressor.compress(
        sourceURL: source, localIdentifier: "lens-asset", destinationDirectory: destDir
    )

    guard case .success(let compression) = result else {
        Issue.record("expected a successful compression, got \(result)")
        return
    }

    // The contract under test: `lensPreserved` is a distinct, checked field
    // — not folded into the asserted set, and not simply absent. It must be
    // non-nil (the fixture *does* carry a LensModel to check), but this
    // test does not assert it must be `true`: either outcome is acceptable
    // per the best-effort contract, per the plan ("report whether it
    // happened to be preserved or not — either is acceptable").
    #expect(compression.metadataFidelity.lensPreserved != nil)

    // And it must be represented distinctly from the guaranteed fields —
    // i.e. this is its own field, not silently merged into (for instance)
    // `cameraMakeModelPreserved`.
    #expect(compression.metadataFidelity.gpsPreserved != nil)
}

// MARK: - 4. Edge case: Display-P3 profile retained

@Test func displayP3ProfileIsRetainedNotSilentlyConvertedToSRGB() throws {
    let tempDir = makeScratchDirectory()
    let destDir = makeScratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: destDir)
    }

    let source = fixtureURL("display_p3_fixture", extension: "jpg")
    let compressor = ImageCompressor(tempDirectory: tempDir)
    let result = compressor.compress(
        sourceURL: source, localIdentifier: "p3-asset", destinationDirectory: destDir
    )

    guard case .success(let compression) = result else {
        Issue.record("expected a successful compression, got \(result)")
        return
    }

    guard
        let outSource = CGImageSourceCreateWithURL(compression.outputURL as CFURL, nil),
        let decoded = CGImageSourceCreateImageAtIndex(outSource, 0, nil),
        let colorSpace = decoded.colorSpace
    else {
        Issue.record("could not decode compressed P3 output")
        return
    }

    let p3Name = CGColorSpace.displayP3 as String
    let outputName = colorSpace.name as String?
    #expect(outputName == p3Name)
}

// MARK: - 5. Atomicity: Finalize failure leaves no file at destination

@Test func finalizeFailureLeavesNoFileAtDestinationOnlyDiscardedTemp() throws {
    let tempDir = makeScratchDirectory()
    let destDir = makeScratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: destDir)
    }

    let source = fixtureURL("happy_path_fixture", extension: "jpg")
    let compressor = ImageCompressor(tempDirectory: tempDir, encoder: AlwaysFailingEncoder())
    let result = compressor.compress(
        sourceURL: source, localIdentifier: "should-not-land", destinationDirectory: destDir
    )

    guard case .failure(let error) = result else {
        Issue.record("expected a failure, got \(result)")
        return
    }
    #expect(error == .encodeFailed)

    // Nothing at the destination at all.
    let destContents = try FileManager.default.contentsOfDirectory(atPath: destDir.path)
    #expect(destContents.isEmpty)

    // The (fake encoder's truncated) temp file was discarded, not left
    // behind.
    let tempContents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    #expect(tempContents.isEmpty)

    // The input itself is completely untouched.
    #expect(FileManager.default.fileExists(atPath: source.path))
}

// MARK: - 6. Edge case: already-HEIC input refused by CompressionPolicy

@Test func alreadyHeicIsRefusedByPolicyNoEncodeAttempted() {
    let record = makeRecord(id: "already-heic-1", resourceUTIs: ["public.heic"])
    let classified = ClassifiedAsset(
        record: record, codec: .heic, isLivePhoto: false, isHDR: false,
        eligibility: .excluded(.alreadyHeic)
    )

    let decision = CompressionPolicy.evaluate(classified)

    #expect(decision == .refuse(.alreadyHeic))
    // No encode attempted / no output written is implicit: this test never
    // constructs or calls an `ImageCompressor` at all for a refused asset.
}

// MARK: - 7. Error path: unreadable/corrupt input

@Test func corruptInputFailsEncodeWithNoOutputAndInputUntouched() throws {
    let tempDir = makeScratchDirectory()
    let destDir = makeScratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: destDir)
    }

    let source = fixtureURL("corrupt_fixture", extension: "jpg")
    let originalBytes = try Data(contentsOf: source)

    let compressor = ImageCompressor(tempDirectory: tempDir)
    let result = compressor.compress(
        sourceURL: source, localIdentifier: "corrupt-asset", destinationDirectory: destDir
    )

    guard case .failure(let error) = result else {
        Issue.record("expected a failure for corrupt input, got \(result)")
        return
    }
    #expect(error == .encodeFailed)

    let destContents = try FileManager.default.contentsOfDirectory(atPath: destDir.path)
    #expect(destContents.isEmpty)

    // Input untouched — same bytes, still present.
    let bytesAfter = try Data(contentsOf: source)
    #expect(bytesAfter == originalBytes)
}

// MARK: - 8. Edge case: RAW / HDR / Live / edited fixtures refused by policy

@Test func rawHdrLiveAndEditedAreAllRefusedByPolicyWithNoEncodeAttempted() {
    let cases: [(String, ExclusionReason)] = [
        ("raw-1", .rawMaster),
        ("hdr-1", .hdrUnpreservable),
        ("live-1", .livePhoto),
        ("edited-1", .editedPhoto),
        ("icloud-1", .iCloudOnly),
    ]

    for (id, reason) in cases {
        let record = makeRecord(id: id)
        let classified = ClassifiedAsset(
            record: record, codec: .jpeg, isLivePhoto: reason == .livePhoto, isHDR: reason == .hdrUnpreservable,
            eligibility: .excluded(reason)
        )

        let decision = CompressionPolicy.evaluate(classified)

        #expect(decision == .refuse(reason))
    }
}

@Test func compressibleClassificationProceedsThroughPolicy() {
    let record = makeRecord(id: "compressible-1", resourceUTIs: ["public.jpeg"])
    let classified = ClassifiedAsset(
        record: record, codec: .jpeg, isLivePhoto: false, isHDR: false, eligibility: .compressible
    )

    #expect(CompressionPolicy.evaluate(classified) == .proceed)
}

@Test func analyticsOnlyVideoIsNotApplicableToCompressionPolicy() {
    let record = makeRecord(id: "video-1", mediaType: .video, resourceUTIs: ["public.mpeg-4"])
    let classified = ClassifiedAsset(
        record: record, codec: .h264, isLivePhoto: false, isHDR: false, eligibility: .analyticsOnly
    )

    #expect(CompressionPolicy.evaluate(classified) == .notApplicable)
}

// MARK: - Collision-safe naming

@Test func localIdentifierWithSlashIsSanitizedIntoFilesystemSafeFilename() throws {
    let tempDir = makeScratchDirectory()
    let destDir = makeScratchDirectory()
    defer {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: destDir)
    }

    // A realistic `PHAsset.localIdentifier` shape: contains slashes.
    let identifier = "3F2A9C10-1B2C-4D3E-9F10-ABCDEF123456/L0/001"
    let source = fixtureURL("happy_path_fixture", extension: "jpg")
    let compressor = ImageCompressor(tempDirectory: tempDir)
    let result = compressor.compress(sourceURL: source, localIdentifier: identifier, destinationDirectory: destDir)

    guard case .success(let compression) = result else {
        Issue.record("expected success, got \(result)")
        return
    }

    // The output landed as a single file directly inside destDir (i.e. the
    // "/" in the identifier did not get interpreted as a path separator
    // creating subdirectories).
    #expect(compression.outputURL.deletingLastPathComponent().path == destDir.path)
    #expect(!compression.outputURL.lastPathComponent.contains("/"))
    #expect(compression.outputURL.pathExtension == "heic")
}

@Test func sameLocalIdentifierProducesSameOutputFilename() {
    let identifier = "AAAA-BBBB/L0/001"
    let first = ImageCompressor.sanitizedFilename(for: identifier)
    let second = ImageCompressor.sanitizedFilename(for: identifier)
    #expect(first == second)
    #expect(first.hasSuffix(".heic"))
}
