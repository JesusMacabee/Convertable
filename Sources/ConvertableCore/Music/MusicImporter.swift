import Foundation

/// Hands finished albums to Music.app, only when the configured library is the open one.
/// An album is imported when every source file that needs work has a verified output — Music
/// never sees a half-converted album.
public struct MusicImporter {
    public struct Outcome: Sendable {
        public var added = 0, failed = 0, skipped = 0
        public var disabledReason: String?
        public var messages: [String] = []
    }

    public let store: Store
    public let settings: Settings
    public let profile: Profile
    public let bridge: MusicBridge
    /// Replaceable in tests; the default reads Music's preferences.
    public var gate: () -> Result<Void, MusicError>

    public init(store: Store, settings: Settings, profile: Profile, bridge: MusicBridge, gate: (() -> Result<Void, MusicError>)? = nil) {
        self.store = store; self.settings = settings; self.profile = profile; self.bridge = bridge
        self.gate = gate ?? { MusicImporter.defaultGate(settings) }
    }

    static func defaultGate(_ settings: Settings) -> Result<Void, MusicError> {
        guard MusicPrefs.isRunning else { return .failure(.notRunning) }
        guard MusicPrefs.isConfiguredLibraryOpen(settings) else {
            return .failure(.wrongLibraryOpen(MusicPrefs.openLibraryURLString?.removingPercentEncoding ?? "unknown"))
        }
        return .success(())
    }

    /// Verified outputs not yet in Music, grouped by album, only for albums that are complete.
    public func pendingAlbums() throws -> [AlbumKey: [(output: OutputFile, source: SourceFile)]] {
        let rows = try store.db.query("""
            SELECT o.id o_id, o.source_id, o.rel_path o_rel, o.size o_size, o.encoder_profile, o.audio_md5 o_md5, o.tag_hash o_th, o.verify_ok, o.music_persistent_id,
                   s.*
            FROM outputs o JOIN source_files s ON s.id = o.source_id
            WHERE o.verify_ok = 1 AND o.music_persistent_id IS NULL AND (o.music_attempts IS NULL OR o.music_attempts < 5) AND s.status = 'active'
            ORDER BY s.artist_dir, s.album_dir, s.rel_path
            """) { r -> (OutputFile, SourceFile) in
            let out = OutputFile(id: r.int("o_id")!, sourceID: r.int("source_id")!, relPath: r.text("o_rel")!, size: r.int("o_size"),
                                 encoderProfile: r.text("encoder_profile")!, audioMD5: r.text("o_md5"), tagHash: r.text("o_th"),
                                 verifyOK: true, musicPersistentID: nil)
            return (out, Store.sourceFile(r))
        }
        var byAlbum: [AlbumKey: [(OutputFile, SourceFile)]] = [:]
        for (o, s) in rows { byAlbum[s.albumKey, default: []].append((o, s)) }
        // Completeness: every active source in the album that the profile wants work for has a verified output.
        var complete: [AlbumKey: [(output: OutputFile, source: SourceFile)]] = [:]
        for (key, items) in byAlbum {
            let files = try store.sourceFiles(in: key)
            let needed = files.filter { profile.action(for: $0).isWork }
            var ok = true
            for f in needed where try store.output(forSource: f.id)?.verifyOK != true { ok = false; break }
            if ok { complete[key] = items.map { (output: $0.0, source: $0.1) } }
        }
        return complete
    }

    public func pendingCount() -> Int {
        (try? pendingAlbums().values.reduce(0) { $0 + $1.count }) ?? 0
    }

    /// Gate: right library open in a running Music.
    public func libraryReady() -> Result<Void, MusicError> { gate() }

    /// Adds up to `maxTracks` tracks (whole albums). Stops at the first sign of the copy-files setting.
    public func drain(maxTracks: Int = 200, mirrorRoot: String? = nil) -> Outcome {
        var out = Outcome()
        guard settings.importMethod == .appleScript else {
            out.disabledReason = "Import method “Automatically Add to Music” is not available in this version; switch to “Reference in place via AppleScript”."
            return out
        }
        if case let .failure(e) = libraryReady() { out.messages.append(e.description); return out }
        let root = mirrorRoot ?? settings.mirrorRoot
        guard let albums = try? pendingAlbums() else { return out }
        var budget = maxTracks
        for key in albums.keys.sorted() {
            guard budget > 0 else { break }
            for item in albums[key]! {
                guard budget > 0 else { break }
                budget -= 1
                let path = root + "/" + item.output.relPath
                do {
                    let (pid, loc) = try bridge.add(path: path)
                    if !Self.samePath(loc, path) {
                        // Music copied the file. Undo what we can and stop: the setting must change first.
                        try? bridge.remove(persistentID: pid)
                        if !loc.isEmpty, Self.looksLikeCopy(of: path, at: loc) { try? FileManager.default.removeItem(atPath: loc) }
                        out.disabledReason = MusicError.copiedIntoMediaFolder(added: loc, ours: path).description
                        try? store.log("error", "music", out.disabledReason!, relPath: item.source.relPath)
                        return out
                    }
                    try store.db.run("UPDATE outputs SET music_persistent_id=?, music_added_at=?, music_error=NULL WHERE id=?",
                                     [.text(pid), .real(Date().timeIntervalSince1970), .integer(item.output.id)])
                    try? store.log("info", "music", "added to Music (\(pid))", relPath: item.source.relPath)
                    out.added += 1
                } catch {
                    out.failed += 1
                    try? store.db.run("UPDATE outputs SET music_attempts=COALESCE(music_attempts,0)+1, music_error=? WHERE id=?", [.text("\(error)"), .integer(item.output.id)])
                    try? store.log("warn", "music", "add failed: \(error)", relPath: item.source.relPath)
                    // Music being busy (iPod sync, dialog open) fails everything; don't hammer it.
                    if out.failed >= 3 { out.messages.append("Music is refusing adds; will retry later"); return out }
                }
            }
        }
        return out
    }

    /// Maps Music's file tracks back onto our outputs (after a reinstall, a manual import, or a lost ID).
    public func reconcile(mirrorRoot: String? = nil) throws -> (matched: Int, unknownInMirror: Int) {
        let root = (mirrorRoot ?? settings.mirrorRoot) + "/"
        let tracks = try bridge.fileTracks()
        var matched = 0, unknown = 0
        try store.db.transaction {
            for t in tracks where t.path.hasPrefix(root) {
                let rel = String(t.path.dropFirst(root.count))
                let n = try store.db.run("UPDATE outputs SET music_persistent_id=?, music_added_at=COALESCE(music_added_at, ?) WHERE rel_path=? AND (music_persistent_id IS NULL OR music_persistent_id != ?)",
                                         [.text(t.persistentID), .real(Date().timeIntervalSince1970), .text(rel), .text(t.persistentID)])
                if n > 0 { matched += 1 } else if try store.db.scalar("SELECT COUNT(*) FROM outputs WHERE rel_path=?", [.text(rel)]) == .integer(0) { unknown += 1 }
            }
        }
        return (matched, unknown)
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        let ra = URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path
        let rb = URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
        return ra.lowercased() == rb.lowercased()
    }

    /// Only delete Music's copy if it is byte-for-byte the same size as ours — never anything else.
    static func looksLikeCopy(of ours: String, at theirs: String) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: ours)[.size] as? NSNumber,
              let b = try? FileManager.default.attributesOfItem(atPath: theirs)[.size] as? NSNumber else { return false }
        return a == b && !samePath(ours, theirs)
    }
}
