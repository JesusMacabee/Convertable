import Foundation

/// Detects work that should not happen silently — removing mirror files, superseding legacy copies —
/// and turns it into proposals. Approved proposals move files to a dated quarantine, never delete.
public struct Reviewer {
    public let store: Store
    public let mirrorRoot: String
    public var clock: () -> Double = { Date().timeIntervalSince1970 }

    public init(store: Store, mirrorRoot: String) { self.store = store; self.mirrorRoot = mirrorRoot }

    /// Sources missing across at least two full scans → one "remove" proposal per album.
    @discardableResult
    public func detectOrphans(minimumFullScans: Int = 2) throws -> Int {
        let covered = try store.outputIDsCoveredByProposals()
        let rows = try store.db.query("""
            SELECT o.id o_id, o.rel_path o_rel, o.size o_size, o.music_persistent_id o_pid, s.artist_dir, s.album_dir, s.rel_path s_rel, s.missing_since, s.missing_full_scans
            FROM outputs o JOIN source_files s ON s.id = o.source_id
            WHERE s.status='missing' AND s.missing_full_scans >= ?
            ORDER BY s.artist_dir, s.album_dir, s.rel_path
            """, [.integer(Int64(minimumFullScans))]) { r in
            (id: r.int("o_id")!, rel: r.text("o_rel")!, size: r.int("o_size") ?? 0, pid: r.text("o_pid"),
             key: AlbumKey(artistDir: r.text("artist_dir")!, albumDir: r.text("album_dir")!), srel: r.text("s_rel")!,
             since: r.double("missing_since") ?? 0, scans: Int(r.int("missing_full_scans") ?? 0))
        }.filter { !covered.contains($0.id) }
        var byAlbum: [AlbumKey: [(id: Int64, rel: String, size: Int64, pid: String?, key: AlbumKey, srel: String, since: Double, scans: Int)]] = [:]
        for r in rows { byAlbum[r.key, default: []].append(r) }
        var created = 0
        for (key, items) in byAlbum.sorted(by: { $0.key < $1.key }) {
            let since = Date(timeIntervalSince1970: items.map(\.since).min() ?? clock())
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
            let total = try store.sourceFiles(in: key, includeMissing: true).count
            let title = items.count == total ? "Remove album from mirror" : "Remove \(items.count) of \(total) tracks from mirror"
            let reason = "Source \(items.count == 1 ? "file" : "files") missing since \(df.string(from: since)), confirmed by \(items.map(\.scans).min() ?? 0) full scans."
            _ = try store.insertProposal(kind: "remove", album: key, title: title, reason: reason,
                                         items: items.map { .init(outputID: $0.id, legacyID: nil, relPath: $0.rel, musicPersistentID: $0.pid, bytes: $0.size, counterpartPersistentID: nil) },
                                         now: clock())
            created += 1
        }
        return created
    }

    /// A pending proposal whose sources came back (or whose outputs were re-pointed by a move) is withdrawn automatically.
    @discardableResult
    public func withdrawStaleProposals() throws -> Int {
        var n = 0
        for p in try store.proposals(states: ["pending"]) where p.kind == "remove" {
            var stillMissing = 0
            for i in p.items {
                guard let oid = i.outputID else { continue }
                let missing = try store.db.scalar("SELECT COUNT(*) FROM outputs o JOIN source_files s ON s.id=o.source_id WHERE o.id=? AND s.status='missing'", [.integer(oid)])
                if missing == .integer(1) { stillMissing += 1 }
            }
            if stillMissing == 0 {
                try store.setProposalState(p.id, "dismissed", error: "withdrawn: source reappeared or was moved", now: clock())
                try? store.log("info", "review", "withdrew proposal #\(p.id) (\(p.title)) — source is back", relPath: p.artistDir + "/" + p.albumDir)
                n += 1
            }
        }
        return n
    }

    public func quarantineDir(now: Double? = nil) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return mirrorRoot + "/.quarantine/" + df.string(from: Date(timeIntervalSince1970: now ?? clock()))
    }

    /// Applies an approved "remove" proposal: quarantine the mirror files and drop the rows.
    /// Music-side removals happen when the library is open (see MusicImporter.processApproved); until then
    /// the proposal stays "approved" carrying the persistent IDs still to remove.
    public func applyRemove(_ p: Store.Proposal, shareIO: ShareIO) async throws -> [Store.ProposalItem] {
        var musicPending: [Store.ProposalItem] = []
        let qdir = quarantineDir()
        for item in p.items {
            let src = mirrorRoot + "/" + item.relPath
            if await shareIO.exists(src) {
                try await shareIO.move(from: src, to: qdir + "/" + item.relPath)
            }
            if let oid = item.outputID {
                let sid = try store.db.scalar("SELECT source_id FROM outputs WHERE id=?", [.integer(oid)])
                try store.db.run("DELETE FROM outputs WHERE id=?", [.integer(oid)])
                if case let .integer(s)? = sid { try store.db.run("DELETE FROM source_files WHERE id=? AND status='missing'", [.integer(s)]) }
            }
            if item.musicPersistentID != nil { musicPending.append(item) }
            try? store.log("info", "review", "quarantined \(item.relPath)", relPath: item.relPath)
        }
        return musicPending
    }

    /// Deletes quarantine folders older than the retention period. The only place Convertable deletes anything.
    public func purgeQuarantine(retentionDays: Int, shareIO: ShareIO) async -> Int {
        let root = mirrorRoot + "/.quarantine"
        guard let days = try? FileManager.default.contentsOfDirectory(atPath: root) else { return 0 }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let cutoff = Date(timeIntervalSince1970: clock()).addingTimeInterval(-Double(retentionDays) * 86400)
        var n = 0
        for d in days {
            guard let date = df.date(from: d), date < cutoff else { continue }
            if (try? await shareIO.remove(root + "/" + d)) != nil { n += 1; try? store.log("info", "review", "purged quarantine \(d)") }
        }
        return n
    }
}
