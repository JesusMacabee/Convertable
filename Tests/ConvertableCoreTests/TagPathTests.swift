import XCTest
@testable import ConvertableCore

final class TagPathTests: XCTestCase {
    func testSanitize() {
        XCTAssertEqual(TagPaths.sanitize("AC/DC: Live"), "AC-DC- Live")
        XCTAssertEqual(TagPaths.sanitize("  .hidden.  "), "hidden")
        XCTAssertEqual(TagPaths.sanitize(""), "Unknown")
        XCTAssertEqual(TagPaths.sanitize("Cam’ron"), "Cam’ron")
        XCTAssertEqual(TagPaths.sanitize(String(repeating: "x", count: 300)).count, 120)
    }
    func testFileName() {
        XCTAssertEqual(TagPaths.fileName(title: "Marooned", track: 4, disc: 1, discTotal: 1, ext: ".m4a", fallbackStem: "x"), "04 Marooned.m4a")
        XCTAssertEqual(TagPaths.fileName(title: "Intro", track: 1, disc: 2, discTotal: 2, ext: ".m4a", fallbackStem: "x"), "2-01 Intro.m4a")
        XCTAssertEqual(TagPaths.fileName(title: nil, track: nil, disc: nil, discTotal: nil, ext: ".mp3", fallbackStem: "raw name"), "raw name.mp3")
    }
    func file(_ id: Int64, artist: String, album: String, mbid: String?, year: Int?, title: String, track: Int, hasMBID: Bool = true) -> SourceFile {
        SourceFile(id: id, relPath: "\(artist)/\(album)/\(track).flac", artistDir: artist, albumDir: album, ext: ".flac", kind: .lossless, codec: nil, size: 1, mtime: 1, stableSince: 1,
                   observations: 3, firstSeen: 1, lastSeenScan: 1, status: .active, missingSince: nil, audioMD5: nil, tagHash: nil, tagArtist: artist,
                   tagAlbumArtist: artist, tagAlbum: album, hasMBID: hasMBID, tagTitle: title, tagTrack: track, tagDisc: 1, tagDiscTotal: 1, tagYear: year, mbidRelease: mbid)
    }
    func testDerivedPathsAndReleaseCollisions() throws {
        let store = try Store.inMemory()
        let a = file(1, artist: "Pink Floyd", album: "The Final Cut", mbid: "rel-A", year: 1983, title: "The Post War Dream", track: 1)
        let b = file(2, artist: "Pink Floyd", album: "The Final Cut", mbid: "rel-B", year: 1983, title: "The Post War Dream", track: 1)   // other pressing
        let a2 = file(3, artist: "Pink Floyd", album: "The Final Cut", mbid: "rel-A", year: 1983, title: "Your Possible Pasts", track: 2)
        XCTAssertEqual(try TagPaths.outputRelPath(for: a, outputExt: ".m4a", store: store), "Pink Floyd/The Final Cut (1983)/01 The Post War Dream.m4a")
        XCTAssertEqual(try TagPaths.outputRelPath(for: b, outputExt: ".m4a", store: store), "Pink Floyd/The Final Cut (1983) [2]/01 The Post War Dream.m4a")
        XCTAssertEqual(try TagPaths.outputRelPath(for: a2, outputExt: ".m4a", store: store), "Pink Floyd/The Final Cut (1983)/02 Your Possible Pasts.m4a", "same release → same folder")
        XCTAssertNil(try TagPaths.outputRelPath(for: file(4, artist: "X", album: "Y", mbid: nil, year: nil, title: "t", track: 1, hasMBID: false), outputExt: ".m4a", store: store), "no IDs → no tag-derived path")
    }
    func testArtistLevelFollowsSourceFolderNotAlbumArtistTag() throws {
        let store = try Store.inMemory()
        var f = file(1, artist: "21 Savage", album: "Savage Mode II", mbid: "rel-S", year: 2020, title: "Runnin", track: 3)
        f.tagAlbumArtist = "21 Savage & Metro Boomin"
        XCTAssertEqual(try TagPaths.outputRelPath(for: f, outputExt: ".m4a", store: store), "21 Savage/Savage Mode II (2020)/03 Runnin.m4a")
        var g = file(2, artist: "Boston", album: "Born to Run", mbid: "rel-B", year: 1975, title: "Thunder Road", track: 1)
        g.tagAlbumArtist = "Bruce Springsteen"
        XCTAssertEqual(try TagPaths.outputRelPath(for: g, outputExt: ".m4a", store: store), "Boston/Born to Run (1975)/01 Thunder Road.m4a", "mis-filed album stays in the folder the user put it in")
    }
    func testAlbumFolderRegistryFollowsRenamedPreference() throws {
        let store = try Store.inMemory()
        XCTAssertEqual(try store.albumFolder(releaseKey: "release:A", preferred: "Old Artist/Album (2001)"), "Old Artist/Album (2001)")
        XCTAssertEqual(try store.albumFolder(releaseKey: "release:A", preferred: "Old Artist/Album (2001)"), "Old Artist/Album (2001)", "stable while unchanged")
        XCTAssertEqual(try store.albumFolder(releaseKey: "release:B", preferred: "Old Artist/Album (2001)"), "Old Artist/Album (2001) [2]")
        XCTAssertEqual(try store.albumFolder(releaseKey: "release:B", preferred: "Old Artist/Album (2001)"), "Old Artist/Album (2001) [2]", "collision suffix is stable")
        XCTAssertEqual(try store.albumFolder(releaseKey: "release:A", preferred: "Folder/Album (2001)"), "Folder/Album (2001)", "preferred name changed → re-registered")
        XCTAssertEqual(try store.albumFolder(releaseKey: "release:C", preferred: "Old Artist/Album (2001)"), "Old Artist/Album (2001)", "the vacated name is free again")
    }
    func testPlannerHoldsUntaggedAlbums() throws {
        let store = try Store.inMemory()
        func insert(_ artist: String, _ album: String, _ n: Int, mbid: Int?) throws {
            for i in 1...n {
                try store.db.run("""
                    INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan, has_mbid, tag_audit_at, tag_albumartist, tag_album, tag_title, tag_track, tag_year, mbid_release)
                    VALUES (?,?,?,'.flac','lossless',10,1,1,3,1,1,?,?,?,?,?,?,2000,?)
                    """, [.text("\(artist)/\(album)/\(i).flac"), .text(artist), .text(album), Database.Value(mbid), .real(mbid == nil ? 0 : 1),
                          .text(artist), .text(album), .text("Track \(i)"), .integer(Int64(i)), .text("rel-\(album)")])
            }
        }
        try insert("Tagged", "Album", 2, mbid: 1); try insert("Untagged", "Album", 2, mbid: 0); try insert("Pending", "Album", 2, mbid: nil)
        try store.db.run("UPDATE source_files SET tag_audit_at=NULL WHERE artist_dir='Pending'")
        let planner = Planner(store: store, profile: .ipodClassic, fileSettleSeconds: 0, albumSettleSeconds: 0, requireMusicBrainz: true, tagDerivedPaths: true)
        let plan = try planner.plan(Selection(mode: .everything, ignoreSettle: true))
        XCTAssertEqual(plan.albums.map(\.key.artistDir), ["Tagged"])
        XCTAssertEqual(plan.albums[0].tracks[0].outputRelPath, "Tagged/Album (2000)/01 Track 1.m4a")
        XCTAssertTrue(plan.ineligible.contains { $0.0.artistDir == "Untagged" && $0.1 == .needsTagging(untagged: 2) })
        XCTAssertTrue(plan.ineligible.contains { $0.0.artistDir == "Pending" && $0.1 == .auditing })
        let off = Planner(store: store, profile: .ipodClassic, fileSettleSeconds: 0, albumSettleSeconds: 0, requireMusicBrainz: false, tagDerivedPaths: false)
        XCTAssertEqual(try off.plan(Selection(mode: .everything, ignoreSettle: true)).albums.count, 3, "gate off → everything converts under folder names")
    }
    func testAuditRecordsMBIDPresenceOnFixtures() async throws {
        let src = try Fixtures.first("flac", containing: "16BIT")
        let store = try Store.inMemory()
        let root = src.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let rel = String(src.path.dropFirst(root.count + 1))
        try store.db.run("INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan) VALUES (?,?,?,'.flac','lossless',1,1,1,3,1,1)",
                         [.text(rel), .text(rel.components(separatedBy: "/")[0]), .text(rel.components(separatedBy: "/")[1])])
        let r = try await TagAudit(store: store, sourceRoot: root).run(shareIO: ShareIO(limit: 2))
        XCTAssertEqual(r.audited, 1)
        let f = try store.sourceFile(relPath: rel)!
        XCTAssertNotNil(f.hasMBID); XCTAssertNotNil(f.tagTitle); XCTAssertNotNil(f.tagTrack)
        XCTAssertTrue(try store.filesNeedingTagAudit().isEmpty, "audited files are not re-audited until they change")
    }
}

final class RepathTests: XCTestCase {
    func testRepathMovesMirroredFilesAndFlagsRelocation() async throws {
        let store = try Store.inMemory()
        let mirror = try Fixtures.tempDir("repath"); defer { try? FileManager.default.removeItem(at: mirror) }
        let sid = try store.db.insert("""
            INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan, has_mbid, tag_audit_at, tag_albumartist, tag_album, tag_title, tag_track, tag_year, mbid_release)
            VALUES ('Scene-Dir/Scene-Album-FLAC/01-x.flac','Scene-Dir','Scene-Album-FLAC','.flac','lossless',1,1,1,3,1,1,1,1,'Pink Floyd','Meddle','One of These Days',1,1971,'rel-1')
            """)
        try store.db.run("INSERT INTO outputs (source_id, rel_path, encoder_profile, verify_ok, music_persistent_id) VALUES (?, 'Scene-Dir/Scene-Album-FLAC/01-x.m4a', 'ipod-classic', 1, 'P1')", [.integer(sid)])
        let old = mirror.appendingPathComponent("Scene-Dir/Scene-Album-FLAC/01-x.m4a").path
        try FileManager.default.createDirectory(atPath: (old as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: old))
        let moved = await Reviewer(store: store, mirrorRoot: mirror.path).repathMirror(profile: .ipodClassic, shareIO: ShareIO(limit: 1))
        XCTAssertEqual(moved, 1)
        // Artist level stays the source folder; album folder and file name come from tags.
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("Scene-Dir/Meddle (1971)/01 One of These Days.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirror.appendingPathComponent("Scene-Dir/Scene-Album-FLAC").path), "empty old album folder removed")
        XCTAssertEqual(try store.db.scalar("SELECT rel_path FROM outputs"), .text("Scene-Dir/Meddle (1971)/01 One of These Days.m4a"))
        XCTAssertEqual(try store.db.scalar("SELECT music_relocate_pending FROM outputs"), .integer(1))
        let again = await Reviewer(store: store, mirrorRoot: mirror.path).repathMirror(profile: .ipodClassic, shareIO: ShareIO(limit: 1))
        XCTAssertEqual(again, 0, "idempotent")
    }
}
