import Foundation

/// Reads the tags of files the scanner found (new or changed) and records what the planner needs:
/// MusicBrainz presence, display names, and the fields tag-derived paths are built from.
/// Runs through ShareIO so it never floods the share; ~40 ms per file over SMB.
public struct TagAudit {
    public let store: Store
    public let sourceRoot: String
    public var onProgress: ((Int, Int) -> Void)?

    public init(store: Store, sourceRoot: String) { self.store = store; self.sourceRoot = sourceRoot }

    public struct Result: Sendable { public var audited = 0, withMBID = 0, failed = 0 }

    public func run(shareIO: ShareIO, isCancelled: @escaping () -> Bool = { false }) async throws -> Result {
        var res = Result()
        var seen: Set<Int64> = []
        while true {
            let batch = try store.filesNeedingTagAudit().filter { !seen.contains($0.id) }
            if batch.isEmpty { break }
            for f in batch {
                if isCancelled() { return res }
                seen.insert(f.id)
                let path = sourceRoot + "/" + f.relPath
                let now = Date().timeIntervalSince1970
                do {
                    let info = try await shareIO.perform("tag-audit") { try TagReader.read(path) }
                    try store.recordTagAudit(id: f.id, info: info, now: now)
                    res.audited += 1
                    if info.first("MUSICBRAINZ_ALBUMID") != nil || info.first("MUSICBRAINZ_TRACKID") != nil { res.withMBID += 1 }
                } catch {
                    // Unreadable: mark audited without IDs so the album is held back rather than retried forever.
                    try store.db.run("UPDATE source_files SET has_mbid=0, tag_audit_at=? WHERE id=?", [.real(now), .integer(f.id)])
                    res.failed += 1
                }
                if (res.audited + res.failed) % 200 == 0 { onProgress?(res.audited + res.failed, res.withMBID) }
            }
        }
        return res
    }
}

/// Mirror paths from tags: `Album Artist/Album (Year)/[Disc-]NN Title.ext`, filesystem-safe.
public enum TagPaths {
    public static func sanitize(_ s: String, max: Int = 120) -> String {
        var t = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        t = t.unicodeScalars.filter { $0.value >= 0x20 && $0 != "\\" && $0 != "\u{7F}" }.map(String.init).joined()
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        while t.hasSuffix(".") || t.hasSuffix(" ") { t.removeLast() }
        while t.hasPrefix(".") { t.removeFirst() }
        if t.count > max { t = String(t.prefix(max)).trimmingCharacters(in: .whitespaces) }
        return t.isEmpty ? "Unknown" : t
    }

    /// Preferred album folder (before collision handling): `Album Artist/Album (Year)`.
    public static func albumFolder(albumArtist: String?, album: String?, year: Int?) -> String {
        let artist = sanitize(albumArtist ?? "Unknown Artist")
        var alb = sanitize(album ?? "Unknown Album")
        if let year { alb += " (\(year))" }
        return artist + "/" + alb
    }

    /// File name within the album folder.
    public static func fileName(title: String?, track: Int?, disc: Int?, discTotal: Int?, ext: String, fallbackStem: String) -> String {
        var name = ""
        if let disc, (discTotal ?? 1) > 1 { name += "\(disc)-" }
        if let track { name += String(format: "%02d ", track) }
        name += sanitize(title ?? fallbackStem, max: 150)
        return name + ext
    }

    /// Full relative output path for a source file, or nil when the tags are not trustworthy enough.
    public static func outputRelPath(for f: SourceFile, outputExt: String, store: Store) throws -> String? {
        guard f.hasMBID == true else { return nil }
        let preferred = albumFolder(albumArtist: f.tagAlbumArtist ?? f.tagArtist, album: f.tagAlbum, year: f.tagYear)
        let key = f.mbidRelease.map { "release:" + $0 } ?? "dirs:" + f.artistDir + "/" + f.albumDir
        let folder = try store.albumFolder(releaseKey: key, preferred: preferred)
        return folder + "/" + fileName(title: f.tagTitle, track: f.tagTrack, disc: f.tagDisc, discTotal: f.tagDiscTotal, ext: outputExt, fallbackStem: f.stem)
    }
}
