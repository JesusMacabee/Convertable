import Foundation

/// Text normalisation for matching albums across two differently tagged collections.
public enum Norm {
    static let junk: [String] = ["deluxe edition", "deluxe version", "deluxe", "expanded edition", "remastered", "remaster", "explicit", "clean", "bonus track version", "special edition", "anniversary edition"]
    public static func key(_ s: String?) -> String {
        guard var t = s?.lowercased() else { return "" }
        t = t.applyingTransform(.stripDiacritics, reverse: false) ?? t
        t = t.replacingOccurrences(of: "&", with: " and ")
        // Drop bracketed edition qualifiers and known junk words.
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        for j in junk { t = t.replacingOccurrences(of: j, with: " ") }
        t = t.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("the ") { t = String(t.dropFirst(4)) }
        return t.replacingOccurrences(of: " ", with: "")
    }
    public static func trackNumber(_ s: String?) -> Int? { s.flatMap { Int($0.prefix { $0.isNumber }) } }
}

/// Reads tags from the legacy library into `legacy_files`. Incremental: unchanged files (path+size+mtime) are skipped,
/// so a 12k-file first pass is the only slow one.
public struct LegacyIndexer {
    public let store: Store
    public let roots: [String]
    public var onProgress: ((Int, Int) -> Void)?

    public init(store: Store, roots: [String]) { self.store = store; self.roots = roots }

    public struct Result: Sendable { public var seen = 0, indexed = 0, removed = 0 }

    public func run(shareIO: ShareIO, isCancelled: @escaping () -> Bool = { false }) async throws -> Result {
        var res = Result()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var seenPaths: Set<String> = []
        for root in roots where fm.fileExists(atPath: root) {
            guard let it = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in it {
                if isCancelled() { return res }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let ext = "." + url.pathExtension.lowercased()
                guard Classifier.isAudio(ext) else { continue }
                res.seen += 1
                let rel = String(url.path.dropFirst(root.count + 1))
                seenPaths.insert(root + "/" + rel)
                let size = Int64(v.fileSize ?? 0), mtime = v.contentModificationDate?.timeIntervalSince1970 ?? 0
                let existing = try store.db.query("SELECT size, mtime FROM legacy_files WHERE root=? AND rel_path=?", [.text(root), .text(rel)]) { ($0.int(0)!, $0.double(1) ?? 0) }.first
                if let e = existing, e.0 == size, abs(e.1 - mtime) < 0.001 { continue }
                let path = url.path
                guard let info = try? await shareIO.perform("legacy-tags", { try TagReader.read(path) }) else { continue }
                try store.db.run("""
                    INSERT INTO legacy_files (root, rel_path, size, mtime, album_artist_norm, album_norm, title_norm, track_no, disc_no, duration_ms, title, album_artist, album, indexed_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(rel_path) DO UPDATE SET root=excluded.root, size=excluded.size, mtime=excluded.mtime, album_artist_norm=excluded.album_artist_norm,
                        album_norm=excluded.album_norm, title_norm=excluded.title_norm, track_no=excluded.track_no, disc_no=excluded.disc_no,
                        duration_ms=excluded.duration_ms, title=excluded.title, album_artist=excluded.album_artist, album=excluded.album, indexed_at=excluded.indexed_at
                    """, [.text(root), .text(rel), .integer(size), .real(mtime),
                          .text(Norm.key(info.albumArtist ?? info.artist)), .text(Norm.key(info.album)), .text(Norm.key(info.title)),
                          Database.Value(Norm.trackNumber(info.first("TRACKNUMBER"))), Database.Value(Norm.trackNumber(info.first("DISCNUMBER"))),
                          .integer(Int64(info.lengthMs)), Database.Value(info.title), Database.Value(info.albumArtist ?? info.artist), Database.Value(info.album),
                          .real(Date().timeIntervalSince1970)])
                res.indexed += 1
                if res.indexed % 100 == 0 { onProgress?(res.seen, res.indexed) }
            }
        }
        // Legacy rows whose files are gone (and that we did not quarantine ourselves) are dropped.
        let rows = try store.db.query("SELECT id, root, rel_path FROM legacy_files WHERE superseded_at IS NULL") { ($0.int(0)!, $0.text(1)!, $0.text(2)!) }
        for (id, root, rel) in rows where roots.contains(root) && !seenPaths.contains(root + "/" + rel) {
            try store.db.run("DELETE FROM legacy_files WHERE id=?", [.integer(id)]); res.removed += 1
        }
        return res
    }
}

/// Finds legacy albums that a completed mirror album makes redundant, and proposes replacing them.
public struct SupersedeMatcher {
    public let store: Store
    public let profile: Profile
    public var clock: () -> Double = { Date().timeIntervalSince1970 }

    public init(store: Store, profile: Profile) { self.store = store; self.profile = profile }

    struct LegacyRow { let id: Int64, root: String, rel: String, size: Int64, titleNorm: String, track: Int?, disc: Int?, durationMs: Int64, pid: String? }

    @discardableResult
    public func run() throws -> Int {
        var created = 0
        var covered = try coveredLegacyIDs()
        // Mirror albums: complete, with tags known.
        let albums = try store.albumSummaries().filter { $0.mirrored == $0.tracks && $0.tracks > 0 && $0.displayArtist != nil && $0.displayAlbum != nil }
        for a in albums {
            let aa = Norm.key(a.displayArtist), al = Norm.key(a.displayAlbum)
            guard !aa.isEmpty, !al.isEmpty else { continue }
            let legacy = try store.db.query("""
                SELECT id, root, rel_path, size, title_norm, track_no, disc_no, duration_ms, music_persistent_id FROM legacy_files
                WHERE album_artist_norm=? AND album_norm=? AND superseded_at IS NULL ORDER BY disc_no, track_no
                """, [.text(aa), .text(al)]) { r in
                LegacyRow(id: r.int(0)!, root: r.text(1)!, rel: r.text(2)!, size: r.int(3) ?? 0, titleNorm: r.text(4) ?? "", track: r.int(5).map(Int.init),
                          disc: r.int(6).map(Int.init), durationMs: r.int(7) ?? 0, pid: r.text(8))
            }.filter { !covered.contains($0.id) }
            guard !legacy.isEmpty else { continue }
            // Mirror tracks with their tags and Music IDs.
            let mirror = try store.db.query("""
                SELECT s.rel_path, o.music_persistent_id, s.tag_hash FROM source_files s JOIN outputs o ON o.source_id=s.id
                WHERE s.artist_dir=? AND s.album_dir=? AND s.status='active' AND o.verify_ok=1 ORDER BY s.rel_path
                """, [.text(a.key.artistDir), .text(a.key.albumDir)]) { ($0.text(0)!, $0.text(1)) }
            // Confidence: track counts within one, and most legacy titles present among the mirror's file names / titles.
            let countOK = abs(legacy.count - mirror.count) <= 1
            let mirrorTitles = Set(mirror.map { Norm.key(($0.0 as NSString).lastPathComponent) })
            let titleHits = legacy.filter { l in mirrorTitles.contains { $0.contains(l.titleNorm) && !l.titleNorm.isEmpty } }.count
            let ratio = Double(titleHits) / Double(max(1, legacy.count))
            let confident = countOK && ratio >= 0.6
            let title = confident ? "Replace legacy AAC copies with the mirror" : "Possible legacy duplicate — check before approving"
            let reason = "Legacy album “\(a.displayArtist!) — \(a.displayAlbum!)”: \(legacy.count) legacy tracks vs \(mirror.count) mirrored; \(titleHits) title matches\(legacy.first?.pid == nil ? "; legacy tracks not yet mapped to Music" : "")."
            // Counterparts by track number order when counts line up.
            let items: [Store.ProposalItem] = legacy.enumerated().map { i, l in
                let counterpart = (countOK && i < mirror.count) ? mirror[i].1 : nil
                return .init(outputID: nil, legacyID: l.id, relPath: l.root + "/" + l.rel, musicPersistentID: l.pid, bytes: l.size, counterpartPersistentID: counterpart)
            }
            _ = try store.insertProposal(kind: "supersede", album: a.key, title: title, reason: reason, items: items, now: clock())
            covered.formUnion(legacy.map(\.id))   // one proposal per legacy album, even when several mirror editions match it
            created += 1
        }
        return created
    }

    func coveredLegacyIDs() throws -> Set<Int64> {
        var ids: Set<Int64> = []
        for p in try store.proposals(states: ["pending", "approved", "dismissed"]) where p.kind == "supersede" { for i in p.items { if let l = i.legacyID { ids.insert(l) } } }
        return ids
    }

    /// Maps Music's tracks under the legacy roots onto legacy rows (needs the library open).
    public static func mapMusicIDs(store: Store, roots: [String], bridge: MusicBridge) throws -> Int {
        var n = 0
        for t in try bridge.fileTracks() {
            for root in roots where t.path.hasPrefix(root + "/") {
                n += try store.db.run("UPDATE legacy_files SET music_persistent_id=? WHERE root=? AND rel_path=?", [.text(t.persistentID), .text(root), .text(String(t.path.dropFirst(root.count + 1)))])
            }
        }
        return n
    }

    /// Applies an approved supersede proposal with the library open: carry stats to the mirror track, remove the
    /// legacy entry from Music, move the legacy file into quarantine. Returns items still to do.
    public static func apply(_ p: Store.Proposal, store: Store, bridge: MusicBridge, quarantineDir: String, roots: [String] = []) -> [Store.ProposalItem] {
        var remaining: [Store.ProposalItem] = []
        var items = p.items
        if items.contains(where: { $0.musicPersistentID == nil && $0.legacyID != nil }) {
            // Never quarantine a file Music still references: map persistent IDs first.
            _ = try? mapMusicIDs(store: store, roots: roots, bridge: bridge)
            items = items.map { i in
                var i = i
                if i.musicPersistentID == nil, let lid = i.legacyID, case let .text(pid)? = try? store.db.scalar("SELECT music_persistent_id FROM legacy_files WHERE id=?", [.integer(lid)]) { i.musicPersistentID = pid }
                return i
            }
        }
        for item in items {
            do {
                if let pid = item.musicPersistentID {
                    if let to = item.counterpartPersistentID { try? bridge.copyStats(from: pid, to: to) }
                    do { try bridge.remove(persistentID: pid) } catch let e where "\(e)".contains("get") { /* already gone */ }
                }
                if FileManager.default.fileExists(atPath: item.relPath) {
                    let dest = quarantineDir + "/legacy/" + item.relPath.split(separator: "/").suffix(3).joined(separator: "/")
                    try FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(atPath: item.relPath, toPath: dest)
                }
                if let lid = item.legacyID { try store.db.run("UPDATE legacy_files SET superseded_at=? WHERE id=?", [.real(Date().timeIntervalSince1970), .integer(lid)]) }
                try? store.log("info", "review", "superseded legacy \(item.relPath)", relPath: item.relPath)
            } catch {
                remaining.append(item)
                try? store.log("warn", "review", "supersede failed: \(error)", relPath: item.relPath)
            }
        }
        return remaining
    }
}
