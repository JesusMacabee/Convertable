import Foundation

/// Turns the scanned library plus a Selection into an ordered list of albums to process.
/// Albums are the unit: never split across a cap, ordered pinned-first then oldest-first.
public struct Planner {
    public let store: Store
    public let profile: Profile
    public let fileSettleSeconds: Int
    public let albumSettleSeconds: Int
    public var requireMusicBrainz = false
    public var tagDerivedPaths = false
    public var clock: () -> Double = { Date().timeIntervalSince1970 }

    public init(store: Store, profile: Profile, fileSettleSeconds: Int, albumSettleSeconds: Int, requireMusicBrainz: Bool = false, tagDerivedPaths: Bool = false) {
        self.store = store; self.profile = profile
        self.fileSettleSeconds = fileSettleSeconds; self.albumSettleSeconds = albumSettleSeconds
        self.requireMusicBrainz = requireMusicBrainz; self.tagDerivedPaths = tagDerivedPaths
    }

    public func plan(_ selection: Selection) throws -> Plan {
        let now = clock()
        let pins = try store.pinnedArtists()
        var summaries = try store.albumSummaries()

        // Restrict to the selection.
        switch selection.mode {
        case let .artists(list):
            let set = Set(list)
            summaries = summaries.filter { set.contains($0.key.artistDir) }
        case let .albums(list):
            let set = Set(list)
            summaries = summaries.filter { set.contains($0.key) }
        case .size, .everything:
            break
        }

        var candidates: [PlannedAlbum] = []
        var ineligible: [(AlbumKey, Plan.Ineligibility)] = []

        for s in summaries {
            guard s.mirrored < s.tracks || s.stale > 0 else { ineligible.append((s.key, .nothingToDo)); continue }
            if requireMusicBrainz {
                // Whole albums only: a mix of tagged and untagged tracks would split the album across two names.
                if s.untagged > 0 { ineligible.append((s.key, .needsTagging(untagged: s.untagged))); continue }
                if s.unaudited > 0 { ineligible.append((s.key, .auditing)); continue }
            }
            if !selection.ignoreSettle {
                let fileWait = Double(fileSettleSeconds) - (now - s.lastChange)
                let albumWait = Double(albumSettleSeconds) - (now - s.lastChange)
                let wait = max(fileWait, albumWait)
                if s.minObservations < 2 || wait > 0 {
                    ineligible.append((s.key, .settling(secondsLeft: max(1, Int(wait.rounded(.up))))))
                    continue
                }
            }
            let files = try store.sourceFiles(in: s.key)
            let outputs = try store.outputs(in: s.key)
            var work: [(SourceFile, Action, OutputFile?)] = []
            for f in files {
                let a = profile.action(for: f)
                guard a.isWork else { continue }
                if let o = outputs[f.id], o.verifyOK {
                    // Already mirrored; only re-visit if the source changed after the output was written.
                    if o.tagPolicy < TagPolicy.version { work.append((f, a, o)) }
                    else if let written = o.tagsWrittenAt ?? o.encodedAt, f.stableSince > written { work.append((f, a, o)) }
                    continue
                }
                work.append((f, a, nil))
            }
            guard !work.isEmpty else { ineligible.append((s.key, .allSkipped)); continue }
            let mapping = PathMapping.outputRelPaths(for: work.map { ($0.0.relPath, $0.1) })
            var tracks: [PlannedTrack] = []
            for (f, a, o) in work {
                var path = o?.relPath ?? mapping[f.relPath] ?? f.relPath
                if o == nil, tagDerivedPaths, let ext = Planner.outputExtension(f, a), let derived = try TagPaths.outputRelPath(for: f, outputExt: ext, store: store) {
                    path = derived
                }
                tracks.append(PlannedTrack(source: f, action: a, outputRelPath: path, estimatedOutBytes: o == nil ? Planner.estimate(f, a) : 0, existingOutput: o))
            }
            candidates.append(PlannedAlbum(key: s.key, displayArtist: s.displayArtist ?? s.key.artistDir,
                                           displayAlbum: s.displayAlbum ?? (s.key.albumDir.isEmpty ? "(loose files)" : s.key.albumDir),
                                           tracks: tracks, pinned: pins.contains(s.key.artistDir), firstSeen: s.firstSeen))
        }

        // Order: pinned first, then oldest first_seen, then path.
        candidates.sort {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.firstSeen != $1.firstSeen { return $0.firstSeen < $1.firstSeen }
            return $0.key < $1.key
        }
        // In artist/album modes, keep the user's own order of artists (after pins).
        if case let .artists(list) = selection.mode {
            let rank = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1, $0) })
            candidates.sort {
                if $0.pinned != $1.pinned { return $0.pinned }
                let ra = rank[$0.key.artistDir] ?? .max, rb = rank[$1.key.artistDir] ?? .max
                if ra != rb { return ra < rb }
                return $0.key < $1.key
            }
        }

        // Apply the cap album by album; never split an album.
        var fits: [PlannedAlbum] = [], overflow: [PlannedAlbum] = []
        var used: Int64 = 0
        for a in candidates {
            // An album larger than the whole cap still goes first rather than blocking forever.
            if let cap = selection.cap, used + a.bytesIn > cap, !fits.isEmpty {
                overflow.append(a); continue
            }
            fits.append(a); used += a.bytesIn
        }

        // For size/everything, "overflow" is just the backlog remaining after this batch.
        var backlogAlbums = 0; var backlogBytes: Int64 = 0
        if case .size = selection.mode { backlogAlbums = overflow.count; backlogBytes = overflow.reduce(0) { $0 + $1.bytesIn }; overflow = [] }
        if case .everything = selection.mode, selection.cap != nil { backlogAlbums = overflow.count; backlogBytes = overflow.reduce(0) { $0 + $1.bytesIn }; overflow = [] }

        return Plan(selection: selection, albums: fits, overflow: overflow, ineligible: ineligible, backlogAlbums: backlogAlbums, backlogBytes: backlogBytes)
    }

    static func outputExtension(_ f: SourceFile, _ a: Action) -> String? {
        switch a {
        case let .transcode(spec): return spec.outputExtension
        case .copyThrough: return f.ext
        case .skip: return nil
        }
    }

    static func estimate(_ f: SourceFile, _ a: Action) -> Int64 {
        switch a {
        case let .transcode(spec): return Int64(Double(f.size) * spec.estimatedRatio)
        case .copyThrough: return f.size
        case .skip: return 0
        }
    }
}

/// "25GB", "1.5 TB", "800MB", "1000000" → bytes (decimal units, matching Finder).
public enum ByteParser {
    public static func parse(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: " ", with: "")
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("T", 1e12), ("G", 1e9), ("M", 1e6), ("K", 1e3), ("B", 1)]
        for (u, m) in units where t.hasSuffix(u) {
            guard let v = Double(t.dropLast(u.count)) else { return nil }
            return Int64(v * m)
        }
        return Int64(t)
    }
}
