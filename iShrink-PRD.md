# iShrink

> **Open Source Apple Photos Library Optimizer (macOS)**
>
> A privacy-first, open source Mac app that safely compresses the photos and videos in your Apple Photos library to reclaim local disk space — preserving visual quality and metadata, and never sending your media anywhere.

---

# Problem Statement

Modern smartphones capture incredibly high quality photos and videos. Features like 48 MP photos, Live Photos, HDR, ProRAW, Cinematic Mode, Dolby Vision, ProRes, and 4K/8K video recording produce excellent media, but they also consume a significant amount of storage.

As users continue using their devices over the years, their photo libraries often grow to hundreds of gigabytes. This forces users to:

- Upgrade to a higher iCloud storage plan
- Purchase a new iPhone with more storage
- Manually delete precious memories
- Move photos to external hard drives
- Use closed source, paid compression applications

While several commercial applications solve parts of this problem, almost all of them are closed source, subscription/paid, limited in automation, not extensible, and not transparent about how media is processed.

General-purpose open source building blocks exist (FFmpeg, libvips, CompressO, ExifTool), but **no open source tool integrates natively with the Apple Photos library to perform safe, in-library compression and original replacement while preserving metadata.** That specific, Photos-native, safety-first workflow is the gap **iShrink** fills.

---

# Vision

A modern, fast, privacy-focused **macOS** desktop application that can:

- Scan an Apple Photos library on the Mac
- Estimate realistic storage savings from the library's actual codec mix
- Compress photos and videos using modern codecs
- Preserve metadata (as far as PhotoKit allows)
- Safely replace originals (optional), with a recoverable undo window
- Process all media locally, never uploading user media
- Be fully open source

The internal compression engine is kept platform-agnostic for potential reuse; the Apple Photos integration is macOS-native.

---

# Goals

## Primary Goals

- Reduce **local disk usage** of the Mac's Photos library without noticeable quality loss
- Preserve important metadata (what PhotoKit permits; see Metadata Preservation)
- Work directly with Apple Photos via PhotoKit
- Process large libraries efficiently
- Keep all processing local — never upload or transmit user media to any third party
- Provide a safe, reversible workflow with verification before any deletion

## Guiding Trade-off Rule

When fidelity and savings conflict, **preserve the original**. Master formats (RAW / ProRAW / ProRes) are excluded from compression by default.

---

# Target Users

**Primary persona:** a Mac user with a large, everyday Apple Photos library who is running low on local disk space.

> **Requirement:** iShrink runs on macOS and operates on an Apple Photos library that is accessible on that Mac.

**Secondary (v1 benefits, not the focus):**

- Families managing a shared Mac library
- Developers and open source contributors
- Privacy-conscious users

**Future / aspirational (out of v1 scope):**

- iPhone-only users with no Mac (would require a separate iOS app; iOS PhotoKit is more restrictive for this workflow)
- Photographers who want a dedicated non-destructive RAW workflow

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

## Selection

Users can choose what to compress through any of three modes, all ending in a mandatory confirmation:

- **Smart default** — iShrink proposes the best-savings set (largest space-savers, excluding master formats by default)
- **Manual** — hand-pick individual assets
- **Filters/rules** — e.g. "videos over 200 MB, older than 2 years"
- **Mandatory confirmation** before any job runs, showing item count, current size → estimated size, and estimated savings

## Compression Engine

Per-type policy (see Guiding Trade-off Rule):

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

### Special media (default policy)

- **RAW / ProRAW / ProRes / Cinematic:** excluded by default; advanced opt-in only, with an explicit warning
- **Live Photos:** re-encode both paired resources together and preserve the pairing
- **HDR / Dolby Vision:** preserve HDR when transcoding — never silently flatten to SDR

## Metadata Preservation

Preserve:

- EXIF metadata
- GPS location
- Date taken
- Camera model
- Lens information
- Orientation
- Timezone information

Where possible (re-attached to the newly created asset):

- Album membership
- Favorite status
- Creation date
- Live Photo pairing

Cannot be preserved (no PhotoKit API) — clearly disclosed to the user up front:

- Faces / People tagging
- Memories history

Handling of sensitive metadata:

- Store temporary working copies containing EXIF / GPS data in an app-private location and delete them promptly after processing

## Preview

- A **batch summary** as the primary decision surface: total items, original size, estimated compressed size, estimated storage savings, and a breakdown by type/album

## Progress & Job Control

- Persistent progress UI: items done / total, current file, elapsed time and ETA, running GB saved
- **Pause** and **Cancel**, both stopping safely at an item boundary (never mid-item)
- Job continues if the window is closed while the app stays open

## Resume & Atomicity

- Each asset is processed as an atomic transaction: encode to temp → verify → add new → delete old
- A durable job journal records progress
- On relaunch after an interruption: a **Resume / Discard** prompt (items done / remaining); any item not fully committed is treated as not-done and re-run from the untouched original

## Failure Handling

- Per-item isolation: a failure never halts the batch
- A file whose compression or verification fails **keeps its original** — never deleted
- Transient failures (disk pressure, briefly locked file) get one automatic retry
- All failures are logged and surfaced in the job report

## Permissions

- First-run pre-prompt explaining why full library access is needed and that nothing leaves the Mac
- Denied-access state with a one-click deep link to System Settings
- "Limited access" handling (explain full access is required for a whole-library scan)
- If access is revoked mid-job, pause safely and warn

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

- **Privacy-first:** iShrink never uploads or transmits your media to any third party; all processing happens on your device
- **v1 works on local originals only** (assets whose full-resolution originals are present on the Mac); iCloud download-on-demand is deferred to a later phase
- **v1 assumes a non-iCloud library:** detect iCloud Photos and gate/warn; full iCloud-aware sync handling deferred
- Open source
- macOS-native architecture (image/video engine kept platform-agnostic for potential reuse)
- Multi-threaded
- Hardware accelerated
- Bounded, streaming pipeline with a live free-space guardrail (adaptive batch sizing, immediate temp cleanup, pause when disk runs low)
- Resume interrupted jobs (atomic per-asset transactions + durable journal)
- Memory efficient
- Verify each compressed output (decode + checksum) before it is allowed to replace an original
- Move replaced originals to the system's Recently Deleted (30-day undo window); offer an optional archive of originals to an external location for permanent rollback
- Require explicit confirmation (naming file count and total GB) before any permanent deletion
- Prefer native Apple frameworks; run any remaining third-party binary in a sandboxed, no-network subprocess built from pinned/verified sources
- Reliable for libraries with 100,000+ assets

---

# Proposed Architecture

```text
Apple Photos Library (local originals, non-iCloud in v1)
        │
        ▼
PhotoKit Scanner
        │
        ▼
Media Analyzer (codec mix, savings estimate, type detection)
        │
        ▼
Selection + Confirmation (smart / manual / filters)
        │
        ▼
Compression Planner (per-type policy)
        │
        ▼
Compression Engine
   ├── ImageIO / Core Image (images, preferred)
   ├── AVFoundation / VideoToolbox (video, preferred)
   └── FFmpeg / libheif (sandboxed subprocess, only where native is insufficient)
        │
        ▼
Metadata Preservation (re-attach date/location/favorite/album/Live pairing)
        │
        ▼
Verification (decode + checksum) — gate before any deletion
        │
        ▼
Create New Asset (PHAssetCreationRequest)
        │
        ▼
Delete Old Asset → Recently Deleted (30-day undo) + optional external archive
        │
        ▼
Storage Report
```

---

# Tech Stack

## Desktop

- Swift
- SwiftUI

## Apple Frameworks (preferred)

- PhotoKit
- AVFoundation
- VideoToolbox
- ImageIO
- Core Image
- UniformTypeIdentifiers

## Compression (fallback, sandboxed — only where native APIs fall short)

- FFmpeg
- libheif
- libvips
- ImageMagick (optional)

## Metadata

- Native `CGImageMetadata` / ImageIO preferred; ExifTool only as a sandboxed fallback

## Distribution

- v1 ships as a **notarized direct download** (and Homebrew), which allows the fallback toolchain and GPL components; a Mac App Store build remains possible later if the native-first engine proves sufficient

---

# Open Source Projects to Learn From

## 1. CompressO

**GitHub:** https://github.com/codeforreal1/compressO

**Why:** Desktop architecture, batch compression, FFmpeg integration, modern UI, compression pipeline

## 2. FFmpeg

https://github.com/FFmpeg/FFmpeg — Video compression, codec support, HEVC, AV1, hardware encoding

## 3. libheif

https://github.com/strukturag/libheif — HEIC encoding, AVIF support, modern image compression

## 4. libvips

https://github.com/libvips/libvips — Extremely fast image processing, low memory usage, batch operations

## 5. ImageMagick

https://github.com/ImageMagick/ImageMagick — Image conversion, optimization, batch processing

## 6. ExifTool

https://github.com/exiftool/exiftool — Metadata preservation, EXIF handling, GPS/camera information

## 7. PhotoPrism

https://github.com/photoprism/photoprism — Media indexing, metadata architecture

## 8. Immich

https://github.com/immich-app/immich — Background workers, job queues, storage management, UI inspiration, scalable architecture

## 9. LibrePhotos

https://github.com/LibrePhotos/librephotos — Media organization ideas

## 10. digiKam

https://github.com/KDE/digikam — Album management, metadata editing, professional media workflows

## 11. darktable

https://github.com/darktable-org/darktable — RAW image pipeline, high-performance image processing

## 12. ExifCleaner

https://github.com/szTheory/exifcleaner — Cross-platform desktop application, metadata workflow

---

# Apple APIs to Explore

## Photos

- PhotoKit
- PHPhotoLibrary
- PHAsset
- PHAssetResource
- PHImageManager
- PHAssetCreationRequest / PHAssetChangeRequest (create-new + delete-old workflow)

## Images

- ImageIO
- Core Image
- Core Graphics
- CGImageMetadata (metadata)

## Videos

- AVFoundation
- AVAssetReader
- AVAssetWriter
- AVAssetExportSession
- VideoToolbox

---

# Potential Future Roadmap

## Phase 1

- Photos library scanning
- Storage analytics + codec breakdown
- Compression estimation
- Batch photo compression (non-destructive export first, to prove the engine)

## Phase 2

- Video compression
- Metadata preservation + re-attachment
- Hardware acceleration
- Batch-summary preview interface

## Phase 3

- Safe replacement workflow (create-new + delete-old) with verification gate
- 30-day undo + optional external archive
- Background processing, progress/pause/cancel
- Resume interrupted jobs (atomic + journal)

## Phase 4

- iCloud-aware handling (download-on-demand originals; sync-safe deletes)
- CLI over the same engine

---

# Near-term Stretch Goals

- Command Line Interface (CLI) over the same core engine
- Homebrew package

---

# Ideas / Maybe Later (unranked, not committed)

These are deliberately parked outside the roadmap until the compression core is proven and demand is real:

- AI-powered quality estimation
- Duplicate / near-duplicate detection
- Blur detection
- Screenshot cleanup
- WhatsApp media cleanup
- Automatic recommendations (e.g. "Save 75 GB")
- NAS support
- Immich integration
- Plugin system
- REST API
- iOS companion app

---

# Success Metrics

- Reduce local library size by **30% to 70%** for libraries with significant JPEG / H.264 content (modern HEIC / HEVC libraries yield less); the actual estimate is computed per-library from the real codec mix
- Preserve visually indistinguishable quality (verified against a measurable quality floor at the Verification step)
- **Never delete a user's only copy without explicit consent;** the quality trade-off is opt-in and shown before committing
- All processing local; no third-party uploads
- Support libraries containing **100,000+ assets**
- Become the go-to open source, Photos-native storage optimization tool for Apple Photos on macOS

---

# Inspiration

The goal of **iShrink** is to become for Apple Photos what projects like **Immich** and **PhotoPrism** are for self-hosted photo management: a trusted, community-driven, open source tool that gives users complete control over their media while solving a real storage problem without compromising privacy.

---

# Resolved Decisions

### From 2026-07-24 review walk-through

The 20 open questions from the document review were resolved as follows. Items marked *(spike)* need a technical proof before the relevant phase.

**Core data-safety architecture**

1. **Replacement model:** add-new-then-delete-old (the only PhotoKit path that reclaims space), with safety rails; validate with a throwaway spike before Phase 3. *(spike)*
2. **Reversibility:** rely on the system's 30-day Recently Deleted window for undo, offer an optional external-drive archive for permanent rollback, and reword "zero data loss" honestly.
3. **Offline / iCloud reads:** v1 processes only locally-present originals; iCloud download-on-demand deferred to Phase 4.
4. **iCloud sync writes:** v1 assumes a non-iCloud library — detect iCloud Photos and gate/warn; full iCloud handling deferred.
5. **Selection:** flexible multi-mode (smart default + manual + filters), always ending in a mandatory confirmation screen.
6. **Failure handling:** per-item skip-log-keep (never delete a failed item's original), with one auto-retry for transient errors.

**Product & positioning**

7. **Primary persona:** reframed to Mac users managing a large Apple Photos library; iPhone-only users moved to future/aspirational.
8. **Storage target:** v1 reduces the Mac's local disk footprint; iCloud-plan savings staged for a later phase.
9. **Personas & trade-off rule:** pruned to one primary persona + "preserve originals when in doubt (exclude RAW/ProRAW/ProRes by default)"; Photographers dropped as a primary segment.
10. **Prior-art claim:** reframed from "no mature OSS exists" to the precise gap — no OSS tool does Photos-native safe compression + replacement.

**Media handling**

11. **Special media:** conservative per-type policy — protect RAW/ProRAW/ProRes/Cinematic (opt-in only); handle Live Photos with preserved pairing; preserve HDR.

**UX & operations**

12. **Preview:** batch summary as the decision surface (no per-asset compare in v1); safety is covered by verification + 30-day undo.
13. **Resume & atomicity:** atomic per-asset transactions + durable journal + resume/discard prompt.
14. **Progress:** full progress UI with safe pause and cancel at item boundaries.
15. **Permissions:** full first-run permission lifecycle (pre-prompt, denied state, limited access, mid-job revocation).

**Security & distribution**

16. **Toolchain security:** prefer native Apple frameworks; sandbox + pin + patch any remaining third-party binary.
17. **Distribution:** notarized direct download + Homebrew for v1; App Store possible later.
18. **Temp disk:** bounded streaming pipeline with adaptive batch sizing, immediate cleanup, and a live free-space guardrail.

**Scope**

19. **Curation/dedup:** moved entirely to the Ideas list (out of the roadmap).
20. **Extensibility:** plugin system / REST API / NAS / Immich moved to Ideas; CLI kept as a near-term stretch over the same engine.

## Open follow-ups

- **Spike (Q1):** verify the create-new + delete-old workflow preserves date/location/favorite/album/Live-pairing on the new asset, before Phase 3.
- **Validate savings:** measure realistic savings on a modern (already-HEIC/HEVC) library to confirm the 30–70% framing before making it a headline.
