#!/usr/bin/env swift
//
// generate_fixtures.swift
//
// iShrink Phase 1 plan, U6 "Non-destructive HEIC compression engine" —
// fixture generator ("Extend the spike" gap: the plan explicitly wants real,
// committed fixture files with real embedded GPS/EXIF and a Display-P3
// profile, so `ImageCompressorTests` exercises a genuine CGImageSource ->
// CGImageDestination re-encode round trip, not a faked metadata check).
//
// This script is NOT part of the iShrinkCore package or the app — it is a
// one-off tool. Run it directly with the Swift interpreter from the repo
// root (or anywhere; it writes next to itself):
//
//     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//         swift Core/Tests/iShrinkCoreTests/Fixtures/generate_fixtures.swift
//
// It produces four files in this same directory:
//   - happy_path_fixture.jpg — a 32x32 pseudo-random-noise JPEG at high
//                              JPEG quality (0.9). Random per-pixel noise
//                              barely compresses under JPEG's DCT, but HEIC
//                              (HEVC intra) still beats it handily — verified
//                              below (this is the fixture the "output
//                              smaller than input" happy-path test needs;
//                              the *other* fixtures here are so tiny that
//                              HEIC's container overhead alone would make
//                              the "compressed" output *larger* than the
//                              input, which would make that assertion
//                              meaningless — this fixture exists
//                              specifically to avoid that trap).
//   - gps_exif_fixture.jpg   — tiny JPEG with GPS, DateTimeOriginal, camera
//                              make/model, a non-default orientation (6),
//                              an Exif timezone offset, and a LensModel tag
//                              (for the "lens is best-effort" test).
//   - display_p3_fixture.jpg — tiny JPEG tagged with the Display-P3 color
//                              space (for the "P3 profile isn't silently
//                              dropped to sRGB" test).
//   - corrupt_fixture.jpg    — deliberately NOT a real image (garbage
//                              bytes), for the "unreadable/corrupt input"
//                              error-path test. Written directly (no
//                              ImageIO involved — that's the point).
//
// Every fixture that goes through ImageIO is read back and verified
// (`CGImageSourceCopyPropertiesAtIndex` / decoded `CGImage.colorSpace`)
// before this script prints success — nothing here trusts a write to have
// "worked" just because no error was thrown. If verification fails, the
// script calls `fatalError` and nothing should be committed.
//
// Images are 8x8 pixels, solid-ish gradient — a few dozen pixels, per the
// plan ("doesn't need to look like a real photo, just needs to be a valid
// decodable JPEG"). This keeps each fixture in the low single-digit KB
// range; metadata size dominates pixel data at this resolution.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("generate_fixtures: FAILED — \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Tiny synthetic CGImage

/// Builds an 8x8 RGB gradient CGImage in the given color space — solid color
/// data, just needs to be valid decodable pixels.
func makeTinyImage(colorSpace: CGColorSpace) -> CGImage {
    let width = 8
    let height = 8
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fail("could not create CGContext for synthetic image")
    }

    for y in 0..<height {
        for x in 0..<width {
            let r = CGFloat(x) / CGFloat(width)
            let g = CGFloat(y) / CGFloat(height)
            context.setFillColor(red: r, green: g, blue: 0.5, alpha: 1.0)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }

    guard let image = context.makeImage() else {
        fail("could not render synthetic CGImage")
    }
    return image
}

// MARK: - Fixture 0: happy-path (shrinks under HEIC re-encode)

/// A small xorshift-style PRNG so the noise image is deterministic across
/// regenerations (reproducible fixture, not "whatever `Int.random` gave us
/// this run").
struct DeterministicNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUnit() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1
        return CGFloat((state >> 33) & 0xFFFF) / CGFloat(0xFFFF)
    }
}

func makeNoiseImage(size: Int, colorSpace: CGColorSpace) -> CGImage {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fail("could not create CGContext for noise image")
    }
    var noise = DeterministicNoise(seed: 987_654_321)
    for y in 0..<size {
        for x in 0..<size {
            context.setFillColor(red: noise.nextUnit(), green: noise.nextUnit(), blue: noise.nextUnit(), alpha: 1.0)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    guard let image = context.makeImage() else {
        fail("could not render noise CGImage")
    }
    return image
}

func writeHappyPathFixture() {
    let url = fixturesDir.appendingPathComponent("happy_path_fixture.jpg")
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        fail("could not create sRGB color space")
    }
    // 32x32 random noise: JPEG's DCT barely compresses noise (unlike the
    // gradient fixtures above), so this JPEG is meaningfully larger than a
    // same-content HEIC re-encode — proven below, not assumed.
    let image = makeNoiseImage(size: 32, colorSpace: colorSpace)

    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
    ) else {
        fail("could not create JPEG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        fail("CGImageDestinationFinalize returned false for happy_path_fixture.jpg")
    }

    // Verify: re-encode to a scratch HEIC via the exact same primitive
    // ImageCompressor uses (AddImageFromSource) and confirm it's smaller —
    // if this ever stops being true (e.g. noise seed/size changed), fail
    // loudly here rather than let the real test suite's happy-path
    // assertion silently become a coin flip.
    guard let jpegSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
        fail("could not stat happy_path_fixture.jpg")
    }
    let scratchHEIC = fixturesDir.appendingPathComponent(".scratch_happy_path_check.heic")
    defer { try? FileManager.default.removeItem(at: scratchHEIC) }
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let heicDest = CGImageDestinationCreateWithURL(scratchHEIC as CFURL, UTType.heic.identifier as CFString, 1, nil)
    else {
        fail("could not set up HEIC verification encode for happy_path_fixture.jpg")
    }
    CGImageDestinationAddImageFromSource(heicDest, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(heicDest) else {
        fail("verification HEIC encode did not finalize for happy_path_fixture.jpg")
    }
    guard let heicSize = try? FileManager.default.attributesOfItem(atPath: scratchHEIC.path)[.size] as? Int else {
        fail("could not stat verification HEIC output")
    }
    guard heicSize < jpegSize else {
        fail("happy_path_fixture.jpg (\(jpegSize) bytes) did not shrink under HEIC re-encode (\(heicSize) bytes) — pick a different size/seed")
    }

    print("generate_fixtures: OK — happy_path_fixture.jpg written (\(jpegSize) bytes; verified HEIC re-encode is \(heicSize) bytes, smaller)")
}

// MARK: - Fixture 1: GPS + EXIF + orientation + lens + timezone

func writeGPSExifFixture() {
    let url = fixturesDir.appendingPathComponent("gps_exif_fixture.jpg")
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        fail("could not create sRGB color space")
    }
    let image = makeTinyImage(colorSpace: colorSpace)

    let gps: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: 37.7749,
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 122.4194,
        kCGImagePropertyGPSLongitudeRef: "W",
    ]
    let exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: "2024:01:15 10:30:00",
        kCGImagePropertyExifLensModel: "iShrink Test Lens 24mm f/1.8",
        kCGImagePropertyExifOffsetTimeOriginal: "-08:00",
    ]
    let tiff: [CFString: Any] = [
        kCGImagePropertyTIFFMake: "iShrinkTestMake",
        kCGImagePropertyTIFFModel: "iShrinkTestModel X100",
    ]
    // Orientation 6 = "rotate 90 CW" — a deliberately non-default value so
    // the round-trip test is meaningful (plan: "pick a non-default value
    // like 6").
    let properties: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: gps,
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: tiff,
        kCGImagePropertyOrientation: 6,
    ]

    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
    ) else {
        fail("could not create JPEG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        fail("CGImageDestinationFinalize returned false for gps_exif_fixture.jpg")
    }

    // Verify by reading back — don't just trust the write succeeded.
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let readBack = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
        fail("could not read back properties from gps_exif_fixture.jpg")
    }

    guard let readGPS = readBack[kCGImagePropertyGPSDictionary] as? [CFString: Any],
          let lat = readGPS[kCGImagePropertyGPSLatitude] as? Double,
          let lon = readGPS[kCGImagePropertyGPSLongitude] as? Double,
          abs(lat - 37.7749) < 0.001, abs(lon - 122.4194) < 0.001
    else {
        fail("GPS round-trip verification failed for gps_exif_fixture.jpg")
    }

    guard let readExif = readBack[kCGImagePropertyExifDictionary] as? [CFString: Any],
          readExif[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:01:15 10:30:00",
          readExif[kCGImagePropertyExifLensModel] as? String == "iShrink Test Lens 24mm f/1.8",
          readExif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "-08:00"
    else {
        fail("EXIF round-trip verification failed for gps_exif_fixture.jpg")
    }

    guard let readTIFF = readBack[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
          readTIFF[kCGImagePropertyTIFFMake] as? String == "iShrinkTestMake",
          readTIFF[kCGImagePropertyTIFFModel] as? String == "iShrinkTestModel X100"
    else {
        fail("TIFF make/model round-trip verification failed for gps_exif_fixture.jpg")
    }

    guard let readOrientation = readBack[kCGImagePropertyOrientation] as? Int, readOrientation == 6 else {
        fail("Orientation round-trip verification failed for gps_exif_fixture.jpg")
    }

    print("generate_fixtures: OK — gps_exif_fixture.jpg written and verified at \(url.path)")
}

// MARK: - Fixture 2: Display-P3 color profile

func writeDisplayP3Fixture() {
    let url = fixturesDir.appendingPathComponent("display_p3_fixture.jpg")
    guard let p3ColorSpace = CGColorSpace(name: CGColorSpace.displayP3) else {
        fail("could not create Display-P3 color space")
    }
    let image = makeTinyImage(colorSpace: p3ColorSpace)

    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
    ) else {
        fail("could not create JPEG destination at \(url.path)")
    }
    // No extra properties dict needed — CGImageDestinationAddImage embeds
    // the source CGImage's own color profile.
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fail("CGImageDestinationFinalize returned false for display_p3_fixture.jpg")
    }

    // Verify by decoding the image back and checking its color space name —
    // don't just trust the write succeeded.
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let readColorSpace = decoded.colorSpace
    else {
        fail("could not decode display_p3_fixture.jpg back for verification")
    }

    let p3Name = CGColorSpace.displayP3 as String
    let readName = readColorSpace.name as String?
    guard readName == p3Name else {
        fail("display_p3_fixture.jpg round-tripped as '\(readName ?? "nil")', expected '\(p3Name)'")
    }

    print("generate_fixtures: OK — display_p3_fixture.jpg written and verified at \(url.path)")
}

// MARK: - Fixture 3: corrupt / unreadable input

func writeCorruptFixture() {
    let url = fixturesDir.appendingPathComponent("corrupt_fixture.jpg")
    // Deliberately garbage bytes, not a real image — no ImageIO involved on
    // write, and CGImageSourceCreateWithURL must fail to decode it.
    let garbage = Data("this is not a real image file — iShrink test fixture".utf8)
    do {
        try garbage.write(to: url)
    } catch {
        fail("could not write corrupt_fixture.jpg: \(error)")
    }

    // Verify it is in fact undecodable (that's the whole point of this
    // fixture) — if ImageIO somehow parses it, this fixture wouldn't
    // exercise the error path the test needs.
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
       CGImageSourceCreateImageAtIndex(source, 0, nil) != nil {
        fail("corrupt_fixture.jpg unexpectedly decoded as a valid image")
    }

    print("generate_fixtures: OK — corrupt_fixture.jpg written (\(garbage.count) bytes, verified undecodable)")
}

// MARK: - Run

writeHappyPathFixture()
writeGPSExifFixture()
writeDisplayP3Fixture()
writeCorruptFixture()
print("generate_fixtures: all fixtures generated and verified.")
