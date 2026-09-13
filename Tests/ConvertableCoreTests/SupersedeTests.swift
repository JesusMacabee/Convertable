import XCTest
@testable import ConvertableCore

final class SupersedeTests: XCTestCase {
    func testNormalisation() {
        XCTAssertEqual(Norm.key("The Beatles"), "beatles")
        XCTAssertEqual(Norm.key("B.O.A.T.S II: Metime (Deluxe Edition)"), "boatsiimetime")
        XCTAssertEqual(Norm.key("Beyoncé & Jay-Z"), "beyonceandjayz")
        XCTAssertEqual(Norm.key("21 Savage & Metro Boomin"), Norm.key("21 Savage and Metro Boomin"))
        XCTAssertEqual(Norm.trackNumber("3/12"), 3); XCTAssertNil(Norm.trackNumber(nil))
    }

    func testMatcherProposesOnlyForCompleteMirrorAlbumsWithLegacyTwins() throws {
        let store = try Store.inMemory()
        // Mirror album (complete, tagged) and a partial one.
        for (i, t) in ["No Advance", "No Heart", "X"].enumerated() {
            let sid = try store.db.insert("""
                INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan, tag_albumartist, tag_album)
                VALUES (?,?,?,'.flac','lossless',10,1,1,3,1,1,'21 Savage & Metro Boomin','Savage Mode')
                """, [.text("21 Savage/Savage Mode (2016)/0\(i + 1) - \(t).flac"), .text("21 Savage"), .text("Savage Mode (2016)")])
            try store.db.run("INSERT INTO outputs (source_id, rel_path, encoder_profile, verify_ok, music_persistent_id, encoded_at) VALUES (?,?,'x',1,?,1)", [.integer(sid), .text("21 Savage/Savage Mode (2016)/0\(i + 1) - \(t).m4a"), .text("M\(i)")])
        }
        try store.db.run("INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan, tag_albumartist, tag_album) VALUES ('Adele/21/1.flac','Adele','21','.flac','lossless',10,1,1,3,1,1,'Adele','21')")
        // Legacy: the same album under a differently spelled artist, plus an unrelated one.
        for (i, t) in ["No Advance", "No Heart", "X"].enumerated() {
            try store.db.run("INSERT INTO legacy_files (root, rel_path, size, album_artist_norm, album_norm, title_norm, track_no, duration_ms, music_persistent_id, indexed_at) VALUES ('/L',?,5,?,?,?,?,1000,?,1)",
                             [.text("21 Savage and Metro Boomin/Savage Mode/\(i + 1) \(t).m4a"), .text(Norm.key("21 Savage and Metro Boomin")), .text(Norm.key("Savage Mode")), .text(Norm.key(t)), .integer(Int64(i + 1)), .text("L\(i)")])
        }
        try store.db.run("INSERT INTO legacy_files (root, rel_path, size, album_artist_norm, album_norm, title_norm, indexed_at) VALUES ('/L','Adele/21/1.m4a',5,?,?,'x',1)", [.text(Norm.key("Adele")), .text(Norm.key("21"))])
        try store.db.run("INSERT INTO legacy_files (root, rel_path, size, album_artist_norm, album_norm, title_norm, indexed_at) VALUES ('/L','CAKE/Fashion Nugget/1.m4a',5,?,?,'x',1)", [.text(Norm.key("CAKE")), .text(Norm.key("Fashion Nugget"))])

        // A second mirror edition of the same album must not produce a second proposal for the same legacy files.
        for (i, t) in ["No Advance", "No Heart", "X"].enumerated() {
            let sid = try store.db.insert("""
                INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan, tag_albumartist, tag_album)
                VALUES (?,?,?,'.flac','lossless',10,1,1,3,1,1,'21 Savage & Metro Boomin','Savage Mode')
                """, [.text("21 Savage/Savage Mode (Vinyl)/0\(i + 1) - \(t).flac"), .text("21 Savage"), .text("Savage Mode (Vinyl)")])
            try store.db.run("INSERT INTO outputs (source_id, rel_path, encoder_profile, verify_ok, music_persistent_id, encoded_at) VALUES (?,?,'x',1,?,1)", [.integer(sid), .text("21 Savage/Savage Mode (Vinyl)/0\(i + 1) - \(t).m4a"), .text("V\(i)")])
        }
        let m = SupersedeMatcher(store: store, profile: .ipodClassic)
        XCTAssertEqual(try m.run(), 1, "one proposal per legacy album, even with two mirror editions")
        XCTAssertEqual(try m.run(), 0, "not proposed twice")
        let p = try store.proposals()[0]
        XCTAssertEqual(p.kind, "supersede"); XCTAssertEqual(p.items.count, 3)
        XCTAssertTrue(p.title.hasPrefix("Replace the old AAC"), p.title)
        XCTAssertEqual(p.items[0].counterpartPersistentID, "M0"); XCTAssertEqual(p.items[2].musicPersistentID, "L2")
        XCTAssertEqual(p.items[0].relPath, "/L/21 Savage and Metro Boomin/Savage Mode/1 No Advance.m4a")
    }

    func testApplyCarriesStatsRemovesAndQuarantines() throws {
        let store = try Store.inMemory()
        let tmp = try Fixtures.tempDir("supersede")
        let legacyFile = tmp.appendingPathComponent("L/Artist/Album/1.m4a").path
        try FileManager.default.createDirectory(atPath: (legacyFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: legacyFile))
        let lid = try store.db.insert("INSERT INTO legacy_files (root, rel_path, size, indexed_at) VALUES (?, 'Artist/Album/1.m4a', 1, 1)", [.text(tmp.path + "/L")])
        let pid = try store.insertProposal(kind: "supersede", album: AlbumKey(artistDir: "A", albumDir: "B"), title: "t", reason: "r",
                                           items: [.init(outputID: nil, legacyID: lid, relPath: legacyFile, musicPersistentID: "LP", bytes: 1, counterpartPersistentID: "MP")], now: 1)
        let m = MockRunner()
        m.answers = [
            { s in XCTAssertTrue(s.contains("played count") && s.contains("LP") && s.contains("MP")); return .success("") },
            { s in XCTAssertTrue(s.contains("delete") && s.contains("LP")); return .success("") },
        ]
        let remaining = SupersedeMatcher.apply(try store.proposal(id: pid)!, store: store, bridge: MusicBridge(runner: m), quarantineDir: tmp.path + "/q")
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path + "/q/legacy/Artist/Album/1.m4a"))
        XCTAssertNotNil(try store.db.scalar("SELECT superseded_at FROM legacy_files WHERE id=?", [.integer(lid)]).flatMap { if case .real = $0 { return true }; return nil })
    }
}
