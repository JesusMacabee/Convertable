# Convertable

A macOS menu bar app that keeps an AAC copy of a lossless music library up to date and adds it to an Apple Music library, so an iPod Classic (or anything else that can't play FLAC) always has the whole collection.

You keep ripping and tagging into your lossless folder. Convertable notices new albums, converts them with Apple's own encoder, carries the tags and cover art across, checks the result, and adds it to Music. When you retag something, it retags the copy. When you delete something, it asks before it touches anything.

```
NAS/Music/Lossless/<Artist>/<Album>/<track>.flac         you rip and tag here (Picard, PlexAmp, whatever)
        |   scan, settle, copy local, afconvert, tag, verify, publish
        v
NAS/Music/AAC Music/Lossless Mirror/<Artist>/<Album (Year)>/<NN Title>.m4a
        |   AppleScript "add", only when the right Music library is open
        v
Apple Music library  ->  iPod Classic
```

## About this project

I didn't write any of this code. Claude, Anthropic's AI model, wrote all of it through Claude Code: the Swift, the tests, the build scripts, the dashboard, and the documentation, including this file. My part was describing what I wanted, making the design decisions, running it against my own library, and reporting what broke. The commit history shows the same thing: every commit carries a co-author line for the model.

I'm saying this up front because it changes how you should treat the code:

- It has been tested on exactly one library (mine: about 21,000 tracks on a Synology NAS over SMB, one Mac mini, one iPod). It works well there. Your setup will differ.
- No human has reviewed the code line by line. I've read parts of it, and the design log explains every decision, but if you plan to point this at a library you care about, read the pipeline and review code first.
- It is a personal tool, not a product. There are no signed builds or releases. You build it from source.

What it does to protect your files: it never writes into your lossless folder, it never deletes anything without you approving it in the Review tab, and anything it does remove goes to a dated quarantine folder for 30 days first. The whole pipeline writes to a local temp folder and only publishes a file after it has been verified.

If you find a bug, open an issue. The fix will almost certainly be written the same way the rest was.

## What it does

- **Watches a folder tree**, local or on a mounted share. Over SMB, AFP, or NFS it reads the protocol from the mount table to decide how hard to push the share; a folder on a local disk just runs faster. There's a full scan every night, an incremental scan every ten minutes, and both resume if a share drops. Nothing is marked missing while a volume is unmounted.
- **Converts with afconvert** to 256 kbps constrained-VBR AAC at 44.1 kHz, the iTunes Plus profile, with gapless info and Sound Check. Lossy files that ended up in the lossless tree are copied as they are, never re-encoded. Output formats are profiles, so ALAC, MP3 (via lame) and FLAC (via flac) exist too.
- **Carries the metadata.** afconvert writes no tags, so TagLib copies every tag into the MP4, MusicBrainz IDs included, and embeds one cover downscaled to 600 px. A verifier checks duration, sample rate, the key tags, and the artwork before a file is published.
- **Wants MusicBrainz tags first.** An album is only converted once every track has MusicBrainz IDs. Albums that don't are listed under Needs tagging, so you run Picard once up front instead of fixing the copy later. Folder and file names come from the tags.
- **Converts in batches you choose.** By size budget (25, 50, 100, 250 GB, or your own number) or by picking artists and albums from a list. Albums are never split across batches. Albums that are already done grey out, and any album can be ignored with one click.
- **Handles changes.** Audio hashes tell the app what happened. Tags changed: rewrite the tags in place and tell Music to refresh. File moved: move the copy and re-point Music. Audio changed: re-encode.
- **Asks before deleting.** A source album that disappears becomes a proposal. Approve it and the copy goes to quarantine, never straight to the trash. Music entries whose files are gone are found and removed the same way.
- **Can replace an older AAC collection.** If you already have a folder of downloaded AACs, Convertable indexes it and proposes replacing the albums the new copy now covers. The old files go to quarantine and play counts carry over.
- **Talks to Music carefully.** Tracks are added by reference through AppleScript, and only when the configured library is the one Music has open, so a second library on the same Mac is never touched.
- **Three ways in.** A menu bar item for status and quick actions, a web dashboard served by the app (token-protected, works from your phone on the LAN), and a `convertctl` command line for diagnostics and scripting.

## Requirements

- macOS 14 or later. It's built and run on macOS 27 with Xcode 27 and Swift 6.4, in Swift 6 language mode.
- Xcode, to build. The Command Line Tools alone don't include XCTest. Accept the license once with `sudo xcodebuild -license accept`.
- Homebrew, for `taglib` and `pkgconf`, plus `lame` and `flac` if you want the non-AAC profiles:
  ```bash
  Scripts/install-deps.sh
  ```
  The TagLib libraries get bundled into the app. Homebrew builds them for the macOS you're on, so the app you build runs on that version or newer.
- Automation permission for Music. macOS asks the first time.

## Build and install

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Scripts/build-app.sh --install
```

That builds `Convertable.app`, bundles TagLib, installs it to `/Applications`, and launches it. On first launch the menu bar icon opens the dashboard's setup wizard, which walks through source folder, mirror folder, Music library, batch budget, and encoder profile. Settings live in `~/Library/Application Support/Convertable/settings.json`, with the state database next to it.

To run the tests:

```bash
Scripts/test.sh
```

The app icon and the dashboard favicon both come from `Assets/AppIcon.png`. If you change it, run `Scripts/make-icons.sh`.

## Day to day

1. Rip or download into the lossless tree and tag with Picard.
2. The next scan reads the tags. Tagged albums join the backlog; untagged ones show under Needs tagging. New folders and files show up within ten minutes. Retags inside existing files are picked up by the nightly full scan, or right away with the Full scan button.
3. Click Start next batch, or pick artists on the Convert tab, preview, and start. Progress shows in the menu bar and the dashboard.
4. Finished albums are added to Music automatically when the right library is open.
5. Check the Review tab now and then. Approve or close proposals one at a time or all at once.

`convertctl doctor` checks the mount, paths, tools, Music library, database, and share latency. The other subcommands cover planning, status, tag audits, Music, and the review queue.

## Layout

```
Sources/ConvertableCore   scanning, state (SQLite), planning, pipeline, tags, Music bridge, review, controller
Sources/ConvertableWeb    Hummingbird server and the single-file dashboard (Dashboard/index.html)
Sources/ConvertableApp    menu bar app (NSStatusItem, notifications, launch at login)
Sources/convertctl        command line
Sources/CTagLib           TagLib C bindings
Tests/                    104 unit and integration tests, run against real audio and the real encoder
docs/DESIGN.md            the design and build log: every decision, what was measured, what went wrong
```

Swift Package Manager only, no Xcode project. [docs/DESIGN.md](docs/DESIGN.md) has the reasoning behind each decision and the measurements that drove them, like SMB turning out 20 times faster than AFP for this workload, and the macOS 27 FLAC decoder bug that silently produced empty files.
