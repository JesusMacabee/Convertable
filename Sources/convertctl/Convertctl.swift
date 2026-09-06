import Foundation
import ArgumentParser
import ConvertableCore

@main
struct Convertctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convertable command line — diagnostics and scripting over the same core as the app.",
        subcommands: [Doctor.self, Config.self, Tags.self, Scan.self, PlanCommand.self, Artists.self, Status.self, Pin.self],
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
