import XCTest
@testable import ConvertableCore

/// One source folder, several MusicBrainz releases (a dump of live shows): each release is an album of its own,
/// the files without a release id form an "untagged" remainder, and a folder with a single release is untouched.
final class SplitFolderTests: XCTestCase {
    var store: Store!

    override func setUpWithError() throws { store = try Store.inMemory() }

    @discardableResult
    func file(_ artist: String, _ album: String, _ name: String, release: String?, tagAlbum: String? = nil, mirrored: Bool = false) throws -> Int64 {
        let id = try store.db.insert("""
            INSERT INTO source_files (rel_path, artist_dir, album_dir, ext, kind, size, mtime, stable_since, observations, first_seen, last_seen_scan, has_mbid, mbid_release, tag_album)
            VALUES (?,?,?,'.flac','lossless',10,1,1,3,1,1,?,?,?)
            """, [.text("\(artist)/\(album)/\(name).flac"), .text(artist), .text(album), .integer(release == nil ? 0 : 1), Database.Value(release), Database.Value(tagAlbum)])
        if mirrored { try store.db.run("INSERT INTO outputs (source_id, rel_path, encoder_profile, verify_ok, encoded_at, tags_written_at, tag_policy) VALUES (?,?,'ipod-classic',1,5,5,?)", [.integer(id), .text("\(artist)/\(album)/\(name).m4a"), .integer(Int64(TagPolicy.version))]) }
        return id
    }

    func liveShows() throws {
        for i in 1...3 { try file("Dead", "Live Shows", "veneta-\(i)", release: "rel-veneta", tagAlbum: "1972-08-27: Veneta", mirrored: true) }
        for i in 1...2 { try file("Dead", "Live Shows", "wembley-\(i)", release: "rel-wembley", tagAlbum: "Europe '72 Vol. 02: Wembley") }
        try file("Dead", "Live Shows", "stray", release: nil, tagAlbum: "Jahrhunderthalle (as was)")
        try file("Dead", "American Beauty", "01", release: "rel-ab", tagAlbum: "American Beauty")
        try file("Dead", "American Beauty", "02", release: "rel-ab", tagAlbum: "American Beauty")
        try file("Dead", "Untagged Album", "01", release: nil)
        try store.refreshReleaseGroups()
    }

    func testFolderWithSeveralReleasesSplitsIntoOneAlbumPerRelease() throws {
        try liveShows()
        let rows = try store.albumSummaries(artist: "Dead")
        XCTAssertEqual(rows.map(\.key), [
            AlbumKey(artistDir: "Dead", albumDir: "American Beauty"),
            AlbumKey(artistDir: "Dead", albumDir: "Live Shows", release: "rel-veneta"),
            AlbumKey(artistDir: "Dead", albumDir: "Live Shows", release: "rel-wembley"),
            AlbumKey(artistDir: "Dead", albumDir: "Live Shows", release: AlbumKey.untaggedRelease),
            AlbumKey(artistDir: "Dead", albumDir: "Untagged Album"),
        ])
        let veneta = rows[1], wembley = rows[2], stray = rows[3]
        XCTAssertEqual(veneta.tracks, 3); XCTAssertEqual(veneta.mirrored, 3); XCTAssertEqual(veneta.displayAlbum, "1972-08-27: Veneta")
        XCTAssertEqual(wembley.tracks, 2); XCTAssertEqual(wembley.untagged, 0)
        XCTAssertEqual(stray.tracks, 1); XCTAssertEqual(stray.untagged, 1); XCTAssertNil(stray.displayAlbum, "the remainder is named after the folder, not the stray tag")
        XCTAssertEqual(AppController.albumName(stray), "Live Shows — files without MusicBrainz tags")
        XCTAssertEqual(AppController.albumName(veneta), "1972-08-27: Veneta")
        XCTAssertEqual(AppController.albumName(rows[0]), "American Beauty", "a single-release folder keeps its folder name")
        XCTAssertEqual(try store.artistSummaries().first { $0.artistDir == "Dead" }?.albums, 5)
        XCTAssertEqual(try store.sourceFiles(in: wembley.key).map(\.relPath), ["Dead/Live Shows/wembley-1.flac", "Dead/Live Shows/wembley-2.flac"])
        XCTAssertEqual(try store.sourceFiles(in: AlbumKey(artistDir: "Dead", albumDir: "Live Shows")).count, 6, "the whole-folder key still sees every file")
        XCTAssertEqual(try store.outputs(in: veneta.key).count, 3); XCTAssertEqual(try store.outputs(in: wembley.key).count, 0)
    }

    func testPlannerConvertsTaggedReleasesWhileTheStrayFilesWaitAlone() throws {
        try liveShows()
        let planner = Planner(store: store, profile: .ipodClassic, fileSettleSeconds: 0, albumSettleSeconds: 0, requireMusicBrainz: true)
        let plan = try planner.plan(Selection(mode: .albums([AlbumKey(artistDir: "Dead", albumDir: "Live Shows")]), ignoreSettle: true))
        XCTAssertEqual(plan.albums.map(\.key.release), ["rel-wembley"], "Veneta is mirrored already; the stray file is held, not the folder")
        XCTAssertEqual(plan.albums.first?.tracks.count, 2)
        let held = plan.ineligible.first { $0.0.isUntaggedRemainder }
        if case .needsTagging(let n)? = held?.1 { XCTAssertEqual(n, 1) } else { XCTFail("untagged remainder should be the only thing needing tags: \(plan.ineligible)") }
        // Selecting one release by key plans just that release.
        let one = try planner.plan(Selection(mode: .albums([AlbumKey(artistDir: "Dead", albumDir: "Live Shows", release: "rel-wembley")]), ignoreSettle: true))
        XCTAssertEqual(one.albums.count, 1); XCTAssertEqual(one.ineligible.count, 0)
    }

    func testIgnoreWorksPerReleaseAndForTheWholeFolder() throws {
        try liveShows()
        let wembley = AlbumKey(artistDir: "Dead", albumDir: "Live Shows", release: "rel-wembley")
        try store.ignore(wembley, ignored: true)
        var rows = try store.albumSummaries(artist: "Dead")
        XCTAssertEqual(rows.filter(\.ignored).map(\.key), [wembley])
        try store.ignore(wembley, ignored: false)
        try store.ignore(AlbumKey(artistDir: "Dead", albumDir: "Live Shows"), ignored: true)
        rows = try store.albumSummaries(artist: "Dead")
        XCTAssertEqual(rows.filter(\.ignored).count, 3, "ignoring the folder ignores every release in it")
        XCTAssertEqual(try store.artistSummaries().first { $0.artistDir == "Dead" }?.albums, 2)
        XCTAssertEqual(try store.ignoredAlbums(), [AlbumKey(artistDir: "Dead", albumDir: "Live Shows")])
    }

    func testRegroupingFollowsTheTags() throws {
        // One release only: an ordinary album, even with a stray untagged file beside it.
        try file("X", "A", "1", release: "r1"); try file("X", "A", "2", release: nil)
        try store.refreshReleaseGroups()
        XCTAssertEqual(try store.albumSummaries(artist: "X").map(\.key.release), [nil])
        // Picard tags the stray as a second release: the folder splits on the next refresh.
        try store.db.run("UPDATE source_files SET mbid_release='r2', has_mbid=1 WHERE rel_path='X/A/2.flac'")
        XCTAssertEqual(try store.refreshReleaseGroups(), 2)
        XCTAssertEqual(try store.albumSummaries(artist: "X").map(\.key.release), ["r1", "r2"])
        XCTAssertEqual(try store.refreshReleaseGroups(), 0, "idempotent")
        // Music import completeness is per release, not per folder.
        let s = try store.sourceFiles(in: AlbumKey(artistDir: "X", albumDir: "A", release: "r1"))
        XCTAssertEqual(s.map(\.albumKey.release), ["r1"])
    }

    func testAlbumKeyWireFormatStaysCompatible() throws {
        let plain = try JSONDecoder().decode(AlbumKey.self, from: Data(#"{"artistDir":"A","albumDir":"B"}"#.utf8))
        XCTAssertNil(plain.release)
        let split = try JSONDecoder().decode(AlbumKey.self, from: Data(#"{"artistDir":"A","albumDir":"B","release":"r"}"#.utf8))
        XCTAssertEqual(split.release, "r")
        XCTAssertTrue(plain.covers(split)); XCTAssertFalse(split.covers(plain))
    }
}
