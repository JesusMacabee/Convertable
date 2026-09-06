import Foundation

/// Runs a Plan: per album, per track — copy in, hash + read tags, encode or copy, tag, verify, publish, record.
/// Local CPU work runs in parallel; every touch of the share goes through `ShareIO`.
public final class Pipeline: @unchecked Sendable {
    public struct Config: Sendable {
        public var sourceRoot: String
        public var mirrorRoot: String
        public var workDir: String
        public var encodeConcurrency: Int
        public var artMaxPixels: Int
        public var artJPEGQuality: Double
        public var profileID: String
        public var maxAttempts: Int = 3
        public init(sourceRoot: String, mirrorRoot: String, workDir: String, encodeConcurrency: Int, artMaxPixels: Int, artJPEGQuality: Double, profileID: String) {
            self.sourceRoot = sourceRoot; self.mirrorRoot = mirrorRoot; self.workDir = workDir
            self.encodeConcurrency = max(1, encodeConcurrency); self.artMaxPixels = artMaxPixels; self.artJPEGQuality = artJPEGQuality; self.profileID = profileID
        }
    }

    public struct TrackResult: Sendable {
        public let track: PlannedTrack
        public let ok: Bool
        public let outputBytes: Int64
        public let seconds: Double
        public let error: String?
        public let verify: Verifier.Report?
    }

    public struct AlbumResult: Sendable {
        public let album: PlannedAlbum
        public let tracks: [TrackResult]
        public var complete: Bool { tracks.allSatisfy(\.ok) }
    }

    public struct Summary: Sendable {
        public var albums: [AlbumResult] = []
        public var bytesIn: Int64 = 0
        public var bytesOut: Int64 = 0
        public var tracksDone = 0
        public var tracksFailed = 0
        public var seconds: Double = 0
        public var endedBy: String = "empty"
    }

    public enum Event: Sendable {
        case albumStarted(PlannedAlbum)
        case trackFinished(TrackResult)
        case albumFinished(AlbumResult)
        case message(String)
    }

    public let config: Config
    public let store: Store
    public let shareIO: ShareIO
    public var onEvent: (@Sendable (Event) -> Void)?
    /// Checked between tracks; a paused pipeline finishes the current tracks and stops.
    public var shouldStop: @Sendable () -> Bool = { false }

    private let storeQueue = DispatchQueue(label: "convertable.pipeline.store")

    public init(config: Config, store: Store, shareIO: ShareIO) {
        self.config = config; self.store = store; self.shareIO = shareIO
    }

    // MARK: Run

    public func run(_ plan: Plan, batchID: Int64?) async -> Summary {
        var summary = Summary()
        let t0 = Date()
        try? FileManager.default.createDirectory(atPath: config.workDir, withIntermediateDirectories: true)
        cleanStaleWork()

        albums: for album in plan.albums {
            if shouldStop() { summary.endedBy = "user"; break }
            onEvent?(.albumStarted(album))
            var results: [TrackResult] = []
            // Bounded parallelism over the album's tracks.
            await withTaskGroup(of: TrackResult.self) { group in
                var pending = album.tracks[...]
                var running = 0
                func launch(_ t: PlannedTrack) { group.addTask { await self.process(t) } }
                while running < config.encodeConcurrency, let t = pending.popFirst() { launch(t); running += 1 }
                for await r in group {
                    results.append(r); onEvent?(.trackFinished(r))
                    if !shouldStop(), let t = pending.popFirst() { launch(t) }
                }
            }
            let ar = AlbumResult(album: album, tracks: results)
            summary.albums.append(ar)
            for r in results {
                summary.bytesIn += r.track.source.size
                if r.ok { summary.bytesOut += r.outputBytes; summary.tracksDone += 1 } else { summary.tracksFailed += 1 }
            }
            onEvent?(.albumFinished(ar))
            if results.count < album.tracks.count { summary.endedBy = "user"; break albums }
        }
        summary.seconds = Date().timeIntervalSince(t0)
        if summary.endedBy == "empty", plan.backlogAlbums > 0 || !plan.overflow.isEmpty { summary.endedBy = "budget" }
        if let batchID {
            try? store(sync: { s in
                try s.db.run("UPDATE batches SET bytes_in=?, bytes_out=?, files_done=?, finished_at=?, ended_by=? WHERE id=?",
                             [.integer(summary.bytesIn), .integer(summary.bytesOut), .integer(Int64(summary.tracksDone)),
                              .real(Date().timeIntervalSince1970), .text(summary.endedBy), .integer(batchID)])
            })
        }
        return summary
    }

    // MARK: One track

    func process(_ track: PlannedTrack) async -> TrackResult {
        let t0 = Date()
        var lastError = "unknown"
        for attempt in 1...config.maxAttempts {
            do {
                let (bytes, report) = try await processOnce(track, attempt: attempt)
                return TrackResult(track: track, ok: true, outputBytes: bytes, seconds: Date().timeIntervalSince(t0), error: nil, verify: report)
            } catch {
                lastError = "\(error)"
                try? store(sync: { try $0.log("warn", "pipeline", "attempt \(attempt) failed: \(lastError)", relPath: track.source.relPath) })
                if attempt < config.maxAttempts { try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) }
            }
        }
        try? store(sync: { try $0.log("error", "pipeline", "gave up: \(lastError)", relPath: track.source.relPath) })
        return TrackResult(track: track, ok: false, outputBytes: 0, seconds: Date().timeIntervalSince(t0), error: lastError, verify: nil)
    }

    private func processOnce(_ track: PlannedTrack, attempt: Int) async throws -> (Int64, Verifier.Report) {
        let src = track.source
        let work = config.workDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }

        // 1. Copy in (share → local), verify byte count.
        let localIn = work + "/in" + src.ext
        try await shareIO.copy(from: config.sourceRoot + "/" + src.relPath, to: localIn)
        let inSize = (try? FileManager.default.attributesOfItem(atPath: localIn)[.size] as? NSNumber)?.int64Value ?? -1
        guard inSize == src.size else { throw PipelineError.copyMismatch(expected: src.size, got: inSize) }

        // 2. Tags, art, hashes, duration — all local.
        let info = try TagReader.read(localIn)
        let audioMD5 = AudioHash.audioMD5(localIn, ext: src.ext)
        let tagHash = TagHash.compute(info)
        let srcDuration = (try? Verifier.durationMs(localIn).ms) ?? info.lengthMs

        // 3. Produce the output locally.
        let outName = (track.outputRelPath as NSString).lastPathComponent
        let localOut = work + "/" + outName
        var expectedRate: Int? = nil
        switch track.action {
        case let .transcode(spec):
            try Encoders.encoder(for: spec).encode(spec, input: localIn, output: localOut, sourceChannels: info.channels)
            expectedRate = spec.sampleRate
        case .copyThrough:
            try FileManager.default.copyItem(atPath: localIn, toPath: localOut)
        case .skip:
            throw PipelineError.nothingToDo
        }

        // 4. Tags + art onto the output.
        let carried = info.properties.filter { TagPolicy.isCarried($0.key) }
        var picture: Data? = nil
        if let pic = info.pictures.first, let small = Artwork.downscale(pic.data, maxPixels: config.artMaxPixels, jpegQuality: config.artJPEGQuality) {
            picture = small.data
        }
        let stamp: String? = { if case let .transcode(spec) = track.action { return Encoders.stamp(spec) }; return nil }()
        try TagWriter.write(path: localOut, properties: carried, picture: picture, encoderStamp: stamp)

        // 5. Verify.
        let report = Verifier.verify(output: localOut, sourceDurationMs: srcDuration, expectedSampleRate: expectedRate, expectedTags: carried)
        guard report.ok else { throw PipelineError.verifyFailed(report.problems) }
        let outSize = (try? FileManager.default.attributesOfItem(atPath: localOut)[.size] as? NSNumber)?.int64Value ?? 0

        // 6. Publish atomically onto the share.
        let dest = config.mirrorRoot + "/" + track.outputRelPath
        try await shareIO.publish(localFile: localOut, to: dest)

        // 7. Record.
        let now = Date().timeIntervalSince1970
        try store(sync: { s in
            try s.setTags(id: src.id, artist: info.artist, albumArtist: info.albumArtist, album: info.album, audioMD5: audioMD5, tagHash: tagHash)
            try s.db.run("""
                INSERT INTO outputs (source_id, rel_path, size, encoder_profile, audio_md5, tag_hash, encoded_at, tags_written_at, verify_ok)
                VALUES (?,?,?,?,?,?,?,?,1)
                ON CONFLICT(rel_path) DO UPDATE SET source_id=excluded.source_id, size=excluded.size, encoder_profile=excluded.encoder_profile,
                    audio_md5=excluded.audio_md5, tag_hash=excluded.tag_hash, encoded_at=excluded.encoded_at, tags_written_at=excluded.tags_written_at, verify_ok=1
                """, [.integer(src.id), .text(track.outputRelPath), .integer(outSize), .text(self.config.profileID),
                      Database.Value(audioMD5), .text(tagHash), .real(now), .real(now)])
            try s.log("info", "pipeline", "\(track.action.label) → \(track.outputRelPath) (\(ByteCount.string(outSize)))", relPath: src.relPath)
        })
        return (outSize, report)
    }

    /// Leftovers from a crash: work dirs and `.partial` files under the mirror root are ours to remove.
    func cleanStaleWork() {
        if let items = try? FileManager.default.contentsOfDirectory(atPath: config.workDir) {
            for i in items { try? FileManager.default.removeItem(atPath: config.workDir + "/" + i) }
        }
    }

    // Store access is serialized; the Store itself is not thread-safe.
    @discardableResult
    private func store<T>(sync body: (Store) throws -> T) rethrows -> T {
        try storeQueue.sync { try body(store) }
    }

    public enum PipelineError: Error, CustomStringConvertible {
        case copyMismatch(expected: Int64, got: Int64)
        case verifyFailed([String])
        case nothingToDo
        public var description: String {
            switch self {
            case let .copyMismatch(e, g): return "copied \(g) bytes, expected \(e) (file still being written?)"
            case let .verifyFailed(p): return "verify failed: " + p.joined(separator: "; ")
            case .nothingToDo: return "nothing to do"
            }
        }
    }
}
