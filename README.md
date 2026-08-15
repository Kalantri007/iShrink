# iShrink

**Open Source Apple Photos Library Optimizer for macOS**

A privacy-first, open source Mac app that safely compresses the photos and videos in your Apple Photos library to reclaim local disk space — preserving visual quality and metadata, and never sending your media anywhere.

> 🚧 **Status: early.** Phase 1 — scan, analyse, and compress to a folder you choose — is implemented and installable. iShrink does not yet write anything back into your Photos library. See [Status](#status) below.

---

## Install

### With Homebrew

```
brew install --cask Kalantri007/tap/ishrink
```

*Available from the first tagged release onward. Until then, use the build-it-yourself path below.*

That one command adds the tap and installs the app — there's no separate `brew tap` step. Then, once:

```
sudo xattr -rd com.apple.quarantine /Applications/iShrink.app
```

**Why that second command is needed, and why you shouldn't just trust it.** Pasting a `sudo` command from a README is a reasonable thing to be suspicious of, so here is exactly what it does and why it's unavoidable.

macOS flags everything downloaded from the internet. Normally the developer's Apple Developer ID signature clears that flag — but that certificate costs $99/year, and iShrink doesn't have one. Without it macOS refuses to open the app and says *"iShrink is damaged and can't be opened."* That message is misleading: nothing is damaged, it's just unsigned. The command above removes only that download flag, only from iShrink, and changes nothing else on your system. Homebrew used to do this for you with a `--no-quarantine` flag, but that was removed in Homebrew 5.1 and is no longer available to community taps, so the step is genuinely manual now.

You will also be asked for Photos access again after **every** update. Each release is signed with a throwaway identity, and macOS ties permission grants to that identity, so a new version looks like a brand new app to it. That's expected, not a bug.

### Build it yourself

Works today, needs no Homebrew, and never breaks when Homebrew changes its rules. Requires Xcode installed, but you never have to open it:

```
./scripts/build-app.sh
```

That builds a universal Release binary, checks the result is correctly signed and entitled, and installs it to `/Applications`. No quarantine step is needed — an app you built locally was never downloaded, so it was never flagged. Photos access is re-requested after each rebuild, for the same signing-identity reason described above.

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
| PhotoKit replace-workflow spike | ✅ Written ([`spikes/photokit-replace-spike/`](spikes/photokit-replace-spike/)) — verifies which metadata survives the create-new + delete-old workflow that PhotoKit requires. **Not yet run/validated.** |
| Phase 1 — scan, analyse, compress to a chosen folder | ✅ Implemented and merged, 112 tests passing |
| Distribution — no-Xcode install | ✅ Local build script; Homebrew cask and tagged releases wired up |
| Validated against a large real photo library | ⏳ Not yet |
| Phase 3 — writing compressed media back into Photos | ⏳ Not started |

**What iShrink does today:** reads your Photos library, estimates what could be saved, and writes compressed copies into a folder you pick. **What it does not do yet:** modify your Photos library in any way. The replace-and-reclaim workflow is a later phase, gated on the spike above actually being run.

See the PRD's **Resolved Decisions** section for the full history of scope and architecture calls, and **Open follow-ups** for what's still genuinely open.

## Repository layout

```
iShrink-PRD.md              — the requirements document (read this first)
App/                        — the SwiftUI app: views, view models, entitlements
Core/                       — iShrinkCore, the engine, as a Swift package with
                               its own test suite (swift test)
scripts/
  build-app.sh              — build, verify, and install the app in one command
  verify-app.sh             — asserts a built .app is signed, entitled, and
                               universal; run by both the local and CI paths
  check-readonly.sh         — fails the build if a PhotoKit mutation API ever
                               appears in iShrinkCore
packaging/homebrew/         — the Homebrew cask, whose live copy belongs in the
                               separate homebrew-tap repository
docs/plans/                 — the implementation plans behind each phase
spikes/
  photokit-replace-spike/   — small standalone test verifying PhotoKit metadata
                               survival across the replace workflow (see its own
                               README for how to run it)
```

## Tech stack

Swift + SwiftUI, built on PhotoKit / AVFoundation / VideoToolbox / ImageIO / Core Image, with FFmpeg / libheif as a sandboxed fallback only where the native frameworks fall short. Full rationale in the PRD's Tech Stack section.

The app runs in the macOS App Sandbox with **no network entitlement at all**. "Nothing is uploaded" isn't a promise in the README — the operating system denies it, and you can confirm that in [`App/iShrink.entitlements`](App/iShrink.entitlements).

## For maintainers

Releases are cut by pushing a version tag. GitHub Actions builds the app, verifies it, and publishes a zip plus its SHA-256; the cask is then updated with those two values.

**One thing to know before adding Developer ID signing later.** Switching from the current ad-hoc signature to a real Developer ID certificate *under the same bundle identifier* can leave macOS's privacy database treating Photos permission as never granted — and confusingly, it isn't fixed by reinstalling, because that state survives uninstall. The remedy is to reset the app's Photos permission explicitly:

```
tccutil reset Photos com.ishrink.app
```

This is written down now, while the reason is understood, so it costs one command later rather than a debugging session.

## Contributing

Not yet open for outside contributions. The requirements are settled and Phase 1 is implemented; the plans in [`docs/plans/`](docs/plans/) describe what's built and what's next.

## License

Not yet chosen.
