import Foundation

/// Typed access to the state database. One instance per Database; callers serialize.
public final class Store {
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
        try db.run("INSERT INTO scans (kind, started_at) VALUES (?, ?)", [.text(kind.rawValue), .real(now)])
        return ScanRecord(id: db.lastInsertRowID, kind: kind, startedAt: now, finishedAt: nil, dirsSeen: 0, filesSeen: 0, checkpoint: nil)
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
                   tagAlbumArtist: r.text("tag_albumartist"), tagAlbum: r.text("tag_album"))
    }

    // MARK: Outputs

    public func output(forSource id: Int64) throws -> OutputFile? {
        try db.query("SELECT * FROM outputs WHERE source_id=?", [.integer(id)]) { r in
            OutputFile(id: r.int("id")!, sourceID: r.int("source_id")!, relPath: r.text("rel_path")!, size: r.int("size"),
                       encoderProfile: r.text("encoder_profile")!, audioMD5: r.text("audio_md5"), tagHash: r.text("tag_hash"),
                       verifyOK: (r.int("verify_ok") ?? 0) != 0, musicPersistentID: r.text("music_persistent_id"))
        }.first
    }

    // MARK: Pins

    public func pinnedArtists() throws -> Set<String> {
        Set(try db.query("SELECT artist_dir FROM pins") { $0.text(0)! })
    }
    public func pin(_ artistDir: String, pinned: Bool, now: Double = Date().timeIntervalSince1970) throws {
        if pinned { try db.run("INSERT OR IGNORE INTO pins (artist_dir, pinned_at) VALUES (?, ?)", [.text(artistDir), .real(now)]) }
        else { try db.run("DELETE FROM pins WHERE artist_dir=?", [.text(artistDir)]) }
    }

    // MARK: Aggregates for the planner and the picker

    public struct AlbumSummary: Equatable, Sendable {
        public var key: AlbumKey
        public var tracks: Int
        public var bytes: Int64
        public var losslessTracks: Int
        public var lossyTracks: Int
        public var mirrored: Int          // tracks with a verified output
        public var firstSeen: Double      // earliest first_seen in the album
        public var lastChange: Double     // latest stable_since in the album
        public var minObservations: Int
        public var displayArtist: String? // from tags when known
        public var displayAlbum: String?
    }

    public func albumSummaries(artist: String? = nil) throws -> [AlbumSummary] {
        var sql = """
            SELECT s.artist_dir, s.album_dir, COUNT(*) tracks, SUM(s.size) bytes,
                   SUM(CASE WHEN s.kind='lossless' THEN 1 ELSE 0 END) lossless,
                   SUM(CASE WHEN s.kind='lossy' THEN 1 ELSE 0 END) lossy,
                   SUM(CASE WHEN o.id IS NOT NULL THEN 1 ELSE 0 END) mirrored,
                   MIN(s.first_seen) first_seen, MAX(s.stable_since) last_change, MIN(s.observations) min_obs,
                   MAX(s.tag_albumartist) tag_aa, MAX(s.tag_album) tag_album
            FROM source_files s
            LEFT JOIN outputs o ON o.source_id = s.id AND o.verify_ok = 1
            WHERE s.status='active' AND s.kind != 'other'
            """
        var params: [Database.Value] = []
        if let artist { sql += " AND s.artist_dir=?"; params.append(.text(artist)) }
        sql += " GROUP BY s.artist_dir, s.album_dir ORDER BY s.artist_dir, s.album_dir"
        return try db.query(sql, params) { r in
            AlbumSummary(key: AlbumKey(artistDir: r.text(0)!, albumDir: r.text(1)!), tracks: Int(r.int(2)!), bytes: r.int(3)!,
                         losslessTracks: Int(r.int(4)!), lossyTracks: Int(r.int(5)!), mirrored: Int(r.int(6)!),
                         firstSeen: r.double(7)!, lastChange: r.double(8)!, minObservations: Int(r.int(9)!),
                         displayArtist: r.text(10), displayAlbum: r.text(11))
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
        public var status: String { mirrored == 0 ? "none" : (mirrored == tracks ? "complete" : "partial") }
    }

    public func artistSummaries() throws -> [ArtistSummary] {
        let pins = try pinnedArtists()
        return try db.query("""
            SELECT s.artist_dir, COUNT(DISTINCT s.album_dir) albums, COUNT(*) tracks, SUM(s.size) bytes,
                   SUM(CASE WHEN o.id IS NOT NULL THEN 1 ELSE 0 END) mirrored, MAX(s.tag_albumartist) tag_aa
            FROM source_files s
            LEFT JOIN outputs o ON o.source_id = s.id AND o.verify_ok = 1
            WHERE s.status='active' AND s.kind != 'other'
            GROUP BY s.artist_dir ORDER BY s.artist_dir COLLATE NOCASE
            """) { r in
            let dir = r.text(0)!
            return ArtistSummary(artistDir: dir, displayName: r.text(5) ?? dir, albums: Int(r.int(1)!), tracks: Int(r.int(2)!),
                                 bytes: r.int(3)!, mirrored: Int(r.int(4)!), pinned: pins.contains(dir))
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
