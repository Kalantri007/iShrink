# iShrink

**Open Source Apple Photos Library Optimizer for macOS**

A privacy-first, open source Mac app that safely compresses the photos and videos in your Apple Photos library to reclaim local disk space — preserving visual quality and metadata, and never sending your media anywhere.

> 🚧 **Status: pre-implementation.** This repository currently holds the requirements document and a technical spike. No app code exists yet — see [Status](#status) below.

---

## Why

Modern phones capture 48 MP photos, ProRAW, ProRes, and 4K/8K video — beautiful media that quietly eats hundreds of gigabytes over the years. The usual fixes are a bigger iCloud plan, a new phone, or a paid closed-source tool. There's no mature open source project that safely compresses an Apple Photos library *in place*, with metadata and safety guarantees, while staying fully auditable.

iShrink aims to be that tool: the focused, Photos-native equivalent of what [CompressO](https://github.com/codeforreal1/compressO) is for general video compression — not a full media-management platform.

## v1 scope, in plain terms

- **macOS only**, operating on an Apple Photos library on that Mac
- **Local disk space only** — reduces the Mac's on-disk Photos footprint (iCloud storage savings are a later-phase goal)
- **Non-iCloud libraries in v1** — since there's no public API to detect the iCloud Photos toggle, the app asks once at first run and remembers the answer, rather than guessing
- **Safety-first**: verify (decode + checksum) before replacing anything, keep a 30-day undo window via the system's Recently Deleted, offer an optional external archive for permanent rollback, and never touch RAW / ProRAW / ProRes / Cinematic media unless you explicitly opt in
- **Native-first**: prefers Apple's own frameworks (PhotoKit, ImageIO, AVFoundation, VideoToolbox) over bundled third-party binaries, sandboxing any fallback that's still needed

The full detail — functional requirements, architecture, tech stack, and every scope decision with its reasoning — lives in [`iShrink-PRD.md`](iShrink-PRD.md).

## Status

| Stage | State |
|---|---|
| Requirements (PRD) | ✅ Written, multi-persona reviewed (2 rounds), all open questions resolved |
| PhotoKit replace-workflow spike | ✅ Written ([`spikes/photokit-replace-spike/`](spikes/photokit-replace-spike/)) — verifies which metadata survives the create-new + delete-old workflow that PhotoKit requires. Not yet run/validated. |
| Implementation plan | ⏳ Not started |
| App code | ⏳ Not started |

See the PRD's **Resolved Decisions** section for the full history of scope and architecture calls, and **Open follow-ups** for what's still genuinely open (a few implementation-shaping questions deferred to planning on purpose).

## Repository layout

```
iShrink-PRD.md              — the requirements document (read this first)
spikes/
  photokit-replace-spike/   — small standalone test verifying PhotoKit metadata
                               survival across the replace workflow (see its own
                               README for how to run it)
```

## Tech stack (planned)

Swift + SwiftUI, built on PhotoKit / AVFoundation / VideoToolbox / ImageIO / Core Image, with FFmpeg / libheif as a sandboxed fallback only where the native frameworks fall short. Full rationale in the PRD's Tech Stack section.

## Contributing

Not yet open for contributions — the requirements are settled but there's no implementation plan or code to build against. Once planning starts, this section will point to the plan and open issues.

## License

Not yet chosen.
