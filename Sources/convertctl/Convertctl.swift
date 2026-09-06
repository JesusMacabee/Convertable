import Foundation
import ArgumentParser
import ConvertableCore
import ConvertableWeb

@main
struct Convertctl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convertable command line — diagnostics and scripting over the same core as the app.",
        subcommands: [Doctor.self, Config.self, Tags.self, Scan.self, PlanCommand.self, Artists.self, Status.self, Pin.self, Run.self, Serve.self, WebURL.self, Music.self, Review.self],
        defaultSubcommand: Doctor.self)
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check mount, paths, tools, Music library, database, web port, share latency.")
    @Flag(name: .long, help: "Skip the share latency benchmark.") var noBenchmark = false

    func run() throws {
        let settings = try Settings.load()
        let checks = ConvertableCore.Doctor.run(settings: settings, benchmark: !noBenchmark)
        let width = checks.map(\.name.count).max() ?? 10
        for c in checks {
            let mark = c.result == .pass ? "✅" : (c.result == .warn ? "⚠️ " : "❌")
            print("\(mark) \(c.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(c.detail)")
        }
        let fails = checks.filter { $0.result == .fail }.count
        print(fails == 0 ? "\nAll critical checks passed." : "\n\(fails) critical check(s) failed.")
        if fails > 0 { throw ExitCode(1) }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show or initialise settings.json.")
    @Flag(name: .long, help: "Write the default settings file if none exists.") var initialize = false

    func run() throws {
        if initialize, !FileManager.default.fileExists(atPath: Settings.defaultURL.path) {
            try Settings().save()
            print("wrote \(Settings.defaultURL.path)")
        }
        let s = try Settings.load()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try enc.encode(s), as: UTF8.self))
        print("\n(file: \(Settings.defaultURL.path))")
    }
}

struct Tags: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Dump the tags TagLib reads from a file.")
    @Argument(help: "Audio file path.") var path: String

    func run() throws {
        let info = try TagReader.read(path)
        print("\(info.sampleRate) Hz, \(info.channels) ch, \(info.bitrateKbps) kbps, \(Double(info.lengthMs) / 1000) s, \(info.pictures.count) picture(s)")
        for (k, v) in info.properties.sorted(by: { $0.key < $1.key }) {
            print("  \(k.padding(toLength: 28, withPad: " ", startingAt: 0)) \(v.joined(separator: " | "))")
        }
        for p in info.pictures { print("  PICTURE \(p.pictureType) \(p.mimeType) \(p.data.count) bytes") }
    }
}


// MARK: - Phase 1: scan / plan / artists / status

func openStore() throws -> Store { try Store(path: Settings.defaultDatabaseURL.path) }

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read-only scan of the source library into the state database.")
    @Flag(name: .long, help: "Incremental scan (stat known directories, re-list changed ones). Default is a full, resumable scan.") var incremental = false
    @Flag(name: .long, help: "Print per-artist progress.") var verbose = false

    func run() throws {
        let settings = try Settings.load()
        let store = try openStore()
        let scanner = LibraryScanner(root: settings.sourceRoot, store: store)
        let t0 = Date()
        var lastPrinted = ""
        scanner.onProgress = { p in
            guard verbose, p.currentArtist != lastPrinted else { return }
            lastPrinted = p.currentArtist
            print(String(format: "  %6d files  %5d dirs  +%d ~%d  %@", p.files, p.dirs, p.added, p.changed, p.currentArtist))
        }
        let p = incremental ? try scanner.incrementalScan() : try scanner.fullScan()
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "%@ scan finished in %.1f s: %d dirs, %d files (%d audio), +%d added, ~%d changed, =%d unchanged, %d reappeared, %d missing, %d containers sniffed",
                     incremental ? "Incremental" : "Full", dt, p.dirs, p.files, p.audio, p.added, p.changed, p.unchanged, p.reappeared, p.missing, p.sniffed))
        let c = try store.counts()
        print("Library: \(c.artists) artists, \(c.albums) albums, \(c.active) active audio files (\(c.lossless) lossless, \(c.lossy) lossy), \(ByteCount.string(c.bytes)); \(c.missing) missing; \(c.mirrored) mirrored")
    }
}

struct PlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plan", abstract: "Preview a batch. Touches nothing.")
    @Option(name: .long, help: "Size mode: budget like 25GB.") var budget: String?
    @Option(name: .long, parsing: .upToNextOption, help: "Artist mode: one or more artist directory names.") var artists: [String] = []
    @Option(name: .long, parsing: .upToNextOption, help: "Album mode: 'Artist/Album' directory paths.") var albums: [String] = []
    @Flag(name: .long, help: "Everything eligible.") var everything = false
    @Option(name: .long, help: "Soft cap for artist/album/everything modes, e.g. 25GB.") var cap: String?
    @Flag(name: .long, help: "Treat not-yet-settled albums as eligible (preview aid).") var ignoreSettle = false
    @Flag(name: .long, help: "List every track.") var tracks = false
    @Option(name: .long, help: "Profile id (default from settings).") var profile: String?

    func run() throws {
        let settings = try Settings.load()
        let store = try openStore()
        guard let prof = Profile.named(profile ?? settings.profileID) else { throw ValidationError("unknown profile") }
        let mode: Selection.Mode
        var capBytes: Int64? = cap.flatMap(ByteParser.parse)
        if !artists.isEmpty { mode = .artists(artists) }
        else if !albums.isEmpty {
            mode = .albums(albums.map { a in
                let parts = a.split(separator: "/", maxSplits: 1).map(String.init)
                return AlbumKey(artistDir: parts[0], albumDir: parts.count > 1 ? parts[1] : "")
            })
        } else if everything { mode = .everything }
        else {
            mode = .size
            capBytes = budget.flatMap(ByteParser.parse) ?? settings.batchBudgetBytes
        }
        let planner = Planner(store: store, profile: prof, fileSettleSeconds: settings.fileSettleSeconds, albumSettleSeconds: settings.albumSettleSeconds)
        let plan = try planner.plan(Selection(mode: mode, cap: capBytes, ignoreSettle: ignoreSettle))

        print("Profile: \(prof.name)")
        print("Selection: \(plan.selection.description)\n")
        for a in plan.albums {
            print(String(format: "%@%@ — %@   [%d tracks, %@ in → ~%@ out]", a.pinned ? "★ " : "", a.displayArtist, a.displayAlbum, a.tracks.count,
                         ByteCount.string(a.bytesIn), ByteCount.string(a.estimatedOutBytes)))
            if tracks { for t in a.tracks { print("      \(t.action.label.padding(toLength: 28, withPad: " ", startingAt: 0)) \(t.source.fileName) → \((t.outputRelPath as NSString).lastPathComponent)") } }
        }
        print(String(format: "\nThis batch: %d albums, %d tracks, %@ in → ~%@ out", plan.albums.count, plan.trackCount,
                     ByteCount.string(plan.bytesIn), ByteCount.string(plan.estimatedOutBytes)))
        if !plan.overflow.isEmpty {
            print(String(format: "Beyond the cap: %d albums, %@ — you may convert all, respect the cap, or raise it.", plan.overflow.count, ByteCount.string(plan.overflowBytes)))
        }
        if plan.backlogAlbums > 0 {
            print(String(format: "Backlog after this batch: %d albums, %@", plan.backlogAlbums, ByteCount.string(plan.backlogBytes)))
        }
        let settling = plan.ineligible.filter { if case .settling = $0.1 { return true }; return false }.count
        let done = plan.ineligible.filter { $0.1 == .nothingToDo }.count
        let skipped = plan.ineligible.filter { $0.1 == .allSkipped }.count
        print("Not in this plan: \(settling) settling, \(done) already mirrored, \(skipped) all-skipped")
    }
}

struct Artists: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "The artist picker, as a table.")
    @Option(name: .long, help: "name | size | tracks | status") var sort: String = "name"
    @Option(name: .long, help: "Show only the first N rows.") var top: Int?
    @Option(name: .long, help: "Expand one artist's albums.") var expand: String?

    func run() throws {
        let store = try openStore()
        if let expand {
            for a in try store.albumSummaries(artist: expand) {
                let status = a.mirrored == 0 ? "—" : (a.mirrored == a.tracks ? "✓" : "\(a.mirrored)/\(a.tracks)")
                let name = String((a.key.albumDir.isEmpty ? "(loose files)" : a.key.albumDir).prefix(60))
                print("  \(pad(name, 60)) \(pad(String(a.tracks), 3, left: true)) tracks  \(pad(ByteCount.string(a.bytes), 10, left: true))  \(status)")
            }
            return
        }
        var rows = try store.artistSummaries()
        switch sort {
        case "size": rows.sort { $0.bytes > $1.bytes }
        case "tracks": rows.sort { $0.tracks > $1.tracks }
        case "status": rows.sort { $0.status < $1.status }
        default: break
        }
        if let top { rows = Array(rows.prefix(top)) }
        print("  \(pad("Artist", 38)) \(pad("Albums", 6, left: true)) \(pad("Tracks", 7, left: true)) \(pad("Size", 10, left: true))  Mirror")
        for r in rows {
            print("\(r.pinned ? "★ " : "  ")\(pad(String(r.displayName.prefix(38)), 38)) \(pad(String(r.albums), 6, left: true)) \(pad(String(r.tracks), 7, left: true)) \(pad(ByteCount.string(r.bytes), 10, left: true))  \(r.status)")
        }
        let total = rows.reduce(Int64(0)) { $0 + $1.bytes }
        print("\n\(rows.count) artists, \(ByteCount.string(total))")
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Library and scan status.")
    func run() throws {
        let settings = try Settings.load()
        let store = try openStore()
        let c = try store.counts()
        print("Source: \(settings.sourceRoot)")
        print("Volume: \(VolumeGate.check(root: settings.sourceRoot, timeout: 10))")
        print("Library: \(c.artists) artists, \(c.albums) albums, \(c.active) audio files (\(c.lossless) lossless, \(c.lossy) lossy), \(ByteCount.string(c.bytes)), \(c.directories) directories")
        print("Missing: \(c.missing)   Mirrored: \(c.mirrored)")
        if let s = try store.lastFinishedScan(.full) { print("Last full scan: \(Date(timeIntervalSince1970: s.finishedAt!)) (\(s.filesSeen) files)") }
        if let s = try store.lastFinishedScan(.incremental) { print("Last incremental scan: \(Date(timeIntervalSince1970: s.finishedAt!))") }
        if let s = try store.unfinishedFullScan() { print("Unfinished full scan: resumes after '\(s.checkpoint ?? "start")'") }
    }
}

struct Pin: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pin or unpin an artist (pinned artists are always queued first).")
    @Argument var artist: String
    @Flag(name: .long) var remove = false
    func run() throws {
        try openStore().pin(artist, pinned: !remove)
        print(remove ? "unpinned \(artist)" : "pinned \(artist)")
    }
}


func pad(_ s: String, _ width: Int, left: Bool = false) -> String {
    let n = s.count
    guard n < width else { return s }
    let fill = String(repeating: " ", count: width - n)
    return left ? fill + s : s + fill
}


// MARK: - Phase 2: run

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Convert a batch. Same selection flags as `plan`. Writes to the mirror root (override with --mirror).")
    @Option(name: .long, help: "Size mode budget, e.g. 2GB.") var budget: String?
    @Option(name: .long, parsing: .upToNextOption) var artists: [String] = []
    @Option(name: .long, parsing: .upToNextOption) var albums: [String] = []
    @Flag(name: .long) var everything = false
    @Option(name: .long) var cap: String?
    @Flag(name: .long) var ignoreSettle = false
    @Option(name: .long, help: "Write outputs here instead of the configured mirror root (scratch testing).") var mirror: String?
    @Option(name: .long) var concurrency: Int?
    @Option(name: .long) var profile: String?
    @Flag(name: .long, help: "Plan and print, but convert nothing.") var dryRun = false

    func run() async throws {
        let settings = try Settings.load()
        let store = try openStore()
        guard let prof = Profile.named(profile ?? settings.profileID) else { throw ValidationError("unknown profile") }
        let mode: Selection.Mode
        var capBytes: Int64? = cap.flatMap(ByteParser.parse)
        if !artists.isEmpty { mode = .artists(artists) }
        else if !albums.isEmpty { mode = .albums(albums.map { a in let p = a.split(separator: "/", maxSplits: 1).map(String.init); return AlbumKey(artistDir: p[0], albumDir: p.count > 1 ? p[1] : "") }) }
        else if everything { mode = .everything }
        else { mode = .size; capBytes = budget.flatMap(ByteParser.parse) ?? settings.batchBudgetBytes }
        let selection = Selection(mode: mode, cap: capBytes, ignoreSettle: ignoreSettle)
        let planner = Planner(store: store, profile: prof, fileSettleSeconds: settings.fileSettleSeconds, albumSettleSeconds: settings.albumSettleSeconds)
        let plan = try planner.plan(selection)
        print("Selection: \(selection.description) → \(plan.albums.count) albums, \(plan.trackCount) tracks, \(ByteCount.string(plan.bytesIn)) in")
        if dryRun || plan.albums.isEmpty { return }

        guard case let .available(mount) = VolumeGate.check(root: settings.sourceRoot) else { throw ValidationError("source volume not available") }
        let mirrorRoot = mirror ?? settings.mirrorRoot
        try FileManager.default.createDirectory(atPath: mirrorRoot, withIntermediateDirectories: true)
        let shareIO = ShareIO(limit: settings.shareConcurrencyOverride ?? mount.suggestedConcurrency, maxLimit: 8)
        let work = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Convertable/work").path
        let config = Pipeline.Config(sourceRoot: settings.sourceRoot, mirrorRoot: mirrorRoot, workDir: work,
                                     encodeConcurrency: concurrency ?? settings.encodeConcurrency,
                                     artMaxPixels: settings.artMaxPixels, artJPEGQuality: settings.artJPEGQuality, profileID: prof.id)
        let sel = try JSONEncoder().encode(selection)
        try store.db.run("INSERT INTO batches (selection_json, budget_bytes, started_at) VALUES (?,?,?)",
                         [.text(String(decoding: sel, as: UTF8.self)), Database.Value(capBytes), .real(Date().timeIntervalSince1970)])
        let batchID = store.db.lastInsertRowID

        let pipeline = Pipeline(config: config, store: store, shareIO: shareIO)
        pipeline.onEvent = { ev in
            switch ev {
            case let .albumStarted(a): print("▶ \(a.displayArtist) — \(a.displayAlbum) (\(a.tracks.count) tracks)")
            case let .trackFinished(r):
                let name = (r.track.outputRelPath as NSString).lastPathComponent
                print(r.ok ? String(format: "   ✓ %@  %@  %.1fs", name, ByteCount.string(r.outputBytes), r.seconds) : "   ✗ \(name): \(r.error ?? "?")")
            case let .albumFinished(a): print(a.complete ? "   album complete" : "   album INCOMPLETE — not eligible for Music import")
            case let .message(m): print("   \(m)")
            }
        }
        let summary = await pipeline.run(plan, batchID: batchID)
        print(String(format: "\nBatch #%d %@: %d tracks ok, %d failed, %@ in → %@ out, %.0f s (share concurrency peak %d, limit now %d)",
                     batchID, summary.endedBy, summary.tracksDone, summary.tracksFailed, ByteCount.string(summary.bytesIn), ByteCount.string(summary.bytesOut),
                     summary.seconds, await shareIO.peakInFlight, await shareIO.limit))
        if summary.tracksFailed > 0 { throw ExitCode(2) }
    }
}


// MARK: - Phase 3: serve

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the controller (scheduler + batches) and the web dashboard in the foreground.")
    @Flag(name: .long, help: "Do not start periodic scanning / auto-continue.") var noScheduler = false

    func run() async throws {
        let settings = try Settings.load()
        let store = try openStore()
        let controller = AppController(settings: settings, store: store)
        await controller.startScheduler(scans: !noScheduler)
        let server = WebServer(controller: controller, settings: settings)
        print("Convertable dashboard: \(server.localURL)")
        if settings.web.allowLAN { print("LAN access is ON — same token, any interface, port \(settings.web.port)") }
        try await server.run()
    }
}

struct WebURL: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "web-url", abstract: "Print the dashboard address including the access token.")
    func run() throws {
        let s = try Settings.load()
        print("http://127.0.0.1:\(s.web.port)/?token=\(s.web.token)")
    }
}


// MARK: - Phase 4: music

struct Music: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Music.app bridge: ping, pending, drain, reconcile, tracks, remove.",
                                                    subcommands: [Ping.self, Pending.self, Drain.self, Reconcile.self, TracksCmd.self, Remove.self])

    struct LibraryOptions: ParsableArguments {
        @Option(name: .long, help: "Override the configured .musiclibrary path (testing against a throwaway library).") var library: String?
        @Option(name: .long, help: "Override the mirror root (scratch testing).") var mirror: String?
        func settings() throws -> Settings {
            var s = try Settings.load()
            if let library { s.musicLibraryPath = library }
            if let mirror { s.mirrorRoot = mirror }
            return s
        }
    }

    struct Ping: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check Automation permission and which library is open.")
        @OptionGroup var lib: LibraryOptions
        func run() throws {
            let s = try lib.settings()
            print("Music running: \(MusicPrefs.isRunning)")
            print("Open library:  \(MusicPrefs.openLibraryURLString?.removingPercentEncoding ?? "?")")
            print("Configured:    \(s.musicLibraryFileURLString.removingPercentEncoding ?? "")  → \(MusicPrefs.isConfiguredLibraryOpen(s) ? "MATCH" : "different")")
            print("Version:       \(try MusicBridge().version())")
        }
    }
    struct Pending: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Albums complete and waiting to be added to Music.")
        @OptionGroup var lib: LibraryOptions
        func run() throws {
            let s = try lib.settings()
            let imp = MusicImporter(store: try openStore(), settings: s, profile: Profile.named(s.profileID)!, bridge: MusicBridge())
            let albums = try imp.pendingAlbums()
            for k in albums.keys.sorted() { print("  \(k.relPath)  (\(albums[k]!.count) tracks)") }
            print("\(albums.values.reduce(0) { $0 + $1.count }) tracks in \(albums.count) complete albums; gate: \(imp.libraryReady())")
        }
    }
    struct Drain: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add pending complete albums to the open Music library.")
        @OptionGroup var lib: LibraryOptions
        @Option(name: .long) var max: Int = 200
        func run() throws {
            let s = try lib.settings()
            let imp = MusicImporter(store: try openStore(), settings: s, profile: Profile.named(s.profileID)!, bridge: MusicBridge())
            let o = imp.drain(maxTracks: max)
            print("added \(o.added), failed \(o.failed)")
            o.messages.forEach { print("  \($0)") }
            if let d = o.disabledReason { print("DISABLED: \(d)"); throw ExitCode(2) }
        }
    }
    struct Reconcile: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Map Music's file tracks back onto recorded outputs.")
        @OptionGroup var lib: LibraryOptions
        func run() throws {
            let s = try lib.settings()
            let imp = MusicImporter(store: try openStore(), settings: s, profile: Profile.named(s.profileID)!, bridge: MusicBridge())
            let r = try imp.reconcile()
            print("matched \(r.matched) outputs; \(r.unknownInMirror) tracks under the mirror root are not ours")
        }
    }
    struct TracksCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "tracks", abstract: "List file tracks (persistent ID and path) in the open library.")
        func run() throws { for t in try MusicBridge().fileTracks() { print("\(t.persistentID)\t\(t.path)") } }
    }
    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove one track entry from the open library by persistent ID (the file is untouched).")
        @Argument var persistentID: String
        func run() throws { try MusicBridge().remove(persistentID: persistentID); print("removed \(persistentID)") }
    }
}


// MARK: - Phase 6: review

struct Review: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Removal / supersede proposals.", subcommands: [List.self, Detect.self, Approve.self, Dismiss.self, LegacyIndex.self, LegacyMatch.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pending and approved proposals.")
        func run() throws {
            let ps = try openStore().proposals(states: ["pending", "approved"])
            for p in ps { print("#\(p.id) [\(p.state)] \(p.kind)  \(p.artistDir)/\(p.albumDir)  — \(p.title) (\(p.items.count) files, \(ByteCount.string(p.bytes)))\n     \(p.reason)") }
            if ps.isEmpty { print("no proposals") }
        }
    }
    struct Detect: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run orphan detection now (normally after each scan).")
        func run() throws {
            let s = try Settings.load(); let r = Reviewer(store: try openStore(), mirrorRoot: s.mirrorRoot)
            print("withdrawn \(try r.withdrawStaleProposals()), new proposals \(try r.detectOrphans())")
        }
    }
    struct Approve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Approve a proposal (files go to quarantine).")
        @Argument var id: Int64
        func run() async throws {
            let s = try Settings.load(); let store = try openStore()
            let c = AppController(settings: s, store: store)
            try await c.approve(id)
            print("approved #\(id): \(try store.proposal(id: id)?.state ?? "?")")
        }
    }
    struct Dismiss: ParsableCommand {
        @Argument var id: Int64
        func run() throws { try openStore().setProposalState(id, "dismissed"); print("dismissed #\(id)") }
    }
    struct LegacyIndex: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "legacy-index", abstract: "Index the legacy library's tags (incremental).")
        @Option(name: .long, parsing: .upToNextOption) var roots: [String] = []
        func run() async throws {
            let s = try Settings.load()
            var idx = LegacyIndexer(store: try openStore(), roots: roots.isEmpty ? s.legacyMediaRoots : roots)
            idx.onProgress = { seen, indexed in print("  \(seen) seen, \(indexed) indexed") }
            let r = try await idx.run(shareIO: ShareIO(limit: 4))
            print("legacy: \(r.seen) seen, \(r.indexed) indexed, \(r.removed) removed")
        }
    }
    struct LegacyMatch: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "legacy-match", abstract: "Propose supersedes for completed mirror albums.")
        func run() throws {
            let s = try Settings.load(); let store = try openStore()
            print("new supersede proposals: \(try SupersedeMatcher(store: store, profile: Profile.named(s.profileID)!).run())")
        }
    }
}
