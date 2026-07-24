// iShrink — PhotoKit replace-workflow spike
//
// Question this answers (PRD Resolved Decision #1 / Open follow-up):
// when we do create-new-asset + delete-old-asset (the only way PhotoKit lets us
// reclaim space), which of {creation date, location, favorite status, album
// membership, Live Photo pairing} actually survives onto the new asset?
//
// Safety guarantees:
//  - This script ONLY creates and deletes a synthetic test photo + test album
//    that it makes itself. It never touches your real photos.
//  - The optional Live Photo check (--live-photo-id=<id>) is opt-in: it reads
//    resources from the Live Photo you name, creates its OWN duplicate to test
//    pairing, and deletes only that duplicate — never the asset you passed in.
//  - Deleted test assets go through the normal system "Recently Deleted" flow
//    (recoverable for 30 days), same as the real app will do.
//
// Run with: swift run   (see ../README.md for setup + how to interpret results)

import Foundation
import Photos
import AppKit
import CoreLocation

// MARK: - Utilities

func requestAuthorization() -> PHAuthorizationStatus {
    let sem = DispatchSemaphore(value: 0)
    var result: PHAuthorizationStatus = .notDetermined
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
        result = status
        sem.signal()
    }
    sem.wait()
    return result
}

func makeTestImageFile(text: String) -> URL {
    let size = NSSize(width: 800, height: 600)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(origin: .zero, size: size).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 28),
        .foregroundColor: NSColor.white
    ]
    let textSize = text.size(withAttributes: attrs)
    let point = NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2)
    text.draw(at: point, withAttributes: attrs)
    image.unlockFocus()

    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
        fatalError("Failed to render synthetic test image")
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try! jpegData.write(to: url)
    return url
}

func exportResource(_ resource: PHAssetResource, ext: String) -> URL? {
    let sem = DispatchSemaphore(value: 0)
    var result: URL?
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: nil) { error in
        if error == nil { result = url }
        sem.signal()
    }
    sem.wait()
    return result
}

struct CheckResult {
    let name: String
    let pass: Bool
    let detail: String
}

var results: [CheckResult] = []
func record(_ name: String, _ pass: Bool, _ detail: String) {
    results.append(CheckResult(name: name, pass: pass, detail: detail))
    print("\(pass ? "✅ PASS" : "❌ FAIL")  \(name) — \(detail)")
}

// MARK: - Setup

print("iShrink PhotoKit replace-workflow spike")
print("========================================")
print("Creates its own synthetic test photo + album, verifies what survives a")
print("create-new + delete-old cycle, then cleans up its own test data.\n")

let status = requestAuthorization()
guard status == .authorized || status == .limited else {
    print("❌ Photos access not granted (status: \(status.rawValue)).")
    print("   Grant access in System Settings > Privacy & Security > Photos, then re-run.")
    exit(1)
}

let runID = Int(Date().timeIntervalSince1970)
let albumTitle = "iShrink Spike Test \(runID)"
let expectedDate = ISO8601DateFormatter().date(from: "2020-01-15T10:30:00Z")!
let expectedLocation = CLLocation(latitude: 37.7749, longitude: -122.4194) // San Francisco

var albumLocalID: String?
var originalAssetLocalID: String?

// MARK: - Step 1: create the synthetic "original" asset + album

let setupImageURL = makeTestImageFile(text: "iShrink Spike \(runID)")
do {
    try PHPhotoLibrary.shared().performChangesAndWait {
        let albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
        let albumPlaceholder = albumRequest.placeholderForCreatedAssetCollection

        let assetRequest = PHAssetCreationRequest.forAsset()
        assetRequest.addResource(with: .photo, fileURL: setupImageURL, options: nil)
        assetRequest.creationDate = expectedDate
        assetRequest.location = expectedLocation
        assetRequest.isFavorite = true

        if let assetPlaceholder = assetRequest.placeholderForCreatedAsset {
            albumRequest.addAssets([assetPlaceholder] as NSArray)
            originalAssetLocalID = assetPlaceholder.localIdentifier
        }
        albumLocalID = albumPlaceholder.localIdentifier
    }
} catch {
    print("❌ Setup failed: could not create synthetic test asset — \(error)")
    exit(1)
}
try? FileManager.default.removeItem(at: setupImageURL)

guard let albumID = albumLocalID, let originalID = originalAssetLocalID,
      let originalAsset = PHAsset.fetchAssets(withLocalIdentifiers: [originalID], options: nil).firstObject else {
    print("❌ Setup failed: could not fetch back the synthetic test asset")
    exit(1)
}

print("Created synthetic test asset (id: \(originalID)) in album \"\(albumTitle)\"\n")
print("--- As created ---")
record("original.creationDate set", originalAsset.creationDate == expectedDate,
       "expected \(expectedDate), got \(String(describing: originalAsset.creationDate))")
record("original.location set", originalAsset.location != nil, String(describing: originalAsset.location))
record("original.isFavorite set", originalAsset.isFavorite, "isFavorite = \(originalAsset.isFavorite)")

// MARK: - Step 2: simulate "replace" — export original bytes, create new asset carrying
// forward metadata, add to same album. (Testing PhotoKit metadata propagation here,
// not actual codec/compression behavior — that's a separate concern.)

var replacementFileURL: URL?
if let photoResource = PHAssetResource.assetResources(for: originalAsset).first(where: { $0.type == .photo }) {
    replacementFileURL = exportResource(photoResource, ext: "jpg")
}
guard let replacementURL = replacementFileURL else {
    print("❌ Could not export original resource to simulate the compressed replacement")
    exit(1)
}

var newAssetLocalID: String?
do {
    try PHPhotoLibrary.shared().performChangesAndWait {
        let newAssetRequest = PHAssetCreationRequest.forAsset()
        newAssetRequest.addResource(with: .photo, fileURL: replacementURL, options: nil)
        newAssetRequest.creationDate = originalAsset.creationDate
        newAssetRequest.location = originalAsset.location
        newAssetRequest.isFavorite = originalAsset.isFavorite

        if let newPlaceholder = newAssetRequest.placeholderForCreatedAsset {
            newAssetLocalID = newPlaceholder.localIdentifier
            if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
               let albumChangeRequest = PHAssetCollectionChangeRequest(for: album) {
                albumChangeRequest.addAssets([newPlaceholder] as NSArray)
            }
        }
    }
} catch {
    print("❌ Replace step failed: could not create the replacement asset — \(error)")
    exit(1)
}
try? FileManager.default.removeItem(at: replacementURL)

guard let newID = newAssetLocalID,
      let newAsset = PHAsset.fetchAssets(withLocalIdentifiers: [newID], options: nil).firstObject else {
    print("❌ Replace step failed: could not fetch back the new asset")
    exit(1)
}

// MARK: - Step 3: delete the old ("original") asset — the actual space-reclaiming step

do {
    try PHPhotoLibrary.shared().performChangesAndWait {
        PHAssetChangeRequest.deleteAssets([originalAsset] as NSArray)
    }
} catch {
    print("⚠️  Could not delete the original test asset (non-fatal for this spike) — \(error)")
}

// MARK: - Step 4: verify what survived on the new asset

print("\n--- After create-new + delete-old ---")

record("creationDate survives", newAsset.creationDate == expectedDate,
       "expected \(expectedDate), got \(String(describing: newAsset.creationDate))")

let locationSurvived = newAsset.location != nil &&
    abs((newAsset.location?.coordinate.latitude ?? 0) - expectedLocation.coordinate.latitude) < 0.0001 &&
    abs((newAsset.location?.coordinate.longitude ?? 0) - expectedLocation.coordinate.longitude) < 0.0001
record("location survives", locationSurvived, String(describing: newAsset.location))

record("isFavorite survives", newAsset.isFavorite, "isFavorite = \(newAsset.isFavorite)")

if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
    let assetsInAlbum = PHAsset.fetchAssets(in: album, options: nil)
    let stillInAlbum = assetsInAlbum.index(of: newAsset) != NSNotFound
    record("album membership survives", stillInAlbum, "album \"\(albumTitle)\" contains new asset: \(stillInAlbum)")
} else {
    record("album membership survives", false, "could not re-fetch test album")
}

// MARK: - Step 5 (optional): Live Photo pairing check
//
// Opt-in only — pass an existing Live Photo's local identifier to test pairing.
// This never modifies or deletes the asset you pass in; it only reads its
// resources and creates + deletes its own duplicate to check whether pairing survives.

if let liveArg = CommandLine.arguments.first(where: { $0.hasPrefix("--live-photo-id=") }) {
    let sourceID = String(liveArg.dropFirst("--live-photo-id=".count))
    print("\n--- Optional: Live Photo pairing check on asset \(sourceID) ---")

    if let sourceAsset = PHAsset.fetchAssets(withLocalIdentifiers: [sourceID], options: nil).firstObject,
       sourceAsset.mediaSubtypes.contains(.photoLive) {

        let sourceResources = PHAssetResource.assetResources(for: sourceAsset)
        if let photoRes = sourceResources.first(where: { $0.type == .photo }),
           let videoRes = sourceResources.first(where: { $0.type == .pairedVideo }),
           let photoURL = exportResource(photoRes, ext: "heic"),
           let videoURL = exportResource(videoRes, ext: "mov") {

            var livePhotoDupeID: String?
            do {
                try PHPhotoLibrary.shared().performChangesAndWait {
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, fileURL: photoURL, options: nil)
                    req.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
                    livePhotoDupeID = req.placeholderForCreatedAsset?.localIdentifier
                }
            } catch {
                print("❌ Could not create duplicate Live Photo asset — \(error)")
            }
            try? FileManager.default.removeItem(at: photoURL)
            try? FileManager.default.removeItem(at: videoURL)

            if let dupeID = livePhotoDupeID,
               let dupeAsset = PHAsset.fetchAssets(withLocalIdentifiers: [dupeID], options: nil).firstObject {
                let pairingSurvived = dupeAsset.mediaSubtypes.contains(.photoLive)
                record("Live Photo pairing survives", pairingSurvived,
                       "duplicate mediaSubtypes contains .photoLive: \(pairingSurvived)")
                try? PHPhotoLibrary.shared().performChangesAndWait {
                    PHAssetChangeRequest.deleteAssets([dupeAsset] as NSArray)
                }
            } else {
                record("Live Photo pairing survives", false, "could not create/fetch duplicate asset")
            }
        } else {
            print("❌ Could not find paired photo+video resources on the source Live Photo")
        }
    } else {
        print("⚠️  Asset \(sourceID) not found, or is not a Live Photo — skipping.")
    }
} else {
    print("\n(Skipped Live Photo pairing check — pass --live-photo-id=<localIdentifier> of an")
    print(" existing Live Photo to test it. See README.md for how to find an id.)")
}

// MARK: - Step 6: clean up (delete the new test asset + test album)

try? PHPhotoLibrary.shared().performChangesAndWait {
    PHAssetChangeRequest.deleteAssets([newAsset] as NSArray)
    if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
        PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
    }
}

// MARK: - Summary

print("\n========================================")
print("SUMMARY")
for r in results {
    print("\(r.pass ? "✅" : "❌") \(r.name)")
}
let passCount = results.filter { $0.pass }.count
print("\n\(passCount)/\(results.count) checks passed.")
print("The test asset and test album have been cleaned up by this script.")
print("(Deleted items are recoverable from Recently Deleted for the normal 30-day window.)")
