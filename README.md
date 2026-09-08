# Convertable

A macOS menu bar app that keeps an AAC mirror of a lossless music library in sync, unattended, and feeds it into an Apple Music library so an iPod Classic (or any device that can't play FLAC) always has the whole collection.

You keep ripping and tagging into your lossless folder. Convertable notices, converts new albums with Apple's own encoder, carries every tag and the cover art across, verifies the result, and adds it to Music. When you retag, it retags the mirror. When you delete, it asks before it deletes anything.

```
NAS/Music/Lossless/<Artist>/<Album>/<track>.flac         ← you rip and tag here (Picard, PlexAmp, whatever)
        │   scan → settle → copy local → afconvert → tag → verify → publish
        ▼
NAS/Music/AAC Music/Lossless Mirror/<Artist>/<Album (Year)>/<NN Title>.m4a
        │   AppleScript "add" — only when the right Music library is open
        ▼
Apple Music library  →  iPod Classic
```

## What it does

- **Watches a folder tree** on a mounted share (SMB, AFP, NFS — it reads the protocol from the mount table and tunes itself). Full scans daily, incremental scans every ten minutes, resumable if the share drops. Nothing is ever marked missing while the volume is unmounted.
- **Converts with `afconvert`** to 256 kbps constrained-VBR AAC at 44.1 kHz, the iTunes Plus profile, with gapless info and Sound Check written. Lossy sources (MP3/AAC that ended up in the lossless tree) are copied through untouched, never re-encoded. Output formats are profile-driven, so ALAC, MP3 (`lame`) and FLAC (`flac`) profiles exist too.
- **Carries all metadata.** `afconvert` writes no tags, so TagLib copies every FLAC/ALAC/WAV/MP3 tag into MP4 atoms, MusicBrainz IDs included (Picard can re-identify the mirror files), and embeds one cover downscaled to 600 px. A verifier checks duration, sample rate, key tags and artwork before a file is published.
- **MusicBrainz gate.** An album is only converted when every track carries MusicBrainz IDs. Albums that don't are listed as *Needs tagging* so you run Picard once, up front, instead of fixing the mirror later. Mirror folders and file names come from tags: `<Artist folder>/Album (Year)/NN Title.m4a`.
- **Batches you choose.** Convert by size budget (25 / 50 / 100 / 250 GB or custom) or pick artists and albums from a list; a queue drawer collects the selection. Albums are never split across a batch. Already-mirrored albums grey out; any album can be ignored with one click.
- **Change handling.** Audio hashes decide what happened: tags changed → rewrite tags in place and tell Music to refresh; file moved → move the mirror copy and re-point Music; audio changed → re-encode. A tag-policy version lets a later app version re-sync every mirror file's metadata from source.
- **Deletes need approval.** A source album that disappears becomes a proposal. Approve it and the mirror copy goes to a dated quarantine folder (purged after 30 days), never straight to the trash. Dead Music entries (files gone) are found and removed the same way.
- **Legacy library supersede.** If you already have a folder of downloaded AACs, Convertable indexes it and proposes replacing albums the mirror now covers, leaving everything else alone.
- **Music.app bridge.** Tracks are added by reference via AppleScript, only when the configured library is the one Music has open, so a second library on the same Mac is never polluted. Import, refresh, relocate, remove and dead-entry scans all go through it.
- **Three front ends over one core:** a menu bar item (status, badge, quick actions), a token-protected web dashboard served by the app (Overview, Convert, Batches, Review, Activity, Settings, first-run wizard), and a `convertctl` CLI for diagnostics and scripting.

## Requirements

- macOS 14 or later (built and run on macOS 26). Xcode is needed to build, because the Command Line Tools alone ship no XCTest.
- Homebrew `taglib`, `pkgconf`, and optionally `lame` and `flac` for the non-AAC profiles:
  ```bash
  Scripts/install-deps.sh
  ```
- Automation permission for Music.app (macOS asks the first time).

## Build and install

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Scripts/build-app.sh --install     # builds Convertable.app, bundles TagLib, installs to /Applications, launches
```

On first launch the menu bar icon opens the web dashboard's setup wizard: source folder, mirror folder, Music library, batch budget, encoder profile. Settings live in `~/Library/Application Support/Convertable/settings.json`, state in `state.sqlite` next to it.

Run the tests (with a stall watchdog) using:

```bash
Scripts/test.sh
```

## Day to day

1. Rip or download into the lossless tree and tag with Picard.
2. The next scan audits the tags. Tagged albums join the backlog; untagged ones appear under *Needs tagging*.
3. Click *Start next batch* (size mode) or pick artists on the Convert tab, preview, start. Watch progress in the menu bar or the dashboard.
4. Finished albums are added to Music automatically when the right library is open.
5. Check the Review tab now and then for removal, supersede and dead-entry proposals; approve individually or all at once.

`convertctl doctor` checks the mount, paths, tools, Music library, database and share latency. `convertctl plan`, `artists`, `status`, `audit`, `music …` and `review …` expose the rest.

## Layout

```
Sources/ConvertableCore   scanning, state (SQLite), planning, pipeline, tags, Music bridge, review, controller
Sources/ConvertableWeb    Hummingbird server + the single-file dashboard (Dashboard/index.html)
Sources/ConvertableApp    menu bar app (NSStatusItem, notifications, launch at login)
Sources/convertctl        command line
Sources/CTagLib           TagLib C bindings
Tests/                    100 unit and integration tests (real audio fixtures, real afconvert)
docs/DESIGN.md            the full design and build log, decisions and measurements included
```

Built with Swift Package Manager, no Xcode project. See [docs/DESIGN.md](docs/DESIGN.md) for the reasoning behind each decision, the failure handling, and what was measured along the way (for instance, SMB turned out 20× faster than AFP for this workload).
