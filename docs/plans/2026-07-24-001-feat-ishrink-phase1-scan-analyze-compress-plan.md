---
title: "feat: iShrink v1 Phase 1 — Photos scan, storage analytics, and non-destructive HEIC compression"
type: feat
status: active
date: 2026-07-24
origin: iShrink-PRD.md
deepened: 2026-07-24
---

# feat: iShrink v1 Phase 1 — Photos scan, storage analytics, and non-destructive HEIC compression

## Summary

This plan implements PRD Phase 1: scan an Apple Photos library, compute storage analytics and a codec breakdown, estimate realistic savings from the real per-library codec mix, and compress eligible photos (JPEG/PNG → HEIC) **non-destructively to a user-chosen output folder** — never touching the real library. The library is only ever *read* in this phase; the destructive create-new/delete-old workflow is deferred to PRD Phase 3. The build is structured as a thin, signed SwiftUI `.app` shell (for Photos permission attribution, signing, and notarization) wrapping a headless, unit-testable `iShrinkCore` Swift package where the scan/classify/estimate/compress logic lives behind a PhotoKit-abstracting protocol.

---

## Problem Frame

Mac users with large Apple Photos libraries run out of local disk, and no open-source, Photos-native, safety-first compressor exists (see origin: `iShrink-PRD.md` Problem Statement). Phase 1 delivers the *provably safe* half of that tool — measure and compress — while structurally isolating the risky "replace the original" mechanics into a later phase. Building the engine against non-destructive output first lets us prove real-world savings and quality on real libraries with zero risk of data loss.

---

## Requirements

Traced from `iShrink-PRD.md`. R-IDs are plan-local; the origin uses prose requirements under Functional/Non-Functional headings.

- R1. Scan an Apple Photos library and count photos/videos, detect Live Photos, RAW/ProRAW, HDR, and report a codec breakdown (JPEG/HEIC/H.264/HEVC) — origin: Library Scanner.
- R2. Calculate total storage usage, identify largest files, and estimate potential savings from the **real** per-library codec mix — origin: Library Scanner, Success Metrics.
- R3. Compress photos JPEG→HEIC (PNG→HEIC optional) with adjustable quality, preserving color profiles; skip files already HEIC unless resizing is explicitly requested — origin: Compression Engine › Photos.
- R4. Preserve file-embedded metadata through the re-encode: EXIF, GPS, date taken, camera model, lens, orientation, timezone — origin: Metadata Preservation.
- R5. Exclude master formats (RAW/ProRAW/ProRes/Cinematic) by default; never silently flatten HDR to SDR — origin: Guiding Trade-off Rule, Compression Engine › Special media.
- R6. Process only locally-present originals; assume a non-iCloud library and ask the user once at first run whether iCloud Photos is enabled, remembering the answer — origin: NFR (local originals only; iCloud first-run question, Decision #21).
- R7. Full first-run permission lifecycle: pre-prompt, denied state with deep-link to Settings, mid-job revocation handled by pausing safely — origin: Permissions.
- R8. Selection ends in a mandatory confirmation showing item count, current size → estimated size, and estimated savings — origin: Selection.
- R9. Bounded, streaming pipeline: adaptive batch sizing, immediate temp cleanup, and a live free-space guardrail that pauses when disk runs low; memory-efficient at 100,000+ assets — origin: NFR.
- R10. Per-item failure isolation: a failed compression keeps its input untouched and never halts the batch; one automatic retry for transient failures; all failures logged and surfaced in the report — origin: Failure Handling.
- R11. Progress UI with running totals and safe Pause/Cancel at item boundaries (never mid-item) — origin: Progress & Job Control.
- R12. Generate a post-run report: total storage saved, compression ratio, file-type breakdown, largest files; exclude raw GPS from exported reports by default — origin: Reporting.
- R13. All processing is local; nothing is uploaded or transmitted — origin: NFR (Privacy-first).

**Origin actors:** Primary — a Mac user with a large local Apple Photos library low on disk.
**Origin flows:** Scan → Analyze/estimate → Select → Confirm → Compress (to output folder) → Report.

---

## Scope Boundaries

- **No library mutation in Phase 1.** No `PHAssetCreationRequest`, no deletion, no album re-attach. Output is written to a user-chosen folder outside Photos. (Origin Phase 3.)
- **No video compression.** Video assets are counted and codec-classified for analytics only; H.264→HEVC transcode is Phase 2.
- **No PHAsset-level metadata re-attach** (favorite/album/Live-pairing/creation-date onto a *new library asset*) — that only matters once we create library assets in Phase 3. Phase 1 preserves only **file-embedded** metadata (R4) on the exported file.
- **No iCloud download-on-demand.** iCloud-only assets are detected and excluded from compression, not fetched. (Origin Phase 4.)
- **No SSIM/perceptual quality gate.** Phase 1 is non-destructive, so a quality floor is not a delete-gate here; the metric decision stays deferred (origin Open follow-up / Decision #22).

### Deferred to Follow-Up Work

- **Manual selection at 100k scale** (browse/sort/search/bulk-select UI): Phase 1 ships smart-default + rule-based filters only; full manual browsing is a separate effort (origin Open follow-up "Manual-selection UX at scale").
- **HDR-preserving transcode** (gain-map carry-through on macOS 14/15+): Phase 1 excludes HDR photos; enabling their compression is a later enhancement.
- **Largest-albums report analytics:** deferred — needs a second PhotoKit album-membership pass; Phase 1's report covers the current run's files, not album rollups (origin Reporting; decision: defer).
- **Cross-run compression history:** deferred — implies persisting run results across sessions; Phase 1's report is single-run (origin Reporting; decision: defer).
- **Extend-the-spike EXIF verification** as a standalone spike: folded into U6's test scenarios here rather than a separate spike (origin Open follow-up "Extend the spike").
- **`docs/solutions/` seeding**: capture Phase 1 learnings via `/ce-compound` after implementation (learnings researcher recommendation).

---

## Context & Research

### Relevant Code and Patterns

- `spikes/photokit-replace-spike/Sources/PhotoKitReplaceSpike/main.swift` — working reference for: `PHPhotoLibrary.requestAuthorization(for: .readWrite)` gating on `.authorized || .limited`; `PHAssetResource.assetResources(for:)` + `PHAssetResourceManager.default().writeData(for:toFile:options:)` for resource export; `PHAsset.fetchAssets(...)`. Reuse the *authorization* and *resource-read* shapes; do **not** reuse its `performChangesAndWait` mutation code in Phase 1.
- `spikes/photokit-replace-spike/Package.swift` — pins **Swift tools 5.9, macOS `.v12`**. The real app stays consistent. Its `-sectcreate __TEXT __info_plist` linker trick is spike-only; the app uses a real bundle Info.plist instead.
- `.gitignore` — already ignores `.build/`, `DerivedData/`, `xcuserdata/`, `Package.resolved`. New Xcode/SPM artifacts inherit these; add app-specific ignores in U1.

### External References (2026 framework research)

- **Scanning at scale:** `PHFetchResult` is lazy/faulting — keep it, page by index, never copy to an `Array`; wrap per-batch work in `autoreleasepool`. `PHFetchOptions`: `includeAssetSourceTypes = .typeUserLibrary` (exclude shared/synced), `wantsIncrementalChangeDetails = false` for a one-shot scan. [PHFetchOptions](https://developer.apple.com/documentation/photokit/phfetchoptions)
- **On-disk size:** no public API. Fast path is the undocumented KVC `resource.value(forKey: "fileSize") as? Int64` (does not trigger iCloud download; acceptable for a **notarized non-App-Store** build), guarded with a documented fallback (`PHAssetResourceManager.requestData` with `isNetworkAccessAllowed = false`, summing chunk lengths). [forum: fileSize KVC](https://developer.apple.com/forums/thread/771861)
- **Local-vs-iCloud (per-asset):** probe with `isNetworkAccessAllowed = false` — an error/`PHImageResultIsInCloudKey == true` means iCloud-only. Cannot distinguish a fully-downloaded iCloud library from a genuinely local one (origin Decision #21) → used only to *skip* non-local assets, not for library-wide detection.
- **Codec/format without decoding:** `resource.uniformTypeIdentifier` + `UTType`. RAW/ProRAW caught in one check via `UTType(uti)?.conforms(to: .rawImage)`. Live Photo = `mediaSubtypes.contains(.photoLive)`. HDR = `mediaSubtypes.contains(.photoHDR)` and/or a gain-map auxiliary type. Video codec needs `AVAsset` format descriptions (Phase 2 — analytics can label video as "container only" in Phase 1 or open the track lazily).
- **HEIC encode:** default primitive is **`CGImageDestinationAddImageFromSource(dest, src, 0, props)`** — re-encodes straight from the `CGImageSource`, carrying metadata, orientation, and the Display-P3 profile automatically, at low memory. `props = [kCGImageDestinationLossyCompressionQuality: q]`, destination UTI `UTType.heic.identifier`. Check `CGImageDestinationFinalize` return; `false` = per-item failure → keep input. Use Core Image only for resize/HDR. [CGImageDestinationAddImageFromSource](https://developer.apple.com/documentation/imageio/1465181-cgimagedestinationaddimagefromso)
- **Metadata fidelity:** `AddImageFromSource` copies it; the fallback properties path (`CGImageSourceCopyPropertiesAtIndex`) must re-carry `kCGImagePropertyOrientation` and the P3 profile explicitly or the image visibly rotates / desaturates. EXIF camera-model/lens/orientation/timezone ride the **file** metadata (ImageIO), not PHAsset properties — this is the origin "extend the spike" gap; covered in U6 tests.
- **HDR gain maps:** reliable preservation needs macOS 14+ (`kCGImageAuxiliaryDataTypeHDRGainMap`), ISO 21496-1 needs 15+. On the 12/13 baseline you **cannot** faithfully preserve them → Phase 1 excludes HDR photos (R5).
- **Streaming/concurrency:** bounded `TaskGroup` "sliding window" sized ≈ `activeProcessorCount / 2`; serialize shared state (totals, run manifest, free-space guard) in an `actor`; `autoreleasepool` per item; temp dir via `FileManager.url(for: .itemReplacementDirectory, ...)` on the destination volume, removed immediately after each item.
- **Free-space guardrail:** `URLResourceValues.volumeAvailableCapacityForImportantUsage` on the destination volume, checked at batch boundaries.
- **Packaging/TCC:** ship a signed, notarized `.app` bundle with `NSPhotoLibraryUsageDescription` + `NSPhotoLibraryAddUsageDescription` in a real `Contents/Info.plist`. `.limited` authorization is iOS-only — on macOS treat it defensively as "needs full access." Request authorization on the main actor from the GUI; background scan checks `authorizationStatus(...)` at batch boundaries so revocation pauses safely.

### Institutional Learnings

- None — `docs/solutions/` does not exist; this is genuinely greenfield (learnings researcher, 0 matches). Seed it post-implementation.

---

## Key Technical Decisions

- **Two-target structure — thin app shell + headless core package.** A `iShrinkCore` local SPM package holds all scan/classify/estimate/compress logic with **no UI and no hard PhotoKit dependency at the seams** (PhotoKit sits behind a `PhotoLibraryProviding` protocol). A separate Xcode SwiftUI `.app` target provides the UI, the real Info.plist, code signing, and notarization. *Rationale:* the research is explicit that TCC/notarization need a real bundle, while unit-testing scan/estimate logic needs PhotoKit mocked out. Splitting gives both.
- **PhotoKit behind a protocol (`PhotoLibraryProviding`).** The scanner depends on a protocol returning plain `AssetRecord` value types, not on `PHAsset` directly. A `PhotoKitLibrary` conformer wraps real PhotoKit; a `FakeLibrary` conformer feeds fixtures in tests. *Rationale:* PhotoKit can't run in CI/headless (needs a real library + interactive TCC); this is the only way to test scan/classify/estimate logic.
- **Non-destructive output, written app-private-then-atomically-moved.** Each output is encoded to an **app-private temp directory** (`~/Library/Application Support/iShrink/tmp`, *not* derived from the destination), then **atomically renamed/moved into the user-chosen destination only after `Finalize` returns true**. The Photos library is never mutated. *Rationale:* the working copy carries unredacted GPS/EXIF, so it must never touch the (possibly cloud-synced) destination volume before it's a finished output (origin: app-private-temp requirement, Metadata Preservation); atomic move means a crash never leaves a truncated `.heic` at the destination.
- **Collision-safe output naming keyed on `localIdentifier`.** `originalFilename` is **not** unique across a library (burst frames, re-imports, `IMG_9999→IMG_0001` rollover), so outputs are namespaced by the asset's stable `localIdentifier` (subfolder or filename prefix), and the run manifest keys on `localIdentifier`, never on the output path. *Rationale:* two assets sharing a basename would otherwise clobber each other and corrupt both the on-disk result and resume logic.
- **`AddImageFromSource` as the default transcode primitive**, Core Image reserved for resize. Metadata preservation is **best-effort and honestly labelled**: GPS, date, camera model, orientation, and timezone ride through reliably, but **lens info stored in proprietary MakerNote/XMP is best-effort, not guaranteed** — R4/the UI must not promise more than ImageIO delivers. *Rationale:* faithful for the common fields at lowest memory (research 2a); avoids an unfalsifiable "lens always preserved" claim the MakerNote reality can't back (see origin Metadata Preservation "as far as PhotoKit allows").
- **Guarded fast size read, cross-validated, summed across resources.** `AssetSizeReader` tries the undocumented `fileSize` KVC with a documented `requestData` fallback, **cross-validates the KVC value against the fallback on a sampled subset each run** and switches the whole run to the fallback on divergence beyond tolerance (guards against plausible-but-wrong nonzero values, not just nil), and **sums all of an asset's resources** for storage totals (edited photos and Live Photos carry multiple resources). *Rationale:* a bare `≤0` guard trusts a wrong nonzero size and silently corrupts the savings estimate shown at confirmation.
- **HDR (incl. gain-map), RAW/ProRAW, iCloud-only, and already-HEIC are exclusion classes.** HDR detection uses **both** `mediaSubtypes.contains(.photoHDR)` **and** a gain-map auxiliary-data probe (`CGImageSourceCopyAuxiliaryDataInfoAtIndex` for `kCGImageAuxiliaryDataTypeHDRGainMap`), because the legacy subtype under-detects modern gain-map captures. Surfaced in analytics as "excluded (reason)". *Rationale:* the subtype alone would let a modern HDR photo through and be silently flattened to SDR on the 12/13 baseline, violating R5.
- **Run manifest = append-only log + periodic checkpoint, keyed on `localIdentifier`.** Resume means "skip items **recorded complete in the manifest**" (not "a file exists at the path"); any pre-existing output whose item isn't in the manifest is overwritten. The manifest is an append-only log (one flushed line per completed item) with periodic atomic-rewrite checkpoints. *Rationale:* atomic whole-file rewrite per item is O(n²) at 100k assets (R9); append-only keeps the hot path O(1). The durable per-asset atomic journal is still Phase 3.
- **Read-only invariant is enforced, not just asserted.** A build/test-time guard fails if `iShrinkCore` sources reference `PHAssetChangeRequest`, `PHAssetCreationRequest`, `PHAssetCollectionChangeRequest`, or `performChanges`. `.readWrite` is requested only because it is the **only** macOS `PHAccessLevel` that grants full-library read (`.addOnly` cannot read); the guard is the compensating control for that over-broad grant. *Rationale:* "read-only" is the load-bearing safety property — a convention that nothing lints against will eventually be broken by Phase 2/3 work in the shared package.
- **App Sandbox enabled with no network entitlement.** The Phase-1 `.app` runs sandboxed with the Photos entitlement and **no `com.apple.security.network.client`**, so R13 ("nothing leaves the Mac") is enforced by the OS, not just by the absence of network code. Compatible with notarized Developer-ID direct download; Phase 1 is native-only so nothing needs network. *Rationale:* makes the privacy guarantee fail-closed against accidental or injected egress.

---

## Open Questions

### Resolved During Planning

- **App packaging (SPM exe vs bundle)?** → Signed `.app` bundle for TCC/notarization; engine stays in an SPM package. (Decision above.)
- **How to get on-disk size?** → Guarded `fileSize` KVC + documented fallback.
- **HDR in Phase 1?** → Detect and exclude (baseline can't preserve gain maps).
- **iCloud-only assets?** → Detect via network-off probe; exclude from compression, never download.
- **Which encode API?** → `CGImageDestinationAddImageFromSource`.
- **Quality metric / SSIM?** → Not needed in non-destructive Phase 1; stays deferred.
- **Savings estimate method?** → Fast heuristic from codec mix at scan time, refined by an actual measured ratio from a small calibration sample before the confirmation screen (U5).
- **Metadata that can't be fully preserved (e.g. MakerNote-resident lens)?** → Best-effort + honestly labelled; preserve what ImageIO reliably carries, report lens as best-effort, don't over-promise (2026-07-24 review decision).
- **Output naming / write atomicity?** → Namespace outputs by `localIdentifier`; encode to app-private temp then atomic-move into the destination only on `Finalize` success; resume off the manifest, not file existence.
- **Enforce "nothing leaves the Mac"?** → App Sandbox with no network entitlement (2026-07-24 review decision); native-only Phase 1 needs no network.
- **Which resource to size/compress?** → Sum all resources for storage; export the primary photo resource; exclude edited photos (no edit re-render in Phase 1).
- **Transient-vs-permanent failure classification?** → Bounded transient set (disk-pressure, locked file, temp I/O) gets one retry; permanent errors are not retried (U7).
- **Keeping the library read-only?** → Enforced by a build/test guard that rejects PhotoKit mutation APIs in `iShrinkCore`, not left to convention.

### Deferred to Implementation

- **Exact concurrency window size and memory budget constants** — tune against a real 100k library during implementation; research gives a starting point (`cores/2`), not a final number.
- **Whether video codec detection runs during the Phase-1 scan** (opening `AVAsset` per video is I/O-heavy) or is labeled "container-only" until Phase 2 — decide when U4 measures scan cost on a real library.
- **Precise heuristic ratios** for JPEG→HEIC savings by source characteristics — seeded from the calibration sample, not guessable up front (origin Open follow-up "Validate savings").

---

## Output Structure

    iShrink.xcodeproj/                      — app shell target (or project.yml for xcodegen)
    scripts/check-readonly.sh               — fails if iShrinkCore references PhotoKit mutation APIs
    App/
      iShrinkApp.swift                      — @main SwiftUI App
      Info.plist                            — real bundle plist; NSPhotoLibrary(Add)UsageDescription
      iShrink.entitlements                  — App Sandbox on, Photos entitlement, NO network
      Views/
        PermissionGateView.swift
        ScanView.swift
        AnalyticsDashboardView.swift
        SelectionView.swift
        ConfirmationView.swift
        CompressionRunView.swift
        ReportView.swift
      ViewModels/
        AppModel.swift                      — @MainActor observable app state
    Core/                                   — local SPM package "iShrinkCore"
      Package.swift
      Sources/iShrinkCore/
        Permissions/PhotoAuthorization.swift
        Library/PhotoLibraryProviding.swift — protocol + AssetRecord value type
        Library/PhotoKitLibrary.swift       — real PhotoKit conformer
        Library/AssetSizeReader.swift       — guarded KVC + fallback, cross-validated, summed
        Scan/LibraryScanner.swift
        Classify/MediaClassifier.swift      — codec + exclusion-class detection (incl. gain-map HDR)
        Classify/ExclusionReason.swift      — enum + user-facing copy table
        Analytics/StorageAnalytics.swift    — totals, breakdown, largest files
        Estimate/SavingsEstimator.swift     — heuristic tier + calibration tier
        Selection/SelectionRules.swift      — smart default + filter predicates
        Selection/DestinationValidator.swift— writable/free-space/cloud-sync checks
        Compress/CompressionPolicy.swift    — eligibility rules
        Compress/ImageCompressor.swift      — AddImageFromSource HEIC encode, temp→atomic move
        Pipeline/CompressionPipeline.swift  — bounded TaskGroup, pause reasons
        Pipeline/FreeSpaceGuard.swift       — incl. nil-capacity policy
        Pipeline/RunManifest.swift          — append-only log keyed on localIdentifier
        Pipeline/TempStore.swift            — app-private temp + orphan sweep
        Report/CompressionReport.swift
      Tests/iShrinkCoreTests/
        (mirrors Sources; FakeLibrary + FakeCompressor + fixture images)

> The tree is a scope declaration, not a constraint — the implementer may adjust layout if implementation reveals a better shape. Per-unit `**Files:**` remain authoritative.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

Data flow (Phase 1, read-only against Photos → write-only to a user folder):

```text
PhotoKitLibrary ──(AssetRecord[])──▶ LibraryScanner ──▶ MediaClassifier
   (protocol seam)                        │                    │
                                          ▼                    ▼
                                   AssetSizeReader        exclusion classes
                                          │              (RAW/HDR/iCloud/HEIC)
                                          └────────┬───────────┘
                                                   ▼
                                          StorageAnalytics ──▶ SavingsEstimator
                                                   │                 │
                                                   ▼                 ▼
                                       AnalyticsDashboardView   ConfirmationView
                                                                     │ (mandatory confirm)
                                                                     ▼
                                              CompressionPipeline (bounded TaskGroup, actor state)
                                                 ├─ FreeSpaceGuard (pause when low)
                                                 ├─ ImageCompressor → OUTPUT FOLDER (never Photos)
                                                 ├─ per-item retry / isolate failure (keep input)
                                                 └─ RunManifest (skip already-done on resume)
                                                                     │
                                                                     ▼
                                                             CompressionReport
```

Module dependency (build order): `PhotoAuthorization` + `PhotoLibraryProviding` → `LibraryScanner`/`AssetSizeReader` → `MediaClassifier` → `StorageAnalytics` → `SavingsEstimator` **(heuristic tier)** → `ImageCompressor`/`CompressionPolicy` → `SavingsEstimator` **(calibration tier, needs the compressor)** → `CompressionPipeline` (+`FreeSpaceGuard`,`RunManifest`) → UI. The estimator is split precisely because its heuristic math is independent of the compressor but its calibration re-projection calls it — see U5.

---

## Implementation Units

Grouped into four sub-phases. Dependencies cite U-IDs.

### Foundation

- U1. **Project scaffold & module boundaries**

**Goal:** Stand up the two-target structure: an Xcode SwiftUI `.app` shell with a real Info.plist, and the `iShrinkCore` SPM package with a test target. No feature logic yet.

**Requirements:** Enables all; directly R7 (Info.plist usage strings), R13 (local, no network — nothing added).

**Dependencies:** None.

**Files:**
- Create: `Core/Package.swift` (Swift tools 5.9, macOS `.v12`, `iShrinkCore` library target + `iShrinkCoreTests`)
- Create: `App/iShrinkApp.swift`, `App/Info.plist` (with `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription`), `App/iShrink.entitlements` (App Sandbox on, Photos entitlement, **no** `com.apple.security.network.client`), `iShrink.xcodeproj` (or `project.yml`)
- Create: `scripts/check-readonly.sh` (fails if `iShrinkCore` sources reference `PHAssetChangeRequest`/`PHAssetCreationRequest`/`PHAssetCollectionChangeRequest`/`performChanges`), wired into the test run
- Modify: `.gitignore` (add `*.xcodeproj/project.xcworkspace/xcuserdata/`, `*.xcodeproj/xcuserdata/` if not covered)
- Test: `Core/Tests/iShrinkCoreTests/SmokeTests.swift` (imports `iShrinkCore`, asserts it builds/links)

**Approach:**
- App target depends on the local `iShrinkCore` package. Keep `@main` app minimal (a placeholder window) until U8.
- Enable App Sandbox with the Photos entitlement and no network entitlement (enforces R13); confirm the app builds, signs (Developer ID / hardened runtime), and launches under the sandbox.
- Pin versions to match the spike.

**Execution note:** Scaffolding — no behavioral tests beyond a build/link smoke test, plus the read-only guard script.

**Patterns to follow:** `spikes/photokit-replace-spike/Package.swift` for tools/platform pins and Info.plist key names.

**Test scenarios:**
- Test expectation: none behavioral (scaffolding) — SmokeTests asserts the module imports/links; `check-readonly.sh` asserts no mutation-API references exist in `iShrinkCore` (and fails the build if introduced later).

**Verification:** `swift build` succeeds for `iShrinkCore`; the sandboxed app target builds, launches to an empty window, and has no network entitlement; Info.plist contains both usage-description keys; `check-readonly.sh` passes.

---

- U2. **Photos authorization service**

**Goal:** A `PhotoAuthorization` type that requests `.readWrite` access on the main actor, exposes current status, and models the denied / restricted / (defensive) limited states plus mid-job revocation checks.

**Requirements:** R7; supports R6 (first-run flow entry point).

**Dependencies:** U1.

**Files:**
- Create: `Core/Sources/iShrinkCore/Permissions/PhotoAuthorization.swift`
- Test: `Core/Tests/iShrinkCoreTests/PhotoAuthorizationTests.swift`

**Approach:**
- Wrap `PHPhotoLibrary.requestAuthorization(for: .readWrite)` (async form) and `authorizationStatus(for:)`. Expose a `Sendable` `AuthState` enum (`.notDetermined/.authorized/.denied/.restricted/.needsFullAccess`). Map macOS `.limited` → `.needsFullAccess` (research: `.limited` is iOS-only; handle defensively).
- Provide a `poll()` the pipeline calls at batch boundaries so revocation triggers a safe pause (R7/R11).
- Keep the raw PhotoKit call behind a tiny injectable closure so the state-mapping logic is unit-testable without real TCC.

**Patterns to follow:** `spikes/.../main.swift` authorization gate (`.authorized || .limited`), upgraded to async/await.

**Test scenarios:**
- Happy path: injected status `.authorized` → `AuthState.authorized`.
- Edge case: injected `.limited` → maps to `.needsFullAccess` (macOS defensive handling).
- Error path: injected `.denied`/`.needsFullAccess` → surfaces the deep-link-to-Settings affordance flag.
- Edge case: injected `.restricted` (MDM/parental controls) → surfaces explanatory copy with **no** Settings deep-link (not user-resolvable).
- Integration: foreground re-check — status flips `.denied → .authorized` between checks → the gate reports it can advance (no relaunch needed).
- Integration: `poll()` transitioning `.authorized → .denied` between calls reports a revocation event the pipeline can act on.

**Verification:** All state mappings covered by tests with an injected status source; no real TCC needed to run the suite.

---

### Read & Analyze

- U3. **Library scanner & asset sizing**

**Goal:** Enumerate the library lazily into `AssetRecord` value types, reading per-asset on-disk size and local-availability without triggering iCloud downloads.

**Requirements:** R1 (counts, detection inputs), R2 (size, largest files), R6 (local-availability), R9 (memory discipline at scale).

**Dependencies:** U2.

**Files:**
- Create: `Core/Sources/iShrinkCore/Library/PhotoLibraryProviding.swift` (protocol + `AssetRecord`)
- Create: `Core/Sources/iShrinkCore/Library/PhotoKitLibrary.swift` (real conformer)
- Create: `Core/Sources/iShrinkCore/Library/AssetSizeReader.swift` (guarded KVC + fallback)
- Create: `Core/Sources/iShrinkCore/Scan/LibraryScanner.swift`
- Test: `Core/Tests/iShrinkCoreTests/LibraryScannerTests.swift`, `AssetSizeReaderTests.swift`

**Approach:**
- `PhotoLibraryProviding` returns an async sequence / paged accessor over lightweight `AssetRecord { localIdentifier, mediaType, mediaSubtypes, primaryUTI, resourceUTIs, byteSize, isLocallyAvailable, originalFilename, creationDate, pixelWidth/Height }`. `PhotoKitLibrary` builds records from `PHAsset` + `PHAssetResource.assetResources(for:)`, wrapping each batch in `autoreleasepool`, keeping the `PHFetchResult` and paging by index (never copying to an array).
- `AssetSizeReader`: for each of the asset's resources try `resource.value(forKey: "fileSize") as? Int64`; on nil/≤0 fall back to `PHAssetResourceManager.requestData` with `isNetworkAccessAllowed = false` summing chunk lengths. **Sum across all resources** so edited photos (original + adjustment) and Live Photos (photo + pairedVideo) aren't undercounted. **Cross-validate** the KVC value against the fallback on a sampled subset each run; on divergence beyond tolerance, switch the whole run to the fallback. Never enable network access.
- **Resource-selection policy (explicit):** storage totals sum *all* resources; the compressor (U6) exports the **primary photo resource** (`.photo` / `.fullSizePhoto`), and an *edited* photo's exclusion/selection is decided in U4 — Phase 1 does not attempt to re-render user edits, so an edited photo is labelled and (by default) excluded rather than exported from the unedited original.
- `LibraryScanner` streams records to a caller-provided sink with progress callbacks; it depends only on the protocol, so tests drive it with `FakeLibrary`.

**Execution note:** Characterize scanner behavior against a `FakeLibrary` first; the real `PhotoKitLibrary` conformer is validated manually against a live library (can't run in CI).

**Patterns to follow:** research §1a/§1b; spike's `PHAssetResource`/`PHAssetResourceManager` usage shapes.

**Test scenarios:**
- Happy path: `FakeLibrary` of 1,000 records → scanner yields all 1,000 with correct counts by `mediaType`.
- Edge case: empty library → zero counts, no crash.
- Edge case: an asset whose size read returns nil from the primary path → `AssetSizeReader` falls back and still yields a size (fake injects both behaviors).
- Edge case: KVC returns a plausible-but-wrong nonzero size diverging from the fallback beyond tolerance → run switches to the fallback path (not trusted on nonzero alone).
- Edge case: multi-resource asset (photo + adjustment, or Live photo + pairedVideo) → reported size is the **sum** of all resources, not just the primary.
- Edge case: iCloud-only record (`isLocallyAvailable == false`) is yielded with the flag set, and no network fetch is attempted (fake asserts network-off).
- Integration/scale: 100k `FakeLibrary` records processed with bounded memory (assert peak record buffer stays paged, not a full copy).

**Verification:** Scanner tests pass on `FakeLibrary`; a manual smoke run against a small real library produces sane counts/sizes.

---

- U4. **Media classifier & storage analytics**

**Goal:** Classify each `AssetRecord` (codec, Live Photo, HDR, RAW/ProRAW) and compute exclusion classes; aggregate into a codec breakdown, totals, and largest-files/albums analytics.

**Requirements:** R1 (codec breakdown, Live/RAW/HDR detection), R2 (totals, largest), R3/R5/R6 (exclusion classes).

**Dependencies:** U3.

**Files:**
- Create: `Core/Sources/iShrinkCore/Classify/MediaClassifier.swift`
- Create: `Core/Sources/iShrinkCore/Analytics/StorageAnalytics.swift`
- Test: `Core/Tests/iShrinkCoreTests/MediaClassifierTests.swift`, `StorageAnalyticsTests.swift`

**Approach:**
- `MediaClassifier` maps a record to `{ codec: .jpeg/.heic/.png/.rawOrProRaw/.h264/.hevc/.otherVideo/.unknown, isLivePhoto, isHDR, eligibility: .compressible | .excluded(reason) }`. RAW/ProRAW via `UTType(uti)?.conforms(to: .rawImage)`; **HDR via `mediaSubtypes.contains(.photoHDR)` OR a gain-map auxiliary probe** (`CGImageSourceCopyAuxiliaryDataInfoAtIndex` / `kCGImageAuxiliaryDataTypeHDRGainMap`) — the subtype alone under-detects modern gain-map captures. Exclusion reasons: `.rawMaster`, `.hdrUnpreservable`, `.iCloudOnly`, `.alreadyHeic`, `.livePhoto`, `.editedPhoto`. Video → analytics-only (Phase 1 excludes from compression). A **Live Photo whose still is JPEG** is excluded (`.livePhoto`) rather than exported as an orphaned still, so analytics stay honest.
- The gain-map probe is a per-file ImageIO read; run it **only on candidates that pass the cheap subtype/UTI filters** (not every asset) to bound scan cost at 100k — see Deferred to Implementation on scan-cost measurement.
- `StorageAnalytics` folds classified records into: per-codec count+bytes, total bytes, compressible bytes, excluded bytes by reason, top-N largest files. **Largest *albums* and cross-run compression *history* are deferred** (see Scope Boundaries › Deferred to Follow-Up Work) — Phase 1's report covers the current run only.

**Execution note:** Pure logic — test-first.

**Patterns to follow:** research §1c (UTType conformance, subtypes).

**Test scenarios:**
- Happy path: JPEG record → `.jpeg`, `.compressible`; H.264 video record → `.h264`, analytics-only.
- Edge case: `com.adobe.raw-image` and a vendor RAW UTI (e.g. `com.sony.arw-raw-image`) both → `.rawOrProRaw`, `.excluded(rawMaster)`.
- Edge case: record with `.photoHDR` subtype → `isHDR true`, `.excluded(hdrUnpreservable)`.
- Edge case: gain-map HDR photo with **no** `.photoHDR` subtype but a `kCGImageAuxiliaryDataTypeHDRGainMap` auxiliary → still `isHDR true`, `.excluded(hdrUnpreservable)` (the under-detection case R5 depends on).
- Edge case: Live Photo with a JPEG still → `.excluded(livePhoto)`, not exported as an orphaned still.
- Edge case: already-`public.heic` still image → `.excluded(alreadyHeic)` (unless resize requested — resize flag off in Phase 1).
- Edge case: `isLocallyAvailable == false` → `.excluded(iCloudOnly)` regardless of codec.
- Happy path: analytics over a mixed fixture set → correct per-codec bytes, correct total, correct compressible-vs-excluded split, correct top-N largest.

**Verification:** Classifier and analytics fully covered by fixtures; excluded-byte accounting reconciles to total bytes.

---

- U5. **Savings estimator**

**Goal:** Estimate realistic post-compression size and savings from the real codec mix, refined by a small measured calibration sample before the confirmation screen.

**Requirements:** R2, R8 (drives the confirmation numbers).

**Dependencies:** **Heuristic tier depends only on U4** (builds early, unblocks the analytics dashboard). **Calibration tier depends on U6** (calls the compressor on a sample) and builds after it — the two tiers are deliberately separable so the "Read & Analyze" sub-phase ships without waiting on the compressor.

**Files:**
- Create: `Core/Sources/iShrinkCore/Estimate/SavingsEstimator.swift`
- Test: `Core/Tests/iShrinkCoreTests/SavingsEstimatorTests.swift`

**Approach:**
- **Tier 1 — heuristic (no compressor):** apply a default expected-ratio table by source codec to compressible bytes for an instant estimate. Pure math, injected ratios, ships in Read & Analyze.
- **Tier 2 — calibration (needs U6):** compress a small representative sample (e.g. N largest-plus-random JPEGs) via `ImageCompressor` to the app-private temp dir, measure the actual ratio, and re-project. Wired in after the compressor exists.
- Report a **range**, not a false-precision single number (origin honesty about savings).
- Estimator takes ratios as injected parameters so the projection math is testable without real encoding.

**Execution note:** Test-first for the projection math; calibration path validated with fixture images in U6's suite.

**Patterns to follow:** origin Success Metrics (30–70% framing computed per-library, not asserted).

**Test scenarios:**
- Happy path: 10 GB compressible JPEG at injected 0.5 ratio → 5 GB estimate, 5 GB savings.
- Edge case: 0 compressible bytes → 0 savings, no divide-by-zero.
- Edge case: all-HEIC/HEVC library → near-zero compressible → estimate honestly reports small savings (guards against the origin "validate savings" concern).
- Integration: calibration re-projection replaces heuristic ratio with a measured one from a fixture sample and the confirmation number shifts accordingly.

**Verification:** Projection math exact under injected ratios; calibration changes the estimate when the measured ratio differs from the heuristic.

---

### Compress

- U6. **Non-destructive HEIC compression engine**

**Goal:** Compress one eligible photo to a `.heic` in the output folder, preserving file-embedded metadata, orientation, and color profile; enforce the eligibility policy; never touch the library.

**Requirements:** R3, R4, R5, R13.

**Dependencies:** U4 (eligibility), U1.

**Files:**
- Create: `Core/Sources/iShrinkCore/Compress/CompressionPolicy.swift` (eligibility from classification + user options)
- Create: `Core/Sources/iShrinkCore/Compress/ImageCompressor.swift`
- Test: `Core/Tests/iShrinkCoreTests/ImageCompressorTests.swift` (with committed fixture images incl. GPS/EXIF and a P3 image)

**Approach:**
- Export the primary photo resource bytes to the **app-private temp dir** (`PHAssetResourceManager.writeData` shape for the real conformer; tests operate directly on fixture file URLs, no PhotoKit). Never write working copies to the destination volume.
- Encode to a **temp `.heic` in the app-private dir** with `CGImageDestinationCreateWithURL(tmpOut, UTType.heic.identifier, 1, nil)` + `CGImageDestinationAddImageFromSource(dest, src, 0, [kCGImageDestinationLossyCompressionQuality: q])` + `Finalize`. Only on `Finalize == true`, **atomically move** the finished file into the user's destination under the collision-safe name (namespaced by `localIdentifier`). Fallback properties path only if a resize is requested (Phase 1 default: no resize).
- **Metadata is best-effort and honestly reported:** GPS, DateTimeOriginal, camera make/model, orientation, and timezone are asserted preserved; **lens (often MakerNote-resident) is best-effort** — the compressor returns a per-item metadata-fidelity result the report can surface, rather than silently claiming full preservation.
- Treat `Finalize == false` as a failure → no partial output reaches the destination (the temp file is discarded); leave the input untouched (R10 handoff to U7).
- `CompressionPolicy` refuses RAW/ProRAW, HDR, iCloud-only, already-HEIC (unless resize), Live Photos, and edited photos — a second guard even though U4 pre-filters.

**Execution note:** Test-first, and this unit absorbs the origin "extend the spike" gap by diffing EXIF before/after a real re-encode.

**Patterns to follow:** research §2a/§2b; spike resource-export shape.

**Test scenarios:**
- Happy path: fixture JPEG → HEIC in the destination dir; output smaller than input at default quality; the intermediate temp file is gone from the app-private dir.
- Covers R4: GPS+EXIF fixture → `CGImageSourceCopyPropertiesAtIndex` before/after shows lat/long, DateTimeOriginal, camera make/model, timezone, and **orientation** preserved on the output.
- Metadata-fidelity path: a fixture whose lens lives in MakerNote → the compressor's returned fidelity result flags lens as best-effort (preserved-or-not) rather than the test asserting guaranteed lens preservation (matches the best-effort contract).
- Edge case: Display-P3 fixture → output retains the P3 ICC profile (not silently sRGB).
- Atomicity: a `Finalize`-fails injection leaves **no** file at the destination (only a discarded temp), proving no truncated output can reach the output folder.
- Edge case: already-HEIC input with resize off → policy returns `.excluded(alreadyHeic)`, no output written.
- Error path: unreadable/corrupt input → `Finalize` fails or throws → no output file created, error surfaced, input untouched.
- Edge case: RAW / HDR (incl. gain-map) / Live / edited fixture → policy refuses (`.excluded(reason)`), no encode attempted.

**Verification:** Fixture round-trips preserve the R4 metadata set including orientation and P3; no output on skip/fail; output never lands anywhere but the chosen folder.

---

- U7. **Bounded streaming pipeline**

**Goal:** Drive many assets through the compressor with a bounded concurrency window, a live free-space guardrail, per-item failure isolation with one retry, immediate temp cleanup, and a resume manifest — plus safe pause/cancel at item boundaries.

**Requirements:** R9, R10, R11 (pause/cancel/resume mechanics), R6 (skip non-local).

**Dependencies:** U6, U2 (revocation poll).

**Files:**
- Create: `Core/Sources/iShrinkCore/Pipeline/CompressionPipeline.swift`
- Create: `Core/Sources/iShrinkCore/Pipeline/FreeSpaceGuard.swift`
- Create: `Core/Sources/iShrinkCore/Pipeline/RunManifest.swift`
- Create: `Core/Sources/iShrinkCore/Pipeline/TempStore.swift` (app-private temp dir + per-item cleanup + startup orphan sweep)
- Test: `Core/Tests/iShrinkCoreTests/CompressionPipelineTests.swift`, `FreeSpaceGuardTests.swift`, `RunManifestTests.swift`, `TempStoreTests.swift`

- Bounded `TaskGroup` sliding window (size ≈ `activeProcessorCount / 2`, injectable for tests). Shared state (running totals, manifest, guard) in an `actor`. `autoreleasepool` per item; remove the item's app-private temp file immediately after commit/fail.
- **Orphan sweep on startup:** before a run, sweep and delete any leftover files in the app-private temp dir from a crashed/force-quit prior run (they may contain unredacted GPS/EXIF). This is the crash-time complement to per-item cleanup.
- `FreeSpaceGuard` reads `volumeAvailableCapacityForImportantUsage` on the **destination** volume; below threshold → stop admitting new items (pause), resume when it recovers. **Nil-capacity policy:** the key returns nil on network shares / exotic volumes — fall back to `volumeAvailableCapacity`, and if that is also nil, surface a blocking "can't monitor free space on this volume" setup error rather than filling the disk.
- **Typed pause reasons.** The pipeline exposes a `PauseReason` (`.userRequested`, `.lowDiskSpace`, `.authorizationRevoked`, `.destinationUnavailable`) so U9 can show *why* it stopped and what the user must do. Distinct from Cancel.
- **Structural (non-per-item) failures** — destination volume unmounted/unwritable mid-run — transition the whole run to a blocking error state (`.destinationUnavailable`), not per-item isolation. Per-item isolation covers only per-asset encode failures.
- Failure isolation: a thrown/`false` result increments a failure log, keeps the input, and one **transient**-classified retry is attempted; the batch continues (R10). **Transient = a bounded set** (disk-pressure `ENOSPC`/`EDQUOT`, briefly-locked-file, temporary I/O error); permanent errors (corrupt input, unsupported format, `Finalize` false on a readable file) are **not** retried.
- **Failure-log entries carry identifier / filename / error-code only — never raw EXIF/GPS payloads** — so logs and any support bundle stay free of location data.
- Pause/Cancel: cooperative flags checked at the top of each item; in-flight items finish (never mid-item), then the group drains. `RunManifest` records **items completed, keyed on `localIdentifier`**, as an append-only log with periodic atomic checkpoints; **resume skips items recorded complete in the manifest** (not "a file exists at the path"), and overwrites any stray output whose item isn't in the manifest. Phase-3's atomic journal is still out of scope.
- Poll `PhotoAuthorization` at batch boundaries; revocation → pause with `.authorizationRevoked`.

**Execution note:** Drive with a `FakeCompressor` (deterministic success/fail/slow) so concurrency, guardrail, retry, pause, and resume are all testable without real encoding.

**Patterns to follow:** research §3a/§3b.

**Test scenarios:**
- Happy path: 100 fake items, window 4 → all complete; never more than 4 in flight (assert observed concurrency ≤ 4).
- Error path: an item that always fails → logged, input untouched, batch still finishes the other 99.
- Error path: an item that fails once then succeeds (transient class) → single retry, ends successful.
- Error path: a **permanent** failure (corrupt input) → **no** retry, logged once, batch continues.
- Edge case: `FreeSpaceGuard` reports low space mid-run → pipeline pauses with `.lowDiskSpace`, resumes when space recovers; no item interrupted mid-write.
- Edge case: `volumeAvailableCapacityForImportantUsage` returns nil → falls back to `volumeAvailableCapacity`; if also nil → blocking setup error (guard never silently no-ops).
- Edge case: orphan temp file present at startup → swept before the run begins (assert app-private dir is empty after sweep).
- Edge case: destination volume unmounted mid-run → run enters `.destinationUnavailable` blocking state (not per-item isolation).
- Edge case: Pause requested → in-flight items finish, no new items start; Cancel → same, then stops.
- Integration: interrupted run leaves a `RunManifest`; re-run skips items recorded complete (by `localIdentifier`) and processes only the remainder.
- Integration: a stray output file exists at a path whose item is **not** in the manifest (simulating a truncated prior write) → the resumed run overwrites it rather than skipping.
- Integration: authorization poll flips to revoked → pipeline pauses with `.authorizationRevoked` at the next boundary.

**Verification:** Concurrency bound, retry, failure isolation, guardrail pause, and manifest-based resume all proven with the fake compressor; temp dir is empty after a run.

---

### UI

- U8. **App UI: permission → scan → analytics → selection → confirmation**

**Goal:** The SwiftUI surface from first-run permission through the analytics dashboard, rule-based/smart selection, and the mandatory confirmation screen.

**Requirements:** R6, R7, R8, R1/R2 (surfaced), R11 (scan progress).

**Dependencies:** U3, U4, U5, U2.

**Files:**
- Create: `App/Views/PermissionGateView.swift`, `App/Views/ScanView.swift`, `App/Views/AnalyticsDashboardView.swift`, `App/Views/SelectionView.swift`, `App/Views/ConfirmationView.swift`
- Create: `App/ViewModels/AppModel.swift`
- Create: `Core/Sources/iShrinkCore/Selection/SelectionRules.swift`, `Core/Sources/iShrinkCore/Selection/DestinationValidator.swift`, `Core/Sources/iShrinkCore/Classify/ExclusionReason.swift` (enum + user-facing copy table)
- Test: `Core/Tests/iShrinkCoreTests/SelectionRulesTests.swift`, `DestinationValidatorTests.swift` (selection/filter/validation logic lives in Core, not the View)

- `PermissionGateView`: first-run pre-prompt explaining why full access is needed and that nothing leaves the Mac; **distinct states for `.denied` vs `.restricted`** — `.denied`/`.needsFullAccess` show the one-click Settings deep link (R7); `.restricted` (MDM/parental controls) shows explanatory copy **without** a deep link, since it isn't user-resolvable. **Re-check authorization on app foreground** (`NSApplication.didBecomeActive`) so a user who grants access in Settings advances past the gate without relaunching.
- **iCloud first-run question:** a one-time modal, shown after Photos access is granted, asking whether iCloud Photos is enabled; the answer is persisted (R6). A "yes" answer surfaces a **persistent, dismissible banner** on the analytics/selection screens noting only locally-present originals will be processed (it does not change the exclusion logic, which already skips non-local assets — it sets expectations). Exact copy is a UI detail for implementation; the *placement and behavior* are fixed here.
- `ScanView`: progress (items scanned, elapsed) driven by U3 callbacks on `@MainActor`, **with a Cancel affordance** to abort a long 100k-asset scan without force-quitting.
- `AnalyticsDashboardView`: **savings estimate is the primary element** (the low-disk user's headline), with codec breakdown, totals, and largest files as secondary detail. Excluded assets are shown as a **count-per-reason summary** (RAW master, HDR, iCloud-only, already-HEIC, Live, edited) using a **shared `ExclusionReason`→copy string table** (defined alongside the enum so phrasing is consistent), with optional drill-down deferred.
- `SelectionView`: **smart default** (all `.compressible`) + **rule filters** (type, size threshold, age); manual per-asset selection at scale is deferred (Scope Boundaries). Put the filter/predicate logic in a Core `SelectionRules` type so it's unit-tested headlessly.
- `ConfirmationView`: mandatory gate showing item count, current size → estimated size, estimated savings, and the output-folder picker (`NSOpenPanel`); nothing runs until confirmed (R8). **Validates the chosen destination** at confirmation time: rejects read-only/unwritable folders and warns on insufficient free space; **warns (with explicit acknowledgement) if the destination resolves under a known cloud-sync container** (`~/Library/Mobile Documents`, `~/Dropbox`, `~/OneDrive`, …), because outputs carry GPS/EXIF and would otherwise be auto-uploaded — a real egress path against R13. **Distinct zero-item copy:** "filter matches nothing" (adjust filter) vs "library has nothing compressible" (all HEIC/RAW/iCloud-only) read differently so the disabled Start button is never unexplained.

**Patterns to follow:** research §1d (request auth on main actor from GUI); origin Permissions + Selection + Preview sections.

**Test scenarios:**
- Happy path (`SelectionRules`): "videos > 200 MB, older than 2 years" over a fixture set selects exactly the matching records.
- Edge case: a filter matching zero assets → "adjust filter" messaging; an all-HEIC/RAW/iCloud library with zero compressible → "nothing compressible" messaging (distinct copy, both disable Start).
- Edge case: smart default excludes all `.excluded(reason)` assets automatically.
- Destination validation (`DestinationValidator` in Core): read-only folder → rejected; path under `~/Library/Mobile Documents` or `~/Dropbox` → cloud-sync warning flag set; ordinary local folder → clean.
- Integration: confirmation numbers equal the estimator output for the selected subset (not the whole library).
- Test expectation for pure Views: none — logic under test lives in `AppModel`/`SelectionRules`/`DestinationValidator`; Views are thin. Permission re-check-on-foreground and the restricted-vs-denied branch are validated in `PhotoAuthorization` (U2) tests.

**Verification:** Permission lifecycle reachable in the running app; selection rules unit-tested; confirmation blocks until an output folder is chosen and the user confirms.

---

- U9. **App UI: compression run & report**

**Goal:** The run screen (progress, running GB saved, ETA, Pause/Cancel) and the post-run report, wired to U7.

**Requirements:** R11, R12, R10 (surface failures).

**Dependencies:** U7, U8.

**Files:**
- Create: `App/Views/CompressionRunView.swift`, `App/Views/ReportView.swift`
- Create: `Core/Sources/iShrinkCore/Report/CompressionReport.swift`
- Test: `Core/Tests/iShrinkCoreTests/CompressionReportTests.swift`

- `CompressionRunView`: items done/total, current file, elapsed/ETA, running GB saved, and Pause/Cancel buttons. **When paused, the view shows the `PauseReason` and its remediation** — user-paused ("Resume" enabled), `.lowDiskSpace` ("free up space on <volume>"), `.authorizationRevoked` ("re-grant Photos access"), `.destinationUnavailable` (blocking, "reconnect <volume>"). **Cancel shows a confirmation** ("Stop compressing? Files already finished are kept in <folder>.") so an accidental click doesn't silently abort a long run. State updates marshalled to `@MainActor`.
- **Resume affordance:** on relaunch (or re-entering the flow) with an incomplete `RunManifest` for the same selection+destination, present a **Resume / Discard prompt** (items done / remaining) rather than silently re-running — the user must see that a resume is happening (mirrors the origin Resume & Atomicity intent, at Phase-1 weight).
- `CompressionReport` (Core): totals saved, compression ratio, per-type breakdown, largest savers, and the failure list. **Explicit all-failed / zero-success state:** when no item succeeded, the report renders as a failure summary (no divide-by-zero ratio, not a success-styled screen). `ReportView` renders it, and offers post-report actions (reveal output folder in Finder, start another selection).
- Report **export** excludes raw GPS by default (`redactGPS = true`); **enabling GPS inclusion requires an explicit confirmation** ("This report will include exact photo locations — continue?"), not a bare toggle, since an exported report is shareable (R12).
- Report is derived from the `RunManifest` + per-item results so it survives a resumed run.

**Patterns to follow:** origin Reporting; research §3 (totals from the actor state).

**Test scenarios:**
- Happy path: run of 100 items (90 ok, 10 excluded, 0 failed) → report shows correct saved bytes, ratio, and per-type split.
- Edge case: run with failures → failures listed with reasons; saved-bytes counts only successful items.
- Edge case: all-failed / zero-success run → report renders a failure summary with no divide-by-zero ratio and no success styling.
- Covers R12: exported report with `redactGPS = true` (default) omits coordinates; opt-in includes them.
- Edge case: resumed run → report reflects combined totals across both runs via the manifest.

**Verification:** Report math reconciles with pipeline results; default export contains no GPS; Pause/Cancel visibly stop new items at a boundary in a manual run.

---

## System-Wide Impact

- **Interaction graph:** UI (`@MainActor`) ↔ `AppModel` ↔ Core engine (actor-isolated pipeline). The only PhotoKit entry points are `PhotoAuthorization` and `PhotoKitLibrary`; everything else is pure/file-based. Authorization is requested once from the GUI; the pipeline only *reads* status.
- **Error propagation:** per-item errors are values (kept-input + logged with identifier/filename/error-code only, never raw GPS/EXIF), not thrown out of the batch (R10). Setup errors (no permission, no/invalid output folder, disk full at start) **and structural mid-run failures** (destination volume unmounted/unwritable) surface to the UI as blocking states (`.destinationUnavailable`), distinct from per-item isolation.
- **State lifecycle risks:** working copies and encode outputs live in an **app-private temp dir** (never the destination volume) and are removed per item even on failure, with a startup **orphan sweep** for crash leftovers (they carry unredacted GPS/EXIF). The `RunManifest` is an append-only log keyed on `localIdentifier` with atomic checkpoints; resume keys on manifest records, so a truncated stray output is overwritten, not skipped. No library state is touched, so there is **no** duplicate-asset risk in Phase 1 (that risk is the Phase-3 crash-window in the origin Open follow-ups — explicitly out of scope here).
- **API surface parity:** none external — no network (enforced by the sandbox's absent network entitlement), no exported API. The eventual CLI (origin Stretch Goal) will reuse `iShrinkCore` directly; keeping logic out of Views is what makes that possible later.
- **Integration coverage:** the `FakeLibrary`/`FakeCompressor` seams prove scan/estimate/pipeline behavior headlessly; the real PhotoKit conformers need one manual pass against a live library (documented, not CI-able).
- **Unchanged invariants:** the Apple Photos library is **read-only** in Phase 1 — no change requests of any kind, **enforced by `scripts/check-readonly.sh`** (not just convention). This is the load-bearing safety property of the whole phase.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Undocumented `fileSize` KVC returns nil **or a plausible-but-wrong value** on a future macOS | `AssetSizeReader` cross-validates against the documented fallback on a sampled subset and switches the whole run to the fallback on divergence; test fails loudly on nil for a supported OS |
| HDR photos silently flattened to SDR | Detected via subtype **and** gain-map auxiliary probe, then **excluded** in Phase 1 (R5); HDR transcode deferred to macOS 14/15+ |
| `AddImageFromSource` drops MakerNote-resident lens info | Metadata is best-effort and honestly labelled; the compressor returns a per-item fidelity result and the UI/report never claim guaranteed lens preservation (2026-07-24 review decision) |
| Output written to a cloud-synced destination folder auto-uploads GPS-bearing photos (R13 egress) | `DestinationValidator` warns with explicit acknowledgement when the destination resolves under a known cloud-sync container; App Sandbox has no network entitlement so the app itself never uploads |
| Duplicate output filenames clobber each other / corrupt resume | Outputs namespaced by `localIdentifier`; manifest keyed on `localIdentifier`; atomic move only on `Finalize` success |
| Per-item atomic manifest rewrite is O(n²) at 100k | Append-only log on the hot path + periodic atomic checkpoints |
| Orphaned temp copy with GPS/EXIF survives a crash | App-private temp location + startup orphan sweep |
| PhotoKit can't run in CI | Protocol seams (`PhotoLibraryProviding`) + fakes for all logic tests; real conformers validated by a documented manual pass |
| No Xcode on some build hosts (research host had none) | U1 prerequisite: Xcode (or `xcodegen` + `xcodebuild`) on the dev/CI machine; the `iShrinkCore` package still builds/tests with the Swift toolchain alone |
| Scan cost at 100k assets (esp. if video codec detection opens `AVAsset` per item) | Video codec detection kept lazy/optional in Phase 1 (deferred decision in U4); scan measured on a real library before committing |
| Savings under-deliver on modern HEIC/HEVC libraries | Estimator reports a **range** and honestly shows small numbers when compressible bytes are low (origin "validate savings") |

---

## Documentation / Operational Notes

- Add a short `Core/README.md` describing the `iShrinkCore` module map and the `PhotoLibraryProviding` seam so contributors can test without a real library.
- Record the manual live-library validation steps (permission grant, small-library scan, sample compress) as a checklist — this is the substitute for CI on the PhotoKit conformers.
- After Phase 1 lands, capture learnings (PhotoKit scan cost, real JPEG→HEIC ratios, metadata fidelity results) via `/ce-compound` into a newly-seeded `docs/solutions/`.

---

## Sources & References

- **Origin document:** [iShrink-PRD.md](iShrink-PRD.md) — Phase 1 scope, Metadata Preservation, NFRs, Decisions #3/#4/#21, Open follow-ups.
- Existing spike: `spikes/photokit-replace-spike/Sources/PhotoKitReplaceSpike/main.swift`, `spikes/photokit-replace-spike/Package.swift`
- Apple docs: [PHFetchOptions](https://developer.apple.com/documentation/photokit/phfetchoptions), [PHAssetResourceManager](https://developer.apple.com/documentation/photokit/phassetresourcemanager), [CGImageDestinationAddImageFromSource](https://developer.apple.com/documentation/imageio/1465181-cgimagedestinationaddimagefromso), [kCGImageAuxiliaryDataTypeHDRGainMap](https://developer.apple.com/documentation/imageio/kcgimageauxiliarydatatypehdrgainmap), [volumeAvailableCapacityForImportantUsage](https://developer.apple.com/documentation/foundation/urlresourcevalues/2887126-volumeavailablecapacityforimport), [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
