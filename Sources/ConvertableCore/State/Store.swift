import Foundation

/// Typed access to the state database. One instance per Database; callers serialize.
/// Thread-safe: every Database call takes the connection lock.
public final class Store: @unchecked Sendable {
    public let db: Database

    public init(db: Database) throws {
        self.db = db
        try Schema.migrate(db)
    }

    public convenience init(path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try self.init(db: try Database(path: path))
    }

    public static func inMemory() throws -> Store { try Store(db: try Database.inMemory()) }

    // MARK: Scans

    public func beginScan(_ kind: ScanKind, now: Double = Date().timeIntervalSince1970) throws -> ScanRecord {
        let id = try db.insert("INSERT INTO scans (kind, started_at) VALUES (?, ?)", [.text(kind.rawValue), .real(now)])
        return ScanRecord(id: id, kind: kind, startedAt: now, finishedAt: nil, dirsSeen: 0, filesSeen: 0, checkpoint: nil)
    }

    /// The most recent full scan that never finished — a resumable one.
    public func unfinishedFullScan() throws -> ScanRecord? {
        try db.query("SELECT * FROM scans WHERE kind='full' AND finished_at IS NULL ORDER BY id DESC LIMIT 1", [], Store.scan).first
    }

    public func lastFinishedScan(_ kind: ScanKind? = nil) throws -> ScanRecord? {
        if let kind {
            return try db.query("SELECT * FROM scans WHERE kind=? AND finished_at IS NOT NULL ORDER BY id DESC LIMIT 1", [.text(kind.rawValue)], Store.scan).first
        }
        return try db.query("SELECT * FROM scans WHERE finished_at IS NOT NULL ORDER BY id DESC LIMIT 1", [], Store.scan).first
    }

    public func updateScan(_ id: Int64, checkpoint: String?, dirsSeen: Int, filesSeen: Int) throws {
        try db.run("UPDATE scans SET checkpoint=?, dirs_seen=?, files_seen=? WHERE id=?",
                   [Database.Value(checkpoint), .integer(Int64(dirsSeen)), .integer(Int64(filesSeen)), .integer(id)])
    }

    public func finishScan(_ id: Int64, now: Double = Date().timeIntervalSince1970) throws {
        try db.run("UPDATE scans SET finished_at=?, checkpoint=NULL WHERE id=?", [.real(now), .integer(id)])
    }

    /// Abandons an unfinished scan so its id no longer counts as the "current" scan (e.g. after a volume loss).
    public func abandonScan(_ id: Int64) throws {
        try db.run("DELETE FROM scans WHERE id=? AND finished_at IS NULL", [.integer(id)])
    }

    static func scan(_ r: Database.Row) -> ScanRecord {
        ScanRecord(id: r.int("id")!, kind: ScanKind(rawValue: r.text("kind")!)!, startedAt: r.double("started_at")!,
                   finishedAt: r.double("finished_at"), dirsSeen: Int(r.int("dirs_seen") ?? 0), filesSeen: Int(r.int("files_seen") ?? 0),
                   checkpoint: r.text("checkpoint"))
    }

    // MARK: Directories

    public func seenDirectory(_ relPath: String, mtime: Double, scanID: Int64) throws {
        try db.run("""
            INSERT INTO directories (rel_path, mtime, last_seen_scan, status) VALUES (?, ?, ?, 'active')
            ON CONFLICT(rel_path) DO UPDATE SET mtime=excluded.mtime, last_seen_scan=excluded.last_seen_scan, status='active'
            """, [.text(relPath), .real(mtime), .integer(scanID)])
    }

    public func activeDirectories() throws -> [(relPath: String, mtime: Double)] {
        try db.query("SELECT rel_path, mtime FROM directories WHERE status='active' ORDER BY rel_path") { ($0.text(0)!, $0.double(1)!) }
    }

    public func markDirectoriesMissing(notSeenIn scanID: Int64, underPrefix prefix: String? = nil) throws -> Int {
        if let prefix {
            return try db.run("UPDATE directories SET status='missing' WHERE status='active' AND last_seen_scan < ? AND (rel_path = ? OR rel_path LIKE ? ESCAPE '\\')",
                              [.integer(scanID), .text(prefix), .text(Store.likePrefix(prefix) + "/%")])
        }
        return try db.run("UPDATE directories SET status='missing' WHERE status='active' AND last_seen_scan < ?", [.integer(scanID)])
    }

    // MARK: Source files

    public enum SeenResult: Equatable { case added, changed, unchanged, reappeared }

    /// Records an observation of a file. Implements the settle bookkeeping:
    /// same size+mtime → observations += 1; different → reset stable_since and observations.
    @discardableResult
    public func seenFile(relPath: String, artistDir: String, albumDir: String, ext: String, kind: FileKind, codec: String?,
                         size: Int64, mtime: Double, scanID: Int64, now: Double) throws -> SeenResult {
        let existing = try db.query("SELECT id, size, mtime, status FROM source_files WHERE rel_path=?", [.text(relPath)]) {
            ($0.int("id")!, $0.int("size")!, $0.double("mtime")!, $0.text("status")!)
        }.first
        guard let (id, oldSize, oldMtime, status) = existing else {
            try db.run("""
                INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, codec, size, mtime, stable_since, observations, first_seen, last_seen_scan, status)
                VALUES (?,?,?,?,?,?,?,?,?,1,?,?,'active')
                """, [.text(relPath), .text(artistDir), .text(albumDir), .text(ext), .text(kind.rawValue), Database.Value(codec),
                      .integer(size), .real(mtime), .real(now), .real(now), .integer(scanID)])
            return .added
        }
        if oldSize == size && abs(oldMtime - mtime) < 0.001 {
            try db.run("UPDATE source_files SET observations=observations+1, last_seen_scan=?, status='active', missing_since=NULL WHERE id=?",
                       [.integer(scanID), .integer(id)])
            return status == "missing" ? .reappeared : .unchanged
        }
        try db.run("""
            UPDATE source_files SET size=?, mtime=?, stable_since=?, observations=1, last_seen_scan=?, status='active', missing_since=NULL,
                                    kind=?, codec=COALESCE(?, codec)
            WHERE id=?
            """, [.integer(size), .real(mtime), .real(now), .integer(scanID), .text(kind.rawValue), Database.Value(codec), .integer(id)])
        return .changed
    }

    /// A source found changed outside a scan (the pipeline stat'ed it before copying): record the new size/mtime and
    /// restart its settle clock, exactly as a scan would. Its tags are re-read because stable_since now exceeds tag_audit_at.
    public func noteSourceChanged(id: Int64, size: Int64, mtime: Double, now: Double) throws {
        try db.run("UPDATE source_files SET size=?, mtime=?, stable_since=?, observations=1 WHERE id=?",
                   [.integer(size), .real(mtime), .real(now), .integer(id)])
    }

    /// Marks active files not seen by `scanID` as missing. Optionally limited to one directory (non-recursive)
    /// or to everything under a prefix (recursive).
    @discardableResult
    public func markFilesMissing(notSeenIn scanID: Int64, now: Double, directlyIn dir: String? = nil, underPrefix prefix: String? = nil) throws -> Int {
        var sql = "UPDATE source_files SET status='missing', missing_since=COALESCE(missing_since, ?) WHERE status='active' AND last_seen_scan < ?"
        var params: [Database.Value] = [.real(now), .integer(scanID)]
        if let dir {
            // Files whose parent directory is exactly `dir`.
            sql += " AND rel_path LIKE ? ESCAPE '\\' AND rel_path NOT LIKE ? ESCAPE '\\'"
            let base = dir.isEmpty ? "" : Store.likePrefix(dir) + "/"
            params += [.text(base + "%"), .text(base + "%/%")]
        } else if let prefix {
            sql += " AND rel_path LIKE ? ESCAPE '\\'"
            params.append(.text(Store.likePrefix(prefix) + "/%"))
        }
        return try db.run(sql, params)
    }

    /// Files seen only once so far — an incremental scan re-stats these individually so they can settle
    /// (or be caught still growing) without waiting for the next full scan.
    public func filesAwaitingConfirmation(limit: Int = 5000) throws -> [SourceFile] {
        try db.query("SELECT * FROM source_files WHERE status='active' AND observations < 2 ORDER BY id LIMIT ?", [.integer(Int64(limit))], Store.sourceFile)
    }

    public func markFileMissing(relPath: String, now: Double) throws {
        try db.run("UPDATE source_files SET status='missing', missing_since=COALESCE(missing_since, ?) WHERE rel_path=? AND status='active'", [.real(now), .text(relPath)])
    }

    public func sourceFile(relPath: String) throws -> SourceFile? {
        try db.query("SELECT * FROM source_files WHERE rel_path=?", [.text(relPath)], Store.sourceFile).first
    }

    public func sourceFiles(in album: AlbumKey, includeMissing: Bool = false) throws -> [SourceFile] {
        try db.query("SELECT * FROM source_files WHERE artist_dir=? AND album_dir=? \(includeMissing ? "" : "AND status='active'") ORDER BY rel_path",
                     [.text(album.artistDir), .text(album.albumDir)], Store.sourceFile)
    }

    public func setCodec(id: Int64, codec: String, kind: FileKind) throws {
        try db.run("UPDATE source_files SET codec=?, kind=? WHERE id=?", [.text(codec), .text(kind.rawValue), .integer(id)])
    }

    public func setTags(id: Int64, artist: String?, albumArtist: String?, album: String?, audioMD5: String?, tagHash: String?) throws {
        try db.run("UPDATE source_files SET tag_artist=?, tag_albumartist=?, tag_album=?, audio_md5=?, tag_hash=? WHERE id=?",
                   [Database.Value(artist), Database.Value(albumArtist), Database.Value(album), Database.Value(audioMD5), Database.Value(tagHash), .integer(id)])
    }

    static func sourceFile(_ r: Database.Row) -> SourceFile {
        SourceFile(id: r.int("id")!, relPath: r.text("rel_path")!, artistDir: r.text("artist_dir")!, albumDir: r.text("album_dir")!,
                   ext: r.text("ext")!, kind: FileKind(rawValue: r.text("kind")!) ?? .other, codec: r.text("codec"),
                   size: r.int("size")!, mtime: r.double("mtime")!, stableSince: r.double("stable_since")!,
                   observations: Int(r.int("observations") ?? 1), firstSeen: r.double("first_seen")!, lastSeenScan: r.int("last_seen_scan")!,
                   status: FileStatus(rawValue: r.text("status")!) ?? .active, missingSince: r.double("missing_since"),
                   audioMD5: r.text("audio_md5"), tagHash: r.text("tag_hash"), tagArtist: r.text("tag_artist"),
                   tagAlbumArtist: r.text("tag_albumartist"), tagAlbum: r.text("tag_album"),
                   hasMBID: r.int("has_mbid").map { $0 != 0 }, tagTitle: r.text("tag_title"), tagTrack: r.int("tag_track").map(Int.init),
                   tagDisc: r.int("tag_disc").map(Int.init), tagDiscTotal: r.int("tag_disctotal").map(Int.init), tagYear: r.int("tag_year").map(Int.init),
                   mbidRelease: r.text("mbid_release"))
    }

    /// Files whose tags have never been audited, or changed since they were.
    public func filesNeedingTagAudit(limit: Int = 2000) throws -> [SourceFile] {
        try db.query("""
            SELECT * FROM source_files WHERE status='active' AND kind != 'other'
              AND (tag_audit_at IS NULL OR stable_since > tag_audit_at) ORDER BY artist_dir, album_dir, rel_path LIMIT ?
            """, [.integer(Int64(limit))], Store.sourceFile)
    }

    public func recordTagAudit(id: Int64, info: AudioFileInfo, now: Double) throws {
        let mbid = info.first("MUSICBRAINZ_ALBUMID") ?? info.first("MUSICBRAINZ_RELEASEGROUPID")
        let hasMBID = mbid != nil || info.first("MUSICBRAINZ_TRACKID") != nil || info.first("MUSICBRAINZ_RELEASETRACKID") != nil
        let year = (info.first("ORIGINALYEAR") ?? info.first("DATE") ?? info.first("ORIGINALDATE")).flatMap { Int($0.prefix(4)) }
        func num(_ k: String) -> Int? { info.first(k).flatMap { Int($0.split(separator: "/").first.map(String.init) ?? "") } }
        let discTotal = info.first("DISCTOTAL").flatMap { Int($0) } ?? info.first("DISCNUMBER").flatMap { $0.contains("/") ? Int($0.split(separator: "/").last!) : nil }
        try db.run("""
            UPDATE source_files SET has_mbid=?, tag_audit_at=?, tag_title=?, tag_artist=?, tag_albumartist=?, tag_album=?,
                   tag_track=?, tag_disc=?, tag_disctotal=?, tag_year=?, mbid_release=? WHERE id=?
            """, [.integer(hasMBID ? 1 : 0), .real(now), Database.Value(info.title), Database.Value(info.artist),
                  Database.Value(info.albumArtist ?? info.artist), Database.Value(info.album),
                  Database.Value(num("TRACKNUMBER")), Database.Value(num("DISCNUMBER")), Database.Value(discTotal), Database.Value(year),
                  Database.Value(info.first("MUSICBRAINZ_ALBUMID")), .integer(id)])
    }

    /// Deterministic folder for a release: first come, first served; a different release that would collide gets " [2]".
    public func albumFolder(releaseKey: String, preferred: String, now: Double = Date().timeIntervalSince1970) throws -> String {
        let existing: String? = { if case let .text(f)? = try? db.scalar("SELECT folder FROM album_folders WHERE release_key=?", [.text(releaseKey)]) { return f }; return nil }()
        // A registered folder stays put while it is still the preferred name (or a collision variant of it), so suffixes are stable.
        // When the preferred name itself changes (naming policy, retagged album) the release is re-registered under the new name.
        if let existing, existing == preferred || (existing.hasPrefix(preferred + " [") && existing.hasSuffix("]")) { return existing }
        var candidate = preferred; var n = 2
        while try db.scalar("SELECT COUNT(*) FROM album_folders WHERE folder=? AND release_key<>?", [.text(candidate), .text(releaseKey)]) != .integer(0) { candidate = preferred + " [\(n)]"; n += 1 }
        if existing != nil {
            try db.run("UPDATE album_folders SET folder=? WHERE release_key=?", [.text(candidate), .text(releaseKey)])
        } else {
            try db.run("INSERT INTO album_folders (release_key, folder, created_at) VALUES (?,?,?)", [.text(releaseKey), .text(candidate), .real(now)])
        }
        return candidate
    }

    // MARK: Outputs

    /// All outputs for an album's sources in one query (the planner used to ask per track).
    public func outputs(in album: AlbumKey) throws -> [Int64: OutputFile] {
        let rows = try db.query("""
            SELECT o.* FROM outputs o JOIN source_files s ON s.id = o.source_id WHERE s.artist_dir=? AND s.album_dir=?
            """, [.text(album.artistDir), .text(album.albumDir)], Store.output)
        return Dictionary(rows.map { ($0.sourceID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func output(forSource id: Int64) throws -> OutputFile? {
        try db.query("SELECT * FROM outputs WHERE source_id=?", [.integer(id)], Store.output).first
    }

    static func output(_ r: Database.Row) -> OutputFile {
        OutputFile(id: r.int("id")!, sourceID: r.int("source_id")!, relPath: r.text("rel_path")!, size: r.int("size"),
                   encoderProfile: r.text("encoder_profile")!, audioMD5: r.text("audio_md5"), tagHash: r.text("tag_hash"),
                   verifyOK: (r.int("verify_ok") ?? 0) != 0, musicPersistentID: r.text("music_persistent_id"),
                   encodedAt: r.double("encoded_at"), tagsWrittenAt: r.double("tags_written_at"), tagPolicy: Int(r.int("tag_policy") ?? 0))
    }

    /// An output whose source has gone missing but whose audio matches — the signature of a rename/move.
    public func orphanedOutput(audioMD5: String) throws -> (OutputFile, SourceFile)? {
        try db.query("""
            SELECT o.*, s.rel_path s_rel FROM outputs o JOIN source_files s ON s.id = o.source_id
            WHERE s.status='missing' AND o.audio_md5=? LIMIT 1
            """, [.text(audioMD5)]) { r -> (OutputFile, SourceFile)? in
            guard let src = try? self.sourceFile(relPath: r.text("s_rel")!) else { return nil }
            return (Store.output(r), src)
        }.compactMap { $0 }.first
    }

    /// Counts one more full scan of confirmed absence for everything still missing after `scanID`.
    public func bumpMissingScans(notSeenIn scanID: Int64) throws {
        try db.run("UPDATE source_files SET missing_full_scans = missing_full_scans + 1 WHERE status='missing' AND last_seen_scan < ?", [.integer(scanID)])
    }

    // MARK: Proposals

    public struct ProposalItem: Codable, Equatable, Sendable {
        public var outputID: Int64?
        public var legacyID: Int64?
        public var relPath: String          // relative to the mirror root (remove) or the legacy media root (supersede)
        public var musicPersistentID: String?
        public var bytes: Int64
        public var counterpartPersistentID: String?   // supersede: the mirror track that inherits play counts
    }

    public struct Proposal: Codable, Equatable, Sendable, Identifiable {
        public var id: Int64
        public var kind: String
        public var artistDir: String, albumDir: String
        public var title: String, reason: String
        public var items: [ProposalItem]
        public var bytes: Int64
        public var createdAt: Double
        public var state: String
        public var decidedAt: Double?, doneAt: Double?, error: String?
    }

    public func insertProposal(kind: String, album: AlbumKey, title: String, reason: String, items: [ProposalItem], now: Double) throws -> Int64 {
        let json = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
        return try db.insert("INSERT INTO proposals (kind, artist_dir, album_dir, title, reason, items_json, bytes, created_at) VALUES (?,?,?,?,?,?,?,?)",
                             [.text(kind), .text(album.artistDir), .text(album.albumDir), .text(title), .text(reason), .text(json),
                              .integer(items.reduce(0) { $0 + $1.bytes }), .real(now)])
    }

    public func proposals(states: [String] = ["pending", "approved"]) throws -> [Proposal] {
        let marks = states.map { _ in "?" }.joined(separator: ",")
        return try db.query("SELECT * FROM proposals WHERE state IN (\(marks)) ORDER BY created_at DESC", states.map { .text($0) }, Store.proposal)
    }

    public func proposal(id: Int64) throws -> Proposal? { try db.query("SELECT * FROM proposals WHERE id=?", [.integer(id)], Store.proposal).first }

    public func setProposalState(_ id: Int64, _ state: String, error: String? = nil, now: Double = Date().timeIntervalSince1970) throws {
        let col = state == "done" || state == "failed" ? "done_at" : "decided_at"
        try db.run("UPDATE proposals SET state=?, \(col)=?, error=? WHERE id=?", [.text(state), .real(now), Database.Value(error), .integer(id)])
    }

    /// Output ids already covered by a live proposal (pending/approved) or an explicit dismissal.
    public func outputIDsCoveredByProposals() throws -> Set<Int64> {
        var ids: Set<Int64> = []
        for p in try proposals(states: ["pending", "approved", "dismissed"]) { for i in p.items { if let o = i.outputID { ids.insert(o) } } }
        return ids
    }

    static func proposal(_ r: Database.Row) -> Proposal {
        let items = (try? JSONDecoder().decode([ProposalItem].self, from: Data((r.text("items_json") ?? "[]").utf8))) ?? []
        return Proposal(id: r.int("id")!, kind: r.text("kind")!, artistDir: r.text("artist_dir")!, albumDir: r.text("album_dir")!,
                        title: r.text("title")!, reason: r.text("reason")!, items: items, bytes: r.int("bytes") ?? 0,
                        createdAt: r.double("created_at")!, state: r.text("state")!, decidedAt: r.double("decided_at"), doneAt: r.double("done_at"), error: r.text("error"))
    }

    // MARK: Pins

    public func pinnedArtists() throws -> Set<String> {
        Set(try db.query("SELECT artist_dir FROM pins") { $0.text(0)! })
    }
    public func pin(_ artistDir: String, pinned: Bool, now: Double = Date().timeIntervalSince1970) throws {
        if pinned { try db.run("INSERT OR IGNORE INTO pins (artist_dir, pinned_at) VALUES (?, ?)", [.text(artistDir), .real(now)]) }
        else { try db.run("DELETE FROM pins WHERE artist_dir=?", [.text(artistDir)]) }
    }

    // MARK: Learned throughput

    public struct Throughput: Equatable, Sendable {
        public var bytesPerSecond: Double
        public var batches: Int        // finished batches the figure is based on
        public var newestAt: Double    // finished_at of the most recent one
    }

    /// The real end-to-end rate this installation achieves: bytes of source processed per second of batch wall time,
    /// covering share reads, encoding, tagging, verification and publishing. Learned from finished batches and weighted
    /// toward the newest ones, so a network change shows up in the estimate after a batch or two. Tiny batches
    /// (under 100 MB or 20 s) are noise and ignored. nil until at least one real batch has finished.
    public func learnedThroughput(limit: Int = 12, decay: Double = 0.6) throws -> Throughput? {
        let rows = try db.query("""
            SELECT bytes_in, finished_at - started_at, finished_at FROM batches
            WHERE finished_at IS NOT NULL AND bytes_in >= 100000000 AND finished_at - started_at >= 20
            ORDER BY id DESC LIMIT ?
            """, [.integer(Int64(limit))]) { ($0.int(0)!, $0.double(1)!, $0.double(2)!) }
        guard !rows.isEmpty else { return nil }
        // Weighted mean of each batch's own rate (not of totals), so one long slow batch cannot dominate several
        // fast recent ones — the estimate follows a network change after a batch or two.
        var sum = 0.0, weights = 0.0, weight = 1.0
        for (b, s, _) in rows { sum += Double(b) / s * weight; weights += weight; weight *= decay }
        return Throughput(bytesPerSecond: sum / weights, batches: rows.count, newestAt: rows[0].2)
    }

    // MARK: Ignored albums

    public func ignoredAlbums() throws -> Set<AlbumKey> {
        Set(try db.query("SELECT artist_dir, album_dir FROM ignored_albums") { AlbumKey(artistDir: $0.text(0)!, albumDir: $0.text(1)!) })
    }
    /// An ignored album is left out of every plan, the backlog and the needs-tagging counts, and out of its artist's
    /// totals (so an artist whose only unmirrored albums are ignored shows as complete). Its mirror copies are untouched.
    public func ignore(_ key: AlbumKey, ignored: Bool, now: Double = Date().timeIntervalSince1970) throws {
        if ignored { try db.run("INSERT OR IGNORE INTO ignored_albums (artist_dir, album_dir, ignored_at) VALUES (?,?,?)", [.text(key.artistDir), .text(key.albumDir), .real(now)]) }
        else { try db.run("DELETE FROM ignored_albums WHERE artist_dir=? AND album_dir=?", [.text(key.artistDir), .text(key.albumDir)]) }
    }

    // MARK: Aggregates for the planner and the picker

    public struct AlbumSummary: Equatable, Sendable {
        public var key: AlbumKey
        public var tracks: Int
        public var bytes: Int64
        public var losslessTracks: Int
        public var lossyTracks: Int
        public var mirrored: Int          // tracks with a verified output
        public var stale: Int             // mirrored tracks whose source changed after the output was written
        public var firstSeen: Double      // earliest first_seen in the album
        public var lastChange: Double     // latest stable_since in the album
        public var minObservations: Int
        public var displayArtist: String? // from tags when known
        public var displayAlbum: String?
        public var untagged: Int = 0      // tracks audited and found without MusicBrainz IDs
        public var unaudited: Int = 0     // tracks not yet audited
        public var ignored: Bool = false  // user chose to leave this album out
    }

    public func albumSummaries(artist: String? = nil) throws -> [AlbumSummary] {
        var sql = """
            SELECT s.artist_dir, s.album_dir, COUNT(*) tracks, SUM(s.size) bytes,
                   SUM(CASE WHEN s.kind='lossless' THEN 1 ELSE 0 END) lossless,
                   SUM(CASE WHEN s.kind='lossy' THEN 1 ELSE 0 END) lossy,
                   SUM(CASE WHEN o.id IS NOT NULL THEN 1 ELSE 0 END) mirrored,
                   MIN(s.first_seen) first_seen, MAX(s.stable_since) last_change, MIN(s.observations) min_obs,
                   MAX(s.tag_albumartist) tag_aa, MAX(s.tag_album) tag_album,
                   SUM(CASE WHEN o.id IS NOT NULL AND ((COALESCE(o.tags_written_at, o.encoded_at) IS NOT NULL AND s.stable_since > COALESCE(o.tags_written_at, o.encoded_at)) OR o.tag_policy < \(TagPolicy.version)) THEN 1 ELSE 0 END) stale,
                   SUM(CASE WHEN s.has_mbid = 0 THEN 1 ELSE 0 END) untagged,
                   SUM(CASE WHEN s.has_mbid IS NULL THEN 1 ELSE 0 END) unaudited,
                   (i.artist_dir IS NOT NULL) ignored
            FROM source_files s
            LEFT JOIN outputs o ON o.source_id = s.id AND o.verify_ok = 1
            LEFT JOIN ignored_albums i ON i.artist_dir = s.artist_dir AND i.album_dir = s.album_dir
            WHERE s.status='active' AND s.kind != 'other'
            """
        var params: [Database.Value] = []
        if let artist { sql += " AND s.artist_dir=?"; params.append(.text(artist)) }
        sql += " GROUP BY s.artist_dir, s.album_dir ORDER BY s.artist_dir, s.album_dir"
        return try db.query(sql, params) { r in
            AlbumSummary(key: AlbumKey(artistDir: r.text(0)!, albumDir: r.text(1)!), tracks: Int(r.int(2)!), bytes: r.int(3)!,
                         losslessTracks: Int(r.int(4)!), lossyTracks: Int(r.int(5)!), mirrored: Int(r.int(6)!), stale: Int(r.int(12) ?? 0),
                         firstSeen: r.double(7)!, lastChange: r.double(8)!, minObservations: Int(r.int(9)!),
                         displayArtist: r.text(10), displayAlbum: r.text(11), untagged: Int(r.int(13) ?? 0), unaudited: Int(r.int(14) ?? 0),
                         ignored: (r.int(15) ?? 0) != 0)
        }
    }

    public struct ArtistSummary: Equatable, Sendable {
        public var artistDir: String
        public var displayName: String
        public var albums: Int
        public var tracks: Int
        public var bytes: Int64
        public var mirrored: Int
        public var pinned: Bool
        public var untagged: Int = 0
        public var stale: Int = 0
        public var status: String { mirrored == 0 ? "none" : (mirrored == tracks ? "complete" : "partial") }
    }

    public func artistSummaries() throws -> [ArtistSummary] {
        let pins = try pinnedArtists()
        return try db.query("""
            SELECT s.artist_dir, COUNT(DISTINCT s.album_dir) albums, COUNT(*) tracks, SUM(s.size) bytes,
                   SUM(CASE WHEN o.id IS NOT NULL THEN 1 ELSE 0 END) mirrored,
                   SUM(CASE WHEN s.has_mbid = 0 THEN 1 ELSE 0 END) untagged,
                   SUM(CASE WHEN o.id IS NOT NULL AND ((COALESCE(o.tags_written_at, o.encoded_at) IS NOT NULL AND s.stable_since > COALESCE(o.tags_written_at, o.encoded_at)) OR o.tag_policy < \(TagPolicy.version)) THEN 1 ELSE 0 END) stale
            FROM source_files s
            LEFT JOIN outputs o ON o.source_id = s.id AND o.verify_ok = 1
            LEFT JOIN ignored_albums i ON i.artist_dir = s.artist_dir AND i.album_dir = s.album_dir
            WHERE s.status='active' AND s.kind != 'other' AND i.artist_dir IS NULL
            GROUP BY s.artist_dir ORDER BY s.artist_dir COLLATE NOCASE
            """) { r in
            let dir = r.text(0)!
            // The artist folder is the unit the user picks and the mirror keeps, so it is also the display name (album-artist
            // tags vary per album: collaborations, mis-filed albums) and the sort key.
            return ArtistSummary(artistDir: dir, displayName: dir, albums: Int(r.int(1)!), tracks: Int(r.int(2)!),
                                 bytes: r.int(3)!, mirrored: Int(r.int(4)!), pinned: pins.contains(dir), untagged: Int(r.int(5) ?? 0), stale: Int(r.int(6) ?? 0))
        }
    }

    public struct Counts: Equatable, Sendable {
        public var active: Int, missing: Int, lossless: Int, lossy: Int, bytes: Int64, mirrored: Int, artists: Int, albums: Int, directories: Int
    }

    public func counts() throws -> Counts {
        let r = try db.query("""
            SELECT SUM(status='active'), SUM(status='missing'),
                   SUM(status='active' AND kind='lossless'), SUM(status='active' AND kind='lossy'),
                   COALESCE(SUM(CASE WHEN status='active' THEN size ELSE 0 END),0),
                   COUNT(DISTINCT CASE WHEN status='active' THEN artist_dir END),
                   COUNT(DISTINCT CASE WHEN status='active' THEN artist_dir || '/' || album_dir END)
            FROM source_files
            """) { r in (r.int(0) ?? 0, r.int(1) ?? 0, r.int(2) ?? 0, r.int(3) ?? 0, r.int(4) ?? 0, r.int(5) ?? 0, r.int(6) ?? 0) }[0]
        let mirrored = try db.scalar("SELECT COUNT(*) FROM outputs WHERE verify_ok=1")
        let dirs = try db.scalar("SELECT COUNT(*) FROM directories WHERE status='active'")
        func i(_ v: Database.Value?) -> Int { if case let .integer(x)? = v { return Int(x) }; return 0 }
        return Counts(active: Int(r.0), missing: Int(r.1), lossless: Int(r.2), lossy: Int(r.3), bytes: r.4, mirrored: i(mirrored),
                      artists: Int(r.5), albums: Int(r.6), directories: i(dirs))
    }

    // MARK: Activity log

    public func log(_ level: String, _ category: String, _ message: String, relPath: String? = nil, jobID: Int64? = nil,
                    now: Double = Date().timeIntervalSince1970) throws {
        try db.run("INSERT INTO activity (at, level, category, message, rel_path, job_id) VALUES (?,?,?,?,?,?)",
                   [.real(now), .text(level), .text(category), .text(message), Database.Value(relPath), Database.Value(jobID)])
    }

    static func likePrefix(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}
