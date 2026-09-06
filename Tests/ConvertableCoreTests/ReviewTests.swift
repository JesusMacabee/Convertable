import XCTest
@testable import ConvertableCore

/// Change handling end to end: retag, re-encode, rename, orphan → proposal → quarantine.
final class ChangeHandlingTests: XCTestCase {
    var lib: URL!, mirror: URL!, work: URL!
    var store: Store!
    var now: Double = Date().timeIntervalSince1970 + 1   // real clock: the pipeline stamps outputs with wall time

    override func setUpWithError() throws {
        guard Fixtures.available else { throw XCTSkip("fixture library not present") }
        lib = try Fixtures.tempDir("chg-lib"); mirror = try Fixtures.tempDir("chg-mirror"); work = try Fixtures.tempDir("chg-work")
        store = try Store.inMemory()
    }
    override func tearDownWithError() throws { for u in [lib, mirror, work] { try? FileManager.default.removeItem(at: u!) } }

    func add(_ fixture: URL, as rel: String) throws {
        let dst = lib.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: dst)
    }
    func scan() throws { let s = LibraryScanner(root: lib.path, store: store); s.clock = { self.now }; try s.fullScan(); now += 60 }
    func runAll() async throws -> Pipeline.Summary {
        let plan = try Planner(store: store, profile: .ipodClassic, fileSettleSeconds: 0, albumSettleSeconds: 0).plan(Selection(mode: .everything, ignoreSettle: true))
        let cfg = Pipeline.Config(sourceRoot: lib.path, mirrorRoot: mirror.path, workDir: work.path, encodeConcurrency: 2, artMaxPixels: 600, artJPEGQuality: 0.85, profileID: "ipod-classic")
        return await Pipeline(config: cfg, store: store, shareIO: ShareIO(limit: 2)).run(plan, batchID: nil)
    }
    func output(_ rel: String) throws -> OutputFile? {
        try store.db.query("SELECT * FROM outputs WHERE rel_path=?", [.text(rel)], Store.output).first
    }

    func testRetagOnlyRewritesTagsAndFlagsRefresh() async throws {
        try add(try Fixtures.first("flac", containing: "16BIT"), as: "A/B/01.flac")
        try scan()
        var s = try await runAll(); XCTAssertEqual(s.tracksDone, 1)
        let before = try output("A/B/01.m4a")!
        // Retag the source (title only), then let it settle and re-plan.
        try TagWriter.write(path: lib.appendingPathComponent("A/B/01.flac").path, properties: ["TITLE": ["Renamed Song"], "ARTIST": ["X"], "ALBUM": ["B"]], picture: nil, encoderStamp: nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now)], ofItemAtPath: lib.appendingPathComponent("A/B/01.flac").path)
        try scan()
        try store.db.run("UPDATE outputs SET music_persistent_id='PID1'")   // pretend Music has it
        s = try await runAll(); XCTAssertEqual(s.tracksDone, 1)
        let after = try output("A/B/01.m4a")!
        XCTAssertEqual(after.audioMD5, before.audioMD5, "audio untouched")
        XCTAssertEqual(after.encodedAt, before.encodedAt, "no re-encode happened")
        XCTAssertNotEqual(after.tagHash, before.tagHash)
        XCTAssertEqual(try TagReader.read(mirror.appendingPathComponent("A/B/01.m4a").path).title, "Renamed Song")
        XCTAssertEqual(try store.db.scalar("SELECT music_refresh_pending FROM outputs"), .integer(1))
        XCTAssertTrue(Fixtures.contains(mirror.appendingPathComponent("A/B/01.m4a").path, marker: "iTunSMPB"), "gapless atom survives the retag")
    }

    func testAudioChangeReencodesInPlace() async throws {
        let flacs = Fixtures.all(withExtension: "flac").filter { $0.path.contains("16BIT") }
        guard flacs.count >= 2 else { throw XCTSkip("need two CD-rate fixtures") }
        try add(flacs[0], as: "A/B/01.flac"); try scan()
        _ = try await runAll()
        let before = try output("A/B/01.m4a")!
        // Replace the audio with a different track under the same name.
        try FileManager.default.removeItem(at: lib.appendingPathComponent("A/B/01.flac"))
        try add(flacs[1], as: "A/B/01.flac")
        try scan()
        let s = try await runAll(); XCTAssertEqual(s.tracksDone, 1)
        let after = try output("A/B/01.m4a")!
        XCTAssertNotEqual(after.audioMD5, before.audioMD5)
        XCTAssertGreaterThan(after.encodedAt!, before.encodedAt!, "re-encoded")
        XCTAssertEqual(try store.db.scalar("SELECT COUNT(*) FROM outputs"), .integer(1), "same output row, same path")
    }

    func testRenameMovesOutputWithoutReencoding() async throws {
        try add(try Fixtures.first("flac", containing: "16BIT"), as: "A/B/01 old name.flac"); try scan()
        _ = try await runAll()
        let before = try output("A/B/01 old name.m4a")!
        try store.db.run("UPDATE outputs SET music_persistent_id='PID1'")
        try FileManager.default.moveItem(at: lib.appendingPathComponent("A/B/01 old name.flac"), to: lib.appendingPathComponent("A/B/01 new name.flac"))
        try scan()   // old missing, new added
        let s = try await runAll(); XCTAssertEqual(s.tracksDone, 1)
        XCTAssertNil(try output("A/B/01 old name.m4a"))
        let after = try output("A/B/01 new name.m4a")!
        XCTAssertEqual(after.id, before.id, "same output row re-pointed")
        XCTAssertEqual(after.encodedAt, before.encodedAt, "no re-encode")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("A/B/01 new name.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("A/B/01 old name.m4a").path))
        XCTAssertEqual(try store.db.scalar("SELECT music_relocate_pending FROM outputs"), .integer(1))
        XCTAssertEqual(try store.db.scalar("SELECT COUNT(*) FROM source_files"), .integer(1), "old source row removed")
    }

    func testOrphanNeedsTwoFullScansThenProposesThenQuarantines() async throws {
        try add(try Fixtures.first("flac", containing: "16BIT"), as: "A/B/01.flac")
        try add(try Fixtures.first("mp3"), as: "A/B/02.mp3")
        try scan(); _ = try await runAll()
        try store.db.run("UPDATE outputs SET music_persistent_id='PIDX' WHERE rel_path LIKE '%.mp3'")
        try FileManager.default.removeItem(at: lib.appendingPathComponent("A/B"))
        let reviewer = Reviewer(store: store, mirrorRoot: mirror.path)
        try scan()
        XCTAssertEqual(try reviewer.detectOrphans(), 0, "one full scan of absence is not enough")
        try scan()
        XCTAssertEqual(try reviewer.detectOrphans(), 1)
        XCTAssertEqual(try reviewer.detectOrphans(), 0, "not proposed twice")
        let p = try store.proposals()[0]
        XCTAssertEqual(p.kind, "remove"); XCTAssertEqual(p.items.count, 2); XCTAssertEqual(p.title, "Remove album from mirror")
        XCTAssertTrue(p.reason.contains("2 full scans"))
        // Approve: files move to quarantine; the Music-side item stays for later.
        let remaining = try await reviewer.applyRemove(p, shareIO: ShareIO(limit: 2))
        XCTAssertEqual(remaining.count, 1); XCTAssertEqual(remaining[0].musicPersistentID, "PIDX")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("A/B/01.m4a").path))
        let q = mirror.appendingPathComponent(".quarantine").path
        let quarantined = FileManager.default.enumerator(atPath: q)!.compactMap { $0 as? String }.filter { $0.hasSuffix(".m4a") || $0.hasSuffix(".mp3") }
        XCTAssertEqual(quarantined.count, 2)
        XCTAssertEqual(try store.db.scalar("SELECT COUNT(*) FROM outputs"), .integer(0))
        XCTAssertEqual(try store.db.scalar("SELECT COUNT(*) FROM source_files"), .integer(0))
    }

    func testReappearanceWithdrawsProposal() async throws {
        try add(try Fixtures.first("flac", containing: "16BIT"), as: "A/B/01.flac")
        try scan(); _ = try await runAll()
        let backup = try Fixtures.tempDir("chg-backup").appendingPathComponent("01.flac")
        try FileManager.default.moveItem(at: lib.appendingPathComponent("A/B/01.flac"), to: backup)
        try scan(); try scan()
        let reviewer = Reviewer(store: store, mirrorRoot: mirror.path)
        XCTAssertEqual(try reviewer.detectOrphans(), 1)
        try FileManager.default.moveItem(at: backup, to: lib.appendingPathComponent("A/B/01.flac"))
        try scan()
        XCTAssertEqual(try reviewer.withdrawStaleProposals(), 1)
        XCTAssertEqual(try store.proposals(states: ["dismissed"]).first?.error, "withdrawn: source reappeared or was moved")
        XCTAssertTrue(try store.proposals().isEmpty)
    }

    func testQuarantinePurgeRespectsRetention() async throws {
        let reviewer = Reviewer(store: store, mirrorRoot: mirror.path)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let old = df.string(from: Date(timeIntervalSince1970: now - 40 * 86400)), recent = df.string(from: Date(timeIntervalSince1970: now - 2 * 86400))
        for d in [old, recent] { try FileManager.default.createDirectory(atPath: mirror.path + "/.quarantine/\(d)/x", withIntermediateDirectories: true) }
        var r = reviewer; r.clock = { self.now }
        let purged = await r.purgeQuarantine(retentionDays: 30, shareIO: ShareIO(limit: 1))
        XCTAssertEqual(purged, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.path + "/.quarantine/\(old)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror.path + "/.quarantine/\(recent)"))
    }
}

final class MusicPendingProcessingTests: XCTestCase {
    func testRefreshRelocateAndRemovals() throws {
        let store = try Store.inMemory()
        var settings = Settings(); settings.mirrorRoot = "/M"
        let sid = try store.db.insert("INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan) VALUES ('A/B/1.flac','A','B','.flac','lossless',1,1,1,3,1,1)")
        try store.db.run("INSERT INTO outputs (source_id, rel_path, encoder_profile, verify_ok, music_persistent_id, music_refresh_pending) VALUES (?,'A/B/1.m4a','x',1,'P1',1)", [.integer(sid)])
        let sid2 = try store.db.insert("INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan) VALUES ('A/B/2.flac','A','B','.flac','lossless',1,1,1,3,1,1)")
        try store.db.run("INSERT INTO outputs (source_id, rel_path, encoder_profile, verify_ok, music_persistent_id, music_relocate_pending) VALUES (?,'A/B/2.m4a','x',1,'P2',1)", [.integer(sid2)])
        let pid = try store.insertProposal(kind: "remove", album: AlbumKey(artistDir: "Z", albumDir: "Q"), title: "t", reason: "r",
                                           items: [.init(outputID: nil, legacyID: nil, relPath: "Z/Q/9.m4a", musicPersistentID: "P9", bytes: 1, counterpartPersistentID: nil)], now: 1)
        try store.setProposalState(pid, "approved")
        let m = MockRunner()
        m.answers = [
            { s in XCTAssertTrue(s.contains("refresh")); return .success("") },
            { s in XCTAssertTrue(s.contains("set location")); return .failure(.script("Can’t set location")) },   // Music refuses → fallback
            { s in XCTAssertTrue(s.contains("add (")); return .success("P2NEW\u{1F}/M/A/B/2.m4a") },
            { s in XCTAssertTrue(s.contains("played count")); return .success("") },
            { s in XCTAssertTrue(s.contains("delete")); return .success("") },
            { s in XCTAssertTrue(s.contains("delete")); XCTAssertTrue(s.contains("P9")); return .success("") },
        ]
        let imp = MusicImporter(store: store, settings: settings, profile: .ipodClassic, bridge: MusicBridge(runner: m), gate: { .success(()) })
        let r = imp.processPending(mirrorRoot: "/M", reviewer: Reviewer(store: store, mirrorRoot: "/M"))
        XCTAssertEqual(r.refreshed, 1); XCTAssertEqual(r.relocated, 1); XCTAssertEqual(r.removed, 1); XCTAssertEqual(r.failed, 0)
        XCTAssertEqual(try store.db.scalar("SELECT music_persistent_id FROM outputs WHERE rel_path='A/B/2.m4a'"), .text("P2NEW"))
        XCTAssertEqual(try store.db.scalar("SELECT SUM(music_refresh_pending)+SUM(music_relocate_pending) FROM outputs"), .integer(0))
        XCTAssertEqual(try store.proposal(id: pid)?.state, "done")
    }
}

final class TagPolicyTests: XCTestCase {
    func testOutputsUnderOlderPolicyAreReplannedForRetag() throws {
        let store = try Store.inMemory()
        let sid = try store.db.insert("INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan) VALUES ('A/B/1.flac','A','B','.flac','lossless',10,1,1,3,1,1)")
        try store.db.run("INSERT INTO outputs (source_id, rel_path, encoder_profile, verify_ok, encoded_at, tags_written_at, tag_policy) VALUES (?, 'A/B/1.m4a', 'x', 1, 5, 5, 0)", [.integer(sid)])
        let plan = try Planner(store: store, profile: .ipodClassic, fileSettleSeconds: 0, albumSettleSeconds: 0).plan(Selection(mode: .everything, ignoreSettle: true))
        XCTAssertEqual(plan.albums.count, 1); XCTAssertNotNil(plan.albums[0].tracks[0].existingOutput, "older tag policy → re-tag, not re-encode")
        try store.db.run("UPDATE outputs SET tag_policy=?", [.integer(Int64(TagPolicy.version))])
        XCTAssertTrue(try Planner(store: store, profile: .ipodClassic, fileSettleSeconds: 0, albumSettleSeconds: 0).plan(Selection(mode: .everything, ignoreSettle: true)).albums.isEmpty)
    }
    func testVerifierFlagsMissingArt() throws {
        let src = try Fixtures.first("flac", containing: "16BIT")
        let tmp = try Fixtures.tempDir("verify-art"); defer { try? FileManager.default.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("o.m4a").path
        try AfconvertEncoder().encode(.ipodAAC, input: src.path, output: out, sourceChannels: 2)
        try TagWriter.write(path: out, properties: ["TITLE": ["t"]], picture: nil, encoderStamp: nil)
        let d = try Verifier.durationMs(out).ms
        XCTAssertFalse(Verifier.verify(output: out, sourceDurationMs: d, expectedSampleRate: 44100, expectedTags: ["TITLE": ["t"]], expectPicture: true).ok)
        XCTAssertTrue(Verifier.verify(output: out, sourceDurationMs: d, expectedSampleRate: 44100, expectedTags: ["TITLE": ["t"]], expectPicture: false).ok)
    }
}

final class DeadEntryTests: XCTestCase {
    func testDeadEntriesGroupPerAlbumAndSkipMirrorTracks() throws {
        let store = try Store.inMemory()
        let sid = try store.db.insert("INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan) VALUES ('A/B/1.flac','A','B','.flac','lossless',1,1,1,3,1,1)")
        try store.db.run("INSERT INTO outputs (source_id, rel_path, encoder_profile, verify_ok, music_persistent_id) VALUES (?,'A/B/1.m4a','x',1,'MIRROR1')", [.integer(sid)])
        let r = Reviewer(store: store, mirrorRoot: "/M")
        let dead = [("D1", "Song 1", "Old Artist", "Old Album"), ("D2", "Song 2", "Old Artist", "Old Album"), ("D3", "Loose", "", ""), ("MIRROR1", "Ours", "A", "B")]
        XCTAssertEqual(try r.proposeDeadEntries(dead.map { ($0.0, $0.1, $0.2, $0.3) }), 2)
        XCTAssertEqual(try r.proposeDeadEntries(dead.map { ($0.0, $0.1, $0.2, $0.3) }), 0, "not proposed twice")
        let ps = try store.proposals()
        XCTAssertTrue(ps.allSatisfy { $0.kind == "dead" })
        XCTAssertTrue(ps.flatMap(\.items).map { $0.musicPersistentID! }.allSatisfy { $0 != "MIRROR1" }, "mirror tracks are never proposed as dead")
        XCTAssertEqual(ps.first { $0.artistDir == "Old Artist" }?.items.count, 2)
        XCTAssertEqual(ps.first { $0.artistDir == "(no artist)" }?.items.count, 1)
    }
}
