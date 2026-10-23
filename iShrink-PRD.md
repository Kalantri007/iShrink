# iShrink v2 — PRD

**Status:** Draft · **Date:** 2026-10-23 · **Replaces:** v1 (branch `main`, release v0.1.0)

---

## In one sentence

Shrink the photos and videos in an iPhone's Photos library to WhatsApp-like sizes (for example 15–20 MB down to 200–300 KB) while keeping each one in its right place, with the same date, location, and albums, so Photos keeps building its Memories and slideshows. And do it **completely free**.

## Who it's for

A person who has:

- an **iPhone**, with their photos and videos on it
- a **MacBook**
- a **free Apple ID**, with **no paid iCloud+ subscription**

Their photos live **on the iPhone itself**, not in iCloud. The free 5 GB of iCloud is far too small for a photo library, so assume **iCloud Photos is off**.

## The free-only rule

**No step may need money.** That includes:

- no iCloud+ subscription
- no paid app, tool, or service
- no paid Apple Developer membership for the user

Every way of moving, backing up, or installing must work with a free Apple ID, a cable or AirDrop, and the MacBook.

| Need | Free way to do it |
|---|---|
| Install the app on the iPhone | Build on the Mac with xtool and a free Apple ID, or use AltStore/SideStore |
| Move photos between iPhone and Mac | USB cable (Image Capture, Photos import) or AirDrop |
| Back up originals before replacing | Copy them to the Mac, or to an external drive, over the cable |
| Undo | Photos' **Recently Deleted** album keeps originals for 30 days, on the device |

## Why a second version

- **v1 compressed almost nothing on a modern iPhone library.** It skipped HEIC photos, Live Photos, and videos, which is most of what an iPhone shoots.
- **v1 never put anything back into the library.** It only wrote copies to a folder on the Mac.
- **v1 wrote everything itself on top of Apple's built-in engine.** v2 builds on proven open-source code instead of redoing work a large community has already done.

## Goals

1. **Big savings.** Shrink the picture size and recompress it hard, like WhatsApp does. The user picks how strong.
2. **The photo stays in its place.** The small version replaces the original **in the iPhone's Photos library**, with the same capture date and time, location, favorite status, and albums.
3. **Memories keep working.** The iPhone keeps creating its automatic slideshows and short videos from the replaced photos.
4. **Completely free.** See the free-only rule above.
5. **Reuse community code first.** Write our own code only to connect the pieces.
6. **No Xcode hassle for the developer.** Use command-line builds (scripts, xtool).

## Not in scope (for now)

- Libraries that rely on iCloud Photos, especially "Optimize iPhone Storage", where the full originals live in iCloud
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

The iPhone builds Memories on the device from **date, location, people, and scenes**. Date and location are therefore must-haves. People are the biggest risk.

| What | Why it matters | Can we keep it? |
|---|---|---|
| Capture date, time, timezone | Timeline order, Memories | Yes |
| GPS location | Places map, Memories | Yes |
| Camera and lens details (EXIF) | Info panel | Yes for common fields. Rare lens data is best-effort. |
| Favorite, Hidden | User's choices | Yes |
| Albums | Organisation | Yes, by re-adding the new photo to the same albums |
| Title, caption, keywords | Search | To verify |
| People and face names | Memories, People album | **Risky.** There's no public API to set them, so Photos would have to re-recognise faces in the new photo. To verify. |
| Live Photo (photo plus its 3-second video) | Motion, Memories | Only if both parts are rebuilt together. To verify. |
| Edit history | Being able to undo edits | Lost. Save the edited version instead. |

---

## Safety rules

- Show a preview and a size estimate first. Nothing changes until the user confirms.
- **Back up the originals to the Mac (or an external drive) first.** That's the free replacement for an iCloud backup.
- Before removing the original, check that the new file opens and its metadata matches.
- Originals go to **Recently Deleted** for 30 days, which Photos does on its own. That's the undo button.
- **Storage frees up only after Recently Deleted is emptied**, either automatically after 30 days or by hand. The UI must say so, or users will think nothing happened.
- Nothing is ever uploaded.

---

## Big decision #1: where does the app run?

Without iCloud, **a Mac app cannot put photos back into the iPhone's library**. Nothing syncs them back. That changes the picture:

| Option | Good | Hard |
|---|---|---|
| **iPhone app** (built and installed from the Mac with xtool) | Works right where the photos and Memories live, and replaces them in place. Needs no iCloud at all. The MacBook is used to install the app and hold the backup. | A free Apple ID signs the app for only **7 days**, after which it must be reinstalled from the Mac (AltStore or SideStore can do this automatically). Xcode must be installed for its iPhone SDK, though you never open it. ExifTool and osxphotos can't run on an iPhone. ffmpeg-kit is archived. |
| **Mac app** (like v1) | ExifTool, osxphotos, libvips, and FFmpeg all run easily. The Homebrew release pipeline already exists. | Photos have to be copied to the Mac, and the small versions **can't go back into the iPhone's library** without iCloud. That breaks goals 2 and 3. |
| **Both** | The iPhone app replaces photos; the Mac adds the backup and any heavy tools. | More work. |

**Leaning: iPhone app, with the MacBook as its helper** for installing and backups. This is still to be confirmed by the M0 spike.

---

## Open-source code to reuse

### Building blocks: real code we can plug in

| Project | Link | Licence | What it gives us | Runs on iPhone? |
|---|---|---|---|---|
| libvips | https://github.com/libvips/libvips | LGPL-2.1 | Very fast, low-memory resizing | C library. Can be compiled for iPhone; effort to verify. |
| libheif | https://github.com/strukturag/libheif | LGPL-3.0 | HEIC and AVIF encoding | Can be compiled; the iPhone also has HEIC built in |
| mozjpeg *(new)* | https://github.com/mozilla/mozjpeg | BSD-style | Smaller JPEGs at the same quality | Can be compiled |
| jpegli *(new)* | https://github.com/google/jpegli | BSD-3-Clause | A newer JPEG encoder, even smaller files | Can be compiled |
| FFmpeg | https://github.com/FFmpeg/FFmpeg | LGPL/GPL | Compressing videos and Live Photo videos | Hard, because ffmpeg-kit is archived. Apple's built-in video encoder is the free fallback. |
| ffmpeg-kit | https://github.com/arthenica/ffmpeg-kit | LGPL-3.0 | FFmpeg inside an iPhone app | **Archived**, so it's a risk |
| ExifTool | https://github.com/exiftool/exiftool | GPL-3.0 | Copies **all** metadata from the original to the new file | No, it's a Perl program. Mac only: useful for checking backups. |
| osxphotos *(new)* | https://github.com/RhetTbull/osxphotos | MIT | Reads a Photos library and imports photos with date, location, and albums | No, it's Python and Mac only |
| ImageMagick | https://github.com/ImageMagick/ImageMagick | ImageMagick licence | General format conversion | Likely not needed if we use libvips |
| xtool | https://github.com/xtool-org/xtool | MIT | Builds and installs iPhone apps from the Mac with a free Apple ID, without using the Xcode app | Runs on the Mac (it's a dev tool) |
| AltStore *(new)* | https://github.com/altstoreio/AltStore | AGPL-3.0 | Free sideloading. Re-signs the app before the 7-day limit. | Yes, as a helper app |
| SideStore *(new)* | https://github.com/SideStore/SideStore | AGPL-3.0 | Like AltStore, but refreshes without the Mac | Yes, as a helper app |

### Learn from: whole apps (ideas, not drop-in code)

| Project | Link | Licence | What to learn |
|---|---|---|---|
| CompressO | https://github.com/codeforreal1/compressO | AGPL-3.0 | Compression presets and UX. Its engine is FFmpeg, which we would use directly. |
| Immich | https://github.com/immich-app/immich | AGPL-3.0 | Background jobs, metadata handling, iPhone backup flow |
| PhotoPrism | https://github.com/photoprism/photoprism | AGPL-3.0 | Indexing, metadata model |
| LibrePhotos | https://github.com/LibrePhotos/librephotos | MIT | Organisation ideas |
| digiKam | https://github.com/KDE/digikam | GPL-2.0 | Metadata editing workflows. The GitHub copy is archived; the live code is at https://invent.kde.org/graphics/digikam |
| darktable | https://github.com/darktable-org/darktable | GPL-3.0 | Fast image pipeline (RAW is out of scope) |
| ExifCleaner | https://github.com/szTheory/exifcleaner | MIT | UI ideas only. It **removes** metadata, which is the opposite of our goal. |

**Licence warning:** copying AGPL or GPL code *into* the app makes the whole app AGPL or GPL. Running a GPL tool such as ExifTool as a separate program is generally fine. AltStore and SideStore are separate apps, so using them doesn't affect iShrink's licence. Choose iShrink's licence (MIT or GPL) **before** copying any code.

---

## Milestones

- **M0, spike (1–2 days).** Use 10 real photos on an iPhone with iCloud Photos off.
  1. Back them up to the Mac over the cable.
  2. On the iPhone, shrink them to WhatsApp size and put them back into Photos.
  3. Check:
     - correct day in the timeline
     - correct pin on the map
     - same albums
     - faces recognised again
     - Live Photo still moves
     - **no step needed a paid account**
- **M1.** Preview and size estimate, back up, then compress-and-replace a batch the user picks.
- **M2.** Live Photos and videos.
- **M3.** Polish, plus a free install path for non-developers.

## Open questions

1. **Confirm the platform after M0:** iPhone app (leaning), Mac app, or both.
2. **How do other people install it for free?** Options:
   - each person builds it themselves with xtool
   - share an app file that they install through AltStore or SideStore
   - the App Store, which is free for users but costs the *developer* $99 a year

   Is that developer cost acceptable?
3. Which licence, MIT or GPL? This decides what code we're allowed to copy.
4. Which preset is the default?
5. Is it acceptable if face names have to be re-tagged?
6. How do we handle someone who *does* have iCloud Photos on? Detect it and warn, or block?

## Success means

The 10-photo spike gets **at least 90% smaller files**, each photo looks clear on a phone, and every one shows up on the right day, at the right place, in the right albums, **on the iPhone, with no paid step anywhere**.
