# iShrink v2 — PRD

**Status:** Draft · **Date:** 2026-10-23 · **Replaces:** v1 (branch `main`, release v0.1.0)

---

## In one sentence

Shrink the photos in an Apple Photos library to WhatsApp-like sizes (for example 15–20 MB down to 200–300 KB) while keeping each photo in its right place, with the same date, location, and albums, so Photos keeps building its Memories and slideshows from them.

## Why a second version

- **v1 compressed almost nothing on a modern iPhone library.** It skipped HEIC photos, Live Photos, and videos, which is most of what an iPhone shoots.
- **v1 never put anything back into the library.** It only wrote copies to a folder.
- **v1 wrote everything itself on top of Apple's built-in engine.** v2 builds on proven open-source code instead of redoing work a large community has already done.

## Goals

1. **Big savings.** Shrink the picture size and recompress it hard, like WhatsApp does. The user picks how strong.
2. **The photo stays in its place.** The small version replaces the original in Photos with the same capture date and time, location, favorite status, and albums.
3. **Memories keep working.** Photos keeps creating its automatic slideshows and short videos from the replaced photos.
4. **Reuse community code first.** Write our own code only to connect the pieces.
5. **No Xcode hassle for the developer.** Use command-line builds (scripts, xtool).

## Not in scope (for now)

- RAW photo editing
- Running a media server, or uploading anything to a cloud
- Android or Windows

---

## How "small but still clear" works

WhatsApp's normal mode (approximate, to verify): it shrinks the long side of the photo to about 1600 px, then re-saves it as a JPEG at roughly 70–80% quality. The result is about 100–300 KB.

Newer formats look better at the same size: **HEIC/AVIF** (libheif), or for JPEG, **mozjpeg/jpegli**.

| Preset | Long side | Rough size per photo | Good for |
|---|---|---|---|
| Keep size | unchanged | 30–60% smaller | Zooming in and printing |
| Balanced | about 4000 px | about 1–2 MB | Big screens |
| WhatsApp-like | about 1600 px | about 200–400 KB | Phone viewing only |

These sizes are guesses. Measure them in the M0 spike.

**The trade-off:** a 48-megapixel photo shrunk to 1600 px keeps about 5% of its pixels. It looks sharp on a phone, but it cannot be zoomed or printed large later. The UI must say this plainly before anything happens.

---

## Metadata that must survive

Photos builds Memories on the device from **date, location, people, and scenes**. Date and location are therefore must-haves. People are the biggest risk.

| What | Why it matters | Can we keep it? |
|---|---|---|
| Capture date, time, timezone | Timeline order, Memories | Yes |
| GPS location | Places map, Memories | Yes |
| Camera and lens details (EXIF) | Info panel | Yes, using ExifTool |
| Favorite, Hidden | User's choices | Yes |
| Albums | Organisation | Yes, by re-adding the new photo to the same albums |
| Title, caption, keywords | Search | To verify |
| People and face names | Memories, People album | **Risky.** There's no public API to set them, so Photos would have to re-recognise faces in the new photo. To verify. |
| Live Photo (photo plus its 3-second video) | Motion, Memories | Only if both parts are rebuilt together. To verify. |
| Edit history | Being able to undo edits | Lost. Save the edited version instead. |

---

## Safety rules

- Show a preview and a size estimate first. Nothing changes until the user confirms.
- Before removing the original, check that the new file opens and its metadata matches.
- Originals go to **Recently Deleted** for 30 days, which Photos does on its own. That's the undo button.
- Optionally back up the originals to an external drive first.
- Nothing is ever uploaded.

---

## Big decision #1: where does the app run?

| Option | Good | Hard |
|---|---|---|
| **iPhone app** (built with xtool) | The photos and Memories already live there. No Mac needed for end users. | With a free Apple ID, the app stops working after 7 days and must be reinstalled. Xcode must be installed for its iPhone SDK, though you never open it. The common iPhone FFmpeg wrapper (ffmpeg-kit) is archived. ExifTool and osxphotos can't run on an iPhone. |
| **Mac app** (like v1) | ExifTool, osxphotos, libvips, and FFmpeg all run easily. The Homebrew release pipeline already exists. | Changes only reach the iPhone if **iCloud Photos** is turned on. |
| **Both** | The Mac does the heavy work and the iPhone gets the results through iCloud. | Twice the work. |

**Not decided yet.** We'll choose after the M0 spike. Mac currently looks easier, because most of the reusable code runs only, or most easily, on a Mac.

---

## Open-source code to reuse

### Building blocks: real code we can plug in

| Project | Link | Licence | What it gives us |
|---|---|---|---|
| libvips | https://github.com/libvips/libvips | LGPL-2.1 | Very fast, low-memory resizing |
| libheif | https://github.com/strukturag/libheif | LGPL-3.0 | HEIC and AVIF encoding |
| mozjpeg *(new)* | https://github.com/mozilla/mozjpeg | BSD-style | Smaller JPEGs at the same quality |
| jpegli *(new)* | https://github.com/google/jpegli | BSD-3-Clause | A newer JPEG encoder, even smaller files |
| FFmpeg | https://github.com/FFmpeg/FFmpeg | LGPL/GPL | Compressing videos and Live Photo videos |
| ExifTool | https://github.com/exiftool/exiftool | GPL-3.0 | Copies **all** metadata from the original to the new file. Runs as a separate tool, Mac only. |
| osxphotos *(new)* | https://github.com/RhetTbull/osxphotos | MIT | Reads the Photos library and imports photos back with date, location, albums, and keywords. Mac only. |
| ImageMagick | https://github.com/ImageMagick/ImageMagick | ImageMagick licence | General format conversion. Likely not needed if we use libvips. |
| xtool | https://github.com/xtool-org/xtool | MIT | Builds and installs iPhone apps without using the Xcode app |
| ffmpeg-kit | https://github.com/arthenica/ffmpeg-kit | LGPL-3.0 | FFmpeg inside an iPhone app. **Archived**, so it's a risk. |

### Learn from: whole apps (ideas, not drop-in code)

| Project | Link | Licence | What to learn |
|---|---|---|---|
| CompressO | https://github.com/codeforreal1/compressO | AGPL-3.0 | Compression presets and UX. Its engine is FFmpeg, which we would use directly. |
| Immich | https://github.com/immich-app/immich | AGPL-3.0 | Background jobs, metadata handling |
| PhotoPrism | https://github.com/photoprism/photoprism | AGPL-3.0 | Indexing, metadata model |
| LibrePhotos | https://github.com/LibrePhotos/librephotos | MIT | Organisation ideas |
| digiKam | https://github.com/KDE/digikam | GPL-2.0 | Metadata editing workflows. The GitHub copy is archived; the live code is at https://invent.kde.org/graphics/digikam |
| darktable | https://github.com/darktable-org/darktable | GPL-3.0 | Fast image pipeline (RAW is out of scope) |
| ExifCleaner | https://github.com/szTheory/exifcleaner | MIT | UI ideas only. It **removes** metadata, which is the opposite of our goal. |

**Licence warning:** copying AGPL or GPL code *into* the app makes the whole app AGPL or GPL. Running a GPL tool such as ExifTool as a separate program is generally fine. Choose iShrink's licence (MIT or GPL) **before** copying any code.

---

## Milestones

- **M0, spike (1–2 days).** Take 10 real iPhone photos. Shrink them to WhatsApp size with libvips and libheif, copy their metadata with ExifTool, and put them back into Photos. Then check:
  - correct day in the timeline
  - correct pin on the map
  - same albums
  - faces recognised again
  - Live Photo still moves
- **M1.** Preview and size estimate, then compress-and-replace a batch the user picks.
- **M2.** Live Photos and videos, using FFmpeg.
- **M3.** Polish and release through Homebrew.

## Open questions

1. Where does the app run: iPhone, Mac, or both?
2. Do the target libraries use iCloud Photos?
3. Which licence, MIT or GPL? This decides what code we're allowed to copy.
4. Which preset is the default?
5. Is it acceptable if face names have to be re-tagged?

## Success means

The 10-photo spike gets **at least 90% smaller files**, each photo looks clear on a phone, and every one shows up on the right day, at the right place, in the right albums.
