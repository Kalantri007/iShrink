# iShrink

> **Open Source Apple Photos Library Optimizer**
>
> A privacy-first, open source application that intelligently compresses photos and videos in an Apple Photos library while preserving visual quality, metadata, and user privacy.

---

# Problem Statement

Modern smartphones capture incredibly high quality photos and videos. Features like 48 MP photos, Live Photos, HDR, ProRAW, Cinematic Mode, Dolby Vision, ProRes, and 4K/8K video recording produce excellent media, but they also consume a significant amount of storage.

As users continue using their devices over the years, their photo libraries often grow to hundreds of gigabytes. This forces users to:

- Upgrade to a higher iCloud storage plan
- Purchase a new iPhone with more storage
- Manually delete precious memories
- Move photos to external hard drives
- Use closed source, paid compression applications

While several commercial applications solve parts of this problem, almost all of them are:

- Closed source
- Subscription based or paid
- Limited in automation
- Not extensible
- Not transparent about how media is processed
- Impossible for developers to audit or contribute to

Despite the popularity of this problem, there is currently **no mature open source project** that provides a complete solution for optimizing an Apple Photos library while preserving user data, metadata, and visual quality.

**iShrink** aims to fill this gap by becoming the first fully open source, privacy-first Apple Photos optimizer.

---

# Vision

Build the **"Immich for Photo Compression."**

A modern, fast, privacy-focused desktop application that can:

- Scan an Apple Photos library
- Estimate potential storage savings
- Compress photos and videos using modern codecs
- Preserve metadata
- Safely replace originals (optional)
- Work completely offline
- Be fully open source

---

# Goals

## Primary Goals

- Reduce storage usage without noticeable quality loss
- Preserve important metadata
- Work directly with Apple Photos
- Process large libraries efficiently
- Keep all processing local
- Never upload user media
- Provide a safe and reversible workflow

---

# Target Users

- iPhone users running out of storage
- Mac users with large Photos libraries
- Families sharing iCloud storage
- Photographers
- Developers
- Privacy-conscious users
- Open source contributors

---

# Functional Requirements

## Library Scanner

- Scan the Apple Photos library
- Count photos and videos
- Detect Live Photos
- Detect RAW and ProRAW
- Detect ProRes videos
- Detect HDR media
- Calculate total storage usage
- Identify largest files
- Report current codec breakdown (JPEG / HEIC / H.264 / HEVC)
- Estimate potential storage savings from the real per-library codec mix

---

## Compression Engine

### Photos

- JPEG → HEIC
- PNG → HEIC (optional)
- Adjustable compression quality
- Optional resizing
- Preserve color profiles
- Skip files already in HEIC unless resizing is explicitly requested

### Videos

- H.264 → HEVC (H.265)
- Adjustable bitrate
- Preserve frame rate
- Preserve resolution (optional)
- Hardware accelerated encoding
- Skip files already in HEVC unless bitrate reduction is explicitly requested

---

## Metadata Preservation

Preserve:

- EXIF metadata
- GPS location
- Date taken
- Camera model
- Lens information
- Orientation
- Timezone information

Where possible:

- Album membership
- Favorite status
- Captions
- Keywords

Handling of sensitive metadata:

- Store temporary working copies containing EXIF / GPS data in an app-private location and delete them promptly after processing

---

## Preview

Before compressing:

- Original size
- Estimated compressed size
- Estimated storage savings
- Side-by-side comparison
- Compression ratio

---

## Reporting

Generate reports including:

- Total storage saved
- Compression ratio
- Largest albums
- Largest files
- File type breakdown
- Compression history
- Exclude raw GPS coordinates from exported reports by default (opt-in to include)

---

# Non-Functional Requirements

- 100% offline
- Open source
- macOS-native architecture (image/video engine kept platform-agnostic for potential reuse)
- Multi-threaded
- Hardware accelerated
- Resume interrupted jobs
- Memory efficient
- Safe rollback
- Verify each compressed output (decode + checksum) before it is allowed to replace an original
- Move replaced originals to a recoverable staging area, retained until user-confirmed cleanup — never immediate permanent deletion
- Require explicit confirmation (naming file count and total GB) before any permanent deletion
- Require Photos.app to be closed and operate exclusively through PhotoKit change requests; abort and retry safely on concurrent-modification errors
- Reliable for libraries with 100,000+ assets

---

# Proposed Architecture

```text
Apple Photos Library
        │
        ▼
PhotoKit Scanner
        │
        ▼
Media Analyzer
        │
        ▼
Compression Planner
        │
        ▼
Compression Engine
   ├── FFmpeg
   ├── VideoToolbox
   ├── libheif
   └── libvips/ImageMagick
        │
        ▼
Metadata Preservation
        │
        ▼
Verification
        │
        ▼
Import Optimized Media
        │
        ▼
Optional Original Cleanup
        │
        ▼
Storage Report
```

---

# Tech Stack

## Desktop

- Swift
- SwiftUI

## Apple Frameworks

- PhotoKit
- AVFoundation
- VideoToolbox
- ImageIO
- Core Image
- UniformTypeIdentifiers

## Compression

- FFmpeg
- libheif
- libvips
- ImageMagick (optional)

## Metadata

- ExifTool

---

# Open Source Projects to Learn From

## 1. CompressO

**GitHub**

https://github.com/codeforreal1/compressO

**Why**

- Desktop architecture
- Batch compression
- FFmpeg integration
- Modern UI
- Compression pipeline

---

## 2. FFmpeg

https://github.com/FFmpeg/FFmpeg

**Useful For**

- Video compression
- Codec support
- HEVC
- AV1
- Hardware encoding

---

## 3. libheif

https://github.com/strukturag/libheif

**Useful For**

- HEIC encoding
- AVIF support
- Modern image compression

---

## 4. libvips

https://github.com/libvips/libvips

**Useful For**

- Extremely fast image processing
- Low memory usage
- Batch operations

---

## 5. ImageMagick

https://github.com/ImageMagick/ImageMagick

**Useful For**

- Image conversion
- Image optimization
- Batch processing

---

## 6. ExifTool

https://github.com/exiftool/exiftool

**Useful For**

- Metadata preservation
- EXIF handling
- GPS information
- Camera information

---

## 7. PhotoPrism

https://github.com/photoprism/photoprism

**Ideas**

- Media indexing
- Search
- Duplicate detection
- Metadata architecture

---

## 8. Immich

https://github.com/immich-app/immich

**Ideas**

- Background workers
- Job queues
- Storage management
- UI inspiration
- Scalable architecture

---

## 9. LibrePhotos

https://github.com/LibrePhotos/librephotos

**Ideas**

- Duplicate detection
- Face recognition
- Media organization

---

## 10. digiKam

https://github.com/KDE/digikam

**Ideas**

- Album management
- Metadata editing
- Professional media workflows

---

## 11. darktable

https://github.com/darktable-org/darktable

**Ideas**

- RAW image pipeline
- High-performance image processing

---

## 12. ExifCleaner

https://github.com/szTheory/exifcleaner

**Ideas**

- Cross-platform desktop application
- Metadata workflow

---

# Apple APIs to Explore

## Photos

- PhotoKit
- PHPhotoLibrary
- PHAsset
- PHAssetResource
- PHImageManager

## Images

- ImageIO
- Core Image
- Core Graphics

## Videos

- AVFoundation
- AVAssetReader
- AVAssetWriter
- AVAssetExportSession
- VideoToolbox

---

# Stretch Goals

- AI-powered quality estimation
- Duplicate detection
- Near-duplicate detection
- Blur detection
- Screenshot cleanup
- WhatsApp media cleanup
- Batch scheduling
- Automatic recommendations (e.g. "Save 75 GB")
- NAS support
- Immich integration
- Plugin system
- Command Line Interface (CLI)
- REST API
- Homebrew package

---

# Success Metrics

- Reduce library size by **30% to 70%** for libraries with significant JPEG / H.264 content (modern HEIC / HEVC libraries yield less); the actual estimate is computed per-library from the real codec mix
- Preserve visually indistinguishable quality
- Zero data loss
- Fully offline operation
- Support libraries containing **100,000+ assets**
- Become the go-to open source storage optimization tool for Apple Photos

---

# Potential Future Roadmap

## Phase 1

- Photos library scanning
- Storage analytics
- Compression estimation
- Batch photo compression

## Phase 2

- Video compression
- Metadata preservation
- Hardware acceleration
- Preview interface

## Phase 3

- Safe replacement workflow
- Rollback support
- Background processing
- Resume interrupted jobs

## Phase 4

- AI-assisted optimization
- Duplicate detection
- CLI
- Plugin ecosystem
- Community contributions

---

# Inspiration

The goal of **iShrink** is to become for Apple Photos what projects like **Immich** and **PhotoPrism** are for self-hosted photo management: a trusted, community-driven, open source tool that gives users complete control over their media while solving a real storage problem without compromising privacy.

---

# Deferred / Open Questions

### From 2026-07-24 review

These findings need a human decision (architecture, product, or scope judgment) and were surfaced by the document review rather than auto-applied. Resolve before or during planning.

**Core data-safety architecture (resolve #1 first — the rest depend on it):**

1. **[P0] PhotoKit has no in-place original replacement.** (Architecture / Vision) The core "safely replace originals" workflow assumes a capability PhotoKit does not offer — the only path is export → encode → create new asset → delete old asset. Decide and document the concrete substitution mechanism, and validate it with a throwaway spike before Phase 3.
   - **[P1] (depends on #1) Delete-and-reimport loses library metadata.** (Metadata Preservation) A re-imported asset is a new `PHAsset`, so album membership, faces/people, Memories, and Live Photo pairing are lost with no API to restore them. Decide which losses are acceptable and how pairing/albums are reconstructed.
2. **[P0] "Zero data loss" + "safe rollback" conflict with reclaiming space.** (Success Metrics / NFR) Rollback needs the original kept; keeping it saves no space; once purged, rollback is impossible. Define the reversibility window explicitly and require informed acknowledgement before any deletion that empties the rollback path.
3. **[P0] "100% offline" breaks under iCloud "Optimize Mac Storage."** (NFR / Goals) Full originals may live only in iCloud; re-encoding requires downloading them. Decide whether v1 requires originals present locally, or soften the offline claim to cover download-on-demand.
4. **[P0] iCloud delete+reimport propagates across devices.** (Target Users / Architecture) Deletions sync to all devices and compressed copies re-upload, so iCloud usage can rise before it falls. Model the sync side effects (warn when iCloud is on, sequence deletes after upload confirmation, or recommend disabling sync during a run).
5. **[P0] No selection model for which assets get compressed.** (Compression Engine / Scanner) Undefined whether compression targets the whole library, a subset, albums, or only large files. Add an explicit selection + confirm step before any job runs.
6. **[P0] No failure/error handling for a large batch.** (Architecture / Compression Engine) Corrupt, unsupported, or partially-processed files across 100k+ assets need a per-item policy (skip-and-log, never touch the original, never clean up an item that failed verification).

**Product & positioning:**

7. **[P1] Primary user (iPhone-only) can't use a Mac-only app.** (Target Users / NFR) State the real prerequisite (a Mac with the library accessible) and reframe the primary persona accordingly.
8. **[P1] Ambiguous whether the tool reduces local disk vs iCloud storage.** (Vision / Goals) The two imply different workflows and success metrics — commit to which storage the tool reduces.
9. **[P2] Seven unprioritized target segments; "Photographers" contradicts lossy compression.** (Target Users) Designate one primary persona and state the fidelity-vs-savings trade-off rule; exclude RAW/ProRAW from default compression.
10. **[P2] "No mature open-source project" premise is unproven.** (Problem Statement / Vision) CompressO is listed as prior art. Add a short competitive/gap analysis naming the closest tools and the precise remaining gap.

**Media handling:**

11. **[P1] Special media detected but no compression policy.** (Scanner / Compression Engine) RAW/ProRAW, ProRes, Live Photos, HDR, and Cinematic are detected but the engine only defines JPEG/PNG→HEIC and H.264→HEVC. Define a per-type default (e.g., RAW/ProRAW and ProRes excluded by default; Live Photos re-encode both paired resources while preserving pairing).

**UX & operations:**

12. **[P1] Preview interface has no interaction model.** (Preview) Define per-asset vs. batch review and the comparison affordance (slider/toggle/split-pane) for a 100k-asset library.
13. **[P1] Resumable jobs lack resume UI and per-asset atomicity.** (NFR / Roadmap) Define the interruption/resume flow and make each asset an atomic transaction so a crash never leaves a half-replaced asset.
14. **[P1] No progress/pause/cancel state for long-running jobs.** (NFR) Define a persistent progress UI (items done/total, current file, ETA) with pause and cancel.
15. **[P1] No PhotoKit permission handling.** (Apple Frameworks) Define the first-run permission prompt, a denied/limited-access empty state, and behavior when access is revoked mid-job.

**Security & distribution:**

16. **[P1] Bundled binaries lack sandboxing and supply-chain integrity.** (Tech Stack / Compression) FFmpeg/libheif/ImageMagick/ExifTool parse untrusted media and have CVE histories. Define subprocess sandboxing, pinned/verified builds, and a CVE-update cadence.
17. **[P2] FFmpeg (GPL) + ExifTool subprocess vs App Sandbox / App Store.** (Tech Stack / Metadata) Distribution model (App Store vs notarized direct download) determines whether the toolchain is even permitted. Decide it early — it may force ImageIO/AVFoundation substitutions.
18. **[P2] No temp-disk budget for a 100k-asset export.** (NFR / Success Metrics) Exporting full-res originals before compressing can fill the drive the tool is meant to free. Define the concurrency/temp-space/streaming/cleanup model.

**Scope:**

19. **[P2] Curation/dedup features serve a different goal.** (Stretch Goals / Roadmap) Duplicate/near-duplicate/blur/screenshot/WhatsApp cleanup is content curation, not compression, yet duplicate detection is committed into Phase 4. Move these out of the phased roadmap into an unranked idea list.
20. **[P2] Extensibility and cross-library features exceed the stated Apple Photos scope.** (Stretch Goals / Roadmap) Plugin system, CLI, REST API (no current consumer) and NAS support / Immich integration (outside Apple Photos) should be dropped from the roadmap or given their own goal statements before being planned.
