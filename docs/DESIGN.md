# Convertable — Design & Build Plan

*Status: awaiting sign-off before any code. Last updated 2026-09-05.*

## 1. Purpose

Keep an AAC mirror of a lossless music library in sync, continuously and unattended, so that an Apple Music library (and the iPod Classic paired to it) always reflects what PlexAmp plays from the lossless master.

```
/Volumes/PLeX/Music/New Tunes/<Artist>/<Album>/<track>.flac      (source, PlexAmp; folder renamed from "Lossless Music" on 2026-09-05)
        │  scan → settle → copy local → afconvert → tag → verify → move
        ▼
/Volumes/PLeX/Music/AAC Music/Lossless Mirror/<Artist>/<Album>/<track>.m4a
        │  AppleScript add (only when the NAS library is the open one)
        ▼
Apple Music library  "AAC Music/Music Library.musiclibrary"  →  iPod Classic (1 TB)
```

## 2. Decisions already made

| Topic | Decision |
|---|---|
| Name | **Convertable** |
| Host | Native macOS app on this Mac (macOS 26, Command Line Tools only, no Xcode) |
| Encoder | Apple `afconvert`, `-f m4af -d aac@44100 -b 256000 -s 2 -q 127 --soundcheck-generate` → ≈262 kbps constrained VBR (iTunes Plus profile), Sound Check, `iTunSMPB` gapless atom. Default resampler. |
| Sample rate | Everything resampled to 44.1 kHz (iPod Classic max is 48 kHz; 44.1 chosen for consistency) |
| Lossy sources (MP3, AAC already in the lossless tree) | **Copy-through**: never re-encode lossy→lossy. Copied unchanged, then tags normalized and art downscaled like every other output. |
| Tags | Full carry-over FLAC/ALAC/WAV/MP3 → MP4 atoms via TagLib, including MusicBrainz IDs. `afconvert` writes no tags itself. |
| Artwork | Embedded art only (no cover.jpg). Downscaled to ≤ 600 px JPEG (~85 quality). |
| Non-audio files | `.jpg .nfo .m3u .sfv .log .cue .txt` etc. ignored entirely |
| UI | **Menu bar app** (status, badge, quick actions) **+ web dashboard** (full UI, served by the app on the LAN, token-protected). A thin CLI (`convertctl`) shares the same core for diagnostics. |
| What gets converted, and when | User chooses per batch: **by size budget** (25 / 50 / 100 / 250 GB / custom / unlimited), **by artist** (pick from a list with sizes), **by album**, or **everything**. Pinned artists always go first. Details in §7. |
| Deletes | Mirror follows source deletions **but** every removal goes to an approval queue. Approved removals go to a dated quarantine folder, purged after 30 days. Nothing is hard-deleted unprompted. |
| Retags | If the audio is unchanged but tags changed → rewrite MP4 tags in place (no re-encode), then tell Music.app to refresh the track. |
| Legacy AAC library (12,377 × 320k downloads) | **Supersede overlaps, keep the rest.** When a mirror album completes and matches a legacy album, propose removing the legacy copies (approval queue). Artists that exist only in the legacy library are never touched. |
| Music.app | **Import method** setting: *Reference in place via AppleScript* (default) or *Hand off to the "Automatically Add to Music" folder*. Both gated: only when the open library is the NAS one. Otherwise queue + notify. Music never watches its media folder, so a file must be imported one of these two ways to appear at all. |
| Share / protocol | **Protocol-agnostic.** The app works on a mounted path and reads the protocol (`afpfs`, `smbfs`, `nfs`) from the mount table only to tune concurrency. Setting accepts a mounted path or a server URL (`smb://`, `afp://`, `nfs://`) that the app can mount on demand with Keychain credentials. |
| Volume | If the share is not mounted → hard gate (optionally: try to mount it). Notify once; do nothing until it returns. A missing volume is never interpreted as deleted files. |
| Formats | **Profile-driven.** Ordered rules *input → action* (transcode with a given encoder/settings, copy-through, skip). Encoders: `afconvert` for AAC / ALAC / PCM (built in), `lame` for MP3 and `flac` for FLAC (Homebrew, detected at runtime), others pluggable. Default profile = "iPod Classic: AAC 256 CVBR 44.1, lossy copy-through". |
| Initial conversion | Not started by hand — the app does it, batch by batch, under the user's selection. |

## 3. Facts learned from probing the environment

These shaped the design and are not obvious from the request:

1. **The share was mounted over AFP when first probed and is now SMB** (`smbfs`, `//192.168.0.96/PLeX`). The app must not assume either; it reads the type from the mount table.
2. **The macOS AFP client collapses under concurrency; the SMB client does not.** Over AFP, 24 parallel reads made every operation on the mount take seconds (even `ls` on the root); killing the load restored 28 ms opens instantly. Over SMB (same NAS, same files), 4 parallel readers *improved* throughput (17 ms/file effective vs 36 ms serial) with no after-effects. → All share I/O funnels through one actor whose in-flight limit is **protocol-aware and adaptive** (AFP starts at 1, SMB/NFS at 4; halves when latency spikes, creeps back when it settles). CPU parallelism happens on local temp files only.
3. **First access to a file is slow over AFP (~0.8 s cold, 28 ms warm) and fast over SMB (36 ms cold, 7 ms warm, 4 ms stat, 8 ms root listing).** The AFP cost is server-side (netatalk per-file catalog lookups); Samba has none of it. **SMB is the recommended protocol** and the share is now mounted that way (`//192.168.0.96/PLeX`, `smbfs`). `doctor` runs this same measurement for any user and recommends a protocol. Regardless: the scanner uses only what directory enumeration returns for free (name, size, mtime) and opens a file only when it actually has work to do on it. Scans are resumable.
4. **Encoding straight off the share is a trap**: the same 3-min track took 135 s when the link was busy vs 1.8 s from local disk. → Copy source to local temp, encode there, move result back atomically.
5. **`afconvert` produces no tags** — output has only its own `iTunSMPB`/`iTunNORM` freeform atoms. A dedicated tagging stage is mandatory, and it must preserve those two atoms.
6. **FLAC headers carry an MD5 of the decoded PCM** (STREAMINFO). That gives a free "did the audio change or only the tags?" test with no decoding.
7. **Two Music libraries exist.** The Mac currently has the *local* library open (`~/Music/Music/`, 17,435 cloud tracks). The iPod library is `AAC Music/Music Library.musiclibrary` on the NAS (last written Feb 2025). Music exposes the open library as `library-url` in `com.apple.Music` prefs; AppleScript has no way to target a non-open library. Automation permission for Music is already granted to the terminal; the app will request its own on first run.
8. **The legacy AAC library is not derived from the lossless files.** 320 kbps CBR, `©too = LAME`, viperial.com tags. 386 of its 439 artists overlap the lossless tree; 53 are AAC-only.
9. **The lossless tree contains lossy files** (e.g. `Alabama/…/South.mp3`). Hence copy-through.
10. **Folder/file names are scene-release style** (`2 Chainz-So Help Me God-24BIT-WEBFLAC-2020-MenInFlac/01-2_chainz-lambo_wrist.flac`). Paths are mapped 1:1, never parsed. Tags (cleaned with Picard) are the source of truth for Music.app — and for the artist/album names shown in the picker.
11. **SwiftPM builds AppKit/AVFoundation/NSStatusBar binaries without Xcode** (verified). The `.app` bundle is assembled by a build script and ad-hoc signed.
12. **Library scale**: see §10 (figures being filled in from the running survey).

## 4. Architecture

SwiftPM package, five targets:

```
Convertable/
├── Package.swift
├── Sources/
│   ├── ConvertableCore/     # library: everything that isn't UI. Fully testable headless.
│   │   ├── Config/          # Settings model, defaults, validation
│   │   ├── Volume/          # mount gate, health probe
│   │   ├── Scan/            # enumerator, settle rules, diff against DB, FSEvents
│   │   ├── State/           # SQLite store (system libsqlite3, thin wrapper)
│   │   ├── Plan/            # selection modes, job planner, path mapping, batch budget
│   │   ├── Pipeline/        # copy-in, afconvert, tag, verify, move-out; copy-through
│   │   ├── Tags/            # TagLib bridge, Vorbis→MP4 mapping table, art resize (ImageIO)
│   │   ├── Music/           # AppleScript bridge, library gate, dedup, refresh, remove
│   │   ├── Review/          # orphan / rename / supersede detection → approval queue
│   │   ├── API/             # the one command/query surface used by menu bar, web, and CLI
│   │   └── ShareIO.swift    # the single serial actor for all NAS I/O
│   ├── CTagLib/             # system-library target → Homebrew taglib (libtag_c)
│   ├── ConvertableWeb/      # HTTP + JSON + SSE server (Hummingbird) and the embedded dashboard (HTML/CSS/JS, no build step)
│   ├── convertctl/          # CLI: scan | plan | run | status | approvals | doctor | reconcile
│   └── ConvertableApp/      # menu bar app (NSStatusItem + small SwiftUI popover); hosts the web server
├── Tests/ConvertableCoreTests/
├── Scripts/                 # build-app.sh (bundle + Info.plist + codesign), install-deps.sh
└── docs/DESIGN.md
```

**Dependencies**: Homebrew `taglib` (2.3) and the Hummingbird Swift package (HTTP server on SwiftNIO). Everything else is system frameworks: AppKit, SwiftUI, AVFoundation, ImageIO, UserNotifications, ServiceManagement (launch at login), CoreServices (FSEvents), libsqlite3, `afconvert`/`afinfo` from `/usr/bin`.

**One API, three faces.** `ConvertableCore/API` exposes a single set of commands (scan, select, start batch, pause, approve, …) and queries (status, artists, queue, approvals, activity, settings) plus a change stream. The menu bar popover, the web dashboard, and `convertctl` are all clients of that one surface, so a feature exists in all three the moment it exists in Core.

## 5. State database

`~/Library/Application Support/Convertable/state.sqlite` (WAL mode). Source of truth for "what has been done"; the filesystem is the source of truth for "what exists".

```
source_files  id, rel_path, artist_dir, album_dir, ext, kind(lossless|lossy), size, mtime,
              stable_since, audio_md5 (FLAC STREAMINFO or computed), tag_hash,
              tag_artist, tag_albumartist, tag_album (filled lazily when a file is first processed),
              first_seen, last_seen_scan, status(active|missing|ignored)
outputs       id, source_id, rel_path, size, encoder_profile, encoded_at,
              tags_written_at, verify_ok, music_persistent_id, music_added_at
jobs          id, type(encode|copy|retag|music_add|music_refresh|remove|supersede),
              source_id/output_id, batch_id, state(pending|running|done|failed|awaiting_approval|dismissed),
              bytes, attempts, last_error, created_at, finished_at
batches       id, selection_json (mode + artists/albums + budget), budget_bytes, bytes_in, bytes_out,
              files_done, started_at, finished_at, ended_by(budget|empty|user|error)
pins          artist_dir, pinned_at                       # always-first artists
legacy_files  id, rel_path, size, album_artist_norm, album_norm, title_norm, track_no, disc_no, duration_ms,
              music_persistent_id, indexed_at
scans         id, kind(full|incremental), started_at, finished_at, dirs_seen, files_seen, resumed_from
```

## 6. Scanner

**Gate (runs before anything else, every cycle)**
- The configured share is present in the mount table (any network filesystem type; the type is recorded and used to pick the concurrency profile), both roots exist, and a root listing succeeds within 30 s.
- If the share is configured as a server URL and is not mounted: optionally mount it via NetFS with credentials from the Keychain (off by default; the user turns it on knowingly). Mount failures are reported, not retried in a tight loop.
- Failure → state `Volume unavailable`, one notification (re-notified at most every 6 h), all jobs paused, nothing marked missing.

**Full scan** (startup, daily, or on demand)
- One `FileManager` enumeration with prefetched `fileSize`/`contentModificationDate`/`isDirectory` — that's one AFP directory read per folder, no per-file stats.
- Compare to `source_files`: new, changed (size or mtime), unchanged, missing.
- Resumable: progress checkpointed per top-level artist directory; an interrupted scan continues where it stopped.

**Incremental scan** (default every 10 min)
- Stat every known directory (~3–4k) and compare mtimes; enumerate only directories whose mtime changed (a file added/removed/renamed inside a directory bumps that directory's mtime on AFP/SMB). Roughly a minute instead of five.
- FSEvents on the source root as a bonus trigger for changes made from this Mac (network volumes don't deliver events for other clients' writes, so this is never relied on).

**Settle rules** (protects against half-copied files and half-copied albums)
- A file is *eligible* only when size and mtime are identical across two scans at least 2 minutes apart.
- An album directory is *eligible* only when nothing inside it has changed for 5 minutes. Albums are encoded and added to Music as a unit, so Music never shows a 4-track version of a 14-track album.

**Concurrency**: every read/write/rename on the share passes through `ShareIO`, a serial actor (configurable 1–2 in flight). Encoding runs on local temp with up to N parallel `afconvert` processes (default: performance-core count − 1).

## 7. Choosing what to convert — selection modes and batches

The scan gives every artist directory and album directory a size, file count, and mirror status (not started / partial / complete / up to date) without opening a single file. That powers a picker that makes each batch explicit before it starts.

**Selection modes** (a batch has exactly one; they can be combined with a budget cap):

| Mode | What you pick | What the app queues |
|---|---|---|
| **By artist** | One or more artists from a sortable list — name, albums, tracks, GB in, est. GB out, status | All not-yet-mirrored albums of those artists, in list order |
| **By album** | Expand an artist and tick individual albums | Exactly those albums |
| **By size** | A budget: 25 / 50 / 100 / 250 GB / custom / unlimited | Oldest-eligible albums first until the next whole album would exceed the budget |
| **Everything** | — | The whole backlog, oldest first |

Rules that apply to every mode:
- **Budget cap is optional and *soft* on artist/album selections.** Pick 6 artists totalling 38 GB with a 25 GB cap and the preview says so up front and offers three ways forward: **Convert all 38.2 GB** (exceed the cap for this batch), **Convert the first 4 artists (23.9 GB)** (respect it), or raise the cap. In *size* mode the budget is the definition of the batch, so "exceeding" simply means choosing a larger budget.
- **Albums are never split** across a batch boundary.
- **Pinned artists** (a star in the picker) are always queued ahead of anything else whenever new content from them appears — useful for "whatever this artist releases, I want on the iPod first."
- **Preview before commit**: every batch shows the exact album list, GB in, estimated GB out (FLAC ÷ 4, hi-res ÷ 8, lossy 1:1), and estimated time before you press Start.
- Budget is measured in **source bytes** (known up front); output estimate is shown beside it and refined as real ratios accumulate.

**Batch lifecycle**
- Start → runs until the selection is exhausted or the cap is hit → notification "Batch complete — 25.0 GB in, 6.1 GB out, 412 tracks. 187 GB remaining in backlog."
- **Start next batch** repeats the last selection mode (size) or returns you to the picker (artist/album).
- `auto_continue` off (default) / on / on-with-schedule-window (e.g. only 01:00–07:00) — applies to size mode and "everything".
- **Steady state** after the backlog: new content is processed as it settles, pinned artists first; a size cap still applies if a giant drop arrives.
- **Pause** at any time; the current track finishes, nothing is left half-done.

Artist names in the picker come from the folder name until the first file of that artist has been processed, then from the tag (`ALBUMARTIST`), so scene-style folder names don't leak into the UI for long.

## 8. Pipeline

### 8.1 Profiles — what happens to which input

A **profile** is an ordered list of rules; the first matching rule wins:

```
rule = match { extensions | lossless/lossy | sample-rate > N | channels > 2 | path glob }
       → action { transcode(encoder, settings) | copy-through | skip }
```

Encoder backends, each a small adapter with the same interface (encode(localIn, localOut), capabilities, version):

| Encoder | Outputs | Source | Notes |
|---|---|---|---|
| `afconvert` | AAC (CBR/ABR/CVBR/true VBR, any rate), ALAC, PCM WAV/AIFF | built into macOS | writes `iTunSMPB` gapless + Sound Check |
| `lame` | MP3 (CBR/VBR presets) | Homebrew | writes LAME gapless header |
| `flac` | FLAC (compression level) | Homebrew | lossless→lossless (e.g. WAV → FLAC) |
| `opusenc` / `oggenc` | Opus / Vorbis | Homebrew, optional | pluggable, same adapter shape |
| `ffmpeg` | *decoder only* for exotic inputs (APE, WavPack, DSD → WAV) | Homebrew, optional | feeds any encoder above |

Backends are detected at startup (`which` + version); rules that need a missing backend are flagged in Settings and `doctor` rather than failing mid-batch. Output extension, tag container (MP4 / ID3v2 / FLAC / Ogg — all via TagLib) and the verify step follow from the encoder.

**Built-in presets** (editable, copyable): *iPod Classic* — lossless → AAC 256 CVBR 44.1 kHz, lossy → copy-through (the default and the one this project exists for); *Apple Lossless* — everything → ALAC; *MP3 320* — everything → MP3 320 CBR; *Archive to FLAC* — WAV/AIFF/ALAC → FLAC -8, FLAC → copy-through, lossy → copy-through. Users can define their own.

The path mapping, settle rules, batches, Music bridge and review queue are profile-independent.

### 8.2 Stages

Per file whose rule says *transcode* (each stage idempotent; a crash mid-way is cleaned up on next start):

1. **Copy in** — source → `~/Library/Caches/Convertable/work/<job>/src.<ext>` via `ShareIO`; verify byte count.
2. **Read tags + art** — TagLib on the local copy. Compute `audio_md5` (from FLAC STREAMINFO; for ALAC/WAV/AIFF, hash of decoded PCM via `AVAudioFile`). Compute `tag_hash` over the normalized tag set.
3. **Encode** — the rule's backend. For the default preset: `afconvert -f m4af -d aac@44100 -b 256000 -s 2 -q 127 --soundcheck-generate src out.m4a`. Sources with > 2 channels are downmixed to stereo (`-l Stereo`); mono stays mono.
4. **Tag** — TagLib write for the output container (MP4 atoms, ID3v2, FLAC Vorbis comments) using the mapping table (§9). Art: ImageIO decode → longest side ≤ 600 px → JPEG q 0.85. Preserve encoder-written gapless/loudness atoms (`iTunSMPB`, `iTunNORM`, LAME header). Set the encoder tag (`©too` / `TSSE`) to `"Convertable (<encoder> <settings>)"` so output is self-identifying forever.
5. **Verify** — `AVAudioFile` (or the backend's decoder) opens the result; duration within 100 ms of source; tags read back match. Failure → job `failed` with reason, retried up to 3× with backoff, surfaced in UI.
6. **Move out** — write to `<dest>.partial` on the share, then rename to final name. Never overwrite a non-`.partial` file without an explicit `retag`/`replace` job.
7. **Record** — `outputs` row; enqueue `music_add`.

Per file whose rule says *copy-through*: steps 1, 2, 4 (tags normalized on a local copy of the original), 5 (parse check), 6, 7. *Skip* rules record the file as `ignored` so it never shows as backlog.

**Retag path** (source changed, `audio_md5` unchanged, `tag_hash` changed): rewrite tags on the existing output (copied locally, tagged, moved back atomically), then enqueue `music_refresh`. No re-encode.

**Re-encode path** (`audio_md5` changed): full pipeline; the new file replaces the old one under the same path; Music track kept (same location), `music_refresh` enqueued.

**Path mapping** — pure and total: `Lossless Music/<rel>/<stem>.<ext>` → `Lossless Mirror/<rel>/<stem>.m4a` (lossless) or `…/<stem>.<ext>` unchanged (lossy). If two sources in the same folder share a stem (e.g. `track.flac` and `track.mp3`), the second gets a ` (2)` suffix and both are logged.

## 9. Tag mapping (Vorbis comment / ID3 → MP4)

| Source | MP4 atom | Notes |
|---|---|---|
| TITLE | `©nam` | |
| ARTIST | `©ART` | multi-valued → joined with "; " (Music shows one string) |
| ALBUMARTIST | `aART` | fallback: ARTIST |
| ALBUM | `©alb` | |
| DATE / ORIGINALDATE | `©day` | full date kept if present |
| TRACKNUMBER / TRACKTOTAL | `trkn` | `n/total` forms parsed |
| DISCNUMBER / DISCTOTAL | `disk` | |
| GENRE | `©gen` | first value |
| COMPOSER | `©wrt` | |
| COMMENT | `©cmt` | |
| LYRICS / UNSYNCEDLYRICS | `©lyr` | |
| COMPILATION | `cpil` | also set when ALBUMARTIST = "Various Artists" |
| BPM | `tmpo` | |
| TITLESORT / ARTISTSORT / ALBUMSORT / ALBUMARTISTSORT | `sonm` / `soar` / `soal` / `soaa` | |
| MUSICBRAINZ_* (trackid, albumid, artistid, albumartistid, releasegroupid) | `----:com.apple.iTunes:MusicBrainz …` | Picard's own convention, so Picard can re-identify the mirror files |
| ISRC, BARCODE, LABEL, CATALOGNUMBER | `----:com.apple.iTunes:…` | |
| METADATA_BLOCK_PICTURE / FLAC picture block (front cover preferred) | `covr` | downscaled |
| ReplayGain | *dropped* | iPod uses Sound Check, which afconvert already wrote |

ID3 (MP3 copy-through) uses the equivalent frames. Anything unmapped is logged once per key so gaps are visible.

## 10. Library scale and sizing

Measured by the Phase 1 scanner (2026-09-05, full scan over SMB in 184 s):

| | |
|---|---|
| Source tree | 2,789 directories, 23,386 files |
| Audio files | **21,509** — 17,689 lossless (FLAC/WAV/ALAC…) + 3,820 lossy (MP3 / AAC already in the tree → copy-through) |
| Artists / albums | 505 artist directories with audio (of 557 total) / 1,813 albums |
| Source bytes | **1.06 TB** |
| `.m4a` containers sniffed | 1,192 (ALAC vs AAC resolved by reading the `stsd` box) |
| Largest artists | King Gizzard 37.7 GB, Goose 35.5 GB, Grateful Dead 34.0 GB, Pink Floyd 23.5 GB |
| Legacy AAC library | 12,377 files / 124 GB (separate; see §12 supersede) |
| iPod capacity | 1 TB |

Output estimate at the default profile: lossless ×0.27 (planning ratio, refined from real outputs as they accumulate; hi-res sources come out lower) + lossy 1:1 → on the order of **300–350 GB** for the whole tree. Fits the iPod with room to spare.

## 11. Music.app bridge

**How Music learns about files — and why this section exists.** Music.app does not watch its media folder; a file placed there is invisible until something imports it. Tags are read from the file *once, at import*; later on-disk changes are not noticed until a `refresh`. Two import paths exist, offered as the **Import method** setting:

| | *Reference in place via AppleScript* (default) | *Hand off to "Automatically Add to Music"* |
|---|---|---|
| Mechanism | `add POSIX file` → Music records our path | We drop the finished file into the library's Auto-Add folder; Music imports and **moves** it into its own media folder, renamed by tag |
| Where the file lives afterwards | Our mirror folder (authoritative) | Music's media folder; mirror folder is transient |
| Requires "Copy files to Music Media folder" | **off** (checked and enforced) | any |
| Retag / re-encode in place | yes, same path | must locate the moved file via persistent ID → `location` |
| Works while another library is open | no — queued until the right library is open | no — Auto-Add is only processed by the open library; files wait in the folder |
| Needs AppleScript | for add, refresh, remove | only for refresh, remove, supersede |

Both modes are gated identically; the manual library switching the user plans is fine — the queue drains whenever the iPod library is opened.

- **Gate**: `library-url` in `com.apple.Music` prefs must equal the configured library (`…/AAC Music/Music Library.musiclibrary/`). If Music isn't running: launch it only if its last library was the right one; otherwise leave it alone. Wrong library open → all Music jobs wait; UI shows "Waiting for the AAC library to be open in Music" with a button to open it (which quits/relaunches Music into that library — always user-initiated).
- **Add**: `add POSIX file … to library playlist 1`; read back `location`. If the returned location is not our file, "Copy files to Music Media folder" is on → alert, disable auto-add until fixed (the app never fights that setting). Store `persistent ID`.
- **Reconcile** (first run and on demand): dump `location` + `persistent ID` of every file track once, map to `outputs` so re-installs or manual imports don't double-add.
- **Refresh** after retag: `refresh track`.
- **Remove** on approved deletion: `delete track` by persistent ID (the file is quarantined by us, not by Music).
- **Rename/move detection**: same `audio_md5` appears at a new path → treat as move: rename output, then try `set location of track` (keeps play counts/ratings); if Music refuses, remove + re-add and copy rating/play count/last played across first.
- All AppleScript runs in-process via `NSAppleScript`, serialized, with timeouts and exponential backoff; Music being busy/syncing an iPod is a retry, not a failure.

## 12. Review queue (deletes, renames, supersede)

- **Orphan**: a source missing across two consecutive *full* scans with the volume healthy → proposal *Remove mirror copy*. Approval → move output to `Lossless Mirror/.quarantine/<yyyy-mm-dd>/…` + Music remove. Quarantine purged after 30 days (configurable). Dismissing a proposal keeps the file and suppresses re-proposal until the source situation changes.
- **Supersede**: legacy `AAC Music/Music/Music/**/*.m4a` is indexed once (tags, duration). When a mirror album finishes, match legacy albums by normalized (album artist, album) with track count and per-track duration within ±3 s; only confident matches are proposed, others listed as "possible" for manual confirmation. Approval → copy rating/play count/last played from legacy tracks to mirror tracks (optional, default on), quarantine legacy files, Music remove. Legacy artists absent from the lossless tree are never proposed.
- The queue is grouped by album with select-all, Approve / Dismiss, and a "why" line per item. A badge on the menu bar icon shows pending count.

## 13. User interface

### 13.1 Menu bar (always visible, minimal)
- **Icon states**: idle · scanning · converting (with percent) · paused · batch complete · attention (approvals / volume missing / wrong library / failures). Badge = pending approvals.
- **Popover**: one-line status, current track, batch progress (in / out / remaining), queue depth, next scan; buttons *Pause/Resume*, *Start next batch*, *Scan now*, **Open Dashboard**, *Quit*.
- Launch at login via `SMAppService`. Ad-hoc signed `.app` in `/Applications`.

### 13.2 Web dashboard (the full UI)
Served by the app itself; opens at `http://<mac>.local:<port>/` from the popover, or from a phone/tablet on the LAN.

- **Overview** — status, current batch, throughput, backlog remaining (GB / albums / est. time), recent activity, alerts (volume, library, failures).
- **Convert** — the picker from §7: artist table (search, sort by name/size/status), expandable albums, star to pin, mode switch (artist / album / size / everything), budget cap, live selection summary, **Preview batch** → **Start**.
- **Batches** — history and the running one; per-album progress; pause/resume/stop.
- **Review** — the approval queue from §12, grouped by album, approve / dismiss, filters by kind.
- **Activity** — searchable per-track log with failure details and "retry" buttons.
- **Settings** — paths (with live validation), library identity, selection defaults, auto-continue + schedule window, encoder/share concurrency, art size, quarantine retention, notifications, web access (port, LAN on/off, token regenerate, QR code for phones), launch at login.
- Live updates over Server-Sent Events; no page reloads while a batch runs.

**Implementation**: Hummingbird HTTP server inside the app process; JSON API mirroring `ConvertableCore/API`; a single-page dashboard in plain HTML/CSS/JS embedded as a bundle resource (no Node toolchain to maintain). Mobile-friendly layout.

**Security**: binds to localhost by default; LAN exposure is an explicit toggle. Every request carries a random access token (cookie set by a one-time link/QR from Settings; also usable as a bearer header for scripts). No TLS on the LAN by default — the token is the only thing protecting it, so the token is long, rotated on demand, and the server never accepts requests from outside RFC-1918/link-local ranges. Any destructive action (approve removals, stop batch) requires the token *and* a same-origin check.

### 13.3 CLI (`convertctl`)
Same API over the command line for diagnostics and scripting: `doctor`, `scan`, `plan --artists "Adele,Aerosmith"` / `plan --budget 25GB`, `run`, `status`, `approvals list|approve|dismiss`, `reconcile`, `web token`.

## 14. Failure handling

- Every job is idempotent and resumable; `.partial` files and orphaned work dirs are cleaned on start.
- Volume vanishes mid-run → in-flight jobs abort cleanly, state returns to gate, nothing marked missing.
- Sleep/wake → scans reschedule; a batch resumes exactly where it stopped.
- Encode/tag/verify failures → 3 attempts with backoff, then `failed` with the exact stderr shown in Activity; the album's other tracks still complete, but the album is *not* added to Music until all tracks succeed or the user explicitly chooses "add anyway".
- Disk space: refuses to start an album if local temp free space < 2× the album's source size or if the share reports < 5 GB free.
- Music unreachable (not running, wrong library, syncing) → music jobs wait, everything else proceeds.
- Web server failing to bind → app still works from the menu bar; the popover shows the error and a retry.

## 15. Testing and stress

Every phase ends with `swift test` green; results are reported as they are. Nothing goes live (Phase 7) until the stress suite passes.

**Unit** — tag mapping (fixture Vorbis/ID3 sets → expected atoms, and back), path mapping incl. collisions and unicode/long paths, planner diffs, settle rules, selection modes and budget batching (album boundaries, soft caps, pins), profile rule matching, supersede matcher, API JSON encoding, adaptive concurrency controller.

**Integration (real audio, real tools)** — a fixture set of ~30 files copied from the library (FLAC 16/44.1, FLAC 24/96, 24/192, mono, multi-disc, compilation, ALAC, WAV, MP3, awkward unicode names, ID3-prefixed FLAC) run through the full pipeline into a scratch mirror on the NAS (`AAC Music/_convertable_test/`): asserts on sample rate, bitrate range, `iTunSMPB` presence, duration match, tag round-trip incl. MusicBrainz IDs, art dimensions, `©too` stamp. Repeated for each encoder backend present. Web API and SSE smoke tests against an in-memory core.

**Scale** — a synthetic library generator produces 25k tiny tone files (FLAC/MP3/ALAC, 1–2 s each) across ~600 artists / ~3.5k albums with realistic naming. Used to measure full scan, incremental scan, DB size, picker query latency, and batch planning at the real library's size. Target: incremental scan < 60 s on a local tree, picker queries < 100 ms.

**Fault injection** — each of these is a repeatable test, not a manual exercise:
- file still being written (grows across scans) → must not become eligible;
- album gaining tracks over 10 minutes → single Music add, all tracks;
- rename / move / delete during a running batch → correct proposals, no crash, no orphaned `.partial`;
- corrupt or truncated input; input with zero tags; art 6000×6000 PNG;
- unwritable destination; destination disk full (small disk image);
- **volume disappears mid-batch** (disk image ejected while encoding) → clean abort, gate state, nothing marked missing, resume after remount;
- `kill -9` of the app mid-encode / mid-move / mid-DB-write → next start cleans up and resumes;
- Music not running / wrong library open / Music busy → queue, backoff, drain;
- concurrency: a probe counts in-flight share operations and fails the test if the cap is ever exceeded; latency spike simulation verifies the adaptive back-off.

**Bridge** — AppleScript add / refresh / remove / reconcile tested only against a throwaway library (*Convertable Test*), never the real iPod library, until Phase 7.

**Manual acceptance** — one album into the scratch mirror, imported into the test library, synced to the iPod: gapless, art, sort order, Sound Check checked by ear and eye. Dashboard exercised from a phone on the LAN.

**`convertctl doctor`** — mount + protocol, cold/warm open latency benchmark with protocol recommendation, paths, afconvert/taglib/lame/flac presence and versions, Music library identity, Automation permission, free space, web port; pass/fail table.

**Needed from the user**: write access to the scratch folder on the NAS; OK to copy ~30 fixture files locally; Homebrew installs (`taglib`, `lame`, `flac`); a throwaway Music library before Phase 4 and an "Allow" on the Automation prompt; optionally an SMB mount now for the protocol benchmark; ears + iPod at Phase 7.

## 16. Build phases

Each phase ends with something you can run and judge.

| # | Phase | Deliverable |
|---|---|---|
| 0 | Scaffold | Package, targets, TagLib + Hummingbird deps, SQLite store, config, `convertctl doctor` passes on this Mac |
| 1 | Scan + plan (read-only) | `convertctl scan` builds the DB; `convertctl plan --budget 25GB` and `plan --artists …` print the batch: albums, tracks, GB in / est. GB out. **Touches nothing on the share.** |
| 2 | Pipeline | `convertctl run --mirror /path/to/scratch` encodes a couple of albums into a scratch folder. You verify in Music/iPod. |
| 3 | Web dashboard | Overview, Convert picker, Batches, Activity, Settings — against the real DB from phase 1, driving the pipeline from phase 2 into the scratch folder |
| 4 | Music bridge | Gate, add, reconcile, refresh, remove; tested against the NAS library with the scratch albums |
| 5 | Menu bar app | Status item, popover, notifications, hosts the web server, launch at login, `.app` build script |
| 6 | Review queue | Orphans, renames, retags, supersede matcher + Review page |
| 7 | First real batch | Point at `Lossless Mirror`, pick the first batch in the dashboard, run it with you watching; fix whatever reality reveals |

Phase 1 is deliberately read-only so the plan output can be checked against the survey before any file is written to the NAS. The web dashboard comes before the menu bar because it's the richer UI and the easier one to iterate on; the menu bar is then a thin shell around a working system.

## 17. Assumptions to confirm

1. Mirror folder is `/Volumes/PLeX/Music/AAC Music/Lossless Mirror/` (inside the library home, beside — not inside — Music's own media folder). Configurable.
2. Batch budget counts **source** bytes.
3. Album art capped at 600 px; quarantine kept 30 days.
4. "Copy files to Music Media folder when adding" will be turned **off** in the NAS library (the app detects and warns if it isn't).
5. Web dashboard: localhost by default, LAN access an explicit toggle with token + QR code; no TLS on the LAN.
6. Menu bar stays minimal (status + quick actions); everything with real surface area lives in the dashboard.
7. Import method defaults to *Reference in place via AppleScript*; Auto-Add hand-off is available as an option.
8. v1 encoder backends: `afconvert` (AAC/ALAC/PCM), `lame` (MP3), `flac` (FLAC); Opus/Vorbis/ffmpeg-decoding are pluggable later.
9. Auto-mounting the share from a URL is off by default; the app normally expects the volume to be mounted at login as today.
