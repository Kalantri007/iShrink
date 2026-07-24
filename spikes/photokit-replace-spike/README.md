# PhotoKit replace-workflow spike

Answers PRD Resolved Decision #1 / Open follow-up: when iShrink does
**create-new-asset → delete-old-asset** (the only way PhotoKit lets an app
reclaim space — there is no in-place original replacement), which of these
survive onto the new asset?

- Creation date
- Location
- Favorite status
- Album membership
- Live Photo pairing (optional check, see below)

## Safety — what this touches

- **Creates and deletes only its own synthetic test data.** It generates a
  plain teal test image, adds it as a new photo with known metadata, puts it
  in a throwaway album named `iShrink Spike Test <timestamp>`, runs the
  replace workflow against *that*, checks what survived, then deletes both
  the test asset and the test album it made.
- **Never touches your real photos** — with one opt-in exception:
- The **Live Photo pairing check** is off by default. If you pass
  `--live-photo-id=<id>` for an existing Live Photo, it *reads* that asset's
  resources and creates its **own duplicate** to test pairing — it never
  modifies or deletes the Live Photo you point it at. Only the duplicate is
  deleted at the end.
- Everything this script deletes goes through the normal system
  **Recently Deleted** (30-day recoverable window) — same as the real app.

## Setup

You need Xcode's command-line tools installed (`xcode-select --install` if
you haven't already).

```bash
cd spikes/photokit-replace-spike
swift build
```

If `swift build` succeeds, run it:

```bash
swift run
```

**The first run will pop a system permission dialog** ("PhotoKitReplaceSpike
wants access to your Photos") — click **Allow Full Access**. This is required
because the spike needs to create/read/delete assets; there's no way around
the interactive prompt, and no way for an AI agent to click through it for
you.

### If the permission prompt never appears (SPM quirk)

Command-line Swift Package executables don't always get proper Info.plist /
TCC attribution. If `swift run` exits immediately with "Photos access not
granted" and you never saw a prompt, do this instead:

1. Open Xcode → **File > New > Project > macOS > Command Line Tool**.
2. Name it anything (e.g. `PhotoKitReplaceSpike`).
3. Replace the generated `main.swift` with the contents of
   `Sources/PhotoKitReplaceSpike/main.swift` from this folder.
4. In the target's **Info** tab, add two keys:
   - `Privacy - Photo Library Usage Description`
   - `Privacy - Photo Library Additions Usage Description`
   (use the same description text as `Sources/PhotoKitReplaceSpike/Info.plist`
   in this folder).
5. Run from Xcode (⌘R) — the permission dialog should appear normally.

## Interpreting the output

The script prints a `✅ PASS` / `❌ FAIL` line for each check, then a summary.
Expected outcome, based on how PhotoKit's `PHAssetCreationRequest` and
`PHAssetChangeRequest` work:

| Check | Expected | Why |
|---|---|---|
| creationDate survives | ✅ | Explicitly copied onto the new asset's creation request |
| location survives | ✅ | Explicitly copied onto the new asset's creation request |
| isFavorite survives | ✅ | Explicitly copied onto the new asset's creation request |
| album membership survives | ✅ | New asset explicitly re-added to the same album |
| Live Photo pairing survives | ✅ (if tested) | Both `.photo` and `.pairedVideo` resources added together |

If any of these come back ❌, that's exactly the kind of finding that should
update PRD Resolved Decision #1 — it means the substitution model needs an
extra explicit step (or a documented limitation) to carry that field forward.

**Known limitation this spike does NOT test:** Faces/People tagging and
Memories history. PhotoKit has no public API to read or write these at all,
so no code can carry them forward — this is a documented, accepted loss (see
Metadata Preservation section of the PRD), not something this spike needs to
verify empirically.

## After running

Please share the printed PASS/FAIL summary back so it can be recorded in the
PRD's "Open follow-ups" section (turning the spike from "planned" to
"validated" or noting what needs to change).
